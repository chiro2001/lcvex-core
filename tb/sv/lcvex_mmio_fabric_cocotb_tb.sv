// lcvex_mmio_fabric_cocotb_tb.sv
// C++ fabric 的 Cocotb 适配顶层：将 mem_req_t 展平为稳定的 VPI 端口。

`timescale 1ns/1ps

module lcvex_mmio_fabric_cocotb_tb (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        retire_valid,
    input  logic        req_valid,
    input  logic [63:0] req_addr,
    input  logic        req_we,
    input  logic [7:0]  req_strb,
    input  logic [63:0] req_wdata,
    output logic        req_accept,
    output logic        rsp_valid,
    input  logic        rsp_ready,
    output logic [63:0] rsp_rdata,
    output logic        rsp_fault,
    output logic        irq
);

  import lcvex_pkg::*;
  mem_req_t req;
  mem_rsp_t rsp;

  always_comb begin
    req = '{addr: req_addr, we: req_we, strb: req_strb, wdata: req_wdata,
            maint: MAINT_NONE, bypass: 1'b1};
  end

  lcvex_mmio_fabric dut (
      .clk, .rst_n, .retire_valid, .req_valid, .req, .req_accept,
      .rsp_valid, .rsp, .rsp_ready, .irq
  );

  assign rsp_rdata = rsp.rdata;
  assign rsp_fault = rsp.fault;

endmodule
