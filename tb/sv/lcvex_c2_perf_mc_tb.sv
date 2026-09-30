// lcvex_c2_perf_mc_tb.sv
// C2 dual-core performance workload.
//
// Loads tb/sv/lcvex_c2_perf_mc.hex into the shared C2 coherent SRAM, starts
// both lcvex_core instances, and records the commit-store cycles for the
// workload markers.  The kernel itself is in lcvex_c2_perf_mc.S.
//
// Measured phases:
//   1. pingpong: 16 mailbox exchanges through shared flags/DMB.
//   2. reduction: two 32-word partial sums, combined in shared memory.
//   3. same-line: 32 stores from each core to the same cache line.
//   4. diff-line: 32 stores from each core to separate cache lines.
// All numbers are proxy cycles for this C2 RTL shell, not an A10/Fmax signoff.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c2_perf_mc_tb;
  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 2;
  localparam logic [63:0] BASE = 64'h0000_0000_4000_0000;

  // Marker addresses (offsets from BASE), matching the .S data layout.
  localparam logic [63:0] ADDR_PING_DONE0 = BASE + 64'h0000_2008;
  localparam logic [63:0] ADDR_PING_DONE1 = BASE + 64'h0000_200C;
  localparam logic [63:0] ADDR_RED_RESULT = BASE + 64'h0000_220C;
  localparam logic [63:0] ADDR_RED_DONE   = BASE + 64'h0000_2210;
  localparam logic [63:0] ADDR_SAME0_DONE = BASE + 64'h0000_2304;
  localparam logic [63:0] ADDR_SAME1_DONE = BASE + 64'h0000_2308;
  localparam logic [63:0] ADDR_DIFF0_DONE = BASE + 64'h0000_2404;
  localparam logic [63:0] ADDR_DIFF1_DONE = BASE + 64'h0000_2444;

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
  integer cycle_count = 0;
  integer start_cyc = 0;
  integer final_cyc = 0;

  integer pp0_cyc = -1;
  integer pp1_cyc = -1;
  integer red_result_cyc = -1;
  integer red_done_cyc = -1;
  integer same0_cyc = -1;
  integer same1_cyc = -1;
  integer diff0_cyc = -1;
  integer diff1_cyc = -1;

  logic pp0_seen = 1'b0;
  logic pp1_seen = 1'b0;
  logic red_result_seen = 1'b0;
  logic red_done_seen = 1'b0;
  logic same0_seen = 1'b0;
  logic same1_seen = 1'b0;
  logic diff0_seen = 1'b0;
  logic diff1_seen = 1'b0;

  logic [31:0] pp0_val = 32'h0;
  logic [31:0] pp1_val = 32'h0;
  logic [31:0] red_result_val = 32'h0;
  logic [31:0] red_done_val = 32'h0;
  logic [31:0] same0_val = 32'h0;
  logic [31:0] same1_val = 32'h0;
  logic [31:0] diff0_val = 32'h0;
  logic [31:0] diff1_val = 32'h0;

  // Program image read from the generated hex file.
  localparam int IMG_WORDS = 2322;
  logic [31:0] img [0:IMG_WORDS-1];

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

  initial begin
    $readmemh("tb/sv/lcvex_c2_perf_mc.hex", img);
  end

  task automatic load_shared_mem();
    begin
      prog_we = 1'b1;
      for (int i = 0; i < IMG_WORDS; i++) begin
        prog_addr[0*64 +: 64] = BASE + 64'(4 * i);
        prog_strb[0*8 +: 8] = 8'h0f;
        prog_wdata[0*64 +: 64] = 64'(img[i]);
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
    cycle_count <= cycle_count + 1;

    for (int c = 0; c < CORE_COUNT; c++) begin
      if (mc_commit_valid[c] && mc_commit[c].commit.mem_we) begin
        if (!pp0_seen && mc_commit[c].commit.mem_addr == ADDR_PING_DONE0) begin
          pp0_seen <= 1'b1;
          pp0_cyc <= cycle_count;
          pp0_val <= mc_commit[c].commit.mem_wdata[31:0];
        end
        if (!pp1_seen && mc_commit[c].commit.mem_addr == ADDR_PING_DONE1) begin
          pp1_seen <= 1'b1;
          pp1_cyc <= cycle_count;
          pp1_val <= mc_commit[c].commit.mem_wdata[31:0];
        end
        if (!red_result_seen && mc_commit[c].commit.mem_addr == ADDR_RED_RESULT) begin
          red_result_seen <= 1'b1;
          red_result_cyc <= cycle_count;
          red_result_val <= mc_commit[c].commit.mem_wdata[31:0];
        end
        if (!red_done_seen && mc_commit[c].commit.mem_addr == ADDR_RED_DONE) begin
          red_done_seen <= 1'b1;
          red_done_cyc <= cycle_count;
          red_done_val <= mc_commit[c].commit.mem_wdata[31:0];
        end
        if (!same0_seen && mc_commit[c].commit.mem_addr == ADDR_SAME0_DONE) begin
          same0_seen <= 1'b1;
          same0_cyc <= cycle_count;
          same0_val <= mc_commit[c].commit.mem_wdata[31:0];
        end
        if (!same1_seen && mc_commit[c].commit.mem_addr == ADDR_SAME1_DONE) begin
          same1_seen <= 1'b1;
          same1_cyc <= cycle_count;
          same1_val <= mc_commit[c].commit.mem_wdata[31:0];
        end
        if (!diff0_seen && mc_commit[c].commit.mem_addr == ADDR_DIFF0_DONE) begin
          diff0_seen <= 1'b1;
          diff0_cyc <= cycle_count;
          diff0_val <= mc_commit[c].commit.mem_wdata[31:0];
        end
        if (!diff1_seen && mc_commit[c].commit.mem_addr == ADDR_DIFF1_DONE) begin
          diff1_seen <= 1'b1;
          diff1_cyc <= cycle_count;
          diff1_val <= mc_commit[c].commit.mem_wdata[31:0];
        end
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
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
    repeat (2) @(posedge clk);
    start_cyc = cycle_count;

    // Wait for both cores to finish all measured phases.
    for (int t = 0; t < 5000000; t++) begin
      @(posedge clk);
      if (diff0_seen && diff1_seen) break;
    end
    final_cyc = cycle_count;

    check(pp0_seen && pp1_seen, "pingpong done markers observed");
    check(red_result_seen && red_done_seen, "reduction result/done markers observed");
    check(same0_seen && same1_seen, "same-line done markers observed");
    check(diff0_seen && diff1_seen, "diff-line done markers observed");
    check(core_fault == '0, "no core fault in MC perf workload");
    check(pp0_val == 32'h12345678, "pingpong core0 marker value");
    check(pp1_val == 32'h87654321, "pingpong core1 marker value");
    check(red_result_val == 32'd64, "parallel reduction result is 64");
    check(red_done_val == 32'hABCDEF01, "reduction done marker value");
    check(same0_val == 32'h1111, "same-line core0 marker value");
    check(same1_val == 32'h3333, "same-line core1 marker value");
    check(diff0_val == 32'h2222, "diff-line core0 marker value");
    check(diff1_val == 32'h4444, "diff-line core1 marker value");

    if (pp0_seen && pp1_seen && red_done_seen && same0_seen && same1_seen &&
        diff0_seen && diff1_seen) begin
      automatic integer pp_end = (pp0_cyc > pp1_cyc) ? pp0_cyc : pp1_cyc;
      automatic integer same_end = (same0_cyc > same1_cyc) ? same0_cyc : same1_cyc;
      automatic integer diff_end = (diff0_cyc > diff1_cyc) ? diff0_cyc : diff1_cyc;
      automatic integer pp_cycles = pp_end - start_cyc;
      automatic integer red_cycles = red_done_cyc - pp_end;
      automatic integer same_cycles = same_end - red_done_cyc;
      automatic integer diff_cycles = diff_end - same_end;
      automatic integer total_cycles = final_cyc - start_cyc;
      $display("MC_PERF total=%0d start=%0d final=%0d", total_cycles, start_cyc, final_cyc);
      $display("MC_PERF pingpong=%0d cycles (%0d exchanges, %0d cyc/exchange)",
               pp_cycles, 16, pp_cycles / 16);
      $display("MC_PERF reduction=%0d cycles", red_cycles);
      $display("MC_PERF same_line=%0d cycles (32 stores/core)", same_cycles);
      $display("MC_PERF diff_line=%0d cycles (32 stores/core)", diff_cycles);
      $display("MC_PERF raw pp0=%0d pp1=%0d red_result=%0d red_done=%0d same0=%0d same1=%0d diff0=%0d diff1=%0d",
               pp0_cyc, pp1_cyc, red_result_cyc, red_done_cyc,
               same0_cyc, same1_cyc, diff0_cyc, diff1_cyc);
    end else begin
      $display("MC_PERF incomplete: pp=%0d/%0d red=%0d/%0d same=%0d/%0d diff=%0d/%0d",
               pp0_seen, pp1_seen, red_result_seen, red_done_seen,
               same0_seen, same1_seen, diff0_seen, diff1_seen);
    end

    if (errors == 0) $display("LCVEX_C2_PERF_MC_TB PASS");
    else $display("LCVEX_C2_PERF_MC_TB FAIL: %0d", errors);
    $finish;
  end

endmodule
