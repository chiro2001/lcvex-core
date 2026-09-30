// lcvex_catapult_soc_stub_top.v
// A2 open-synthesis *boundary stub* for lcvex_catapult_soc_top.
//
// This is a plain-Verilog, Yosys-readable proxy that mirrors the external port
// list of rtl/lcvex_catapult_soc_top.sv.  It does NOT contain the real LCVEX
// core/cache/SoC RTL and it is NOT an Arria 10 or ECP5 signoff.  Its purpose is
// to let open-source generic synth and optional ECP5 nextpnr exercise the same
// top-level boundary with all vendor/board-facing outputs held inactive.
//
// All outputs are tie-off constants.  The real SoC top is validated separately
// with Verilator through fpga/opensynth/rtl/lcvex_catapult_soc_tieoff.sv.
//
// This file lives only under fpga/opensynth; no RTL source is modified.

`timescale 1ns/1ps

module lcvex_catapult_soc_stub_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        emif_clk,
    input  wire        emif_rst_n,
    input  wire        emif_cal_success,
    input  wire        emif_cal_fail,
    input  wire        cal_ready,
    input  wire        cal_failed,

    output wire        avalon_read,
    output wire        avalon_write,
    output wire [24:0] avalon_address,
    output wire [511:0] avalon_writedata,
    output wire [6:0]  avalon_burstcount,
    output wire [63:0] avalon_byteenable,
    input  wire        avalon_waitrequest_n,
    input  wire [511:0] avalon_readdata,
    input  wire        avalon_readdatavalid,

    output wire        ju_chipselect,
    output wire        ju_read_n,
    output wire        ju_write_n,
    output wire [0:0]  ju_address,
    output wire [31:0] ju_writedata,
    input  wire [31:0] ju_readdata,
    input  wire        ju_waitrequest,
    input  wire        ju_irq,

    output wire        epcq_csr_read,
    output wire        epcq_csr_write,
    output wire [2:0]  epcq_csr_address,
    output wire [31:0] epcq_csr_writedata,
    input  wire        epcq_csr_waitrequest,
    input  wire [31:0] epcq_csr_readdata,
    input  wire        epcq_csr_readdatavalid,

    input  wire        prog_we,
    input  wire [63:0] prog_addr,
    input  wire [7:0]  prog_strb,
    input  wire [63:0] prog_wdata,
    input  wire [31:0] dbg_addr,
    output wire [63:0] dbg_rdata,

    input  wire        checkpoint_quiesce,
    output wire        checkpoint_ack_valid,
    input  wire        checkpoint_ack_ready,
    output wire        checkpoint_fault,
    output wire        l1_drain_done,
    output wire        l1_drain_fault,
    output wire        l2_drain_ack_valid,
    output wire        l2_drain_fault,

    output wire        commit_valid,
    output wire [63:0] commit_pc,
    output wire [63:0] commit_next_pc,
    output wire [31:0] commit_insn,
    output wire        commit_gpr_we,
    output wire [4:0]  commit_gpr_rd,
    output wire [63:0] commit_gpr_wdata,
    output wire        commit_exc_valid,
    output wire [31:0] commit_exc_code,
    output wire [31:0] commit_exc_esr,
    output wire [63:0] commit_exc_far,
    output wire        jtag_uart_tx_valid,
    output wire [7:0]  jtag_uart_tx_char,
    output wire [31:0] soc_ddr_read_count,
    output wire [31:0] soc_ddr_write_count,
    output wire        timer_phys_irq,
    output wire        timer_virt_irq,
    output wire        tlb_invalidate,

    output wire        dbg_dmem_req_valid,
    output wire        dbg_dmem_req_ready,
    output wire [63:0] dbg_dmem_req_addr,
    output wire        dbg_dmem_req_we,
    output wire [63:0] dbg_dmem_req_wdata,
    output wire        dbg_dmem_rsp_valid,
    output wire        dbg_poc_req_valid,
    output wire [63:0] dbg_poc_req_addr,
    output wire        dbg_poc_req_we,
    output wire        dbg_ddr_req_valid,
    output wire        dbg_ddr_req_ready,
    output wire        dbg_ddr_req_write,
    output wire [63:0] dbg_ddr_req_addr,
    output wire        dbg_ddr_u_req_valid,
    output wire        dbg_ddr_u_req_we,
    output wire        dbg_ddr_u_req_accept,
    output wire [2:0]  dbg_bridge_state,
    output wire        dbg_bridge_req_write_q,
    output wire        dbg_ddr_rsp_valid,
    output wire        dbg_axi_awvalid,
    output wire        dbg_axi_awready,
    output wire        dbg_axi_wvalid,
    output wire        dbg_axi_wready,
    output wire        dbg_axi_bvalid,
    output wire        dbg_axi_bready,
    output wire        dbg_axi_arvalid,
    output wire        dbg_axi_arready,
    output wire        dbg_axi_rvalid,
    output wire        dbg_axi_rready,
    output wire        dbg_avalon_read,
    output wire        dbg_avalon_write,
    output wire        dbg_avalon_readdatavalid,
    output wire        dbg_avalon_waitrequest_n,
    output wire        dbg_l1_u_req_we,
    output wire [63:0] dbg_l1_u_req_addr,
    output wire        dbg_l1_u_req_bypass,
    output wire [63:0] dbg_l1_u_req_wdata,
    output wire        dbg_arb_req0_we,
    output wire        dbg_arb_req0_bypass,
    output wire [63:0] dbg_arb_req0_wdata,
    output wire        dbg_l2_u_req_we,
    output wire [63:0] dbg_l2_u_req_addr,
    output wire        dbg_l2_u_req_bypass,
    output wire [63:0] dbg_l2_u_req_wdata,
    output wire [63:0] dbg_ju_req_wdata
);

  // Boundary stub: all SoC output pins are held at inactive tie-off constants.
  assign avalon_read           = 1'b0;
  assign avalon_write          = 1'b0;
  assign avalon_address        = 25'b0;
  assign avalon_writedata      = 512'b0;
  assign avalon_burstcount     = 7'b0;
  assign avalon_byteenable     = 64'b0;

  assign ju_chipselect         = 1'b0;
  assign ju_read_n             = 1'b1;
  assign ju_write_n            = 1'b1;
  assign ju_address            = 1'b0;
  assign ju_writedata          = 32'b0;

  assign epcq_csr_read         = 1'b0;
  assign epcq_csr_write        = 1'b0;
  assign epcq_csr_address      = 3'b0;
  assign epcq_csr_writedata    = 32'b0;

  assign dbg_rdata             = 64'b0;

  assign checkpoint_ack_valid  = 1'b0;
  assign checkpoint_fault      = 1'b0;
  assign l1_drain_done         = 1'b0;
  assign l1_drain_fault        = 1'b0;
  assign l2_drain_ack_valid    = 1'b0;
  assign l2_drain_fault        = 1'b0;

  assign commit_valid          = 1'b0;
  assign commit_pc             = 64'b0;
  assign commit_next_pc        = 64'b0;
  assign commit_insn           = 32'b0;
  assign commit_gpr_we         = 1'b0;
  assign commit_gpr_rd         = 5'b0;
  assign commit_gpr_wdata      = 64'b0;
  assign commit_exc_valid      = 1'b0;
  assign commit_exc_code       = 32'b0;
  assign commit_exc_esr        = 32'b0;
  assign commit_exc_far        = 64'b0;
  assign jtag_uart_tx_valid    = 1'b0;
  assign jtag_uart_tx_char     = 8'b0;
  assign soc_ddr_read_count    = 32'b0;
  assign soc_ddr_write_count   = 32'b0;
  assign timer_phys_irq        = 1'b0;
  assign timer_virt_irq        = 1'b0;
  assign tlb_invalidate        = 1'b0;

  assign dbg_dmem_req_valid    = 1'b0;
  assign dbg_dmem_req_ready    = 1'b0;
  assign dbg_dmem_req_addr     = 64'b0;
  assign dbg_dmem_req_we       = 1'b0;
  assign dbg_dmem_req_wdata    = 64'b0;
  assign dbg_dmem_rsp_valid    = 1'b0;
  assign dbg_poc_req_valid     = 1'b0;
  assign dbg_poc_req_addr      = 64'b0;
  assign dbg_poc_req_we        = 1'b0;
  assign dbg_ddr_req_valid     = 1'b0;
  assign dbg_ddr_req_ready     = 1'b0;
  assign dbg_ddr_req_write     = 1'b0;
  assign dbg_ddr_req_addr      = 64'b0;
  assign dbg_ddr_u_req_valid   = 1'b0;
  assign dbg_ddr_u_req_we      = 1'b0;
  assign dbg_ddr_u_req_accept  = 1'b0;
  assign dbg_bridge_state      = 3'b0;
  assign dbg_bridge_req_write_q = 1'b0;
  assign dbg_ddr_rsp_valid     = 1'b0;
  assign dbg_axi_awvalid       = 1'b0;
  assign dbg_axi_awready       = 1'b0;
  assign dbg_axi_wvalid        = 1'b0;
  assign dbg_axi_wready        = 1'b0;
  assign dbg_axi_bvalid        = 1'b0;
  assign dbg_axi_bready        = 1'b0;
  assign dbg_axi_arvalid       = 1'b0;
  assign dbg_axi_arready       = 1'b0;
  assign dbg_axi_rvalid        = 1'b0;
  assign dbg_axi_rready        = 1'b0;
  assign dbg_avalon_read       = 1'b0;
  assign dbg_avalon_write      = 1'b0;
  assign dbg_avalon_readdatavalid = 1'b0;
  assign dbg_avalon_waitrequest_n = 1'b0;
  assign dbg_l1_u_req_we       = 1'b0;
  assign dbg_l1_u_req_addr     = 64'b0;
  assign dbg_l1_u_req_bypass   = 1'b0;
  assign dbg_l1_u_req_wdata    = 64'b0;
  assign dbg_arb_req0_we       = 1'b0;
  assign dbg_arb_req0_bypass   = 1'b0;
  assign dbg_arb_req0_wdata    = 64'b0;
  assign dbg_l2_u_req_we       = 1'b0;
  assign dbg_l2_u_req_addr     = 64'b0;
  assign dbg_l2_u_req_bypass   = 1'b0;
  assign dbg_l2_u_req_wdata    = 64'b0;
  assign dbg_ju_req_wdata      = 64'b0;

endmodule
