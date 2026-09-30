// lcvex_soc_tb.sv
// 仿真顶层：lcvex_core + M1-B 内存接口（仲裁 -> 延迟注入 -> SRAM）
// + 程序加载口（复位期间由测试写入）。
// MEM_DELAY_MODE：0=直通（1-cycle SRAM），1=响应 +1 周期，2=随机延迟。
// D_L1_ENABLE：1=数据路径插入 D-L1 写通缓存（M2）。
// I_L1_ENABLE：1=取指路径插入 I-L1 只读缓存（M2）。
// L2_ENABLE：1=仲裁器与延迟/SRAM 之间插入统一 L2（32 KiB 2-way）。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */

module lcvex_soc_tb #(
    parameter logic [63:0] RESET_PC    = 64'h0000_0000_4400_0000,
    parameter int MEM_DELAY_MODE = 0,
    parameter int D_L1_ENABLE    = 0,
    parameter int I_L1_ENABLE    = 0,
    parameter int L2_ENABLE      = 0,
    parameter int CATAPULT_COH_ENABLE = 0,
    parameter int FETCH_FIFO_ENABLE = 1,
    parameter int FETCH_FIFO_DEPTH  = 2,
    parameter int FETCH_EPOCH_W     = 8,
    parameter logic A64_FP_SIMD  = 1'b1,
    parameter logic TIMER_REALTIME = 1'b0,
    parameter logic [63:0] CNTFRQ_HZ = 64'd1_000_000_000
) (
    input  logic        clk,
    input  logic        rst_n,
    // 提交握手：0 = 提交消费者忙（核心保持 WB 条目，不丢不重）
    input  logic        commit_ready,
    // P6 difftest wait-time sideband（QEMU→Verilator）；独立 SV/Cocotb
    // 测试固定为 0，锁步协调器在 QEMU WAIT_RESUME 后单拍驱动。
    input  logic        difftest_wait_release,
    input  logic        difftest_wait_cntvct_valid,
    input  logic [63:0] difftest_wait_cntvct,
    // P6 checkpoint 架构/系统状态恢复口（QEMU→Verilator）。只由锁步
    // 协调器在 reset 后的单个边界驱动；普通测试和可综合顶层固定为 0。
    input  logic        difftest_restore_sys_valid,
    // P7-0 FP sidecar restore：与 system restore 同一时钟沿采样。
    // V 使用 little-endian low/high 64-bit halves，便于 C++/Verilator 访问。
    input  logic        difftest_restore_fp_valid,
    input  logic [31:0] difftest_restore_fpcr,
    input  logic [31:0] difftest_restore_fpsr,
    input  logic [63:0] difftest_restore_fp_v_lo [0:31],
    input  logic [63:0] difftest_restore_fp_v_hi [0:31],
    input  logic [63:0] difftest_restore_pc,
    input  logic [63:0] difftest_restore_sp_el0,
    input  logic [63:0] difftest_restore_sp_el1,
    input  logic [3:0]  difftest_restore_nzcv,
    input  logic        difftest_restore_el,
    input  logic        difftest_restore_sp_sel,
    input  logic [3:0]  difftest_restore_daif,
    input  logic        difftest_restore_pan,
    input  logic        difftest_restore_dit,
    input  logic        difftest_restore_ssbs,
    input  logic        difftest_restore_uao,
    input  logic        difftest_restore_tco,
    input  logic        difftest_restore_allint,
    input  logic [63:0] difftest_restore_elr_el1,
    input  logic [63:0] difftest_restore_spsr_el1,
    input  logic [63:0] difftest_restore_vbar_el1,
    input  logic [63:0] difftest_restore_sctlr_el1,
    input  logic [63:0] difftest_restore_tcr_el1,
    input  logic [63:0] difftest_restore_ttbr0_el1,
    input  logic [63:0] difftest_restore_ttbr1_el1,
    input  logic [63:0] difftest_restore_mair_el1,
    input  logic [31:0] difftest_restore_esr_el1,
    input  logic [63:0] difftest_restore_far_el1,
    input  logic [63:0] difftest_restore_par_el1,
    input  logic [63:0] difftest_restore_cpacr_el1,
    input  logic [63:0] difftest_restore_mdscr_el1,
    input  logic [63:0] difftest_restore_pmuserenr_el0,
    input  logic [63:0] difftest_restore_cntkctl_el1,
    input  logic [63:0] difftest_restore_tpidr_el0,
    input  logic [63:0] difftest_restore_tpidrro_el0,
    input  logic [63:0] difftest_restore_tpidr_el1,
    input  logic [63:0] difftest_restore_pir_el1,
    input  logic [63:0] difftest_restore_pire0_el1,
    input  logic [63:0] difftest_restore_zcr_el1,
    input  logic [63:0] difftest_restore_smcr_el1,
    input  logic [63:0] difftest_restore_csselr_el1,
    input  logic [63:0] difftest_restore_tcr2_el1,
    input  logic [63:0] difftest_restore_contextidr_el1,
    input  logic        difftest_restore_excl_valid,
    input  logic [63:0] difftest_restore_excl_addr,
    input  logic [63:0] difftest_restore_excl_data,
    input  logic [63:0] difftest_restore_excl_data_hi,
    input  logic [63:0] difftest_restore_cntpct,
    input  logic [63:0] difftest_restore_cntp_cval,
    input  logic [1:0]  difftest_restore_cntp_ctl,
    input  logic [63:0] difftest_restore_cntv_cval,
    input  logic [1:0]  difftest_restore_cntv_ctl,
    // 程序加载口（Cocotb / SV testbench 驱动）
    input  logic        prog_we,
    input  logic [63:0] prog_addr,
    input  logic [7:0]  prog_strb,
    input  logic [63:0] prog_wdata,
    // 提交包
    output logic        commit_valid,
    output logic [63:0] commit_pc,
    output logic [63:0] commit_next_pc,
    output logic [31:0] commit_insn,
    output logic        commit_gpr_we,
    output logic [4:0]  commit_gpr_rd,
    output logic [63:0] commit_gpr_wdata,
    output logic        commit_gpr2_we,
    output logic [4:0]  commit_gpr2_rd,
    output logic [63:0] commit_gpr2_wdata,
    output logic        commit_gpr3_we,
    output logic [4:0]  commit_gpr3_rd,
    output logic [63:0] commit_gpr3_wdata,
    output logic        commit_sp_we,
    output logic [63:0] commit_sp_wdata,
    output logic        commit_nzcv_we,
    output logic [3:0]  commit_nzcv,
    output logic        commit_mem_we,
    output logic [63:0] commit_mem_addr,
    output logic [63:0] commit_mem_wdata,
    output logic [7:0]  commit_mem_strb,
    output logic        commit_mem2_we,
    output logic [63:0] commit_mem2_addr,
    output logic [63:0] commit_mem2_wdata,
    output logic [7:0]  commit_mem2_strb,
    output logic        commit_exc_valid,
    output logic [31:0] commit_exc_code,
    output logic [31:0] commit_exc_esr,
    output logic [63:0] commit_exc_far,
    // exclusive 监视器（M3）：本提交是否更新 + 新值
    output logic        commit_mon_we,
    output logic        commit_mon_valid,
    output logic [63:0] commit_mon_addr,
    output logic [63:0] commit_mon_data,
    output logic [63:0] commit_mon_data2,
    // P7-0 RTL-only FP effect view. Scalar/trap commits expose zeros.
    output logic [2:0]  commit_vec_write_count,
    output logic [4:0]  commit_vec_rd0,
    output logic [4:0]  commit_vec_rd1,
    output logic [4:0]  commit_vec_rd2,
    output logic [4:0]  commit_vec_rd3,
    output logic [63:0] commit_vec_wdata0_lo,
    output logic [63:0] commit_vec_wdata0_hi,
    output logic [63:0] commit_vec_wdata1_lo,
    output logic [63:0] commit_vec_wdata1_hi,
    output logic [63:0] commit_vec_wdata2_lo,
    output logic [63:0] commit_vec_wdata2_hi,
    output logic [63:0] commit_vec_wdata3_lo,
    output logic [63:0] commit_vec_wdata3_hi,
    output logic        commit_fpcr_we,
    output logic [31:0] commit_fpcr_wdata,
    output logic        commit_fpsr_we,
    output logic [31:0] commit_fpsr_wdata,
    // P7-0 raw state observation (V halves preserve all 128 bits).
    output logic [31:0] fpcr_state,
    output logic [31:0] fpsr_state,
    output logic [63:0] fp_cpacr_el1_state,
    output logic [63:0] fp_v_lo [0:31],
    output logic [63:0] fp_v_hi [0:31],
    // M2-4b：TLBI 整表失效脉冲（观测用）
    output logic        tlb_invalidate,
    // P6：PL011 TX 输出（观测用，非架构状态）
    output logic        uart_tx_valid,
    output logic [7:0]  uart_tx_char,
    // P6：Generic Timer 中断（供 GIC，观测用）
    output logic        timer_phys_irq,
    output logic        timer_virt_irq,
    // P6：GIC 中断输出（观测用）
    output logic        gic_irq_out,
    output logic        gic_fiq_out,
    // P6：RAM 调试读口（锁步失败诊断用）
    input  logic [31:0] dbg_addr,
    output logic [63:0] dbg_rdata,
    // P6 内核锁步调试：DUT 核心内部状态（decode/mmu 信号）
    output logic        dbg_mmu_en,
    output logic [63:0] dbg_vbar_el1,
    output logic        dbg_dec_valid,
    output logic        dbg_dec_exc,
    output logic [31:0] dbg_dec_insn,
    output logic [63:0] dbg_dec_pc,
    output logic [31:0] dbg_dec_exc_code,
    // F0 performance observation: read-only event pulses, driven 0 when the
    // corresponding cache is not instantiated. These do not affect architecture
    // state or memory semantics.
    output logic        perf_il1_upstream,
    output logic        perf_il1_read_hit,
    output logic        perf_il1_read_miss,
    output logic        perf_il1_refill_beat,
    output logic        perf_il1_downstream,
    output logic        perf_dl1_upstream,
    output logic        perf_dl1_read_hit,
    output logic        perf_dl1_read_miss,
    output logic        perf_dl1_write,
    output logic        perf_dl1_refill_beat,
    output logic        perf_dl1_downstream,
    output logic        perf_l2_upstream,
    output logic        perf_l2_read_hit,
    output logic        perf_l2_read_miss,
    output logic        perf_l2_write,
    output logic        perf_l2_refill_beat,
    output logic        perf_l2_downstream,
    // F1a read-only frontend observation. These ports do not enter the
    // architectural commit packet and remain zero when FETCH_FIFO_ENABLE=0.
    output logic [FETCH_EPOCH_W-1:0] fetch_epoch,
    output logic [1:0]  fetch_fifo_occupancy,
    output logic        fetch_fifo_push,
    output logic        fetch_fifo_pop,
    output logic        fetch_fifo_flush,
    output logic        fetch_stale_drain,
    output logic        fetch_stale_rsp_drop,
    output logic [1:0]  fetch_fifo_peak,
    // T-009 有界事件 probe：稳定的顶层只读观测，不进入 commit/digest。
    output logic        probe_frontend_kill,
    output logic        probe_fetch_issue_blocked,
    output logic [63:0] probe_if_pc,
    output logic [63:0] probe_fetch_pc_r,
    output logic        probe_fetch_pending,
    output logic        probe_fetch_translated,
    output logic        probe_fetch_trans_busy,
    output logic        probe_fetch_stale_mmu,
    output logic        probe_fetch_stale_imem,
    output logic        probe_dmem_pending,
    output logic        probe_mem_busy,
    output logic        probe_fetch_req_valid,
    output logic        probe_fetch_req_ready,
    output logic        probe_imem_req_valid,
    output logic        probe_imem_req_ready,
    output logic [63:0] probe_imem_req_addr,
    output logic        probe_imem_rsp_valid,
    output logic        probe_imem_rsp_ready,
    output logic        probe_dmem_req_valid,
    output logic        probe_dmem_req_ready,
    output logic        probe_dmem_rsp_valid,
    output logic        probe_dmem_rsp_ready,
    output logic        probe_ptw_req_valid,
    output logic        probe_ptw_req_ready,
    output logic        probe_ptw_rsp_valid,
    output logic        probe_ptw_rsp_ready,
    output logic        probe_arb_req_valid,
    output logic        probe_arb_req_ready,
    output logic        probe_arb_rsp_valid,
    output logic        probe_arb_rsp_ready,
    output logic        probe_l2_req_valid,
    output logic        probe_l2_req_ready,
    output logic        probe_l2_rsp_valid,
    output logic        probe_l2_rsp_ready,
    output logic        probe_delay_req_valid,
    output logic        probe_delay_req_ready,
    output logic [63:0] probe_delay_req_addr,
    output logic        probe_delay_rsp_valid,
    output logic        probe_delay_rsp_ready,
    output logic        probe_ram_req_valid,
    output logic        probe_ram_req_ready,
    output logic        probe_ram_rsp_valid,
    output logic        probe_ram_rsp_ready,
    output logic        probe_delay_req_pending,
    output logic        probe_delay_rsp_pending,
    output logic [31:0] probe_delay_count,
    output logic [7:0]  probe_delay_lfsr,
    // T-010 raw control-flow fetch-fence state (read-only).
    output logic        fetch_control_fence
);

  lcvex_pkg::commit_packet_t commit;

  // M1-B 内存接口
  logic                imem_req_valid;
  lcvex_pkg::mem_req_t imem_req;
  logic                imem_req_ready;
  logic                imem_rsp_valid;
  lcvex_pkg::mem_rsp_t imem_rsp;
  logic                imem_rsp_ready;
  logic                dmem_req_valid;
  lcvex_pkg::mem_req_t dmem_req;
  logic                dmem_req_ready;
  logic                dmem_rsp_valid;
  lcvex_pkg::mem_rsp_t dmem_rsp;
  logic                dmem_rsp_ready;
  logic                ptw_req_valid;
  lcvex_pkg::mem_req_t ptw_req;
  logic                ptw_req_ready;
  logic                ptw_rsp_valid;
  lcvex_pkg::mem_rsp_t ptw_rsp;
  logic                ptw_rsp_ready;
  // D-L1 下游（接仲裁端口 1）
  logic                arb_dmem_req_valid;
  lcvex_pkg::mem_req_t arb_dmem_req;
  logic                arb_dmem_req_ready;
  logic                arb_dmem_rsp_valid;
  lcvex_pkg::mem_rsp_t arb_dmem_rsp;
  logic                arb_dmem_rsp_ready;
  logic                dl1_perf_hit;
  logic                dl1_perf_refill_beat;
  // I-L1 下游（接仲裁端口 2）
  logic                arb_imem_req_valid;
  lcvex_pkg::mem_req_t arb_imem_req;
  logic                arb_imem_req_ready;
  logic                arb_imem_rsp_valid;
  lcvex_pkg::mem_rsp_t arb_imem_rsp;
  logic                arb_imem_rsp_ready;
  logic                il1_perf_hit;
  logic                il1_perf_refill_beat;
  logic                arb_req_valid;
  lcvex_pkg::mem_req_t arb_req;
  logic                arb_req_accept;
  logic                arb_rsp_valid;
  lcvex_pkg::mem_rsp_t arb_rsp;
  logic                arb_rsp_ready;
  // L2 下游（接延迟注入器）
  logic                l2_req_valid;
  lcvex_pkg::mem_req_t l2_req;
  logic                l2_req_accept;
  logic                l2_rsp_valid;
  lcvex_pkg::mem_rsp_t l2_rsp;
  logic                l2_rsp_ready;
  logic                l2_perf_hit;
  logic                l2_perf_refill_beat;
  logic                coh_poc_req_valid;
  lcvex_pkg::mem_req_t coh_poc_req;
  logic                coh_poc_req_ready;
  logic                coh_poc_rsp_valid;
  lcvex_pkg::mem_rsp_t coh_poc_rsp;
  logic                coh_poc_rsp_ready;
  logic                coh_dmem_req_ready, coh_dmem_rsp_valid;
  lcvex_pkg::mem_rsp_t coh_dmem_rsp;
  logic                coh_imem_req_ready, coh_imem_rsp_valid;
  lcvex_pkg::mem_rsp_t coh_imem_rsp;
  logic                coh_ptw_req_ready, coh_ptw_rsp_valid;
  lcvex_pkg::mem_rsp_t coh_ptw_rsp;
  logic                del_req_valid;
  lcvex_pkg::mem_req_t del_req;
  logic                del_req_ready;
  logic                del_rsp_valid;
  lcvex_pkg::mem_rsp_t del_rsp;
  logic                del_rsp_ready;

  lcvex_core #(
      .RESET_PC(RESET_PC),
      .SRAM_BASE(64'h0000_0000_4000_0000),
      .SRAM_TOP (64'h0000_0000_4800_0000),
      .A64_FP_SIMD (A64_FP_SIMD),
      .TIMER_REALTIME(TIMER_REALTIME),
      .CNTFRQ_HZ(CNTFRQ_HZ),
      .FETCH_FIFO_ENABLE(FETCH_FIFO_ENABLE),
      .FETCH_FIFO_DEPTH(FETCH_FIFO_DEPTH),
      .FETCH_EPOCH_W(FETCH_EPOCH_W)
  ) core (
      .clk          (clk),
      .rst_n        (rst_n),
      .commit_ready (commit_ready),
      .commit       (commit),
      .fpcr_state   (fpcr_state),
      .fpsr_state   (fpsr_state),
      .fp_cpacr_el1_state(fp_cpacr_el1_state),
      .fp_v_lo      (fp_v_lo),
      .fp_v_hi      (fp_v_hi),
      .imem_req_valid (imem_req_valid),
      .imem_req       (imem_req),
      .imem_req_ready (imem_req_ready),
      .imem_rsp_valid (imem_rsp_valid),
      .imem_rsp       (imem_rsp),
      .imem_rsp_ready (imem_rsp_ready),
      .dmem_req_valid (dmem_req_valid),
      .dmem_req       (dmem_req),
      .dmem_req_ready (dmem_req_ready),
      .dmem_rsp_valid (dmem_rsp_valid),
      .dmem_rsp       (dmem_rsp),
      .dmem_rsp_ready (dmem_rsp_ready),
      .ptw_req_valid  (ptw_req_valid),
      .ptw_req        (ptw_req),
      .ptw_req_ready  (ptw_req_ready),
      .ptw_rsp_valid  (ptw_rsp_valid),
      .ptw_rsp        (ptw_rsp),
      .ptw_rsp_ready  (ptw_rsp_ready),
      .tlb_invalidate (tlb_invalidate),
      .timer_phys_irq (timer_phys_irq),
      .timer_virt_irq (timer_virt_irq),
      .irq            (gic_irq),
      .difftest_wait_release(difftest_wait_release),
      .difftest_wait_cntvct_valid(difftest_wait_cntvct_valid),
      .difftest_wait_cntvct(difftest_wait_cntvct),
      .difftest_restore_sys_valid(difftest_restore_sys_valid),
      .difftest_restore_fp_valid(difftest_restore_fp_valid),
      .difftest_restore_fpcr(difftest_restore_fpcr),
      .difftest_restore_fpsr(difftest_restore_fpsr),
      .difftest_restore_fp_v_lo(difftest_restore_fp_v_lo),
      .difftest_restore_fp_v_hi(difftest_restore_fp_v_hi),
      .difftest_restore_pc(difftest_restore_pc),
      .difftest_restore_sp_el0(difftest_restore_sp_el0),
      .difftest_restore_sp_el1(difftest_restore_sp_el1),
      .difftest_restore_nzcv(difftest_restore_nzcv),
      .difftest_restore_el(difftest_restore_el),
      .difftest_restore_sp_sel(difftest_restore_sp_sel),
      .difftest_restore_daif(difftest_restore_daif),
      .difftest_restore_pan(difftest_restore_pan),
      .difftest_restore_dit(difftest_restore_dit),
      .difftest_restore_ssbs(difftest_restore_ssbs),
      .difftest_restore_uao(difftest_restore_uao),
      .difftest_restore_tco(difftest_restore_tco),
      .difftest_restore_allint(difftest_restore_allint),
      .difftest_restore_elr_el1(difftest_restore_elr_el1),
      .difftest_restore_spsr_el1(difftest_restore_spsr_el1),
      .difftest_restore_vbar_el1(difftest_restore_vbar_el1),
      .difftest_restore_sctlr_el1(difftest_restore_sctlr_el1),
      .difftest_restore_tcr_el1(difftest_restore_tcr_el1),
      .difftest_restore_ttbr0_el1(difftest_restore_ttbr0_el1),
      .difftest_restore_ttbr1_el1(difftest_restore_ttbr1_el1),
      .difftest_restore_mair_el1(difftest_restore_mair_el1),
      .difftest_restore_esr_el1(difftest_restore_esr_el1),
      .difftest_restore_far_el1(difftest_restore_far_el1),
      .difftest_restore_par_el1(difftest_restore_par_el1),
      .difftest_restore_cpacr_el1(difftest_restore_cpacr_el1),
      .difftest_restore_mdscr_el1(difftest_restore_mdscr_el1),
      .difftest_restore_pmuserenr_el0(difftest_restore_pmuserenr_el0),
      .difftest_restore_cntkctl_el1(difftest_restore_cntkctl_el1),
      .difftest_restore_tpidr_el0(difftest_restore_tpidr_el0),
      .difftest_restore_tpidrro_el0(difftest_restore_tpidrro_el0),
      .difftest_restore_tpidr_el1(difftest_restore_tpidr_el1),
      .difftest_restore_pir_el1(difftest_restore_pir_el1),
      .difftest_restore_pire0_el1(difftest_restore_pire0_el1),
      .difftest_restore_zcr_el1(difftest_restore_zcr_el1),
      .difftest_restore_smcr_el1(difftest_restore_smcr_el1),
      .difftest_restore_csselr_el1(difftest_restore_csselr_el1),
      .difftest_restore_tcr2_el1(difftest_restore_tcr2_el1),
      .difftest_restore_contextidr_el1(difftest_restore_contextidr_el1),
      .difftest_restore_excl_valid(difftest_restore_excl_valid),
      .difftest_restore_excl_addr(difftest_restore_excl_addr),
      .difftest_restore_excl_data(difftest_restore_excl_data),
      .difftest_restore_excl_data_hi(difftest_restore_excl_data_hi),
      .difftest_restore_cntpct(difftest_restore_cntpct),
      .difftest_restore_cntp_cval(difftest_restore_cntp_cval),
      .difftest_restore_cntp_ctl(difftest_restore_cntp_ctl),
      .difftest_restore_cntv_cval(difftest_restore_cntv_cval),
      .difftest_restore_cntv_ctl(difftest_restore_cntv_ctl)
  );

  generate
    if (CATAPULT_COH_ENABLE != 0) begin : g_catapult_coh
      lcvex_catapult_soc_coh #(
          .LINE_BYTES(64), .L1_SETS(64), .L2_SETS(256), .L2_WAYS(2)
      ) coh (
          .clk(clk), .rst_n(rst_n),
          .imem_req_valid(imem_req_valid), .imem_req(imem_req),
          .imem_req_ready(coh_imem_req_ready),
          .imem_rsp_valid(coh_imem_rsp_valid), .imem_rsp(coh_imem_rsp),
          .imem_rsp_ready(imem_rsp_ready),
          .dmem_req_valid(dmem_req_valid), .dmem_req(dmem_req),
          .dmem_req_ready(coh_dmem_req_ready),
          .dmem_rsp_valid(coh_dmem_rsp_valid), .dmem_rsp(coh_dmem_rsp),
          .dmem_rsp_ready(dmem_rsp_ready),
          .ptw_req_valid(ptw_req_valid), .ptw_req(ptw_req),
          .ptw_req_ready(coh_ptw_req_ready),
          .ptw_rsp_valid(coh_ptw_rsp_valid), .ptw_rsp(coh_ptw_rsp),
          .ptw_rsp_ready(ptw_rsp_ready),
          .checkpoint_quiesce(1'b0), .checkpoint_ack_valid(),
          .checkpoint_ack_ready(1'b1), .checkpoint_fault(),
          .l1_drain_done(), .l1_drain_fault(),
          .l2_drain_ack_valid(), .l2_drain_fault(),
          .poc_req_valid(coh_poc_req_valid), .poc_req(coh_poc_req),
          .poc_req_ready(coh_poc_req_ready),
          .poc_rsp_valid(coh_poc_rsp_valid), .poc_rsp(coh_poc_rsp),
          .poc_rsp_ready(coh_poc_rsp_ready),
          .dbg_l1_u_req_we(), .dbg_l1_u_req_addr(),
          .dbg_l1_u_req_bypass(), .dbg_l1_u_req_wdata(),
          .dbg_arb_req0_we(), .dbg_arb_req0_bypass(),
          .dbg_arb_req0_wdata(), .dbg_l2_u_req_we(),
          .dbg_l2_u_req_addr(), .dbg_l2_u_req_bypass(),
          .dbg_l2_u_req_wdata()
      );
    end else begin : g_no_catapult_coh
      assign coh_imem_req_ready = 1'b0;
      assign coh_imem_rsp_valid = 1'b0;
      assign coh_imem_rsp = '0;
      assign coh_dmem_req_ready = 1'b0;
      assign coh_dmem_rsp_valid = 1'b0;
      assign coh_dmem_rsp = '0;
      assign coh_ptw_req_ready = 1'b0;
      assign coh_ptw_rsp_valid = 1'b0;
      assign coh_ptw_rsp = '0;
      assign coh_poc_req_valid = 1'b0;
      assign coh_poc_req = '0;
      assign coh_poc_req_ready = 1'b0;
      assign coh_poc_rsp_valid = 1'b0;
      assign coh_poc_rsp = '0;
      assign coh_poc_rsp_ready = 1'b0;
    end
  endgenerate

  assign fetch_epoch          = core.fetch_epoch;
  assign fetch_fifo_occupancy = core.fetch_fifo_occupancy;
  assign fetch_fifo_push      = core.fetch_fifo_push;
  assign fetch_fifo_pop       = core.fetch_fifo_pop;
  assign fetch_fifo_flush     = core.fetch_fifo_flush;
  assign fetch_stale_drain    = core.fetch_stale_drain;
  assign fetch_stale_rsp_drop = core.fetch_stale_rsp_drop;
  assign fetch_fifo_peak      = core.fetch_fifo_peak;
  assign fetch_control_fence       = core.fetch_control_fence;
  assign probe_frontend_kill       = core.frontend_kill;
  assign probe_fetch_issue_blocked = core.fetch_imem_req_valid && !imem_req_ready;
  assign probe_if_pc               = core.if_pc;
  assign probe_fetch_pc_r          = core.fetch_pc_r;
  assign probe_fetch_pending       = core.fetch_pending;
  assign probe_fetch_translated    = core.fetch_translated;
  assign probe_fetch_trans_busy    = core.fetch_trans_busy;
  assign probe_fetch_stale_mmu     = core.fetch_stale_mmu;
  assign probe_fetch_stale_imem    = core.fetch_stale_imem;
  assign probe_dmem_pending        = core.dmem_pending;
  assign probe_mem_busy            = core.mem_busy;
  assign probe_fetch_req_valid    = core.fetch_imem_req_valid;
  assign probe_fetch_req_ready    = imem_req_ready;
  assign probe_imem_req_valid     = imem_req_valid;
  assign probe_imem_req_ready     = imem_req_ready;
  assign probe_imem_req_addr      = imem_req.addr;
  assign probe_imem_rsp_valid     = imem_rsp_valid;
  assign probe_imem_rsp_ready     = imem_rsp_ready;
  assign probe_dmem_req_valid     = dmem_req_valid;
  assign probe_dmem_req_ready     = dmem_req_ready;
  assign probe_dmem_rsp_valid     = dmem_rsp_valid;
  assign probe_dmem_rsp_ready     = dmem_rsp_ready;
  assign probe_ptw_req_valid      = ptw_req_valid;
  assign probe_ptw_req_ready      = ptw_req_ready;
  assign probe_ptw_rsp_valid      = ptw_rsp_valid;
  assign probe_ptw_rsp_ready      = ptw_rsp_ready;
  assign probe_arb_req_valid      = arb_req_valid;
  assign probe_arb_req_ready      = arb_req_accept;
  assign probe_arb_rsp_valid      = arb_rsp_valid;
  assign probe_arb_rsp_ready      = arb_rsp_ready;
  assign probe_l2_req_valid       = l2_req_valid;
  assign probe_l2_req_ready       = l2_req_accept;
  assign probe_l2_rsp_valid       = l2_rsp_valid;
  assign probe_l2_rsp_ready       = l2_rsp_ready;
  assign probe_delay_req_valid    = del_req_valid;
  assign probe_delay_req_ready    = del_req_ready;
  assign probe_delay_req_addr     = del_req.addr;
  assign probe_delay_rsp_valid    = del_rsp_valid;
  assign probe_delay_rsp_ready    = del_rsp_ready;
  assign probe_ram_req_valid      = ram_req_valid;
  assign probe_ram_req_ready      = ram_req_accept;
  assign probe_ram_rsp_valid      = ram_rsp_valid;
  assign probe_ram_rsp_ready      = ram_rsp_ready;

  // ---- M2：D-L1 数据缓存（可选插入 dmem 与仲裁之间）----
  generate
    if (CATAPULT_COH_ENABLE != 0) begin : g_catapult_dmem
      assign dmem_req_ready = coh_dmem_req_ready;
      assign dmem_rsp_valid = coh_dmem_rsp_valid;
      assign dmem_rsp = coh_dmem_rsp;
      assign arb_dmem_req_valid = 1'b0;
      assign arb_dmem_req = '0;
      assign arb_dmem_req_ready = 1'b0;
      assign arb_dmem_rsp_valid = 1'b0;
      assign arb_dmem_rsp = '0;
      assign arb_dmem_rsp_ready = 1'b0;
      assign dl1_perf_hit = 1'b0;
      assign dl1_perf_refill_beat = 1'b0;
      assign perf_dl1_upstream = 1'b0;
      assign perf_dl1_read_hit = 1'b0;
      assign perf_dl1_read_miss = 1'b0;
      assign perf_dl1_write = 1'b0;
      assign perf_dl1_refill_beat = 1'b0;
      assign perf_dl1_downstream = 1'b0;
    end else if (D_L1_ENABLE != 0) begin : g_dl1
      lcvex_l1_d #(.LINE_BYTES(64), .SETS(64)) dl1 (
          .clk         (clk),
          .rst_n       (rst_n),
          .u_req_valid (dmem_req_valid),
          .u_req       (dmem_req),
          .u_req_ready (dmem_req_ready),
          .u_rsp_valid (dmem_rsp_valid),
          .u_rsp       (dmem_rsp),
          .u_rsp_ready (dmem_rsp_ready),
          .d_req_valid (arb_dmem_req_valid),
          .d_req       (arb_dmem_req),
          .d_req_ready (arb_dmem_req_ready),
          .d_rsp_valid (arb_dmem_rsp_valid),
          .d_rsp       (arb_dmem_rsp),
          .d_rsp_ready (arb_dmem_rsp_ready),
          .perf_hit    (dl1_perf_hit),
          .perf_refill_beat (dl1_perf_refill_beat)
      );
      assign perf_dl1_upstream    = dmem_req_valid && dmem_req_ready;
      assign perf_dl1_read_hit    = dmem_req_valid && dmem_req_ready &&
                                    !dmem_req.we && !dmem_req.bypass &&
                                    (dmem_req.maint == lcvex_pkg::MAINT_NONE) &&
                                    dl1_perf_hit;
      assign perf_dl1_read_miss   = dmem_req_valid && dmem_req_ready &&
                                    !dmem_req.we && !dmem_req.bypass &&
                                    (dmem_req.maint == lcvex_pkg::MAINT_NONE) &&
                                    !dl1_perf_hit;
      assign perf_dl1_write       = dmem_req_valid && dmem_req_ready &&
                                    dmem_req.we && !dmem_req.bypass &&
                                    (dmem_req.maint == lcvex_pkg::MAINT_NONE);
      assign perf_dl1_refill_beat = dl1_perf_refill_beat;
      assign perf_dl1_downstream  = arb_dmem_req_valid && arb_dmem_req_ready;
    end else begin : g_dl1_bypass
      assign arb_dmem_req_valid = dmem_req_valid;
      assign arb_dmem_req       = dmem_req;
      assign dmem_req_ready     = arb_dmem_req_ready;
      assign dmem_rsp_valid     = arb_dmem_rsp_valid;
      assign dmem_rsp           = arb_dmem_rsp;
      assign arb_dmem_rsp_ready = dmem_rsp_ready;
      assign dl1_perf_hit        = 1'b0;
      assign dl1_perf_refill_beat = 1'b0;
      assign perf_dl1_upstream    = 1'b0;
      assign perf_dl1_read_hit    = 1'b0;
      assign perf_dl1_read_miss   = 1'b0;
      assign perf_dl1_write       = 1'b0;
      assign perf_dl1_refill_beat = 1'b0;
      assign perf_dl1_downstream  = 1'b0;
    end
  endgenerate

  // ---- M2：I-L1 指令缓存（可选插入 imem 与仲裁之间）----
  generate
    if (CATAPULT_COH_ENABLE != 0) begin : g_catapult_imem
      assign imem_req_ready = coh_imem_req_ready;
      assign imem_rsp_valid = coh_imem_rsp_valid;
      assign imem_rsp = coh_imem_rsp;
      assign arb_imem_req_valid = 1'b0;
      assign arb_imem_req = '0;
      assign arb_imem_req_ready = 1'b0;
      assign arb_imem_rsp_valid = 1'b0;
      assign arb_imem_rsp = '0;
      assign arb_imem_rsp_ready = 1'b0;
      assign il1_perf_hit = 1'b0;
      assign il1_perf_refill_beat = 1'b0;
      assign perf_il1_upstream = 1'b0;
      assign perf_il1_read_hit = 1'b0;
      assign perf_il1_read_miss = 1'b0;
      assign perf_il1_refill_beat = 1'b0;
      assign perf_il1_downstream = 1'b0;
    end else if (I_L1_ENABLE != 0) begin : g_il1
      lcvex_l1_i #(.LINE_BYTES(64), .SETS(64)) il1 (
          .clk         (clk),
          .rst_n       (rst_n),
          .u_req_valid (imem_req_valid),
          .u_req       (imem_req),
          .u_req_ready (imem_req_ready),
          .u_rsp_valid (imem_rsp_valid),
          .u_rsp       (imem_rsp),
          .u_rsp_ready (imem_rsp_ready),
          .d_req_valid (arb_imem_req_valid),
          .d_req       (arb_imem_req),
          .d_req_ready (arb_imem_req_ready),
          .d_rsp_valid (arb_imem_rsp_valid),
          .d_rsp       (arb_imem_rsp),
          .d_rsp_ready (arb_imem_rsp_ready),
          .perf_hit    (il1_perf_hit),
          .perf_refill_beat (il1_perf_refill_beat)
      );
      assign perf_il1_upstream    = imem_req_valid && imem_req_ready;
      assign perf_il1_read_hit    = imem_req_valid && imem_req_ready &&
                                    !imem_req.bypass &&
                                    (imem_req.maint == lcvex_pkg::MAINT_NONE) &&
                                    il1_perf_hit;
      assign perf_il1_read_miss   = imem_req_valid && imem_req_ready &&
                                    !imem_req.bypass &&
                                    (imem_req.maint == lcvex_pkg::MAINT_NONE) &&
                                    !il1_perf_hit;
      assign perf_il1_refill_beat = il1_perf_refill_beat;
      assign perf_il1_downstream  = arb_imem_req_valid && arb_imem_req_ready;
    end else begin : g_il1_bypass
      assign arb_imem_req_valid = imem_req_valid;
      assign arb_imem_req       = imem_req;
      assign imem_req_ready     = arb_imem_req_ready;
      assign imem_rsp_valid     = arb_imem_rsp_valid;
      assign imem_rsp           = arb_imem_rsp;
      assign arb_imem_rsp_ready = imem_rsp_ready;
      assign il1_perf_hit        = 1'b0;
      assign il1_perf_refill_beat = 1'b0;
      assign perf_il1_upstream    = 1'b0;
      assign perf_il1_read_hit    = 1'b0;
      assign perf_il1_read_miss   = 1'b0;
      assign perf_il1_refill_beat = 1'b0;
      assign perf_il1_downstream  = 1'b0;
    end
  endgenerate

  // 仲裁：PTW(0) > 数据(1) > 取指(2)
  generate
    if (CATAPULT_COH_ENABLE != 0) begin : g_catapult_arb_bypass
      assign ptw_req_ready = coh_ptw_req_ready;
      assign ptw_rsp_valid = coh_ptw_rsp_valid;
      assign ptw_rsp = coh_ptw_rsp;
      assign arb_req_valid = 1'b0;
      assign arb_req = '0;
      assign arb_req_accept = 1'b0;
      assign arb_rsp_valid = 1'b0;
      assign arb_rsp = '0;
      assign arb_rsp_ready = 1'b0;
    end else begin : g_generic_arb
      lcvex_mem_arb #(.PORTS(3)) arb (
          .clk            (clk),
          .rst_n          (rst_n),
          .req_valid      ({arb_imem_req_valid, arb_dmem_req_valid, ptw_req_valid}),
          .req            ({arb_imem_req, arb_dmem_req, ptw_req}),
          .req_ready      ({arb_imem_req_ready, arb_dmem_req_ready, ptw_req_ready}),
          .rsp_valid      ({arb_imem_rsp_valid, arb_dmem_rsp_valid, ptw_rsp_valid}),
          .rsp            ({arb_imem_rsp, arb_dmem_rsp, ptw_rsp}),
          .rsp_ready      ({arb_imem_rsp_ready, arb_dmem_rsp_ready, ptw_rsp_ready}),
          .mem_req_valid  (arb_req_valid),
          .mem_req        (arb_req),
          .mem_req_accept (arb_req_accept),
          .mem_rsp_valid  (arb_rsp_valid),
          .mem_rsp        (arb_rsp),
          .mem_rsp_ready  (arb_rsp_ready)
      );
    end
  endgenerate

  // ---- M2：统一 L2（可选插入仲裁器与延迟/SRAM 之间）----
  generate
    if (CATAPULT_COH_ENABLE != 0) begin : g_catapult_poc
      assign l2_req_valid = coh_poc_req_valid;
      assign l2_req = coh_poc_req;
      assign coh_poc_req_ready = l2_req_accept;
      assign coh_poc_rsp_valid = l2_rsp_valid;
      assign coh_poc_rsp = l2_rsp;
      assign l2_rsp_ready = coh_poc_rsp_ready;
      assign l2_perf_hit = 1'b0;
      assign l2_perf_refill_beat = 1'b0;
      assign perf_l2_upstream = 1'b0;
      assign perf_l2_read_hit = 1'b0;
      assign perf_l2_read_miss = 1'b0;
      assign perf_l2_write = 1'b0;
      assign perf_l2_refill_beat = 1'b0;
      assign perf_l2_downstream = 1'b0;
    end else if (L2_ENABLE != 0) begin : g_l2
      lcvex_l2 #(.LINE_BYTES(64), .SETS(256), .WAYS(2)) l2 (
          .clk         (clk),
          .rst_n       (rst_n),
          .u_req_valid (arb_req_valid),
          .u_req       (arb_req),
          .u_req_ready (arb_req_accept),
          .u_rsp_valid (arb_rsp_valid),
          .u_rsp       (arb_rsp),
          .u_rsp_ready (arb_rsp_ready),
          .d_req_valid (l2_req_valid),
          .d_req       (l2_req),
          .d_req_ready (l2_req_accept),
          .d_rsp_valid (l2_rsp_valid),
          .d_rsp       (l2_rsp),
          .d_rsp_ready (l2_rsp_ready),
          .perf_hit    (l2_perf_hit),
          .perf_refill_beat (l2_perf_refill_beat)
      );
      assign perf_l2_upstream    = arb_req_valid && arb_req_accept;
      assign perf_l2_read_hit    = arb_req_valid && arb_req_accept &&
                                    !arb_req.we && !arb_req.bypass &&
                                    (arb_req.maint == lcvex_pkg::MAINT_NONE) &&
                                    l2_perf_hit;
      assign perf_l2_read_miss   = arb_req_valid && arb_req_accept &&
                                    !arb_req.we && !arb_req.bypass &&
                                    (arb_req.maint == lcvex_pkg::MAINT_NONE) &&
                                    !l2_perf_hit;
      assign perf_l2_write       = arb_req_valid && arb_req_accept &&
                                    arb_req.we && !arb_req.bypass &&
                                    (arb_req.maint == lcvex_pkg::MAINT_NONE);
      assign perf_l2_refill_beat = l2_perf_refill_beat;
      assign perf_l2_downstream  = l2_req_valid && l2_req_accept;
    end else begin : g_l2_bypass
      assign l2_req_valid = arb_req_valid;
      assign l2_req       = arb_req;
      assign arb_req_accept = l2_req_accept;
      assign arb_rsp_valid = l2_rsp_valid;
      assign arb_rsp       = l2_rsp;
      assign l2_rsp_ready  = arb_rsp_ready;
      assign l2_perf_hit        = 1'b0;
      assign l2_perf_refill_beat = 1'b0;
      assign perf_l2_upstream    = 1'b0;
      assign perf_l2_read_hit    = 1'b0;
      assign perf_l2_read_miss   = 1'b0;
      assign perf_l2_write       = 1'b0;
      assign perf_l2_refill_beat = 1'b0;
      assign perf_l2_downstream  = 1'b0;
    end
  endgenerate

  // 延迟注入：0=直通，1=响应 +1，2=随机（LFSR）
  lcvex_mem_delay #(.DELAY_MODE(MEM_DELAY_MODE), .RAND_MAX(4)) delay (
      .clk            (clk),
      .rst_n          (rst_n),
      .req_valid      (l2_req_valid),
      .req            (l2_req),
      .req_ready      (l2_req_accept),
      .req_out_valid  (del_req_valid),
      .req_out        (del_req),
      .req_out_ready  (del_req_ready),
      .rsp_in_valid   (del_rsp_valid),
      .rsp_in         (del_rsp),
      .rsp_in_ready   (del_rsp_ready),
      .rsp_out_valid  (l2_rsp_valid),
      .rsp_out        (l2_rsp),
      .rsp_out_ready  (l2_rsp_ready),
      .probe_req_pending (probe_delay_req_pending),
      .probe_rsp_pending (probe_delay_rsp_pending),
      .probe_delay_count (probe_delay_count),
      .probe_lfsr         (probe_delay_lfsr)
  );

  // ---- P6：地址路由（RAM / MMIO，均不命中回 fault）----
  logic                ram_req_valid;
  lcvex_pkg::mem_req_t ram_req;
  logic                ram_req_accept;
  logic                ram_rsp_valid;
  lcvex_pkg::mem_rsp_t ram_rsp;
  logic                ram_rsp_ready;
  logic                uart_req_valid;
  lcvex_pkg::mem_req_t uart_req;
  logic                uart_req_accept;
  logic                uart_rsp_valid;
  lcvex_pkg::mem_rsp_t uart_rsp;
  logic                uart_rsp_ready;
  logic                jtag_chipselect, jtag_read_n, jtag_write_n;
  logic [0:0]          jtag_address;
  logic [31:0]         jtag_writedata, jtag_readdata;
  logic                jtag_waitrequest;
  logic [31:0]         jtag_rx_data_read_count;
  logic [15:0]         jtag_rx_rvalid_count;
  logic                jtag_rx_seen;
  logic [7:0]          jtag_rx_last_byte;
  logic                gic_req_valid;
  lcvex_pkg::mem_req_t gic_req;
  logic                gic_req_accept;
  logic                gic_rsp_valid;
  lcvex_pkg::mem_rsp_t gic_rsp;
  logic                gic_rsp_ready;
  logic                gpio_req_valid;
  lcvex_pkg::mem_req_t gpio_req;
  logic                gpio_req_accept;
  logic                gpio_rsp_valid;
  lcvex_pkg::mem_rsp_t gpio_rsp;
  logic                gpio_rsp_ready;
  logic                gpio_irq;
  logic                fabric_req_valid;
  lcvex_pkg::mem_req_t fabric_req;
  logic                fabric_req_accept;
  logic                fabric_rsp_valid;
  lcvex_pkg::mem_rsp_t fabric_rsp;
  logic                fabric_rsp_ready;
  logic                fabric_irq;
  logic                gic_irq;
  logic                gic_fiq;
  lcvex_mem_router #(
      .SRAM_BASE(64'h0000_0000_4000_0000),
      .SRAM_TOP (64'h0000_0000_4800_0000),
      .MMIO_BASE(64'h0000_0000_0900_0000),
      .MMIO_TOP (64'h0000_0000_0900_1000),
      .MMIO2_BASE(64'h0000_0000_0800_0000),
      .MMIO2_TOP (64'h0000_0000_0802_1000),
      .MMIO3_BASE(64'h0000_0000_0903_0000),
      .MMIO3_TOP (64'h0000_0000_0903_1000),
      .MMIO4_BASE(64'h0000_0000_0901_0000),
      .MMIO4_TOP (64'h0000_0000_0a02_0000)
  ) router (
      .clk             (clk),
      .rst_n           (rst_n),
      .req_valid       (del_req_valid),
      .req             (del_req),
      .req_ready       (del_req_ready),
      .rsp_out_valid   (del_rsp_valid),
      .rsp_out         (del_rsp),
      .rsp_out_ready   (del_rsp_ready),
      .ram_req_valid   (ram_req_valid),
      .ram_req         (ram_req),
      .ram_req_accept  (ram_req_accept),
      .ram_rsp_valid   (ram_rsp_valid),
      .ram_rsp         (ram_rsp),
      .ram_rsp_ready   (ram_rsp_ready),
      .mmio_req_valid  (uart_req_valid),
      .mmio_req        (uart_req),
      .mmio_req_accept (uart_req_accept),
      .mmio_rsp_valid  (uart_rsp_valid),
      .mmio_rsp        (uart_rsp),
      .mmio_rsp_ready  (uart_rsp_ready),
      .mmio2_req_valid (gic_req_valid),
      .mmio2_req       (gic_req),
      .mmio2_req_accept(gic_req_accept),
      .mmio2_rsp_valid (gic_rsp_valid),
      .mmio2_rsp       (gic_rsp),
      .mmio2_rsp_ready (gic_rsp_ready),
      .mmio3_req_valid (gpio_req_valid),
      .mmio3_req       (gpio_req),
      .mmio3_req_accept(gpio_req_accept),
      .mmio3_rsp_valid (gpio_rsp_valid),
      .mmio3_rsp       (gpio_rsp),
      .mmio3_rsp_ready (gpio_rsp_ready),
      .mmio4_req_valid (fabric_req_valid),
      .mmio4_req       (fabric_req),
      .mmio4_req_accept(fabric_req_accept),
      .mmio4_rsp_valid (fabric_rsp_valid),
      .mmio4_rsp       (fabric_rsp),
      .mmio4_rsp_ready (fabric_rsp_ready),
      .mmio5_req_valid (),
      .mmio5_req (),
      .mmio5_req_accept (1'b0),
      .mmio5_rsp_valid (1'b0),
      .mmio5_rsp ('0),
      .mmio5_rsp_ready (),
      .mmio6_req_valid (),
      .mmio6_req (),
      .mmio6_req_accept (1'b0),
      .mmio6_rsp_valid (1'b0),
      .mmio6_rsp ('0),
      .mmio6_rsp_ready ()
  );

  lcvex_mem_ram #(
      .DEPTH(1 << 27),  // 128 MiB：QEMU virt RAM（0x40000000..0x48000000）
      .SRAM_BASE(64'h0000_0000_4000_0000)
  ) mem (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (ram_req_valid),
      .req        (ram_req),
      .req_accept (ram_req_accept),
      .rsp_valid  (ram_rsp_valid),
      .rsp        (ram_rsp),
      .rsp_ready  (ram_rsp_ready),
      .prog_we    (prog_we),
      .prog_addr  (prog_addr),
      .prog_strb  (prog_strb),
      .prog_wdata (prog_wdata),
      .dbg_addr   (dbg_addr),
      .dbg_rdata  (dbg_rdata)
  );

  generate
    if (CATAPULT_COH_ENABLE != 0) begin : g_catapult_jtag_uart
      // Use the production M1-B -> Avalon JTAG-UART bridge in the focused
      // Catapult-core test. The endpoint has a permanently available TX FIFO;
      // CONTROL reads report 64 free entries and RX remains empty.
      assign jtag_waitrequest = 1'b0;
      assign jtag_readdata = jtag_address[0] ? 32'h0040_0000 : 32'd0;
      lcvex_catapult_soc_jtag_uart jtag_uart (
          .clk(clk), .rst_n(rst_n),
          .req_valid(uart_req_valid), .req(uart_req),
          .req_accept(uart_req_accept), .rsp_valid(uart_rsp_valid),
          .rsp(uart_rsp), .rsp_ready(uart_rsp_ready),
          .chipselect(jtag_chipselect), .read_n(jtag_read_n),
          .write_n(jtag_write_n), .address(jtag_address),
          .writedata(jtag_writedata), .readdata(jtag_readdata),
          .waitrequest(jtag_waitrequest),
          .tx_valid(uart_tx_valid), .tx_char(uart_tx_char),
          .rx_data_read_count(jtag_rx_data_read_count),
          .rx_rvalid_count(jtag_rx_rvalid_count), .rx_seen(jtag_rx_seen),
          .rx_last_byte(jtag_rx_last_byte)
      );
    end else begin : g_pl011_uart
      lcvex_pl011 uart (
          .clk        (clk),
          .rst_n      (rst_n),
          .req_valid  (uart_req_valid),
          .req        (uart_req),
          .req_accept (uart_req_accept),
          .rsp_valid  (uart_rsp_valid),
          .rsp        (uart_rsp),
          .rsp_ready  (uart_rsp_ready),
          .tx_valid   (uart_tx_valid),
          .tx_char    (uart_tx_char)
      );
      assign jtag_chipselect = 1'b0;
      assign jtag_read_n = 1'b1;
      assign jtag_write_n = 1'b1;
      assign jtag_address = 1'b0;
      assign jtag_writedata = '0;
      assign jtag_readdata = '0;
      assign jtag_waitrequest = 1'b0;
      assign jtag_rx_data_read_count = '0;
      assign jtag_rx_rvalid_count = '0;
      assign jtag_rx_seen = 1'b0;
      assign jtag_rx_last_byte = '0;
    end
  endgenerate

  // QEMU virt 的非安全 PL061 GPIO @0x09030000。当前无板级输入，因此
  // gpio_irq 不接 GIC；Linux probe/ID 访问与方向寄存器仍由该模型复刻。
  lcvex_pl061 gpio (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (gpio_req_valid),
      .req        (gpio_req),
      .req_accept (gpio_req_accept),
      .rsp_valid  (gpio_rsp_valid),
      .rsp        (gpio_rsp),
      .rsp_ready  (gpio_rsp_ready),
      .irq        (gpio_irq)
  );

  // C++ fabric 保留给不宜写为 RTL 的 QEMU virt 外设。当前 PL031 RTC 是首个
  // 模型；PL011/GIC/PL061 继续走各自可综合的原生 RTL。fabric_irq 预留给
  // 将来的 PL031 SPI2 接线，P6 当前不让未配置的 RTC alarm 影响锁步。
  lcvex_mmio_fabric fabric (
      .clk          (clk),
      .rst_n        (rst_n),
      .retire_valid (commit.valid && commit_ready),
      .req_valid    (fabric_req_valid),
      .req          (fabric_req),
      .req_accept   (fabric_req_accept),
      .rsp_valid    (fabric_rsp_valid),
      .rsp          (fabric_rsp),
      .rsp_ready    (fabric_rsp_ready),
      .irq          (fabric_irq)
  );

  lcvex_gic gic (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (gic_req_valid),
      .req        (gic_req),
      .req_accept (gic_req_accept),
      .rsp_valid  (gic_rsp_valid),
      .rsp        (gic_rsp),
      .rsp_ready  (gic_rsp_ready),
      .level_ppi  ({timer_virt_irq, timer_phys_irq}),  // PPI27/30
      .level_spi  ('0),
      .irq        (gic_irq),
      .fiq        (gic_fiq)
  );

  assign gic_irq_out = gic_irq;
  assign gic_fiq_out = gic_fiq;

  assign commit_valid     = commit.valid;
  assign commit_pc        = commit.pc;
  assign commit_next_pc   = commit.next_pc;
  assign commit_insn      = commit.insn;
  assign commit_gpr_we    = commit.gpr_we;
  assign commit_gpr_rd    = commit.gpr_rd;
  assign commit_gpr_wdata = commit.gpr_wdata;
  assign commit_gpr2_we   = commit.gpr2_we;
  assign commit_gpr2_rd   = commit.gpr2_rd;
  assign commit_gpr2_wdata = commit.gpr2_wdata;
  assign commit_gpr3_we   = commit.gpr3_we;
  assign commit_gpr3_rd   = commit.gpr3_rd;
  assign commit_gpr3_wdata = commit.gpr3_wdata;
  assign commit_sp_we     = commit.sp_we;
  assign commit_sp_wdata  = commit.sp_wdata;
  assign commit_nzcv_we   = commit.nzcv_we;
  assign commit_nzcv      = commit.nzcv;
  assign commit_mem_we    = commit.mem_we;
  assign commit_mem_addr  = commit.mem_addr;
  assign commit_mem_wdata = commit.mem_wdata;
  assign commit_mem_strb  = commit.mem_strb;
  assign commit_mem2_we   = commit.mem2_we;
  assign commit_mem2_addr = commit.mem2_addr;
  assign commit_mem2_wdata = commit.mem2_wdata;
  assign commit_mem2_strb = commit.mem2_strb;
  assign commit_exc_valid = commit.exc_valid;
  assign commit_exc_code  = commit.exc_code;
  assign commit_exc_esr   = commit.exc_esr;
  assign commit_exc_far   = commit.exc_far;
  assign commit_mon_we    = commit.mon_we;
  assign commit_mon_valid = commit.mon_valid;
  assign commit_mon_addr  = commit.mon_addr;
  assign commit_mon_data  = commit.mon_data;
  assign commit_mon_data2 = commit.mon_data2;
  assign commit_vec_write_count = commit.vec_write_count;
  assign commit_vec_rd0 = commit.vec_rd0;
  assign commit_vec_rd1 = commit.vec_rd1;
  assign commit_vec_rd2 = commit.vec_rd2;
  assign commit_vec_rd3 = commit.vec_rd3;
  assign commit_vec_wdata0_lo = commit.vec_wdata0[63:0];
  assign commit_vec_wdata0_hi = commit.vec_wdata0[127:64];
  assign commit_vec_wdata1_lo = commit.vec_wdata1[63:0];
  assign commit_vec_wdata1_hi = commit.vec_wdata1[127:64];
  assign commit_vec_wdata2_lo = commit.vec_wdata2[63:0];
  assign commit_vec_wdata2_hi = commit.vec_wdata2[127:64];
  assign commit_vec_wdata3_lo = commit.vec_wdata3[63:0];
  assign commit_vec_wdata3_hi = commit.vec_wdata3[127:64];
  assign commit_fpcr_we = commit.fpcr_we;
  assign commit_fpcr_wdata = commit.fpcr_wdata;
  assign commit_fpsr_we = commit.fpsr_we;
  assign commit_fpsr_wdata = commit.fpsr_wdata;

  // P6 内核锁步调试：暴露核心 decode/mmu 内部状态（协调器故障时读取）
  assign dbg_mmu_en       = core.mmu_en;
  assign dbg_vbar_el1     = core.vbar_el1;
  assign dbg_dec_valid    = core.decode.d.valid;
  assign dbg_dec_exc      = core.decode.d.exc;
  assign dbg_dec_insn     = core.ifid_insn;
  assign dbg_dec_pc       = core.ifid_pc;
  assign dbg_dec_exc_code = core.decode.d.exc_code;

endmodule
