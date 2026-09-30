// lcvex_l1_d_wb.sv
// B4-L1-Coherence：模块级单核 D-L1 write-back/write-allocate candidate。
//
// 这是独立的 cache endpoint，不接 core/pkg/filelist 或 SoC。上游和下游
// 使用现有 M1-B 8B 协议；一条 cache line 固定 64B。L2 的出向 probe 在
// response ready 前不会改变本模块的 valid/tag/dirty/data，L2 负责在 dirty
// response 被消费前完成下刷。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_l1_d_wb #(
    parameter int LINE_BYTES       = 64,
    parameter int SETS             = 64,
    parameter int SOURCE_ID_W      = 4,
    parameter int TRANSACTION_ID_W = 8
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // core/PTW 共享的 D-L1 请求端点
    input  logic                        u_req_valid,
    input  lcvex_pkg::mem_req_t         u_req,
    output logic                        u_req_ready,
    output logic                        u_rsp_valid,
    output lcvex_pkg::mem_rsp_t         u_rsp,
    input  logic                        u_rsp_ready,

    // L2 端点：单未完成 8B beat
    output logic                        d_req_valid,
    output lcvex_pkg::mem_req_t         d_req,
    input  logic                        d_req_ready,
    input  logic                        d_rsp_valid,
    input  lcvex_pkg::mem_rsp_t         d_rsp,
    output logic                        d_rsp_ready,

    // L2 -> D-L1：lookup/clean/invalidate/clean+invalidate（0/1/2/3）
    input  logic                        l1_probe_req_valid,
    output logic                        l1_probe_req_ready,
    input  logic [63:0]                 l1_probe_req_addr,
    input  logic [1:0]                  l1_probe_req_cmd,
    input  logic [SOURCE_ID_W-1:0]      l1_probe_req_source_id,
    input  logic [TRANSACTION_ID_W-1:0] l1_probe_req_transaction_id,
    output logic                        l1_probe_rsp_valid,
    input  logic                        l1_probe_rsp_ready,
    output logic                        l1_probe_rsp_fault,
    output logic                        l1_probe_rsp_line_valid,
    output logic                        l1_probe_rsp_dirty,
    output logic [LINE_BYTES*8-1:0]     l1_probe_rsp_data,
    output logic [63:0]                 l1_probe_rsp_addr,
    output logic [SOURCE_ID_W-1:0]      l1_probe_rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0] l1_probe_rsp_transaction_id,
    input  logic                        l1_probe_rsp_abort,

    // checkpoint：quiesce 阻止新的 core/PTW 请求，但允许已到达的 probe
    // 完成；本地 dirty line 全部成功写入 L2 后才报告 done。
    input  logic                        checkpoint_quiesce,
    output logic                        l1_drain_done,
    output logic                        l1_drain_fault
);

  import lcvex_pkg::*;

  localparam int OFF_W   = $clog2(LINE_BYTES);
  localparam int TAG_W   = 64 - $clog2(LINE_BYTES) - $clog2(SETS);
  localparam int BEATS   = LINE_BYTES / 8;
  localparam int BEAT_W  = (BEATS > 1) ? $clog2(BEATS) : 1;
  localparam int SET_W   = (SETS > 1) ? $clog2(SETS) : 1;

  localparam logic [1:0] PROBE_LOOKUP           = 2'd0;
  localparam logic [1:0] PROBE_CLEAN            = 2'd1;
  localparam logic [1:0] PROBE_INVALIDATE       = 2'd2;
  localparam logic [1:0] PROBE_CLEAN_INVALIDATE = 2'd3;

  typedef enum logic [4:0] {
    ST_IDLE,
    ST_WB_REQ,
    ST_WB_WAIT,
    ST_REFILL_REQ,
    ST_REFILL_WAIT,
    ST_COMMIT,
    ST_BYPASS_REQ,
    ST_BYPASS_WAIT,
    ST_RSP,
    ST_PROBE_RSP,
    ST_DRAIN_SCAN,
    ST_DRAIN_DONE,
    ST_DRAIN_FAILED,
    // Cache data RAM has a synchronous read contract.  Keep these states at
    // the end of the enum so the legacy ST_RSP encoding used by existing
    // standalone scoreboards remains unchanged.
    ST_DATA_RD_REQ,
    ST_DATA_RD_WAIT,
    ST_DATA_WR,
    ST_CROSS_LOOKUP
  } state_t;

  state_t state;

  logic                         valid [0:SETS-1];
  logic                         dirty [0:SETS-1];
  logic [TAG_W-1:0]             tags  [0:SETS-1];
  logic [7:0]                   fill_buf [0:LINE_BYTES-1];

  localparam int DATA_ADDR_W = (SETS > 1) ? $clog2(SETS) : 1;
  localparam int LINE_BITS   = LINE_BYTES * 8;
  logic [DATA_ADDR_W-1:0]      data_rd_addr;
  logic                         data_rd_en;
  logic                         data_rd_valid;
  logic [LINE_BITS-1:0]         data_rd_data;
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
      .LINE_BYTES(LINE_BYTES), .DEPTH_WORDS(SETS)
  ) u_data_ram (
      .clk(clk), .rst_n(rst_n),
      .rd_en(data_rd_en), .rd_addr(data_rd_addr),
      .rd_valid(data_rd_valid), .rd_data(data_rd_data),
      .wr_en(data_wr_en), .wr_addr(data_wr_addr),
      .wr_byte_en(data_wr_byte_en), .wr_data(data_wr_data)
  );

  mem_req_t                     u_req_r;
  logic [SET_W-1:0]             set_r;
  logic [TAG_W-1:0]             tag_r;
  logic [OFF_W-1:0]             off_r;
  logic [BEAT_W-1:0]            beat_r;
  logic [SET_W-1:0]             drain_set_r;
  logic                         cross_read_pending_r;
  logic                         cross_store_pending_r;
  logic                         cross_second_r;
  logic [63:0]                  cross_first_data_r;
  logic [OFF_W-1:0]             cross_first_bytes_r;
  logic [63:0]                  cross_next_addr_r;
  logic [63:0]                  cross_second_wdata_r;
  logic [7:0]                   cross_second_strb_r;

  logic                         op_refill_r;
  logic                         op_write_miss_r;
  logic                         op_zva_r;
  logic                         op_maint_r;
  logic                         op_maint_invalidate_r;
  logic                         wb_for_drain_r;

  logic                         resp_fault_r;
  logic [63:0]                  resp_data_r;

  logic [1:0]                   probe_cmd_r;
  logic [63:0]                  probe_addr_r;
  logic [SOURCE_ID_W-1:0]       probe_source_r;
  logic [TRANSACTION_ID_W-1:0]  probe_transaction_r;
  logic                         probe_fault_r;
  logic                         probe_hit_r;
  logic                         probe_dirty_r;
  logic [LINE_BYTES*8-1:0]      probe_data_r;

  logic [SET_W-1:0]             u_set;
  logic [TAG_W-1:0]             u_tag;
  logic                         u_hit;
  logic [SET_W-1:0]             p_set;
  logic [TAG_W-1:0]             p_tag;
  logic                         p_hit;
  logic [SET_W-1:0]             cross_set;
  logic [TAG_W-1:0]             cross_tag;
  logic                         cross_hit;

  function automatic int unsigned request_bytes(input logic [7:0] strb);
    unique case (strb)
      8'h01: request_bytes = 1;
      8'h03: request_bytes = 2;
      8'h0f: request_bytes = 4;
      default: request_bytes = 8;
    endcase
  endfunction

  function automatic logic request_crosses_line(input logic [63:0] addr,
                                                 input logic [7:0] strb);
    request_crosses_line =
        (addr[OFF_W-1:0] + request_bytes(strb)) > LINE_BYTES;
  endfunction

  function automatic logic [63:0] line_addr(
      input logic [TAG_W-1:0] t,
      input logic [SET_W-1:0] s);
    logic [63:0] a;
    begin
      a = 64'd0;
      a[63:OFF_W+$clog2(SETS)] = t;
      if (SETS > 1) a[OFF_W +: $clog2(SETS)] = s[$clog2(SETS)-1:0];
      line_addr = a;
    end
  endfunction

  function automatic logic [63:0] line_read_word(
      input logic [LINE_BITS-1:0] line,
      input logic [OFF_W-1:0] o);
    logic [63:0] v;
    integer pos;
    begin
      v = '0;
      for (int i = 0; i < 8; i++) begin
        pos = o + i;
        if (pos < LINE_BYTES) v[i*8 +: 8] = line[pos*8 +: 8];
      end
      line_read_word = v;
    end
  endfunction

  function automatic logic [63:0] fill_word(input logic [OFF_W-1:0] o);
    logic [63:0] v;
    integer pos;
    begin
      v = '0;
      for (int i = 0; i < 8; i++) begin
        pos = o + i;
        if (pos < LINE_BYTES) v[i*8 +: 8] = fill_buf[pos];
      end
      fill_word = v;
    end
  endfunction

  function automatic logic [63:0] cache_chunk(
      input logic [LINE_BITS-1:0] line,
      input logic [BEAT_W-1:0] b);
    logic [63:0] v;
    begin
      v = '0;
      for (int i = 0; i < 8; i++) v[i*8 +: 8] = line[b*64+i*8 +: 8];
      cache_chunk = v;
    end
  endfunction

  function automatic logic maint_line_op(input maint_op_t m);
    case (m)
      MAINT_DC_IVAC, MAINT_DC_ISW, MAINT_DC_CVAC, MAINT_DC_CVAU,
      MAINT_DC_CIVAC, MAINT_DC_CVAP: maint_line_op = 1'b1;
      default: maint_line_op = 1'b0;
    endcase
  endfunction

  function automatic logic maint_invalidate(input maint_op_t m);
    case (m)
      MAINT_DC_IVAC, MAINT_DC_CIVAC: maint_invalidate = 1'b1;
      default: maint_invalidate = 1'b0;
    endcase
  endfunction

  always_comb begin
    u_set = (SETS > 1) ? u_req.addr[OFF_W +: $clog2(SETS)] : '0;
    u_tag = u_req.addr[63:OFF_W+$clog2(SETS)];
    u_hit = valid[u_set] && (tags[u_set] == u_tag);
    p_set = (SETS > 1) ? l1_probe_req_addr[OFF_W +: $clog2(SETS)] : '0;
    p_tag = l1_probe_req_addr[63:OFF_W+$clog2(SETS)];
    p_hit = valid[p_set] && (tags[p_set] == p_tag);
    cross_set = SET_W'((cross_next_addr_r >> OFF_W) & (SETS - 1));
    cross_tag = cross_next_addr_r[63:OFF_W+$clog2(SETS)];
    cross_hit = valid[cross_set] && (tags[cross_set] == cross_tag);
  end

  always_comb begin
    // Probe owns the single cache port when both request classes arrive in
    // ST_IDLE.  Do not advertise acceptance to the upstream client in that
    // cycle: the sequential priority below captures only the probe.
    u_req_ready = rst_n && (state == ST_IDLE) && !l1_probe_req_valid &&
                  !checkpoint_quiesce && !l1_drain_done && !l1_drain_fault;
    u_rsp_valid = rst_n && (state == ST_RSP);
    u_rsp = '0;
    u_rsp.rdata = resp_data_r;
    u_rsp.fault = resp_fault_r;

    l1_probe_req_ready = rst_n && (state == ST_IDLE) && !l1_drain_done &&
                         !l1_drain_fault;
    l1_probe_rsp_valid = rst_n && (state == ST_PROBE_RSP);
    l1_probe_rsp_fault = probe_fault_r;
    l1_probe_rsp_line_valid = probe_hit_r;
    l1_probe_rsp_dirty = probe_hit_r && probe_dirty_r;
    l1_probe_rsp_data = probe_hit_r ? probe_data_r : '0;
    l1_probe_rsp_addr = probe_addr_r;
    l1_probe_rsp_source_id = probe_source_r;
    l1_probe_rsp_transaction_id = probe_transaction_r;

    // The cache data port is intentionally single-issue.  A read request is
    // held for one state and its registered result is consumed in the next;
    // writes are line-wide masked writes and do not require a read/modify/
    // write cycle for partial stores.
    data_rd_en = rst_n && (state == ST_DATA_RD_REQ);
    data_rd_addr = set_r;
    data_wr_en = 1'b0;
    data_wr_addr = set_r;
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
    end

    d_req_valid = rst_n && ((state == ST_WB_REQ) ||
                            (state == ST_REFILL_REQ) ||
                            (state == ST_BYPASS_REQ));
    d_req = '0;
    if (state == ST_WB_REQ) begin
      d_req.addr = line_addr(tags[set_r], set_r) + beat_r * 64'd8;
      d_req.we = 1'b1;
      d_req.strb = 8'hff;
      d_req.wdata = cache_chunk(cache_line_r, beat_r);
      d_req.maint = MAINT_NONE;
      d_req.bypass = 1'b0;
    end else if (state == ST_REFILL_REQ) begin
      d_req.addr = line_addr(tag_r, set_r) + beat_r * 64'd8;
      d_req.we = 1'b0;
      d_req.strb = 8'h00;
      d_req.wdata = '0;
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
      set_r <= '0;
      tag_r <= '0;
      off_r <= '0;
      beat_r <= '0;
      drain_set_r <= '0;
      cross_read_pending_r <= 1'b0;
      cross_store_pending_r <= 1'b0;
      cross_second_r <= 1'b0;
      cross_first_data_r <= 64'd0;
      cross_first_bytes_r <= '0;
      cross_next_addr_r <= 64'd0;
      cross_second_wdata_r <= 64'd0;
      cross_second_strb_r <= 8'd0;
      op_refill_r <= 1'b0;
      op_write_miss_r <= 1'b0;
      op_zva_r <= 1'b0;
      op_maint_r <= 1'b0;
      op_maint_invalidate_r <= 1'b0;
      wb_for_drain_r <= 1'b0;
      resp_fault_r <= 1'b0;
      resp_data_r <= '0;
      probe_cmd_r <= PROBE_LOOKUP;
      probe_addr_r <= '0;
      probe_source_r <= '0;
      probe_transaction_r <= '0;
      probe_fault_r <= 1'b0;
      probe_hit_r <= 1'b0;
      probe_dirty_r <= 1'b0;
      probe_data_r <= '0;
      data_rd_kind_r <= DATA_RD_LOAD;
      cache_line_r <= '0;
      l1_drain_done <= 1'b0;
      l1_drain_fault <= 1'b0;
      for (int s = 0; s < SETS; s++) begin
        valid[s] <= 1'b0;
        dirty[s] <= 1'b0;
        tags[s] <= '0;
      end
    end else begin
      // Quiesce is a level.  Dropping it starts a fresh checkpoint epoch.
      if (!checkpoint_quiesce &&
          (state == ST_DRAIN_DONE || state == ST_DRAIN_FAILED)) begin
        l1_drain_done <= 1'b0;
        l1_drain_fault <= 1'b0;
        state <= ST_IDLE;
      end

      case (state)
        ST_IDLE: begin
          resp_fault_r <= 1'b0;
          resp_data_r <= '0;
          if (l1_probe_req_valid && l1_probe_req_ready) begin
            probe_cmd_r <= l1_probe_req_cmd;
            probe_addr_r <= {l1_probe_req_addr[63:OFF_W], {OFF_W{1'b0}}};
            probe_source_r <= l1_probe_req_source_id;
            probe_transaction_r <= l1_probe_req_transaction_id;
            set_r <= p_set;
            tag_r <= p_tag;
            case (l1_probe_req_cmd)
              PROBE_LOOKUP, PROBE_CLEAN, PROBE_INVALIDATE,
              PROBE_CLEAN_INVALIDATE: probe_fault_r <= 1'b0;
              default: probe_fault_r <= 1'b1;
            endcase
            probe_hit_r <= p_hit;
            probe_dirty_r <= p_hit && dirty[p_set];
            probe_data_r <= '0;
            if (p_hit) begin
              data_rd_kind_r <= DATA_RD_PROBE;
              state <= ST_DATA_RD_REQ;
            end else state <= ST_PROBE_RSP;
          end else if (checkpoint_quiesce) begin
            drain_set_r <= '0;
            beat_r <= '0;
            wb_for_drain_r <= 1'b0;
            state <= ST_DRAIN_SCAN;
          end else if (u_req_valid && u_req_ready) begin
            u_req_r <= u_req;
            set_r <= u_set;
            tag_r <= u_tag;
            off_r <= u_req.addr[OFF_W-1:0];
            resp_fault_r <= 1'b0;
            op_refill_r <= 1'b0;
            op_write_miss_r <= 1'b0;
            op_zva_r <= 1'b0;
            op_maint_r <= 1'b0;
            op_maint_invalidate_r <= 1'b0;
            wb_for_drain_r <= 1'b0;
            cross_read_pending_r <=
                !u_req.we && !u_req.bypass &&
                (u_req.maint == MAINT_NONE) &&
                request_crosses_line(u_req.addr, u_req.strb);
            cross_store_pending_r <=
                u_req.we && (u_req.strb != 8'd0) && !u_req.bypass &&
                (u_req.maint == MAINT_NONE) &&
                request_crosses_line(u_req.addr, u_req.strb);
            cross_second_r <= 1'b0;
            cross_first_data_r <= 64'd0;
            cross_first_bytes_r <= '0;
            cross_next_addr_r <= 64'd0;
            cross_second_wdata_r <= 64'd0;
            cross_second_strb_r <= 8'd0;
            if (!u_req.we && !u_req.bypass &&
                (u_req.maint == MAINT_NONE) &&
                request_crosses_line(u_req.addr, u_req.strb)) begin
              cross_first_bytes_r <= OFF_W'(
                  LINE_BYTES - int'(u_req.addr[OFF_W-1:0]));
              cross_next_addr_r <=
                  {u_req.addr[63:OFF_W], {OFF_W{1'b0}}} +
                  64'(LINE_BYTES);
            end else if (u_req.we && (u_req.strb != 8'd0) &&
                         !u_req.bypass &&
                         (u_req.maint == MAINT_NONE) &&
                         request_crosses_line(u_req.addr, u_req.strb)) begin
              cross_first_bytes_r <= OFF_W'(
                  LINE_BYTES - int'(u_req.addr[OFF_W-1:0]));
              cross_next_addr_r <=
                  {u_req.addr[63:OFF_W], {OFF_W{1'b0}}} +
                  64'(LINE_BYTES);
              cross_second_wdata_r <= u_req.wdata >>
                  ((LINE_BYTES - int'(u_req.addr[OFF_W-1:0])) * 8);
              cross_second_strb_r <= u_req.strb >>
                  (LINE_BYTES - int'(u_req.addr[OFF_W-1:0]));
            end

            if (u_req.bypass) begin
              state <= ST_BYPASS_REQ;
            end else if (u_req.maint == MAINT_IC_IVAU ||
                         u_req.maint == MAINT_IC_IALLU ||
                         u_req.maint == MAINT_TLBI) begin
              // I-cache/TLB state is outside D-L1; wrapper propagates these
              // maintenance requests to the next level.
              state <= ST_RSP;
            end else if (u_req.maint == MAINT_DC_ZVA) begin
              set_r <= u_set;
              if (u_hit) begin
                op_zva_r <= 1'b1;
                state <= ST_COMMIT;
              end else begin
                op_zva_r <= 1'b1;
                if (valid[u_set] && dirty[u_set]) begin
                  beat_r <= '0;
                  data_rd_kind_r <= DATA_RD_WB;
                  state <= ST_DATA_RD_REQ;
                end else state <= ST_COMMIT;
              end
            end else if (maint_line_op(u_req.maint)) begin
              op_maint_r <= 1'b1;
              op_maint_invalidate_r <= maint_invalidate(u_req.maint);
              if (!u_hit) state <= ST_RSP;
              else if (dirty[u_set]) begin
                beat_r <= '0;
                data_rd_kind_r <= DATA_RD_WB;
                state <= ST_DATA_RD_REQ;
              end else state <= ST_COMMIT;
            end else if (u_req.maint != MAINT_NONE) begin
              resp_fault_r <= 1'b1;
              state <= ST_RSP;
            end else if (u_req.we) begin
              if (u_hit) begin
                dirty[u_set] <= 1'b1;
                state <= ST_DATA_WR;
              end else begin
                op_refill_r <= 1'b1;
                op_write_miss_r <= 1'b1;
                beat_r <= '0;
                if (valid[u_set] && dirty[u_set]) begin
                  data_rd_kind_r <= DATA_RD_WB;
                  state <= ST_DATA_RD_REQ;
                end
                else state <= ST_REFILL_REQ;
              end
            end else if (u_hit) begin
              data_rd_kind_r <= DATA_RD_LOAD;
              state <= ST_DATA_RD_REQ;
            end else begin
              op_refill_r <= 1'b1;
              op_write_miss_r <= 1'b0;
              beat_r <= '0;
              if (valid[u_set] && dirty[u_set]) begin
                data_rd_kind_r <= DATA_RD_WB;
                state <= ST_DATA_RD_REQ;
              end
              else state <= ST_REFILL_REQ;
            end
          end
        end

        ST_DATA_RD_REQ: begin
          // lcvex_cache_data_ram samples rd_en/address on this edge and
          // presents rd_valid/data during the following cycle.
          state <= ST_DATA_RD_WAIT;
        end

        ST_DATA_RD_WAIT: begin
          if (data_rd_valid) begin
            cache_line_r <= data_rd_data;
            case (data_rd_kind_r)
              DATA_RD_LOAD: begin
                if (cross_read_pending_r && !cross_second_r) begin
                  cross_first_data_r <= line_read_word(data_rd_data, off_r);
                  cross_second_r <= 1'b1;
                  state <= ST_CROSS_LOOKUP;
                end else if (cross_read_pending_r && cross_second_r) begin
                  resp_data_r <= cross_first_data_r |
                      (line_read_word(data_rd_data, off_r) <<
                       (cross_first_bytes_r * 8));
                  cross_read_pending_r <= 1'b0;
                  cross_second_r <= 1'b0;
                  state <= ST_RSP;
                end else begin
                  resp_data_r <= line_read_word(data_rd_data, off_r);
                  state <= ST_RSP;
                end
              end
              DATA_RD_PROBE: begin
                probe_data_r <= data_rd_data;
                state <= ST_PROBE_RSP;
              end
              default: begin // DATA_RD_WB
                state <= ST_WB_REQ;
              end
            endcase
          end
        end

        ST_CROSS_LOOKUP: begin
          // Complete the second segment through this L1 again so a dirty
          // adjacent-line hit is never bypassed by reading stale L2 data.
          set_r <= cross_set;
          tag_r <= cross_tag;
          off_r <= '0;
          beat_r <= '0;
          op_zva_r <= 1'b0;
          op_maint_r <= 1'b0;
          op_maint_invalidate_r <= 1'b0;
          if (cross_hit) begin
            op_refill_r <= 1'b0;
            if (cross_store_pending_r) begin
              dirty[cross_set] <= 1'b1;
              state <= ST_DATA_WR;
            end else begin
              op_write_miss_r <= 1'b0;
              data_rd_kind_r <= DATA_RD_LOAD;
              state <= ST_DATA_RD_REQ;
            end
          end else begin
            op_refill_r <= 1'b1;
            op_write_miss_r <= cross_store_pending_r;
            if (valid[cross_set] && dirty[cross_set]) begin
              data_rd_kind_r <= DATA_RD_WB;
              state <= ST_DATA_RD_REQ;
            end else state <= ST_REFILL_REQ;
          end
        end

        ST_DATA_WR: begin
          // The masked line write is driven for this complete cycle; the RAM
          // samples it on the transition out of this state.
          if (cross_store_pending_r && !cross_second_r) begin
            u_req_r.addr <= cross_next_addr_r;
            u_req_r.wdata <= cross_second_wdata_r;
            u_req_r.strb <= cross_second_strb_r;
            off_r <= '0;
            cross_second_r <= 1'b1;
            state <= ST_CROSS_LOOKUP;
          end else begin
            if (cross_store_pending_r) begin
              cross_store_pending_r <= 1'b0;
              cross_second_r <= 1'b0;
            end
            state <= ST_RSP;
          end
        end

        ST_WB_REQ: begin
          if (d_req_valid && d_req_ready) state <= ST_WB_WAIT;
        end

        ST_WB_WAIT: begin
          if (d_rsp_valid && d_rsp_ready) begin
            if (d_rsp.fault) begin
              // 未完成的 dirty victim 保留旧 metadata，可安全重试。
              resp_fault_r <= 1'b1;
              if (wb_for_drain_r) begin
                l1_drain_fault <= 1'b1;
                state <= ST_DRAIN_FAILED;
              end else state <= ST_RSP;
            end else if (beat_r == BEATS-1) begin
              dirty[set_r] <= 1'b0;
              beat_r <= '0;
              if (wb_for_drain_r) begin
                if (drain_set_r == SETS-1) begin
                  l1_drain_done <= 1'b1;
                  state <= ST_DRAIN_DONE;
                end else begin
                  drain_set_r <= drain_set_r + 1'b1;
                  state <= ST_DRAIN_SCAN;
                end
              end else if (op_refill_r) state <= ST_REFILL_REQ;
              else state <= ST_COMMIT;
            end else begin
              beat_r <= beat_r + 1'b1;
              state <= ST_WB_REQ;
            end
          end
        end

        ST_REFILL_REQ: begin
          if (d_req_valid && d_req_ready) state <= ST_REFILL_WAIT;
        end

        ST_REFILL_WAIT: begin
          if (d_rsp_valid && d_rsp_ready) begin
            if (d_rsp.fault) begin
              // fill_buf 不是可见阵列；新 tag/valid 不发布。
              resp_fault_r <= 1'b1;
              state <= ST_RSP;
            end else begin
              for (int i = 0; i < 8; i++)
                fill_buf[beat_r*8+i] <= d_rsp.rdata[i*8 +: 8];
              if (beat_r == BEATS-1) state <= ST_COMMIT;
              else begin
                beat_r <= beat_r + 1'b1;
                state <= ST_REFILL_REQ;
              end
            end
          end
        end

        ST_COMMIT: begin
          if (op_refill_r) begin
            valid[set_r] <= 1'b1;
            tags[set_r] <= tag_r;
            dirty[set_r] <= op_write_miss_r;
            if (op_write_miss_r && cross_store_pending_r &&
                !cross_second_r) begin
              u_req_r.addr <= cross_next_addr_r;
              u_req_r.wdata <= cross_second_wdata_r;
              u_req_r.strb <= cross_second_strb_r;
              off_r <= '0;
              cross_second_r <= 1'b1;
              state <= ST_CROSS_LOOKUP;
            end else if (op_write_miss_r && cross_store_pending_r &&
                         cross_second_r) begin
              cross_store_pending_r <= 1'b0;
              cross_second_r <= 1'b0;
              resp_data_r <= 64'd0;
              state <= ST_RSP;
            end else if (!op_write_miss_r && cross_read_pending_r &&
                !cross_second_r) begin
              cross_first_data_r <= fill_word(off_r);
              cross_second_r <= 1'b1;
              state <= ST_CROSS_LOOKUP;
            end else if (!op_write_miss_r && cross_read_pending_r &&
                         cross_second_r) begin
              resp_data_r <= cross_first_data_r |
                  (fill_word(off_r) << (cross_first_bytes_r * 8));
              cross_read_pending_r <= 1'b0;
              cross_second_r <= 1'b0;
              state <= ST_RSP;
            end else begin
              resp_data_r <= op_write_miss_r ? 64'd0 : fill_word(off_r);
              state <= ST_RSP;
            end
          end else if (op_zva_r) begin
            valid[set_r] <= 1'b1;
            tags[set_r] <= tag_r;
            dirty[set_r] <= 1'b1;
            state <= ST_RSP;
          end else if (op_maint_r) begin
            if (op_maint_invalidate_r) valid[set_r] <= 1'b0;
            dirty[set_r] <= 1'b0;
            state <= ST_RSP;
          end else state <= ST_RSP;
        end

        ST_BYPASS_REQ: begin
          if (d_req_valid && d_req_ready) state <= ST_BYPASS_WAIT;
        end

        ST_BYPASS_WAIT: begin
          if (d_rsp_valid && d_rsp_ready) begin
            resp_data_r <= d_rsp.rdata;
            resp_fault_r <= d_rsp.fault;
            state <= ST_RSP;
          end
        end

        ST_PROBE_RSP: begin
          if (l1_probe_rsp_valid && l1_probe_rsp_ready) begin
            // abort is only used by L2 after a failed POC writeback.  It is
            // intentionally case-compared so an unconnected legacy client
            // cannot turn a fault retry into an accidental invalidation.
            if (!probe_fault_r && (l1_probe_rsp_abort !== 1'b1)) begin
              case (probe_cmd_r)
                PROBE_CLEAN: begin
                  dirty[set_r] <= 1'b0;
                end
                PROBE_INVALIDATE: begin
                  valid[set_r] <= 1'b0;
                  dirty[set_r] <= 1'b0;
                end
                PROBE_CLEAN_INVALIDATE: begin
                  valid[set_r] <= 1'b0;
                  dirty[set_r] <= 1'b0;
                end
                default: begin end
              endcase
            end
            state <= ST_IDLE;
          end
        end

        ST_DRAIN_SCAN: begin
          set_r <= drain_set_r;
          if (valid[drain_set_r] && dirty[drain_set_r]) begin
            beat_r <= '0;
            wb_for_drain_r <= 1'b1;
            op_refill_r <= 1'b0;
            op_maint_r <= 1'b0;
            data_rd_kind_r <= DATA_RD_WB;
            state <= ST_DATA_RD_REQ;
          end else if (drain_set_r == SETS-1) begin
            l1_drain_done <= 1'b1;
            state <= ST_DRAIN_DONE;
          end else begin
            drain_set_r <= drain_set_r + 1'b1;
          end
        end

        ST_DRAIN_DONE: begin
          // Level state is released by the quiesce edge handling above.
        end

        ST_DRAIN_FAILED: begin
          // Keep failed metadata and suppress both new traffic and done.
        end

        ST_RSP: begin
          if (u_rsp_valid && u_rsp_ready) begin
            cross_read_pending_r <= 1'b0;
            cross_store_pending_r <= 1'b0;
            cross_second_r <= 1'b0;
            state <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk) disable iff (!rst_n)
      dirty[0] |-> valid[0]);
  generate
    for (genvar gs = 1; gs < SETS; gs++) begin : g_dirty_invariant
      assert property (@(posedge clk) disable iff (!rst_n)
          dirty[gs] |-> valid[gs]);
    end
  endgenerate
  assert property (@(posedge clk) disable iff (!rst_n)
      u_req_ready |-> !u_rsp_valid && !l1_probe_rsp_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      l1_probe_req_valid |-> !u_req_ready);
  assert property (@(posedge clk) disable iff (!rst_n)
      l1_probe_rsp_valid && !l1_probe_rsp_ready |=>
          (l1_probe_rsp_valid || l1_probe_rsp_ready));
  /* verilator lint_on SYNCASYNCNET */

endmodule
