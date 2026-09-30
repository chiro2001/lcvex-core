// Optional simulator test for the Quartus-generated functional/post-map
// netlist.  The remote probe invokes this only when an installed HDL
// simulator and compatible primitive models are discoverable.  Otherwise the
// synthesis warning contract remains the explicit fail-closed evidence.

`timescale 1ns/1ps

module lcvex_logic_imm_quartus_postmap_tb;
  reg [31:0] probe_insn0;
  reg [31:0] probe_insn1;
  reg [63:0] probe_gpr0;
  wire probe_valid0, probe_valid1, probe_exc0, probe_exc1;
  wire [63:0] probe_mask0, probe_mask1;
  wire [63:0] probe_result0, probe_result1;
  wire [4:0] probe_wb_rd0, probe_wb_rd1;

  lcvex_logic_imm_quartus_probe_top dut (
    .probe_insn0(probe_insn0), .probe_insn1(probe_insn1),
    .probe_gpr0(probe_gpr0), .probe_valid0(probe_valid0),
    .probe_valid1(probe_valid1), .probe_exc0(probe_exc0),
    .probe_exc1(probe_exc1), .probe_mask0(probe_mask0),
    .probe_mask1(probe_mask1), .probe_result0(probe_result0),
    .probe_result1(probe_result1), .probe_wb_rd0(probe_wb_rd0),
    .probe_wb_rd1(probe_wb_rd1)
  );

  task automatic check(input condition, input [1023:0] message);
    if (!condition) begin
      $display("LOGIC_IMM_POSTMAP_SEMANTIC_MISMATCH %0s", message);
      $fatal(1);
    end
  endtask

  initial begin
    probe_gpr0 = 64'h000000000000a43f;
    probe_insn0 = 32'h12003c06;
    probe_insn1 = 32'h12001c00;
    #1;
    check(probe_valid0 && !probe_exc0, "opcode_12003c06_valid");
    check(probe_valid1 && !probe_exc1, "opcode_12001c00_valid");
    check(probe_mask0 == 64'h0000ffff0000ffff, "opcode_12003c06_mask");
    check(probe_mask1 == 64'h000000ff000000ff, "opcode_12001c00_mask");
    check(probe_result0 == 64'h000000000000a43f,
          "opcode_12003c06_result_A43F");
    check(probe_result1 == 64'h000000000000003f,
          "opcode_12001c00_result_3F");
    check(probe_wb_rd0 == 5'd6, "opcode_12003c06_rd");
    check(probe_wb_rd1 == 5'd0, "opcode_12001c00_rd");
    $display("LOGIC_IMM_POSTMAP_SEMANTIC_PASS exact=A43F/3F");
    $finish;
  end
endmodule
