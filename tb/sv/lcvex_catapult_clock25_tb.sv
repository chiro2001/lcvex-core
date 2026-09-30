// lcvex_catapult_clock25_tb.sv
//
// B25-CLOCK focused simulation.  The platform shell is instantiated with
// small local stand-ins for the generated Qsys/SFL/JTAG/SoC boundaries so the
// test observes the real divider in lcvex_catapult_a10_top without requiring
// a Quartus installation or the full SoC elaboration.
//
// Checks:
//   * power-up/reset phase starts low and has no runt first pulse;
//   * clk_u59=100 MHz produces a 25 MHz, 40 ns, 50% duty-cycle clock;
//   * Qsys clk_100 consumes the unchanged 100 MHz board clock;
//   * Qsys clk_266 remains connected to the unchanged clk_y3 reference.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off PINMISSING */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDPARAM */

// Minimal Qsys boundary.  The counters make the clk_100/clk_266 inputs real
// consumers in this focused test rather than passive port-name checks.
module Qsys (
    input  wire        clk_100_clk,
    input  wire        clk_266_clk,
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
    output wire        emif_bot_status_local_cal_success,
    output wire        emif_bot_status_local_cal_fail,
    output wire        emif_bot_emif_usr_reset_n_reset_n,
    output wire        emif_bot_emif_usr_clk_clk,
    output wire        emif_bot_ctrl_amm_0_waitrequest_n,
    input  wire        emif_bot_ctrl_amm_0_read,
    input  wire        emif_bot_ctrl_amm_0_write,
    input  wire [24:0] emif_bot_ctrl_amm_0_address,
    output wire [511:0] emif_bot_ctrl_amm_0_readdata,
    input  wire [511:0] emif_bot_ctrl_amm_0_writedata,
    input  wire [6:0]  emif_bot_ctrl_amm_0_burstcount,
    input  wire [63:0] emif_bot_ctrl_amm_0_byteenable,
    output wire        emif_bot_ctrl_amm_0_readdatavalid,
    input  wire        reset_in_reset
);
  integer clk_100_edges = 0;
  integer clk_266_edges = 0;

  always @(posedge clk_100_clk) clk_100_edges = clk_100_edges + 1;
  always @(posedge clk_266_clk) clk_266_edges = clk_266_edges + 1;

  assign emif_bot_mem_mem_ck       = '0;
  assign emif_bot_mem_mem_ck_n     = '0;
  assign emif_bot_mem_mem_a        = '0;
  assign emif_bot_mem_mem_act_n    = '0;
  assign emif_bot_mem_mem_ba       = '0;
  assign emif_bot_mem_mem_bg       = '0;
  assign emif_bot_mem_mem_cke      = '0;
  assign emif_bot_mem_mem_cs_n     = '0;
  assign emif_bot_mem_mem_odt      = '0;
  assign emif_bot_mem_mem_reset_n  = '0;
  assign emif_bot_mem_mem_par      = '0;
  assign emif_bot_status_local_cal_success = 1'b0;
  assign emif_bot_status_local_cal_fail    = 1'b0;
  assign emif_bot_emif_usr_reset_n_reset_n = 1'b1;
  assign emif_bot_emif_usr_clk_clk         = clk_266_clk;
  assign emif_bot_ctrl_amm_0_waitrequest_n = 1'b1;
  assign emif_bot_ctrl_amm_0_readdata      = '0;
  assign emif_bot_ctrl_amm_0_readdatavalid = 1'b0;
endmodule

module jtag_uart_only_jtag_uart (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        av_chipselect,
    input  wire        av_address,
    input  wire        av_read_n,
    output wire [31:0] av_readdata,
    input  wire        av_write_n,
    input  wire [31:0] av_writedata,
    output wire        av_waitrequest,
    output wire        av_irq
);
  assign av_readdata  = '0;
  assign av_waitrequest = 1'b0;
  assign av_irq       = 1'b0;
endmodule

module sfl_sys (
    input  wire        clk_in_clk_clk,
    input  wire        epcq_avl_csr_read,
    output wire        epcq_avl_csr_waitrequest,
    input  wire        epcq_avl_csr_write,
    input  wire [2:0]  epcq_avl_csr_address,
    input  wire [31:0] epcq_avl_csr_writedata,
    output wire [31:0] epcq_avl_csr_readdata,
    output wire        epcq_avl_csr_readdatavalid,
    input  wire        epcq_avl_mem_write,
    input  wire [6:0]  epcq_avl_mem_burstcount,
    output wire        epcq_avl_mem_waitrequest,
    input  wire        epcq_avl_mem_read,
    input  wire [24:0] epcq_avl_mem_address,
    input  wire [31:0] epcq_avl_mem_writedata,
    output wire [31:0] epcq_avl_mem_readdata,
    output wire        epcq_avl_mem_readdatavalid,
    input  wire [3:0]  epcq_avl_mem_byteenable,
    input  wire        rst_in_reset_reset
);
  assign epcq_avl_csr_waitrequest   = 1'b0;
  assign epcq_avl_csr_readdata      = '0;
  assign epcq_avl_csr_readdatavalid = 1'b0;
  assign epcq_avl_mem_waitrequest   = 1'b0;
  assign epcq_avl_mem_readdata      = '0;
  assign epcq_avl_mem_readdatavalid = 1'b0;
