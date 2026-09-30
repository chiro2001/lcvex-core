// lcvex_catapult_soc_tieoff.sv
// A2 open-synthesis tie-off wrapper for lcvex_catapult_soc_top.
//
// This file is intentionally NOT part of the synthesizable Arria 10 platform.
// It exists only in fpga/opensynth to let open-source elaboration (Verilator)
// and proxy flows see the real SoC top with all external board/vendor boundary
// inputs tied to known inactive values:
//   - EMIF/calibration clocks/reset/status are tied off;
//   - Avalon EMIF slave inputs are tied to "no wait / no valid / zero data";
//   - JTAG-UART and EPCQ/SFL slave inputs are tied off;
//   - BRAM program/debug and checkpoint controls are tied off.
// No RTL source semantics are changed; real lcvex_catapult_soc_top is instantiated.
//
// This wrapper is a lint/elaboration harness only. It is NOT an Arria 10
// signoff and does not replace Quartus/T-067.

`timescale 1ns/1ps

module lcvex_catapult_soc_tieoff_top #(
    parameter int          BRAM_BYTES    = 1 << 20,
    parameter int          L1_SETS       = 64,
    parameter int          L2_SETS       = 256,
    parameter int          L2_WAYS       = 2,
    parameter logic        A64_FP_SIMD   = 1'b1,
    parameter string       BOOT_HEX_FILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,

    // Avalon-MM 512-bit EMIF user port (driven by the real SoC top; exposed
    // so the boundary remains visible to lint).
    output logic        avalon_read,
    output logic        avalon_write,
    output logic [24:0] avalon_address,
    output logic [511:0] avalon_writedata,
    output logic [6:0]  avalon_burstcount,
    output logic [63:0] avalon_byteenable,

    // Avalon JTAG-UART master port.
    output logic        ju_chipselect,
    output logic        ju_read_n,
    output logic        ju_write_n,
    output logic [0:0]  ju_address,
    output logic [31:0] ju_writedata,

    // Avalon EPCQ/SFL CSR master port.
    output logic        epcq_csr_read,
    output logic        epcq_csr_write,
    output logic [2:0]  epcq_csr_address,
    output logic [31:0] epcq_csr_writedata,

    // BRAM program/debug read data.
    output logic [63:0] dbg_rdata,

    // checkpoint quiesce + drain.
    output logic        checkpoint_ack_valid,
    output logic        checkpoint_fault,
    output logic        l1_drain_done,
    output logic        l1_drain_fault,
    output logic        l2_drain_ack_valid,
    output logic        l2_drain_fault,

    // observation/debug outputs.
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

  // Tied-off external boundary inputs. The main SoC clock/reset remain exposed
  // so the harness can be driven; all vendor/board side inputs are inert.
  logic emif_clk;
  logic emif_rst_n;
  logic emif_cal_success;
  logic emif_cal_fail;
  logic cal_ready;
  logic cal_failed;

  logic        avalon_waitrequest_n;
  logic [511:0] avalon_readdata;
  logic        avalon_readdatavalid;

  logic [31:0] ju_readdata;
  logic        ju_waitrequest;
  logic        ju_irq;

  logic        epcq_csr_waitrequest;
  logic [31:0] epcq_csr_readdata;
  logic        epcq_csr_readdatavalid;

  logic        prog_we;
  logic [63:0] prog_addr;
  logic [7:0]  prog_strb;
  logic [63:0] prog_wdata;
  logic [31:0] dbg_addr;

  logic        checkpoint_quiesce;
  logic        checkpoint_ack_ready;

  assign emif_clk              = 1'b0;
  assign emif_rst_n            = 1'b1;
  assign emif_cal_success      = 1'b0;
  assign emif_cal_fail         = 1'b0;
  assign cal_ready             = 1'b0;
  assign cal_failed            = 1'b0;

  assign avalon_waitrequest_n  = 1'b1;
  assign avalon_readdata       = 512'b0;
  assign avalon_readdatavalid  = 1'b0;

  assign ju_readdata           = 32'b0;
  assign ju_waitrequest        = 1'b0;
  assign ju_irq                = 1'b0;

  assign epcq_csr_waitrequest  = 1'b0;
  assign epcq_csr_readdata     = 32'b0;
  assign epcq_csr_readdatavalid = 1'b0;

  assign prog_we               = 1'b0;
  assign prog_addr             = 64'b0;
  assign prog_strb             = 8'b0;
  assign prog_wdata            = 64'b0;
  assign dbg_addr              = 32'b0;

  assign checkpoint_quiesce    = 1'b0;
  assign checkpoint_ack_ready  = 1'b0;

  lcvex_catapult_soc_top #(
      .BRAM_BYTES    (BRAM_BYTES),
      .L1_SETS       (L1_SETS),
      .L2_SETS       (L2_SETS),
      .L2_WAYS       (L2_WAYS),
      .A64_FP_SIMD   (A64_FP_SIMD),
      .BOOT_HEX_FILE (BOOT_HEX_FILE)
  ) soc_inst (
      .clk                    (clk),
      .rst_n                  (rst_n),
      .emif_clk               (emif_clk),
      .emif_rst_n             (emif_rst_n),
      .emif_cal_success       (emif_cal_success),
      .emif_cal_fail          (emif_cal_fail),
      .cal_ready              (cal_ready),
      .cal_failed             (cal_failed),

      .avalon_read            (avalon_read),
      .avalon_write           (avalon_write),
      .avalon_address         (avalon_address),
      .avalon_writedata       (avalon_writedata),
      .avalon_burstcount      (avalon_burstcount),
      .avalon_byteenable      (avalon_byteenable),
      .avalon_waitrequest_n   (avalon_waitrequest_n),
      .avalon_readdata        (avalon_readdata),
      .avalon_readdatavalid   (avalon_readdatavalid),

      .ju_chipselect          (ju_chipselect),
      .ju_read_n              (ju_read_n),
      .ju_write_n             (ju_write_n),
      .ju_address             (ju_address),
      .ju_writedata           (ju_writedata),
      .ju_readdata            (ju_readdata),
      .ju_waitrequest         (ju_waitrequest),
      .ju_irq                 (ju_irq),

      .epcq_csr_read          (epcq_csr_read),
      .epcq_csr_write         (epcq_csr_write),
      .epcq_csr_address       (epcq_csr_address),
      .epcq_csr_writedata     (epcq_csr_writedata),
      .epcq_csr_waitrequest   (epcq_csr_waitrequest),
      .epcq_csr_readdata      (epcq_csr_readdata),
      .epcq_csr_readdatavalid (epcq_csr_readdatavalid),

      .prog_we                (prog_we),
      .prog_addr              (prog_addr),
      .prog_strb              (prog_strb),
      .prog_wdata             (prog_wdata),
      .dbg_addr               (dbg_addr),
      .dbg_rdata              (dbg_rdata),

      .checkpoint_quiesce     (checkpoint_quiesce),
      .checkpoint_ack_valid   (checkpoint_ack_valid),
      .checkpoint_ack_ready   (checkpoint_ack_ready),
      .checkpoint_fault       (checkpoint_fault),
      .l1_drain_done          (l1_drain_done),
      .l1_drain_fault         (l1_drain_fault),
      .l2_drain_ack_valid     (l2_drain_ack_valid),
      .l2_drain_fault         (l2_drain_fault),

      .commit_valid           (commit_valid),
      .commit_pc              (commit_pc),
      .commit_next_pc         (commit_next_pc),
      .commit_insn            (commit_insn),
      .commit_gpr_we          (commit_gpr_we),
      .commit_gpr_rd          (commit_gpr_rd),
      .commit_gpr_wdata       (commit_gpr_wdata),
      .commit_exc_valid       (commit_exc_valid),
      .commit_exc_code        (commit_exc_code),
      .commit_exc_esr         (commit_exc_esr),
      .commit_exc_far         (commit_exc_far),
      .jtag_uart_tx_valid     (jtag_uart_tx_valid),
      .jtag_uart_tx_char      (jtag_uart_tx_char),
      .soc_ddr_read_count     (soc_ddr_read_count),
      .soc_ddr_write_count    (soc_ddr_write_count),
      .timer_phys_irq         (timer_phys_irq),
      .timer_virt_irq         (timer_virt_irq),
      .tlb_invalidate         (tlb_invalidate),

      .dbg_dmem_req_valid     (dbg_dmem_req_valid),
      .dbg_dmem_req_ready     (dbg_dmem_req_ready),
      .dbg_dmem_req_addr      (dbg_dmem_req_addr),
      .dbg_dmem_req_we        (dbg_dmem_req_we),
      .dbg_dmem_req_wdata     (dbg_dmem_req_wdata),
      .dbg_dmem_rsp_valid     (dbg_dmem_rsp_valid),
      .dbg_poc_req_valid      (dbg_poc_req_valid),
      .dbg_poc_req_addr       (dbg_poc_req_addr),
      .dbg_poc_req_we         (dbg_poc_req_we),
      .dbg_ddr_req_valid      (dbg_ddr_req_valid),
      .dbg_ddr_req_ready      (dbg_ddr_req_ready),
      .dbg_ddr_req_write      (dbg_ddr_req_write),
      .dbg_ddr_req_addr       (dbg_ddr_req_addr),
      .dbg_ddr_u_req_valid    (dbg_ddr_u_req_valid),
      .dbg_ddr_u_req_we       (dbg_ddr_u_req_we),
      .dbg_ddr_u_req_accept   (dbg_ddr_u_req_accept),
      .dbg_bridge_state       (dbg_bridge_state),
      .dbg_bridge_req_write_q (dbg_bridge_req_write_q),
      .dbg_ddr_rsp_valid      (dbg_ddr_rsp_valid),
      .dbg_axi_awvalid        (dbg_axi_awvalid),
      .dbg_axi_awready        (dbg_axi_awready),
      .dbg_axi_wvalid         (dbg_axi_wvalid),
      .dbg_axi_wready         (dbg_axi_wready),
      .dbg_axi_bvalid         (dbg_axi_bvalid),
      .dbg_axi_bready         (dbg_axi_bready),
      .dbg_axi_arvalid        (dbg_axi_arvalid),
      .dbg_axi_arready        (dbg_axi_arready),
      .dbg_axi_rvalid         (dbg_axi_rvalid),
      .dbg_axi_rready         (dbg_axi_rready),
      .dbg_avalon_read        (dbg_avalon_read),
      .dbg_avalon_write       (dbg_avalon_write),
      .dbg_avalon_readdatavalid (dbg_avalon_readdatavalid),
      .dbg_avalon_waitrequest_n (dbg_avalon_waitrequest_n),
      .dbg_l1_u_req_we        (dbg_l1_u_req_we),
      .dbg_l1_u_req_addr      (dbg_l1_u_req_addr),
      .dbg_l1_u_req_bypass    (dbg_l1_u_req_bypass),
      .dbg_l1_u_req_wdata     (dbg_l1_u_req_wdata),
      .dbg_arb_req0_we        (dbg_arb_req0_we),
      .dbg_arb_req0_bypass    (dbg_arb_req0_bypass),
      .dbg_arb_req0_wdata     (dbg_arb_req0_wdata),
      .dbg_l2_u_req_we        (dbg_l2_u_req_we),
      .dbg_l2_u_req_addr      (dbg_l2_u_req_addr),
      .dbg_l2_u_req_bypass    (dbg_l2_u_req_bypass),
      .dbg_l2_u_req_wdata     (dbg_l2_u_req_wdata),
      .dbg_ju_req_wdata       (dbg_ju_req_wdata)
  );

endmodule
