// lcvex_bram_boot_shim.sv
// B5-SoC/Boot: compatibility shim around the main BRAM selection wrapper.
//
// The main rtl/lcvex_bram_boot.sv already contains the SYNTHESIS-aware
// selection (explicit altera_syncram M20K for Quartus, behavioral fallback
// for Verilator).  This file provides a distinctly named wrapper for
// experimental/standalone filelists that want an explicit module boundary
// without conflicting with the normal module name.
//
// It is intentionally named lcvex_bram_boot_shim, not lcvex_bram_boot, so
// that normal RTL filelists can include both this file and
// rtl/lcvex_bram_boot.sv without a duplicate module definition.

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNSIGNED */

module lcvex_bram_boot_shim #(
    parameter int          DEPTH_BYTES = 1 << 16,
    parameter logic [63:0] SRAM_BASE   = 64'h0,
    parameter string       BOOT_HEX_FILE = "",
    parameter string       BOOT_MIF_FILE = ""
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

  import lcvex_pkg::*;

  lcvex_bram_boot #(
      .DEPTH_BYTES(DEPTH_BYTES),
      .SRAM_BASE(SRAM_BASE),
      .BOOT_HEX_FILE(BOOT_HEX_FILE),
      .BOOT_MIF_FILE(BOOT_MIF_FILE)
  ) u_main (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req),
      .req_accept(req_accept), .rsp_valid(rsp_valid),
      .rsp(rsp), .rsp_ready(rsp_ready),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .prog_strb(prog_strb), .prog_wdata(prog_wdata),
      .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata)
  );

endmodule
