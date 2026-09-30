// lcvex_c3_sysctrl.sv
// C3 four-core system control lite: PSCI-like CPU_ON/OFF/RESET and a minimal
// GIC-lite SGI/IPI/event path.
//
// This is intentionally a small M1-B slave used by directed C3 tests.  It is
// not a full ARM GICv2/PSCI implementation; it only provides the per-core
// control and interrupt routing that C3 needs to demonstrate:
//   * software/mailbox-like CPU start/stop/reset;
//   * SGI/IPI route to selected cores;
//   * SEV/event route to selected cores;
//   * status visibility for testbench/software.
//
// The module does not contain cacheable shared-memory state.  All accesses
// are non-cacheable system MMIO (bypassed through the coherent cluster).

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off DECLFILENAME */

module lcvex_c3_sysctrl #(
    parameter int           CORE_COUNT   = 4,
    parameter int           CORE_ID_W    = 4,
    parameter logic [63:0]  SYS_BASE     = 64'h0000_0000_0903_0000,
    parameter logic [63:0]  SYS_TOP      = 64'h0000_0000_0903_1000
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // M1-B slave.
    input  logic                       req_valid,
    input  lcvex_pkg::mem_req_t        req,
    output logic                       req_accept,
    output logic                       rsp_valid,
    output lcvex_pkg::mem_rsp_t        rsp,
    input  logic                       rsp_ready,

    // Per-core control pulses.
    output logic [CORE_COUNT-1:0]      start_pulse,
    output logic [CORE_COUNT-1:0]      stop_pulse,
    output logic [CORE_COUNT-1:0]      reset_pulse,

    // Per-core interrupt/event outputs.
    output logic [CORE_COUNT-1:0]      irq_out,
    output logic [CORE_COUNT-1:0]      event_out,

    // Status inputs from the cluster.
    input  logic [CORE_COUNT-1:0]      core_running,
    input  logic [CORE_COUNT-1:0]      core_stopped,
    input  logic [CORE_COUNT-1:0]      core_fault
);

  import lcvex_pkg::*;

  logic [31:0] rdata_r;
  logic        fault_r;
  logic        rsp_pending;
  logic [CORE_COUNT-1:0] irq_pending_r;
  logic [CORE_COUNT-1:0] start_pulse_r;
  logic [CORE_COUNT-1:0] stop_pulse_r;
  logic [CORE_COUNT-1:0] reset_pulse_r;
  logic [CORE_COUNT-1:0] event_pulse_r;

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = {32'd0, rdata_r};
  assign rsp.fault  = fault_r;

  assign start_pulse = start_pulse_r;
  assign stop_pulse  = stop_pulse_r;
  assign reset_pulse = reset_pulse_r;
  assign irq_out     = irq_pending_r;
  assign event_out   = event_pulse_r;

  function automatic logic [CORE_COUNT-1:0] target_mask(input logic [63:0] d);
    logic [CORE_COUNT-1:0] m;
    begin
      m = '0;
      for (int i = 0; i < CORE_COUNT; i++) begin
        if (i < 64 && d[i]) m[i] = 1'b1;
      end
      target_mask = m;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdata_r       <= 32'd0;
      fault_r       <= 1'b0;
      rsp_pending   <= 1'b0;
      irq_pending_r <= '0;
      start_pulse_r <= '0;
      stop_pulse_r  <= '0;
      reset_pulse_r <= '0;
      event_pulse_r <= '0;
    end else begin
      start_pulse_r <= '0;
      stop_pulse_r  <= '0;
      reset_pulse_r <= '0;
      event_pulse_r <= '0;

      if (req_accept) begin
        rsp_pending <= 1'b1;
        fault_r     <= 1'b0;
        rdata_r     <= 32'd0;

        if (req.addr >= SYS_BASE && req.addr < SYS_TOP) begin
          automatic int off = int'(req.addr[11:0]);
          if (req.we) begin
            case (off)
              32'h00: start_pulse_r <= target_mask(req.wdata);
              32'h04: stop_pulse_r  <= target_mask(req.wdata);
              32'h08: reset_pulse_r <= target_mask(req.wdata);
              32'h10: irq_pending_r <= irq_pending_r | target_mask(req.wdata);
              32'h14: event_pulse_r <= target_mask(req.wdata);
              32'h20: irq_pending_r <= irq_pending_r & ~target_mask(req.wdata);
              default: fault_r <= 1'b1;
            endcase
          end else begin
            case (off)
              32'h18: rdata_r <= {16'd0, core_fault, core_stopped, core_running};
              default: rdata_r <= 32'hCAFE_C3;
            endcase
          end
        end else begin
          fault_r <= 1'b1;
        end
      end

      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;
      end
    end
  end

endmodule
