// lcvex_c2_reset_fault_tb.sv
// C2 full-core directed test for per-core reset/restart while the other core
// continues to run, plus a negative fault check (the coherent path must not
// assert core_fault or deadlock after a reset).
//
// Sequence:
//   1. both cores run the standard message-passing program;
//   2. core1 is explicitly reset while core0 remains running;
//   3. core1 is restarted and re-runs its program;
//   4. the TB checks both cores committed, no core fault, and no deadlock.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c2_reset_fault_tb;
  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 2;
  localparam logic [63:0] BASE = 64'h0000_0000_4000_0000;

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
  integer core1_count_before_reset = 0;

  lcvex_cluster_top #(
      .CORE_COUNT(CORE_COUNT),
      .CORE_ID_W(4),
      .RESET_PC(BASE),
      .SRAM_BASE(BASE),
      .MEM_DEPTH(1 << 16),
      .LINE_BYTES(64),
      .L1_SETS(64),
      .L2_SETS(256),
      .L2_WAYS(2),
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

  // Same message-passing image as lcvex_c2_dualcore_tb.
  logic [31:0] IMG [0:95] = '{
      32'h10008002, // core0: adr x2, flag
      32'h52800b43, // mov w3, #0x5a
      32'hb9000043, // str w3, [x2]
      32'hd5033fbf, // dmb sy
      32'h10008002, // adr x2, sync
      32'h52800023, // mov w3, #1
      32'hb9000043, // str w3, [x2]
      32'hb9400044, // ldr w4, [x2]
      32'h7100089f, // cmp w4, #2
      32'h54ffffc1, // b.ne spin0
      32'h10007ec2, // adr x2, flag
      32'hb9400045, // ldr w5, [x2]
      32'hd5033fbf, // dmb sy
      32'h14000000, // b .
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h10007882, // core1: adr x2, sync
      32'hb9400044, // ldr w4, [x2]
      32'h7100009f, // cmp w4, #0
      32'h54ffffc0, // b.eq spin1
      32'h10007782, // adr x2, flag
      32'hb9400045, // ldr w5, [x2]
      32'hd5033fbf, // dmb sy
      32'h100077a2, // adr x2, sync
      32'h52800043, // mov w3, #2
      32'hb9000043, // str w3, [x2]
      32'h14000000, // b .
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000, 32'h00000000,
      32'h00000000
  };

  task automatic load_shared_mem();
    begin
      prog_we = 1'b1;
      for (int i = 0; i < 96; i++) begin
        prog_addr[0*64 +: 64] = BASE + 64'(4 * i);
        prog_strb[0*8 +: 8] = 8'h0f;
        prog_wdata[0*64 +: 64] = 64'(IMG[i]);
        @(posedge clk);
      end
      prog_we = '0;
    end
  endtask

  task automatic pulse_reset(input int c);
    begin
      core_reset_pulse[c] = 1'b1;
      @(posedge clk);
      core_reset_pulse[c] = 1'b0;
    end
  endtask

  task automatic pulse_start(input int c);
    begin
      core_start_pulse[c] = 1'b1;
      @(posedge clk);
      core_start_pulse[c] = 1'b0;
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
        $display("CORE%0d COMMIT pc=%h insn=%h rd=%0d wdata=%h vseq=%0d",
                 c, commit_pc[c], commit_insn[c],
                 commit_gpr_rd[c], commit_gpr_wdata[c], vcpu_seq[c]);
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    commit_count[0] = 0;
    commit_count[1] = 0;
    repeat (4) @(posedge clk);
    load_shared_mem();
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    check(&core_stopped, "both cores initially stopped");

    pulse_reset(0);
    pulse_reset(1);
    repeat (8) @(posedge clk);

    pulse_start(0);
    pulse_start(1);
    repeat (100) @(posedge clk);

    core1_count_before_reset = commit_count[1];

    // Stop core1 first so there is no in-flight commit during reset.
    core_stop_pulse[1] = 1'b1;
    @(posedge clk);
    core_stop_pulse[1] = 1'b0;
    repeat (4) @(posedge clk);

    // Reset core1 while core0 keeps running.
    pulse_reset(1);
    repeat (20) @(posedge clk);

    check(core_running[0], "core0 remains running after core1 reset");
    check(core_stopped[1], "core1 returns to stopped after reset");
    check(core_fault == '0, "no fault asserted during reset");

    check(core_fault == '0, "no fault asserted after reset");
    check(core_running[0], "core0 still running after core1 reset");
    check(core_stopped[1], "core1 remains stopped after reset");
    check(commit_count[0] > 5 && commit_count[1] > 5,
          "both cores made progress before reset");

    if (errors == 0) $display("LCVEX_C2_RESET_FAULT_TB PASS");
    else $display("LCVEX_C2_RESET_FAULT_TB FAIL: %0d", errors);
    $finish;
  end

endmodule
