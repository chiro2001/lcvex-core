// lcvex_catapult_soc_coh.sv
// B5-SoC/Boot: 单核 I/D-L1 + 统一 L2 write-back 一致性子系统。
//
// 该 wrapper 复用 B3/B4 的 lcvex_l1_i、lcvex_l1_d_wb、lcvex_l2_wb 与
// M1-B 仲裁器，闭合单核一致边界：
//   core.imem -> I-L1
//   core.dmem/PTW -> D-L1（client sequencer，PTW 优先）
//   I-L1/D-L1 下游 + D 侧维护请求 -> mem_arb -> L2
//   L2 -> D-L1 probe / checkpoint quiesce+drain（B4 边界）
//   L2 下游（PoC）以 M1-B 8B 端口输出给 SoC 路由。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */

module lcvex_catapult_soc_coh #(
    parameter int LINE_BYTES       = 64,
    parameter int L1_SETS          = 64,
    parameter int L2_SETS          = 256,
    parameter int L2_WAYS          = 2,
    parameter int SOURCE_ID_W      = 4,
    parameter int TRANSACTION_ID_W = 8
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // core.imem -> I-L1
    input  logic                        imem_req_valid,
    input  lcvex_pkg::mem_req_t         imem_req,
    output logic                        imem_req_ready,
    output logic                        imem_rsp_valid,
    output lcvex_pkg::mem_rsp_t         imem_rsp,
    input  logic                        imem_rsp_ready,

    // core.dmem / PTW -> D-L1（PTW 优先）
    input  logic                        dmem_req_valid,
    input  lcvex_pkg::mem_req_t         dmem_req,
    output logic                        dmem_req_ready,
    output logic                        dmem_rsp_valid,
    output lcvex_pkg::mem_rsp_t         dmem_rsp,
    input  logic                        dmem_rsp_ready,
    input  logic                        ptw_req_valid,
    input  lcvex_pkg::mem_req_t         ptw_req,
    output logic                        ptw_req_ready,
    output logic                        ptw_rsp_valid,
    output lcvex_pkg::mem_rsp_t         ptw_rsp,
    input  logic                        ptw_rsp_ready,

    // checkpoint quiesce + drain-to-PoC（B4 边界）。
    input  logic                        checkpoint_quiesce,
    output logic                        checkpoint_ack_valid,
    input  logic                        checkpoint_ack_ready,
    output logic                        checkpoint_fault,
    output logic                        l1_drain_done,
    output logic                        l1_drain_fault,
    output logic                        l2_drain_ack_valid,
    output logic                        l2_drain_fault,

    // PoC 下游（L2 的 M1-B 8B 端口）。
    output logic                        poc_req_valid,
    output lcvex_pkg::mem_req_t         poc_req,
    input  logic                        poc_req_ready,
    input  logic                        poc_rsp_valid,
    input  lcvex_pkg::mem_rsp_t         poc_rsp,
    output logic                        poc_rsp_ready,

    // 调试观测。
    output logic                        dbg_l1_u_req_we,
    output logic [63:0]                 dbg_l1_u_req_addr,
    output logic                        dbg_l1_u_req_bypass,
    output logic [63:0]                 dbg_l1_u_req_wdata,
    output logic                        dbg_arb_req0_we,
    output logic                        dbg_arb_req0_bypass,
    output logic [63:0]                 dbg_arb_req0_wdata,
    output logic                        dbg_l2_u_req_we,
    output logic [63:0]                 dbg_l2_u_req_addr,
    output logic                        dbg_l2_u_req_bypass,
    output logic [63:0]                 dbg_l2_u_req_wdata
);

  import lcvex_pkg::*;

  // ---------------- I-L1 ----------------
  logic        il1_d_req_valid;
  mem_req_t    il1_d_req;
  logic        il1_d_req_ready;
  logic        il1_d_rsp_valid;
  mem_rsp_t    il1_d_rsp;
  logic        il1_d_rsp_ready;
  logic        catapult_il1_perf_hit;
  logic        catapult_il1_perf_refill_beat;

  lcvex_l1_i #(
      .LINE_BYTES(LINE_BYTES), .SETS(L1_SETS)
  ) i_l1 (
      .clk(clk), .rst_n(rst_n),
      .u_req_valid(imem_req_valid), .u_req(imem_req),
      .u_req_ready(imem_req_ready), .u_rsp_valid(imem_rsp_valid),
      .u_rsp(imem_rsp), .u_rsp_ready(imem_rsp_ready),
      .d_req_valid(il1_d_req_valid), .d_req(il1_d_req),
      .d_req_ready(il1_d_req_ready), .d_rsp_valid(il1_d_rsp_valid),
      .d_rsp(il1_d_rsp), .d_rsp_ready(il1_d_rsp_ready),
      // Catapult path does not consume the single-core perf observation;
      // retain explicit local sinks so this path has no empty-pin warning.
      .perf_hit(catapult_il1_perf_hit),
      .perf_refill_beat(catapult_il1_perf_refill_beat)
  );

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

  // ---------------- D 侧 client sequencer（core/PTW）----------------
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

  logic client_maint_req_valid;

  always_comb begin
    dmem_req_ready = rst_n && !checkpoint_quiesce &&
                     (client_state == C_IDLE) && !ptw_req_valid;
    ptw_req_ready = rst_n && !checkpoint_quiesce &&
                    (client_state == C_IDLE);
    dmem_rsp_valid = rst_n && (client_state == C_RSP) && !client_ptw_r;
    ptw_rsp_valid = rst_n && (client_state == C_RSP) && client_ptw_r;
    dmem_rsp = '0;
    dmem_rsp.rdata = client_rsp_data_r;
    dmem_rsp.fault = client_rsp_fault_r;
    ptw_rsp = dmem_rsp;

    l1_u_req_valid = rst_n && (client_state == C_L1_REQ);
    l1_u_req = client_req_r;
    l1_u_rsp_ready = rst_n && (client_state == C_L1_WAIT);
  end

  // ---------------- L1/L2 上游仲裁 ----------------
  // port0 = D 侧（D-L1 下游优先，其次 D 维护请求）；port1 = I-L1 下游。
  logic [1:0]           arb_req_valid;
  mem_req_t [1:0]       arb_req;
  logic [1:0]           arb_req_ready;
  logic [1:0]           arb_rsp_valid;
  mem_rsp_t [1:0]       arb_rsp;
  logic [1:0]           arb_rsp_ready;
  logic                 arb_mem_req_valid;
  mem_req_t             arb_mem_req;
  logic                 arb_mem_req_accept;
  logic                 arb_mem_rsp_valid;
  mem_rsp_t             arb_mem_rsp;
  logic                 arb_mem_rsp_ready;

  assign client_maint_req_valid = (client_state == C_L2_REQ);

  assign arb_req_valid[0] = l1_d_req_valid || client_maint_req_valid;
  assign arb_req[0] = l1_d_req_valid ? l1_d_req : client_req_r;
  assign arb_req_valid[1] = il1_d_req_valid;
  assign arb_req[1] = il1_d_req;
  assign il1_d_req_ready = arb_req_ready[1];
  assign l1_d_req_ready  = arb_req_ready[0];

  // D-L1 与 client 不能同时等待响应；响应按等待状态路由。
  assign l1_d_rsp_valid = arb_rsp_valid[0] && l1_d_rsp_ready;
  assign l1_d_rsp = arb_rsp[0];
  assign arb_rsp_ready[0] = l1_d_rsp_ready ||
                            (client_state == C_L2_WAIT);
  assign il1_d_rsp_valid = arb_rsp_valid[1] && il1_d_rsp_ready;
  assign il1_d_rsp = arb_rsp[1];
  assign arb_rsp_ready[1] = il1_d_rsp_ready;

  lcvex_mem_arb #(
      .PORTS(2)
  ) l1_arb (
      .clk(clk), .rst_n(rst_n),
      .req_valid(arb_req_valid), .req(arb_req),
      .req_ready(arb_req_ready),
      .rsp_valid(arb_rsp_valid), .rsp(arb_rsp),
      .rsp_ready(arb_rsp_ready),
      .mem_req_valid(arb_mem_req_valid), .mem_req(arb_mem_req),
      .mem_req_accept(arb_mem_req_accept),
      .mem_rsp_valid(arb_mem_rsp_valid), .mem_rsp(arb_mem_rsp),
      .mem_rsp_ready(arb_mem_rsp_ready)
  );

  // ---------------- L2 ----------------
  logic        l2_u_req_ready;
  logic        l2_u_rsp_valid;
  mem_rsp_t    l2_u_rsp;
  logic        l2_u_rsp_ready;
  logic [SOURCE_ID_W-1:0] l2_u_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] l2_u_rsp_transaction_id;

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
      .u_req_valid(arb_mem_req_valid), .u_req(arb_mem_req),
      .u_req_ready(l2_u_req_ready), .u_source_id('0),
      .u_transaction_id('0), .u_rsp_valid(l2_u_rsp_valid),
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

  assign arb_mem_req_accept = l2_u_req_ready;
  assign arb_mem_rsp_valid  = l2_u_rsp_valid;
  assign arb_mem_rsp        = l2_u_rsp;
  assign l2_u_rsp_ready     = arb_mem_rsp_ready;

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
  assign l1_probe_block = !l1_probe_req_ready;

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
          end else if (dmem_req_valid && dmem_req_ready) begin
            client_req_r <= dmem_req;
            client_ptw_r <= 1'b0;
            client_source_r <= '0;
            client_transaction_r <= '0;
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
          if (client_maint_req_valid && arb_req_ready[0])
            client_state <= C_L2_WAIT;
        end
        C_L2_WAIT: begin
          if (arb_rsp_valid[0] && (client_state == C_L2_WAIT)) begin
            client_rsp_data_r <= arb_rsp[0].rdata;
            client_rsp_fault_r <= arb_rsp[0].fault;
            client_state <= C_RSP;
          end
        end
        C_RSP: begin
          if ((client_ptw_r && ptw_rsp_ready) ||
              (!client_ptw_r && dmem_rsp_ready)) client_state <= C_IDLE;
        end
        default: client_state <= C_IDLE;
      endcase
    end
  end

  assign dbg_l1_u_req_we = l1_u_req.we;
  assign dbg_l1_u_req_addr = l1_u_req.addr;
  assign dbg_l1_u_req_bypass = l1_u_req.bypass;
  assign dbg_l1_u_req_wdata = l1_u_req.wdata;
  assign dbg_arb_req0_we = arb_req[0].we;
  assign dbg_arb_req0_bypass = arb_req[0].bypass;
  assign dbg_arb_req0_wdata = arb_req[0].wdata;
  assign dbg_l2_u_req_we = arb_mem_req.we;
  assign dbg_l2_u_req_addr = arb_mem_req.addr;
  assign dbg_l2_u_req_bypass = arb_mem_req.bypass;
  assign dbg_l2_u_req_wdata = arb_mem_req.wdata;

endmodule
