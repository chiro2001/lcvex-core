// lcvex_catapult_soc_top.sv
// B5-SoC/Boot: Catapult A10 可综合单核 SoC 顶层（仿真 TB 之外）。
//
// 层次：
//   lcvex_core (P7 快照, RESET_PC=0)
//     -> lcvex_catapult_soc_coh (I-L1 + D-L1 WB + L2 WB + probe/drain)
//     -> lcvex_mem_router (BRAM / DDR / JTAG-UART / EPCQ-CSR / PLAT_STATUS)
//        BRAM        -> lcvex_bram_boot
//        DDR         -> lcvex_catapult_soc_axi_bridge
//                       -> lcvex_axi4_master (B1)
//                       -> lcvex_axi4_avalon_adapter (B2, 含 cal gate)
//                       -> Avalon-MM 512-bit EMIF 用户口
//        JTAG-UART   -> lcvex_catapult_soc_jtag_uart（Avalon 从口桥）
//        EPCQ CSR    -> lcvex_catapult_soc_epcq_csr（Avalon 从口桥）
//        PLAT_STATUS -> lcvex_catapult_soc_status（cal 门状态寄存器）
//
// 首版约束：JTAG-UART/EPCQ CSR 走 M1-B 直通（bypass）到 Avalon；
// EPCQ MEM 窗口保留未路由（回 fault）；DDR 写回暂为单 beat AXI 事务。

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off PINMISSING */
/* verilator lint_off WIDTHEXPAND */

