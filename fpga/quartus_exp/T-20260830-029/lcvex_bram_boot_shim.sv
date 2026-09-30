// Isolated SoC-only experiment shim: replace behavioral lcvex_bram_boot
// with the explicit altera_syncram wrapper.  Same ports/parameters.
`timescale 1ns/1ps
module lcvex_bram_boot #(
    parameter int          DEPTH_BYTES = 1 << 20,
    parameter logic [63:0] SRAM_BASE   = 64'h0,
    parameter string       BOOT_HEX_FILE = ""
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    input  logic                prog_we,
    input  logic [63:0]         prog_addr,
    input  logic [7:0]          prog_strb,
    input  logic [63:0]         prog_wdata,
    input  logic [31:0]         dbg_addr,
    output logic [63:0]         dbg_rdata
);
  lcvex_bram_boot_altsyncram #(
      .DEPTH_BYTES(DEPTH_BYTES),
      .SRAM_BASE(SRAM_BASE),
      .BOOT_HEX_FILE(BOOT_HEX_FILE)
  ) u_exp (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req),
      .req_accept(req_accept), .rsp_valid(rsp_valid),
      .rsp(rsp), .rsp_ready(rsp_ready),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .prog_strb(prog_strb), .prog_wdata(prog_wdata),
      .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata)
  );
endmodule
