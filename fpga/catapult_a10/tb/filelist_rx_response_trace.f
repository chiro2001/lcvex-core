# T-20260920-013 vendor-timed CPU-originated UART DATA response trace.
rtl/lcvex_pkg.sv
rtl/lcvex_fp_state.sv
rtl/lcvex_fp_scalar.sv
rtl/lcvex_neon_fp.sv
rtl/lcvex_neon_int.sv
rtl/lcvex_regfile.sv
rtl/lcvex_alu.sv
rtl/lcvex_muldiv.sv
rtl/lcvex_mem_arb.sv
rtl/lcvex_l1_i.sv
rtl/lcvex_cache_data_ram.sv
rtl/lcvex_l1_d_wb.sv
rtl/lcvex_l2_wb.sv
rtl/lcvex_l2_probe.sv
rtl/lcvex_decode.sv
rtl/lcvex_mmu.sv
rtl/lcvex_core.sv
rtl/lcvex_axi4_pkg.sv
rtl/lcvex_axi4_avalon_pkg.sv
rtl/lcvex_async_fifo.sv
rtl/lcvex_calibration_gate.sv
rtl/lcvex_axi4_master.sv
rtl/lcvex_axi4_avalon_adapter.sv
rtl/lcvex_mem_router.sv
rtl/lcvex_catapult_soc_pkg.sv
rtl/lcvex_bram_boot.sv
rtl/lcvex_bram_boot_shim.sv
rtl/lcvex_catapult_soc_axi.sv
rtl/lcvex_catapult_soc_coh.sv
rtl/lcvex_catapult_soc_top.sv
tb/sv/lcvex_jtag_uart_model.sv
# Reuse only the standalone EMIF/EPCQ model modules defined in this source;
# the existing lcvex_catapult_soc_tb top is not selected by the runner.
fpga/catapult_a10/tb/sv/lcvex_catapult_soc_tb.sv
fpga/catapult_a10/tb/sv/lcvex_catapult_soc_rx_response_trace_tb.sv
