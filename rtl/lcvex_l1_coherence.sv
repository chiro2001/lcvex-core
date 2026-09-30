// lcvex_l1_coherence.sv
// B4 模块级单核层次闭环：PTW/D-L1/L2/PoC 的独立验证 endpoint。
//
// 该 wrapper 不接 core/pkg/filelist/SoC。它只提供一个可被独立 SV/Cocotb
// TB 驱动的 core client、一个 PTW client、D-L1/L2 的 64B probe 边界和
// checkpoint sideband。PTW 与 core 共享 D-L1 时 PTW 固定优先，因而页表
// 物理读可以观察 D-L1 中尚未下刷的最新脏数据。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_l1_coherence #(
    parameter int LINE_BYTES       = 64,
    parameter int L1_SETS          = 4,
    parameter int L2_SETS          = 4,
    parameter int L2_WAYS          = 2,
    parameter int SOURCE_ID_W      = 4,
    parameter int TRANSACTION_ID_W = 8
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // core client
    input  logic                        core_req_valid,
    input  lcvex_pkg::mem_req_t         core_req,
    output logic                        core_req_ready,
    output logic                        core_rsp_valid,
    output lcvex_pkg::mem_rsp_t         core_rsp,
    input  logic                        core_rsp_ready,
    input  logic [SOURCE_ID_W-1:0]      core_source_id,
    input  logic [TRANSACTION_ID_W-1:0] core_transaction_id,
    output logic [SOURCE_ID_W-1:0]      core_rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0] core_rsp_transaction_id,

    // PTW client；core 与 PTW 不能同时 outstanding，PTW 优先接受。
    input  logic                        ptw_req_valid,
    input  lcvex_pkg::mem_req_t         ptw_req,
    output logic                        ptw_req_ready,
    output logic                        ptw_rsp_valid,
    output lcvex_pkg::mem_rsp_t         ptw_rsp,
    input  logic                        ptw_rsp_ready,

    // PoC / SRAM 端口（L2 下游）
    output logic                        poc_req_valid,
    output lcvex_pkg::mem_req_t         poc_req,
    input  logic                        poc_req_ready,
    input  logic                        poc_rsp_valid,
    input  lcvex_pkg::mem_rsp_t         poc_rsp,
    output logic                        poc_rsp_ready,

    // checkpoint 顺序：L1 quiesce+drain -> L2 drain_to_poc -> ack。
    input  logic                        checkpoint_quiesce,
    output logic                        checkpoint_ack_valid,
    input  logic                        checkpoint_ack_ready,
    output logic                        checkpoint_fault,
    output logic                        l1_drain_done,
    output logic                        l1_drain_fault,
    output logic                        l2_drain_ack_valid,
    output logic                        l2_drain_fault
);

  import lcvex_pkg::*;

  // ---------------- D-L1 ----------------
  logic        l1_u_req_valid;
  mem_req_t    l1_u_req;
  logic        l1_u_req_ready;
  logic        l1_u_rsp_valid;
  mem_rsp_t    l1_u_rsp;
  logic        l1_u_rsp_ready;

  logic        l1_d_req_valid;
  mem_req_t    l1_d_req;
  logic        l1_d_req_ready;
  logic        l1_d_rsp_valid;
  mem_rsp_t    l1_d_rsp;
  logic        l1_d_rsp_ready;

  logic        l1_probe_req_valid;
  logic        l1_probe_req_ready;
  logic [63:0] l1_probe_req_addr;
  logic [1:0]  l1_probe_req_cmd;
  logic [SOURCE_ID_W-1:0] l1_probe_req_source_id;
  logic [TRANSACTION_ID_W-1:0] l1_probe_req_transaction_id;
  logic        l1_probe_rsp_valid;
  logic        l1_probe_rsp_ready;
  logic        l1_probe_rsp_fault;
  logic        l1_probe_rsp_line_valid;
  logic        l1_probe_rsp_dirty;
  logic [LINE_BYTES*8-1:0] l1_probe_rsp_data;
  logic [63:0] l1_probe_rsp_addr;
  logic [SOURCE_ID_W-1:0] l1_probe_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] l1_probe_rsp_transaction_id;
  logic        l1_probe_rsp_abort;

  lcvex_l1_d_wb #(
      .LINE_BYTES(LINE_BYTES), .SETS(L1_SETS),
      .SOURCE_ID_W(SOURCE_ID_W), .TRANSACTION_ID_W(TRANSACTION_ID_W)
  ) d_l1 (
      .clk(clk), .rst_n(rst_n),
      .u_req_valid(l1_u_req_valid), .u_req(l1_u_req),
      .u_req_ready(l1_u_req_ready), .u_rsp_valid(l1_u_rsp_valid),
      .u_rsp(l1_u_rsp), .u_rsp_ready(l1_u_rsp_ready),
      .d_req_valid(l1_d_req_valid), .d_req(l1_d_req),
      .d_req_ready(l1_d_req_ready), .d_rsp_valid(l1_d_rsp_valid),
      .d_rsp(l1_d_rsp), .d_rsp_ready(l1_d_rsp_ready),
      .l1_probe_req_valid(l1_probe_req_valid),
      .l1_probe_req_ready(l1_probe_req_ready),
      .l1_probe_req_addr(l1_probe_req_addr),
      .l1_probe_req_cmd(l1_probe_req_cmd),
      .l1_probe_req_source_id(l1_probe_req_source_id),
      .l1_probe_req_transaction_id(l1_probe_req_transaction_id),
      .l1_probe_rsp_valid(l1_probe_rsp_valid),
      .l1_probe_rsp_ready(l1_probe_rsp_ready),
      .l1_probe_rsp_fault(l1_probe_rsp_fault),
      .l1_probe_rsp_line_valid(l1_probe_rsp_line_valid),
      .l1_probe_rsp_dirty(l1_probe_rsp_dirty),
      .l1_probe_rsp_data(l1_probe_rsp_data),
      .l1_probe_rsp_addr(l1_probe_rsp_addr),
      .l1_probe_rsp_source_id(l1_probe_rsp_source_id),
      .l1_probe_rsp_transaction_id(l1_probe_rsp_transaction_id),
      .l1_probe_rsp_abort(l1_probe_rsp_abort),
      .checkpoint_quiesce(checkpoint_quiesce),
      .l1_drain_done(l1_drain_done), .l1_drain_fault(l1_drain_fault)
  );

  // ---------------- request client sequencer ----------------
  typedef enum logic [2:0] {
    C_IDLE,
    C_L1_REQ,
    C_L1_WAIT,
    C_L2_REQ,
    C_L2_WAIT,
    C_RSP
  } client_state_t;
  client_state_t client_state;
  mem_req_t client_req_r;
  logic client_ptw_r;
  logic [SOURCE_ID_W-1:0] client_source_r;
  logic [TRANSACTION_ID_W-1:0] client_transaction_r;
  logic client_rsp_fault_r;
  logic [63:0] client_rsp_data_r;

  always_comb begin
    core_req_ready = rst_n && !checkpoint_quiesce &&
                     (client_state == C_IDLE) && !ptw_req_valid;
    ptw_req_ready = rst_n && !checkpoint_quiesce &&
                    (client_state == C_IDLE);
    core_rsp_valid = rst_n && (client_state == C_RSP) && !client_ptw_r;
    ptw_rsp_valid = rst_n && (client_state == C_RSP) && client_ptw_r;
    core_rsp = '0;
    core_rsp.rdata = client_rsp_data_r;
    core_rsp.fault = client_rsp_fault_r;
    ptw_rsp = core_rsp;
    core_rsp_source_id = client_source_r;
    core_rsp_transaction_id = client_transaction_r;

    l1_u_req_valid = rst_n && (client_state == C_L1_REQ);
    l1_u_req = client_req_r;
    l1_u_rsp_ready = rst_n && (client_state == C_L1_WAIT);
  end

  // ---------------- L2 and PoC ----------------
  logic        l2_u_req_valid;
  mem_req_t    l2_u_req;
  logic        l2_u_req_ready;
  logic        l2_u_rsp_valid;
  mem_rsp_t    l2_u_rsp;
  logic        l2_u_rsp_ready;
  logic [SOURCE_ID_W-1:0] l2_u_source_id;
  logic [TRANSACTION_ID_W-1:0] l2_u_transaction_id;
  logic [SOURCE_ID_W-1:0] l2_u_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] l2_u_rsp_transaction_id;
  logic        l2_ctrl_req_ready;

  // L1 writeback/refill is the only active L2 upstream transaction while
  // client_state is C_L1_REQ/C_L1_WAIT.  A maintenance request is issued to
  // L2 only after the local D-L1 response has returned, so the mux cannot
  // split a transaction.
  always_comb begin
    l2_u_req_valid = l1_d_req_valid || (client_state == C_L2_REQ);
    l2_u_req = l1_d_req_valid ? l1_d_req : client_req_r;
    l2_u_source_id = l1_d_req_valid ? '0 : client_source_r;
    l2_u_transaction_id = l1_d_req_valid ? '0 : client_transaction_r;
    l1_d_req_ready = l1_d_req_valid && l2_u_req_ready;
    l2_ctrl_req_ready = !l1_d_req_valid && l2_u_req_ready;

    l1_d_rsp_valid = l2_u_rsp_valid && (client_state != C_L2_WAIT);
    l1_d_rsp = l2_u_rsp;
    l2_u_rsp_ready = (client_state == C_L2_WAIT) ? 1'b1 : l1_d_rsp_ready;
  end

  logic        l2_l1_probe_req_valid;
  logic        l2_l1_probe_req_ready;
  logic [63:0] l2_l1_probe_req_addr;
  logic [1:0]  l2_l1_probe_req_cmd;
  logic [SOURCE_ID_W-1:0] l2_l1_probe_req_source_id;
  logic [TRANSACTION_ID_W-1:0] l2_l1_probe_req_transaction_id;
  logic        l2_l1_probe_rsp_valid;
  logic        l2_l1_probe_rsp_ready;
  logic        l2_l1_probe_rsp_fault;
  logic        l2_l1_probe_rsp_line_valid;
  logic        l2_l1_probe_rsp_dirty;
  logic [LINE_BYTES*8-1:0] l2_l1_probe_rsp_data;
  logic [63:0] l2_l1_probe_rsp_addr;
  logic [SOURCE_ID_W-1:0] l2_l1_probe_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] l2_l1_probe_rsp_transaction_id;
  logic        l2_l1_probe_rsp_abort;
  logic        l1_probe_block;

  // A blocking D-L1 cannot answer a snoop while it owns an outstanding
  // request.  L2 skips that probe only in this narrow single-client window;
  // the current D-L1 operation has already serialized its own victim writeback.
  assign l1_probe_block = !l1_probe_req_ready;

  logic        l2_drain_req_valid;
  logic        l2_drain_req_ready;
  logic [SOURCE_ID_W-1:0] l2_drain_source_id;
  logic [TRANSACTION_ID_W-1:0] l2_drain_transaction_id;
  logic        l2_drain_rsp_valid;
  logic        l2_drain_ack_ready;
  logic        l2_drain_ack_fault;
  logic [SOURCE_ID_W-1:0] l2_drain_ack_source_id;
  logic [TRANSACTION_ID_W-1:0] l2_drain_ack_transaction_id;

  logic        legacy_probe_req_ready;
  logic        legacy_probe_rsp_valid;
  logic        legacy_probe_rsp_fault;
  logic        legacy_probe_rsp_hit;
  logic        legacy_probe_rsp_dirty;
  logic [LINE_BYTES*8-1:0] legacy_probe_rsp_data;
  logic [63:0] legacy_probe_rsp_addr;
  logic [SOURCE_ID_W-1:0] legacy_probe_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] legacy_probe_rsp_transaction_id;
  logic [0:0] legacy_probe_rsp_owner, legacy_probe_rsp_sharers;

  lcvex_l2_wb #(
      .LINE_BYTES(LINE_BYTES), .SETS(L2_SETS), .WAYS(L2_WAYS),
      .CORE_COUNT(1), .SOURCE_ID_W(SOURCE_ID_W),
      .TRANSACTION_ID_W(TRANSACTION_ID_W), .L1_PROBE_ENABLE(1'b1)
  ) l2 (
      .clk(clk), .rst_n(rst_n),
      .u_req_valid(l2_u_req_valid), .u_req(l2_u_req),
      .u_req_ready(l2_u_req_ready), .u_source_id(l2_u_source_id),
      .u_transaction_id(l2_u_transaction_id), .u_rsp_valid(l2_u_rsp_valid),
      .u_rsp(l2_u_rsp), .u_rsp_ready(l2_u_rsp_ready),
      .u_rsp_source_id(l2_u_rsp_source_id),
      .u_rsp_transaction_id(l2_u_rsp_transaction_id),
      .d_req_valid(poc_req_valid), .d_req(poc_req),
      .d_req_ready(poc_req_ready), .d_rsp_valid(poc_rsp_valid),
      .d_rsp(poc_rsp), .d_rsp_ready(poc_rsp_ready),
      .probe_req_valid(1'b0), .probe_req_ready(legacy_probe_req_ready),
      .probe_req_addr('0),
      .probe_req_cmd('0), .probe_req_source_id('0),
      .probe_req_transaction_id('0), .probe_rsp_valid(legacy_probe_rsp_valid),
      .probe_rsp_ready(1'b0), .probe_rsp_fault(legacy_probe_rsp_fault),
      .probe_rsp_hit(legacy_probe_rsp_hit),
      .probe_rsp_dirty(legacy_probe_rsp_dirty),
      .probe_rsp_data(legacy_probe_rsp_data),
      .probe_rsp_addr(legacy_probe_rsp_addr),
      .probe_rsp_source_id(legacy_probe_rsp_source_id),
      .probe_rsp_transaction_id(legacy_probe_rsp_transaction_id),
      .probe_rsp_owner(legacy_probe_rsp_owner),
      .probe_rsp_sharers(legacy_probe_rsp_sharers),
      .l1_probe_req_valid(l2_l1_probe_req_valid),
      .l1_probe_req_ready(l2_l1_probe_req_ready),
      .l1_probe_req_addr(l2_l1_probe_req_addr),
      .l1_probe_req_cmd(l2_l1_probe_req_cmd),
      .l1_probe_req_source_id(l2_l1_probe_req_source_id),
      .l1_probe_req_transaction_id(l2_l1_probe_req_transaction_id),
      .l1_probe_rsp_valid(l2_l1_probe_rsp_valid),
      .l1_probe_rsp_ready(l2_l1_probe_rsp_ready),
      .l1_probe_rsp_fault(l2_l1_probe_rsp_fault),
      .l1_probe_rsp_line_valid(l2_l1_probe_rsp_line_valid),
      .l1_probe_rsp_dirty(l2_l1_probe_rsp_dirty),
      .l1_probe_rsp_data(l2_l1_probe_rsp_data),
      .l1_probe_rsp_addr(l2_l1_probe_rsp_addr),
      .l1_probe_rsp_source_id(l2_l1_probe_rsp_source_id),
      .l1_probe_rsp_transaction_id(l2_l1_probe_rsp_transaction_id),
      .l1_probe_rsp_abort(l2_l1_probe_rsp_abort),
      .l1_probe_block(l1_probe_block),
      .drain_to_poc_valid(l2_drain_req_valid),
      .drain_to_poc_ready(l2_drain_req_ready),
      .drain_source_id(l2_drain_source_id),
      .drain_transaction_id(l2_drain_transaction_id),
      .drain_ack_valid(l2_drain_rsp_valid),
      .drain_ack_ready(l2_drain_ack_ready),
      .drain_ack_fault(l2_drain_ack_fault),
      .drain_ack_source_id(l2_drain_ack_source_id),
      .drain_ack_transaction_id(l2_drain_ack_transaction_id),
      .drain_fault(l2_drain_fault)
  );

  assign l1_probe_req_valid = l2_l1_probe_req_valid;
  assign l2_l1_probe_req_ready = l1_probe_req_ready;
  assign l1_probe_req_addr = l2_l1_probe_req_addr;
  assign l1_probe_req_cmd = l2_l1_probe_req_cmd;
  assign l1_probe_req_source_id = l2_l1_probe_req_source_id;
  assign l1_probe_req_transaction_id = l2_l1_probe_req_transaction_id;
  assign l2_l1_probe_rsp_valid = l1_probe_rsp_valid;
  assign l1_probe_rsp_ready = l2_l1_probe_rsp_ready;
  assign l2_l1_probe_rsp_fault = l1_probe_rsp_fault;
  assign l2_l1_probe_rsp_line_valid = l1_probe_rsp_line_valid;
  assign l2_l1_probe_rsp_dirty = l1_probe_rsp_dirty;
  assign l2_l1_probe_rsp_data = l1_probe_rsp_data;
  assign l2_l1_probe_rsp_addr = l1_probe_rsp_addr;
  assign l2_l1_probe_rsp_source_id = l1_probe_rsp_source_id;
  assign l2_l1_probe_rsp_transaction_id = l1_probe_rsp_transaction_id;
  assign l1_probe_rsp_abort = l2_l1_probe_rsp_abort;

  // ---------------- checkpoint coordinator ----------------
  typedef enum logic [2:0] {
    CP_IDLE,
    CP_L2_REQ,
    CP_L2_WAIT,
    CP_ACK,
    CP_FAILED,
    CP_DONE
  } checkpoint_state_t;
  checkpoint_state_t checkpoint_state;
  assign l2_drain_req_valid = checkpoint_quiesce &&
                              (checkpoint_state == CP_L2_REQ);
  assign l2_drain_source_id = '0;
  assign l2_drain_transaction_id = 8'hc1;
  assign l2_drain_ack_ready = checkpoint_quiesce &&
                              (checkpoint_state == CP_L2_WAIT);
  assign checkpoint_ack_valid = rst_n && (checkpoint_state == CP_ACK);
  assign checkpoint_fault = (checkpoint_state == CP_FAILED) ||
                            l1_drain_fault || l2_drain_fault;
  assign l2_drain_ack_valid = l2_drain_rsp_valid;

  // The public status is driven in the sequential block to avoid exposing a
  // second combinational alias with the same name as the L2 signal.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      client_state <= C_IDLE;
      client_req_r <= '0;
      client_ptw_r <= 1'b0;
      client_source_r <= '0;
      client_transaction_r <= '0;
      client_rsp_fault_r <= 1'b0;
      client_rsp_data_r <= '0;
      checkpoint_state <= CP_IDLE;
    end else begin
      if (!checkpoint_quiesce) begin
        checkpoint_state <= CP_IDLE;
      end else begin
        case (checkpoint_state)
          CP_IDLE: begin
            if (l1_drain_fault || l2_drain_fault)
              checkpoint_state <= CP_FAILED;
            else if (l1_drain_done)
              checkpoint_state <= CP_L2_REQ;
          end
          CP_L2_REQ: begin
            if (l2_drain_req_valid && l2_drain_req_ready)
              checkpoint_state <= CP_L2_WAIT;
            else if (l2_drain_fault) checkpoint_state <= CP_FAILED;
          end
          CP_L2_WAIT: begin
            if (l2_drain_fault) checkpoint_state <= CP_FAILED;
            else if (l2_drain_rsp_valid && l2_drain_ack_ready)
              checkpoint_state <= CP_ACK;
          end
          CP_ACK: begin
            if (checkpoint_ack_valid && checkpoint_ack_ready)
              checkpoint_state <= CP_DONE;
          end
          default: begin end
        endcase
      end

      case (client_state)
        C_IDLE: begin
          if (ptw_req_valid && ptw_req_ready) begin
            client_req_r <= ptw_req;
            client_ptw_r <= 1'b1;
            client_source_r <= '0;
            client_transaction_r <= '0;
            client_state <= C_L1_REQ;
          end else if (core_req_valid && core_req_ready) begin
            client_req_r <= core_req;
            client_ptw_r <= 1'b0;
            client_source_r <= core_source_id;
            client_transaction_r <= core_transaction_id;
            client_state <= C_L1_REQ;
          end
        end
        C_L1_REQ: begin
          if (l1_u_req_valid && l1_u_req_ready) client_state <= C_L1_WAIT;
        end
        C_L1_WAIT: begin
          if (l1_u_rsp_valid && l1_u_rsp_ready) begin
            if (client_req_r.maint != MAINT_NONE &&
                !client_req_r.bypass && !l1_u_rsp.fault)
              client_state <= C_L2_REQ;
            else begin
              client_rsp_data_r <= l1_u_rsp.rdata;
              client_rsp_fault_r <= l1_u_rsp.fault;
              client_state <= C_RSP;
            end
          end
        end
        C_L2_REQ: begin
          if (l2_u_req_valid && l2_ctrl_req_ready) client_state <= C_L2_WAIT;
        end
        C_L2_WAIT: begin
          if (l2_u_rsp_valid && l2_u_rsp_ready) begin
            client_rsp_data_r <= l2_u_rsp.rdata;
            client_rsp_fault_r <= l2_u_rsp.fault;
            client_state <= C_RSP;
          end
        end
        C_RSP: begin
          if ((client_ptw_r && ptw_rsp_ready) ||
              (!client_ptw_r && core_rsp_ready)) client_state <= C_IDLE;
        end
        default: client_state <= C_IDLE;
      endcase
    end
  end

endmodule

// ----------------------------------------------------------------------
// C2 per-core coherent L1 wrapper.
//
// This is a unified direct-mapped line cache used by a single core for
// imem/dmem/PTW traffic in the C2 shared-L2 MSI system.  It translates the
// existing single-core M1-B request stream into lcvex_l2_cluster line-level
// commands and answers L2 probes with the B4 probe command encoding.
//
// Intentionally simple:
//   * one outstanding request per core;
//   * direct-mapped, no eviction of dirty lines yet in this slice (the
//     directed C2 tests use a deliberately small working set);
//   * read miss -> ReadShared; write miss -> ReadUnique; S write hit ->
//     Upgrade; M write hit updates locally;
//   * probe clean/invalidate holds metadata until the cluster releases the
//     response (probe_rsp_abort preserves it).
//
// It does not model a separate I-cache or full ARM maintenance semantics.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */

module lcvex_c2_l1_coherent #(
    parameter int LINE_BYTES       = 64,
    parameter int SETS             = 64,
    parameter int CORE_ID_W        = 4,
    parameter int SOURCE_ID_W      = 4,
    parameter int TRANSACTION_ID_W = 8
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // Upstream M1-B from the per-core arbiter (PTW/D/IMEM).
    input  logic                        u_req_valid,
    input  lcvex_pkg::mem_req_t         u_req,
    output logic                        u_req_ready,
    output logic                        u_rsp_valid,
    output lcvex_pkg::mem_rsp_t         u_rsp,
    input  logic                        u_rsp_ready,

    // Line-level cluster port.
    output logic                        cl_req_valid,
    input  logic                        cl_req_ready,
    output lcvex_cluster_pkg::lcvex_coh_req_t cl_req,
    input  logic                        cl_rsp_valid,
    output logic                        cl_rsp_ready,
    input  lcvex_cluster_pkg::lcvex_coh_rsp_t cl_rsp,

    // L2 -> L1 probe (B4 command encoding).
    input  logic                        probe_req_valid,
    output logic                        probe_req_ready,
    input  logic [63:0]                 probe_req_addr,
    input  logic [1:0]                  probe_req_cmd,
    input  logic [SOURCE_ID_W-1:0]      probe_req_source_id,
    input  logic [TRANSACTION_ID_W-1:0] probe_req_transaction_id,
    output logic                        probe_rsp_valid,
    input  logic                        probe_rsp_ready,
    output logic                        probe_rsp_fault,
    output logic                        probe_rsp_line_valid,
    output logic                        probe_rsp_dirty,
    output logic [LINE_BYTES*8-1:0]     probe_rsp_data,
    output logic [63:0]                 probe_rsp_addr,
    output logic [SOURCE_ID_W-1:0]      probe_rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0] probe_rsp_transaction_id,
    input  logic                        probe_rsp_abort
);

  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int OFF_W  = $clog2(LINE_BYTES);
  localparam int TAG_W  = 64 - $clog2(SETS) - $clog2(LINE_BYTES);
  localparam int SET_W  = (SETS > 1) ? $clog2(SETS) : 1;

  localparam logic [1:0] PROBE_LOOKUP           = 2'd0;
  localparam logic [1:0] PROBE_CLEAN            = 2'd1;
  localparam logic [1:0] PROBE_INVALIDATE       = 2'd2;
  localparam logic [1:0] PROBE_CLEAN_INVALIDATE = 2'd3;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_CL_REQ,
    ST_CL_WAIT,
    ST_RSP,
    ST_PROBE_RSP
  } state_t;

  typedef enum logic [3:0] {
    PH_NONE = 4'd0,
    PH_BYPASS = 4'd1,
    PH_READ_SHARED = 4'd2,
    PH_READ_UNIQUE = 4'd3,
    PH_UPGRADE = 4'd4,
    PH_WRITEBACK = 4'd5,
    PH_CLEAN = 4'd6,
    PH_CLEAN_INVALIDATE = 4'd7,
    PH_EVICT = 4'd8
  } phase_t;

  state_t state;
  phase_t phase;
  phase_t next_phase;
  mem_req_t u_req_r;
  logic [SET_W-1:0] set_r;
  logic [TAG_W-1:0] tag_r;
  logic [TAG_W-1:0] evict_tag_r;
  logic [OFF_W-1:0] off_r;
  logic [63:0]      rsp_data_r;
  logic             rsp_fault_r;
  logic             pending_write;
  logic [63:0]      pending_wdata;
  logic [7:0]       pending_strb;

  // Direct-mapped unified cache.
  logic                     valid [0:SETS-1];
  logic                     dirty [0:SETS-1];
  logic [1:0]               cstate [0:SETS-1];
  logic [TAG_W-1:0]         tags  [0:SETS-1];
  logic [7:0]               data  [0:SETS-1][0:LINE_BYTES-1];

  // Probe context.
  logic                     probe_pending;
  logic [63:0]              probe_addr_r;
  logic [1:0]               probe_cmd_r;
  logic                     probe_hit_r;
  logic                     probe_dirty_r;
  logic [LINE_BYTES*8-1:0]  probe_data_r;

  // ---- Combinational cache lookup ----
  logic [SET_W-1:0] u_set, p_set;
  logic [TAG_W-1:0] u_tag, p_tag;
  logic             u_hit, p_hit;
  logic [1:0]       u_state, p_state;

  always_comb begin
    u_set  = (SETS > 1) ? u_req.addr[OFF_W +: $clog2(SETS)] : '0;
    u_tag  = u_req.addr[63:OFF_W+$clog2(SETS)];
    u_hit  = valid[u_set] && (tags[u_set] == u_tag);
    u_state = cstate[u_set];
    p_set  = (SETS > 1) ? probe_req_addr[OFF_W +: $clog2(SETS)] : '0;
    p_tag  = probe_req_addr[63:OFF_W+$clog2(SETS)];
    p_hit  = valid[p_set] && (tags[p_set] == p_tag);
    p_state = cstate[p_set];
  end

  function automatic logic [63:0] read_word(input logic [SET_W-1:0] s,
                                            input logic [OFF_W-1:0] o);
    logic [63:0] v;
    begin
      v = '0;
      for (int i = 0; i < 8; i++) begin
        if ((o + i) < LINE_BYTES) v[i*8 +: 8] = data[s][o+i];
      end
      read_word = v;
    end
  endfunction

  function automatic logic [LINE_BYTES*8-1:0] pack_line(input logic [SET_W-1:0] s);
    logic [LINE_BYTES*8-1:0] v;
    begin
      v = '0;
      for (int i = 0; i < LINE_BYTES; i++) v[i*8 +: 8] = data[s][i];
      pack_line = v;
    end
  endfunction

  function automatic logic [63:0] line_base(input logic [SET_W-1:0] s,
                                            input logic [TAG_W-1:0] t);
    logic [63:0] a;
    begin
      a = '0;
      a[63:OFF_W+$clog2(SETS)] = t;
      if (SETS > 1) a[OFF_W +: $clog2(SETS)] = s;
      line_base = a;
    end
  endfunction

  // Build the 64B payload for a bypass write so the cluster can extract the
  // correct bytes at u_req.addr[5:0].
  function automatic logic [LINE_BYTES*8-1:0] make_bypass_data(
      input logic [OFF_W-1:0] off, input logic [63:0] wdata, input logic [7:0] strb);
    logic [LINE_BYTES*8-1:0] v;
    begin
      v = '0;
      for (int i = 0; i < 8; i++) begin
        if (strb[i] && ((off + i) < LINE_BYTES))
          v[(off+i)*8 +: 8] = wdata[i*8 +: 8];
      end
      make_bypass_data = v;
    end
  endfunction

  always_comb begin
    u_req_ready = rst_n && (state == ST_IDLE) && !probe_pending;
    u_rsp_valid = rst_n && (state == ST_RSP);
    u_rsp = '0;
    u_rsp.rdata = rsp_data_r;
    u_rsp.fault = rsp_fault_r;

    cl_req_valid = rst_n && (state == ST_CL_REQ);
    cl_req = '0;
    cl_req.addr = (phase == PH_BYPASS) ? u_req_r.addr :
                  (phase == PH_EVICT) ? line_base(set_r, evict_tag_r) :
                  line_base(set_r, tag_r);
    cl_req.data = (phase == PH_WRITEBACK || phase == PH_CLEAN ||
                   phase == PH_CLEAN_INVALIDATE || phase == PH_EVICT) ?
                  pack_line(set_r) :
                  (phase == PH_BYPASS) ?
                    make_bypass_data(off_r, u_req_r.wdata, u_req_r.strb) : '0;
    case (phase)
      PH_BYPASS: cl_req.cmd = u_req_r.we ? COH_BYPASS_WRITE : COH_BYPASS_READ;
      PH_READ_SHARED: cl_req.cmd = COH_READ_SHARED;
      PH_READ_UNIQUE: cl_req.cmd = COH_READ_UNIQUE;
      PH_UPGRADE: cl_req.cmd = COH_UPGRADE;
      PH_WRITEBACK, PH_EVICT: cl_req.cmd = COH_WRITEBACK;
      PH_CLEAN: cl_req.cmd = COH_CLEAN;
      PH_CLEAN_INVALIDATE: cl_req.cmd = COH_CLEAN_INVALIDATE;
      default: cl_req.cmd = COH_READ_SHARED;
    endcase
    cl_rsp_ready = rst_n && (state == ST_CL_WAIT);

    probe_req_ready = rst_n && (state == ST_IDLE) && !u_req_valid && !probe_pending;
    probe_rsp_valid = rst_n && (state == ST_PROBE_RSP);
    probe_rsp_fault = 1'b0;
    probe_rsp_line_valid = rst_n && (state == ST_PROBE_RSP) && probe_hit_r;
    probe_rsp_dirty = rst_n && (state == ST_PROBE_RSP) && probe_hit_r && probe_dirty_r;
    probe_rsp_data = probe_hit_r ? probe_data_r : '0;
    probe_rsp_addr = probe_addr_r;
    probe_rsp_source_id = probe_req_source_id;
    probe_rsp_transaction_id = probe_req_transaction_id;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      phase <= PH_NONE;
      next_phase <= PH_NONE;
      u_req_r <= '0;
      set_r <= '0;
      tag_r <= '0;
      evict_tag_r <= '0;
      off_r <= '0;
      rsp_data_r <= '0;
      rsp_fault_r <= 1'b0;
      pending_write <= 1'b0;
      pending_wdata <= '0;
      pending_strb <= '0;
      probe_pending <= 1'b0;
      probe_addr_r <= '0;
      probe_cmd_r <= PROBE_LOOKUP;
      probe_hit_r <= 1'b0;
      probe_dirty_r <= 1'b0;
      probe_data_r <= '0;
      for (int s = 0; s < SETS; s++) begin
        valid[s]   <= 1'b0;
        dirty[s]   <= 1'b0;
        cstate[s]  <= COH_L1_I;
        tags[s]    <= '0;
      end
    end else begin
      case (state)
        ST_IDLE: begin
          if (probe_req_valid && probe_req_ready) begin
            probe_pending <= 1'b1;
            probe_addr_r  <= {probe_req_addr[63:OFF_W], {OFF_W{1'b0}}};
            probe_cmd_r   <= probe_req_cmd;
            probe_hit_r   <= p_hit;
            probe_dirty_r <= p_hit && dirty[p_set];
            probe_data_r  <= p_hit ? pack_line(p_set) : '0;
            state <= ST_PROBE_RSP;
          end else if (u_req_valid && u_req_ready) begin
            u_req_r <= u_req;
            set_r <= u_set;
            tag_r <= u_tag;
            off_r <= u_req.addr[OFF_W-1:0];
            pending_write <= u_req.we;
            pending_wdata <= u_req.wdata;
            pending_strb <= u_req.strb;
            rsp_fault_r <= 1'b0;
            probe_pending <= 1'b0;

            if (u_req.bypass) begin
              phase <= PH_BYPASS;
              state <= ST_CL_REQ;
            end else if (u_req.maint == MAINT_DC_CVAC ||
                         u_req.maint == MAINT_DC_CVAU) begin
              if (u_hit && dirty[u_set]) begin
                phase <= PH_CLEAN;
                state <= ST_CL_REQ;
              end else begin
                rsp_data_r <= '0;
                state <= ST_RSP;
              end
            end else if (u_req.maint == MAINT_DC_CIVAC ||
                         u_req.maint == MAINT_DC_IVAC) begin
              if (u_hit && dirty[u_set]) begin
                phase <= PH_CLEAN_INVALIDATE;
                state <= ST_CL_REQ;
              end else if (u_hit) begin
                valid[u_set] <= 1'b0;
                dirty[u_set] <= 1'b0;
                cstate[u_set] <= COH_L1_I;
                rsp_data_r <= '0;
                state <= ST_RSP;
              end else begin
                rsp_data_r <= '0;
                state <= ST_RSP;
              end
            end else if (u_req.maint == MAINT_IC_IVAU ||
                         u_req.maint == MAINT_IC_IALLU ||
                         u_req.maint == MAINT_TLBI) begin
              // No separate I-cache model in this unified C2 L1 slice.
              rsp_data_r <= '0;
              state <= ST_RSP;
            end else if (u_req.maint != MAINT_NONE) begin
              rsp_fault_r <= 1'b1;
              state <= ST_RSP;
            end else if (!u_req.we) begin
              if (u_hit) begin
                rsp_data_r <= read_word(u_set, u_req.addr[OFF_W-1:0]);
                state <= ST_RSP;
              end else if (valid[u_set] && dirty[u_set]) begin
                phase <= PH_EVICT;
                evict_tag_r <= tags[u_set];
                next_phase <= PH_READ_SHARED;
                state <= ST_CL_REQ;
              end else begin
                phase <= PH_READ_SHARED;
                state <= ST_CL_REQ;
              end
            end else begin
              if (u_hit && (cstate[u_set] == COH_L1_M)) begin
                for (int i = 0; i < 8; i++) begin
                  if (u_req.strb[i])
                    data[u_set][u_req.addr[OFF_W-1:0]+i] <= u_req.wdata[i*8 +: 8];
                end
                dirty[u_set] <= 1'b1;
                rsp_data_r <= '0;
                state <= ST_RSP;
              end else if (u_hit && (cstate[u_set] == COH_L1_S)) begin
                phase <= PH_UPGRADE;
                state <= ST_CL_REQ;
              end else if (valid[u_set] && dirty[u_set]) begin
                phase <= PH_EVICT;
                evict_tag_r <= tags[u_set];
                next_phase <= PH_READ_UNIQUE;
                state <= ST_CL_REQ;
              end else begin
                phase <= PH_READ_UNIQUE;
                state <= ST_CL_REQ;
              end
            end
          end
        end

        ST_CL_REQ: begin
          if (cl_req_valid && cl_req_ready) begin
            state <= ST_CL_WAIT;
          end
        end

        ST_CL_WAIT: begin
          if (cl_rsp_valid && cl_rsp_ready) begin
            if (cl_rsp.fault) begin
              rsp_fault_r <= 1'b1;
              rsp_data_r <= '0;
              state <= ST_RSP;
            end else begin
              case (phase)
                PH_BYPASS: begin
                  rsp_data_r <= cl_rsp.data[63:0];
                  state <= ST_RSP;
                end
                PH_READ_SHARED: begin
                  for (int i = 0; i < LINE_BYTES; i++)
                    data[set_r][i] <= cl_rsp.data[i*8 +: 8];
                  valid[set_r]  <= 1'b1;
                  dirty[set_r]  <= 1'b0;
                  cstate[set_r] <= COH_L1_S;
                  tags[set_r]   <= tag_r;
                  rsp_data_r    <= cl_rsp.data[off_r*8 +: 64];
                  state <= ST_RSP;
                end
                PH_READ_UNIQUE: begin
                  for (int i = 0; i < LINE_BYTES; i++)
                    data[set_r][i] <= cl_rsp.data[i*8 +: 8];
                  for (int i = 0; i < 8; i++) begin
                    if (pending_strb[i]) data[set_r][off_r+i] <= pending_wdata[i*8 +: 8];
                  end
                  valid[set_r]  <= 1'b1;
                  dirty[set_r]  <= 1'b1;
                  cstate[set_r] <= COH_L1_M;
                  tags[set_r]   <= tag_r;
                  rsp_data_r    <= '0;
                  state <= ST_RSP;
                end
                PH_UPGRADE: begin
                  cstate[set_r] <= COH_L1_M;
                  dirty[set_r]  <= 1'b1;
                  for (int i = 0; i < 8; i++) begin
                    if (pending_strb[i]) data[set_r][off_r+i] <= pending_wdata[i*8 +: 8];
                  end
                  rsp_data_r <= '0;
                  state <= ST_RSP;
                end
                PH_WRITEBACK: begin
                  cstate[set_r] <= COH_L1_I;
                  dirty[set_r]  <= 1'b0;
                  valid[set_r]  <= 1'b0;
                  rsp_data_r <= '0;
                  state <= ST_RSP;
                end
                PH_EVICT: begin
                  dirty[set_r]  <= 1'b0;
                  valid[set_r]  <= 1'b0;
                  cstate[set_r] <= COH_L1_I;
                  phase <= next_phase;
                  state <= ST_CL_REQ;
                end
                PH_CLEAN: begin
                  dirty[set_r] <= 1'b0;
                  cstate[set_r] <= COH_L1_S;
                  rsp_data_r <= '0;
                  state <= ST_RSP;
                end
                default: begin // PH_CLEAN_INVALIDATE
                  dirty[set_r] <= 1'b0;
                  valid[set_r] <= 1'b0;
                  cstate[set_r] <= COH_L1_I;
                  rsp_data_r <= '0;
                  state <= ST_RSP;
                end
              endcase
            end
          end
        end

        ST_RSP: begin
          if (u_rsp_valid && u_rsp_ready) begin
            state <= ST_IDLE;
            pending_write <= 1'b0;
          end
        end

        ST_PROBE_RSP: begin
          if (probe_rsp_valid && probe_rsp_ready) begin
            if (!probe_rsp_abort && probe_hit_r) begin
              case (probe_cmd_r)
                PROBE_CLEAN: begin
                  dirty[p_set] <= 1'b0;
                  cstate[p_set] <= COH_L1_S;
                end
                PROBE_INVALIDATE,
                PROBE_CLEAN_INVALIDATE: begin
                  valid[p_set] <= 1'b0;
                  dirty[p_set] <= 1'b0;
                  cstate[p_set] <= COH_L1_I;
                end
                default: begin end
              endcase
            end
            probe_pending <= 1'b0;
            state <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
