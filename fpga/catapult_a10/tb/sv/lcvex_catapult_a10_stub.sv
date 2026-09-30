// lcvex_catapult_a10_stub.sv
//
// Offline lint stubs for the Catapult A10 platform shell.  These modules are
// intentionally empty: real implementations are provided by the frozen
// Qsys/IP inputs (Qsys_bb.v), the JTAG-UART Verilog files and the SFL QIP
// after qsys/ip regeneration.  The stubs are never listed in the QSF and are
// only used by fpga/catapult_a10/tools/lint_platform.sh to check the shell's
// port connectivity without a Quartus installation.

`timescale 1ns/1ps

module Qsys (
    input  wire         clk_100_clk,
    input  wire         clk_266_clk,
    input  wire         emif_bot_oct_oct_rzqin,
    output wire [0:0]   emif_bot_mem_mem_ck,
    output wire [0:0]   emif_bot_mem_mem_ck_n,
    output wire [16:0]  emif_bot_mem_mem_a,
    output wire [0:0]   emif_bot_mem_mem_act_n,
    output wire [1:0]   emif_bot_mem_mem_ba,
    output wire [0:0]   emif_bot_mem_mem_bg,
    output wire [0:0]   emif_bot_mem_mem_cke,
    output wire [0:0]   emif_bot_mem_mem_cs_n,
    output wire [0:0]   emif_bot_mem_mem_odt,
    output wire [0:0]   emif_bot_mem_mem_reset_n,
    output wire [0:0]   emif_bot_mem_mem_par,
    input  wire [0:0]   emif_bot_mem_mem_alert_n,
    inout  wire [8:0]   emif_bot_mem_mem_dqs,
    inout  wire [8:0]   emif_bot_mem_mem_dqs_n,
    inout  wire [71:0]  emif_bot_mem_mem_dq,
    inout  wire [8:0]   emif_bot_mem_mem_dbi_n,
    output wire         emif_bot_status_local_cal_success,
    output wire         emif_bot_status_local_cal_fail,
    output wire         emif_bot_emif_usr_reset_n_reset_n,
    output wire         emif_bot_emif_usr_clk_clk,
    output wire         emif_bot_ctrl_amm_0_waitrequest_n,
    input  wire         emif_bot_ctrl_amm_0_read,
    input  wire         emif_bot_ctrl_amm_0_write,
    input  wire [24:0]  emif_bot_ctrl_amm_0_address,
    output wire [511:0] emif_bot_ctrl_amm_0_readdata,
    input  wire [511:0] emif_bot_ctrl_amm_0_writedata,
    input  wire [6:0]   emif_bot_ctrl_amm_0_burstcount,
    input  wire [63:0]  emif_bot_ctrl_amm_0_byteenable,
    output wire         emif_bot_ctrl_amm_0_readdatavalid,
    input  wire         reset_in_reset
);
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
endmodule
