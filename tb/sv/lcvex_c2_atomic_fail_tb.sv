// lcvex_c2_atomic_fail_tb.sv
// C2 system-level atomic negative test: core0 performs LDXR on a shared
// word, core1 writes the same line, then core0's STXR must fail.
//
// Expected result:
//   result == 1 (STXR failure status)
//   cell   == 0xDE (remote write wins)
//   cell   != 0xCA (failed local write must not land)
//
// This exercises the shared-L2 MSI invalidation path with the existing
// single-core exclusive monitor.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c2_atomic_fail_tb;
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
  logic stxr_fail_seen = 1'b0;

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
    logic [31:0] IMG [0:75] = '{
32'h10010802,
32'h885f7c40,
32'hd5033fbf,
32'h10010823,
32'h52800024,
32'hb9000064,
32'hb9400065,
32'h710008bf,
32'h54ffffc1,
32'h100106e2,
32'h52801944,
32'h88067c44,
32'hd5033fbf,
32'h10010767,
32'hb90000e6,
32'h14000000,
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
32'h00000000,
32'h00000000,
32'h00000000,
32'h00000000,
32'h00000000,
32'h00000000,
32'h10010083,
32'hb9400065,
32'h710004bf,
32'h54ffffc1,
32'hd5033fbf,
32'h1000ff62,
32'h52801bc4,
32'hb9000044,
32'hd5033fbf,
32'h52800045,
32'hb9000065,
32'h14000000
  };

  task automatic load_shared_mem();
    begin
      prog_we = 1'b1;
      for (int i = 0; i < 76; i++) begin
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
        if (c == 0 && commit_gpr_we[c] && commit_gpr_rd[c] == 6 &&
            commit_gpr_wdata[c] == 64'h1)
          stxr_fail_seen <= 1'b1;
        // Hierarchical debug for the failing atomic negative path.
        if (c == 1 && commit_pc[c] == (BASE + 64'h11c)) begin
          $display("DBG cell-store: L1c1[0..3]=%h %h %h %h dir64 v=%b s=%h sh=%b ow=%b d=%b poc=%h",
                   dut.g_cores[1].wrap.g_coherent_mem.l1coh.data[0][0],
                   dut.g_cores[1].wrap.g_coherent_mem.l1coh.data[0][1],
                   dut.g_cores[1].wrap.g_coherent_mem.l1coh.data[0][2],
                   dut.g_cores[1].wrap.g_coherent_mem.l1coh.data[0][3],
                   dut.g_c2_shared.cluster.dir_valid[64],
                   dut.g_c2_shared.cluster.dir_state[64],
                   dut.g_c2_shared.cluster.dir_sharers[64],
                   dut.g_c2_shared.cluster.dir_owner[64],
                   dut.g_c2_shared.cluster.dir_dirty[64],
                   dut.g_c2_shared.shared_ram.sram[8448]);
        end
        if (c == 0 && commit_pc[c] == (BASE + 64'h2c)) begin
          $display("DBG STXR: L1c0[0..3]=%h %h %h %h L1c1[0..3]=%h %h %h %h poc=%h",
                   dut.g_cores[0].wrap.g_coherent_mem.l1coh.data[0][0],
                   dut.g_cores[0].wrap.g_coherent_mem.l1coh.data[0][1],
                   dut.g_cores[0].wrap.g_coherent_mem.l1coh.data[0][2],
                   dut.g_cores[0].wrap.g_coherent_mem.l1coh.data[0][3],
                   dut.g_cores[1].wrap.g_coherent_mem.l1coh.data[0][0],
                   dut.g_cores[1].wrap.g_coherent_mem.l1coh.data[0][1],
                   dut.g_cores[1].wrap.g_coherent_mem.l1coh.data[0][2],
                   dut.g_cores[1].wrap.g_coherent_mem.l1coh.data[0][3],
                   dut.g_c2_shared.shared_ram.sram[8448]);
        end
        if (c == 0 && commit_pc[c] == (BASE + 64'h38)) begin
          $display("DBG result-store: poc=%h L1c0[0..3]=%h %h %h %h",
                   dut.g_c2_shared.shared_ram.sram[8448],
                   dut.g_cores[0].wrap.g_coherent_mem.l1coh.data[0][0],
                   dut.g_cores[0].wrap.g_coherent_mem.l1coh.data[0][1],
                   dut.g_cores[0].wrap.g_coherent_mem.l1coh.data[0][2],
                   dut.g_cores[0].wrap.g_coherent_mem.l1coh.data[0][3]);
        end
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
    $display("DBG SRAM code0=%h code100=%h", dut.g_c2_shared.shared_ram.sram[0], dut.g_c2_shared.shared_ram.sram[256]);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    check(&core_stopped, "both cores initially stopped");

    // Mirror the C1 directed cold-start: explicit per-core reset before start.
    pulse_reset(0);
    pulse_reset(1);
    repeat (8) @(posedge clk);

    pulse_start(0);
    // Give core0 a deterministic head start before core1 begins.
    repeat (100) @(posedge clk);
    $display("DBG after core0 head: running=%b stopped=%b cnt0=%0d cnt1=%0d",
             core_running, core_stopped, commit_count[0], commit_count[1]);
    pulse_start(1);
    repeat (20) @(posedge clk);
    $display("DBG after core1 start: running=%b stopped=%b cnt0=%0d cnt1=%0d",
             core_running, core_stopped, commit_count[0], commit_count[1]);

    // Wait until core0 commits the failing STXR status in w6.
    for (int t = 0; t < 200000; t++) begin
      @(posedge clk);
      if (stxr_fail_seen) break;
    end

    $display("DBG atomic fail: stxr_fail_seen=%b cell=%h cell4=%h",
             stxr_fail_seen,
             dut.g_c2_shared.shared_ram.sram[8448],
             dut.g_c2_shared.shared_ram.sram[8452]);
    check(stxr_fail_seen, "STXR status is 1 (failed after remote write)");
    check(dut.g_c2_shared.shared_ram.sram[8448] == 8'hde,
          "cell retains remote value 0xde, local 0xca did not land");
    check(core_fault == '0, "no core fault in atomic negative test");
    check(commit_count[0] > 8 && commit_count[1] > 8,
          "both cores progressed through atomic sequence");

    if (errors == 0) $display("LCVEX_C2_ATOMIC_FAIL_TB PASS");
    else $display("LCVEX_C2_ATOMIC_FAIL_TB FAIL: %0d", errors);
    $finish;
  end

endmodule
