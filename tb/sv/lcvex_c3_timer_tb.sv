// lcvex_c3_timer_tb.sv
// C3 directed Generic Timer check: a single core enables CNTP_CTL with a
// near-future compare value, and the cluster outputs timer_phys_irq.
//
// This uses CORE_COUNT=1 non-coherent private-RAM shell for a lightweight
// timer-only check; it does not claim multi-core timer IRQ distribution.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c3_timer_tb;
  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 1;
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
  integer commit_count = 0;
  logic saw_timer = 1'b0;

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
      .COHERENCE_ENABLE(1'b0),
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

  // Timer program: cval = cntpct + 4, enable CNTP_CTL, loop forever.
  logic [31:0] IMG [0:6] = '{
      32'hd53be023, // mrs x3, cntpct_el0
      32'h91001064, // add x4, x3, #4
      32'hd51be244, // msr cntp_cval_el0, x4
      32'hd2800025, // mov x5, #1
      32'hd51be225, // msr cntp_ctl_el0, x5
      32'h14000001, // b loop
      32'h14000000  // loop: b loop
  };

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
    if (commit_valid[0]) begin
      commit_count = commit_count + 1;
      if (commit_count <= 10)
        $display("TIMER TB COMMIT %0d pc=%h insn=%h", commit_count, commit_pc[0], commit_insn[0]);
    end
    if (timer_phys_irq[0]) saw_timer <= 1'b1;
  end

  initial begin
    rst_n = 1'b0;
    prog_we = '0;
    repeat (4) @(posedge clk);
    for (int i = 0; i < 7; i++) begin
      prog_we[0] = 1'b1;
      prog_addr[0*64 +: 64] = BASE + 64'(4 * i);
      prog_strb[0*8 +: 8] = 8'h0f;
      prog_wdata[0*64 +: 64] = 64'(IMG[i]);
      @(posedge clk);
    end
    prog_we[0] = 1'b0;
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    core_reset_pulse[0] = 1'b1;
    @(posedge clk);
    core_reset_pulse[0] = 1'b0;
    repeat (4) @(posedge clk);

    core_start_pulse[0] = 1'b1;
    @(posedge clk);
    core_start_pulse[0] = 1'b0;

    for (int t = 0; t < 20000; t++) begin
      @(posedge clk);
      if (saw_timer) break;
    end

    $display("TIMER TB total commits = %0d", commit_count);
    check(saw_timer, "generic timer physical IRQ observed");
    check(core_running[0], "core still running after timer setup");
    check(core_fault == '0, "no core fault in timer directed test");

    if (errors == 0) $display("LCVEX_C3_TIMER_TB PASS");
    else $display("LCVEX_C3_TIMER_TB FAIL: %0d", errors);
    $finish;
  end

endmodule
