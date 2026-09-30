// lcvex_cluster_top.sv
// C1/C2/C3 parameterized multi-core cluster shell.
//
// This top is intentionally non-coherent when COHERENCE_ENABLE=0 (C1 private
// RAM path).  When COHERENCE_ENABLE=1 it instantiates a shared-L2 MSI cluster
// plus a small C3 system-control module that provides PSCI-like CPU_ON/OFF,
// reset, SGI/IPI and SEV/event routing for directed C3 tests.
//
// CORE_COUNT=1 retains the same private-RAM shell and does not modify the
// existing lcvex_catapult_soc_top path.

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off DECLFILENAME */

module lcvex_cluster_top #(
    parameter int           CORE_COUNT          = 2,
    parameter int           CORE_ID_W           = 4,
    parameter logic [63:0]  RESET_PC            = 64'h0000_0000_4000_0000,
    parameter logic [63:0]  SRAM_BASE           = 64'h0000_0000_4000_0000,
    parameter int           MEM_DEPTH           = 1 << 16,
    parameter int           LINE_BYTES          = 64,
    parameter int           L1_SETS             = 64,
    parameter int           L2_SETS             = 256,
    parameter int           L2_WAYS             = 2,
    parameter bit           COHERENCE_ENABLE    = 1'b0,
    parameter int           SOURCE_ID_W         = 4,
    parameter int           TRANSACTION_ID_W    = 8,
    parameter bit           AUTO_START          = 1'b1,
    parameter int           RESET_DELAY_CYCLES  = 3,
    parameter logic         A64_FP_SIMD         = 1'b1,
    parameter int           FETCH_FIFO_ENABLE   = 1,
    parameter int           FETCH_FIFO_DEPTH    = 2,
    parameter int           FETCH_EPOCH_W       = 8
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // Per-core lifecycle controls.
    input  logic [CORE_COUNT-1:0]      core_reset_pulse,
    input  logic [CORE_COUNT-1:0]      core_start_pulse,
    input  logic [CORE_COUNT-1:0]      core_stop_pulse,

    // Per-core IRQ and event inputs (event_in may additionally receive the
    // broadcast of another core's SEV).
    input  logic [CORE_COUNT-1:0]      irq,
    input  logic [CORE_COUNT-1:0]      event_in,
    input  logic [CORE_COUNT-1:0]      mc_commit_ready,

    // Per-core MC envelope / status outputs.
    output logic [CORE_COUNT-1:0]      mc_commit_valid,
    output lcvex_cluster_pkg::lcvex_mc_commit_t mc_commit [CORE_COUNT],
    output logic [CORE_COUNT-1:0]      core_running,
    output logic [CORE_COUNT-1:0]      core_stopped,
    output logic [CORE_COUNT-1:0]      core_wfi_idle,
    output logic [CORE_COUNT-1:0]      core_fault,
    output logic [CORE_COUNT-1:0]      sev_pulse,
    output logic [31:0]                mpidr [CORE_COUNT],

    // Per-core timer outputs.
    output logic [CORE_COUNT-1:0]      timer_phys_irq,
    output logic [CORE_COUNT-1:0]      timer_virt_irq,

    // Per-core flat commit observability.
    output logic [CORE_COUNT-1:0]      commit_valid,
    output logic [63:0]                commit_pc [CORE_COUNT],
    output logic [63:0]                commit_next_pc [CORE_COUNT],
    output logic [31:0]                commit_insn [CORE_COUNT],
    output logic [CORE_COUNT-1:0]      commit_gpr_we,
    output logic [4:0]                 commit_gpr_rd [CORE_COUNT],
    output logic [63:0]                commit_gpr_wdata [CORE_COUNT],
    output logic [31:0]                vcpu_seq [CORE_COUNT],
    output lcvex_cluster_pkg::lcvex_mc_event_t event_kind [CORE_COUNT],

    // Per-core checkpoint/drain passthrough.
    output logic [CORE_COUNT-1:0]      l1_drain_done,
    output logic [CORE_COUNT-1:0]      l1_drain_fault,
    output logic [CORE_COUNT-1:0]      l2_drain_ack_valid,
    output logic [CORE_COUNT-1:0]      l2_drain_fault,

    // Per-core private-memory program load ports.
    input  logic [CORE_COUNT-1:0]      prog_we,
    input  logic [CORE_COUNT*64-1:0]   prog_addr,
    input  logic [CORE_COUNT*8-1:0]    prog_strb,
    input  logic [CORE_COUNT*64-1:0]   prog_wdata
);

  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CLUSTER_MEM_LINES = MEM_DEPTH / LINE_BYTES;
  localparam logic [63:0] SYS_BASE = 64'h0000_0000_0903_0000;
  localparam logic [63:0] SYS_TOP  = 64'h0000_0000_0903_1000;

  // Per-core C2/C3 coherent cluster wiring.
  logic [CORE_COUNT-1:0]        cl_req_valid;
  logic [CORE_COUNT-1:0]        cl_req_ready;
  lcvex_coh_req_t               cl_req [CORE_COUNT];
  logic [CORE_COUNT-1:0]        cl_rsp_valid;
  logic [CORE_COUNT-1:0]        cl_rsp_ready;
  lcvex_coh_rsp_t               cl_rsp [CORE_COUNT];
  logic [CORE_COUNT-1:0]        probe_req_valid;
  logic [CORE_COUNT-1:0]        probe_req_ready;
  logic [63:0]                  probe_req_addr [CORE_COUNT];
  logic [1:0]                   probe_req_cmd [CORE_COUNT];
  logic [SOURCE_ID_W-1:0]       probe_req_source_id [CORE_COUNT];
  logic [TRANSACTION_ID_W-1:0]  probe_req_transaction_id [CORE_COUNT];
  logic [CORE_COUNT-1:0]        probe_rsp_valid;
  logic [CORE_COUNT-1:0]        probe_rsp_ready;
  logic [CORE_COUNT-1:0]        probe_rsp_fault;
  logic [CORE_COUNT-1:0]        probe_rsp_line_valid;
  logic [CORE_COUNT-1:0]        probe_rsp_dirty;
  logic [LINE_BYTES*8-1:0]      probe_rsp_data [CORE_COUNT];
  logic [63:0]                  probe_rsp_addr [CORE_COUNT];
  logic [SOURCE_ID_W-1:0]       probe_rsp_source_id [CORE_COUNT];
  logic [TRANSACTION_ID_W-1:0]  probe_rsp_transaction_id [CORE_COUNT];
  logic [CORE_COUNT-1:0]        probe_rsp_abort;

  // Shared PoC / system-control routing for coherent mode.
  logic                         poc_req_valid;
  mem_req_t                     poc_req;
  logic                         poc_req_ready;
  logic                         poc_rsp_valid;
  mem_rsp_t                     poc_rsp;
  logic                         poc_rsp_ready;
  logic                         shared_prog_we;
  logic [63:0]                  shared_prog_addr;
  logic [7:0]                   shared_prog_strb;
  logic [63:0]                  shared_prog_wdata;

  logic                         sys_sel;
  logic                         sys_target_r;
  logic                         ram_req_valid;
  mem_req_t                     ram_req;
  logic                         ram_req_accept;
  logic                         ram_rsp_valid;
  mem_rsp_t                     ram_rsp;
  logic                         ram_rsp_ready;
  logic                         sys_req_valid;
  mem_req_t                     sys_req;
  logic                         sys_req_accept;
  logic                         sys_rsp_valid;
  mem_rsp_t                     sys_rsp;
  logic                         sys_rsp_ready;

  // Effective per-core control/interrupt inputs.
  logic [CORE_COUNT-1:0]        start_eff;
  logic [CORE_COUNT-1:0]        stop_eff;
  logic [CORE_COUNT-1:0]        reset_eff;
  logic [CORE_COUNT-1:0]        irq_eff;
  logic [CORE_COUNT-1:0]        event_eff;

  // System-control outputs (tied off when coherence is disabled).
  logic [CORE_COUNT-1:0]        sys_start_pulse;
  logic [CORE_COUNT-1:0]        sys_stop_pulse;
  logic [CORE_COUNT-1:0]        sys_reset_pulse;
  logic [CORE_COUNT-1:0]        sys_irq;
  logic [CORE_COUNT-1:0]        sys_event;

  assign shared_prog_we     = prog_we[0];
  assign shared_prog_addr   = prog_addr[0*64 +: 64];
  assign shared_prog_strb   = prog_strb[0*8 +: 8];
  assign shared_prog_wdata  = prog_wdata[0*64 +: 64];

  logic [SOURCE_ID_W-1:0]      tie_cl_source [CORE_COUNT];
  logic [TRANSACTION_ID_W-1:0] tie_cl_transaction [CORE_COUNT];
  always_comb begin
    for (int ti = 0; ti < CORE_COUNT; ti++) begin
      tie_cl_source[ti] = '0;
      tie_cl_transaction[ti] = '0;
    end
  end

  // Internal per-core event inputs include external event_in plus SEV
  // broadcast from the other wrappers and any system-control event pulse.
  always_comb begin
    for (int i = 0; i < CORE_COUNT; i++) begin
      event_eff[i] = event_in[i] | sys_event[i];
      for (int j = 0; j < CORE_COUNT; j++) begin
        if (j != i) begin
          event_eff[i] = event_eff[i] | sev_pulse[j];
        end
      end
    end
  end

  // Effective lifecycle and interrupt inputs combine testbench rails with
  // the C3 system-control MMIO outputs.
  always_comb begin
    for (int i = 0; i < CORE_COUNT; i++) begin
      start_eff[i] = core_start_pulse[i] | sys_start_pulse[i];
      stop_eff[i]  = core_stop_pulse[i]  | sys_stop_pulse[i];
      reset_eff[i] = core_reset_pulse[i] | sys_reset_pulse[i];
      irq_eff[i]   = irq[i] | sys_irq[i];
    end
  end

  for (genvar i = 0; i < CORE_COUNT; i++) begin : g_cores
    lcvex_core_wrap #(
        .CORE_ID(i),
        .CORE_ID_W(CORE_ID_W),
        .RESET_PC(COHERENCE_ENABLE ? (RESET_PC + 64'(i * 64'h100)) : RESET_PC),
        .SRAM_BASE(SRAM_BASE),
        .MEM_DEPTH(MEM_DEPTH),
        .LINE_BYTES(LINE_BYTES),
        .L1_SETS(L1_SETS),
        .L2_SETS(L2_SETS),
        .L2_WAYS(L2_WAYS),
        .COHERENCE_ENABLE(COHERENCE_ENABLE),
        .SOURCE_ID_W(SOURCE_ID_W),
        .TRANSACTION_ID_W(TRANSACTION_ID_W),
        .AUTO_START(AUTO_START),
        .RESET_DELAY_CYCLES(RESET_DELAY_CYCLES),
        .A64_FP_SIMD(A64_FP_SIMD),
        .FETCH_FIFO_ENABLE(FETCH_FIFO_ENABLE),
        .FETCH_FIFO_DEPTH(FETCH_FIFO_DEPTH),
        .FETCH_EPOCH_W(FETCH_EPOCH_W)
    ) wrap (
        .clk(clk),
        .rst_n(rst_n),
        .core_reset_pulse(reset_eff[i]),
        .core_start_pulse(start_eff[i]),
        .core_stop_pulse(stop_eff[i]),
        .irq(irq_eff[i]),
        .event_in(event_eff[i]),
        .mc_commit_ready(mc_commit_ready[i]),
        .mc_commit_valid(mc_commit_valid[i]),
        .mc_commit(mc_commit[i]),
        .core_running(core_running[i]),
        .core_stopped(core_stopped[i]),
        .core_wfi_idle(core_wfi_idle[i]),
        .core_fault(core_fault[i]),
        .mpidr(mpidr[i]),
        .timer_phys_irq(timer_phys_irq[i]),
        .timer_virt_irq(timer_virt_irq[i]),
        .sev_pulse(sev_pulse[i]),
        .l1_drain_done(l1_drain_done[i]),
        .l1_drain_fault(l1_drain_fault[i]),
        .l2_drain_ack_valid(l2_drain_ack_valid[i]),
        .l2_drain_fault(l2_drain_fault[i]),
        .prog_we(prog_we[i]),
        .prog_addr(prog_addr[i*64 +: 64]),
        .prog_strb(prog_strb[i*8 +: 8]),
        .prog_wdata(prog_wdata[i*64 +: 64]),
        .cl_req_valid(cl_req_valid[i]),
        .cl_req_ready(cl_req_ready[i]),
        .cl_req(cl_req[i]),
        .cl_rsp_valid(cl_rsp_valid[i]),
        .cl_rsp_ready(cl_rsp_ready[i]),
        .cl_rsp(cl_rsp[i]),
        .probe_req_valid(probe_req_valid[i]),
        .probe_req_ready(probe_req_ready[i]),
        .probe_req_addr(probe_req_addr[i]),
        .probe_req_cmd(probe_req_cmd[i]),
        .probe_req_source_id(probe_req_source_id[i]),
        .probe_req_transaction_id(probe_req_transaction_id[i]),
        .probe_rsp_valid(probe_rsp_valid[i]),
        .probe_rsp_ready(probe_rsp_ready[i]),
        .probe_rsp_fault(probe_rsp_fault[i]),
        .probe_rsp_line_valid(probe_rsp_line_valid[i]),
        .probe_rsp_dirty(probe_rsp_dirty[i]),
        .probe_rsp_data(probe_rsp_data[i]),
        .probe_rsp_addr(probe_rsp_addr[i]),
        .probe_rsp_source_id(probe_rsp_source_id[i]),
        .probe_rsp_transaction_id(probe_rsp_transaction_id[i]),
        .probe_rsp_abort(probe_rsp_abort[i]),
        .commit_valid(commit_valid[i]),
        .commit_pc(commit_pc[i]),
        .commit_next_pc(commit_next_pc[i]),
        .commit_insn(commit_insn[i]),
        .commit_gpr_we(commit_gpr_we[i]),
        .commit_gpr_rd(commit_gpr_rd[i]),
        .commit_gpr_wdata(commit_gpr_wdata[i]),
        .vcpu_seq(vcpu_seq[i]),
        .event_kind(event_kind[i]),
        .core_id_out()
    );
  end

  // C2/C3 coherent shared-L2 directory + shared PoC RAM + system control.
  generate
    if (COHERENCE_ENABLE) begin : g_c2_shared
      assign sys_sel = poc_req_valid ?
                       (poc_req.bypass &&
                        (poc_req.addr >= SYS_BASE) &&
                        (poc_req.addr < SYS_TOP)) : sys_target_r;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sys_target_r <= 1'b0;
        end else if (poc_req_valid && poc_req_ready) begin
          sys_target_r <= (poc_req.bypass &&
                           (poc_req.addr >= SYS_BASE) &&
                           (poc_req.addr < SYS_TOP));
        end
      end

      assign ram_req_valid = poc_req_valid && !sys_sel;
      assign ram_req = poc_req;
      assign sys_req_valid = poc_req_valid && sys_sel;
      assign sys_req = poc_req;
      assign poc_req_ready = sys_sel ? sys_req_accept : ram_req_accept;
      assign poc_rsp_valid = sys_sel ? sys_rsp_valid : ram_rsp_valid;
      assign poc_rsp = sys_sel ? sys_rsp : ram_rsp;
      assign sys_rsp_ready = poc_rsp_ready && sys_sel;
      assign ram_rsp_ready = poc_rsp_ready && !sys_sel;

      lcvex_l2_cluster #(
          .CORE_COUNT(CORE_COUNT),
          .CORE_ID_W(CORE_ID_W),
          .SOURCE_ID_W(SOURCE_ID_W),
          .TRANSACTION_ID_W(TRANSACTION_ID_W),
          .LINE_BYTES(LINE_BYTES),
          .MEM_BASE(SRAM_BASE),
          .MEM_LINES(CLUSTER_MEM_LINES)
      ) cluster (
          .clk(clk), .rst_n(rst_n),
          .req_valid(cl_req_valid), .req_ready(cl_req_ready),
          .req(cl_req),
          .req_source_id(tie_cl_source),
          .req_transaction_id(tie_cl_transaction),
          .rsp_valid(cl_rsp_valid), .rsp_ready(cl_rsp_ready),
          .rsp(cl_rsp), .rsp_source_id(), .rsp_transaction_id(),
          .probe_req_valid(probe_req_valid),
          .probe_req_ready(probe_req_ready),
          .probe_req_addr(probe_req_addr),
          .probe_req_cmd(probe_req_cmd),
          .probe_req_source_id(probe_req_source_id),
          .probe_req_transaction_id(probe_req_transaction_id),
          .probe_rsp_valid(probe_rsp_valid),
          .probe_rsp_ready(probe_rsp_ready),
          .probe_rsp_fault(probe_rsp_fault),
          .probe_rsp_line_valid(probe_rsp_line_valid),
          .probe_rsp_dirty(probe_rsp_dirty),
          .probe_rsp_data(probe_rsp_data),
          .probe_rsp_addr(probe_rsp_addr),
          .probe_rsp_source_id(probe_rsp_source_id),
          .probe_rsp_transaction_id(probe_rsp_transaction_id),
          .probe_rsp_abort(probe_rsp_abort),
          .poc_req_valid(poc_req_valid), .poc_req(poc_req),
          .poc_req_ready(poc_req_ready), .poc_rsp_valid(poc_rsp_valid),
          .poc_rsp(poc_rsp), .poc_rsp_ready(poc_rsp_ready),
          .dir_valid_dbg(), .dir_state_dbg(), .dir_sharers_dbg(),
          .dir_owner_dbg(), .dir_dirty_dbg(), .dir_pending_dbg(),
          .dbg_cur_core(), .dbg_cur_state()
      );

      lcvex_mem_ram #(
          .DEPTH(MEM_DEPTH), .SRAM_BASE(SRAM_BASE)
      ) shared_ram (
          .clk(clk), .rst_n(rst_n),
          .req_valid(ram_req_valid), .req(ram_req),
          .req_accept(ram_req_accept),
          .rsp_valid(ram_rsp_valid), .rsp(ram_rsp),
          .rsp_ready(ram_rsp_ready),
          .prog_we(shared_prog_we), .prog_addr(shared_prog_addr),
          .prog_strb(shared_prog_strb), .prog_wdata(shared_prog_wdata),
          .dbg_addr(32'd0), .dbg_rdata()
      );

      lcvex_c3_sysctrl #(
          .CORE_COUNT(CORE_COUNT),
          .CORE_ID_W(CORE_ID_W),
          .SYS_BASE(SYS_BASE),
          .SYS_TOP(SYS_TOP)
      ) sysctrl (
          .clk(clk), .rst_n(rst_n),
          .req_valid(sys_req_valid), .req(sys_req),
          .req_accept(sys_req_accept),
          .rsp_valid(sys_rsp_valid), .rsp(sys_rsp),
          .rsp_ready(sys_rsp_ready),
          .start_pulse(sys_start_pulse),
          .stop_pulse(sys_stop_pulse),
          .reset_pulse(sys_reset_pulse),
          .irq_out(sys_irq),
          .event_out(sys_event),
          .core_running(core_running),
          .core_stopped(core_stopped),
          .core_fault(core_fault)
      );
    end else begin : g_noncoherent
      assign sys_sel = 1'b0;
      assign ram_req_valid = 1'b0;
      assign ram_req = '0;
      assign sys_req_valid = 1'b0;
      assign sys_req = '0;
      assign poc_req_ready = 1'b0;
      assign poc_rsp_valid = 1'b0;
      assign poc_rsp = '0;
      assign sys_rsp_ready = 1'b0;
      assign ram_rsp_ready = 1'b0;
      assign sys_start_pulse = '0;
      assign sys_stop_pulse  = '0;
      assign sys_reset_pulse = '0;
      assign sys_irq = '0;
      assign sys_event = '0;
    end
  endgenerate

endmodule
