// lcvex_cache_data_ram.sv
//
// 64-byte cache-line data RAM abstraction.  The cache controllers are
// single-blocking and therefore need only one synchronous read/write port.
// The simulation implementation is the byte-accurate reference model; the
// Quartus implementation is an explicit 512-bit altera_syncram intended for
// Arria 10 M20K inference.
//
// The RAM contents are deliberately not reset.  Cache metadata (valid/tag/
// dirty) is the visibility boundary, so an invalid line never exposes stale
// power-up data.  rd_valid is reset because it is transaction state, not RAM
// contents.  A read request is sampled on a rising edge and rd_valid/data are
// presented for the following cycle.  A write is sampled on the same edge as
// wr_en and uses one byte-enable bit per byte in the packed line.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_cache_data_ram #(
    parameter int LINE_BYTES  = 64,
    parameter int DEPTH_WORDS = 64,
    parameter int ADDR_W      = $clog2(DEPTH_WORDS > 1 ? DEPTH_WORDS : 2)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         rd_en,
    input  logic [ADDR_W-1:0]            rd_addr,
    output logic                         rd_valid,
    output logic [LINE_BYTES*8-1:0]      rd_data,
    input  logic                         wr_en,
    input  logic [ADDR_W-1:0]            wr_addr,
    input  logic [LINE_BYTES-1:0]        wr_byte_en,
    input  logic [LINE_BYTES*8-1:0]      wr_data
);

  localparam int DATA_BITS = LINE_BYTES * 8;
`ifdef SYNTHESIS

  // address_reg_a gives the explicit synchronous-read contract: the address
  // is sampled at CLOCK0, while the unregistered q output becomes valid in
  // the following cycle.  The cache-side rd_valid register is aligned to
  // that cycle.  DONT_CARE is the legal Arria 10 single-port mode for a
  // simultaneous read/write.  The blocking cache controllers serialize such
  // operations, so no architectural result depends on that unspecified
  // collision; a following read observes the committed write.
  logic [DATA_BITS-1:0] ram_q;

  altera_syncram #(
      .address_aclr_a                    ("NONE"),
      .address_reg_a                     ("CLOCK0"),
      .byte_size                         (8),
      .byteena_reg_a                     ("CLOCK0"),
      .clock_enable_input_a              ("BYPASS"),
      .clock_enable_output_a             ("BYPASS"),
      .enable_ecc                        ("FALSE"),
      .indata_reg_a                      ("CLOCK0"),
      .lpm_type                          ("altera_syncram"),
      .numwords_a                        (DEPTH_WORDS),
      .operation_mode                    ("SINGLE_PORT"),
      .outdata_aclr_a                    ("NONE"),
      .outdata_sclr_a                    ("NONE"),
      .outdata_reg_a                     ("UNREGISTERED"),
      .power_up_uninitialized             ("TRUE"),
      .ram_block_type                     ("M20K"),
      .read_during_write_mode_port_a      ("DONT_CARE"),
      .rdcontrol_reg_a                    ("CLOCK0"),
      .widthad_a                          (ADDR_W),
      .width_a                            (DATA_BITS),
      .width_byteena_a                    (LINE_BYTES)
  ) u_ram (
      .address_a                          (wr_en ? wr_addr : rd_addr),
      .clock0                             (clk),
      .data_a                             (wr_data),
      .wren_a                             (wr_en),
      .q_a                                (ram_q),
      .aclr0                              (1'b0),
      .aclr1                              (1'b0),
      .addressstall_a                     (1'b0),
      .byteena_a                          (wr_byte_en),
      .clocken0                           (1'b1),
      .clocken1                           (1'b1),
      .clocken2                           (1'b1),
      .clocken3                           (1'b1),
      .eccstatus                          (),
      .eccencbypass                       (1'b0),
      .eccencparity                       (8'b0),
      .rden_a                             (rd_en),
      .sclr                               (1'b0)
  );

  assign rd_data = ram_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rd_valid <= 1'b0;
    else        rd_valid <= rd_en;
  end

`else

  // Simulation/reference path: packed lines preserve exact byte-enable
  // semantics while keeping the same synchronous latency as M20K.
  logic [DATA_BITS-1:0] mem [0:DEPTH_WORDS-1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid <= 1'b0;
      rd_data  <= '0;
    end else begin
      rd_valid <= rd_en;
      if (rd_en) rd_data <= mem[rd_addr];
      if (wr_en) begin
        for (int i = 0; i < LINE_BYTES; i++) begin
          if (wr_byte_en[i]) mem[wr_addr][i*8 +: 8] <= wr_data[i*8 +: 8];
        end
      end
    end
  end

`endif

endmodule
