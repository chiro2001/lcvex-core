// lcvex_c2_atomic_ok_tb.sv
// C2 system-level atomic positive test: core0 performs LDXR/STXR on a
// shared word without remote interference and the store must succeed.
//
// Expected:
//   result == 0 (STXR success)
//   cell   == 0x55

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c2_atomic_ok_tb;
  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 2;
  localparam logic [63:0] BASE = 64'h0000_0000_4000_0000;
  localparam logic [63:0] CORE1_PC_OFF = 64'h0000_0000_0000_0100;

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
  logic saw_flag0 = 1'b0;
  logic saw_flag1 = 1'b0;

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

  // AArch64 binary assembled from the message-passing sequence described in
  // the header.  Words are little-endian 32-bit.
  logic [31:0] IMG [0:15] = '{
      32'h10010002, // core0: adr x2, cell
      32'h885f7c40, // ldxr w0, [x2]
      32'h52800aa4, // mov w4, #0x55
      32'h88067c44, // stxr w6, w4, [x2]
      32'hd5033fbf, // dmb sy
      32'h1000ffe7, // adr x7, result
      32'hb90000e6, // str w6, [x7]
      32'h14000000, // b .
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h00000000,
      32'h14000000  // core1: b . (unused)
  };

  task automatic load_shared_mem();
    begin
      prog_we = 1'b1;
      for (int i = 0; i < 16; i++) begin
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
        // After the message-passing load, w5 should hold 0x5a on both cores.
        if (commit_gpr_we[c] && commit_gpr_rd[c] == 5 &&
            commit_gpr_wdata[c] == 64'h5a) begin
          if (c == 0) saw_flag0 <= 1'b1;
          else saw_flag1 <= 1'b1;
        end
      end
    end
  end

  initial begin
    clk = 1'b0;
    // Reset and load shared memory.
    rst_n = 1'b0;
    commit_count[0] = 0;
    commit_count[1] = 0;
    repeat (4) @(posedge clk);
    load_shared_mem();
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    check(&core_stopped, "both cores initially stopped");

    // Mirror the C1 directed cold-start: explicit per-core reset before start.
    pulse_reset(0);
    pulse_reset(1);
    repeat (8) @(posedge clk);

    pulse_start(0);
    // core1 intentionally stays stopped for the positive exclusive test.
    repeat (20) @(posedge clk);

    // Wait for both cores to observe the shared flag.
    for (int t = 0; t < 200000; t++) begin
      @(posedge clk);
      if (saw_flag0 && saw_flag1) break;
    end

    // Wait for core0 to write the STXR status at result (0x2010).
    for (int t = 0; t < 100000; t++) begin
      @(posedge clk);
      if (dut.g_c2_shared.shared_ram.sram[8208] != 8'h00) break;
    end

    check(dut.g_c2_shared.shared_ram.sram[8208] == 8'h00,
          "STXR status is 0 (succeeded without remote interference)");
    check(dut.g_c2_shared.shared_ram.sram[8192] == 8'h55,
          "cell stores 0x55 after successful STXR");
    check(core_fault == '0, "no core fault in atomic positive test");

    if (errors == 0) $display("LCVEX_C2_ATOMIC_OK_TB PASS");
    else $display("LCVEX_C2_ATOMIC_OK_TB FAIL: %0d", errors);
    $finish;
  end

endmodule
