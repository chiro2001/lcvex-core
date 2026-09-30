// lcvex_fp_state_cocotb_tb.sv
// Cocotb wrapper for the standalone P7-0 FP state boundary.
// The V array is flattened only at this test boundary; the RTL module keeps
// V0-V31 as independent 128-bit architectural registers.

`timescale 1ns/1ps

module lcvex_fp_state_cocotb_tb;
  logic clk;
  logic rst_n = 1'b0;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  logic [1:0] current_el = 2'd1;
  logic fp_access_valid = 1'b0;
  logic fp_access_allowed;
  logic fp_trap_valid;
  logic [31:0] fp_trap_code;
  logic [31:0] fp_trap_esr;

  logic [31:0] fpcr_state;
  logic [31:0] fpsr_state;
  logic [63:0] cpacr_el1_state;
  logic [1:0] cpacr_fpen;
  logic [31:0] fpcr_read_data;
  logic [31:0] fpsr_read_data;
  logic [63:0] cpacr_read_data;
  logic [127:0] v_state [0:31];
  logic [4095:0] v_state_flat;

  logic sys_commit_valid = 1'b0;
  logic sys_fpcr_we = 1'b0;
  logic [31:0] sys_fpcr_wdata = 32'd0;
  logic sys_fpsr_we = 1'b0;
  logic [31:0] sys_fpsr_wdata = 32'd0;
  logic sys_cpacr_we = 1'b0;
  logic [63:0] sys_cpacr_wdata = 64'd0;
  logic sys_fpcr_write_accept;
  logic sys_fpsr_write_accept;
  logic sys_cpacr_write_accept;
  logic sys_fp_access_blocked;
  logic sys_cpacr_write_blocked;

  logic commit_valid = 1'b0;
  logic [2:0] commit_vec_write_count = 3'd0;
  logic [4:0] commit_vec_rd0 = 5'd0;
  logic [4:0] commit_vec_rd1 = 5'd0;
  logic [4:0] commit_vec_rd2 = 5'd0;
  logic [4:0] commit_vec_rd3 = 5'd0;
  logic [127:0] commit_vec_wdata0 = 128'd0;
  logic [127:0] commit_vec_wdata1 = 128'd0;
  logic [127:0] commit_vec_wdata2 = 128'd0;
  logic [127:0] commit_vec_wdata3 = 128'd0;
  logic commit_fpcr_we = 1'b0;
  logic [31:0] commit_fpcr_wdata = 32'd0;
  logic commit_fpsr_we = 1'b0;
  logic [31:0] commit_fpsr_wdata = 32'd0;
  logic commit_effect_valid;
  logic commit_effect_error;
  logic [2:0] commit_effect_vec_write_count;
  logic [4:0] commit_effect_vec_rd0;
  logic [4:0] commit_effect_vec_rd1;
  logic [4:0] commit_effect_vec_rd2;
  logic [4:0] commit_effect_vec_rd3;
  logic [127:0] commit_effect_vec_wdata0;
  logic [127:0] commit_effect_vec_wdata1;
  logic [127:0] commit_effect_vec_wdata2;
  logic [127:0] commit_effect_vec_wdata3;
  logic commit_effect_fpcr_we;
  logic [31:0] commit_effect_fpcr_wdata;
  logic commit_effect_fpsr_we;
  logic [31:0] commit_effect_fpsr_wdata;

  logic difftest_restore_fp_valid = 1'b0;
  logic [31:0] difftest_restore_fpcr = 32'd0;
  logic [31:0] difftest_restore_fpsr = 32'd0;
  logic [4095:0] difftest_restore_v_flat = 4096'd0;
  logic [127:0] difftest_restore_v [0:31];
  logic difftest_restore_sys_valid = 1'b0;
  logic [63:0] difftest_restore_cpacr_el1 = 64'd0;

  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin : g_v_flatten
      assign difftest_restore_v[i] = difftest_restore_v_flat[i*128 +: 128];
      assign v_state_flat[i*128 +: 128] = v_state[i];
    end
  endgenerate

  lcvex_fp_state dut (
      .clk                         (clk),
      .rst_n                       (rst_n),
      .current_el                  (current_el),
      .fp_access_valid             (fp_access_valid),
      .fp_access_allowed           (fp_access_allowed),
      .fp_trap_valid               (fp_trap_valid),
      .fp_trap_code                (fp_trap_code),
      .fp_trap_esr                 (fp_trap_esr),
      .fpcr_state                  (fpcr_state),
      .fpsr_state                  (fpsr_state),
      .cpacr_el1_state             (cpacr_el1_state),
      .cpacr_fpen                  (cpacr_fpen),
      .fpcr_read_data              (fpcr_read_data),
      .fpsr_read_data              (fpsr_read_data),
      .cpacr_read_data             (cpacr_read_data),
      .v_state                     (v_state),
      .sys_commit_valid            (sys_commit_valid),
      .sys_fpcr_we                (sys_fpcr_we),
      .sys_fpcr_wdata             (sys_fpcr_wdata),
      .sys_fpsr_we                (sys_fpsr_we),
      .sys_fpsr_wdata             (sys_fpsr_wdata),
      .sys_cpacr_we               (sys_cpacr_we),
      .sys_cpacr_wdata            (sys_cpacr_wdata),
      .sys_fpcr_write_accept      (sys_fpcr_write_accept),
      .sys_fpsr_write_accept      (sys_fpsr_write_accept),
      .sys_cpacr_write_accept     (sys_cpacr_write_accept),
      .sys_fp_access_blocked      (sys_fp_access_blocked),
      .sys_cpacr_write_blocked    (sys_cpacr_write_blocked),
      .commit_valid                (commit_valid),
      .commit_vec_write_count      (commit_vec_write_count),
      .commit_vec_rd0              (commit_vec_rd0),
      .commit_vec_rd1              (commit_vec_rd1),
      .commit_vec_rd2              (commit_vec_rd2),
      .commit_vec_rd3              (commit_vec_rd3),
      .commit_vec_wdata0           (commit_vec_wdata0),
      .commit_vec_wdata1           (commit_vec_wdata1),
      .commit_vec_wdata2           (commit_vec_wdata2),
      .commit_vec_wdata3           (commit_vec_wdata3),
      .commit_fpcr_we              (commit_fpcr_we),
      .commit_fpcr_wdata           (commit_fpcr_wdata),
      .commit_fpsr_we              (commit_fpsr_we),
      .commit_fpsr_wdata           (commit_fpsr_wdata),
      .commit_effect_valid         (commit_effect_valid),
      .commit_effect_error         (commit_effect_error),
      .commit_effect_vec_write_count(commit_effect_vec_write_count),
      .commit_effect_vec_rd0       (commit_effect_vec_rd0),
      .commit_effect_vec_rd1       (commit_effect_vec_rd1),
      .commit_effect_vec_rd2       (commit_effect_vec_rd2),
      .commit_effect_vec_rd3       (commit_effect_vec_rd3),
      .commit_effect_vec_wdata0    (commit_effect_vec_wdata0),
      .commit_effect_vec_wdata1    (commit_effect_vec_wdata1),
      .commit_effect_vec_wdata2    (commit_effect_vec_wdata2),
      .commit_effect_vec_wdata3    (commit_effect_vec_wdata3),
      .commit_effect_fpcr_we       (commit_effect_fpcr_we),
      .commit_effect_fpcr_wdata    (commit_effect_fpcr_wdata),
      .commit_effect_fpsr_we       (commit_effect_fpsr_we),
      .commit_effect_fpsr_wdata    (commit_effect_fpsr_wdata),
      .difftest_restore_fp_valid   (difftest_restore_fp_valid),
      .difftest_restore_fpcr       (difftest_restore_fpcr),
      .difftest_restore_fpsr       (difftest_restore_fpsr),
      .difftest_restore_v          (difftest_restore_v),
      .difftest_restore_sys_valid  (difftest_restore_sys_valid),
      .difftest_restore_cpacr_el1 (difftest_restore_cpacr_el1)
  );
endmodule
