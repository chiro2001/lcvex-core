// Cocotb endpoint for the standalone B3-L2-WB module.
// It deliberately contains only the L2, its independent byte-memory BFM and
// flattened core-side signals; it is not connected to core, L1 or SoC.

`timescale 1ns/1ps

module lcvex_l2_wb_cocotb_tb #(
    parameter int LINE_BYTES = 64,
    parameter int SETS = 4,
    parameter int WAYS = 2,
    parameter int DEPTH = 1 << 16,
    parameter int SOURCE_ID_W = 4,
    parameter int TRANSACTION_ID_W = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         req_valid,
    output logic                         req_ready,
    input  logic [63:0]                  req_addr,
    input  logic                         req_we,
    input  logic [7:0]                   req_strb,
    input  logic [63:0]                  req_wdata,
    input  logic [3:0]                   req_maint,
    input  logic                         req_bypass,
    input  logic [SOURCE_ID_W-1:0]       req_source_id,
    input  logic [TRANSACTION_ID_W-1:0]  req_transaction_id,
    output logic                         rsp_valid,
    input  logic                         rsp_ready,
    output logic [63:0]                  rsp_rdata,
    output logic                         rsp_fault,
    output logic [SOURCE_ID_W-1:0]       rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0]  rsp_transaction_id,
    input  logic                         fault_enable,
    input  logic [63:0]                  fault_addr,
    input  logic                         fault_we_only,
    input  logic                         init_we,
    input  logic [63:0]                  init_addr,
    input  logic [7:0]                   init_strb,
    input  logic [63:0]                  init_wdata,
    output logic [31:0]                  accepted_count,
    output logic [31:0]                  response_count,
    output logic [31:0]                  write_count,
    output logic [31:0]                  read_count
);

  import lcvex_pkg::*;

  mem_req_t u_req;
  mem_rsp_t u_rsp;
  mem_req_t d_req;
  mem_rsp_t d_rsp;
  logic d_req_valid, d_req_ready, d_rsp_valid, d_rsp_ready;

  logic probe_req_valid, probe_req_ready, probe_rsp_valid, probe_rsp_ready;
  logic [63:0] probe_req_addr, probe_rsp_addr;
  logic [1:0] probe_req_cmd;
  logic probe_rsp_fault, probe_rsp_hit, probe_rsp_dirty;
  logic [LINE_BYTES*8-1:0] probe_rsp_data;
  logic [SOURCE_ID_W-1:0] probe_req_source_id, probe_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] probe_req_transaction_id;
  logic [TRANSACTION_ID_W-1:0] probe_rsp_transaction_id;
  logic [0:0] probe_rsp_owner, probe_rsp_sharers;

  always_comb begin
    u_req = '0;
    u_req.addr = req_addr;
    u_req.we = req_we;
    u_req.strb = req_strb;
    u_req.wdata = req_wdata;
    u_req.maint = maint_op_t'(req_maint);
    u_req.bypass = req_bypass;
  end

  assign rsp_rdata = u_rsp.rdata;
  assign rsp_fault = u_rsp.fault;

  assign probe_req_valid = 1'b0;
  assign probe_req_addr = '0;
  assign probe_req_cmd = '0;
  assign probe_req_source_id = '0;
  assign probe_req_transaction_id = '0;
  assign probe_rsp_ready = 1'b1;

  lcvex_l2_wb #(
      .LINE_BYTES(LINE_BYTES), .SETS(SETS), .WAYS(WAYS), .CORE_COUNT(1),
      .SOURCE_ID_W(SOURCE_ID_W), .TRANSACTION_ID_W(TRANSACTION_ID_W)
  ) dut (
      .clk, .rst_n,
      .u_req_valid(req_valid), .u_req, .u_req_ready(req_ready),
      .u_source_id(req_source_id), .u_transaction_id(req_transaction_id),
      .u_rsp_valid(rsp_valid), .u_rsp, .u_rsp_ready(rsp_ready),
      .u_rsp_source_id(rsp_source_id),
      .u_rsp_transaction_id(rsp_transaction_id),
      .d_req_valid, .d_req, .d_req_ready,
      .d_rsp_valid, .d_rsp, .d_rsp_ready,
      .probe_req_valid, .probe_req_ready, .probe_req_addr, .probe_req_cmd,
      .probe_req_source_id, .probe_req_transaction_id,
      .probe_rsp_valid, .probe_rsp_ready, .probe_rsp_fault, .probe_rsp_hit,
      .probe_rsp_dirty, .probe_rsp_data, .probe_rsp_addr,
      .probe_rsp_source_id, .probe_rsp_transaction_id,
      .probe_rsp_owner, .probe_rsp_sharers
  );

  lcvex_l2_wb_bfm #(.DEPTH(DEPTH), .BFM_SEED(32'h00b3_0551)) bfm (
      .clk, .rst_n, .req_valid(d_req_valid), .req(d_req),
      .req_ready(d_req_ready), .rsp_valid(d_rsp_valid), .rsp(d_rsp),
      .rsp_ready(d_rsp_ready), .fault_enable, .fault_addr, .fault_we_only,
      .init_we, .init_addr, .init_strb, .init_wdata,
      .accepted_count, .response_count, .write_count, .read_count
  );

endmodule
