// lcvex_l2_wb.sv
// B3-L2-WB：模块级 64B、2-way、write-back/write-allocate L2。
//
// 设计边界：
//   * 单发射、单未完成事务；下游以 8B M1-B beat 传输一个 64B line。
//   * write miss 先完整 refill，再把 partial store merge 到 line buffer。
//   * dirty victim 的 8 个写回 beat 全部成功前保持原 valid/tag/dirty，
//     因而写回 fault 不会静默丢数据或复用 tag。
//   * refill 先写独立 line buffer，最后一个 beat 成功后才发布新 tag。
//     refill fault 不产生成功响应，也不发布新 tag。
//   * CORE_COUNT=1；probe/maintenance 是单客户端。source_id、
//     transaction_id、owner、sharer 只作为未来多核边界预留。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
// B3 legacy named instances intentionally omit B4-only optional ports.
/* verilator lint_off PINMISSING */

module lcvex_l2_wb #(
    parameter int LINE_BYTES       = 64,
    parameter int SETS             = 256,
    parameter int WAYS             = 2,
    parameter int CORE_COUNT       = 1,
    parameter int SOURCE_ID_W      = 4,
    parameter int TRANSACTION_ID_W = 8,
    // B3 compatibility keeps the legacy standalone L2 usable without an
    // attached L1.  B4 enables this port from lcvex_l1_coherence.
    parameter bit L1_PROBE_ENABLE  = 1'b0
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // 核心/上游 M1-B 请求
    input  logic                        u_req_valid,
    input  lcvex_pkg::mem_req_t         u_req,
    output logic                        u_req_ready,
    input  logic [SOURCE_ID_W-1:0]      u_source_id,
    input  logic [TRANSACTION_ID_W-1:0] u_transaction_id,
    output logic                        u_rsp_valid,
    output lcvex_pkg::mem_rsp_t         u_rsp,
    input  logic                        u_rsp_ready,
    output logic [SOURCE_ID_W-1:0]      u_rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0] u_rsp_transaction_id,

    // 下游 M1-B 8B 内存端口
    output logic                        d_req_valid,
    output lcvex_pkg::mem_req_t         d_req,
    input  logic                        d_req_ready,
    input  logic                        d_rsp_valid,
    input  lcvex_pkg::mem_rsp_t         d_rsp,
    output logic                        d_rsp_ready,

    // 单客户端 probe 端口。cmd: 0=lookup, 1=clean, 2=invalidate,
    // 3=clean+invalidate。地址只使用 line 所在的 PA。
    input  logic                        probe_req_valid,
    output logic                        probe_req_ready,
    input  logic [63:0]                 probe_req_addr,
    input  logic [1:0]                  probe_req_cmd,
    input  logic [SOURCE_ID_W-1:0]      probe_req_source_id,
    input  logic [TRANSACTION_ID_W-1:0] probe_req_transaction_id,
    output logic                        probe_rsp_valid,
    input  logic                        probe_rsp_ready,
    output logic                        probe_rsp_fault,
    output logic                        probe_rsp_hit,
    output logic                        probe_rsp_dirty,
    output logic [LINE_BYTES*8-1:0]     probe_rsp_data,
    output logic [63:0]                 probe_rsp_addr,
    output logic [SOURCE_ID_W-1:0]      probe_rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0] probe_rsp_transaction_id,
    output logic [CORE_COUNT-1:0]       probe_rsp_owner,
    output logic [CORE_COUNT-1:0]       probe_rsp_sharers,

    // B4：L2 -> D-L1 probe。响应 ready 只有在 L2 已经完成脏行下刷后
    // 才拉高；因此 clean/invalidate 的 metadata 提交点由下游成功定义。
    output logic                        l1_probe_req_valid,
    input  logic                        l1_probe_req_ready,
    output logic [63:0]                 l1_probe_req_addr,
    output logic [1:0]                  l1_probe_req_cmd,
    output logic [SOURCE_ID_W-1:0]      l1_probe_req_source_id,
    output logic [TRANSACTION_ID_W-1:0] l1_probe_req_transaction_id,
    input  logic                        l1_probe_rsp_valid,
    output logic                        l1_probe_rsp_ready,
    input  logic                        l1_probe_rsp_fault,
    input  logic                        l1_probe_rsp_line_valid,
    input  logic                        l1_probe_rsp_dirty,
    input  logic [LINE_BYTES*8-1:0]     l1_probe_rsp_data,
    input  logic [63:0]                 l1_probe_rsp_addr,
    input  logic [SOURCE_ID_W-1:0]      l1_probe_rsp_source_id,
    input  logic [TRANSACTION_ID_W-1:0] l1_probe_rsp_transaction_id,
    output logic                        l1_probe_rsp_abort,
    // During D-L1 local drain, normal L2 replacement must not wait for a
    // probe from the quiesced L1.  The L1 dirty lines are being sent down.
    input  logic                        l1_probe_block,

    // B4 checkpoint drain-to-Point-of-Coherence sideband.
    input  logic                        drain_to_poc_valid,
    output logic                        drain_to_poc_ready,
    input  logic [SOURCE_ID_W-1:0]      drain_source_id,
    input  logic [TRANSACTION_ID_W-1:0] drain_transaction_id,
    output logic                        drain_ack_valid,
    input  logic                        drain_ack_ready,
    output logic                        drain_ack_fault,
    output logic [SOURCE_ID_W-1:0]      drain_ack_source_id,
    output logic [TRANSACTION_ID_W-1:0] drain_ack_transaction_id,
    output logic                        drain_fault
);

  import lcvex_pkg::*;

  localparam int OFF_W       = $clog2(LINE_BYTES);
  localparam int IDX_W       = (SETS > 1) ? $clog2(SETS) : 1;
  localparam int WAY_W       = (WAYS > 1) ? $clog2(WAYS) : 1;
  localparam int TAG_W       = 64 - $clog2(LINE_BYTES) - $clog2(SETS);
  localparam int REFILL_BEATS = LINE_BYTES / 8;
  localparam int BEAT_W      = (REFILL_BEATS > 1) ? $clog2(REFILL_BEATS) : 1;

  localparam logic [1:0] PROBE_LOOKUP            = 2'd0;
  localparam logic [1:0] PROBE_CLEAN             = 2'd1;
  localparam logic [1:0] PROBE_INVALIDATE        = 2'd2;
  localparam logic [1:0] PROBE_CLEAN_INVALIDATE  = 2'd3;

  typedef enum logic [4:0] {
    ST_IDLE,
    ST_WB_REQ,
    ST_WB_WAIT,
    ST_REFILL_REQ,
    ST_REFILL_WAIT,
    ST_COMMIT,
    ST_BYPASS_REQ,
    ST_BYPASS_WAIT,
    ST_GLOBAL_SCAN,
    ST_CORE_RSP,
    ST_PROBE_RSP,
    ST_L1_PROBE_REQ,
    ST_L1_PROBE_WAIT,
    ST_L1_PROBE_COMMIT,
    ST_DRAIN_SCAN,
    ST_DRAIN_ACK,
    // Keep legacy state encodings (in particular ST_CORE_RSP=9) stable for
    // existing scoreboards while adding synchronous cache-data RAM states.
    ST_DATA_RD_REQ,
    ST_DATA_RD_WAIT,
    ST_DATA_WR
  } state_t;

  state_t state;

  // Metadata/data intentionally only reset on metadata.  This matches cache
  // RAM implementation practice and avoids stale data being observable while
  // valid=0.
  logic                         valid [0:SETS-1][0:WAYS-1];
  logic                         dirty [0:SETS-1][0:WAYS-1];
  logic [TAG_W-1:0]             tags  [0:SETS-1][0:WAYS-1];
  logic                         mru   [0:SETS-1]; // 2-way: 0/1 = most recent

  localparam int DATA_WORDS  = SETS * WAYS;
  localparam int DATA_ADDR_W = (DATA_WORDS > 1) ? $clog2(DATA_WORDS) : 1;
  localparam int LINE_BITS   = LINE_BYTES * 8;
  logic [DATA_ADDR_W-1:0]      data_rd_addr;
  logic                         data_rd_en;
  logic                         data_rd_valid;
  logic [LINE_BITS-1:0]        data_rd_data;
  logic [DATA_ADDR_W-1:0]      data_wr_addr;
  logic                         data_wr_en;
  logic [LINE_BYTES-1:0]        data_wr_byte_en;
  logic [LINE_BITS-1:0]         data_wr_data;
  logic [LINE_BITS-1:0]         cache_line_r;

  typedef enum logic [1:0] {
    DATA_RD_LOAD  = 2'd0,
    DATA_RD_WB    = 2'd1,
    DATA_RD_PROBE = 2'd2
  } data_rd_kind_t;
  data_rd_kind_t data_rd_kind_r;

  lcvex_cache_data_ram #(
      .LINE_BYTES(LINE_BYTES), .DEPTH_WORDS(DATA_WORDS)
  ) u_data_ram (
      .clk(clk), .rst_n(rst_n),
      .rd_en(data_rd_en), .rd_addr(data_rd_addr),
      .rd_valid(data_rd_valid), .rd_data(data_rd_data),
      .wr_en(data_wr_en), .wr_addr(data_wr_addr),
      .wr_byte_en(data_wr_byte_en), .wr_data(data_wr_data)
  );

  // Refill buffer is the only destination of an in-flight refill.
  logic [7:0] fill_buf [0:LINE_BYTES-1];

  mem_req_t u_req_r;
  logic [IDX_W-1:0] idx_r;
  logic [TAG_W-1:0] tag_r;
  logic [OFF_W-1:0] off_r;
  logic [WAY_W-1:0] way_r;
  logic [BEAT_W-1:0] beat_r;
  logic [SOURCE_ID_W-1:0]      core_source_r;
  logic [TRANSACTION_ID_W-1:0] core_transaction_r;

  logic client_probe_r;
  logic op_refill_r;
  logic op_write_miss_r;
  logic op_zva_r;
  logic op_line_maint_r;
  logic op_after_wb_invalidate_r;
  logic op_global_r;
  logic op_drain_r;

  // L1 probe context and a held raw line.  The raw line is captured while
  // l1_probe_rsp_ready is low and is the only source for an L1-originated
  // writeback, so the D-L1 response cannot be reused or overwritten.
  logic                        l1_probe_active_r;
  logic                        l1_probe_for_maint_r;
  logic [1:0]                  l1_probe_cmd_r;
  logic [63:0]                 l1_probe_addr_r;
  logic [SOURCE_ID_W-1:0]      l1_probe_source_r;
  logic [TRANSACTION_ID_W-1:0] l1_probe_transaction_r;
  logic                        l1_rsp_fault_r;
  logic                        l1_rsp_line_valid_r;
  logic                        l1_rsp_dirty_r;
  logic [LINE_BYTES*8-1:0]     l1_rsp_data_r;
  logic [63:0]                 l1_rsp_addr_r;
  logic                        wb_from_l1_r;
  logic                        l1_probe_abort_r;
  logic                        l1_probe_done_r;
  logic [LINE_BYTES*8-1:0]     l1_wb_buf;

  logic [SOURCE_ID_W-1:0]      drain_source_r;
  logic [TRANSACTION_ID_W-1:0] drain_transaction_r;
  logic                        drain_ack_fault_r;

  logic resp_fault_r;
  logic [63:0] resp_data_r;

  logic [SOURCE_ID_W-1:0]      probe_source_r;
  logic [TRANSACTION_ID_W-1:0] probe_transaction_r;
  logic [1:0]                  probe_cmd_r;
  logic probe_hit_r;
  logic probe_dirty_r;
  logic [LINE_BYTES*8-1:0] probe_data_r;
  logic [63:0] probe_addr_r;
  logic [CORE_COUNT-1:0] probe_owner_r;
  logic [CORE_COUNT-1:0] probe_sharers_r;

  logic [IDX_W-1:0] global_set_r;
  logic [WAY_W-1:0] global_way_r;
  logic global_invalidate_r;

  logic [IDX_W-1:0] u_idx;
  logic [TAG_W-1:0] u_tag;
  logic u_hit0, u_hit1, u_hit;
  logic [WAY_W-1:0] u_hit_way, u_repl_way;
  logic u_found_invalid;
  logic target_hit_r;
  logic [IDX_W-1:0] p_idx;
  logic [TAG_W-1:0] p_tag;
  logic p_hit0, p_hit1, p_hit;
  logic [WAY_W-1:0] p_hit_way;
  logic global_last;

  function automatic logic maint_line_op(input maint_op_t m);
    case (m)
      MAINT_DC_IVAC, MAINT_DC_ISW, MAINT_DC_CVAC, MAINT_DC_CVAU,
      MAINT_DC_CIVAC, MAINT_DC_CVAP, MAINT_IC_IVAU: maint_line_op = 1'b1;
      default: maint_line_op = 1'b0;
    endcase
  endfunction

  function automatic logic maint_invalidate(input maint_op_t m);
    case (m)
      MAINT_DC_IVAC, MAINT_DC_ISW, MAINT_DC_CIVAC, MAINT_IC_IVAU:
        maint_invalidate = 1'b1;
      default: maint_invalidate = 1'b0;
    endcase
  endfunction

  function automatic logic [63:0] compose_line_addr(
      input logic [TAG_W-1:0] t,
      input logic [IDX_W-1:0] s);
    logic [63:0] a;
    begin
      a = 64'd0;
      a[63:OFF_W+IDX_W] = t;
      a[OFF_W+IDX_W-1:OFF_W] = s;
      compose_line_addr = a;
    end
  endfunction

  function automatic logic [DATA_ADDR_W-1:0] cache_data_addr(
      input logic [IDX_W-1:0] s,
      input logic [WAY_W-1:0] w);
    integer flat;
    begin
      flat = s * WAYS + w;
      cache_data_addr = flat[DATA_ADDR_W-1:0];
    end
  endfunction

  function automatic logic [63:0] cache_chunk(
      input logic [LINE_BITS-1:0] line,
      input logic [BEAT_W-1:0] b);
    logic [63:0] v;
    begin
      v = 64'd0;
      for (int i = 0; i < 8; i++) v[i*8 +: 8] = line[b*64+i*8 +: 8];
      cache_chunk = v;
    end
  endfunction

  function automatic logic [63:0] line_read_req(
      input logic [LINE_BITS-1:0] line,
      input logic [OFF_W-1:0] o);
    logic [63:0] v;
    integer pos;
    begin
      v = 64'd0;
      for (int i = 0; i < 8; i++) begin
        pos = o + i;
        if (pos < LINE_BYTES) v[i*8 +: 8] = line[pos*8 +: 8];
      end
      line_read_req = v;
    end
  endfunction

  function automatic logic [63:0] fill_read_req(input logic [OFF_W-1:0] o);
    logic [63:0] v;
    integer pos;
    begin
      v = 64'd0;
      for (int i = 0; i < 8; i++) begin
        pos = o + i;
        if (pos < LINE_BYTES) v[i*8 +: 8] = fill_buf[pos];
      end
      fill_read_req = v;
    end
  endfunction

  function automatic logic [63:0] l1_chunk(
      input logic [LINE_BYTES*8-1:0] line,
      input logic [BEAT_W-1:0] b);
    logic [63:0] v;
    begin
      v = '0;
      for (int i = 0; i < 8; i++) v[i*8 +: 8] = line[b*64 + i*8 +: 8];
      l1_chunk = v;
    end
  endfunction

  function automatic logic [1:0] l1_cmd_for_maint(input maint_op_t m);
    begin
      case (m)
        MAINT_DC_CIVAC: l1_cmd_for_maint = 2'd3;
        MAINT_DC_IVAC:  l1_cmd_for_maint = 2'd2;
        MAINT_DC_ISW:   l1_cmd_for_maint = 2'd1;
        MAINT_IC_IVAU:  l1_cmd_for_maint = 2'd2;
        default:        l1_cmd_for_maint = 2'd1;
      endcase
    end
  endfunction

  always_comb begin
    u_idx = u_req.addr[OFF_W +: IDX_W];
    u_tag = u_req.addr[63:OFF_W+IDX_W];
    u_hit0 = 1'b0;
    u_hit1 = 1'b0;
    u_hit = 1'b0;
    u_hit_way = WAY_W'(0);
    for (int w = 0; w < WAYS; w++) begin
      if (valid[u_idx][w] && (tags[u_idx][w] == u_tag)) begin
        u_hit = 1'b1;
        u_hit_way = WAY_W'(w);
        if (w == 0) u_hit0 = 1'b1;
        if (w == 1) u_hit1 = 1'b1;
      end
    end

    u_repl_way = WAY_W'(0);
    u_found_invalid = 1'b0;
    for (int w = 0; w < WAYS; w++) begin
      if (!u_found_invalid && !valid[u_idx][w]) begin
        u_repl_way = WAY_W'(w);
        u_found_invalid = 1'b1;
      end
    end
    if (!u_found_invalid && (WAYS > 1))
      u_repl_way = mru[u_idx] ? WAY_W'(0) : WAY_W'(1);

    p_idx = probe_req_addr[OFF_W +: IDX_W];
    p_tag = probe_req_addr[63:OFF_W+IDX_W];
    p_hit0 = 1'b0;
    p_hit1 = 1'b0;
    p_hit = 1'b0;
    p_hit_way = WAY_W'(0);
    for (int w = 0; w < WAYS; w++) begin
      if (valid[p_idx][w] && (tags[p_idx][w] == p_tag)) begin
        p_hit = 1'b1;
        p_hit_way = WAY_W'(w);
        if (w == 0) p_hit0 = 1'b1;
        if (w == 1) p_hit1 = 1'b1;
      end
    end
    global_last = (global_set_r == SETS-1) && (global_way_r == WAYS-1);
  end

  always_comb begin
    u_req_ready = rst_n && (state == ST_IDLE);
    // 核心请求固定优先，避免两个客户端同时 valid 时互相等待。
    probe_req_ready = rst_n && (state == ST_IDLE) && !u_req_valid;
    drain_to_poc_ready = rst_n && (state == ST_IDLE) && !u_req_valid &&
                         !probe_req_valid;
    u_rsp_valid = rst_n && (state == ST_CORE_RSP);
    probe_rsp_valid = rst_n && (state == ST_PROBE_RSP);
    drain_ack_valid = rst_n && (state == ST_DRAIN_ACK);
    drain_ack_fault = drain_ack_fault_r;
    drain_ack_source_id = drain_source_r;
    drain_ack_transaction_id = drain_transaction_r;

    l1_probe_req_valid = rst_n && L1_PROBE_ENABLE &&
                         (state == ST_L1_PROBE_REQ);
    l1_probe_req_addr = l1_probe_addr_r;
    l1_probe_req_cmd = l1_probe_cmd_r;
    l1_probe_req_source_id = l1_probe_source_r;
    l1_probe_req_transaction_id = l1_probe_transaction_r;
    // A dirty response is deliberately not consumed until the eight POC
    // beats have completed.  On a POC fault, COMMIT+abort lets D-L1 release
    // the held lookup without changing its metadata, making a retry safe.
    l1_probe_rsp_ready = rst_n &&
                         ((state == ST_L1_PROBE_COMMIT) ||
                          ((state == ST_L1_PROBE_WAIT) &&
                           (!l1_probe_rsp_valid || l1_probe_rsp_fault ||
                            !l1_probe_rsp_line_valid ||
                            !l1_probe_rsp_dirty ||
                            l1_probe_rsp_source_id != l1_probe_source_r ||
                            l1_probe_rsp_transaction_id !=
                                l1_probe_transaction_r ||
                            ((l1_probe_rsp_addr & ~64'h3f) !=
                             (l1_probe_addr_r & ~64'h3f)))));
    l1_probe_rsp_abort = (state == ST_L1_PROBE_COMMIT) && l1_probe_abort_r;

    u_rsp = '0;
    u_rsp.rdata = resp_data_r;
    u_rsp.fault = resp_fault_r;
    u_rsp_source_id = core_source_r;
    u_rsp_transaction_id = core_transaction_r;

    probe_rsp_fault = resp_fault_r;
    probe_rsp_hit = probe_hit_r;
    probe_rsp_dirty = probe_dirty_r;
    probe_rsp_data = probe_data_r;
    probe_rsp_addr = probe_addr_r;
    probe_rsp_source_id = probe_source_r;
    probe_rsp_transaction_id = probe_transaction_r;
    probe_rsp_owner = probe_owner_r;
    probe_rsp_sharers = probe_sharers_r;

    // One packed line is one RAM word.  The blocking protocol makes a
    // single read/write port sufficient: read requests occupy
    // ST_DATA_RD_REQ/ST_DATA_RD_WAIT, and line writes are sampled only in a
    // commit/write state.
    data_rd_en = rst_n && (state == ST_DATA_RD_REQ);
    data_rd_addr = cache_data_addr(idx_r, way_r);
    data_wr_en = 1'b0;
    data_wr_addr = cache_data_addr(idx_r, way_r);
    data_wr_byte_en = '0;
    data_wr_data = '0;
    if (state == ST_DATA_WR) begin
      for (int i = 0; i < 8; i++) begin
        if (u_req_r.strb[i] && (off_r + i < LINE_BYTES)) begin
          data_wr_byte_en[off_r+i] = 1'b1;
          data_wr_data[(off_r+i)*8 +: 8] = u_req_r.wdata[i*8 +: 8];
        end
      end
      data_wr_en = rst_n;
    end else if (state == ST_COMMIT && op_refill_r) begin
      for (int i = 0; i < LINE_BYTES; i++) begin
        data_wr_byte_en[i] = 1'b1;
        data_wr_data[i*8 +: 8] = fill_buf[i];
        if (op_write_miss_r && (i >= off_r) &&
            (i < off_r + 8) && u_req_r.strb[i-off_r])
          data_wr_data[i*8 +: 8] = u_req_r.wdata[(i-off_r)*8 +: 8];
      end
      data_wr_en = rst_n;
    end else if (state == ST_COMMIT && op_zva_r) begin
      data_wr_byte_en = '1;
      data_wr_data = '0;
      data_wr_en = rst_n;
    end else if (state == ST_L1_PROBE_COMMIT &&
                 !l1_probe_abort_r && l1_probe_for_maint_r &&
                 l1_rsp_dirty_r && target_hit_r) begin
      data_wr_byte_en = '1;
      data_wr_data = l1_rsp_data_r;
      data_wr_en = rst_n;
    end

    d_req_valid = rst_n && ((state == ST_WB_REQ) ||
                            (state == ST_REFILL_REQ) ||
                            (state == ST_BYPASS_REQ));
    d_req = '0;
    if (state == ST_WB_REQ) begin
      d_req.addr = wb_from_l1_r ?
                   ((l1_rsp_addr_r & ~64'h3f) + beat_r * 64'd8) :
                   (compose_line_addr(tags[idx_r][way_r], idx_r) +
                    beat_r * 64'd8);
      d_req.we = 1'b1;
      d_req.strb = 8'hff;
      d_req.wdata = wb_from_l1_r ? l1_chunk(l1_wb_buf, beat_r) :
                                  cache_chunk(cache_line_r, beat_r);
      d_req.maint = MAINT_NONE;
      d_req.bypass = 1'b0;
    end else if (state == ST_REFILL_REQ) begin
      d_req.addr = compose_line_addr(tag_r, idx_r) + beat_r * 64'd8;
      d_req.we = 1'b0;
      d_req.strb = 8'h00;
      d_req.wdata = 64'd0;
      d_req.maint = MAINT_NONE;
      d_req.bypass = 1'b0;
    end else if (state == ST_BYPASS_REQ) begin
      d_req = u_req_r;
    end
    d_rsp_ready = rst_n && ((state == ST_WB_WAIT) ||
                            (state == ST_REFILL_WAIT) ||
                            (state == ST_BYPASS_WAIT));
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      u_req_r <= '0;
      idx_r <= '0;
      tag_r <= '0;
      off_r <= '0;
      way_r <= '0;
      beat_r <= '0;
      core_source_r <= '0;
      core_transaction_r <= '0;
      client_probe_r <= 1'b0;
      op_refill_r <= 1'b0;
      op_write_miss_r <= 1'b0;
      op_zva_r <= 1'b0;
      op_line_maint_r <= 1'b0;
      op_after_wb_invalidate_r <= 1'b0;
      op_global_r <= 1'b0;
      op_drain_r <= 1'b0;
      l1_probe_active_r <= 1'b0;
      l1_probe_for_maint_r <= 1'b0;
      l1_probe_cmd_r <= 2'd0;
      l1_probe_addr_r <= '0;
      l1_probe_source_r <= '0;
      l1_probe_transaction_r <= '0;
      l1_rsp_fault_r <= 1'b0;
      l1_rsp_line_valid_r <= 1'b0;
      l1_rsp_dirty_r <= 1'b0;
      l1_rsp_data_r <= '0;
      l1_rsp_addr_r <= '0;
      wb_from_l1_r <= 1'b0;
      l1_probe_abort_r <= 1'b0;
      l1_probe_done_r <= 1'b0;
      l1_wb_buf <= '0;
      data_rd_kind_r <= DATA_RD_LOAD;
      cache_line_r <= '0;
      drain_source_r <= '0;
      drain_transaction_r <= '0;
      drain_ack_fault_r <= 1'b0;
      drain_fault <= 1'b0;
      resp_fault_r <= 1'b0;
      resp_data_r <= '0;
      probe_source_r <= '0;
      probe_transaction_r <= '0;
      probe_cmd_r <= PROBE_LOOKUP;
      probe_hit_r <= 1'b0;
      probe_dirty_r <= 1'b0;
      probe_data_r <= '0;
      probe_addr_r <= '0;
      probe_owner_r <= '0;
      probe_sharers_r <= '0;
      global_set_r <= '0;
      global_way_r <= '0;
      global_invalidate_r <= 1'b0;
      target_hit_r <= 1'b0;
      for (int s = 0; s < SETS; s++) begin
        mru[s] <= 1'b0;
        for (int w = 0; w < WAYS; w++) begin
          valid[s][w] <= 1'b0;
          dirty[s][w] <= 1'b0;
          tags[s][w] <= '0;
        end
      end
      for (int i = 0; i < LINE_BYTES; i++) fill_buf[i] <= 8'd0;
    end else begin
      case (state)
        ST_IDLE: begin
          resp_fault_r <= 1'b0;
          resp_data_r <= 64'd0;
          // A drain fault is reported for the failed epoch.  Once the
          // controller has returned to idle it is cleared on the next cycle;
          // a later checkpoint can therefore start a fresh epoch.
          if (!drain_to_poc_valid) drain_fault <= 1'b0;
          if (u_req_valid && u_req_ready) begin
            u_req_r <= u_req;
            idx_r <= u_idx;
            tag_r <= u_tag;
            off_r <= u_req.addr[OFF_W-1:0];
            target_hit_r <= u_hit;
            core_source_r <= u_source_id;
            core_transaction_r <= u_transaction_id;
            client_probe_r <= 1'b0;
            op_refill_r <= 1'b0;
            op_write_miss_r <= 1'b0;
            op_zva_r <= 1'b0;
            op_line_maint_r <= 1'b0;
            op_after_wb_invalidate_r <= 1'b0;
            op_global_r <= 1'b0;
            op_drain_r <= 1'b0;
            wb_from_l1_r <= 1'b0;
            l1_probe_active_r <= 1'b0;
            l1_probe_for_maint_r <= 1'b0;
            l1_probe_abort_r <= 1'b0;

            if (u_req.bypass) begin
              state <= ST_BYPASS_REQ;
            end else if (u_req.maint == MAINT_IC_IALLU) begin
              // 全 I-cache invalidate 在 L2 仍必须先排空 dirty line。
              global_set_r <= '0;
              global_way_r <= '0;
              global_invalidate_r <= 1'b1;
              op_global_r <= 1'b1;
              state <= ST_GLOBAL_SCAN;
            end else if (u_req.maint == MAINT_TLBI) begin
              // TLBI 不占 L2 内存端口，在此作为已完成的顺序维护请求。
              state <= ST_CORE_RSP;
            end else if (u_req.maint == MAINT_DC_ZVA) begin
              way_r <= u_hit ? u_hit_way : u_repl_way;
              op_zva_r <= 1'b1;
              op_line_maint_r <= 1'b1;
              if (!u_hit && valid[u_idx][u_repl_way]) begin
                beat_r <= '0;
                if (L1_PROBE_ENABLE && !l1_probe_block) begin
                  l1_probe_active_r <= 1'b1;
                  l1_probe_for_maint_r <= 1'b0;
                  l1_probe_cmd_r <= 2'd0;
                  l1_probe_addr_r <= compose_line_addr(
                      tags[u_idx][u_repl_way], u_idx);
                  l1_probe_source_r <= u_source_id;
                  l1_probe_transaction_r <= u_transaction_id;
                  state <= ST_L1_PROBE_REQ;
                end else if (dirty[u_idx][u_repl_way]) begin
                  data_rd_kind_r <= DATA_RD_WB;
                  state <= ST_DATA_RD_REQ;
                end
                else state <= ST_COMMIT;
              end else begin
                state <= ST_COMMIT;
              end
            end else if (maint_line_op(u_req.maint)) begin
              way_r <= u_hit ? u_hit_way : u_repl_way;
              op_line_maint_r <= 1'b1;
              op_after_wb_invalidate_r <= maint_invalidate(u_req.maint);
              if (L1_PROBE_ENABLE && !l1_probe_block) begin
                // Probe D-L1 even when L2 misses: inclusion is established
                // by the L1 response, not by the stale L2 tag lookup.
                l1_probe_active_r <= 1'b1;
                l1_probe_for_maint_r <= 1'b1;
                l1_probe_cmd_r <= l1_cmd_for_maint(u_req.maint);
                l1_probe_addr_r <= {u_req.addr[63:OFF_W], {OFF_W{1'b0}}};
                l1_probe_source_r <= u_source_id;
                l1_probe_transaction_r <= u_transaction_id;
                state <= ST_L1_PROBE_REQ;
              end else if (!u_hit) begin
                // clean/invalidate miss is an idempotent no-op.
                state <= ST_CORE_RSP;
              end else begin
                if (dirty[u_idx][u_hit_way]) begin
                  beat_r <= '0;
                  data_rd_kind_r <= DATA_RD_WB;
                  state <= ST_DATA_RD_REQ;
                end
                else state <= ST_COMMIT;
              end
            end else if (u_req.maint != MAINT_NONE) begin
              // 未在本模块承诺的 maintenance 不得伪装成成功的副作用。
              resp_fault_r <= 1'b1;
              state <= ST_CORE_RSP;
            end else if (u_req.we) begin
              if (u_hit) begin
                // write hit 只更新 cache line，成为 dirty；不产生下游写。
                way_r <= u_hit_way;
                dirty[u_idx][u_hit_way] <= 1'b1;
                mru[u_idx] <= u_hit_way;
                state <= ST_DATA_WR;
              end else begin
                way_r <= u_repl_way;
                op_refill_r <= 1'b1;
                op_write_miss_r <= 1'b1;
                if (valid[u_idx][u_repl_way]) begin
                  beat_r <= '0;
                  if (L1_PROBE_ENABLE && !l1_probe_block) begin
                    l1_probe_active_r <= 1'b1;
                    l1_probe_for_maint_r <= 1'b0;
                    l1_probe_cmd_r <= 2'd0;
                    l1_probe_addr_r <= compose_line_addr(
                        tags[u_idx][u_repl_way], u_idx);
                    l1_probe_source_r <= u_source_id;
                    l1_probe_transaction_r <= u_transaction_id;
                    state <= ST_L1_PROBE_REQ;
                  end else if (dirty[u_idx][u_repl_way]) begin
                    data_rd_kind_r <= DATA_RD_WB;
                    state <= ST_DATA_RD_REQ;
                  end
                  else state <= ST_REFILL_REQ;
                end else begin
                  beat_r <= '0;
                  state <= ST_REFILL_REQ;
                end
              end
            end else if (u_hit) begin
              way_r <= u_hit_way;
              data_rd_kind_r <= DATA_RD_LOAD;
              state <= ST_DATA_RD_REQ;
            end else begin
              way_r <= u_repl_way;
              op_refill_r <= 1'b1;
              op_write_miss_r <= 1'b0;
              beat_r <= '0;
              if (valid[u_idx][u_repl_way]) begin
                beat_r <= '0;
                if (L1_PROBE_ENABLE && !l1_probe_block) begin
                  l1_probe_active_r <= 1'b1;
                  l1_probe_for_maint_r <= 1'b0;
                  l1_probe_cmd_r <= 2'd0;
                  l1_probe_addr_r <= compose_line_addr(
                      tags[u_idx][u_repl_way], u_idx);
                  l1_probe_source_r <= u_source_id;
                  l1_probe_transaction_r <= u_transaction_id;
                  state <= ST_L1_PROBE_REQ;
                end else if (dirty[u_idx][u_repl_way]) begin
                  data_rd_kind_r <= DATA_RD_WB;
                  state <= ST_DATA_RD_REQ;
                end
                else state <= ST_REFILL_REQ;
              end else state <= ST_REFILL_REQ;
            end
          end else if (probe_req_valid && probe_req_ready) begin
            idx_r <= p_idx;
            tag_r <= p_tag;
            off_r <= '0;
            way_r <= p_hit_way;
            client_probe_r <= 1'b1;
            probe_source_r <= probe_req_source_id;
            probe_transaction_r <= probe_req_transaction_id;
            probe_cmd_r <= probe_req_cmd;
            probe_addr_r <= {probe_req_addr[63:OFF_W], {OFF_W{1'b0}}};
            probe_hit_r <= p_hit;
            probe_dirty_r <= p_hit && dirty[p_idx][p_hit_way];
            probe_data_r <= '0;
            probe_owner_r <= (p_hit && dirty[p_idx][p_hit_way]) ?
                             {{(CORE_COUNT-1){1'b0}}, 1'b1} : '0;
            probe_sharers_r <= p_hit ?
                               {{(CORE_COUNT-1){1'b0}}, 1'b1} : '0;
            op_refill_r <= 1'b0;
            op_write_miss_r <= 1'b0;
            op_zva_r <= 1'b0;
            op_line_maint_r <= 1'b0;
            op_after_wb_invalidate_r <= 1'b0;
            op_global_r <= 1'b0;
            op_drain_r <= 1'b0;
            wb_from_l1_r <= 1'b0;
            if (!p_hit) begin
              state <= ST_PROBE_RSP;
            end else begin
              data_rd_kind_r <= DATA_RD_PROBE;
              state <= ST_DATA_RD_REQ;
            end
            if (p_hit && probe_req_cmd != PROBE_LOOKUP) begin
              op_line_maint_r <= 1'b1;
              if (probe_req_cmd == PROBE_CLEAN)
                op_after_wb_invalidate_r <= 1'b0;
              else
                op_after_wb_invalidate_r <=
                    (probe_req_cmd == PROBE_INVALIDATE) ||
                    (probe_req_cmd == PROBE_CLEAN_INVALIDATE);
              if (dirty[p_idx][p_hit_way]) begin
                beat_r <= '0;
                // The probe read above supplies the complete victim line;
                // writeback starts from ST_DATA_RD_WAIT after that read.
              end
              else begin
                // A clean maintenance operation commits after the line read,
                // so the probe payload is valid even when it is held.
              end
            end
          end else if (drain_to_poc_valid && drain_to_poc_ready) begin
            drain_source_r <= drain_source_id;
            drain_transaction_r <= drain_transaction_id;
            drain_ack_fault_r <= 1'b0;
            drain_fault <= 1'b0;
            global_set_r <= '0;
            global_way_r <= '0;
            op_drain_r <= 1'b1;
            op_global_r <= 1'b0;
            client_probe_r <= 1'b0;
            state <= ST_DRAIN_SCAN;
          end
        end

        ST_DATA_RD_REQ: begin
          // lcvex_cache_data_ram samples the address on this edge and keeps
          // rd_valid/data asserted for the following cycle.
          state <= ST_DATA_RD_WAIT;
        end

        ST_DATA_RD_WAIT: begin
          if (data_rd_valid) begin
            cache_line_r <= data_rd_data;
            case (data_rd_kind_r)
              DATA_RD_LOAD: begin
                resp_data_r <= line_read_req(data_rd_data, off_r);
                mru[idx_r] <= way_r;
                state <= ST_CORE_RSP;
              end
              DATA_RD_PROBE: begin
                probe_data_r <= data_rd_data;
                if (client_probe_r && probe_cmd_r != PROBE_LOOKUP) begin
                  if (probe_dirty_r) state <= ST_WB_REQ;
                  else state <= ST_COMMIT;
                end else state <= ST_PROBE_RSP;
              end
              default: begin // DATA_RD_WB
                state <= ST_WB_REQ;
              end
            endcase
          end
        end

        ST_DATA_WR: begin
          // A masked line write is sampled on this edge.  Metadata was
          // updated at request acceptance, as in the original hit path.
          state <= ST_CORE_RSP;
        end

        ST_WB_REQ: begin
          if (d_req_valid && d_req_ready) state <= ST_WB_WAIT;
        end

        ST_WB_WAIT: begin
          if (d_rsp_valid && d_rsp_ready) begin
            if (d_rsp.fault) begin
              // 不修改 valid/tag/dirty：dirty victim 可被稍后重试。
              resp_fault_r <= 1'b1;
              if (wb_from_l1_r) begin
                // Consume the held D-L1 response with abort=1.  D-L1 keeps
                // its old valid/tag/dirty metadata and a later core retry
                // can issue a fresh probe.
                l1_probe_abort_r <= 1'b1;
                state <= ST_L1_PROBE_COMMIT;
              end else if (op_drain_r) begin
                drain_fault <= 1'b1;
                // A failed drain has no success acknowledgement.  The
                // original line remains valid/dirty and can be retried.
                state <= ST_IDLE;
              end else if (client_probe_r) state <= ST_PROBE_RSP;
              else state <= ST_CORE_RSP;
            end else if (beat_r == REFILL_BEATS-1) begin
              // 只有 8/8 beat 成功才清 dirty，随后才允许 commit/reuse。
              if (wb_from_l1_r) begin
                wb_from_l1_r <= 1'b0;
                l1_probe_abort_r <= 1'b0;
                state <= ST_L1_PROBE_COMMIT;
                beat_r <= '0;
              end else if (op_drain_r) begin
                dirty[idx_r][way_r] <= 1'b0;
                if (global_last) begin
                  op_drain_r <= 1'b0;
                  state <= ST_DRAIN_ACK;
                end else if (global_way_r == WAYS-1) begin
                  global_way_r <= '0;
                  global_set_r <= global_set_r + 1'b1;
                  state <= ST_DRAIN_SCAN;
                end else begin
                  global_way_r <= global_way_r + 1'b1;
                  state <= ST_DRAIN_SCAN;
                end
              end else begin
                dirty[idx_r][way_r] <= 1'b0;
                if (op_global_r) begin
                if (global_invalidate_r) valid[idx_r][way_r] <= 1'b0;
                if (global_last) state <= ST_CORE_RSP;
                else if (global_way_r == WAYS-1) begin
                  global_way_r <= '0;
                  global_set_r <= global_set_r + 1'b1;
                  state <= ST_GLOBAL_SCAN;
                end else begin
                  global_way_r <= global_way_r + 1'b1;
                  state <= ST_GLOBAL_SCAN;
                end
                end else begin
                  state <= op_refill_r ? ST_REFILL_REQ : ST_COMMIT;
                  beat_r <= '0;
                  if (client_probe_r) probe_dirty_r <= 1'b0;
                end
              end
            end else begin
              beat_r <= beat_r + 1'b1;
              state <= ST_WB_REQ;
            end
          end
        end

        ST_L1_PROBE_REQ: begin
          if (l1_probe_req_valid && l1_probe_req_ready)
            state <= ST_L1_PROBE_WAIT;
        end

        ST_L1_PROBE_WAIT: begin
          if (l1_probe_rsp_valid) begin
            l1_rsp_fault_r <= l1_probe_rsp_fault ||
                              (l1_probe_rsp_source_id != l1_probe_source_r) ||
                              (l1_probe_rsp_transaction_id !=
                               l1_probe_transaction_r) ||
                              ((l1_probe_rsp_addr & ~64'h3f) !=
                               (l1_probe_addr_r & ~64'h3f));
            l1_rsp_line_valid_r <= l1_probe_rsp_line_valid;
            l1_rsp_dirty_r <= l1_probe_rsp_dirty;
            l1_rsp_data_r <= l1_probe_rsp_data;
            l1_rsp_addr_r <= l1_probe_rsp_addr;

            if (l1_probe_rsp_valid && !l1_probe_rsp_ready &&
                !l1_probe_rsp_fault && l1_probe_rsp_line_valid &&
                l1_probe_rsp_dirty &&
                (l1_probe_rsp_source_id == l1_probe_source_r) &&
                (l1_probe_rsp_transaction_id == l1_probe_transaction_r) &&
                ((l1_probe_rsp_addr & ~64'h3f) ==
                 (l1_probe_addr_r & ~64'h3f))) begin
              // Keep the D-L1 response unconsumed while the raw line is
              // drained to POC.  D-L1 therefore cannot clear dirty early.
              l1_wb_buf <= l1_probe_rsp_data;
              wb_from_l1_r <= 1'b1;
              beat_r <= '0;
              state <= ST_WB_REQ;
            end else if (l1_probe_rsp_valid && l1_probe_rsp_ready) begin
              l1_probe_active_r <= 1'b0;
              if (l1_probe_rsp_fault ||
                  (l1_probe_rsp_source_id != l1_probe_source_r) ||
                  (l1_probe_rsp_transaction_id != l1_probe_transaction_r) ||
                  ((l1_probe_rsp_addr & ~64'h3f) !=
                   (l1_probe_addr_r & ~64'h3f))) begin
                resp_fault_r <= 1'b1;
                state <= ST_CORE_RSP;
              end else if (l1_probe_for_maint_r) begin
                // The D-L1 line was clean (or absent); now complete the
                // corresponding L2 maintenance operation.
                if (!target_hit_r) state <= ST_CORE_RSP;
                else if (dirty[idx_r][way_r]) begin
                  beat_r <= '0;
                  data_rd_kind_r <= DATA_RD_WB;
                  state <= ST_DATA_RD_REQ;
                end else state <= ST_COMMIT;
              end else if (valid[idx_r][way_r] && dirty[idx_r][way_r]) begin
                // D-L1 did not own the victim; fall back to the L2 copy.
                wb_from_l1_r <= 1'b0;
                beat_r <= '0;
                data_rd_kind_r <= DATA_RD_WB;
                state <= ST_DATA_RD_REQ;
              end else begin
                state <= ST_REFILL_REQ;
              end
            end
          end
        end

        ST_L1_PROBE_COMMIT: begin
          if (l1_probe_rsp_valid && l1_probe_rsp_ready) begin
            l1_probe_active_r <= 1'b0;
            if (l1_probe_abort_r) begin
              // The probe was intentionally aborted after a POC fault;
              // D-L1 preserves its original metadata.
              resp_fault_r <= 1'b1;
              state <= ST_CORE_RSP;
            end else if (l1_probe_for_maint_r) begin
              if (l1_rsp_dirty_r && target_hit_r) begin
                // The line just written to POC is also the newest L2 copy.
                if (op_after_wb_invalidate_r) begin
                  valid[idx_r][way_r] <= 1'b0;
                  dirty[idx_r][way_r] <= 1'b0;
                end else begin
                  valid[idx_r][way_r] <= 1'b1;
                  dirty[idx_r][way_r] <= 1'b0;
                end
              end
              // A clean L1 response has no data to merge; the normal L2
              // maintenance path was selected when it was consumed.
              state <= ST_CORE_RSP;
            end else begin
              // Victim lookup: the L1 raw line has already reached POC.
              // The old L2 victim is therefore satisfied and can be reused.
              state <= ST_REFILL_REQ;
            end
          end
        end

        ST_REFILL_REQ: begin
          if (d_req_valid && d_req_ready) state <= ST_REFILL_WAIT;
        end

        ST_REFILL_WAIT: begin
          if (d_rsp_valid && d_rsp_ready) begin
            if (d_rsp.fault) begin
              // fill_buf 中的部分数据不可见；新 tag/valid/成功响应均不发布。
              resp_fault_r <= 1'b1;
              state <= ST_CORE_RSP;
            end else begin
              for (int i = 0; i < 8; i++)
                fill_buf[beat_r*8+i] <= d_rsp.rdata[i*8 +: 8];
              if (beat_r == REFILL_BEATS-1) state <= ST_COMMIT;
              else begin
                beat_r <= beat_r + 1'b1;
                state <= ST_REFILL_REQ;
              end
            end
          end
        end

        ST_COMMIT: begin
          if (op_global_r) begin
            // global scan 的非 dirty 行在 ST_GLOBAL_SCAN 已处理；保留分支
            // 仅用于保持状态机完备，不会覆盖新 tag。
            state <= ST_CORE_RSP;
          end else if (op_refill_r) begin
            valid[idx_r][way_r] <= 1'b1;
            tags[idx_r][way_r] <= tag_r;
            dirty[idx_r][way_r] <= op_write_miss_r;
            mru[idx_r] <= way_r;
            resp_data_r <= op_write_miss_r ? 64'd0 : fill_read_req(off_r);
            state <= ST_CORE_RSP;
          end else if (op_zva_r) begin
            valid[idx_r][way_r] <= 1'b1;
            tags[idx_r][way_r] <= tag_r;
            dirty[idx_r][way_r] <= 1'b1;
            mru[idx_r] <= way_r;
            state <= ST_CORE_RSP;
          end else if (op_line_maint_r) begin
            if (op_after_wb_invalidate_r) valid[idx_r][way_r] <= 1'b0;
            dirty[idx_r][way_r] <= 1'b0;
            if (client_probe_r) begin
              probe_dirty_r <= 1'b0;
              probe_owner_r <= '0;
              if (op_after_wb_invalidate_r) probe_sharers_r <= '0;
              state <= ST_PROBE_RSP;
            end else begin
              state <= ST_CORE_RSP;
            end
          end else begin
            state <= client_probe_r ? ST_PROBE_RSP : ST_CORE_RSP;
          end
        end

        ST_BYPASS_REQ: begin
          if (d_req_valid && d_req_ready) state <= ST_BYPASS_WAIT;
        end

        ST_BYPASS_WAIT: begin
          if (d_rsp_valid && d_rsp_ready) begin
            resp_data_r <= d_rsp.rdata;
            resp_fault_r <= d_rsp.fault;
            state <= ST_CORE_RSP;
          end
        end

        ST_GLOBAL_SCAN: begin
          idx_r <= global_set_r;
          way_r <= global_way_r;
          if (!valid[global_set_r][global_way_r]) begin
            if (global_last) state <= ST_CORE_RSP;
            else if (global_way_r == WAYS-1) begin
              global_way_r <= '0;
              global_set_r <= global_set_r + 1'b1;
            end else global_way_r <= global_way_r + 1'b1;
          end else if (dirty[global_set_r][global_way_r]) begin
            client_probe_r <= 1'b0;
            op_refill_r <= 1'b0;
            op_global_r <= 1'b1;
            op_line_maint_r <= 1'b1;
            beat_r <= '0;
            data_rd_kind_r <= DATA_RD_WB;
            state <= ST_DATA_RD_REQ;
          end else begin
            if (global_invalidate_r) valid[global_set_r][global_way_r] <= 1'b0;
            if (global_last) state <= ST_CORE_RSP;
            else if (global_way_r == WAYS-1) begin
              global_way_r <= '0;
              global_set_r <= global_set_r + 1'b1;
            end else global_way_r <= global_way_r + 1'b1;
          end
        end

        ST_DRAIN_SCAN: begin
          idx_r <= global_set_r;
          way_r <= global_way_r;
          if (!valid[global_set_r][global_way_r] ||
              !dirty[global_set_r][global_way_r]) begin
            if (global_last) begin
              op_drain_r <= 1'b0;
              state <= ST_DRAIN_ACK;
            end else if (global_way_r == WAYS-1) begin
              global_way_r <= '0;
              global_set_r <= global_set_r + 1'b1;
            end else begin
              global_way_r <= global_way_r + 1'b1;
            end
          end else begin
            beat_r <= '0;
            wb_from_l1_r <= 1'b0;
            data_rd_kind_r <= DATA_RD_WB;
            state <= ST_DATA_RD_REQ;
          end
        end

        ST_CORE_RSP: begin
          if (u_rsp_valid && u_rsp_ready) state <= ST_IDLE;
        end

        ST_PROBE_RSP: begin
          if (probe_rsp_valid && probe_rsp_ready) state <= ST_IDLE;
        end

        ST_DRAIN_ACK: begin
          if (drain_ack_valid && drain_ack_ready) state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // B3 invariants and handshake safety.  Data/tag are intentionally not
  // required to be reset; valid=0 is the architectural visibility boundary.
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk) disable iff (!rst_n)
      u_req_ready |-> !u_rsp_valid && !probe_rsp_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      probe_req_ready |-> !u_rsp_valid && !probe_rsp_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      d_req_valid && !d_req_ready |=>
          d_req_valid && $stable(d_req.addr) && $stable(d_req.we) &&
          $stable(d_req.strb) && $stable(d_req.wdata));
  assert property (@(posedge clk) disable iff (!rst_n)
      d_rsp_valid && d_rsp_ready |->
          (state inside {ST_WB_WAIT, ST_REFILL_WAIT, ST_BYPASS_WAIT}));
  assert property (@(posedge clk) disable iff (!rst_n)
      u_rsp_valid && !u_rsp_ready |=> (u_rsp_valid || u_rsp_ready));
  assert property (@(posedge clk) disable iff (!rst_n)
      probe_rsp_valid && !probe_rsp_ready |=>
          (probe_rsp_valid || probe_rsp_ready));
  assert property (@(posedge clk) disable iff (!rst_n)
      l1_probe_req_valid && !l1_probe_req_ready |=>
          l1_probe_req_valid && $stable(l1_probe_req_addr) &&
          $stable(l1_probe_req_cmd) &&
          $stable(l1_probe_req_source_id) &&
          $stable(l1_probe_req_transaction_id));
  assert property (@(posedge clk) disable iff (!rst_n)
      l1_probe_rsp_valid && !l1_probe_rsp_ready |=>
          (l1_probe_rsp_valid || l1_probe_rsp_ready));
  assert property (@(posedge clk) disable iff (!rst_n)
      drain_ack_valid && !drain_ack_ready |=> drain_ack_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      !rst_n |-> !u_rsp_valid && !probe_rsp_valid);

  generate
    for (genvar gs = 0; gs < SETS; gs++) begin : g_dirty_set
      for (genvar gw = 0; gw < WAYS; gw++) begin : g_dirty_way
        assert property (@(posedge clk) disable iff (!rst_n)
            dirty[gs][gw] |-> valid[gs][gw]);
      end
    end
  endgenerate

  /* verilator lint_on SYNCASYNCNET */
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on WIDTHEXPAND */

endmodule
