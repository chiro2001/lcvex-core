// lcvex_calibration_gate.sv
//
// EMIF calibration status crosses into the CPU domain through two-flop
// synchronizers. cal_fail is sticky until either reset is asserted. The
// adapter uses cal_abort to discard an already accepted normal transaction;
// a later transaction is accepted only for local DECERR and never reaches
// Avalon.
//
// The active-low reset inputs are the adapter's per-domain reset releases
// (async-assert / sync-deassert). The source (EMIF) latch uses the EMIF
// domain release and the CPU status flops use the CPU domain release, so no
// raw cross-domain reset drives the actual synchronizer flops.

`timescale 1ns/1ps

/* verilator lint_off SYNCASYNCNET */

module lcvex_calibration_gate (
    input  logic cpu_clk,
    input  logic emif_clk,
    input  logic cpu_rst_n_sync,
    input  logic emif_rst_n_sync,
    input  logic cal_success,
    input  logic cal_fail,
    output logic cal_ready_cpu,
    output logic cal_failed_cpu,
    output logic cal_abort_cpu
);

  logic success_cpu_meta_q;
  logic success_cpu_sync_q;
  logic fail_emif_latched_q;
  logic fail_cpu_meta_q;
  logic fail_cpu_sync_q;
  logic fail_cpu_latched_q;

  // The sticky latch lives in the source (EMIF) clock domain before the
  // status is synchronized. A one-cycle source indication therefore cannot
  // clear itself before the CPU sees it.
  always_ff @(posedge emif_clk or negedge emif_rst_n_sync) begin
    if (!emif_rst_n_sync) begin
      fail_emif_latched_q <= 1'b0;
    end else if (cal_fail) begin
      fail_emif_latched_q <= 1'b1;
    end
  end

  always_ff @(posedge cpu_clk or negedge cpu_rst_n_sync) begin
    if (!cpu_rst_n_sync) begin
      success_cpu_meta_q <= 1'b0;
      success_cpu_sync_q <= 1'b0;
      fail_cpu_meta_q <= 1'b0;
      fail_cpu_sync_q <= 1'b0;
      fail_cpu_latched_q <= 1'b0;
    end else begin
      success_cpu_meta_q <= cal_success;
      success_cpu_sync_q <= success_cpu_meta_q;
      fail_cpu_meta_q <= fail_emif_latched_q;
      fail_cpu_sync_q <= fail_cpu_meta_q;
      if (fail_cpu_sync_q) begin
        fail_cpu_latched_q <= 1'b1;
      end
    end
  end

  always_comb begin
    cal_failed_cpu = fail_cpu_latched_q | fail_cpu_sync_q;
    cal_abort_cpu = cal_failed_cpu;
    cal_ready_cpu = success_cpu_sync_q && !cal_failed_cpu;
  end

endmodule

/* verilator lint_on SYNCASYNCNET */