endmodule

// The real SoC is intentionally out of scope for this clock-only test.  Keep
// the full top-level port contract so this test still elaborates the actual
// platform shell clock/reset wiring.
module lcvex_catapult_soc_top #(
    parameter int          BRAM_BYTES = 1 << 20,
    parameter int          L1_SETS = 64,
    parameter int          L2_SETS = 256,
    parameter int          L2_WAYS = 2,
    parameter logic        A64_FP_SIMD = 1'b1,
    parameter int          FETCH_FIFO_ENABLE = 1,
    parameter int          FETCH_FIFO_DEPTH = 2,
    parameter int          FETCH_EPOCH_W = 8,
    parameter string       BOOT_HEX_FILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        emif_clk,
    input  logic        emif_rst_n,
    input  logic        emif_cal_success,
    input  logic        emif_cal_fail,
    input  logic        cal_ready,
    input  logic        cal_failed,
    output logic        avalon_read,
    output logic        avalon_write,
    output logic [24:0] avalon_address,
    output logic [511:0] avalon_writedata,
    output logic [6:0]  avalon_burstcount,
    output logic [63:0] avalon_byteenable,
    input  logic        avalon_waitrequest_n,
    input  logic [511:0] avalon_readdata,
    input  logic        avalon_readdatavalid,
    output logic        ju_chipselect,
    output logic        ju_read_n,
    output logic        ju_write_n,
    output logic [0:0]  ju_address,
    output logic [31:0] ju_writedata,
    input  logic [31:0] ju_readdata,
    input  logic        ju_waitrequest,
    input  logic        ju_irq,
    output logic        epcq_csr_read,
    output logic        epcq_csr_write,
    output logic [2:0]  epcq_csr_address,
    output logic [31:0] epcq_csr_writedata,
    input  logic        epcq_csr_waitrequest,
    input  logic [31:0] epcq_csr_readdata,
    input  logic        epcq_csr_readdatavalid,
    input  logic        prog_we,
    input  logic [63:0] prog_addr,
    input  logic [7:0]  prog_strb,
    input  logic [63:0] prog_wdata,
    input  logic [31:0] dbg_addr,
    output logic [63:0] dbg_rdata,
    input  logic        checkpoint_quiesce,
    output logic        checkpoint_ack_valid,
    input  logic        checkpoint_ack_ready,
    output logic        checkpoint_fault,
    output logic        l1_drain_done,
    output logic        l1_drain_fault,
    output logic        l2_drain_ack_valid,
    output logic        l2_drain_fault,
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
  assign avalon_read = 1'b0;
  assign avalon_write = 1'b0;
  assign avalon_address = '0;
  assign avalon_writedata = '0;
  assign avalon_burstcount = '0;
  assign avalon_byteenable = '0;
  assign ju_chipselect = 1'b0;
  assign ju_read_n = 1'b1;
  assign ju_write_n = 1'b1;
  assign ju_address = '0;
  assign ju_writedata = '0;
  assign epcq_csr_read = 1'b0;
  assign epcq_csr_write = 1'b0;
  assign epcq_csr_address = '0;
  assign epcq_csr_writedata = '0;
  assign dbg_rdata = '0;
  assign checkpoint_ack_valid = 1'b0;
  assign checkpoint_fault = 1'b0;
  assign l1_drain_done = 1'b0;
  assign l1_drain_fault = 1'b0;
  assign l2_drain_ack_valid = 1'b0;
  assign l2_drain_fault = 1'b0;
  assign commit_valid = 1'b0;
  assign commit_pc = '0;
  assign commit_next_pc = '0;
  assign commit_insn = '0;
  assign commit_gpr_we = 1'b0;
  assign commit_gpr_rd = '0;
  assign commit_gpr_wdata = '0;
  assign commit_exc_valid = 1'b0;
  assign commit_exc_code = '0;
  assign commit_exc_esr = '0;
  assign commit_exc_far = '0;
  assign jtag_uart_tx_valid = 1'b0;
  assign jtag_uart_tx_char = '0;
  assign soc_ddr_read_count = '0;
  assign soc_ddr_write_count = '0;
  assign timer_phys_irq = 1'b0;
  assign timer_virt_irq = 1'b0;
  assign tlb_invalidate = 1'b0;
  assign dbg_dmem_req_valid = 1'b0;
  assign dbg_dmem_req_ready = 1'b0;
  assign dbg_dmem_req_addr = '0;
  assign dbg_dmem_req_we = 1'b0;
  assign dbg_dmem_req_wdata = '0;
  assign dbg_dmem_rsp_valid = 1'b0;
  assign dbg_poc_req_valid = 1'b0;
  assign dbg_poc_req_addr = '0;
  assign dbg_poc_req_we = 1'b0;
  assign dbg_ddr_req_valid = 1'b0;
  assign dbg_ddr_req_ready = 1'b0;
  assign dbg_ddr_req_write = 1'b0;
  assign dbg_ddr_req_addr = '0;
  assign dbg_ddr_u_req_valid = 1'b0;
  assign dbg_ddr_u_req_we = 1'b0;
  assign dbg_ddr_u_req_accept = 1'b0;
  assign dbg_bridge_state = '0;
  assign dbg_bridge_req_write_q = 1'b0;
  assign dbg_ddr_rsp_valid = 1'b0;
  assign dbg_axi_awvalid = 1'b0;
  assign dbg_axi_awready = 1'b0;
  assign dbg_axi_wvalid = 1'b0;
  assign dbg_axi_wready = 1'b0;
  assign dbg_axi_bvalid = 1'b0;
  assign dbg_axi_bready = 1'b0;
  assign dbg_axi_arvalid = 1'b0;
  assign dbg_axi_arready = 1'b0;
  assign dbg_axi_rvalid = 1'b0;
  assign dbg_axi_rready = 1'b0;
  assign dbg_avalon_read = 1'b0;
  assign dbg_avalon_write = 1'b0;
  assign dbg_avalon_readdatavalid = 1'b0;
  assign dbg_avalon_waitrequest_n = 1'b0;
  assign dbg_l1_u_req_we = 1'b0;
  assign dbg_l1_u_req_addr = '0;
  assign dbg_l1_u_req_bypass = 1'b0;
  assign dbg_l1_u_req_wdata = '0;
  assign dbg_arb_req0_we = 1'b0;
  assign dbg_arb_req0_bypass = 1'b0;
  assign dbg_arb_req0_wdata = '0;
  assign dbg_l2_u_req_we = 1'b0;
  assign dbg_l2_u_req_addr = '0;
  assign dbg_l2_u_req_bypass = 1'b0;
  assign dbg_l2_u_req_wdata = '0;
  assign dbg_ju_req_wdata = '0;
