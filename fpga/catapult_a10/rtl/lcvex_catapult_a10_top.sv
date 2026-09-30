// lcvex_catapult_a10_top.sv
//
// Catapult v3 / Arria 10 25 MHz Linux bring-up Quartus/Qsys platform shell.
//
// This is the explicit top-level entity of the skeleton project.  It owns:
//   - physical board clocks and DDR4 EMIF pins (frozen B0 assignments);
//   - the 100 MHz -> 25 MHz logic-domain divider (SDC anchor sys_clk_25);
//   - the Qsys EMIF black-box boundary (instance name "emif");
//   - the JTAG-UART Avalon slave boundary (B5 SoC master wiring);
//   - the EPCQ/SFL CSR boundary and read-only Linux Flash aperture;
//   - the platform reset/calibration gate status.
//
// B5 instantiates lcvex_catapult_soc_top (core + I/D-L1 + L2 + AXI4 + EMIF
// adapter + BRAM boot + JTAG-UART/EPCQ bridges). The Linux candidate selects
// the standalone BRAM loader MIF and routes the CPU read-only Flash aperture
// to the EPCQ Avalon memory port.

`timescale 1ns/1ps

module lcvex_catapult_a10_top #(
    // FPGA-B: reduce L2 writeback cache geometry to lower the synthesis
    // hotspot.  Old B5 geometry was L2_SETS=256/L2_WAYS=2 (32KB);
    // this reduced geometry is 64 sets x 1 way (4KB) and is intended for
    // synthesis/bring-up, not as a Linux cache-capacity claim.
    parameter int L1_SETS = 64,
    parameter int L2_SETS = 64,
    parameter int L2_WAYS = 1,
    parameter logic A64_FP_SIMD = 1'b0,
    parameter int FETCH_FIFO_ENABLE = 1,
    parameter int FETCH_FIFO_DEPTH  = 2,
    parameter int FETCH_EPOCH_W     = 8
) (
    input  wire        clk_u59,
    input  wire        clk_y3,
    input  wire        emif_bot_oct_oct_rzqin,
    output wire [0:0]  emif_bot_mem_mem_ck,
    output wire [0:0]  emif_bot_mem_mem_ck_n,
    output wire [16:0] emif_bot_mem_mem_a,
    output wire [0:0]  emif_bot_mem_mem_act_n,
    output wire [1:0]  emif_bot_mem_mem_ba,
    output wire [0:0]  emif_bot_mem_mem_bg,
    output wire [0:0]  emif_bot_mem_mem_cke,
    output wire [0:0]  emif_bot_mem_mem_cs_n,
    output wire [0:0]  emif_bot_mem_mem_odt,
    output wire [0:0]  emif_bot_mem_mem_reset_n,
    output wire [0:0]  emif_bot_mem_mem_par,
    input  wire [0:0]  emif_bot_mem_mem_alert_n,
    inout  wire [8:0]  emif_bot_mem_mem_dqs,
    inout  wire [8:0]  emif_bot_mem_mem_dqs_n,
    inout  wire [71:0] emif_bot_mem_mem_dq,
    inout  wire [8:0]  emif_bot_mem_mem_dbi_n,
    output wire [8:0]  leds
);

  // Linux candidate boot image contract: the standalone AArch64 loader is
  // generated as a byte HEX for simulation and a full 64 KiB MIF for Quartus.
  localparam int BRAM_BYTES = 1 << 16;
`ifdef SYNTHESIS
`define LCVEX_CATAPULT_BOOT_INIT_IMAGE "../boot/build/linux-loader/linux_loader.mif"
`else
`define LCVEX_CATAPULT_BOOT_INIT_IMAGE "fpga/catapult_a10/boot/build/linux-loader/linux_loader.hex"
`endif

  // ---- 100 MHz board clock -> 25 MHz logic domain ----
  // The two explicitly kept registers form a glitch-free divide-by-four
  // clock.  sys_clk_25 is the SDC generated-clock anchor
  // [get_pins {sys_clk_25|q}].  The frozen top has no external reset input,
  // so the power-up values below are also the reset phase: both divider bits
  // start low and the first logic-clock rising edge occurs after two board
  // clock edges.  The resulting period is 40 ns (25 MHz), with 20 ns high
  // and low phases.  The fixed reset-gate LOGIC_POR_CYCLES=65536 below now
  // spans 2.62144 ms at this 25 MHz logic clock.
  (* keep = "true" *) logic sys_clk_div2 = 1'b0;
  (* keep = "true" *) logic sys_clk_25 = 1'b0;
  always_ff @(posedge clk_u59) begin
    sys_clk_div2 <= ~sys_clk_div2;
    if (sys_clk_div2) begin
      sys_clk_25 <= ~sys_clk_25;
    end
  end
  wire logic_clk_25 = sys_clk_25;
  wire logic_clk = logic_clk_25;

  // ---- Qsys EMIF boundary ----
  // Instance name "emif" is referenced by the SDC clock-group path
  // emif|emif_bot|emif_bot_core_usr_clk.
  wire         usr_clk;
  wire         usr_rst_n;
  wire         cal_success;
  wire         cal_fail;
  wire         ctrl_waitrequest_n;
  wire [511:0] ctrl_readdata;
  wire         ctrl_readdatavalid;
  wire         ctrl_read;
  wire         ctrl_write;
  wire [24:0]  ctrl_address;
  wire [511:0] ctrl_writedata;
  wire [6:0]   ctrl_burstcount;
  wire [63:0]  ctrl_byteenable;

  Qsys emif (
    // Qsys clk_100 is a real 100 MHz auxiliary consumer: Qsys connects it
    // to reset_controller_0.clk and uses its reset output for EMIF global
    // reset.  Keep this port on the board clock; only the CPU/SoC side below
    // uses logic_clk_25.
    .clk_100_clk                        (clk_u59),
    .clk_266_clk                        (clk_y3),
    .emif_bot_oct_oct_rzqin             (emif_bot_oct_oct_rzqin),
    .emif_bot_mem_mem_ck                (emif_bot_mem_mem_ck),
    .emif_bot_mem_mem_ck_n              (emif_bot_mem_mem_ck_n),
    .emif_bot_mem_mem_a                 (emif_bot_mem_mem_a),
    .emif_bot_mem_mem_act_n             (emif_bot_mem_mem_act_n),
    .emif_bot_mem_mem_ba                (emif_bot_mem_mem_ba),
    .emif_bot_mem_mem_bg                (emif_bot_mem_mem_bg),
    .emif_bot_mem_mem_cke               (emif_bot_mem_mem_cke),
    .emif_bot_mem_mem_cs_n              (emif_bot_mem_mem_cs_n),
    .emif_bot_mem_mem_odt               (emif_bot_mem_mem_odt),
    .emif_bot_mem_mem_reset_n           (emif_bot_mem_mem_reset_n),
    .emif_bot_mem_mem_par               (emif_bot_mem_mem_par),
    .emif_bot_mem_mem_alert_n           (emif_bot_mem_mem_alert_n),
    .emif_bot_mem_mem_dqs               (emif_bot_mem_mem_dqs),
    .emif_bot_mem_mem_dqs_n             (emif_bot_mem_mem_dqs_n),
    .emif_bot_mem_mem_dq                (emif_bot_mem_mem_dq),
    .emif_bot_mem_mem_dbi_n             (emif_bot_mem_mem_dbi_n),
    .emif_bot_status_local_cal_success  (cal_success),
    .emif_bot_status_local_cal_fail     (cal_fail),
    .emif_bot_emif_usr_reset_n_reset_n  (usr_rst_n),
    .emif_bot_emif_usr_clk_clk          (usr_clk),
    .emif_bot_ctrl_amm_0_waitrequest_n  (ctrl_waitrequest_n),
    .emif_bot_ctrl_amm_0_read           (ctrl_read),
    .emif_bot_ctrl_amm_0_write          (ctrl_write),
    .emif_bot_ctrl_amm_0_address        (ctrl_address),
    .emif_bot_ctrl_amm_0_readdata       (ctrl_readdata),
    .emif_bot_ctrl_amm_0_writedata      (ctrl_writedata),
    .emif_bot_ctrl_amm_0_burstcount     (ctrl_burstcount),
    .emif_bot_ctrl_amm_0_byteenable     (ctrl_byteenable),
    .emif_bot_ctrl_amm_0_readdatavalid  (ctrl_readdatavalid),
    .reset_in_reset                     (1'b0)
  );

  // ---- platform reset/calibration gate ----
  (* keep = "true" *) wire logic_rst_n;
  (* keep = "true" *) wire emif_rst_n;
  (* keep = "true" *) wire cal_ready;
  (* keep = "true" *) wire cal_failed;
  (* keep = "true" *) wire ddr_en;

  lcvex_catapult_a10_reset_gate #(
    .LOGIC_POR_CYCLES (65536),
    .SYNC_STAGES      (3)
  ) reset_gate_inst (
    .logic_clk      (logic_clk),
    .emif_usr_clk   (usr_clk),
    .emif_usr_rst_n (usr_rst_n),
    .cal_success    (cal_success),
    .cal_fail       (cal_fail),
    .logic_rst_n    (logic_rst_n),
    .emif_rst_n     (emif_rst_n),
    .cal_ready      (cal_ready),
    .cal_failed     (cal_failed),
    .ddr_en         (ddr_en)
  );

  // ---- JTAG-UART Avalon slave boundary (B5 SoC master wiring) ----
  wire [31:0] jtag_uart_readdata;
  wire        jtag_uart_waitrequest;
  wire        jtag_uart_irq;
  wire        jtag_uart_chipselect;
  wire        jtag_uart_read_n;
  wire        jtag_uart_write_n;
  wire [0:0]  jtag_uart_address;
  wire [31:0] jtag_uart_writedata;

  jtag_uart_only_jtag_uart jtag_uart_inst (
    .clk            (logic_clk),
    .rst_n          (logic_rst_n),
    .av_chipselect  (jtag_uart_chipselect),
    .av_address     (jtag_uart_address),
    .av_read_n      (jtag_uart_read_n),
    .av_readdata    (jtag_uart_readdata),
    .av_write_n     (jtag_uart_write_n),
    .av_writedata   (jtag_uart_writedata),
    .av_waitrequest (jtag_uart_waitrequest),
    .av_irq         (jtag_uart_irq)
  );

  // ---- EPCQ/SFL Avalon CSR boundary (B5 SoC master wiring) ----
  wire        epcq_csr_waitrequest;
  wire [31:0] epcq_csr_readdata;
  wire        epcq_csr_readdatavalid;
  wire        epcq_csr_read;
  wire        epcq_csr_write;
  wire [2:0]  epcq_csr_address;
  wire [31:0] epcq_csr_writedata;
  wire        epcq_mem_waitrequest;
  wire [31:0] epcq_mem_readdata;
  wire        epcq_mem_readdatavalid;
  wire        epcq_mem_read;
  wire [24:0] epcq_mem_address;
  wire [6:0]  epcq_mem_burstcount;
  wire [3:0]  epcq_mem_byteenable;

  sfl_sys sfl_inst (
    .clk_in_clk_clk             (logic_clk),
    .rst_in_reset_reset         (~logic_rst_n),
    .epcq_avl_csr_read          (epcq_csr_read),
    .epcq_avl_csr_waitrequest   (epcq_csr_waitrequest),
    .epcq_avl_csr_write         (epcq_csr_write),
    .epcq_avl_csr_address       (epcq_csr_address),
    .epcq_avl_csr_writedata     (epcq_csr_writedata),
    .epcq_avl_csr_readdata      (epcq_csr_readdata),
    .epcq_avl_csr_readdatavalid (epcq_csr_readdatavalid),
    .epcq_avl_mem_write         (1'b0),
    .epcq_avl_mem_burstcount    (epcq_mem_burstcount),
    .epcq_avl_mem_waitrequest   (epcq_mem_waitrequest),
    .epcq_avl_mem_read          (epcq_mem_read),
    .epcq_avl_mem_address       (epcq_mem_address),
    .epcq_avl_mem_writedata     (32'd0),
    .epcq_avl_mem_readdata      (epcq_mem_readdata),
    .epcq_avl_mem_readdatavalid (epcq_mem_readdatavalid),
    .epcq_avl_mem_byteenable    (epcq_mem_byteenable)
  );

  // ---- B5 SoC ----
  wire        soc_prog_we;
  wire [63:0] soc_prog_addr;
  wire [7:0]  soc_prog_strb;
  wire [63:0] soc_prog_wdata;
  wire [31:0] soc_dbg_addr;
  assign soc_prog_we = 1'b0;
  assign soc_prog_addr = '0;
  assign soc_prog_strb = 8'h00;
  assign soc_prog_wdata = '0;
  assign soc_dbg_addr = 32'd0;

  lcvex_catapult_soc_top #(
      .BRAM_BYTES(BRAM_BYTES),
      .L1_SETS(L1_SETS),
      .L2_SETS(L2_SETS),
      .L2_WAYS(L2_WAYS),
      .A64_FP_SIMD(A64_FP_SIMD),
      .TIMER_REALTIME(1'b1),
      .CNTFRQ_HZ(lcvex_catapult_soc_pkg::SOC_TIMER_HZ),
      .FETCH_FIFO_ENABLE(FETCH_FIFO_ENABLE),
      .FETCH_FIFO_DEPTH(FETCH_FIFO_DEPTH),
      .FETCH_EPOCH_W(FETCH_EPOCH_W),
      .BOOT_HEX_FILE(`LCVEX_CATAPULT_BOOT_INIT_IMAGE)
  ) soc (
      .clk                     (logic_clk),
      .rst_n                   (logic_rst_n),
      .emif_clk                (usr_clk),
      .emif_rst_n              (emif_rst_n),
      .emif_cal_success        (cal_success),
      .emif_cal_fail           (cal_fail),
      .cal_ready               (cal_ready),
      .cal_failed              (cal_failed),
      .avalon_read             (ctrl_read),
      .avalon_write            (ctrl_write),
      .avalon_address          (ctrl_address),
      .avalon_writedata        (ctrl_writedata),
      .avalon_burstcount       (ctrl_burstcount),
      .avalon_byteenable       (ctrl_byteenable),
      .avalon_waitrequest_n    (ctrl_waitrequest_n),
      .avalon_readdata         (ctrl_readdata),
      .avalon_readdatavalid    (ctrl_readdatavalid),
      .ju_chipselect           (jtag_uart_chipselect),
      .ju_read_n               (jtag_uart_read_n),
      .ju_write_n              (jtag_uart_write_n),
      .ju_address              (jtag_uart_address),
      .ju_writedata            (jtag_uart_writedata),
      .ju_readdata             (jtag_uart_readdata),
      .ju_waitrequest          (jtag_uart_waitrequest),
      .ju_irq                  (jtag_uart_irq),
      .epcq_csr_read           (epcq_csr_read),
      .epcq_csr_write          (epcq_csr_write),
      .epcq_csr_address        (epcq_csr_address),
      .epcq_csr_writedata      (epcq_csr_writedata),
      .epcq_csr_waitrequest    (epcq_csr_waitrequest),
      .epcq_csr_readdata       (epcq_csr_readdata),
      .epcq_csr_readdatavalid  (epcq_csr_readdatavalid),
      .epcq_mem_read           (epcq_mem_read),
      .epcq_mem_address        (epcq_mem_address),
      .epcq_mem_burstcount     (epcq_mem_burstcount),
      .epcq_mem_byteenable     (epcq_mem_byteenable),
      .epcq_mem_waitrequest    (epcq_mem_waitrequest),
      .epcq_mem_readdata       (epcq_mem_readdata),
      .epcq_mem_readdatavalid  (epcq_mem_readdatavalid),
      .prog_we                 (soc_prog_we),
      .prog_addr               (soc_prog_addr),
      .prog_strb               (soc_prog_strb),
      .prog_wdata              (soc_prog_wdata),
      .dbg_addr                (soc_dbg_addr),
      .checkpoint_quiesce      (1'b0),
      .checkpoint_ack_ready    (1'b0)
  );

  // ---- status LEDs (cosmetic; SDC false-path target) ----
  assign leds[0] = logic_rst_n;
  assign leds[1] = cal_ready;
  assign leds[2] = cal_failed;
  assign leds[3] = emif_rst_n;
  assign leds[4] = ctrl_waitrequest_n;
  assign leds[5] = ctrl_readdatavalid;
  assign leds[6] = 1'b0;
  assign leds[7] = 1'b1;
  assign leds[8] = ddr_en;

`undef LCVEX_CATAPULT_BOOT_INIT_IMAGE

endmodule
