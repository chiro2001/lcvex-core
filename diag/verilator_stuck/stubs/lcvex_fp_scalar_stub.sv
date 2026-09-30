// Diagnostic stub: identical port list to rtl/lcvex_fp_scalar.sv,
// but no complex 256-bit rounding datapath. Used only to measure
// diagnostic elaboration cost attributable to lcvex_fp_scalar.
`timescale 1ns/1ps
module lcvex_fp_scalar (
    input  logic                  valid,
    input  lcvex_pkg::fp_op_t     op,
    input  logic                  is_double,
    input  logic                  is_half,
    input  logic                  fcvt_dst_half,
    input  logic [2:0]            rint_mode,
    input  logic [63:0]           operand_a,
    input  logic [63:0]           operand_b,
    input  logic [63:0]           operand_c,
    input  logic [63:0]           conv_int,
    input  logic [6:0]            conv_shift,
    input  logic                  conv_is_32,
    input  logic [31:0]           fpcr,
    input  logic                  compare_zero,
    input  logic                  signal_all_nans,
    output logic [63:0]           result,
    output logic [63:0]           int_result,
    output logic [31:0]           fpsr_flags,
    output logic [3:0]            cmp_nzcv
);
  import lcvex_pkg::*;
  always_comb begin
    result = valid ? operand_a : 64'd0;
    int_result = valid ? operand_a : 64'd0;
    fpsr_flags = 32'd0;
    cmp_nzcv = 4'd0;
  end
endmodule
