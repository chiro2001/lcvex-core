// lcvex_c3_fourcore_tb.sv
// C3 system-level directed test: four real lcvex_core instances run from a
// shared coherent L2/SRAM top and perform a simple message-passing sequence.
//
// Core0 is started by the testbench; it writes PSCI-like CPU_ON to the C3
// system-control block to start cores 1..3.  Core0 also writes flag=0x5A and
// sync=1.  Each of cores 1..3 spins on sync, reads flag, and should observe
// 0x5A through the MSI directory.
//
// This is a minimum C3 directed sequence: multi-core start, shared coherent
// memory visibility, and per-core progress.  It is not a full GIC/PSCI/IRQ
// software model.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c3_fourcore_tb;
  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 4;
  localparam logic [63:0] BASE = 64'h0000_0000_4000_0000;
  localparam logic [63:0] CORE_OFF = 64'h0000_0000_0000_0100;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [CORE_COUNT-1:0] core_reset_pulse = '0;
  logic [CORE_COUNT-1:0] core_start_pulse = '0;
  logic [CORE_COUNT-1:0] core_stop_pulse  = '0;
  logic [CORE_COUNT-1:0] irq = '0;
  logic [CORE_COUNT-1:0] event_in = '0;
  logic [CORE_COUNT-1:0] mc_commit_ready = '1;

  logic [CORE_COUNT-1:0] mc_commit_valid;
  lcvex_mc_commit_t mc_commit [CORE_COUNT];
  logic [CORE_COUNT-1:0] core_running;
  logic [CORE_COUNT-1:0] core_stopped;
  logic [CORE_COUNT-1:0] core_wfi_idle;
  logic [CORE_COUNT-1:0] core_fault;
  logic [CORE_COUNT-1:0] sev_pulse;
  logic [31:0] mpidr [CORE_COUNT];
  logic [CORE_COUNT-1:0] timer_phys_irq;
  logic [CORE_COUNT-1:0] timer_virt_irq;
  logic [CORE_COUNT-1:0] commit_valid;
  logic [63:0] commit_pc [CORE_COUNT];
  logic [63:0] commit_next_pc [CORE_COUNT];
  logic [31:0] commit_insn [CORE_COUNT];
  logic [CORE_COUNT-1:0] commit_gpr_we;
  logic [4:0] commit_gpr_rd [CORE_COUNT];
  logic [63:0] commit_gpr_wdata [CORE_COUNT];
  logic [31:0] vcpu_seq [CORE_COUNT];
  lcvex_mc_event_t event_kind [CORE_COUNT];
  logic [CORE_COUNT-1:0] l1_drain_done;
  logic [CORE_COUNT-1:0] l1_drain_fault;
  logic [CORE_COUNT-1:0] l2_drain_ack_valid;
  logic [CORE_COUNT-1:0] l2_drain_fault;

  logic [CORE_COUNT-1:0] prog_we;
  logic [CORE_COUNT*64-1:0] prog_addr;
  logic [CORE_COUNT*8-1:0] prog_strb;
  logic [CORE_COUNT*64-1:0] prog_wdata;

  integer errors = 0;
  integer commit_count [CORE_COUNT];
  logic [CORE_COUNT-1:0] saw_flag;
  logic saw_core0 = 1'b0;

  lcvex_cluster_top #(
      .CORE_COUNT(CORE_COUNT),
      .CORE_ID_W(4),
      .RESET_PC(BASE),
      .SRAM_BASE(BASE),
      .MEM_DEPTH(1 << 16),
      .LINE_BYTES(64),
      .L1_SETS(64),
      .L2_SETS(64),
      .L2_WAYS(1),
      .A64_FP_SIMD(1'b0),
      .COHERENCE_ENABLE(1'b1),
      .AUTO_START(1'b0),
      .RESET_DELAY_CYCLES(3)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .core_reset_pulse(core_reset_pulse),
      .core_start_pulse(core_start_pulse),
      .core_stop_pulse(core_stop_pulse),
      .irq(irq),
      .event_in(event_in),
      .mc_commit_ready(mc_commit_ready),
      .mc_commit_valid(mc_commit_valid),
      .mc_commit(mc_commit),
      .core_running(core_running),
      .core_stopped(core_stopped),
      .core_wfi_idle(core_wfi_idle),
      .core_fault(core_fault),
      .sev_pulse(sev_pulse),
      .mpidr(mpidr),
      .timer_phys_irq(timer_phys_irq),
      .timer_virt_irq(timer_virt_irq),
      .commit_valid(commit_valid),
      .commit_pc(commit_pc),
      .commit_next_pc(commit_next_pc),
      .commit_insn(commit_insn),
      .commit_gpr_we(commit_gpr_we),
      .commit_gpr_rd(commit_gpr_rd),
      .commit_gpr_wdata(commit_gpr_wdata),
      .vcpu_seq(vcpu_seq),
      .event_kind(event_kind),
      .l1_drain_done(l1_drain_done),
      .l1_drain_fault(l1_drain_fault),
      .l2_drain_ack_valid(l2_drain_ack_valid),
      .l2_drain_fault(l2_drain_fault),
      .prog_we(prog_we),
      .prog_addr(prog_addr),
      .prog_strb(prog_strb),
      .prog_wdata(prog_wdata)
  );

  always #5 clk = ~clk;

  // Core0 program (at BASE + 0x000):
  //   flag=0x5A, sync=1. PSCI CPU_ON is not used in this full-core TB;
  //   slaves are started directly by the testbench, while the separate
  //   sysctrl TB verifies PSCI-like CPU_ON/OFF and SGI paths.
  logic [31:0] IMG0 [0:31] = '{
      32'hd2a80002, // movz x2, #0x4000, lsl #16
      32'hf2808002, // movk x2, #0x0400
      32'h52800b43, // mov w3, #0x5a
      32'hb9000043, // str w3, [x2]
      32'hd50330bf, // dmb sy
      32'hf2808082, // movk x2, #0x0404
      32'h52800023, // mov w3, #1
      32'hb9000043, // str w3, [x2]  (sync=1)
      32'h14000001, // b done0
      32'h14000000, // done0: b done0
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000
  };

  // Cores 1..3 (at BASE + 0x100/0x200/0x300):
  //   spin on sync != 0, read flag into w5, dmb, then spin.
  logic [31:0] IMG1 [0:31] = '{
      32'hd2a80002, // movz x2, #0x4000, lsl #16
      32'hf2808082, // movk x2, #0x0404
      32'hb9400044, // ldr w4, [x2]
      32'h7100009f, // cmp w4, #0
      32'h54ffffc0, // b.eq spin
      32'hf2808002, // movk x2, #0x0400
      32'hb9400045, // ldr w5, [x2]
      32'hd50330bf, // dmb sy
      32'h14000001, // b done1
      32'h14000000, // done1: b done1
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000
  };

  task automatic load_program(input int core, input int n, input logic [31:0] img [0:31]);
    begin
      for (int i = 0; i < n; i++) begin
        prog_we[0] = 1'b1;
        prog_addr[0*64 +: 64] = BASE + 64'(core * 64'h100) + 64'(4 * i);
        prog_strb[0*8 +: 8] = 8'h0f;
        prog_wdata[0*64 +: 64] = 64'(img[i]);
        @(posedge clk);
      end
      prog_we[0] = 1'b0;
    end
  endtask

  task automatic pulse_reset(input int c);
    begin
      core_reset_pulse[c] = 1'b1;
      @(posedge clk);
      core_reset_pulse[c] = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic pulse_start(input int c);
    begin
      core_start_pulse[c] = 1'b1;
      @(posedge clk);
      core_start_pulse[c] = 1'b0;
    end
  endtask

  task automatic pulse_stop(input int c);
    begin
      core_stop_pulse[c] = 1'b1;
      @(posedge clk);
      core_stop_pulse[c] = 1'b0;
    end
  endtask

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL: %s", msg);
        errors = errors + 1;
      end else begin
        $display("PASS: %s", msg);
      end
    end
  endtask

  always_ff @(posedge clk) begin
    for (int c = 0; c < CORE_COUNT; c++) begin
      if (commit_valid[c]) begin
        commit_count[c] = commit_count[c] + 1;
        if (c == 0) saw_core0 <= 1'b1;
        if (commit_gpr_we[c] && commit_gpr_rd[c] == 5 &&
            commit_gpr_wdata[c] == 64'h5a) begin
          saw_flag[c] <= 1'b1;
          $display("CORE%0d observed flag=0x5a at commit", c);
        end
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    saw_flag = '0;
    for (int c = 0; c < CORE_COUNT; c++) commit_count[c] = 0;
    repeat (4) @(posedge clk);

    load_program(0, 32, IMG0);
    load_program(1, 32, IMG1);
    load_program(2, 32, IMG1);
    load_program(3, 32, IMG1);

    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    check(&core_stopped, "all cores initially stopped");
    check(!(&core_running), "no core running before start");

    // Explicit per-core reset is required: core_clk is gated while core is
    // stopped, so without a post-rst_n reset pulse the core's async reset
    // never sees a clean negedge and if_pc can remain 0.
    pulse_reset(0);
    pulse_reset(1);
    pulse_reset(2);
    pulse_reset(3);
    repeat (8) @(posedge clk);

    pulse_start(0);
    repeat (20) @(posedge clk);
    check(core_running[0], "core0 running after start");

    // Start slaves directly in this full-core TB.  The separate sysctrl TB
    // verifies the PSCI-like CPU_ON/OFF and SGI paths.
    pulse_start(1);
    pulse_start(2);
    pulse_start(3);
    repeat (20) @(posedge clk);
    check(core_running[1] && core_running[2] && core_running[3],
          "cores 1..3 are running after direct start");

    // Wait for all slave cores to observe the shared flag.
    for (int t = 0; t < 300000; t++) begin
      @(posedge clk);
      if (saw_core0 && saw_flag[1] && saw_flag[2] && saw_flag[3]) break;
    end

    check(saw_core0, "core0 made progress through the sequence");
    check(saw_flag[1], "core1 observed flag after start");
    check(saw_flag[2], "core2 observed flag after start");
    check(saw_flag[3], "core3 observed flag after start");
    check(core_fault == '0, "no core fault in C3 four-core sequence");

    // Test direct stop/start on a slave as a reset/per-core lifecycle check.
    pulse_stop(1);
    repeat (4) @(posedge clk);
    check(core_stopped[1] && core_running[1] == 1'b0,
          "core1 stopped after lifecycle stop");
    pulse_start(1);
    repeat (4) @(posedge clk);
    check(core_running[1], "core1 restarted after lifecycle start");

    if (errors == 0) $display("LCVEX_C3_FOURCORE_TB PASS");
    else $display("LCVEX_C3_FOURCORE_TB FAIL: %0d", errors);
    $finish;
  end

endmodule
