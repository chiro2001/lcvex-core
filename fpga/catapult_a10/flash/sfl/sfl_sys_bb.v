module sfl_sys (
		input  wire        clk_in_clk_clk,             //   clk_in_clk.clk
		input  wire        epcq_avl_csr_read,          // epcq_avl_csr.read
		output wire        epcq_avl_csr_waitrequest,   //             .waitrequest
		input  wire        epcq_avl_csr_write,         //             .write
		input  wire [2:0]  epcq_avl_csr_address,       //             .address
		input  wire [31:0] epcq_avl_csr_writedata,     //             .writedata
		output wire [31:0] epcq_avl_csr_readdata,      //             .readdata
		output wire        epcq_avl_csr_readdatavalid, //             .readdatavalid
		input  wire        epcq_avl_mem_write,         // epcq_avl_mem.write
		input  wire [6:0]  epcq_avl_mem_burstcount,    //             .burstcount
		output wire        epcq_avl_mem_waitrequest,   //             .waitrequest
		input  wire        epcq_avl_mem_read,          //             .read
		input  wire [24:0] epcq_avl_mem_address,       //             .address
		input  wire [31:0] epcq_avl_mem_writedata,     //             .writedata
		output wire [31:0] epcq_avl_mem_readdata,      //             .readdata
		output wire        epcq_avl_mem_readdatavalid, //             .readdatavalid
		input  wire [3:0]  epcq_avl_mem_byteenable,    //             .byteenable
		input  wire        rst_in_reset_reset          // rst_in_reset.reset
	);
endmodule
