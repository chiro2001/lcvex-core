// Vendor-faithful timing stub for the synthesis-only boot-RAM wrapper.
//
// This is deliberately not a functional replacement for Intel's simulation
// library.  It models only the contract used by lcvex_bram_boot_altsyncram:
// address/data are sampled on clock0 and q_a/q_b update after that edge.  In
// particular, code in another posedge process observes the previous q value.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off MULTIDRIVEN */

module altera_syncram #(
    parameter string address_aclr_a = "NONE",
    parameter string address_aclr_b = "NONE",
    parameter string address_reg_a = "CLOCK0",
    parameter string address_reg_b = "CLOCK0",
    parameter string indata_reg_a = "CLOCK0",
    parameter string indata_reg_b = "CLOCK0",
    parameter string byteena_reg_a = "CLOCK0",
    parameter string byteena_reg_b = "CLOCK0",
    parameter string rdcontrol_reg_a = "CLOCK0",
    parameter string rdcontrol_reg_b = "CLOCK0",
    parameter string clock_enable_input_a = "BYPASS",
    parameter string clock_enable_input_b = "BYPASS",
    parameter string clock_enable_output_a = "BYPASS",
    parameter string clock_enable_output_b = "BYPASS",
    parameter string enable_ecc = "FALSE",
    parameter string lpm_type = "altera_syncram",
    parameter int numwords_a = 8,
    parameter int numwords_b = 8,
    parameter string operation_mode = "BIDIR_DUAL_PORT",
    parameter string outdata_aclr_b = "NONE",
    parameter string outdata_sclr_b = "NONE",
    parameter string outdata_reg_a = "UNREGISTERED",
    parameter string outdata_reg_b = "UNREGISTERED",
    parameter string init_file = "UNUSED",
    parameter string power_up_uninitialized = "FALSE",
    parameter string ram_block_type = "M20K",
    parameter string read_during_write_mode_mixed_ports = "DONT_CARE",
    parameter int widthad_a = 3,
    parameter int widthad_b = 3,
    parameter int width_a = 64,
    parameter int width_b = 64,
    parameter int width_byteena_a = 8,
    parameter int width_byteena_b = 8
) (
    input  logic [widthad_a-1:0]       address_a,
    input  logic [widthad_b-1:0]       address_b,
    input  logic                       clock0,
    input  logic [width_a-1:0]         data_a,
    input  logic                       wren_a,
    output logic [width_a-1:0]         q_a,
    output logic [width_b-1:0]         q_b,
    input  logic                       aclr0,
    input  logic                       aclr1,
    input  logic                       address2_a,
    input  logic                       address2_b,
    input  logic                       addressstall_a,
    input  logic                       addressstall_b,
    input  logic [width_byteena_a-1:0] byteena_a,
    input  logic [width_byteena_b-1:0] byteena_b,
    input  logic                       clock1,
    input  logic                       clocken0,
    input  logic                       clocken1,
    input  logic                       clocken2,
    input  logic                       clocken3,
    input  logic [width_b-1:0]         data_b,
    output logic [2:0]                 eccstatus,
    input  logic                       eccencbypass,
    input  logic [7:0]                 eccencparity,
    input  logic                       sclr,
    input  logic                       rden_a,
    input  logic                       rden_b,
    input  logic                       wren_b
);

  logic [width_a-1:0] mem [0:numwords_a-1];

  initial begin
    if (width_a != 64 || width_b != 64 || numwords_a != numwords_b) begin
      $fatal(1, "altera_syncram_sync_stub supports equal 64-bit ports only");
    end
    for (int i = 0; i < numwords_a; i++) begin
      // Word zero is intentionally non-zero so a stale power-up q is visible.
      mem[i] = 64'h8877_6655_4433_2211 ^ {32'd0, i[31:0]};
    end
    q_a = '0;
    q_b = '0;
    eccstatus = '0;
  end

  always_ff @(posedge clock0) begin
    if (clocken0) begin
      if (!addressstall_a) begin
        if (rden_a) q_a <= mem[address_a];
        if (wren_a) begin
          for (int lane = 0; lane < width_byteena_a; lane++) begin
            if (byteena_a[lane])
              mem[address_a][lane*8 +: 8] <= data_a[lane*8 +: 8];
          end
        end
      end
      if (!addressstall_b) begin
        if (rden_b) q_b <= mem[address_b];
        if (wren_b) begin
          for (int lane = 0; lane < width_byteena_b; lane++) begin
            if (byteena_b[lane])
              mem[address_b][lane*8 +: 8] <= data_b[lane*8 +: 8];
          end
        end
      end
    end
  end

endmodule
