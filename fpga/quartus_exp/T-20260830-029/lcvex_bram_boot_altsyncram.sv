// lcvex_bram_boot_altsyncram.sv
// Isolated experiment wrapper: explicit altera_syncram BIDIR_DUAL_PORT.
// Unlike the behavioral byte-addressed memory, this wrapper uses a 64-bit
// word-aligned memory (DEPTH_BYTES/8 words). It is intended for Quartus
// M20K inference/resource measurement and preserves the same ports; for
// strict unaligned byte-access equivalence the behavioral module remains
// authoritative. Writes are mirrored through port A; port B provides the
// dbg read port.
`timescale 1ns/1ps
module lcvex_bram_boot_altsyncram #(
    parameter int          DEPTH_BYTES = 1048576,
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
  import lcvex_pkg::*;
  localparam int AW = $clog2(DEPTH_BYTES);
  localparam int WADDR = AW - 3;
  localparam int NWORDS = DEPTH_BYTES / 8;

  logic        rsp_pending;
  logic [63:0] rdata_r;
  logic        fault_r;
  logic [63:0] req_q;
  logic [63:0] dbg_q;

  wire [WADDR-1:0] req_waddr = req.addr[AW-1:3];
  wire [WADDR-1:0] dbg_waddr = dbg_addr[AW-1:3];
  wire             wr_en = req_accept && req.we;

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = fault_r;

  always_ff @(posedge clk) begin
    dbg_rdata <= dbg_q;
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
    .power_up_uninitialized("TRUE"),
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
    .data_a      (req.wdata),
    .wren_a      (wr_en),
    .q_a         (req_q),
    .q_b         (dbg_q),
    .aclr0       (1'b0),
    .aclr1       (1'b0),
    .address2_a  (1'b1),
    .address2_b  (1'b1),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_a   (req.strb),
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
                       ((64'(req.addr[AW-1:0]) + 64'(hi_byte(req.strb))) >=
                        64'(DEPTH_BYTES));
        rsp_pending <= 1'b1;
        if (!req.we) begin
          rdata_r <= req_q;
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
