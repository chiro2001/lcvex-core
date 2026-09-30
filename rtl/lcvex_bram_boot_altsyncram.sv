// lcvex_bram_boot_altsyncram.sv
// Standalone explicit altera_syncram M20K True Dual Port BRAM wrapper.
//
// This file is retained as the isolated/standalone Quartus artifact for the
// T-20260830-029/G2 matrix and for any experiment that wants to swap the BRAM
// without pulling in the behavioral fallback.  The main RTL wrapper
// (rtl/lcvex_bram_boot.sv) contains the same explicit implementation under
// `ifdef SYNTHESIS, so normal RTL filelists do not need to add this file.
//
// Limitations:
//   - 64-bit word-addressed storage; intra-word unaligned accesses are handled
//     by lane rotation, but accesses crossing an 8-byte word boundary return
//     fault in this explicit implementation.
//   - prog_we is retained only for port compatibility; real board content is
//     supplied through configuration stream/MIF.
//
// Quartus uses this when SYNTHESIS is defined.  Verilator should not compile
// this file (it is empty without SYNTHESIS).

`timescale 1ns/1ps

`ifdef SYNTHESIS
module lcvex_bram_boot_altsyncram #(
    parameter int          DEPTH_BYTES = 65536,
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
  localparam int AW = $clog2(DEPTH_BYTES);
  localparam int WADDR = AW - 3;
  localparam int NWORDS = DEPTH_BYTES / 8;
  localparam string INIT_FILE = (BOOT_MIF_FILE != "")
                              ? BOOT_MIF_FILE : BOOT_HEX_FILE;

  logic        rsp_pending;
  logic [63:0] rdata_r;
  logic        fault_r;
  logic [63:0] req_q;
  logic [63:0] dbg_q;

  wire [WADDR-1:0] req_waddr = req.addr[AW-1:3];
  wire [2:0]       req_off   = req.addr[2:0];
  wire [7:0]       rot_strb  = req.strb << req_off;
  wire [63:0]      rot_data  = req.wdata << (req_off * 8);
  wire [2:0]       req_hi    = hi_byte(req.strb);
  wire             req_cross = (req_off + req_hi) >= 8;
  wire [WADDR-1:0] dbg_waddr = dbg_addr[AW-1:3];
  wire [2:0]       dbg_off   = dbg_addr[2:0];

  wire             wr_en = req_accept && req.we && !req_cross;

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = fault_r;

  always_ff @(posedge clk) begin
    dbg_rdata <= dbg_q >> (dbg_off * 8);
  end

  altera_syncram #(
    .address_aclr_b       ("NONE"),
    .address_reg_b        ("CLOCK0"),
    .indata_reg_b         ("CLOCK0"),
    .byteena_reg_b        ("CLOCK0"),
    .rdcontrol_reg_b      ("CLOCK0"),
    .clock_enable_input_a ("BYPASS"),
    .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b("BYPASS"),
    .enable_ecc           ("FALSE"),
    .lpm_type             ("altera_syncram"),
    .numwords_a           (NWORDS),
    .numwords_b           (NWORDS),
    .operation_mode       ("BIDIR_DUAL_PORT"),
    .outdata_aclr_b       ("NONE"),
    .outdata_sclr_b       ("NONE"),
    .outdata_reg_a        ("UNREGISTERED"),
    .outdata_reg_b        ("UNREGISTERED"),
    .init_file            (INIT_FILE),
    .power_up_uninitialized("FALSE"),
    .ram_block_type       ("M20K"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .widthad_a            (WADDR),
    .widthad_b            (WADDR),
    .width_a              (64),
    .width_b              (64),
    .width_byteena_a      (8),
    .width_byteena_b      (8)
  ) u_ram (
    .address_a   (req_waddr),
    .address_b   (dbg_waddr),
    .clock0      (clk),
    .data_a      (rot_data),
    .wren_a      (wr_en),
    .q_a         (req_q),
    .q_b         (dbg_q),
    .aclr0       (1'b0),
    .aclr1       (1'b0),
    .address2_a  (1'b1),
    .address2_b  (1'b1),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_a   (rot_strb),
    .byteena_b   (8'hFF),
    .clock1      (1'b1),
    .clocken0    (1'b1),
    .clocken1    (1'b1),
    .clocken2    (1'b1),
    .clocken3    (1'b1),
    .data_b      (64'h0),
    .eccstatus   (),
    .eccencbypass(1'b0),
    .eccencparity(8'b0),
    .sclr        (1'b0),
    .rden_a      (1'b1),
    .rden_b      (1'b1),
    .wren_b      (1'b0)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_pending <= 1'b0;
      rdata_r     <= 64'd0;
      fault_r     <= 1'b0;
    end else begin
      if (req_accept) begin
        fault_r     <= (req.addr < SRAM_BASE) ||
                       (req.addr >= (SRAM_BASE + 64'(DEPTH_BYTES))) ||
                       ((64'(req.addr[AW-1:0]) + 64'(req_hi)) >=
                        64'(DEPTH_BYTES)) ||
                       (req_cross);
        rsp_pending <= 1'b1;
        if (!req.we && !req_cross) begin
          rdata_r <= req_q >> (req_off * 8);
        end else if (req.we && req_cross) begin
          // 跨 word 写不执行；fault 已置位，避免静默丢字节。
          rdata_r <= 64'd0;
        end
      end
      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;
      end
    end
  end

  function automatic logic [2:0] hi_byte(input logic [7:0] s);
    for (int i = 7; i >= 0; i--) begin
      if (s[i]) return i[2:0];
    end
    return 3'd0;
  endfunction

endmodule
`endif