endmodule

module lcvex_catapult_clock25_tb;
  logic clk_u59 = 1'b0;
  logic clk_y3 = 1'b0;
  always #5 clk_u59 = ~clk_u59;       // 100 MHz board input
  always #1.875 clk_y3 = ~clk_y3;    // 266.667 MHz EMIF reference

  tri        emif_bot_oct_oct_rzqin = 1'b0;
  tri [0:0]  emif_bot_mem_mem_ck;
  tri [0:0]  emif_bot_mem_mem_ck_n;
  tri [16:0] emif_bot_mem_mem_a;
  tri [0:0]  emif_bot_mem_mem_act_n;
  tri [1:0]  emif_bot_mem_mem_ba;
  tri [0:0]  emif_bot_mem_mem_bg;
  tri [0:0]  emif_bot_mem_mem_cke;
  tri [0:0]  emif_bot_mem_mem_cs_n;
  tri [0:0]  emif_bot_mem_mem_odt;
  tri [0:0]  emif_bot_mem_mem_reset_n;
  tri [0:0]  emif_bot_mem_mem_par;
  logic [0:0] emif_bot_mem_mem_alert_n = '0;
  tri [8:0]  emif_bot_mem_mem_dqs;
  tri [8:0]  emif_bot_mem_mem_dqs_n;
  tri [71:0] emif_bot_mem_mem_dq;
  tri [8:0]  emif_bot_mem_mem_dbi_n;
  wire [8:0] leds;

  integer board_edges = 0;
  always @(posedge clk_u59) board_edges = board_edges + 1;

  lcvex_catapult_a10_top dut (
    .clk_u59(clk_u59), .clk_y3(clk_y3),
    .emif_bot_oct_oct_rzqin(emif_bot_oct_oct_rzqin),
    .emif_bot_mem_mem_ck(emif_bot_mem_mem_ck),
    .emif_bot_mem_mem_ck_n(emif_bot_mem_mem_ck_n),
    .emif_bot_mem_mem_a(emif_bot_mem_mem_a),
    .emif_bot_mem_mem_act_n(emif_bot_mem_mem_act_n),
    .emif_bot_mem_mem_ba(emif_bot_mem_mem_ba),
    .emif_bot_mem_mem_bg(emif_bot_mem_mem_bg),
    .emif_bot_mem_mem_cke(emif_bot_mem_mem_cke),
    .emif_bot_mem_mem_cs_n(emif_bot_mem_mem_cs_n),
    .emif_bot_mem_mem_odt(emif_bot_mem_mem_odt),
    .emif_bot_mem_mem_reset_n(emif_bot_mem_mem_reset_n),
    .emif_bot_mem_mem_par(emif_bot_mem_mem_par),
    .emif_bot_mem_mem_alert_n(emif_bot_mem_mem_alert_n),
    .emif_bot_mem_mem_dqs(emif_bot_mem_mem_dqs),
    .emif_bot_mem_mem_dqs_n(emif_bot_mem_mem_dqs_n),
    .emif_bot_mem_mem_dq(emif_bot_mem_mem_dq),
    .emif_bot_mem_mem_dbi_n(emif_bot_mem_mem_dbi_n), .leds(leds)
  );

  integer rise_count = 0;
  integer fall_count = 0;
  realtime rise_time [0:15];
  realtime fall_time [0:15];

  always @(posedge dut.logic_clk_25) begin
    if (rise_count < 16) rise_time[rise_count] = $realtime;
    rise_count = rise_count + 1;
  end
  always @(negedge dut.logic_clk_25) begin
    if (fall_count < 16) fall_time[fall_count] = $realtime;
    fall_count = fall_count + 1;
  end

  task automatic check(input logic condition, input string message);
    if (!condition) begin
      $display("FAIL: %s", message);
      $fatal(1, "lcvex_catapult_clock25_tb failed");
    end
  endtask

  task automatic check_delta(input realtime actual, input realtime expected,
                             input string message);
    if ((actual < expected - 0.01) || (actual > expected + 0.01)) begin
      $display("FAIL: %s actual=%0.3f expected=%0.3f", message, actual, expected);
      $fatal(1, "lcvex_catapult_clock25_tb timing check failed");
    end
  endtask

  initial begin
    // The frozen board top has no external reset pin.  Power-up initialization
    // is therefore the reset phase and must hold the generated clock low.
    #1;
    check(dut.sys_clk_div2 === 1'b0, "divider phase bit reset low");
    check(dut.sys_clk_25 === 1'b0, "sys_clk_25 reset low");
    check(dut.logic_clk_25 === 1'b0, "logic_clk_25 reset low");
    check(dut.logic_rst_n === 1'b0, "logic POR reset asserted at startup");
    #3;
    check(dut.logic_clk_25 === 1'b0, "no pre-divider runt pulse");

    // Thirty board edges provide multiple complete /4 periods and leave POR
    // asserted, avoiding any dependence on the full 65536-cycle boot delay.
    repeat (30) @(posedge clk_u59);
    #1;
    check(rise_count >= 7, "at least seven logic-clock rising edges observed");
    check(fall_count >= 7, "at least seven logic-clock falling edges observed");
    check_delta(rise_time[0], 15.0, "first rising edge follows two board edges");
    for (int i = 0; i < 6; i++) begin
      check_delta(rise_time[i + 1] - rise_time[i], 40.0,
                  "logic-clock period is 40 ns");
      check_delta(fall_time[i + 1] - fall_time[i], 40.0,
                  "logic-clock falling period is 40 ns");
      check_delta(fall_time[i] - rise_time[i], 20.0,
                  "logic-clock high phase is 20 ns");
      check_delta(rise_time[i + 1] - fall_time[i], 20.0,
                  "logic-clock low phase is 20 ns");
    end

    // Qsys must consume the raw 100 MHz auxiliary clock while clk_y3 remains
    // the independent EMIF reference.  These checks complement the generated
    // Qsys connection records and catch accidental aliasing to logic_clk_25.
    check(dut.emif.clk_100_clk === clk_u59,
          "Qsys clk_100 is wired to raw clk_u59");
    check(dut.emif.clk_266_clk === clk_y3,
          "Qsys clk_266 remains wired to clk_y3");
    check(dut.emif.clk_100_edges == board_edges,
          "Qsys clk_100 consumer sees every board edge");

    $display("PASS: B25 /4 clock period=40ns high=20ns low=20ns; Qsys 100/266MHz anchors preserved");
    $finish;
  end
endmodule
