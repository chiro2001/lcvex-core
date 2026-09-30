// lcvex_core_wrap.sv
// C1 dual-core shell: per-core wrapper around an unmodified lcvex_core.
//
// C1 deliberately does not implement coherence.  Each wrapper owns a private
// RAM (and its own private I/D-L1/L2 cache hierarchy through the existing
// lcvex_catapult_soc_coh).  There is no shared directory, no cross-core
// snoop, and no shared L2.  The wrappers only share the global clock and
// reset; every other control/commit/event path is per-core.

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off DECLFILENAME */

module lcvex_core_wrap #(
    parameter int           CORE_ID            = 0,
    parameter int           CORE_ID_W          = 4,
    parameter logic [63:0]  RESET_PC           = 64'h0000_0000_4000_0000,
    parameter logic [63:0]  SRAM_BASE          = 64'h0000_0000_4000_0000,
    parameter int           MEM_DEPTH          = 1 << 16,   // 64 KiB per core
    parameter int           LINE_BYTES         = 64,
    parameter int           L1_SETS            = 64,
    parameter int           L2_SETS            = 256,
    parameter int           L2_WAYS            = 2,
    parameter bit           COHERENCE_ENABLE   = 1'b0,
    parameter int           SOURCE_ID_W        = 4,
    parameter int           TRANSACTION_ID_W   = 8,
    parameter bit           AUTO_START         = 1'b1,
    parameter int           RESET_DELAY_CYCLES = 3,
    parameter logic         A64_FP_SIMD        = 1'b1,
    parameter int           FETCH_FIFO_ENABLE  = 1,
    parameter int           FETCH_FIFO_DEPTH   = 2,
    parameter int           FETCH_EPOCH_W      = 8
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // Per-core lifecycle (C1 shell uses simple pulse controls).
    input  logic                       core_reset_pulse,
    input  logic                       core_start_pulse,
    input  logic                       core_stop_pulse,

    // Per-core asynchronous interrupt/event/timer observation.
    input  logic                       irq,
    input  logic                       event_in,
    input  logic                       mc_commit_ready,

    output logic                       mc_commit_valid,
    output lcvex_cluster_pkg::lcvex_mc_commit_t mc_commit,

    output logic                       core_running,
    output logic                       core_stopped,
    output logic                       core_wfi_idle,
    output logic                       core_fault,
    output logic [31:0]                mpidr,
    output logic                       timer_phys_irq,
    output logic                       timer_virt_irq,
    output logic                       sev_pulse,

    // Checkpoint passthrough (not used by C1 directed tests but kept visible).
    output logic                       l1_drain_done,
    output logic                       l1_drain_fault,
    output logic                       l2_drain_ack_valid,
    output logic                       l2_drain_fault,

    // Private memory program-load port.
    input  logic                       prog_we,
    input  logic [63:0]                prog_addr,
    input  logic [7:0]                 prog_strb,
    input  logic [63:0]                prog_wdata,

    // C2 coherent cluster ports.  Unused when COHERENCE_ENABLE=0.
    output logic                       cl_req_valid,
    input  logic                       cl_req_ready,
    output lcvex_cluster_pkg::lcvex_coh_req_t cl_req,
    input  logic                       cl_rsp_valid,
    output logic                       cl_rsp_ready,
    input  lcvex_cluster_pkg::lcvex_coh_rsp_t cl_rsp,
    input  logic                       probe_req_valid,
    output logic                       probe_req_ready,
    input  logic [63:0]                probe_req_addr,
    input  logic [1:0]                 probe_req_cmd,
    input  logic [SOURCE_ID_W-1:0]     probe_req_source_id,
    input  logic [TRANSACTION_ID_W-1:0] probe_req_transaction_id,
    output logic                       probe_rsp_valid,
    input  logic                       probe_rsp_ready,
    output logic                       probe_rsp_fault,
    output logic                       probe_rsp_line_valid,
    output logic                       probe_rsp_dirty,
    output logic [LINE_BYTES*8-1:0]    probe_rsp_data,
    output logic [63:0]                probe_rsp_addr,
    output logic [SOURCE_ID_W-1:0]     probe_rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0] probe_rsp_transaction_id,
    input  logic                       probe_rsp_abort,

    // Flat per-core commit observability (subset of lcvex_commit_packet_t).
    output logic                       commit_valid,
    output logic [63:0]                commit_pc,
    output logic [63:0]                commit_next_pc,
    output logic [31:0]                commit_insn,
    output logic                       commit_gpr_we,
    output logic [4:0]                 commit_gpr_rd,
    output logic [63:0]                commit_gpr_wdata,
    output logic [31:0]                vcpu_seq,
    output lcvex_cluster_pkg::lcvex_mc_event_t event_kind,
    output logic [CORE_ID_W-1:0]       core_id_out
);

  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  // ------------------------------------------------------------------
  // Lifecycle state machine
  // ------------------------------------------------------------------
  localparam logic [1:0] S_RESET   = 2'd0;
  localparam logic [1:0] S_RUNNING = 2'd1;
  localparam logic [1:0] S_STOPPED = 2'd2;

  logic [1:0] state;
  logic [7:0] reset_cnt;

  assign core_running = (state == S_RUNNING);
  assign core_stopped = (state == S_STOPPED);
  assign core_fault   = 1'b0;    // C1 has no memory-fault/kill state machine.
  assign core_id_out  = CORE_ID_W'(CORE_ID);

  logic core_rst_n;
  logic core_clk;
  assign core_rst_n = rst_n && (state != S_RESET);
  // Keep the core clock live while in RESET so the asynchronous reset block
  // can reliably initialize if_pc/RESET_PC; STOPPED still gates the clock.
  assign core_clk   = clk && (core_running || (state == S_RESET));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_RESET;
      reset_cnt <= RESET_DELAY_CYCLES[7:0];
    end else begin
      if (core_reset_pulse) begin
        state     <= S_RESET;
        reset_cnt <= RESET_DELAY_CYCLES[7:0];
      end else begin
        case (state)
          S_RESET: begin
            if (reset_cnt > 8'd0) begin
              reset_cnt <= reset_cnt - 8'd1;
            end else if (AUTO_START && !core_stop_pulse) begin
              state <= S_RUNNING;
            end else begin
              state <= S_STOPPED;
            end
          end
          S_RUNNING: begin
            if (core_stop_pulse) begin
              state <= S_STOPPED;
            end
          end
          S_STOPPED: begin
            if (core_start_pulse) begin
              state <= S_RUNNING;
            end
          end
          default: state <= S_RESET;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // Core instance (unmodified lcvex_core)
  // ------------------------------------------------------------------
  logic        imem_req_valid;
  mem_req_t    imem_req;
  logic        imem_req_ready;
  logic        imem_rsp_valid;
  mem_rsp_t    imem_rsp;
  logic        imem_rsp_ready;

  logic        dmem_req_valid;
  mem_req_t    dmem_req;
  logic        dmem_req_ready;
  logic        dmem_rsp_valid;
  mem_rsp_t    dmem_rsp;
  logic        dmem_rsp_ready;

  logic        ptw_req_valid;
  mem_req_t    ptw_req;
  logic        ptw_req_ready;
  logic        ptw_rsp_valid;
  mem_rsp_t    ptw_rsp;
  logic        ptw_rsp_ready;

  lcvex_pkg::commit_packet_t core_commit;
  logic [31:0] fpcr_state;
  logic [31:0] fpsr_state;
  logic [63:0] fp_cpacr_el1_state;
  logic [63:0] fp_v_lo [0:31];
  logic [63:0] fp_v_hi [0:31];

  logic [63:0] difftest_restore_fp_v_lo [0:31];
  logic [63:0] difftest_restore_fp_v_hi [0:31];

  always_comb begin
    for (int i = 0; i < 32; i++) begin
      difftest_restore_fp_v_lo[i] = 64'd0;
      difftest_restore_fp_v_hi[i] = 64'd0;
    end
  end

  // C1 wrapper uses the existing difftest_wait_release sideband as the
  // per-core event wake path because lcvex_core has no public event_in port.
  // This is explicitly a shell-level simulation/reference sideband, not an
  // architectural claim about ARM WFE.
  logic event_wake;
  assign event_wake = event_in && core_running;

  lcvex_core #(
      .RESET_PC (RESET_PC),
      .SRAM_BASE(SRAM_BASE),
      .SRAM_TOP (SRAM_BASE + 64'(MEM_DEPTH)),
      .MMIO_BASE(64'h0000_0000_0900_0000),
      .MMIO_TOP (64'h0000_0000_0900_1000),
      .MMIO2_BASE(64'h0000_0000_0800_0000),
      .MMIO2_TOP (64'h0000_0000_0802_1000),
      .MMIO3_BASE(64'h0000_0000_0903_0000),
      .MMIO3_TOP (64'h0000_0000_0903_1000),
      .MMIO4_BASE(64'h0000_0000_0901_0000),
      .MMIO4_TOP (64'h0000_0000_0a02_0000),
      .A64_FP_SIMD(A64_FP_SIMD),
      .FETCH_FIFO_ENABLE(FETCH_FIFO_ENABLE),
      .FETCH_FIFO_DEPTH(FETCH_FIFO_DEPTH),
      .FETCH_EPOCH_W(FETCH_EPOCH_W)
  ) core (
      .clk                    (core_clk),
      .rst_n                  (core_rst_n),
      .commit_ready           (mc_commit_ready),
      .commit                 (core_commit),
      .fpcr_state             (fpcr_state),
      .fpsr_state             (fpsr_state),
      .fp_cpacr_el1_state     (fp_cpacr_el1_state),
      .fp_v_lo                (fp_v_lo),
      .fp_v_hi                (fp_v_hi),
      .imem_req_valid         (imem_req_valid),
      .imem_req               (imem_req),
      .imem_req_ready         (imem_req_ready),
      .imem_rsp_valid         (imem_rsp_valid),
      .imem_rsp               (imem_rsp),
      .imem_rsp_ready         (imem_rsp_ready),
      .dmem_req_valid         (dmem_req_valid),
      .dmem_req               (dmem_req),
      .dmem_req_ready         (dmem_req_ready),
      .dmem_rsp_valid         (dmem_rsp_valid),
      .dmem_rsp               (dmem_rsp),
      .dmem_rsp_ready         (dmem_rsp_ready),
      .ptw_req_valid          (ptw_req_valid),
      .ptw_req                (ptw_req),
      .ptw_req_ready          (ptw_req_ready),
      .ptw_rsp_valid          (ptw_rsp_valid),
      .ptw_rsp                (ptw_rsp),
      .ptw_rsp_ready          (ptw_rsp_ready),
      .tlb_invalidate         (),
      .timer_phys_irq         (timer_phys_irq),
      .timer_virt_irq         (timer_virt_irq),
      .irq                    (irq),
      .difftest_wait_release  (event_wake),
      .difftest_wait_cntvct_valid(1'b0),
      .difftest_wait_cntvct   (64'd0),
      .difftest_restore_sys_valid(1'b0),
      .difftest_restore_fp_valid(1'b0),
      .difftest_restore_fpcr  (32'd0),
      .difftest_restore_fpsr  (32'd0),
      .difftest_restore_fp_v_lo(difftest_restore_fp_v_lo),
      .difftest_restore_fp_v_hi(difftest_restore_fp_v_hi),
      .difftest_restore_pc    (64'd0),
      .difftest_restore_sp_el0(64'd0),
      .difftest_restore_sp_el1(64'd0),
      .difftest_restore_nzcv  (4'd0),
      .difftest_restore_el    (1'b0),
      .difftest_restore_sp_sel(1'b0),
      .difftest_restore_daif  (4'd0),
      .difftest_restore_pan   (1'b0),
      .difftest_restore_dit   (1'b0),
      .difftest_restore_ssbs  (1'b0),
      .difftest_restore_uao   (1'b0),
      .difftest_restore_tco   (1'b0),
      .difftest_restore_allint(1'b0),
      .difftest_restore_elr_el1(64'd0),
      .difftest_restore_spsr_el1(64'd0),
      .difftest_restore_vbar_el1(64'd0),
      .difftest_restore_sctlr_el1(64'd0),
      .difftest_restore_tcr_el1(64'd0),
      .difftest_restore_ttbr0_el1(64'd0),
      .difftest_restore_ttbr1_el1(64'd0),
      .difftest_restore_mair_el1(64'd0),
      .difftest_restore_esr_el1(32'd0),
      .difftest_restore_far_el1(64'd0),
      .difftest_restore_par_el1(64'd0),
      .difftest_restore_cpacr_el1(64'd0),
      .difftest_restore_mdscr_el1(64'd0),
      .difftest_restore_pmuserenr_el0(64'd0),
      .difftest_restore_cntkctl_el1(64'd0),
      .difftest_restore_tpidr_el0(64'd0),
      .difftest_restore_tpidrro_el0(64'd0),
      .difftest_restore_tpidr_el1(64'd0),
      .difftest_restore_pir_el1(64'd0),
      .difftest_restore_pire0_el1(64'd0),
      .difftest_restore_zcr_el1(64'd0),
      .difftest_restore_smcr_el1(64'd0),
      .difftest_restore_csselr_el1(64'd0),
      .difftest_restore_tcr2_el1(64'd0),
      .difftest_restore_contextidr_el1(64'd0),
      .difftest_restore_excl_valid(1'b0),
      .difftest_restore_excl_addr(64'd0),
      .difftest_restore_excl_data(64'd0),
      .difftest_restore_excl_data_hi(64'd0),
      .difftest_restore_cntpct(64'd0),
      .difftest_restore_cntp_cval(64'd0),
      .difftest_restore_cntp_ctl(2'd0),
      .difftest_restore_cntv_cval(64'd0),
      .difftest_restore_cntv_ctl(2'd0)
  );

  // ------------------------------------------------------------------
  // Private memory path (C1: no shared cache hierarchy, no coherence).
  // The core's imem/dmem/PTW requests are arbitrated into one private RAM.
  // This is a C1 shell simplification: caches are bypassed and each core
  // sees only its own private address space.
  logic [2:0]         arb_req_valid;
  mem_req_t [2:0]     arb_req;
  logic [2:0]         arb_req_ready;
  logic [2:0]         arb_rsp_valid;
  mem_rsp_t [2:0]     arb_rsp;
  logic [2:0]         arb_rsp_ready;

  logic               arb_mem_req_valid;
  mem_req_t           arb_mem_req;
  logic               arb_mem_req_accept;
  logic               arb_mem_rsp_valid;
  mem_rsp_t           arb_mem_rsp;
  logic               arb_mem_rsp_ready;

  // Port 0 = PTW (highest priority), port 1 = data, port 2 = instruction.
  assign arb_req_valid[0] = ptw_req_valid;
  assign arb_req[0]       = ptw_req;
  assign ptw_req_ready    = arb_req_ready[0];
  assign ptw_rsp_valid    = arb_rsp_valid[0];
  assign ptw_rsp          = arb_rsp[0];
  assign arb_rsp_ready[0] = ptw_rsp_ready;

  assign arb_req_valid[1] = dmem_req_valid;
  assign arb_req[1]       = dmem_req;
  assign dmem_req_ready   = arb_req_ready[1];
  assign dmem_rsp_valid   = arb_rsp_valid[1];
  assign dmem_rsp         = arb_rsp[1];
  assign arb_rsp_ready[1] = dmem_rsp_ready;

  assign arb_req_valid[2] = imem_req_valid;
  assign arb_req[2]       = imem_req;
  assign imem_req_ready   = arb_req_ready[2];
  assign imem_rsp_valid   = arb_rsp_valid[2];
  assign imem_rsp         = arb_rsp[2];
  assign arb_rsp_ready[2] = imem_rsp_ready;

  lcvex_mem_arb #(
      .PORTS(3)
  ) mem_arb (
      .clk(clk), .rst_n(core_rst_n),
      .req_valid(arb_req_valid), .req(arb_req),
      .req_ready(arb_req_ready),
      .rsp_valid(arb_rsp_valid), .rsp(arb_rsp),
      .rsp_ready(arb_rsp_ready),
      .mem_req_valid(arb_mem_req_valid), .mem_req(arb_mem_req),
      .mem_req_accept(arb_mem_req_accept),
      .mem_rsp_valid(arb_mem_rsp_valid), .mem_rsp(arb_mem_rsp),
      .mem_rsp_ready(arb_mem_rsp_ready)
  );

  generate
    if (COHERENCE_ENABLE) begin : g_coherent_mem
      logic l1_cl_req_valid;
      assign cl_req_valid = l1_cl_req_valid && core_running;
      lcvex_c2_l1_coherent #(
          .LINE_BYTES(LINE_BYTES),
          .SETS(L1_SETS),
          .CORE_ID_W(CORE_ID_W),
          .SOURCE_ID_W(SOURCE_ID_W),
          .TRANSACTION_ID_W(TRANSACTION_ID_W)
      ) l1coh (
          .clk(clk), .rst_n(core_rst_n),
          .u_req_valid(arb_mem_req_valid), .u_req(arb_mem_req),
          .u_req_ready(arb_mem_req_accept),
          .u_rsp_valid(arb_mem_rsp_valid), .u_rsp(arb_mem_rsp),
          .u_rsp_ready(arb_mem_rsp_ready),
          .cl_req_valid(l1_cl_req_valid), .cl_req_ready(cl_req_ready),
          .cl_req(cl_req), .cl_rsp_valid(cl_rsp_valid),
          .cl_rsp_ready(cl_rsp_ready), .cl_rsp(cl_rsp),
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
          .probe_rsp_abort(probe_rsp_abort)
      );
    end else begin : g_private_ram
      lcvex_mem_ram #(
          .DEPTH(MEM_DEPTH), .SRAM_BASE(SRAM_BASE)
      ) ram (
          .clk(clk), .rst_n(core_rst_n),
          .req_valid(arb_mem_req_valid), .req(arb_mem_req),
          .req_accept(arb_mem_req_accept),
          .rsp_valid(arb_mem_rsp_valid), .rsp(arb_mem_rsp),
          .rsp_ready(arb_mem_rsp_ready),
          .prog_we(prog_we), .prog_addr(prog_addr),
          .prog_strb(prog_strb), .prog_wdata(prog_wdata),
          .dbg_addr(32'd0), .dbg_rdata()
      );
    end
  endgenerate

  // When coherence is disabled, keep the optional C2 outputs deterministically
  // tied off so the C1 private-RAM shell remains fully self-contained.
  if (!COHERENCE_ENABLE) begin : g_tie_coherence_outputs
    assign cl_req_valid        = 1'b0;
    assign cl_req              = '0;
    assign cl_rsp_ready        = 1'b0;
    assign probe_rsp_valid     = 1'b0;
    assign probe_rsp_fault     = 1'b0;
    assign probe_rsp_line_valid = 1'b0;
    assign probe_rsp_dirty     = 1'b0;
    assign probe_rsp_data      = '0;
    assign probe_rsp_addr      = '0;
    assign probe_rsp_source_id = '0;
    assign probe_rsp_transaction_id = '0;
  end

  // C1 shell has no drain/checkpoint path; these are kept as tied-off
  // observability ports for possible future C2 integration.
  assign l1_drain_done     = 1'b0;
  assign l1_drain_fault    = 1'b0;
  assign l2_drain_ack_valid = 1'b0;
  assign l2_drain_fault    = 1'b0;

  // ------------------------------------------------------------------
  // Local WFI/WFE/event observability and commit envelope
  // ------------------------------------------------------------------
  logic        commit_wfi_seen;
  logic        commit_wfe_seen;
  logic        commit_async_irq;
  logic        commit_sev_seen;
  logic [31:0] vcpu_seq_r;
  logic        event_pending_r;

  logic [31:0] vcpu_seq_cur;
  assign vcpu_seq_cur = commit_valid ? (vcpu_seq_r + 32'd1) : vcpu_seq_r;

  assign commit_valid      = core_commit.valid && core_running;
  assign commit_pc         = core_commit.pc;
  assign commit_next_pc    = core_commit.next_pc;
  assign commit_insn       = core_commit.insn;
  assign commit_gpr_we     = core_commit.gpr_we;
  assign commit_gpr_rd     = core_commit.gpr_rd;
  assign commit_gpr_wdata  = core_commit.gpr_wdata;
  assign vcpu_seq          = vcpu_seq_cur;
  assign mc_commit_valid   = commit_valid;

  always_comb begin
    commit_wfi_seen  = commit_valid && (core_commit.insn == INSN_WFI);
    commit_wfe_seen  = commit_valid && (core_commit.insn == INSN_WFE);
    commit_async_irq = commit_valid && core_commit.exc_valid &&
                       (core_commit.exc_code == EXC_IRQ);
    commit_sev_seen  = commit_valid &&
                       ((core_commit.insn == INSN_SEV) ||
                        (core_commit.insn == INSN_SEVL));
  end

  assign mc_commit.version   = MC_VERSION;
  assign mc_commit.core_id   = CORE_ID_W'(CORE_ID);
  assign mc_commit.global_seq = 64'd0;   // C1 does not have a coordinator.
  assign mc_commit.vcpu_seq  = vcpu_seq_cur;
  assign mc_commit.commit    = core_commit;
  assign mc_commit.event_kind =
      commit_async_irq ? MC_EV_ASYNC_IRQ :
      commit_wfi_seen ? MC_EV_WFI :
      commit_wfe_seen ? MC_EV_WFE :
      MC_EV_COMMIT;
  assign event_kind = mc_commit.event_kind;

  // C1 local WFI/idle observer.  It is intentionally wrapper-level: the
  // core itself owns the architectural WFI/WFE state and has no public port.
  // The shell only needs a locally-visible status for directed tests.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      core_wfi_idle    <= 1'b0;
      event_pending_r  <= 1'b0;
      vcpu_seq_r       <= 32'd0;
      sev_pulse        <= 1'b0;
    end else if (core_reset_pulse || (state == S_RESET)) begin
      core_wfi_idle    <= 1'b0;
      event_pending_r  <= 1'b0;
      vcpu_seq_r       <= 32'd0;
      sev_pulse        <= 1'b0;
    end else begin
      sev_pulse <= 1'b0;
      if (commit_valid && (vcpu_seq_r != 32'hFFFF_FFFF)) begin
        vcpu_seq_r <= vcpu_seq_r + 32'd1;
      end
      if (event_in && core_running) begin
        event_pending_r <= 1'b1;
      end
      if (commit_wfe_seen && event_pending_r) begin
        // Kernel already holds an event; WFE does not enter idle.
        event_pending_r <= 1'b0;
        core_wfi_idle   <= 1'b0;
      end else if (commit_wfi_seen || commit_wfe_seen ||
                   ((core_commit.insn & INSN_WFIT_MASK) == INSN_WFIT_BASE) ||
                   ((core_commit.insn & INSN_WFET_MASK) == INSN_WFET_BASE)) begin
        core_wfi_idle <= 1'b1;
      end
      if (core_wfi_idle && (event_in || irq || event_pending_r ||
                            core_stop_pulse || core_reset_pulse ||
                            !core_running)) begin
        core_wfi_idle   <= 1'b0;
        event_pending_r <= 1'b0;
      end
      if (commit_sev_seen) begin
        sev_pulse <= 1'b1;
        event_pending_r <= 1'b1;
      end
    end
  end

  assign mpidr = 32'(CORE_ID);

endmodule
