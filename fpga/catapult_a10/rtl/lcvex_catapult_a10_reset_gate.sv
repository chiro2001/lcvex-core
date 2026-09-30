// lcvex_catapult_a10_reset_gate.sv
//
// B0+ platform clock/reset/calibration gate for the Catapult v3 / Arria 10
// shell.  This file is part of the regenerable Quartus/Qsys skeleton and is
// intentionally platform-local: it must not be confused with the general
// LCVEX calibration gate used inside the platform adapter.
//
// Boundary contract:
//   - logic_clk        : 25 MHz logic domain clock (sys_clk_25 in the top).
//   - emif_usr_clk     : EMIF user clock (266.666750 MHz), source domain of
//                        cal_success/cal_fail.
//   - emif_usr_rst_n   : active-low user reset provided by the EMIF Qsys.
//   - cal_success/fail : EMIF status pins, asynchronous to logic_clk.
//   - logic_rst_n      : power-on reset released in the logic domain.
//   - emif_rst_n       : user-domain reset passed through to B5/B2 wiring.
//   - cal_ready        : synchronized calibration-success indication.
//   - cal_failed       : sticky calibration-failure indication.
//   - ddr_en           : calibration gate output (cal_ready && !cal_failed).
//
// The gate does not implement DDR access, board reset input, JTAG or EPCQ
// control; B5 owns those paths.  No full-compile or STA claim is made.

`timescale 1ns/1ps

module lcvex_catapult_a10_reset_gate #(
    parameter int LOGIC_POR_CYCLES = 65536,  // ~2.62 ms at 25 MHz
    parameter int SYNC_STAGES      = 3
) (
    input  logic logic_clk,
    input  logic emif_usr_clk,
    input  logic emif_usr_rst_n,
    input  logic cal_success,
    input  logic cal_fail,
    output logic logic_rst_n,
    output logic emif_rst_n,
    output logic cal_ready,
    output logic cal_failed,
    output logic ddr_en
);

  localparam int POR_WIDTH = 32;

  // ---- logic-domain power-on reset ----
  // Initial values give deterministic behavior in simulation and a defined
  // power-up state in Quartus; there is no external board reset input in the
  // frozen B0 package.
  logic [POR_WIDTH-1:0] por_cnt_q = '0;
  logic logic_rst_n_q = 1'b0;

  always_ff @(posedge logic_clk) begin
    if (por_cnt_q < POR_WIDTH'(LOGIC_POR_CYCLES)) begin
      por_cnt_q     <= por_cnt_q + POR_WIDTH'(1);
      logic_rst_n_q <= 1'b0;
    end else begin
      logic_rst_n_q <= 1'b1;
    end
  end

  assign logic_rst_n = logic_rst_n_q;

  // ---- EMIF user reset pass-through (same user clock domain) ----
  assign emif_rst_n = emif_usr_rst_n;

  // ---- sticky calibration-failure latch in the source domain ----
  // A one-cycle cal_fail pulse is captured before it is synchronized, so the
  // logic domain cannot miss a short failure indication.
  logic fail_emif_latched_q = 1'b0;

  always_ff @(posedge emif_usr_clk) begin
    if (!emif_rst_n) begin
      fail_emif_latched_q <= 1'b0;
    end else if (cal_fail) begin
      fail_emif_latched_q <= 1'b1;
    end
  end

  // ---- calibrate status synchronizers (EMIF domain -> logic domain) ----
  logic [SYNC_STAGES-1:0] cal_success_sync_q = '0;
  logic [SYNC_STAGES-1:0] cal_fail_sync_q    = '0;
  logic cal_failed_q = 1'b0;

  always_ff @(posedge logic_clk) begin
    if (!logic_rst_n) begin
      cal_success_sync_q <= '0;
      cal_fail_sync_q    <= '0;
      cal_failed_q       <= 1'b0;
    end else begin
      cal_success_sync_q[0] <= cal_success;
      cal_fail_sync_q[0]    <= fail_emif_latched_q;
      for (int stage = 1; stage < SYNC_STAGES; stage++) begin
        cal_success_sync_q[stage] <= cal_success_sync_q[stage-1];
        cal_fail_sync_q[stage]    <= cal_fail_sync_q[stage-1];
      end
      if (cal_fail_sync_q[SYNC_STAGES-1]) begin
        cal_failed_q <= 1'b1;
      end
    end
  end

  assign cal_ready  = cal_success_sync_q[SYNC_STAGES-1] && !cal_failed_q;
  assign cal_failed = cal_failed_q;
  assign ddr_en     = cal_ready;

endmodule
