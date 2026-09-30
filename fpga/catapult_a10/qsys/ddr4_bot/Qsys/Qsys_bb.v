module Qsys (
		input  wire         clk_100_clk,                       //                   clk_100.clk
		input  wire         clk_266_clk,                       //                   clk_266.clk
		input  wire         emif_bot_oct_oct_rzqin,            //              emif_bot_oct.oct_rzqin
		output wire [0:0]   emif_bot_mem_mem_ck,               //              emif_bot_mem.mem_ck
		output wire [0:0]   emif_bot_mem_mem_ck_n,             //                          .mem_ck_n
		output wire [16:0]  emif_bot_mem_mem_a,                //                          .mem_a
		output wire [0:0]   emif_bot_mem_mem_act_n,            //                          .mem_act_n
		output wire [1:0]   emif_bot_mem_mem_ba,               //                          .mem_ba
		output wire [0:0]   emif_bot_mem_mem_bg,               //                          .mem_bg
		output wire [0:0]   emif_bot_mem_mem_cke,              //                          .mem_cke
		output wire [0:0]   emif_bot_mem_mem_cs_n,             //                          .mem_cs_n
		output wire [0:0]   emif_bot_mem_mem_odt,              //                          .mem_odt
		output wire [0:0]   emif_bot_mem_mem_reset_n,          //                          .mem_reset_n
		output wire [0:0]   emif_bot_mem_mem_par,              //                          .mem_par
		input  wire [0:0]   emif_bot_mem_mem_alert_n,          //                          .mem_alert_n
		inout  wire [8:0]   emif_bot_mem_mem_dqs,              //                          .mem_dqs
		inout  wire [8:0]   emif_bot_mem_mem_dqs_n,            //                          .mem_dqs_n
		inout  wire [71:0]  emif_bot_mem_mem_dq,               //                          .mem_dq
		inout  wire [8:0]   emif_bot_mem_mem_dbi_n,            //                          .mem_dbi_n
		output wire         emif_bot_status_local_cal_success, //           emif_bot_status.local_cal_success
		output wire         emif_bot_status_local_cal_fail,    //                          .local_cal_fail
		output wire         emif_bot_emif_usr_reset_n_reset_n, // emif_bot_emif_usr_reset_n.reset_n
		output wire         emif_bot_emif_usr_clk_clk,         //     emif_bot_emif_usr_clk.clk
		output wire         emif_bot_ctrl_amm_0_waitrequest_n, //       emif_bot_ctrl_amm_0.waitrequest_n
		input  wire         emif_bot_ctrl_amm_0_read,          //                          .read
		input  wire         emif_bot_ctrl_amm_0_write,         //                          .write
		input  wire [24:0]  emif_bot_ctrl_amm_0_address,       //                          .address
		output wire [511:0] emif_bot_ctrl_amm_0_readdata,      //                          .readdata
		input  wire [511:0] emif_bot_ctrl_amm_0_writedata,     //                          .writedata
		input  wire [6:0]   emif_bot_ctrl_amm_0_burstcount,    //                          .burstcount
		input  wire [63:0]  emif_bot_ctrl_amm_0_byteenable,    //                          .byteenable
		output wire         emif_bot_ctrl_amm_0_readdatavalid, //                          .readdatavalid
		input  wire         reset_in_reset                     //                  reset_in.reset
	);
endmodule
