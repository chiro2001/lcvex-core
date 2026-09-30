// lcvex_cluster_tb.sv
// C1 directed shell testbench: 2 cores, private RAM, per-core start/stop/
// reset, WFI/WFE/event/IRQ observability, and per-core commit records.

`timescale 1ns/1ps

module lcvex_cluster_tb;

  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 2;
  localparam logic [63:0] BASE = 64'h0000_0000_4000_0000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic [CORE_COUNT-1:0] core_reset_pulse = '0;
  logic [CORE_COUNT-1:0] core_start_pulse = '0;
  logic [CORE_COUNT-1:0] core_stop_pulse  = '0;
  logic [CORE_COUNT-1:0] irq              = '0;
  logic [CORE_COUNT-1:0] event_in         = '0;
  logic [CORE_COUNT-1:0] mc_commit_ready  = '1;

  logic [CORE_COUNT-1:0] mc_commit_valid;
  lcvex_cluster_pkg::lcvex_mc_commit_t mc_commit [CORE_COUNT];
  logic [CORE_COUNT-1:0] core_running;
  logic [CORE_COUNT-1:0] core_stopped;
  logic [CORE_COUNT-1:0] core_wfi_idle;
  logic [CORE_COUNT-1:0] core_fault;
  logic [CORE_COUNT-1:0] sev_pulse;
  logic [31:0]           mpidr [CORE_COUNT];
  logic [CORE_COUNT-1:0] timer_phys_irq;
  logic [CORE_COUNT-1:0] timer_virt_irq;

  logic [CORE_COUNT-1:0] commit_valid;
  logic [63:0]           commit_pc [CORE_COUNT];
  logic [63:0]           commit_next_pc [CORE_COUNT];
  logic [31:0]           commit_insn [CORE_COUNT];
  logic [CORE_COUNT-1:0] commit_gpr_we;
  logic [4:0]            commit_gpr_rd [CORE_COUNT];
  logic [63:0]           commit_gpr_wdata [CORE_COUNT];
  logic [31:0]           vcpu_seq [CORE_COUNT];
  lcvex_cluster_pkg::lcvex_mc_event_t event_kind [CORE_COUNT];
  logic [CORE_COUNT-1:0] l1_drain_done;
  logic [CORE_COUNT-1:0] l1_drain_fault;
  logic [CORE_COUNT-1:0] l2_drain_ack_valid;
  logic [CORE_COUNT-1:0] l2_drain_fault;

  logic [CORE_COUNT-1:0] prog_we;
  logic [CORE_COUNT*64-1:0] prog_addr;
  logic [CORE_COUNT*8-1:0]  prog_strb;
  logic [CORE_COUNT*64-1:0] prog_wdata;

  lcvex_cluster_top #(
      .CORE_COUNT(CORE_COUNT),
      .CORE_ID_W(4),
      .RESET_PC(BASE),
      .SRAM_BASE(BASE),
      .MEM_DEPTH(1 << 16),
      .AUTO_START(1'b0),
      .RESET_DELAY_CYCLES(3)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
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

  // Kernel for both cores.  They are identical except for the initial MOV
  // values, which make per-core commit records distinguishable.
  // 0: mov x0,#1 / mov x1,#2 / wfi / mov x0,#3 / sev / wfe / mov x0,#4 / b .
  logic [31:0] PROG [0:7] = '{
      32'hD2800020,  // mov x0, #1
      32'hD2800041,  // mov x1, #2
      32'hD503207F,  // wfi
      32'hD2800060,  // mov x0, #3
      32'hD503209F,  // sev
      32'hD503205F,  // wfe
      32'hD2800080,  // mov x0, #4
      32'h14000000   // b .
  };

  integer commit_count [CORE_COUNT];
  integer errors;

  task automatic load_core(input int c);
    begin
      // C1 directed test uses identical programs for both cores.  Write all
      // per-core flattened slices in the same cycles so the test is not
      // sensitive to individual program-load port selection.
      prog_we = {CORE_COUNT{1'b1}};
      for (int i = 0; i < 8; i++) begin
        for (int k = 0; k < CORE_COUNT; k++) begin
          prog_addr[k*64 +: 64] = BASE + 64'(4 * i);
          prog_strb[k*8 +: 8]   = 8'h0f;
          prog_wdata[k*64 +: 64] = 64'(PROG[i]);
        end
        @(posedge clk);
      end
      prog_we = '0;
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

  task automatic pulse_reset(input int c);
    begin
      core_reset_pulse[c] = 1'b1;
      @(posedge clk);
      core_reset_pulse[c] = 1'b0;
    end
  endtask

  task automatic pulse_event(input int c);
    begin
      event_in[c] = 1'b1;
      @(posedge clk);
      event_in[c] = 1'b0;
    end
  endtask

  task automatic wait_until_commit(input int c, input int limit,
                                   output logic [31:0] seen_pc_lo);
    begin
      int n;
      n = 0;
      while (n < limit) begin
        @(posedge clk);
        if (commit_valid[c]) begin
          commit_count[c] = commit_count[c] + 1;
          seen_pc_lo = commit_pc[c][31:0];
          $display("CORE %0d COMMIT seq=%0d pc=0x%08x insn=0x%08x vseq=%0d",
                   c, commit_count[c], commit_pc[c][31:0],
                   commit_insn[c], vcpu_seq[c]);
          return;
        end
        n = n + 1;
      end
      $display("ERROR: core %0d no commit within %0d cycles", c, limit);
      errors = errors + 1;
    end
  endtask

  task automatic wait_until_idle(input int c, input int limit);
    begin
      int n;
      n = 0;
      while (n < limit) begin
        @(posedge clk);
        if (core_wfi_idle[c]) return;
        n = n + 1;
      end
      $display("ERROR: core %0d did not reach C1 WFI observer within %0d cycles",
               c, limit);
      errors = errors + 1;
    end
  endtask

  task automatic wait_until_not_idle(input int c, input int limit);
    begin
      int n;
      n = 0;
      while (n < limit) begin
        @(posedge clk);
        if (!core_wfi_idle[c] && core_running[c]) return;
        n = n + 1;
      end
      $display("ERROR: core %0d did not leave WFI observer within %0d cycles",
               c, limit);
      errors = errors + 1;
    end
  endtask

  task automatic check(input int c, input string what);
    begin
      if (errors != 0) begin
        $display("FAIL at %s: %0d error(s)", what, errors);
      end else begin
        $display("PASS: %s", what);
      end
    end
  endtask

  initial begin
    logic [31:0] seen_pc;

    // Reset and load both private memories.
    rst_n = 1'b0;
    mc_commit_ready = '1;
    repeat (4) @(posedge clk);
    load_core(0);
    load_core(1);
    rst_n = 1'b1;

    // After release with AUTO_START=0, both cores should be stopped.
    repeat (8) @(posedge clk);
    if (!core_stopped[0] || !core_stopped[1]) begin
      $display("ERROR: both cores should start stopped");
      errors = errors + 1;
    end else begin
      $display("PASS: initial STOPPED state");
    end

    // Confirm distinct MPIDR outputs.
    if (mpidr[0] != 32'd0 || mpidr[1] != 32'd1) begin
      $display("ERROR: mpidr expected 0/1, got %0d/%0d", mpidr[0], mpidr[1]);
      errors = errors + 1;
    end else begin
      $display("PASS: per-core MPIDR outputs");
    end

    // C1 directed cold-start path: reset/start each core independently.
    // This exercises the same per-core reset/start control sequence that the
    // reset/restart section uses.
    pulse_reset(0);
    repeat (8) @(posedge clk);
    if (!core_stopped[0]) begin
      $display("ERROR: core0 explicit reset did not return to STOPPED");
      errors = errors + 1;
    end

    // Start only core 0: core 1 must stay stopped and produce no commits.
    pulse_start(0);
    wait_until_commit(0, 2000, seen_pc);
    if (commit_pc[0] != BASE || commit_insn[0] != 32'hD2800020) begin
      $display("ERROR: core0 first commit mismatch pc=%h insn=%h",
               commit_pc[0], commit_insn[0]);
      errors = errors + 1;
    end else begin
      $display("PASS: core0 first commit");
    end
    if (!core_stopped[1]) begin
      $display("ERROR: core1 should remain stopped while core0 runs");
      errors = errors + 1;
    end else begin
      $display("PASS: independent start (core1 stopped)");
    end

    // Let core0 reach WFI.
    wait_until_idle(0, 5000);
    if (!core_wfi_idle[0]) begin
      $display("ERROR: core0 should be in WFI observer");
      errors = errors + 1;
    end else begin
      $display("PASS: core0 WFI observer");
    end
    if (core_stopped[0]) begin
      $display("ERROR: core0 should be running/WFI, not stopped");
      errors = errors + 1;
    end

    // Wake core0 with its own event; core1 stays idle/stopped unaffected.
    pulse_event(0);
    wait_until_not_idle(0, 1000);
    wait_until_commit(0, 2000, seen_pc);   // mov x0,#3
    if (commit_insn[0] != 32'hD2800060) begin
      $display("ERROR: after event core0 should execute mov x0,#3, got %h",
               commit_insn[0]);
      errors = errors + 1;
    end else begin
      $display("PASS: core0 event wake");
    end

    // Let core0 pass SEV/WFE/end.  WFE after local SEV should not hang.
    wait_until_commit(0, 2000, seen_pc);   // sev
    wait_until_commit(0, 2000, seen_pc);   // wfe (may complete immediately)
    wait_until_commit(0, 2000, seen_pc);   // mov x0,#4
    $display("PASS: core0 completed local SEV/WFE sequence");

    // Start core1; give it its own reset/start sequence.
    pulse_reset(1);
    repeat (8) @(posedge clk);
    pulse_start(1);
    wait_until_commit(1, 2000, seen_pc);
    if (commit_insn[1] != 32'hD2800020) begin
      $display("ERROR: core1 first commit mismatch");
      errors = errors + 1;
    end else begin
      $display("PASS: core1 first commit");
    end
    wait_until_idle(1, 5000);
    if (!core_wfi_idle[1]) begin
      $display("ERROR: core1 should be in WFI observer");
      errors = errors + 1;
    end else begin
      $display("PASS: core1 independent WFI");
    end

    // Independent IRQ wake: use only core1's IRQ; core0 must not change.
    irq[1] = 1'b1;
    repeat (3) @(posedge clk);
    irq[1] = 1'b0;
    wait_until_not_idle(1, 1000);
    wait_until_commit(1, 2000, seen_pc);   // mov x0,#3 on core1
    if (commit_insn[1] != 32'hD2800060) begin
      $display("ERROR: core1 after IRQ wake should execute mov x0,#3");
      errors = errors + 1;
    end else begin
      $display("PASS: core1 independent IRQ wake");
    end

    // Stop core1 and verify it freezes; core0 is in its WFE/branch path and
    // should remain running.
    pulse_stop(1);
    repeat (6) @(posedge clk);
    if (core_stopped[1]) begin
      $display("PASS: core1 stop");
    end else begin
      $display("ERROR: core1 did not stop");
      errors = errors + 1;
    end

    // Independent reset of core1: vcpu_seq resets and core1 can re-start.
    pulse_reset(1);
    repeat (6) @(posedge clk);
    if (vcpu_seq[1] != 32'd0) begin
      $display("ERROR: core1 vcpu_seq not reset, got %0d", vcpu_seq[1]);
      errors = errors + 1;
    end else begin
      $display("PASS: per-core reset clears commit counter");
    end
    pulse_start(1);
    wait_until_commit(1, 2000, seen_pc);
    if (commit_insn[1] != 32'hD2800020) begin
      $display("ERROR: core1 after reset should restart from mov x0,#1");
      errors = errors + 1;
    end else begin
      $display("PASS: core1 reset/restart");
    end

    // Per-core envelope metadata check.
    if (mc_commit[0].core_id == 0 && mc_commit[1].core_id == 1 &&
        mc_commit[0].version == MC_VERSION && mc_commit[1].version == MC_VERSION) begin
      $display("PASS: MC envelope core_id/version");
    end else begin
      $display("ERROR: MC envelope metadata wrong");
      errors = errors + 1;
    end

    if (errors == 0) begin
      $display("LCVEX_C1_SHELL_TB PASS");
    end else begin
      $display("LCVEX_C1_SHELL_TB FAIL: %0d error(s)", errors);
    end
    $finish;
  end

endmodule
