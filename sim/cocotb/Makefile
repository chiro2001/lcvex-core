# Cocotb 测试入口（Verilator 后端）。
# 顶层 make test 会以 lcvex conda 环境调用本 Makefile。

SIM ?= verilator
TOPLEVEL_LANG ?= verilog

TOPLEVEL ?= lcvex_soc_tb
COCOTB_TEST_MODULES ?= test_lcvex_core

VERILOG_SOURCES = $(abspath ../../rtl/lcvex_pkg.sv) \
                  $(abspath ../../rtl/lcvex_fp_state.sv) \
                  $(abspath ../../rtl/lcvex_fp_scalar.sv) \
                  $(abspath ../../rtl/lcvex_neon_fp.sv) \
                  $(abspath ../../rtl/lcvex_neon_int.sv) \
                  $(abspath ../../rtl/lcvex_regfile.sv) \
                  $(abspath ../../rtl/lcvex_alu.sv) \
                  $(abspath ../../rtl/lcvex_muldiv.sv) \
                  $(abspath ../../rtl/lcvex_mem.sv) \
                  $(abspath ../../rtl/lcvex_mem_ram.sv) \
                  $(abspath ../../rtl/lcvex_mem_delay.sv) \
                  $(abspath ../../rtl/lcvex_mem_arb.sv) \
                  $(abspath ../../rtl/lcvex_mem_router.sv) \
                  $(abspath ../../rtl/lcvex_pl011.sv) \
                  $(abspath ../../rtl/lcvex_pl061.sv) \
                  $(abspath ../../rtl/lcvex_mmio_fabric.sv) \
                  $(abspath ../../rtl/lcvex_gic.sv) \
                  $(abspath ../../rtl/lcvex_decode.sv) \
                  $(abspath ../../rtl/lcvex_mmu.sv) \
                  $(abspath ../../rtl/lcvex_core.sv) \
                  $(abspath ../../tb/sv/lcvex_soc_tb.sv) \
                  $(abspath ../../tb/sv/lcvex_mmio_fabric_cocotb_tb.sv)

# Cocotb 2.x 需要 --timing 支持 Python 侧时钟与触发器
EXTRA_ARGS += --timing --assert

# Verilator 必须把与 DPI bridge 对应的 C++ fabric 链入每一种 Cocotb 顶层。
# COMPILE_ARGS 仅传给构建命令；不要放进 EXTRA_ARGS，后者也会传给运行期。
MMIO_FABRIC_CPP := $(abspath ../mmio/lcvex_mmio_fabric.cc)
CUSTOM_COMPILE_DEPS += $(MMIO_FABRIC_CPP)
COMPILE_ARGS += $(MMIO_FABRIC_CPP)

include $(shell cocotb-config --makefiles)/Makefile.sim
