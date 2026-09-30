// lcvex_l1_d_wb_cocotb_tb.sv
// Cocotb 入口：扁平化联合 D-L1/L2 endpoint，保留 PTW、maintenance、
// checkpoint 和 fault/backpressure 控制；不连接 SoC。

`timescale 1ns/1ps

module lcvex_l1_d_wb_cocotb_tb #(
    parameter int LINE_BYTES = 64,
    parameter int DEPTH = 1 << 16,
    parameter int SOURCE_ID_W = 4,
    parameter int TRANSACTION_ID_W = 8
) (
    input logic clk,
    input logic rst_n,
    input logic req_valid,
    output logic req_ready,
    input logic [63:0] req_addr,
    input logic req_we,
    input logic [7:0] req_strb,
    input logic [63:0] req_wdata,
    input logic [3:0] req_maint,
    input logic req_bypass,
    input logic [SOURCE_ID_W-1:0] req_source_id,
    input logic [TRANSACTION_ID_W-1:0] req_transaction_id,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] rsp_rdata,
    output logic rsp_fault,
    output logic [SOURCE_ID_W-1:0] rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0] rsp_transaction_id,

    input logic ptw_req_valid,
    output logic ptw_req_ready,
    input logic [63:0] ptw_req_addr,
    output logic ptw_rsp_valid,
    input logic ptw_rsp_ready,
    output logic [63:0] ptw_rsp_rdata,
    output logic ptw_rsp_fault,

    input logic checkpoint_quiesce,
    output logic checkpoint_ack_valid,
    input logic checkpoint_ack_ready,
    output logic checkpoint_fault,
    output logic l1_drain_done,
    output logic l1_drain_fault,
    output logic l2_drain_ack_valid,
    output logic l2_drain_fault,
    output logic [31:0] probe_count,
    output logic [31:0] drain_request_count,

    input logic fault_enable,
    input logic [63:0] fault_addr,
    input logic fault_we_only,
    input logic init_we,
    input logic [63:0] init_addr,
    input logic [7:0] init_strb,
    input logic [63:0] init_wdata,
    output logic [31:0] accepted_count,
    output logic [31:0] response_count,
    output logic [31:0] write_count,
    output logic [31:0] read_count
);

  import lcvex_pkg::*;

  mem_req_t core_q, ptw_q;
  mem_rsp_t core_r, ptw_r;
  mem_req_t poc_q;
  mem_rsp_t poc_r;
  logic poc_req_valid, poc_req_ready, poc_rsp_valid, poc_rsp_ready;

  always_comb begin
    core_q = '0;
    core_q.addr = req_addr; core_q.we = req_we; core_q.strb = req_strb;
    core_q.wdata = req_wdata; core_q.maint = maint_op_t'(req_maint);
    core_q.bypass = req_bypass;
    ptw_q = '0; ptw_q.addr = ptw_req_addr;
    ptw_q.maint = MAINT_NONE; ptw_q.bypass = 1'b0;
    req_ready = core_req_ready_i;
    rsp_valid = core_rsp_valid_i; rsp_rdata = core_r.rdata;
    rsp_fault = core_r.fault; rsp_source_id = core_rsp_source_id_i;
    rsp_transaction_id = core_rsp_transaction_id_i;
    ptw_rsp_valid = ptw_rsp_valid_i; ptw_rsp_rdata = ptw_r.rdata;
    ptw_rsp_fault = ptw_r.fault;
  end

  logic core_req_ready_i, core_rsp_valid_i;
  logic [SOURCE_ID_W-1:0] core_rsp_source_id_i;
  logic [TRANSACTION_ID_W-1:0] core_rsp_transaction_id_i;
  logic ptw_rsp_valid_i;

  lcvex_l1_coherence #(
      .LINE_BYTES(LINE_BYTES), .L1_SETS(4), .L2_SETS(4), .L2_WAYS(2),
      .SOURCE_ID_W(SOURCE_ID_W), .TRANSACTION_ID_W(TRANSACTION_ID_W)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .core_req_valid(req_valid), .core_req(core_q),
      .core_req_ready(core_req_ready_i), .core_rsp_valid(core_rsp_valid_i),
      .core_rsp(core_r), .core_rsp_ready(rsp_ready),
      .core_source_id(req_source_id), .core_transaction_id(req_transaction_id),
      .core_rsp_source_id(core_rsp_source_id_i),
      .core_rsp_transaction_id(core_rsp_transaction_id_i),
      .ptw_req_valid(ptw_req_valid), .ptw_req(ptw_q),
      .ptw_req_ready(ptw_req_ready), .ptw_rsp_valid(ptw_rsp_valid_i),
      .ptw_rsp(ptw_r), .ptw_rsp_ready(ptw_rsp_ready),
      .poc_req_valid(poc_req_valid), .poc_req(poc_q),
      .poc_req_ready(poc_req_ready), .poc_rsp_valid(poc_rsp_valid),
      .poc_rsp(poc_r), .poc_rsp_ready(poc_rsp_ready),
      .checkpoint_quiesce(checkpoint_quiesce),
      .checkpoint_ack_valid(checkpoint_ack_valid),
      .checkpoint_ack_ready(checkpoint_ack_ready),
      .checkpoint_fault(checkpoint_fault), .l1_drain_done(l1_drain_done),
      .l1_drain_fault(l1_drain_fault),
      .l2_drain_ack_valid(l2_drain_ack_valid),
      .l2_drain_fault(l2_drain_fault)
  );

  lcvex_l1_d_wb_bfm #(.DEPTH(DEPTH), .BFM_SEED(32'hc0_56a)) bfm (
      .clk(clk), .rst_n(rst_n), .req_valid(poc_req_valid), .req(poc_q),
      .req_ready(poc_req_ready), .rsp_valid(poc_rsp_valid), .rsp(poc_r),
      .rsp_ready(poc_rsp_ready), .fault_enable(fault_enable),
      .fault_addr(fault_addr), .fault_we_only(fault_we_only),
      .init_we(init_we), .init_addr(init_addr), .init_strb(init_strb),
      .init_wdata(init_wdata), .accepted_count(accepted_count),
      .response_count(response_count), .write_count(write_count),
      .read_count(read_count)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      probe_count <= 0;
      drain_request_count <= 0;
    end else begin
      if (dut.l2_l1_probe_req_valid && dut.l2_l1_probe_req_ready)
        probe_count <= probe_count + 1'b1;
      if (dut.l2_drain_req_valid && dut.l2_drain_req_ready)
        drain_request_count <= drain_request_count + 1'b1;
    end
  end

endmodule