module lcvex_catapult_soc_top #(
    parameter int          BRAM_BYTES    = 1 << 20,
    parameter int          L1_SETS       = 64,
    parameter int          L2_SETS       = 256,
    parameter int          L2_WAYS       = 2,
    parameter logic        A64_FP_SIMD   = 1'b1,
    parameter logic        TIMER_REALTIME = 1'b0,
    parameter logic [63:0] CNTFRQ_HZ = lcvex_pkg::CNTFRQ_EL0_VAL,
    parameter int          FETCH_FIFO_ENABLE = 1,
    parameter int          FETCH_FIFO_DEPTH  = 2,
    parameter int          FETCH_EPOCH_W     = 8,
    parameter string       BOOT_HEX_FILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        emif_clk,
    input  logic        emif_rst_n,
    // EMIF 域原始校准状态（B2 adapter）。
    input  logic        emif_cal_success,
    input  logic        emif_cal_fail,
    // 逻辑域同步后的校准状态（平台状态寄存器，来自板级 reset gate）。
    input  logic        cal_ready,
    input  logic        cal_failed,

    // Avalon-MM 512-bit EMIF 用户口（接 Qsys EMIF）。
    output logic        avalon_read,
    output logic        avalon_write,
    output logic [24:0] avalon_address,
    output logic [511:0] avalon_writedata,
    output logic [6:0]  avalon_burstcount,
    output logic [63:0] avalon_byteenable,
    input  logic        avalon_waitrequest_n,
    input  logic [511:0] avalon_readdata,
    input  logic        avalon_readdatavalid,

    // Avalon JTAG-UART 主口（接 Altera IP）。
    output logic        ju_chipselect,
    output logic        ju_read_n,
    output logic        ju_write_n,
    output logic [0:0]  ju_address,
    output logic [31:0] ju_writedata,
    input  logic [31:0] ju_readdata,
    input  logic        ju_waitrequest,
    input  logic        ju_irq,

    // Avalon EPCQ/SFL CSR 主口（接 SFL IP）。
    output logic        epcq_csr_read,
    output logic        epcq_csr_write,
    output logic [2:0]  epcq_csr_address,
    output logic [31:0] epcq_csr_writedata,
    input  logic        epcq_csr_waitrequest,
    input  logic [31:0] epcq_csr_readdata,
    input  logic        epcq_csr_readdatavalid,

    // EPCQ Flash memory port (read-only Linux image aperture).
    output logic        epcq_mem_read,
    output logic [24:0] epcq_mem_address,
    output logic [6:0]  epcq_mem_burstcount,
    output logic [3:0]  epcq_mem_byteenable,
    input  logic        epcq_mem_waitrequest,
    input  logic [31:0] epcq_mem_readdata,
    input  logic        epcq_mem_readdatavalid,

    // BRAM 程序加载/调试口（仿真；综合顶层固定 tie-off）。
    input  logic        prog_we,
    input  logic [63:0] prog_addr,
    input  logic [7:0]  prog_strb,
    input  logic [63:0] prog_wdata,
    input  logic [31:0] dbg_addr,
    output logic [63:0] dbg_rdata,

    // checkpoint quiesce + drain（板级固定 0）。
    input  logic        checkpoint_quiesce,
    output logic        checkpoint_ack_valid,
    input  logic        checkpoint_ack_ready,
    output logic        checkpoint_fault,
    output logic        l1_drain_done,
    output logic        l1_drain_fault,
    output logic        l2_drain_ack_valid,
    output logic        l2_drain_fault,

    // 观测/调试输出。
    output logic        commit_valid,
    output logic [63:0] commit_pc,
    output logic [63:0] commit_next_pc,
    output logic [31:0] commit_insn,
    output logic        commit_gpr_we,
    output logic [4:0]  commit_gpr_rd,
    output logic [63:0] commit_gpr_wdata,
    output logic        commit_exc_valid,
    output logic [31:0] commit_exc_code,
    output logic [31:0] commit_exc_esr,
    output logic [63:0] commit_exc_far,
    output logic        jtag_uart_tx_valid,
    output logic [7:0]  jtag_uart_tx_char,
    output logic [31:0] soc_ddr_read_count,
    output logic [31:0] soc_ddr_write_count,
    output logic        timer_phys_irq,
    output logic        timer_virt_irq,
    output logic        tlb_invalidate,

    // 调试观测（综合顶层可悬空）。
    output logic        dbg_dmem_req_valid,
    output logic        dbg_dmem_req_ready,
    output logic [63:0] dbg_dmem_req_addr,
    output logic        dbg_dmem_req_we,
    output logic [63:0] dbg_dmem_req_wdata,
    output logic        dbg_dmem_rsp_valid,
    output logic        dbg_poc_req_valid,
    output logic [63:0] dbg_poc_req_addr,
    output logic        dbg_poc_req_we,
    output logic        dbg_ddr_req_valid,
    output logic        dbg_ddr_req_ready,
    output logic        dbg_ddr_req_write,
    output logic [63:0] dbg_ddr_req_addr,
    output logic        dbg_ddr_u_req_valid,
    output logic        dbg_ddr_u_req_we,
    output logic        dbg_ddr_u_req_accept,
    output logic [2:0]  dbg_bridge_state,
    output logic        dbg_bridge_req_write_q,
    output logic        dbg_ddr_rsp_valid,
    output logic        dbg_axi_awvalid,
    output logic        dbg_axi_awready,
    output logic        dbg_axi_wvalid,
    output logic        dbg_axi_wready,
    output logic        dbg_axi_bvalid,
    output logic        dbg_axi_bready,
    output logic        dbg_axi_arvalid,
    output logic        dbg_axi_arready,
    output logic        dbg_axi_rvalid,
    output logic        dbg_axi_rready,
    output logic        dbg_avalon_read,
    output logic        dbg_avalon_write,
    output logic        dbg_avalon_readdatavalid,
    output logic        dbg_avalon_waitrequest_n,
    output logic        dbg_l1_u_req_we,
    output logic [63:0] dbg_l1_u_req_addr,
    output logic        dbg_l1_u_req_bypass,
    output logic [63:0] dbg_l1_u_req_wdata,
    output logic        dbg_arb_req0_we,
    output logic        dbg_arb_req0_bypass,
    output logic [63:0] dbg_arb_req0_wdata,
    output logic        dbg_l2_u_req_we,
    output logic [63:0] dbg_l2_u_req_addr,
    output logic        dbg_l2_u_req_bypass,
    output logic [63:0] dbg_l2_u_req_wdata,
    output logic [63:0] dbg_ju_req_wdata
);

  import lcvex_pkg::*;
  import lcvex_catapult_soc_pkg::*;

  lcvex_pkg::commit_packet_t commit;

  // ---------------- core -> coherence ----------------
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

  // ---------------- coherence -> router ----------------
  logic        poc_req_valid;
  mem_req_t    poc_req;
  logic        poc_req_ready;
  logic        poc_rsp_valid;
  mem_rsp_t    poc_rsp;
  logic        poc_rsp_ready;

  // ---------------- router -> slaves ----------------
  logic        bram_req_valid;
  mem_req_t    bram_req;
  logic        bram_req_accept;
  logic        bram_rsp_valid;
  mem_rsp_t    bram_rsp;
  logic        bram_rsp_ready;
  logic        ddr_req_valid;
  mem_req_t    ddr_req;
  logic        ddr_req_accept;
  logic        ddr_rsp_valid;
  mem_rsp_t    ddr_rsp;
  logic        ddr_rsp_ready;
  logic        ju_req_valid;
  mem_req_t    ju_req;
  logic        ju_req_accept;
  logic        ju_rsp_valid;
  mem_rsp_t    ju_rsp;
  logic        ju_rsp_ready;
  logic [31:0] ju_rx_data_read_count;
  logic [15:0] ju_rx_rvalid_count;
  logic        ju_rx_seen;
  logic [7:0]  ju_rx_last_byte;

  // T-20260920-013：CPU-originated UART DATA response observation only.
  // These tokens/counters are deliberately downstream of the functional
  // handshake wires and never feed request/response control.
  logic        obs_bridge_pending_q;
  logic        obs_poc_pending_q;
  logic        obs_dmem_pending_q;
  logic [7:0]  obs_bridge_count_q;
  logic [7:0]  obs_poc_count_q;
  logic [7:0]  obs_dmem_count_q;
  logic [31:0] obs_bridge_rsp_data_q;
  logic [31:0] obs_poc_rsp_data_q;
  logic [31:0] obs_dmem_rsp_data_q;
  logic        obs_bridge_fault_q;
  logic        obs_poc_fault_q;
  logic        obs_dmem_fault_q;
  logic [15:0] obs_tx_count_q;
  logic        obs_tx_seen_q;
  logic [7:0]  obs_tx_last_byte_q;
  logic [31:0] obs_path_events;
  logic [31:0] obs_tx_events;
  logic        epcq_req_valid;
  mem_req_t    epcq_req;
  logic        epcq_req_accept;
  logic        epcq_rsp_valid;
  mem_rsp_t    epcq_rsp;
  logic        epcq_rsp_ready;
  logic        status_req_valid;
  mem_req_t    status_req;
  logic        status_req_accept;
  logic        status_rsp_valid;
  mem_rsp_t    status_rsp;
  logic        status_rsp_ready;
  logic        gic_req_valid;
  mem_req_t    gic_req;
  logic        gic_req_accept;
  logic        gic_rsp_valid;
  mem_rsp_t    gic_rsp;
  logic        gic_rsp_ready;
  logic        gic_irq;
  logic        gic_fiq;
  logic [63:0] gic_level_spi;
  logic        flash_req_valid;
  mem_req_t    flash_req;
  logic        flash_req_accept;
  logic        flash_rsp_valid;
  mem_rsp_t    flash_rsp;
  logic        flash_rsp_ready;

  // ---------------- DDR AXI 链 ----------------
  logic        a_req_valid;
  logic        a_req_ready;
  logic        a_req_write;
  logic [63:0] a_req_addr;
  logic [3:0]  a_req_id;
  logic [7:0]  a_req_len;
  logic [2:0]  a_req_size;
  logic [1:0]  a_req_burst;
  logic [128*16-1:0] a_req_wdata;
  logic [16*16-1:0]  a_req_wstrb;
  logic        a_rsp_valid;
  logic        a_rsp_ready;
  logic        a_rsp_write;
  logic [3:0]  a_rsp_id;
  logic [127:0] a_rsp_rdata;
  logic [1:0]  a_rsp_resp;
  logic        a_rsp_last;

  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic [3:0]  awid, bid;
  logic [63:0] awaddr;
  logic [7:0]  awlen;
  logic [2:0]  awsize;
  logic [1:0]  awburst, bresp;
  logic        awlock;
  logic [3:0]  awcache, awqos;
  logic [2:0]  awprot;
  logic [127:0] wdata;
  logic [15:0] wstrb;
  logic        wlast;
  logic        arvalid, arready, rvalid, rready;
  logic [3:0]  arid, rid;
  logic [63:0] araddr;
  logic [7:0]  arlen;
  logic [2:0]  arsize;
  logic [1:0]  arburst, rresp;
  logic        arlock;
  logic [3:0]  arcache;
  logic [2:0]  arprot;
  logic        avalon_timeout_abort;
  logic [3:0]  arqos;
  logic [127:0] rdata;
  logic        rlast;

  logic [31:0] ddr_read_count;
  logic [31:0] ddr_write_count;
  logic [2:0]  ddr_bridge_state;
  logic        ddr_bridge_req_write_q;

  // ---------------- core ----------------
  logic [63:0] fp_restore_v_lo [0:31];
  logic [63:0] fp_restore_v_hi [0:31];
  always_comb begin
    for (int i = 0; i < 32; i++) begin
      fp_restore_v_lo[i] = 64'd0;
      fp_restore_v_hi[i] = 64'd0;
    end
  end

  lcvex_core #(
      .RESET_PC (64'h0000_0000_0000_0000),
      // core 内部“SRAM 窗口”覆盖 BRAM+DDR（0x0..0x48000000）：
      // MMU 关闭时 decode 用该窗口做取指/分支目标 IABT 边界，
      // pa_window8 也用同一窗口做 LSE128 原子范围检查。
      .SRAM_BASE(64'h0000_0000_0000_0000),
      .SRAM_TOP (SOC_DDR_TOP),
      .MMIO_BASE(SOC_JTAG_UART_BASE),
      .MMIO_TOP (SOC_JTAG_UART_TOP),
      .MMIO2_BASE(SOC_GIC_BASE),
      .MMIO2_TOP (SOC_GIC_TOP),
      .MMIO3_BASE(SOC_EPCQ_CSR_BASE),
      .MMIO3_TOP (SOC_EPCQ_CSR_TOP),
      // MMU-off Catapult bring-up treats the platform/status-to-DDR span as
      // uncached.  The router below still owns the exact device/DDR decode;
      // this wider core-only attribute window merely makes early DDR smoke
      // accesses bypass L1/L2.  Once MMU is enabled, translated MAIR/page
      // attributes replace this direct-mode policy.
      .MMIO4_BASE(SOC_PLAT_STATUS_BASE),
      .MMIO4_TOP (SOC_DDR_TOP),
      .A64_FP_SIMD(A64_FP_SIMD),
      .TIMER_REALTIME(TIMER_REALTIME),
      .CNTFRQ_HZ(CNTFRQ_HZ),
      .FETCH_FIFO_ENABLE(FETCH_FIFO_ENABLE),
      .FETCH_FIFO_DEPTH(FETCH_FIFO_DEPTH),
      .FETCH_EPOCH_W(FETCH_EPOCH_W)
  ) core (
      .clk                    (clk),
      .rst_n                  (rst_n),
      .commit_ready           (1'b1),
      .commit                 (commit),
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
      .tlb_invalidate         (tlb_invalidate),
      .timer_phys_irq         (timer_phys_irq),
      .timer_virt_irq         (timer_virt_irq),
      .irq                    (gic_irq),
      .difftest_wait_release  (1'b0),
      .difftest_wait_cntvct_valid(1'b0),
      .difftest_wait_cntvct   (64'd0),
      .difftest_restore_sys_valid(1'b0),
      .difftest_restore_fp_valid(1'b0),
      .difftest_restore_fpcr  (32'd0),
      .difftest_restore_fpsr  (32'd0),
      .difftest_restore_fp_v_lo(fp_restore_v_lo),
      .difftest_restore_fp_v_hi(fp_restore_v_hi),
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

  // ---------------- coherence subsystem ----------------
  lcvex_catapult_soc_coh #(
      .LINE_BYTES(64), .L1_SETS(L1_SETS),
      .L2_SETS(L2_SETS), .L2_WAYS(L2_WAYS),
      .SOURCE_ID_W(4), .TRANSACTION_ID_W(8)
  ) coh (
      .clk(clk), .rst_n(rst_n),
      .imem_req_valid(imem_req_valid), .imem_req(imem_req),
      .imem_req_ready(imem_req_ready), .imem_rsp_valid(imem_rsp_valid),
      .imem_rsp(imem_rsp), .imem_rsp_ready(imem_rsp_ready),
      .dmem_req_valid(dmem_req_valid), .dmem_req(dmem_req),
      .dmem_req_ready(dmem_req_ready), .dmem_rsp_valid(dmem_rsp_valid),
      .dmem_rsp(dmem_rsp), .dmem_rsp_ready(dmem_rsp_ready),
      .ptw_req_valid(ptw_req_valid), .ptw_req(ptw_req),
      .ptw_req_ready(ptw_req_ready), .ptw_rsp_valid(ptw_rsp_valid),
      .ptw_rsp(ptw_rsp), .ptw_rsp_ready(ptw_rsp_ready),
      .checkpoint_quiesce(checkpoint_quiesce),
      .checkpoint_ack_valid(checkpoint_ack_valid),
      .checkpoint_ack_ready(checkpoint_ack_ready),
      .checkpoint_fault(checkpoint_fault),
      .l1_drain_done(l1_drain_done),
      .l1_drain_fault(l1_drain_fault),
      .l2_drain_ack_valid(l2_drain_ack_valid),
      .l2_drain_fault(l2_drain_fault),
      .poc_req_valid(poc_req_valid), .poc_req(poc_req),
      .poc_req_ready(poc_req_ready), .poc_rsp_valid(poc_rsp_valid),
      .poc_rsp(poc_rsp), .poc_rsp_ready(poc_rsp_ready),
      .dbg_l1_u_req_we(dbg_l1_u_req_we),
      .dbg_l1_u_req_addr(dbg_l1_u_req_addr),
      .dbg_l1_u_req_bypass(dbg_l1_u_req_bypass),
      .dbg_l1_u_req_wdata(dbg_l1_u_req_wdata),
      .dbg_arb_req0_we(dbg_arb_req0_we),
      .dbg_arb_req0_bypass(dbg_arb_req0_bypass),
      .dbg_arb_req0_wdata(dbg_arb_req0_wdata),
      .dbg_l2_u_req_we(dbg_l2_u_req_we),
      .dbg_l2_u_req_addr(dbg_l2_u_req_addr),
      .dbg_l2_u_req_bypass(dbg_l2_u_req_bypass),
      .dbg_l2_u_req_wdata(dbg_l2_u_req_wdata)
  );

  // ---------------- address router ----------------
  lcvex_mem_router #(
      .SRAM_BASE (SOC_BRAM_BASE),
      .SRAM_TOP  (SOC_BRAM_TOP),
      .MMIO_BASE (SOC_DDR_BASE),
      .MMIO_TOP  (SOC_DDR_TOP),
      .MMIO2_BASE(SOC_JTAG_UART_BASE),
      .MMIO2_TOP (SOC_JTAG_UART_TOP),
      .MMIO3_BASE(SOC_EPCQ_CSR_BASE),
      .MMIO3_TOP (SOC_EPCQ_CSR_TOP),
      .MMIO4_BASE(SOC_PLAT_STATUS_BASE),
      .MMIO4_TOP (SOC_PLAT_STATUS_TOP),
      .MMIO5_BASE(SOC_GIC_BASE),
      .MMIO5_TOP (SOC_GIC_TOP),
      .MMIO6_BASE(SOC_FLASH_BASE),
      .MMIO6_TOP (SOC_FLASH_TOP)
  ) router (
      .clk(clk), .rst_n(rst_n),
      .req_valid(poc_req_valid), .req(poc_req), .req_ready(poc_req_ready),
      .rsp_out_valid(poc_rsp_valid), .rsp_out(poc_rsp),
      .rsp_out_ready(poc_rsp_ready),
      .ram_req_valid(bram_req_valid), .ram_req(bram_req),
      .ram_req_accept(bram_req_accept), .ram_rsp_valid(bram_rsp_valid),
      .ram_rsp(bram_rsp), .ram_rsp_ready(bram_rsp_ready),
      .mmio_req_valid(ddr_req_valid), .mmio_req(ddr_req),
      .mmio_req_accept(ddr_req_accept), .mmio_rsp_valid(ddr_rsp_valid),
      .mmio_rsp(ddr_rsp), .mmio_rsp_ready(ddr_rsp_ready),
      .mmio2_req_valid(ju_req_valid), .mmio2_req(ju_req),
      .mmio2_req_accept(ju_req_accept), .mmio2_rsp_valid(ju_rsp_valid),
      .mmio2_rsp(ju_rsp), .mmio2_rsp_ready(ju_rsp_ready),
      .mmio3_req_valid(epcq_req_valid), .mmio3_req(epcq_req),
      .mmio3_req_accept(epcq_req_accept), .mmio3_rsp_valid(epcq_rsp_valid),
      .mmio3_rsp(epcq_rsp), .mmio3_rsp_ready(epcq_rsp_ready),
      .mmio4_req_valid(status_req_valid), .mmio4_req(status_req),
      .mmio4_req_accept(status_req_accept), .mmio4_rsp_valid(status_rsp_valid),
      .mmio4_rsp(status_rsp), .mmio4_rsp_ready(status_rsp_ready),
      .mmio5_req_valid(gic_req_valid), .mmio5_req(gic_req),
      .mmio5_req_accept(gic_req_accept), .mmio5_rsp_valid(gic_rsp_valid),
      .mmio5_rsp(gic_rsp), .mmio5_rsp_ready(gic_rsp_ready),
      .mmio6_req_valid(flash_req_valid), .mmio6_req(flash_req),
      .mmio6_req_accept(flash_req_accept), .mmio6_rsp_valid(flash_rsp_valid),
      .mmio6_rsp(flash_rsp), .mmio6_rsp_ready(flash_rsp_ready)
  );

  lcvex_catapult_soc_epcq_mem #(
      .FLASH_BASE(SOC_FLASH_BASE), .FLASH_TOP(SOC_FLASH_TOP)
  ) epcq_mem_bridge (
      .clk(clk), .rst_n(rst_n),
      .req_valid(flash_req_valid), .req(flash_req),
      .req_accept(flash_req_accept), .rsp_valid(flash_rsp_valid),
      .rsp(flash_rsp), .rsp_ready(flash_rsp_ready),
      .av_read(epcq_mem_read), .av_address(epcq_mem_address),
      .av_burstcount(epcq_mem_burstcount), .av_byteenable(epcq_mem_byteenable),
      .av_waitrequest(epcq_mem_waitrequest), .av_readdata(epcq_mem_readdata),
      .av_readdatavalid(epcq_mem_readdatavalid)
  );

  // One external JTAG-UART interrupt occupies GIC SPI INTID 33 (SPI index 1).
  // All remaining lines are tied low; the GIC still latches software
  // enable/configuration state using its normal reset and MMIO semantics.
  always_comb begin
    gic_level_spi = '0;
    gic_level_spi[SOC_JTAG_UART_SPI] = ju_irq;
  end

  lcvex_gic #(.NUM_IRQ(96)) board_gic (
      .clk(clk), .rst_n(rst_n),
      .req_valid(gic_req_valid), .req(gic_req),
      .req_accept(gic_req_accept), .rsp_valid(gic_rsp_valid),
      .rsp(gic_rsp), .rsp_ready(gic_rsp_ready),
      .level_ppi({timer_virt_irq, timer_phys_irq}),
      .level_spi(gic_level_spi), .irq(gic_irq), .fiq(gic_fiq)
  );

  // ---------------- BRAM ----------------
  lcvex_bram_boot #(
      .DEPTH_BYTES(BRAM_BYTES), .SRAM_BASE(SOC_BRAM_BASE),
      .BOOT_HEX_FILE(BOOT_HEX_FILE)
  ) bram (
      .clk(clk), .rst_n(rst_n),
      .req_valid(bram_req_valid), .req(bram_req),
      .req_accept(bram_req_accept), .rsp_valid(bram_rsp_valid),
      .rsp(bram_rsp), .rsp_ready(bram_rsp_ready),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .prog_strb(prog_strb), .prog_wdata(prog_wdata),
      .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata)
  );

  // ---------------- DDR: M1-B -> AXI -> Avalon EMIF ----------------
  lcvex_catapult_soc_axi_bridge #(
      .ADDR_WIDTH(64), .DATA_WIDTH(128), .ID_WIDTH(4),
      .MAX_BURST_LEN(16)
  ) ddr_bridge (
      .clk(clk), .rst_n(rst_n),
      .u_req_valid(ddr_req_valid), .u_req(ddr_req),
      .u_req_accept(ddr_req_accept), .u_rsp_valid(ddr_rsp_valid),
      .u_rsp(ddr_rsp), .u_rsp_ready(ddr_rsp_ready),
      .a_req_valid(a_req_valid), .a_req_ready(a_req_ready),
      .a_req_write(a_req_write), .a_req_addr(a_req_addr),
      .a_req_id(a_req_id), .a_req_len(a_req_len),
      .a_req_size(a_req_size), .a_req_burst(a_req_burst),
      .a_req_wdata(a_req_wdata), .a_req_wstrb(a_req_wstrb),
      .a_rsp_valid(a_rsp_valid), .a_rsp_ready(a_rsp_ready),
      .a_rsp_write(a_rsp_write), .a_rsp_id(a_rsp_id),
      .a_rsp_rdata(a_rsp_rdata), .a_rsp_resp(a_rsp_resp),
      .a_rsp_last(a_rsp_last),
      .axi_read_count(ddr_read_count),
      .axi_write_count(ddr_write_count),
      .dbg_state(ddr_bridge_state),
      .dbg_req_write_q(ddr_bridge_req_write_q)
  );

  lcvex_axi4_master #(
      .ADDR_WIDTH(64), .DATA_WIDTH(128), .ID_WIDTH(4),
      .MAX_BURST_LEN(16)
  ) axi_master (
      .clk(clk), .rst_n(rst_n),
      .req_valid(a_req_valid), .req_ready(a_req_ready),
      .req_write(a_req_write), .req_addr(a_req_addr),
      .req_id(a_req_id), .req_len(a_req_len),
      .req_size(a_req_size), .req_burst(a_req_burst),
      .req_wdata(a_req_wdata), .req_wstrb(a_req_wstrb),
      .rsp_valid(a_rsp_valid), .rsp_ready(a_rsp_ready),
      .rsp_write(a_rsp_write), .rsp_id(a_rsp_id),
      .rsp_rdata(a_rsp_rdata), .rsp_resp(a_rsp_resp),
      .rsp_last(a_rsp_last),
      .awvalid(awvalid), .awready(awready), .awid(awid),
      .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
      .awburst(awburst), .awlock(awlock), .awcache(awcache),
      .awprot(awprot), .awqos(awqos),
      .wvalid(wvalid), .wready(wready), .wdata(wdata),
      .wstrb(wstrb), .wlast(wlast),
      .bvalid(bvalid), .bready(bready), .bid(bid), .bresp(bresp),
      .arvalid(arvalid), .arready(arready), .arid(arid),
      .araddr(araddr), .arlen(arlen), .arsize(arsize),
      .arburst(arburst), .arlock(arlock), .arcache(arcache),
      .arprot(arprot), .arqos(arqos),
      .rvalid(rvalid), .rready(rready), .rid(rid), .rdata(rdata),
      .rresp(rresp), .rlast(rlast)
  );

  lcvex_axi4_avalon_adapter #(
      .ADDR_WIDTH(64), .DATA_WIDTH(128), .ID_WIDTH(4)
  ) emif_adapter (
      .cpu_clk(clk), .emif_clk(emif_clk),
      .cpu_rst_n(rst_n), .emif_rst_n(emif_rst_n),
      .cal_success(emif_cal_success), .cal_fail(emif_cal_fail),
      .awvalid(awvalid), .awready(awready), .awid(awid),
      .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
      .awburst(awburst), .awlock(awlock), .awcache(awcache),
      .awprot(awprot), .awqos(awqos),
      .wvalid(wvalid), .wready(wready), .wdata(wdata),
      .wstrb(wstrb), .wlast(wlast),
      .bvalid(bvalid), .bready(bready), .bid(bid), .bresp(bresp),
      .arvalid(arvalid), .arready(arready), .arid(arid),
      .araddr(araddr), .arlen(arlen), .arsize(arsize),
      .arburst(arburst), .arlock(arlock), .arcache(arcache),
      .arprot(arprot), .arqos(arqos),
      .rvalid(rvalid), .rready(rready), .rid(rid), .rdata(rdata),
      .rresp(rresp), .rlast(rlast),
      .avalon_read(avalon_read), .avalon_write(avalon_write),
      .avalon_address(avalon_address),
      .avalon_writedata(avalon_writedata),
      .avalon_burstcount(avalon_burstcount),
      .avalon_byteenable(avalon_byteenable),
      .avalon_waitrequest_n(avalon_waitrequest_n),
      .avalon_readdata(avalon_readdata),
      .avalon_readdatavalid(avalon_readdatavalid),
      .avalon_timeout_abort(avalon_timeout_abort)
  );

  // ---------------- JTAG-UART / EPCQ CSR / 状态寄存器 ----------------
  lcvex_catapult_soc_jtag_uart jtag_uart_bridge (
      .clk(clk), .rst_n(rst_n),
      .req_valid(ju_req_valid), .req(ju_req),
      .req_accept(ju_req_accept), .rsp_valid(ju_rsp_valid),
      .rsp(ju_rsp), .rsp_ready(ju_rsp_ready),
      .chipselect(ju_chipselect), .read_n(ju_read_n),
      .write_n(ju_write_n), .address(ju_address),
      .writedata(ju_writedata), .readdata(ju_readdata),
      .waitrequest(ju_waitrequest),
      .tx_valid(jtag_uart_tx_valid), .tx_char(jtag_uart_tx_char),
      .rx_data_read_count(ju_rx_data_read_count),
      .rx_rvalid_count(ju_rx_rvalid_count),
      .rx_seen(ju_rx_seen), .rx_last_byte(ju_rx_last_byte)
  );

  lcvex_catapult_soc_epcq_csr epcq_csr_bridge (
      .clk(clk), .rst_n(rst_n),
      .req_valid(epcq_req_valid), .req(epcq_req),
      .req_accept(epcq_req_accept), .rsp_valid(epcq_rsp_valid),
      .rsp(epcq_rsp), .rsp_ready(epcq_rsp_ready),
      .read(epcq_csr_read), .write(epcq_csr_write),
      .address(epcq_csr_address), .writedata(epcq_csr_writedata),
      .readdata(epcq_csr_readdata), .waitrequest(epcq_csr_waitrequest),
      .readdatavalid(epcq_csr_readdatavalid)
  );

  lcvex_catapult_soc_status status_reg (
      .clk(clk), .rst_n(rst_n),
      .req_valid(status_req_valid), .req(status_req),
      .req_accept(status_req_accept), .rsp_valid(status_rsp_valid),
      .rsp(status_rsp), .rsp_ready(status_rsp_ready),
      .cal_ready(cal_ready), .cal_failed(cal_failed),
      .jtag_data_read_count(ju_rx_data_read_count),
      .jtag_rvalid_count(ju_rx_rvalid_count),
      .jtag_rx_seen(ju_rx_seen), .jtag_last_rx_byte(ju_rx_last_byte),
      .jtag_bridge_rsp_data(obs_bridge_rsp_data_q),
      .jtag_poc_rsp_data(obs_poc_rsp_data_q),
      .jtag_dmem_rsp_data(obs_dmem_rsp_data_q),
      .jtag_path_events(obs_path_events),
      .jtag_tx_events(obs_tx_events)
  );

  // ---------------- response/TX observation state ----------------
  // A DATA read is single-outstanding at every functional layer.  The
  // observation tokens mirror that ownership only for classification; they
  // do not gate or alter any ready/valid signal.
  wire obs_bridge_req_fire = ju_req_valid && ju_req_accept &&
                             !ju_req.we &&
                             (ju_req.maint == MAINT_NONE) &&
                             (ju_req.addr == SOC_JTAG_UART_BASE);
  wire obs_poc_req_fire = poc_req_valid && poc_req_ready &&
                          !poc_req.we &&
                          (poc_req.maint == MAINT_NONE) &&
                          (poc_req.addr == SOC_JTAG_UART_BASE);
  wire obs_dmem_req_fire = dmem_req_valid && dmem_req_ready &&
                           !dmem_req.we &&
                           (dmem_req.maint == MAINT_NONE) &&
                           (dmem_req.addr == SOC_JTAG_UART_BASE);

  lcvex_catapult_soc_rx_observer rx_observer (
      .clk(clk), .rst_n(rst_n),
      .bridge_req_fire(obs_bridge_req_fire),
      .bridge_rsp_valid(ju_rsp_valid), .bridge_rsp_ready(ju_rsp_ready),
      .bridge_rsp_data_i(ju_rsp.rdata[31:0]),
      .bridge_rsp_fault_i(ju_rsp.fault),
      .poc_req_fire(obs_poc_req_fire),
      .poc_rsp_valid(poc_rsp_valid), .poc_rsp_ready(poc_rsp_ready),
      .poc_rsp_data_i(poc_rsp.rdata[31:0]),
      .poc_rsp_fault_i(poc_rsp.fault),
      .dmem_req_fire(obs_dmem_req_fire),
      .dmem_rsp_valid(dmem_rsp_valid), .dmem_rsp_ready(dmem_rsp_ready),
      .dmem_rsp_data_i(dmem_rsp.rdata[31:0]),
      .dmem_rsp_fault_i(dmem_rsp.fault),
      .tx_valid(jtag_uart_tx_valid), .tx_char(jtag_uart_tx_char),
      .bridge_pending(obs_bridge_pending_q),
      .poc_pending(obs_poc_pending_q), .dmem_pending(obs_dmem_pending_q),
      .bridge_count(obs_bridge_count_q), .poc_count(obs_poc_count_q),
      .dmem_count(obs_dmem_count_q),
      .bridge_rsp_data(obs_bridge_rsp_data_q),
      .poc_rsp_data(obs_poc_rsp_data_q),
      .dmem_rsp_data(obs_dmem_rsp_data_q),
      .bridge_fault(obs_bridge_fault_q), .poc_fault(obs_poc_fault_q),
      .dmem_fault(obs_dmem_fault_q), .tx_count(obs_tx_count_q),
      .tx_seen(obs_tx_seen_q), .tx_last_byte(obs_tx_last_byte_q)
  );

  assign obs_path_events = {obs_bridge_count_q, obs_poc_count_q,
                            obs_dmem_count_q, 5'd0,
                            obs_dmem_fault_q, obs_poc_fault_q,
                            obs_bridge_fault_q};
  assign obs_tx_events = {obs_tx_count_q, 7'd0, obs_tx_seen_q,
                          obs_tx_last_byte_q};

  // ---------------- 观测输出 ----------------
  assign commit_valid = commit.valid;
  assign commit_pc = commit.pc;
  assign commit_next_pc = commit.next_pc;
  assign commit_insn = commit.insn;
  assign commit_gpr_we = commit.gpr_we;
  assign commit_gpr_rd = commit.gpr_rd;
  assign commit_gpr_wdata = commit.gpr_wdata;
  assign commit_exc_valid = commit.exc_valid;
  assign commit_exc_code = commit.exc_code;
  assign commit_exc_esr = commit.exc_esr;
  assign commit_exc_far = commit.exc_far;
  assign soc_ddr_read_count = ddr_read_count;
  assign soc_ddr_write_count = ddr_write_count;
  assign dbg_dmem_req_valid = dmem_req_valid;
  assign dbg_dmem_req_ready = dmem_req_ready;
  assign dbg_dmem_req_addr = dmem_req.addr;
  assign dbg_dmem_req_we = dmem_req.we;
  assign dbg_dmem_req_wdata = dmem_req.wdata;
  assign dbg_dmem_rsp_valid = dmem_rsp_valid;
  assign dbg_poc_req_valid = poc_req_valid;
  assign dbg_poc_req_addr = poc_req.addr;
  assign dbg_poc_req_we = poc_req.we;
  assign dbg_ddr_req_valid = a_req_valid;
  assign dbg_ddr_req_ready = a_req_ready;
  assign dbg_ddr_req_write = a_req_write;
  assign dbg_ddr_req_addr = a_req_addr;
  assign dbg_ddr_u_req_valid = ddr_req_valid;
  assign dbg_ddr_u_req_we = ddr_req.we;
  assign dbg_ddr_u_req_accept = ddr_req_accept;
  assign dbg_bridge_state = ddr_bridge_state;
  assign dbg_bridge_req_write_q = ddr_bridge_req_write_q;
  assign dbg_ju_req_wdata = ju_req.wdata;
  assign dbg_ddr_rsp_valid = a_rsp_valid;
  assign dbg_axi_awvalid = awvalid;
  assign dbg_axi_awready = awready;
  assign dbg_axi_wvalid = wvalid;
  assign dbg_axi_wready = wready;
  assign dbg_axi_bvalid = bvalid;
  assign dbg_axi_bready = bready;
  assign dbg_axi_arvalid = arvalid;
  assign dbg_axi_arready = arready;
  assign dbg_axi_rvalid = rvalid;
  assign dbg_axi_rready = rready;
  assign dbg_avalon_read = avalon_read;
  assign dbg_avalon_write = avalon_write;
  assign dbg_avalon_readdatavalid = avalon_readdatavalid;
  assign dbg_avalon_waitrequest_n = avalon_waitrequest_n;

endmodule


// ---------------------------------------------------------------------------
// CPU-originated UART DATA response observer (observation-only).
//
// Each input stage has at most one outstanding transaction in the production
// path.  The pending bits below mirror that ownership for diagnostics only;
// no output from this module is connected to a functional handshake.
// ---------------------------------------------------------------------------
module lcvex_catapult_soc_rx_observer (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        bridge_req_fire,
    input  logic        bridge_rsp_valid,
    input  logic        bridge_rsp_ready,
    input  logic [31:0] bridge_rsp_data_i,
    input  logic        bridge_rsp_fault_i,
    input  logic        poc_req_fire,
    input  logic        poc_rsp_valid,
    input  logic        poc_rsp_ready,
    input  logic [31:0] poc_rsp_data_i,
    input  logic        poc_rsp_fault_i,
    input  logic        dmem_req_fire,
    input  logic        dmem_rsp_valid,
    input  logic        dmem_rsp_ready,
    input  logic [31:0] dmem_rsp_data_i,
    input  logic        dmem_rsp_fault_i,
    input  logic        tx_valid,
    input  logic [7:0]  tx_char,
    output logic        bridge_pending,
    output logic        poc_pending,
    output logic        dmem_pending,
    output logic [7:0]  bridge_count,
    output logic [7:0]  poc_count,
    output logic [7:0]  dmem_count,
    output logic [31:0] bridge_rsp_data,
    output logic [31:0] poc_rsp_data,
    output logic [31:0] dmem_rsp_data,
    output logic        bridge_fault,
    output logic        poc_fault,
    output logic        dmem_fault,
    output logic [15:0] tx_count,
    output logic        tx_seen,
    output logic [7:0]  tx_last_byte
);

  wire bridge_rsp_fire = bridge_pending && bridge_rsp_valid &&
                         bridge_rsp_ready;
  wire poc_rsp_fire = poc_pending && poc_rsp_valid && poc_rsp_ready;
  wire dmem_rsp_fire = dmem_pending && dmem_rsp_valid && dmem_rsp_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bridge_pending <= 1'b0;
      poc_pending <= 1'b0;
      dmem_pending <= 1'b0;
      bridge_count <= 8'd0;
      poc_count <= 8'd0;
      dmem_count <= 8'd0;
      bridge_rsp_data <= 32'd0;
      poc_rsp_data <= 32'd0;
      dmem_rsp_data <= 32'd0;
      bridge_fault <= 1'b0;
      poc_fault <= 1'b0;
      dmem_fault <= 1'b0;
      tx_count <= 16'd0;
      tx_seen <= 1'b0;
      tx_last_byte <= 8'd0;
    end else begin
      if (bridge_req_fire)
        bridge_pending <= 1'b1;
      if (poc_req_fire)
        poc_pending <= 1'b1;
      if (dmem_req_fire)
        dmem_pending <= 1'b1;

      if (bridge_rsp_fire) begin
        bridge_pending <= 1'b0;
        bridge_fault <= bridge_fault | bridge_rsp_fault_i;
        if (!bridge_rsp_fault_i && bridge_rsp_data_i[15]) begin
          bridge_count <= bridge_count + 8'd1;
          bridge_rsp_data <= bridge_rsp_data_i;
        end
      end
      if (poc_rsp_fire) begin
        poc_pending <= 1'b0;
        poc_fault <= poc_fault | poc_rsp_fault_i;
        if (!poc_rsp_fault_i && poc_rsp_data_i[15]) begin
          poc_count <= poc_count + 8'd1;
          poc_rsp_data <= poc_rsp_data_i;
        end
      end
      if (dmem_rsp_fire) begin
        dmem_pending <= 1'b0;
        dmem_fault <= dmem_fault | dmem_rsp_fault_i;
        if (!dmem_rsp_fault_i && dmem_rsp_data_i[15]) begin
          dmem_count <= dmem_count + 8'd1;
          dmem_rsp_data <= dmem_rsp_data_i;
        end
      end

      if (tx_valid) begin
        tx_count <= tx_count + 16'd1;
        tx_seen <= 1'b1;
        tx_last_byte <= tx_char;
      end
    end
  end
endmodule


// ---------------------------------------------------------------------------
// JTAG-UART Avalon 从口桥（M1-B -> Altera Avalon JTAG-UART）。
// 寄存器选择：addr[2]=0 data，addr[2]=1 control。
// ---------------------------------------------------------------------------
module lcvex_catapult_soc_jtag_uart (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    output logic                chipselect,
    output logic                read_n,
    output logic                write_n,
    output logic [0:0]          address,
    output logic [31:0]         writedata,
    input  logic [31:0]         readdata,
    input  logic                waitrequest,
    output logic                tx_valid,
    output logic [7:0]          tx_char,
    output logic [31:0]         rx_data_read_count,
    output logic [15:0]         rx_rvalid_count,
    output logic                rx_seen,
    output logic [7:0]          rx_last_byte
);

  import lcvex_pkg::*;

  typedef enum logic [1:0] {
    S_IDLE,
    S_WR,
    S_RD,
    S_RSP
  } state_t;
  state_t state_q;
  logic        req_addr_q;
  logic        req_we_q;
  logic [31:0] req_wdata_q;
  logic [31:0] rd_data_q;
  logic [63:0] rsp_data_r;
  logic        rsp_fault_r;
  logic        tx_pulse_q;
  logic [7:0]  tx_char_q;

  assign req_accept = (state_q == S_IDLE) && req_valid;
  assign rsp_valid  = (state_q == S_RSP);
  assign rsp.rdata  = rsp_data_r;
  assign rsp.fault  = rsp_fault_r;

  always_comb begin
    chipselect = 1'b0;
    read_n     = 1'b1;
    write_n    = 1'b1;
    address    = req_addr_q;
    writedata  = 32'd0;
    if (state_q == S_WR) begin
      chipselect = 1'b1;
      write_n    = 1'b0;
      writedata  = req_wdata_q;
    end else if (state_q == S_RD) begin
      chipselect = 1'b1;
      read_n     = 1'b0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= S_IDLE;
      req_addr_q  <= '0;
      req_we_q    <= 1'b0;
      req_wdata_q <= '0;
      rd_data_q   <= '0;
      rsp_data_r  <= '0;
      rsp_fault_r <= 1'b0;
      tx_pulse_q  <= 1'b0;
      tx_char_q   <= '0;
      rx_data_read_count <= 32'd0;
      rx_rvalid_count <= 16'd0;
      rx_seen <= 1'b0;
      rx_last_byte <= 8'd0;
    end else begin
      tx_pulse_q <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (req_valid) begin
            req_addr_q <= req.addr[2];
            req_we_q   <= req.we;
            req_wdata_q <= req.wdata[31:0];
            if (req.maint != MAINT_NONE) begin
              rsp_data_r  <= 64'd0;
              rsp_fault_r <= 1'b0;
              state_q <= S_RSP;
            end else if (req.we) begin
              state_q <= S_WR;
            end else begin
              state_q <= S_RD;
            end
          end
        end
        S_WR: begin
          if (!waitrequest) begin
            if (req_addr_q == 1'b0) begin
              tx_pulse_q <= 1'b1;
              tx_char_q  <= req_wdata_q[7:0];
            end
            rsp_data_r  <= 64'd0;
            rsp_fault_r <= 1'b0;
            state_q <= S_RSP;
          end
        end
        S_RD: begin
          if (!waitrequest) begin
            rd_data_q   <= readdata;
            rsp_data_r  <= {32'd0, readdata};
            rsp_fault_r <= 1'b0;
            if (req_addr_q == 1'b0) begin
              rx_data_read_count <= rx_data_read_count + 32'd1;
              if (readdata[15]) begin
                rx_rvalid_count <= rx_rvalid_count + 16'd1;
                rx_seen <= 1'b1;
                rx_last_byte <= readdata[7:0];
              end
            end
            state_q <= S_RSP;
          end
        end
        S_RSP: begin
          if (rsp_ready) begin
            state_q <= S_IDLE;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign tx_valid = tx_pulse_q;
  assign tx_char  = tx_char_q;

endmodule


// ---------------------------------------------------------------------------
// EPCQ/SFL CSR Avalon 从口桥（M1-B -> SFL CSR）。
// 寄存器选择：addr[4:2]。
// ---------------------------------------------------------------------------
module lcvex_catapult_soc_epcq_csr (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    output logic                read,
    output logic                write,
    output logic [2:0]          address,
    output logic [31:0]         writedata,
    input  logic [31:0]         readdata,
    input  logic                waitrequest,
    input  logic                readdatavalid
);

  import lcvex_pkg::*;

  typedef enum logic [1:0] {
    S_IDLE,
    S_WR,
    S_RD,
    S_RSP
  } state_t;
  state_t state_q;
  logic [2:0]  req_addr_q;
  logic        req_we_q;
  logic [31:0] req_wdata_q;
  logic [63:0] rsp_data_r;
  logic        rsp_fault_r;

  assign req_accept = (state_q == S_IDLE) && req_valid;
  assign rsp_valid  = (state_q == S_RSP);
  assign rsp.rdata  = rsp_data_r;
  assign rsp.fault  = rsp_fault_r;

  always_comb begin
    read      = 1'b0;
    write     = 1'b0;
    address   = req_addr_q;
    writedata = 32'd0;
    if (state_q == S_WR) begin
      write     = 1'b1;
      writedata = req_wdata_q;
    end else if (state_q == S_RD) begin
      read = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= S_IDLE;
      req_addr_q  <= '0;
      req_we_q    <= 1'b0;
      req_wdata_q <= '0;
      rsp_data_r  <= '0;
      rsp_fault_r <= 1'b0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (req_valid) begin
            req_addr_q <= req.addr[4:2];
            req_we_q   <= req.we;
            req_wdata_q <= req.wdata[31:0];
            if (req.maint != MAINT_NONE) begin
              rsp_data_r  <= 64'd0;
              rsp_fault_r <= 1'b0;
              state_q <= S_RSP;
            end else if (req.we) begin
              state_q <= S_WR;
            end else begin
              state_q <= S_RD;
            end
          end
        end
        S_WR: begin
          if (!waitrequest) begin
            rsp_data_r  <= 64'd0;
            rsp_fault_r <= 1'b0;
            state_q <= S_RSP;
          end
        end
        S_RD: begin
          if (readdatavalid) begin
            rsp_data_r  <= {32'd0, readdata};
            rsp_fault_r <= 1'b0;
            state_q <= S_RSP;
          end
        end
        S_RSP: begin
          if (rsp_ready) begin
            state_q <= S_IDLE;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule


// ---------------------------------------------------------------------------
// EPCQ 32-bit Avalon read port to 64-bit M1 memory responses.
// Writes/maintenance and accesses crossing the aperture end fault. Requests
// and responses are each single-outstanding and remain stable under backpressure.
// ---------------------------------------------------------------------------
module lcvex_catapult_soc_epcq_mem #(
    parameter logic [63:0] FLASH_BASE = 64'h0000_0000_1000_0000,
    parameter logic [63:0] FLASH_TOP  = 64'h0000_0000_1800_0000,
    parameter logic [31:0] WAIT_LIMIT_CYCLES = 32'd25_000_000
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    output logic                av_read,
    output logic [24:0]         av_address,
    output logic [6:0]          av_burstcount,
    output logic [3:0]          av_byteenable,
    input  logic                av_waitrequest,
    input  logic [31:0]         av_readdata,
    input  logic                av_readdatavalid
);
  import lcvex_pkg::*;

  typedef enum logic [2:0] {
    S_IDLE, S_ISSUE0, S_WAIT0, S_ISSUE1, S_WAIT1,
    S_ISSUE2, S_WAIT2, S_RESP
  } state_t;
  state_t state_q;
  logic [24:0] word_addr_q;
  logic [1:0] byte_offset_q;
  logic [31:0] first_word_q;
  logic [31:0] second_word_q;
  logic [63:0] rdata_q;
  logic fault_q;
  logic [31:0] wait_cycles_q;
  logic timeout_now;
  logic invalid_req;
  logic second_word_state;
  logic third_word_state;

  assign invalid_req = req.we || (req.maint != MAINT_NONE) ||
                       (req.addr < FLASH_BASE) ||
                       (req.addr > (FLASH_TOP - 64'd8));
  assign req_accept = req_valid && (state_q == S_IDLE);
  assign rsp_valid = (state_q == S_RESP);
  assign rsp.rdata = rdata_q;
  assign rsp.fault = fault_q;
  assign timeout_now = wait_cycles_q >= (WAIT_LIMIT_CYCLES - 32'd1);
  assign second_word_state = (state_q == S_ISSUE1) ||
                             (state_q == S_WAIT1);
  assign third_word_state = (state_q == S_ISSUE2) ||
                            (state_q == S_WAIT2);
  assign av_read = (state_q == S_ISSUE0) || (state_q == S_ISSUE1) ||
                   (state_q == S_ISSUE2);
  assign av_address = word_addr_q + (third_word_state ? 25'd2 :
                                     second_word_state ? 25'd1 : 25'd0);
  assign av_burstcount = 7'd1;
  assign av_byteenable = 4'hF;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      word_addr_q <= 25'd0;
      byte_offset_q <= 2'd0;
      first_word_q <= 32'd0;
      second_word_q <= 32'd0;
      rdata_q <= 64'd0;
      fault_q <= 1'b0;
      wait_cycles_q <= 32'd0;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (req_accept) begin
            wait_cycles_q <= 32'd0;
            if (invalid_req) begin
              rdata_q <= 64'd0;
              fault_q <= 1'b1;
              state_q <= S_RESP;
            end else begin
              word_addr_q <= 25'((req.addr - FLASH_BASE) >> 2);
              byte_offset_q <= req.addr[1:0];
              state_q <= S_ISSUE0;
            end
          end
        end
        S_ISSUE0: begin
          if (timeout_now) begin
            rdata_q <= 64'd0;
            fault_q <= 1'b1;
            wait_cycles_q <= 32'd0;
            state_q <= S_RESP;
          end else if (!av_waitrequest) begin
            wait_cycles_q <= 32'd0;
            if (av_readdatavalid) begin
              first_word_q <= av_readdata;
              state_q <= S_ISSUE1;
            end else begin
              state_q <= S_WAIT0;
            end
          end else begin
            wait_cycles_q <= wait_cycles_q + 32'd1;
          end
        end
        S_WAIT0: begin
          if (timeout_now) begin
            rdata_q <= 64'd0;
            fault_q <= 1'b1;
            wait_cycles_q <= 32'd0;
            state_q <= S_RESP;
          end else if (av_readdatavalid) begin
            first_word_q <= av_readdata;
            wait_cycles_q <= 32'd0;
            state_q <= S_ISSUE1;
          end else begin
            wait_cycles_q <= wait_cycles_q + 32'd1;
          end
        end
        S_ISSUE1: begin
          if (timeout_now) begin
            rdata_q <= 64'd0;
            fault_q <= 1'b1;
            wait_cycles_q <= 32'd0;
            state_q <= S_RESP;
          end else if (!av_waitrequest) begin
            wait_cycles_q <= 32'd0;
            if (av_readdatavalid) begin
              if (byte_offset_q == 2'd0) begin
                rdata_q <= {av_readdata, first_word_q};
                fault_q <= 1'b0;
                state_q <= S_RESP;
              end else begin
                second_word_q <= av_readdata;
                state_q <= S_ISSUE2;
              end
            end else begin
              state_q <= S_WAIT1;
            end
          end else begin
            wait_cycles_q <= wait_cycles_q + 32'd1;
          end
        end
        S_WAIT1: begin
          if (timeout_now) begin
            rdata_q <= 64'd0;
            fault_q <= 1'b1;
            wait_cycles_q <= 32'd0;
            state_q <= S_RESP;
          end else if (av_readdatavalid) begin
            wait_cycles_q <= 32'd0;
            if (byte_offset_q == 2'd0) begin
              rdata_q <= {av_readdata, first_word_q};
              fault_q <= 1'b0;
              state_q <= S_RESP;
            end else begin
              second_word_q <= av_readdata;
              state_q <= S_ISSUE2;
            end
          end else begin
            wait_cycles_q <= wait_cycles_q + 32'd1;
          end
        end
        S_ISSUE2: begin
          if (timeout_now) begin
            rdata_q <= 64'd0;
            fault_q <= 1'b1;
            wait_cycles_q <= 32'd0;
            state_q <= S_RESP;
          end else if (!av_waitrequest) begin
            wait_cycles_q <= 32'd0;
            if (av_readdatavalid) begin
              rdata_q <= 64'({av_readdata, second_word_q, first_word_q} >>
                             (8 * byte_offset_q));
              fault_q <= 1'b0;
              state_q <= S_RESP;
            end else begin
              state_q <= S_WAIT2;
            end
          end else begin
            wait_cycles_q <= wait_cycles_q + 32'd1;
          end
        end
        S_WAIT2: begin
          if (timeout_now) begin
            rdata_q <= 64'd0;
            fault_q <= 1'b1;
            wait_cycles_q <= 32'd0;
            state_q <= S_RESP;
          end else if (av_readdatavalid) begin
            rdata_q <= 64'({av_readdata, second_word_q, first_word_q} >>
                           (8 * byte_offset_q));
            fault_q <= 1'b0;
            wait_cycles_q <= 32'd0;
            state_q <= S_RESP;
          end else begin
            wait_cycles_q <= wait_cycles_q + 32'd1;
          end
        end
        S_RESP: begin
          if (rsp_ready) begin
            wait_cycles_q <= 32'd0;
            state_q <= S_IDLE;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule


// ---------------------------------------------------------------------------
// 平台校准/版本与 JTAG-RX 观测寄存器（只读，写忽略）。
//   +0x00: bit0=cal_ready, bit1=cal_failed, bit2=ddr_en,
//          bit15:8=SOC_STATUS_VERSION。
//   +0x08: completed JTAG DATA-read count。
//   +0x10: bits31:16=RVALID count, bit8=RX-seen, bits7:0=last byte。
//   +0x18/+0x20/+0x28: bridge/PoC/core-dmem DATA response low 32 bits。
//   +0x30: bits31:24/23:16/15:8=bridge/PoC/dmem RVALID response counts,
//          bits2:0=sticky dmem/PoC/bridge fault。
//   +0x38: bits31:16=accepted DATA-write count, bit8=TX-seen,
//          bits7:0=last accepted byte。
//   +0x40: read-only 64-bit logic clock cycle count; reset=0, +1 per clk。
// ---------------------------------------------------------------------------
module lcvex_catapult_soc_status (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    input  logic                cal_ready,
    input  logic                cal_failed,
    input  logic [31:0]         jtag_data_read_count,
    input  logic [15:0]         jtag_rvalid_count,
    input  logic                jtag_rx_seen,
    input  logic [7:0]          jtag_last_rx_byte,
    input  logic [31:0]         jtag_bridge_rsp_data,
    input  logic [31:0]         jtag_poc_rsp_data,
    input  logic [31:0]         jtag_dmem_rsp_data,
    input  logic [31:0]         jtag_path_events,
    input  logic [31:0]         jtag_tx_events
);

  import lcvex_pkg::*;
  import lcvex_catapult_soc_pkg::*;

  logic        rsp_pending_q;
  logic [63:0] rdata_r;
  logic [31:0] status_value;
  logic [31:0] rx_event_value;
  logic [63:0] selected_value;
  logic [63:0] cycle_counter_q;

  assign status_value = {16'd0, SOC_STATUS_VERSION, 5'd0,
                         cal_ready && !cal_failed, cal_failed, cal_ready};
  assign rx_event_value = {jtag_rvalid_count, 7'd0, jtag_rx_seen,
                           jtag_last_rx_byte};
  always_comb begin
    unique case (req.addr[11:0])
      SOC_STATUS_CAL_OFFSET: selected_value = {32'd0, status_value};
      SOC_STATUS_JTAG_READ_COUNT_OFFSET: selected_value = {32'd0, jtag_data_read_count};
      SOC_STATUS_JTAG_RX_EVENT_OFFSET: selected_value = {32'd0, rx_event_value};
      SOC_STATUS_JTAG_BRIDGE_RSP_OFFSET: selected_value = {32'd0, jtag_bridge_rsp_data};
      SOC_STATUS_JTAG_POC_RSP_OFFSET: selected_value = {32'd0, jtag_poc_rsp_data};
      SOC_STATUS_JTAG_DMEM_RSP_OFFSET: selected_value = {32'd0, jtag_dmem_rsp_data};
      SOC_STATUS_JTAG_PATH_EVENTS_OFFSET: selected_value = {32'd0, jtag_path_events};
      SOC_STATUS_JTAG_TX_EVENT_OFFSET: selected_value = {32'd0, jtag_tx_events};
      SOC_STATUS_CYCLE_COUNT_OFFSET: selected_value = cycle_counter_q;
      default: selected_value = 64'd0;
    endcase
  end
  assign req_accept = req_valid && !rsp_pending_q;
  assign rsp_valid  = rsp_pending_q;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle_counter_q <= 64'd0;
    else cycle_counter_q <= cycle_counter_q + 64'd1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_pending_q <= 1'b0;
      rdata_r       <= 64'd0;
    end else begin
      if (req_accept) begin
        rsp_pending_q <= 1'b1;
        rdata_r       <= selected_value;
      end
      if (rsp_pending_q && rsp_ready) begin
        rsp_pending_q <= 1'b0;
      end
    end
  end

endmodule
