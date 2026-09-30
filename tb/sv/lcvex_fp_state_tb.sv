// lcvex_fp_state_tb.sv
//
// P7-0 独立 SV 定向测试：
//   * V0-V31/FPCR/FPSR/CPACR reset；
//   * FPEN 四态和 EL0/EL1 权限矩阵；
//   * EC=0x07、IL=1、CV=1、COND=0xe 的完整 syndrome；
//   * FPCR/FPSR RAZ/WI mask 与 CPACR 非 FPEN 位保留；
//   * scalar-compatible FP effect 上限、拒绝和同拍原子更新；
//   * restore 与 scalar commit 同沿，restore 优先且 trap 无副作用。
//
// 该 testbench 故意只编译 lcvex_fp_state，不依赖 filelist 或 SoC 顶层。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_fp_state_tb;
  import lcvex_pkg::*;

  logic clk;
  logic rst_n = 1'b0;
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
  logic [127:0] difftest_restore_v [0:31];
  logic difftest_restore_sys_valid = 1'b0;
  logic [63:0] difftest_restore_cpacr_el1 = 64'd0;

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
      .sys_fpcr_we                 (sys_fpcr_we),
      .sys_fpcr_wdata              (sys_fpcr_wdata),
      .sys_fpsr_we                 (sys_fpsr_we),
      .sys_fpsr_wdata              (sys_fpsr_wdata),
      .sys_cpacr_we                (sys_cpacr_we),
      .sys_cpacr_wdata             (sys_cpacr_wdata),
      .sys_fpcr_write_accept       (sys_fpcr_write_accept),
      .sys_fpsr_write_accept       (sys_fpsr_write_accept),
      .sys_cpacr_write_accept      (sys_cpacr_write_accept),
      .sys_fp_access_blocked       (sys_fp_access_blocked),
      .sys_cpacr_write_blocked     (sys_cpacr_write_blocked),
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

  int errors = 0;

  task automatic fail(input string message);
    begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  task automatic idle_controls;
    begin
      fp_access_valid = 1'b0;
      sys_commit_valid = 1'b0;
      sys_fpcr_we = 1'b0;
      sys_fpsr_we = 1'b0;
      sys_cpacr_we = 1'b0;
      commit_valid = 1'b0;
      commit_vec_write_count = 3'd0;
      commit_fpcr_we = 1'b0;
      commit_fpsr_we = 1'b0;
      difftest_restore_fp_valid = 1'b0;
      difftest_restore_sys_valid = 1'b0;
    end
  endtask

  task automatic write_cpacr(input logic [1:0] fpen,
                             input logic [63:0] template);
    logic [63:0] expected;
    begin
      expected = template;
      expected[21:20] = fpen;
      current_el = 2'd1;
      sys_cpacr_wdata = expected;
      sys_commit_valid = 1'b1;
      sys_cpacr_we = 1'b1;
      #1;
      if (!sys_cpacr_write_accept)
        fail("EL1 CPACR write should be accepted");
      @(posedge clk);
      #1;
      sys_commit_valid = 1'b0;
      sys_cpacr_we = 1'b0;
      if (cpacr_el1_state !== expected)
        fail("CPACR full value/FPEN write mismatch");
    end
  endtask

  task automatic check_fp_access(input logic [1:0] el_value,
                                 input logic expected_allowed);
    begin
      current_el = el_value;
      fp_access_valid = 1'b1;
      #1;
      if (fp_access_allowed !== expected_allowed)
        fail("FPEN permission matrix mismatch");
      if (fp_trap_valid !== !expected_allowed)
        fail("FP access trap valid mismatch");
      if (!expected_allowed && fp_trap_code !== EXC_FP_ACCESS)
        fail("FP trap EC must be 0x07");
      if (!expected_allowed && fp_trap_esr !== ESR_FP_ACCESS_TRAP)
        fail("FP trap ESR must contain EC=0x07 and IL=1");
      if (expected_allowed && (fp_trap_code !== 32'd0 ||
                               fp_trap_esr !== 32'd0))
        fail("allowed FP access must not expose a trap syndrome");
      fp_access_valid = 1'b0;
      #1;
    end
  endtask

  initial begin
    logic [63:0] cpacr_template;
    logic [63:0] restore_cpacr;
    cpacr_template = 64'hA5A5_5A5A_0000_1234;
    restore_cpacr = 64'h5AA5_1357_00C0_FFEE;
    clk = 1'b0;

    $display("=== lcvex_fp_state_tb: P7-0 state/FPEN/trap ===");
    idle_controls();
    current_el = 2'd1;
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    #1;
    if (fpcr_state !== 32'd0 || fpsr_state !== 32'd0 ||
        cpacr_el1_state !== 64'd0 || cpacr_fpen !== 2'b00)
      fail("reset FPCR/FPSR/CPACR state mismatch");
    if (fpcr_read_data !== 32'd0 || fpsr_read_data !== 32'd0 ||
        cpacr_read_data !== 64'd0)
      fail("reset MRS read data mismatch");
    for (int i = 0; i < 32; i++) begin
      if (v_state[i] !== 128'd0)
        fail("reset V state must be all zero");
    end
    rst_n = 1'b1;

    // FPEN 四态：EL0 只有 11 放行；EL1 放行 01/11。
    for (int f = 0; f < 4; f++) begin
      write_cpacr(f[1:0], cpacr_template);
      check_fp_access(2'd0, (f == 3));
      check_fp_access(2'd1, (f == 1) || (f == 3));
    end

    // CPACR 的 EL1-only 权限，且不能因为 FPEN owned mask 丢失其它位。
    write_cpacr(2'b11, cpacr_template);
    current_el = 2'd0;
    sys_cpacr_wdata = 64'hFFFF_FFFF_FFFF_FFFF;
    sys_commit_valid = 1'b1;
    sys_cpacr_we = 1'b1;
    #1;
    if (sys_cpacr_write_accept || !sys_cpacr_write_blocked)
      fail("EL0 CPACR write must be blocked");
    @(posedge clk);
    #1;
    sys_commit_valid = 1'b0;
    sys_cpacr_we = 1'b0;
    if (cpacr_el1_state[63:22] !== cpacr_template[63:22] ||
        cpacr_el1_state[19:0] !== cpacr_template[19:0])
      fail("blocked EL0 CPACR write changed non-FPEN state");

    // FPCR/FPSR system writes apply exact RAZ/WI masks.
    current_el = 2'd1;
    fp_access_valid = 1'b1;
    sys_commit_valid = 1'b1;
    sys_fpcr_we = 1'b1;
    sys_fpcr_wdata = 32'hFFFF_FFFF;
    #1;
    if (!sys_fpcr_write_accept || sys_fp_access_blocked)
      fail("enabled FPCR write should be accepted");
    @(posedge clk);
    #1;
    sys_commit_valid = 1'b0;
    sys_fpcr_we = 1'b0;
    if (fpcr_state !== FPCR_P7_WRMASK || fpcr_read_data !== FPCR_P7_WRMASK)
      fail("FPCR mask mismatch");

    sys_commit_valid = 1'b1;
    sys_fpsr_we = 1'b1;
    sys_fpsr_wdata = 32'hFFFF_FFFF;
    #1;
    if (!sys_fpsr_write_accept || sys_fp_access_blocked)
      fail("enabled FPSR write should be accepted");
    @(posedge clk);
    #1;
    sys_commit_valid = 1'b0;
    sys_fpsr_we = 1'b0;
    fp_access_valid = 1'b0;
    if (fpsr_state !== FPSR_P7_WRMASK || fpsr_read_data !== FPSR_P7_WRMASK)
      fail("FPSR mask mismatch");

    // 禁止的 FP access 同时带 effect 时，trap 和 malformed access 都不能
    // 更新 V/FP state。
    write_cpacr(2'b00, cpacr_template);
    current_el = 2'd0;
    fp_access_valid = 1'b1;
    commit_valid = 1'b1;
    commit_vec_write_count = 3'd1;
    commit_vec_rd0 = 5'd3;
    commit_vec_wdata0 = 128'hDEAD_BEEF_0123_4567_89AB_CDEF_0BAD_F00D;
    #1;
    if (!fp_trap_valid || fp_trap_code !== EXC_FP_ACCESS ||
        fp_trap_esr !== ESR_FP_ACCESS_TRAP)
      fail("denied FP effect must expose EC=0x07 syndrome");
    if (commit_effect_valid || !commit_effect_error)
      fail("denied FP effect must be rejected");
    @(posedge clk);
    #1;
    idle_controls();
    if (v_state[3] !== 128'd0 || fpcr_state !== FPCR_P7_WRMASK ||
        fpsr_state !== FPSR_P7_WRMASK)
      fail("FP trap instruction changed architectural state");

    // 单个 effect：与 scalar commit 同一边界写入 raw 128-bit V。
    write_cpacr(2'b11, cpacr_template);
    current_el = 2'd1;
    fp_access_valid = 1'b1;
    commit_valid = 1'b1;
    commit_vec_write_count = 3'd1;
    commit_vec_rd0 = 5'd7;
    commit_vec_wdata0 = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;
    #1;
    if (!commit_effect_valid || commit_effect_error ||
        commit_effect_vec_write_count !== 3'd1 ||
        commit_effect_vec_rd0 !== 5'd7 ||
        commit_effect_vec_wdata0 !== commit_vec_wdata0)
      fail("single V commit effect mismatch");
    @(posedge clk);
    #1;
    idle_controls();
    if (v_state[7] !== 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210)
      fail("single V raw commit mismatch");

    // ABI 预留 4V effect，所有写入仍属于同一沿。
    fp_access_valid = 1'b1;
    commit_valid = 1'b1;
    commit_vec_write_count = 3'd4;
    commit_vec_rd0 = 5'd1;
    commit_vec_rd1 = 5'd2;
    commit_vec_rd2 = 5'd4;
    commit_vec_rd3 = 5'd8;
    commit_vec_wdata0 = 128'h1;
    commit_vec_wdata1 = 128'h2;
    commit_vec_wdata2 = 128'h4;
    commit_vec_wdata3 = 128'h8;
    commit_fpcr_we = 1'b1;
    commit_fpcr_wdata = 32'hFFFF_FFFF;
    commit_fpsr_we = 1'b1;
    commit_fpsr_wdata = 32'hFFFF_FFFF;
    #1;
    if (!commit_effect_valid || commit_effect_error ||
        commit_effect_vec_write_count !== 3'd4 ||
        !commit_effect_fpcr_we || !commit_effect_fpsr_we)
      fail("four-V/FPCR/FPSR effect boundary mismatch");
    @(posedge clk);
    #1;
    idle_controls();
    if (v_state[1] !== 128'h1 || v_state[2] !== 128'h2 ||
        v_state[4] !== 128'h4 || v_state[8] !== 128'h8 ||
        fpcr_state !== FPCR_P7_WRMASK || fpsr_state !== FPSR_P7_WRMASK)
      fail("same-edge four-V/FP state update mismatch");

    // 超过 4V 和重复 destination 都必须拒绝，不能静默截断或 last-write-win。
    fp_access_valid = 1'b1;
    commit_valid = 1'b1;
    commit_vec_write_count = 3'd5;
    commit_vec_rd0 = 5'd9;
    commit_vec_wdata0 = 128'h99;
    #1;
    if (!commit_effect_error || commit_effect_valid)
      fail("vec_write_count>4 must be rejected");
    @(posedge clk);
    #1;
    idle_controls();
    if (v_state[9] !== 128'd0)
      fail("over-limit V effect was silently applied");

    fp_access_valid = 1'b1;
    commit_valid = 1'b1;
    commit_vec_write_count = 3'd2;
    commit_vec_rd0 = 5'd10;
    commit_vec_rd1 = 5'd10;
    commit_vec_wdata0 = 128'hAA;
    commit_vec_wdata1 = 128'hBB;
    #1;
    if (!commit_effect_error || commit_effect_valid)
      fail("duplicate V destination must be rejected");
    @(posedge clk);
    #1;
    idle_controls();
    if (v_state[10] !== 128'd0)
      fail("duplicate V effect was silently applied");

    // FPEN 关闭不应阻断没有 FP effect 的旧 scalar commit。
    write_cpacr(2'b00, cpacr_template);
    current_el = 2'd0;
    commit_valid = 1'b1;
    #1;
    if (commit_effect_valid || commit_effect_error)
      fail("pure scalar commit must remain FPEN-independent");
    @(posedge clk);
    #1;
    idle_controls();

    // restore 与同拍 commit 冲突时 restore 优先；V raw 全 128 bit 保留，
    // FPCR/FPSR 仍执行 mask，CPACR 则完整保留非 FPEN 位。
    for (int i = 0; i < 32; i++) begin
      difftest_restore_v[i] = {64'h1000_0000_0000_0000 + 64'(i),
                               64'h2000_0000_0000_0000 + 64'(i)};
    end
    difftest_restore_fpcr = 32'hFFFF_FFFF;
    difftest_restore_fpsr = 32'hFFFF_FFFF;
    difftest_restore_cpacr_el1 = restore_cpacr;
    difftest_restore_fp_valid = 1'b1;
    difftest_restore_sys_valid = 1'b1;
    commit_valid = 1'b1;
    fp_access_valid = 1'b1;
    commit_vec_write_count = 3'd1;
    commit_vec_rd0 = 5'd31;
    commit_vec_wdata0 = 128'hFFFF;
    #1;
    if (commit_effect_valid || commit_effect_error)
      fail("restore edge must suppress scalar FP effect");
    @(posedge clk);
    #1;
    idle_controls();
    if (fpcr_state !== FPCR_P7_WRMASK || fpsr_state !== FPSR_P7_WRMASK ||
        cpacr_el1_state !== restore_cpacr)
      fail("restore FP/system scalar state mismatch");
    for (int i = 0; i < 32; i++) begin
      if (v_state[i] !== difftest_restore_v[i])
        fail("restore V raw state mismatch");
    end

    if (errors == 0) begin
      $display("PASS: lcvex_fp_state_tb P7-0 定向场景全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errors);
    end
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
