	sfl_sys u0 (
		.clk_in_clk_clk             (_connected_to_clk_in_clk_clk_),             //   input,   width = 1,   clk_in_clk.clk
		.epcq_avl_csr_read          (_connected_to_epcq_avl_csr_read_),          //   input,   width = 1, epcq_avl_csr.read
		.epcq_avl_csr_waitrequest   (_connected_to_epcq_avl_csr_waitrequest_),   //  output,   width = 1,             .waitrequest
		.epcq_avl_csr_write         (_connected_to_epcq_avl_csr_write_),         //   input,   width = 1,             .write
		.epcq_avl_csr_address       (_connected_to_epcq_avl_csr_address_),       //   input,   width = 3,             .address
		.epcq_avl_csr_writedata     (_connected_to_epcq_avl_csr_writedata_),     //   input,  width = 32,             .writedata
		.epcq_avl_csr_readdata      (_connected_to_epcq_avl_csr_readdata_),      //  output,  width = 32,             .readdata
		.epcq_avl_csr_readdatavalid (_connected_to_epcq_avl_csr_readdatavalid_), //  output,   width = 1,             .readdatavalid
		.epcq_avl_mem_write         (_connected_to_epcq_avl_mem_write_),         //   input,   width = 1, epcq_avl_mem.write
		.epcq_avl_mem_burstcount    (_connected_to_epcq_avl_mem_burstcount_),    //   input,   width = 7,             .burstcount
		.epcq_avl_mem_waitrequest   (_connected_to_epcq_avl_mem_waitrequest_),   //  output,   width = 1,             .waitrequest
		.epcq_avl_mem_read          (_connected_to_epcq_avl_mem_read_),          //   input,   width = 1,             .read
		.epcq_avl_mem_address       (_connected_to_epcq_avl_mem_address_),       //   input,  width = 25,             .address
		.epcq_avl_mem_writedata     (_connected_to_epcq_avl_mem_writedata_),     //   input,  width = 32,             .writedata
		.epcq_avl_mem_readdata      (_connected_to_epcq_avl_mem_readdata_),      //  output,  width = 32,             .readdata
		.epcq_avl_mem_readdatavalid (_connected_to_epcq_avl_mem_readdatavalid_), //  output,   width = 1,             .readdatavalid
		.epcq_avl_mem_byteenable    (_connected_to_epcq_avl_mem_byteenable_),    //   input,   width = 4,             .byteenable
		.rst_in_reset_reset         (_connected_to_rst_in_reset_reset_)          //   input,   width = 1, rst_in_reset.reset
	);
