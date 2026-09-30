# LCVEX 顶层构建入口。
# 用法：make test（在 lcvex conda 环境中运行全部 P0 检查）

CONDA_ENV ?= lcvex
CONDA_RUN = conda run --no-capture-output -n $(CONDA_ENV)
CXX ?= c++
VERILATOR_JOBS ?= 6  # 本地 50% 核数（12 核一半），CI 可覆盖为 75%
LSE128_MAX_INSNS ?= 120
TIMER_EL0_MAX_INSNS ?= 260
MAINT_V82_MAX_INSNS ?= 19
MAINT_V82_MMU_MAX_INSNS ?= 30
MAINT_V82_EL0_MAX_INSNS ?= 24
P7_FP_SCALAR_MAX_INSNS ?= 28
P7_FP_SCALAR_EDGE_MAX_INSNS ?= 38
P7_FP_SCALAR_ROUNDING_MAX_INSNS ?= 18
P7_FP_SCALAR_SEQUENCE_MAX_INSNS ?= 388
P7_NEON_INT_MAX_INSNS ?= 31
P7_NEON_FETCH_FAULT_MAX_INSNS ?= 20
P7_NEON_MEM_DELAY_MODE ?= 0
P7_NEON_SIM_BUILD ?= sim_build_p7_2_neon
P7_NEON_FP_MAX_INSNS ?= 48
P7_NEON_FP_MEM_DELAY_MODE ?= 0
P7_NEON_FP_SIM_BUILD ?= sim_build_p7_3_neon_fp
P7_4_FMA_CONVERT_MAX_INSNS ?= 94
P7_4_FMA_CONVERT_EDGE_MAX_INSNS ?= 54
P7_4_FMA_CONVERT_ROUNDING_MAX_INSNS ?= 27
P7_4_FMA_CONVERT_SEQUENCE_MAX_INSNS ?= 142
P7_5_FP16_SQRT_MINMAX_ROUND_MAX_INSNS ?= 102
P7_5_FP16_SQRT_MINMAX_ROUND_EDGE_MAX_INSNS ?= 59
P7_5_FP16_SQRT_MINMAX_ROUND_ROUNDING_MAX_INSNS ?= 40
P7_5_FP16_SQRT_MINMAX_ROUND_SEQUENCE_MAX_INSNS ?= 66
P7_5_FP16_SQRT_MINMAX_ROUND_SIM_BUILD ?= sim_build_p7_5_fp16
P7_4_FMA_CONVERT_SIM_BUILD ?= sim_build_p7_4_fma_convert
MULDIV_REQUEST_MAX_INSNS ?= 16
MMIO_FABRIC_CPP := sim/mmio/lcvex_mmio_fabric.cc
LOCKSTEP_CXX := $(MMIO_FABRIC_CPP) sim/difftest/lockstep_coordinator.cc
RESET_PC_KERNEL := 64\'d1073741824   # 0x40000000（QEMU bootloader 入口，P6）

.PHONY: all toolcheck compile sim-sv sim-sv-timer-realtime sim-sv-gic-spi sim-sv-catapult-axi-bridge sim-sv-catapult-axi-read-path sim-sv-axi4-avalon sim-sv-catapult-coh-tail sim-sv-catapult-coh-tail-stress b25-flash-path-test b25-linux-boot-test sim-cocotb sim-cocotb-core \
	sim-cocotb-regfile sim-cocotb-backpressure sim-cocotb-mmio \
	sim-sv-fetch-fifo sim-sv-fetch-fifo-cache sim-sv-fetch-fifo-iabt sim-cocotb-fetch-fifo test-f1a cocotb-f1a f1a-fetch-fifo \
	sim-sv-backpressure sim-sv-memif sim-sv-irq-young-squash sim-sv-core-postindex sim-sv-core-umull-reg-offset sim-sv-core-mmu-ldrb-scan sim-sv-core-mmu-ttbr1-ldrb-scan sim-sv-core-mmu-ttbr1-ldrb-evict sim-sv-core-mmu-catapult-coh-ldrb-scan \
	sim-sv-irq-atomic-overlap \
	sim-sv-core-syskill sim-cocotb-core-syskill \
	sim-sv-fp-exec-directed sim-sv-fp-scalar sim-sv-fp-scalar-r18 \
	sim-sv-fp-scalar-r20-route sim-sv-fp-scalar-r20-pack \
	sim-sv-fp-scalar-r21-iter-round sim-sv-fp-scalar-r21-fma-cut \
	sim-cocotb-fp-scalar sim-sv-muldiv-req sim-cocotb-muldiv-req \
	sim-sv-l1d sim-sv-l1i sim-sv-l2 sim-sv-mmu sim-sv-pl061 sim-sv-mmio sim-sv-crc \
	lockstep-build-delay1 lockstep-build-delay2 \
	lockstep-build-f1a lockstep-build-f1a-cache lockstep-build-f1a-delay2 \
	lockstep-build-l1d lockstep-build-l1i lockstep-build-l1di \
	lockstep-build-l2 lockstep-build-l1dl2 \
	lockstep-build-l1dl2-delay2 \
	difftest-qemu difftest-rtl difftest difftest-random \
	difftest-random-big difftest-hazard \
	lockstep-build lockstep lockstep-q5 lockstep-step p4b p4c p5a \
		 m2-4b p6-lse p6-lse128 p6-wfi p6-timer-el0 p6-maint-v82 p6-irq-atomic-overlap p6-stxr-irq-mon-we difftest-muldiv-request p7-1-fp-scalar p7-1-fp-scalar-edge p7-1-fp-scalar-rounding p7-1-fp-scalar-sequence p7-2-neon-int p7-2-neon-fetch-fault p7-2-neon-fetch-fault-semantic p7-2-neon-fetch-fault-semantic-selftest p7-3-neon-fp sim-sv-p7-2-neon sim-sv-p7-2-neon-fault-bfm sim-sv-p7-3-neon-fp sim-cocotb-p7-2-neon sim-cocotb-p7-3-neon-fp p7-4-fma-convert p7-4-fma-convert-edge p7-4-fma-convert-rounding p7-4-fma-convert-sequence sim-sv-p7-4-fma-convert sim-cocotb-p7-4-fma-convert gate-d coverage q6 test test-plan test-parallel microbench \
	microbench-build microbench-one perf perf-build perf-run perf-full checkpoint-dut-smoke checkpoint-timer-smoke \
 checkpoint-gic-smoke checkpoint-sys-smoke checkpoint-sys-v3-smoke checkpoint-sctlr-mask-smoke checkpoint-mmio-smoke checkpoint-manifest-smoke checkpoint-resume-manifest-smoke \
	 trace-manifest-smoke trace-slice-help fail-fp-smoke sim-sv-l1d-wb \
 cache-perf-elab cache-perf-elab-off cache-perf-elab-on cache-perf-smoke \
 f1a-d2-event-probe-selftest f1a-control-flow-fence-smoke \
	 qemu-sysreg-inventory dtb-smoke test-registry-check test-list b25-axi-bridge-test b25-bram-init-test b25-bringup-smoke b25-board-runner-check b25-microbench-test clean commit-digest-test
commit-digest-test:
	@mkdir -p build
	$(CXX) -std=c++17 -Wall -Wextra -Werror -I sim/microbench \
		sim/microbench/commit_digest_test.cc -o build/commit_digest_test
	./build/commit_digest_test

all: test

toolcheck:
	./scripts/toolcheck.sh

test-plan:
	@bash scripts/test_planner.sh

test-registry-check:
	python3 scripts/test_registry.py --check --check-consistency

test-list:
	python3 scripts/test_registry.py list $(ARGS)

b25-axi-bridge-test:
	VERILATOR_JOBS=1 bash fpga/catapult_a10/tools/run_axi_bridge_test.sh

b25-bram-init-test:
	VERILATOR_JOBS=1 bash fpga/catapult_a10/tools/run_bram_init25_test.sh

b25-bringup-smoke:
	VERILATOR_JOBS=1 bash fpga/catapult_a10/tools/run_soc_smoke.sh

b25-board-runner-check:
	bash -n fpga/catapult_a10/tools/board_runner/run_board_once.sh
	python3 -m py_compile fpga/catapult_a10/tools/board_runner/direct_terminal.py \
		fpga/catapult_a10/tools/board_runner/seal_manifest.py \
		fpga/catapult_a10/tools/board_runner/validate_contract.py \
		fpga/catapult_a10/tools/test_board_runner.py
	python3 fpga/catapult_a10/tools/test_board_runner.py
	python3 fpga/catapult_a10/tools/board_runner/direct_terminal.py \
		--contract fpga/catapult_a10/tools/board_runner/contract-example.json \
		--task-id T-20990101-001 --print-command

b25-microbench-test:
	bash fpga/catapult_a10/tools/run_microbench_tests.sh

test-parallel:
	bash sim/difftest/run_p5a_hardening.sh --parallel

# Performance-runner configuration.  These are also used by
# scripts/run_perf_matrix.py. F1a is default-on; set
# PERF_FETCH_FIFO_ENABLE=0 to explicitly force the F0 path.
PERF_RUNNER_DIR ?= build/microbench_runner
PERF_I_L1 ?= 0
PERF_D_L1 ?= 0
PERF_L2 ?= 0
PERF_MEM_DELAY_MODE ?= 0
PERF_FETCH_FIFO_ENABLE ?= 1

microbench-build-config:
	@test -n "$(PERF_RUNNER_DIR)" || { echo "PERF_RUNNER_DIR is empty" >&2; exit 2; }
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -Mdir $(PERF_RUNNER_DIR) \
		-o microbench_runner --public-flat-rw \
		-GI_L1_ENABLE=$(PERF_I_L1) -GD_L1_ENABLE=$(PERF_D_L1) \
		-GL2_ENABLE=$(PERF_L2) -GMEM_DELAY_MODE=$(PERF_MEM_DELAY_MODE) \
		-GFETCH_FIFO_ENABLE=$(PERF_FETCH_FIFO_ENABLE) \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		$(MMIO_FABRIC_CPP) sim/microbench/microbench_runner.cc

microbench-build:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -Mdir build/microbench_runner \
		-o microbench_runner --public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		$(MMIO_FABRIC_CPP) sim/microbench/microbench_runner.cc

microbench: microbench-build
	bash scripts/build-microbench.sh
	./build/microbench_runner/microbench_runner \
		--image build/microbench/mb_all.bin --name mb_all

microbench-one: microbench-build
	./build/microbench_runner/microbench_runner \
		--image build/microbench/mb_all.bin --name mb_all

# T-007：显式验证可选 cache 的 SoC testbench 在 cache-off/on 两种参数下
# 都能从干净命令完成 Verilator lint/elaboration。两条命令分别传入完整
# 参数，避免复用任何带有旧 generate 配置的仿真目录。
cache-perf-elab-off:
	$(CONDA_RUN) verilator --lint-only --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		--top-module lcvex_soc_tb -GI_L1_ENABLE=0 -GD_L1_ENABLE=0 -GL2_ENABLE=0 \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv

cache-perf-elab-on:
	$(CONDA_RUN) verilator --lint-only --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		--top-module lcvex_soc_tb -GI_L1_ENABLE=1 -GD_L1_ENABLE=1 -GL2_ENABLE=1 \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv

cache-perf-elab: cache-perf-elab-off cache-perf-elab-on
	@echo "PASS: lcvex_soc_tb cache-off (0/0/0) 与 cache-on (1/1/1) lint/elaboration"

# T-007：小规模 cache-on/off 观测 smoke。该目标复用现有 v2 runner 和
# workload，只检查只读 cache event 的资格化语义：off 全零，on 的 I-L1、
# D-L1、L2 均有 hit/refill/downstream 事件。每个 runner 使用独立目录。
CACHE_PERF_SMOKE_DIR ?= build/cache_perf_smoke
cache-perf-smoke: cache-perf-elab
	mkdir -p $(CACHE_PERF_SMOKE_DIR)
	$(MAKE) PERF_NAME=mem_ldst PERF_CFLAGS="-O2 -DLDS_SIZE=4096 -DLDS_ITERS=64 -DLDS_PAIR_ITERS=32" perf-build
	$(MAKE) VERILATOR_JOBS=1 PERF_RUNNER_DIR=$(CACHE_PERF_SMOKE_DIR)/runner_off \
		PERF_I_L1=0 PERF_D_L1=0 PERF_L2=0 PERF_MEM_DELAY_MODE=0 \
		PERF_FETCH_FIFO_ENABLE=0 microbench-build-config
	$(MAKE) VERILATOR_JOBS=1 PERF_RUNNER_DIR=$(CACHE_PERF_SMOKE_DIR)/runner_on \
		PERF_I_L1=1 PERF_D_L1=1 PERF_L2=1 PERF_MEM_DELAY_MODE=0 \
		PERF_FETCH_FIFO_ENABLE=0 microbench-build-config
	$(CONDA_RUN) python3 sim/microbench/perf_runner.py \
		--runner $(CACHE_PERF_SMOKE_DIR)/runner_off/microbench_runner \
		--image build/microbench/perf_mem_ldst.bin --name mem_ldst \
		--max-cycles 2000000 --param CACHE_CONFIG=off \
		--out $(CACHE_PERF_SMOKE_DIR)/off.json
	$(CONDA_RUN) python3 sim/microbench/perf_runner.py \
		--runner $(CACHE_PERF_SMOKE_DIR)/runner_on/microbench_runner \
		--image build/microbench/perf_mem_ldst.bin --name mem_ldst \
		--max-cycles 2000000 --param CACHE_CONFIG=on \
		--out $(CACHE_PERF_SMOKE_DIR)/on.json
	$(CONDA_RUN) python3 -c 'import json; off=json.load(open("$(CACHE_PERF_SMOKE_DIR)/off.json")); on=json.load(open("$(CACHE_PERF_SMOKE_DIR)/on.json")); assert off["status"] == "pass" and on["status"] == "pass"; assert all(value == 0 for cache in off["cache"].values() for value in cache.values()); required=(("il1","hit"),("dl1","read_hit"),("l2","read_hit")); assert all(on["cache"][name][key] > 0 and on["cache"][name]["refill_beat"] > 0 and on["cache"][name]["downstream"] > 0 for name,key in required); print("PASS: cache perf off 全零；on I-L1/D-L1/L2 hit/refill/downstream 均非零")'

# ---- perf workload 独立构建/运行（P-line P-INFRA）----
PERF_NAME ?= $(PERF_ONLY)
PERF_PARAMS ?=
PERF_PARAM ?=
PERF_MAX_CYCLES ?= 5000000
PERF_RUNNER ?= ./$(PERF_RUNNER_DIR)/microbench_runner
# PERF_CFLAGS 会传给 build-microbench.sh，可用于 -D<workload宏>=<值>
# 覆盖单个 workload 的迭代/规模参数（例如 -DPERF_ALU_ITERATIONS=20000）。
PERF_CFLAGS ?= -O2
PERF_BASE := $(patsubst t_%,%,$(PERF_NAME))
PERF_BASE := $(patsubst %.c,%,$(PERF_BASE))

perf-build:
	@test -n "$(PERF_NAME)" || { echo "需要 PERF_NAME=<name>（例如 PERF_NAME=smoke）" >&2; exit 2; }
	PERF_ONLY="$(PERF_BASE)" PERF_CFLAGS="$(PERF_CFLAGS)" bash scripts/build-microbench.sh \
		"$(CURDIR)/build/microbench/perf_$(PERF_BASE).bin"

perf-run:
	@test -n "$(PERF_NAME)" || { echo "需要 PERF_NAME=<name>（例如 PERF_NAME=smoke）" >&2; exit 2; }
	python3 sim/microbench/perf_runner.py \
		--runner "$(PERF_RUNNER)" \
		--image "build/microbench/perf_$(PERF_BASE).bin" \
		--name "$(PERF_BASE)" \
		--max-cycles "$(PERF_MAX_CYCLES)" \
		$(if $(PERF_PARAMS),--params '$(PERF_PARAMS)') \
		$(if $(PERF_PARAM),--param '$(PERF_PARAM)')

# perf 只构建镜像并调用现有/已构建 runner；如 runner 不存在，先执行：
#   make VERILATOR_JOBS=1 microbench-build
perf: perf-build perf-run

# perf-full 额外包含 Verilator runner 构建；始终使用 VERILATOR_JOBS=1，
# 外层仍需按项目规范加 cgroup MemoryMax<16GiB / MemorySwapMax=0。
perf-full:
	$(MAKE) VERILATOR_JOBS=1 PERF_RUNNER_DIR=$(PERF_RUNNER_DIR) microbench-build-config
	$(MAKE) perf-build
	$(MAKE) perf-run

# T-009：只校验有界 F1a event probe 的 schema/上限和默认关闭口径；不启动仿真。
f1a-d2-event-probe-selftest:
	python3 sim/microbench/perf_runner.py --probe-self-test

# L3：验证 Verilator 显式架构状态注入会冲刷流水线，并从恢复点继续产生
# 与连续运行完全相同的提交包；不涉及 QEMU/ Linux 长跑。
checkpoint-dut-smoke: lockstep-build
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_psci_program("build/difftest/hard_psci.bin")'
	./build/verilator_lockstep/lockstep_coordinator \
		--selftest-restore build/difftest/hard_psci.bin \
		--base 0x44000000 --split 10 --count 10

# P6：Generic Timer sidecar 恢复 smoke。checkpoint 选在第一条 MRS
# CNTPCT 之后，下一条直接读取 CNTVCT，专门检查 QEMU 虚拟计数到 RTL
# 已提交计数（减一）的边界转换；中间 RAM backend 只存在于临时目录。
checkpoint-timer-smoke: lockstep-build
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_timer_program("build/difftest/hard_timer.bin")'
	bash sim/difftest/checkpoint_timer_smoke.sh

# P6：GICv2 pending/enable/priority sidecar 的 QEMU/DUT 联合恢复 smoke。
checkpoint-gic-smoke: lockstep-build
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_gic_program("build/difftest/hard_gic.bin")'
	bash sim/difftest/checkpoint_gic_smoke.sh

# P6：sys sidecar v2/v3 兼容（ZCR/SMCR/CSSELR）QEMU/DUT 联合恢复 smoke。
checkpoint-sys-smoke: lockstep-build
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_sve_probe_program("build/difftest/hard_sve_probe.bin")'
	bash sim/difftest/checkpoint_sys_smoke.sh

# P6：LCVXSYS3 补齐 PMUSERENR_EL0/TCR2_EL1/exclusive monitor 的联合恢复。
checkpoint-sys-v3-smoke: lockstep-build
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_checkpoint_sys_v3_program("build/difftest/hard_checkpoint_sys_v3.bin")'
	bash sim/difftest/checkpoint_sys_v3_smoke.sh

# P6：故意向仅供 DUT 恢复使用的 SCTLR sys sidecar 注入四个未实现的
# PAuth enable 位。QEMU 始终从未篡改的 vmstate 恢复，随后 MRS SCTLR 与一条
# 普通提交必须继续严格锁步，防止 restore 写掩码回归。
checkpoint-sctlr-mask-smoke:
	mkdir -p build/difftest build/tmp
	$(MAKE) lockstep-build
	$(MAKE) -C qemu/plugins
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_sctlr_pauth_program("build/difftest/hard_sctlr_pauth.bin")'
	bash sim/difftest/checkpoint_sctlr_mask_smoke.sh

# P6：C++ MMIO fabric（PL031）状态也必须随差分 checkpoint 保存和恢复；
# 该 smoke 专门检查 LR 写后从 checkpoint 恢复，不能把 fabric reset 当恢复。
checkpoint-mmio-smoke: lockstep-build
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_pl031_program("build/difftest/hard_pl031.bin")'
	bash sim/difftest/checkpoint_mmio_smoke.sh

# P6：checkpoint 输入环境、TSV 链和压缩 artifact 的 SHA256 反向校验。
checkpoint-manifest-smoke:
	$(CONDA_RUN) python3 sim/difftest/checkpoint_manifest_smoke.py

checkpoint-resume-manifest-smoke:
	$(CONDA_RUN) python3 sim/difftest/checkpoint_resume_manifest_smoke.py

# P1：压缩/明文 trace manifest、全局 seq 切片和 parent 内容绑定的低资源 smoke。
trace-manifest-smoke:
	$(CONDA_RUN) python3 scripts/trace_manifest_smoke.py

trace-slice-help:
	$(CONDA_RUN) python3 scripts/trace_slice.py --help >/dev/null

# P6：批量取证固定 QEMU 的系统寄存器编码、读值和异常结果。
qemu-sysreg-inventory:
	$(CONDA_RUN) python3 scripts/qemu_sysreg_inventory.py

# P6：生成并校验确定性的 QEMU virt/GICv2 compact DTB，记录 SHA256。
dtb-smoke:
	$(CONDA_RUN) python3 scripts/validate_virt_dtb.py \
		--qemu ../qemu/build/qemu-system-aarch64 \
		--output build/difftest/virt-gic2.dtb \
		--summary build/difftest/virt-gic2.json

compile:
	$(CONDA_RUN) verilator --lint-only -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL --top-module lcvex_core -f rtl/filelist.f

sim-sv:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_core_tb \
		-Mdir obj_dir -o lcvex_core_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_core_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir/lcvex_core_tb

# Focus repeated scalar post-index base/length writeback used by the Linux loader.
sim-sv-core-postindex:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		-GD_L1_ENABLE=1 --top-module lcvex_core_tb \
		-Mdir obj_dir_postindex -o lcvex_core_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_core_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_postindex/lcvex_core_tb +POSTINDEX_LOOP

sim-sv-core-umull-reg-offset:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		-GD_L1_ENABLE=1 --top-module lcvex_core_tb \
		-Mdir obj_dir_umull_regoffset -o lcvex_core_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_core_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_umull_regoffset/lcvex_core_tb +UMULL_REGOFFSET_LDR

sim-sv-core-mmu-ldrb-scan:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		-GD_L1_ENABLE=1 --top-module lcvex_core_tb \
		-Mdir obj_dir_mmu_ldrb_scan -o lcvex_core_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_core_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_mmu_ldrb_scan/lcvex_core_tb +MMU_LDRB_SCAN

sim-sv-core-mmu-ttbr1-ldrb-scan:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		-GD_L1_ENABLE=1 -GL2_ENABLE=1 --top-module lcvex_core_tb \
		-Mdir obj_dir_mmu_ttbr1_ldrb_scan -o lcvex_core_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_core_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_mmu_ttbr1_ldrb_scan/lcvex_core_tb +MMU_TTBR1_LDRB_SCAN

sim-sv-core-mmu-ttbr1-ldrb-evict:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		-GD_L1_ENABLE=1 -GL2_ENABLE=1 --top-module lcvex_core_tb \
		-Mdir obj_dir_mmu_ttbr1_ldrb_evict -o lcvex_core_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_core_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_mmu_ttbr1_ldrb_evict/lcvex_core_tb +MMU_TTBR1_LDRB_EVICT

sim-sv-core-mmu-catapult-coh-ldrb-scan:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		-GCATAPULT_COH_ENABLE=1 --top-module lcvex_core_tb \
		-Mdir obj_dir_mmu_catapult_coh -o lcvex_core_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_core_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_mmu_catapult_coh/lcvex_core_tb +MMU_TTBR1_LDRB_EVICT
	./obj_dir_mmu_catapult_coh/lcvex_core_tb +MMU_TTBR1_LDRB_UART_SCAN

# Exercise the physical board timer source and its CNTFRQ_EL0 contract while
# retaining the default instruction-count mode for ordinary QEMU lockstep.
sim-sv-timer-realtime:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		-GTIMER_REALTIME=1 -GCNTFRQ_HZ=25000000 \
		--top-module lcvex_core_tb \
		-Mdir obj_dir_timer_realtime -o lcvex_core_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_core_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_timer_realtime/lcvex_core_tb

LINUX_PLATFORM_TEST_OUT ?= build/agents/T-20260928-002/linux-platform-tests
LINUX_BOOT_PLUSARGS ?=
LINUX_BOOT_FLASH_MEMH ?=

sim-sv-gic-spi:
	mkdir -p $(LINUX_PLATFORM_TEST_OUT)/gic
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_gic_spi_tb -Mdir $(LINUX_PLATFORM_TEST_OUT)/gic/obj_dir -o lcvex_gic_spi_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_gic.sv tb/sv/lcvex_gic_spi_tb.sv
	$(LINUX_PLATFORM_TEST_OUT)/gic/obj_dir/lcvex_gic_spi_tb

sim-sv-catapult-axi-bridge:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -j $(VERILATOR_JOBS) \
		--top-module lcvex_catapult_soc_axi_bridge_tb -Mdir obj_dir_catapult_soc_axi -o lcvex_catapult_soc_axi_bridge_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_axi4_pkg.sv rtl/lcvex_catapult_soc_axi.sv \
		tb/sv/lcvex_catapult_soc_axi_bridge_tb.sv
	./obj_dir_catapult_soc_axi/lcvex_catapult_soc_axi_bridge_tb

sim-sv-catapult-axi-read-path:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -j $(VERILATOR_JOBS) \
		--top-module lcvex_catapult_soc_axi_read_path_tb \
		-Mdir obj_dir_catapult_axi_read_path -o lcvex_catapult_soc_axi_read_path_tb \
		-f rtl/filelist.f tb/sv/lcvex_catapult_soc_axi_read_path_tb.sv
	./obj_dir_catapult_axi_read_path/lcvex_catapult_soc_axi_read_path_tb

sim-sv-catapult-coh-tail:
	mkdir -p build/agents/T-20260928-002/coh-tail/obj_dir
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -j $(VERILATOR_JOBS) \
		--top-module lcvex_catapult_soc_coh_tail_tb \
		-Mdir build/agents/T-20260928-002/coh-tail/obj_dir \
		-o lcvex_catapult_soc_coh_tail_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_mem_arb.sv rtl/lcvex_l1_i.sv \
		rtl/lcvex_cache_data_ram.sv rtl/lcvex_l1_d_wb.sv rtl/lcvex_l2_wb.sv \
		rtl/lcvex_catapult_soc_coh.sv tb/sv/lcvex_catapult_soc_coh_tail_tb.sv
	build/agents/T-20260928-002/coh-tail/obj_dir/lcvex_catapult_soc_coh_tail_tb

sim-sv-catapult-coh-tail-stress:
	mkdir -p build/agents/T-20260928-002/coh-tail-stress/obj_dir
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -j $(VERILATOR_JOBS) \
		-GL2_SETS=64 -GL2_WAYS=1 --top-module lcvex_catapult_soc_coh_tail_tb \
		-Mdir build/agents/T-20260928-002/coh-tail-stress/obj_dir \
		-o lcvex_catapult_soc_coh_tail_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_mem_arb.sv rtl/lcvex_l1_i.sv \
		rtl/lcvex_cache_data_ram.sv rtl/lcvex_l1_d_wb.sv rtl/lcvex_l2_wb.sv \
		rtl/lcvex_catapult_soc_coh.sv tb/sv/lcvex_catapult_soc_coh_tail_tb.sv
	build/agents/T-20260928-002/coh-tail-stress/obj_dir/lcvex_catapult_soc_coh_tail_tb

sim-sv-axi4-avalon:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_axi4_avalon_tb -Mdir obj_dir_axi4_avalon -o lcvex_axi4_avalon_tb \
		-f rtl/filelist.f tb/sv/lcvex_axi4_avalon_bfm.sv tb/sv/lcvex_axi4_avalon_tb.sv
	./obj_dir_axi4_avalon/lcvex_axi4_avalon_tb

b25-flash-path-test:
	mkdir -p $(LINUX_PLATFORM_TEST_OUT)/flash
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -Wno-DECLFILENAME -j $(VERILATOR_JOBS) \
		--top-module lcvex_flash_path_tb -Mdir $(LINUX_PLATFORM_TEST_OUT)/flash/obj_dir -o lcvex_flash_path_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_catapult_soc_pkg.sv rtl/lcvex_mem_router.sv \
		rtl/lcvex_gic.sv rtl/lcvex_catapult_soc_top.sv tb/sv/lcvex_flash_path_tb.sv
	$(LINUX_PLATFORM_TEST_OUT)/flash/obj_dir/lcvex_flash_path_tb

b25-linux-boot-test:
	mkdir -p $(LINUX_PLATFORM_TEST_OUT)
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -Wno-DECLFILENAME -j $(VERILATOR_JOBS) \
		--top-module lcvex_catapult_linux_boot_tb -Mdir $(LINUX_PLATFORM_TEST_OUT)/obj_dir -o lcvex_catapult_linux_boot_tb \
		-f fpga/catapult_a10/tb/filelist_soc.f \
		fpga/catapult_a10/tb/sv/lcvex_catapult_linux_boot_tb.sv
	set -o pipefail; stdbuf -oL $(LINUX_PLATFORM_TEST_OUT)/obj_dir/lcvex_catapult_linux_boot_tb $(if $(LINUX_BOOT_FLASH_MEMH),+FLASH_WORDS_MEMH=$(LINUX_BOOT_FLASH_MEMH),) $(LINUX_BOOT_PLUSARGS) 2>&1 | tee $(LINUX_PLATFORM_TEST_OUT)/simulation.log

# T-016：在完整 core smoke elaboration 上追加 system-commit/FP owner 定向探针。
sim-sv-core-syskill: sim-sv
	./obj_dir/lcvex_core_tb +T016_SYSKILL

# T-051：ordinary IRQ 直接注入边界。四种 FIFO/MEM delay 配置串行编译，
# 每个二进制内依次覆盖 ID/EX、未接受 store 和 held FP response；所有
# Verilator 进程由 cgroup 限制并固定单线程，避免与其它重型任务争用资源。
sim-sv-irq-young-squash:
	@set -eu; \
	for spec in fifo_off_delay0:0:0 fifo_on_delay0:1:0 fifo_off_delay2:0:2 fifo_on_delay2:1:2; do \
		name=$${spec%%:*}; rest=$${spec#*:}; fifo=$${rest%%:*}; delay=$${rest##*:}; \
		build="obj_dir_irq_young_$${name}"; \
		systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
			$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
			-j 1 --top-module lcvex_irq_young_squash_tb -Mdir "$$build" \
			-o lcvex_irq_young_squash_tb -GFETCH_FIFO_ENABLE=$$fifo -GMEM_DELAY_MODE=$$delay \
			-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_irq_young_squash_tb.sv \
			sim/mmio/lcvex_mmio_fabric.cc; \
		"./$$build/lcvex_irq_young_squash_tb"; \
	done

# T-054：CASP/STXR/DC ZVA 与 ordinary IRQ 的真实流水 overlap。只驱动
# gic_irq，禁止 force commit_fire/stage metadata；FIFO off/on × delay 0/2
# 四配置串行编译和运行，所有 Verilator 进程限于 16 GiB cgroup、-j 1。
sim-sv-irq-atomic-overlap:
	@set -eu; \
	for spec in fifo_off_delay0:0:0 fifo_on_delay0:1:0 fifo_off_delay2:0:2 fifo_on_delay2:1:2; do \
		name=$${spec%%:*}; rest=$${spec#*:}; fifo=$${rest%%:*}; delay=$${rest##*:}; \
		build="obj_dir_irq_atomic_$${name}"; \
		systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
			$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
			-j 1 --top-module lcvex_irq_atomic_overlap_tb -Mdir "$$build" \
			-o lcvex_irq_atomic_overlap_tb -GFETCH_FIFO_ENABLE=$$fifo -GMEM_DELAY_MODE=$$delay \
			-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_irq_atomic_overlap_tb.sv \
			sim/mmio/lcvex_mmio_fabric.cc; \
		"./$$build/lcvex_irq_atomic_overlap_tb"; \
	done

sim-sv-fp-scalar:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_fp_scalar_tb -Mdir obj_dir_fp_scalar \
		-o lcvex_fp_scalar_tb rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv \
		tb/sv/lcvex_fp_scalar_tb.sv
	./obj_dir_fp_scalar/lcvex_fp_scalar_tb

# T-017：R18 普通 FP prescan/classify/normalize 寄存边界。
sim-sv-fp-scalar-r18:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-j $(VERILATOR_JOBS) --top-module lcvex_fp_scalar_r18_tb \
		-Mdir obj_dir_fp_scalar_r18 -o lcvex_fp_scalar_r18_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv tb/sv/lcvex_fp_scalar_r18_tb.sv
	./obj_dir_fp_scalar_r18/lcvex_fp_scalar_r18_tb

# T-20260906-029：R20 非 half IT_ARITH 闭合 route 与 default 行为。
sim-sv-fp-scalar-r20-route:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-j $(VERILATOR_JOBS) --top-module lcvex_fp_scalar_r20_route_tb \
		-Mdir obj_dir_fp_scalar_r20_route -o lcvex_fp_scalar_r20_route_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv tb/sv/lcvex_fp_scalar_r20_route_tb.sv
	./obj_dir_fp_scalar_r20_route/lcvex_fp_scalar_r20_route_tb

# T-20260906-030：R20 final pack-result 寄存边界与 exactly-once 行为。
sim-sv-fp-scalar-r20-pack:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-j $(VERILATOR_JOBS) --top-module lcvex_fp_scalar_r20_pack_tb \
		-Mdir obj_dir_fp_scalar_r20_pack -o lcvex_fp_scalar_r20_pack_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv tb/sv/lcvex_fp_scalar_r20_pack_tb.sv
	./obj_dir_fp_scalar_r20_pack/lcvex_fp_scalar_r20_pack_tb

# T-20260906-033：R21 iterative round-pack 使用已寄存 leading metadata。
sim-sv-fp-scalar-r21-iter-round:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-j $(VERILATOR_JOBS) --top-module lcvex_fp_scalar_r21_iter_round_tb \
		-Mdir obj_dir_fp_scalar_r21_iter_round -o lcvex_fp_scalar_r21_iter_round_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv tb/sv/lcvex_fp_scalar_r21_iter_round_tb.sv
	./obj_dir_fp_scalar_r21_iter_round/lcvex_fp_scalar_r21_iter_round_tb

# T-20260906-034：R21 FMA alignment 与 wide add/sub 寄存切分。
sim-sv-fp-scalar-r21-fma-cut:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-j $(VERILATOR_JOBS) --top-module lcvex_fp_scalar_r21_fma_cut_tb \
		-Mdir obj_dir_fp_scalar_r21_fma_cut -o lcvex_fp_scalar_r21_fma_cut_tb \
		rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv tb/sv/lcvex_fp_scalar_r21_fma_cut_tb.sv
	./obj_dir_fp_scalar_r21_fma_cut/lcvex_fp_scalar_r21_fma_cut_tb

# T-20260905-002/003：共享 FP transaction/iterative engine 的定向状态、
# latency、pause/kill/reset/valid-drop 与 held-response 自检入口。
sim-sv-fp-exec-directed:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-j $(VERILATOR_JOBS) --top-module lcvex_fp_exec_tb -Mdir obj_dir_fp_exec_directed \
		-o lcvex_fp_exec_tb rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv \
		rtl/lcvex_neon_fp.sv tb/sv/lcvex_fp_exec_tb.sv
	./obj_dir_fp_exec_directed/lcvex_fp_exec_tb

sim-cocotb-fp-scalar:
	$(CONDA_RUN) make -C sim/cocotb -f Makefile.fp_scalar \
		SIM=verilator TOPLEVEL=lcvex_soc_tb \
		COCOTB_TEST_MODULES=test_p7_fp_scalar \
		SIM_BUILD=sim_build_p7_1_fp_scalar

# T-20260905-004：standalone mul/div request capture/launch 边界；SV 与
# Cocotb 共用一个 wrapper，SV 通过参数启用自检，Cocotb 默认由 Python 驱动。
sim-sv-muldiv-req:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-j $(VERILATOR_JOBS) --top-module lcvex_muldiv_req_tb -Mdir obj_dir_muldiv_req \
		-o lcvex_muldiv_req_tb -GRUN_SV_SELFTEST=1 \
		rtl/lcvex_muldiv.sv tb/sv/lcvex_muldiv_req_tb.sv
	./obj_dir_muldiv_req/lcvex_muldiv_req_tb

sim-cocotb-muldiv-req:
	$(CONDA_RUN) make -C sim/cocotb \
		SIM=verilator \
		TOPLEVEL=lcvex_muldiv_req_tb \
		COCOTB_TEST_MODULES=test_muldiv_req \
		SIM_BUILD=sim_build_muldiv_req \
		VERILOG_SOURCES="$(abspath rtl/lcvex_muldiv.sv) $(abspath tb/sv/lcvex_muldiv_req_tb.sv)" \
		EXTRA_ARGS="--timing --assert"

sim-sv-backpressure:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_commit_backpressure_tb -Mdir obj_dir_bp \
		-o lcvex_commit_backpressure_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		tb/sv/lcvex_commit_backpressure_tb.sv $(MMIO_FABRIC_CPP)
	./obj_dir_bp/lcvex_commit_backpressure_tb

# F1a：独立打开 2-entry fetch FIFO 的定向 SV 入口。默认测试槽由集成者
# 释放后再运行；feature-off 的旧 sim-sv/sim-sv-backpressure 不受影响。
sim-sv-fetch-fifo:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_fetch_fifo_tb -Mdir obj_dir_fetch_fifo \
		-o lcvex_fetch_fifo_tb \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_fetch_fifo_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_fetch_fifo/lcvex_fetch_fifo_tb

# T-010：同一控制流 fence 入口的 cache-on/delay2 变体；仍只观察
# commit/FIFO/flush 边界，不引入新的架构或缓存语义。
sim-sv-fetch-fifo-cache:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_fetch_fifo_tb -Mdir obj_dir_fetch_fifo_cache \
		-o lcvex_fetch_fifo_tb \
		-GI_L1_ENABLE=1 -GD_L1_ENABLE=1 -GL2_ENABLE=1 -GMEM_DELAY_MODE=2 \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv tb/sv/lcvex_fetch_fifo_tb.sv \
		$(MMIO_FABRIC_CPP)
	./obj_dir_fetch_fifo_cache/lcvex_fetch_fifo_tb

# T-010 correction：branch-target IABT 是 fence 的负控。异常 FIFO entry
# 必须可进入 decode/commit，不能被 `!d.exc` 缺失的 fence 条件卡死。
sim-sv-fetch-fifo-iabt: sim-sv-fetch-fifo
	./obj_dir_fetch_fifo/lcvex_fetch_fifo_tb +T010_IABT

test-f1a: sim-sv-fetch-fifo

f1a-control-flow-fence-smoke: sim-sv-fetch-fifo sim-sv-fetch-fifo-iabt sim-sv-fetch-fifo-cache

sim-sv-memif:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_mem_if_tb -Mdir obj_dir_memif \
		-o lcvex_mem_if_tb \
		-f rtl/filelist.f tb/sv/lcvex_mem_if_tb.sv
	./obj_dir_memif/lcvex_mem_if_tb

sim-sv-pl011:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_pl011_tb -Mdir obj_dir_pl011 \
		-o lcvex_pl011_tb \
		-f rtl/filelist.f tb/sv/lcvex_pl011_tb.sv
	./obj_dir_pl011/lcvex_pl011_tb

sim-sv-pl061:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_pl061_tb -Mdir obj_dir_pl061 \
		-o lcvex_pl061_tb \
		-f rtl/filelist.f tb/sv/lcvex_pl061_tb.sv
	./obj_dir_pl061/lcvex_pl061_tb

sim-sv-mmio:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_mmio_fabric_tb -Mdir obj_dir_mmio \
		-o lcvex_mmio_fabric_tb \
		-f rtl/filelist.f tb/sv/lcvex_mmio_fabric_tb.sv $(MMIO_FABRIC_CPP)
	./obj_dir_mmio/lcvex_mmio_fabric_tb

sim-sv-crc:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_crc_tb -Mdir obj_dir_crc \
		-o lcvex_crc_tb \
		-f rtl/filelist.f tb/sv/lcvex_crc_tb.sv
	./obj_dir_crc/lcvex_crc_tb

sim-sv-l1d:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_l1_d_tb -Mdir obj_dir_l1d \
		-o lcvex_l1_d_tb \
		-f rtl/filelist.f tb/sv/lcvex_l1_d_tb.sv
	./obj_dir_l1d/lcvex_l1_d_tb

sim-sv-l1d-wb:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -Wno-DECLFILENAME -j $(VERILATOR_JOBS) \
		--top-module lcvex_l1_d_wb_tb -Mdir obj_dir_l1d_wb \
		-o lcvex_l1_d_wb_tb rtl/lcvex_pkg.sv rtl/lcvex_cache_data_ram.sv \
		rtl/lcvex_l1_d_wb.sv tb/sv/lcvex_l1_d_wb_bfm.sv \
		tb/sv/lcvex_l1_d_wb_tb.sv
	./obj_dir_l1d_wb/lcvex_l1_d_wb_tb

sim-sv-l1i:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_l1_i_tb -Mdir obj_dir_l1i \
		-o lcvex_l1_i_tb \
		-f rtl/filelist.f tb/sv/lcvex_l1_i_tb.sv
	./obj_dir_l1i/lcvex_l1_i_tb

sim-sv-l2:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_l2_tb -Mdir obj_dir_l2 \
		-o lcvex_l2_tb \
		-f rtl/filelist.f tb/sv/lcvex_l2_tb.sv
	./obj_dir_l2/lcvex_l2_tb

sim-sv-mmu:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_mmu_tb -Mdir obj_dir_mmu \
		-o lcvex_mmu_tb \
		-f rtl/filelist.f tb/sv/lcvex_mmu_tb.sv
	./obj_dir_mmu/lcvex_mmu_tb

sim-cocotb:
	$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_alu COCOTB_TEST_MODULES=test_alu \
		SIM_BUILD=sim_build_alu

sim-cocotb-regfile:
	$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_regfile COCOTB_TEST_MODULES=test_regfile \
		SIM_BUILD=sim_build_regfile

sim-cocotb-backpressure:
	$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_commit_backpressure \
		SIM_BUILD=sim_build_bp

sim-cocotb-mmio:
	$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_mmio_fabric_cocotb_tb COCOTB_TEST_MODULES=test_mmio_fabric \
		SIM_BUILD=sim_build_mmio

sim-cocotb-core:
	$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_lcvex_core \
		SIM_BUILD=sim_build_core

# T-016：独立 Cocotb system-after-FP/RAW owner 检查；held response 由
# companion SV 与 T-012 data-MMU overlap 覆盖。
sim-cocotb-core-syskill:
	$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_core_syskill \
		SIM_BUILD=sim_build_core_syskill

sim-cocotb-fetch-fifo:
	$(CONDA_RUN) make -C sim/cocotb -f Makefile.fetch_fifo \
		SIM=verilator TOPLEVEL=lcvex_soc_tb \
		COCOTB_TEST_MODULES=test_fetch_fifo SIM_BUILD=sim_build_fetch_fifo

cocotb-f1a: sim-cocotb-fetch-fifo

# F1a 锁步入口：脚本负责生成/选择 hard_fetch_* 镜像并串行运行 base、
# I-L1/cache 和 delay2 变体；调用者可覆盖 IMAGE/MAX_INSNS/COORD。
f1a-fetch-fifo:
	bash sim/difftest/run_f1a.sh

difftest-qemu:
	$(MAKE) -C qemu/plugins
	$(CONDA_RUN) python3 sim/difftest/run_qemu.py

difftest-rtl:
	$(MAKE) -C qemu/plugins
	$(CONDA_RUN) python3 sim/difftest/run_qemu.py --trace-only \
		--program p2 --out build/difftest/rtl.trace --limit 40
	QEMU_TRACE=$(abspath build/difftest/rtl.trace) \
		$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_lcvex_core \
		SIM_BUILD=sim_build_core

difftest: difftest-qemu difftest-rtl
	@echo "P1/P2 差分检查全部通过"

SEED ?= 1
LENGTH ?= 2000

difftest-random:
	$(MAKE) -C qemu/plugins
	$(CONDA_RUN) python3 sim/difftest/run_qemu.py --trace-only \
		--program random --seed $(SEED) --length $(LENGTH) \
		--out build/difftest/random_$(SEED).trace
	PROGRAM_BIN=$(abspath build/difftest/random.bin) \
	QEMU_TRACE=$(abspath build/difftest/random_$(SEED).trace) \
	COCOTB_RESULTS_FILE=$(abspath build/difftest/random_$(SEED)_results.xml) \
		$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_lcvex_core \
		SIM_BUILD=sim_build_core

difftest-random-big:
	$(MAKE) difftest-random SEED=1 LENGTH=100000

difftest-random-multi:
	$(MAKE) difftest-random SEED=1 LENGTH=100000
	$(MAKE) difftest-random SEED=2 LENGTH=100000
	$(MAKE) difftest-random SEED=3 LENGTH=100000

difftest-hazard:
	$(MAKE) -C qemu/plugins
	$(CONDA_RUN) python3 sim/difftest/run_qemu.py --trace-only \
		--program hazard --out build/difftest/hazard.trace
	PROGRAM_BIN=$(abspath build/difftest/hazard.bin) \
	QEMU_TRACE=$(abspath build/difftest/hazard.trace) \
	COCOTB_RESULTS_FILE=$(abspath build/difftest/hazard_results.xml) \
		$(CONDA_RUN) make -C sim/cocotb SIM=verilator \
		TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_lcvex_core \
		SIM_BUILD=sim_build_core

lockstep-build:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -Mdir build/verilator_lockstep \
		-o lockstep_coordinator --public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
	$(LOCKSTEP_CXX)

# F1a strict-lockstep coordinator variants.  Each top-level parameter is
# explicit so run_f1a.sh cannot accidentally reuse the feature-off binary.
lockstep-build-f1a:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GFETCH_FIFO_ENABLE=1 -GFETCH_FIFO_DEPTH=2 \
		-GFETCH_EPOCH_W=8 -Mdir build/verilator_lockstep_f1a \
		-o lockstep_coordinator --public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

lockstep-build-f1a-cache:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GFETCH_FIFO_ENABLE=1 -GFETCH_FIFO_DEPTH=2 \
		-GFETCH_EPOCH_W=8 -GI_L1_ENABLE=1 -Mdir build/verilator_lockstep_f1a_cache \
		-o lockstep_coordinator --public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

lockstep-build-f1a-delay2:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GFETCH_FIFO_ENABLE=1 -GFETCH_FIFO_DEPTH=2 \
		-GFETCH_EPOCH_W=8 -GMEM_DELAY_MODE=2 -Mdir build/verilator_lockstep_f1a_delay2 \
		-o lockstep_coordinator --public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# P7-0：只用本地 socket peer 重放 FP_INIT/FP_COMMIT mismatch，验证完整
# fail-fp.json 与首个 raw mismatch 的 fail.txt；不启动 QEMU。
fail-fp-smoke: lockstep-build
	$(CONDA_RUN) python3 sim/difftest/fail_fp_smoke.py \
		--coordinator build/verilator_lockstep/lockstep_coordinator

# P6：内核锁步变体（RESET_PC=0x40000000，QEMU bootloader 入口）
lockstep-build-kernel:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GRESET_PC=$(RESET_PC_KERNEL) \
		-Mdir build/verilator_lockstep_kernel \
		-o lockstep_coordinator --public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# P6：内核锁步无 FP/NEON 变体（lite 线）：QEMU 用
# -cpu max,vfp=off,neon=off,vfp-d32=off，RTL ID 寄存器按 QEMU 语义
# 返回无 FP 值（ID_AA64PFR0.FP/ASIMD=0xf 等），内核走纯标量路径。
lockstep-build-kernel-nofp:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GRESET_PC=$(RESET_PC_KERNEL) \
		-GA64_FP_SIMD=0 \
		-Mdir build/verilator_lockstep_kernel_nofp \
		-o lockstep_coordinator --public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# M1-B：1 周期注入延迟下的锁步构建（验证 request/response 与延迟解耦）
lockstep-build-delay1:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GMEM_DELAY_MODE=1 \
		-Mdir build/verilator_lockstep_d1 -o lockstep_coordinator \
		--public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# M1-B：随机 0..4 周期注入延迟下的锁步构建（LFSR 可复现）
lockstep-build-delay2:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GMEM_DELAY_MODE=2 \
		-Mdir build/verilator_lockstep_d2 -o lockstep_coordinator \
		--public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# M2：数据路径插入 D-L1 写通缓存的锁步构建
lockstep-build-l1d:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GD_L1_ENABLE=1 \
		-Mdir build/verilator_lockstep_l1d -o lockstep_coordinator \
		--public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# M2：取指路径插入 I-L1 的锁步构建
lockstep-build-l1i:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GI_L1_ENABLE=1 \
		-Mdir build/verilator_lockstep_l1i -o lockstep_coordinator \
		--public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# M2：I-L1 + D-L1 同时启用的锁步构建
lockstep-build-l1di:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GI_L1_ENABLE=1 -GD_L1_ENABLE=1 \
		-Mdir build/verilator_lockstep_l1di -o lockstep_coordinator \
		--public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# M2：统一 L2 的锁步构建（I/D-L1 关闭，L2 独立验证）
lockstep-build-l2:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GL2_ENABLE=1 \
		-Mdir build/verilator_lockstep_l2 -o lockstep_coordinator \
		--public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# M2：I-L1 + D-L1 + L2 全缓存锁步构建
lockstep-build-l1dl2:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GI_L1_ENABLE=1 -GD_L1_ENABLE=1 \
		-GL2_ENABLE=1 \
		-Mdir build/verilator_lockstep_l1dl2 -o lockstep_coordinator \
		--public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

# M2-5 Gate D：全缓存 + 随机下级延迟（0..4 周期 LFSR）锁步构建，
# 验证 Cache 在可变下游延迟下的请求/响应握手无丢失/重复。
lockstep-build-l1dl2-delay2:
	$(CONDA_RUN) verilator --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_soc_tb -GI_L1_ENABLE=1 -GD_L1_ENABLE=1 \
		-GL2_ENABLE=1 -GMEM_DELAY_MODE=2 \
		-Mdir build/verilator_lockstep_l1dl2_d2 -o lockstep_coordinator \
		--public-flat-rw \
		-f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
		-CFLAGS "-I/usr/include" \
		-LDFLAGS \"-lz\" \
		$(LOCKSTEP_CXX)

lockstep:
	$(MAKE) -C qemu/plugins
	$(CONDA_RUN) python3 sim/difftest/run_qemu.py --gen-only --program p2
	$(MAKE) lockstep-build
	./sim/difftest/run_lockstep.sh

lockstep-q5:
	$(MAKE) -C qemu/plugins
	$(CONDA_RUN) python3 sim/difftest/run_qemu.py --gen-only --program p2
	$(CONDA_RUN) python3 sim/difftest/run_qemu.py --gen-only --program q5exc
	$(MAKE) lockstep-build
	./sim/difftest/run_lockstep_q5.sh

q6:
	$(MAKE) -C qemu/plugins
	./sim/difftest/run_q6.sh

lockstep-step:
	$(MAKE) -C qemu/plugins
	$(MAKE) lockstep-build
	./sim/difftest/run_lockstep_step.sh

p4b:
	./sim/difftest/run_p4b.sh

p4c:
	./sim/difftest/run_gate_c.sh

p5a:
	./sim/difftest/run_p5a.sh

m2-4b:
	./sim/difftest/run_m2_4b.sh

p6-lse:
	./sim/difftest/run_p6_lse.sh

# T-20260905-004：显式 MUL/UMULH/SMULH/UDIV/SDIV W/X/div0 程序的
# strict-step 锁步入口；仅在 batch candidate 联合门运行。
difftest-muldiv-request: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_muldiv_request_program("build/difftest/hard_muldiv_request.bin")'
	$(MAKE) -C qemu/plugins
	IMAGE=$(CURDIR)/build/difftest/hard_muldiv_request.bin MAX_INSNS=$(MULDIV_REQUEST_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# T-054：真实 CASP/STXR/DC ZVA 与 Generic Timer IRQ overlap；base 与
# MEM_DELAY_MODE=2 strict 矩阵由专用 runner 串行执行。
p6-irq-atomic-overlap:
	systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
		env VERILATOR_JOBS=1 $(MAKE) lockstep-build lockstep-build-delay2
	systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
		env VERILATOR_JOBS=1 ./sim/difftest/run_p6_irq_atomic_overlap.sh

# T-055：STXR same-COMMIT IRQ monitor sidecar；先串行构建两个 coordinator，
# 再在同一 16 GiB cgroup 内运行协议 fixture、定向矩阵和 T-054 回归。
p6-stxr-irq-mon-we:
	$(MAKE) -C qemu/plugins
	systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
		env VERILATOR_JOBS=1 $(MAKE) lockstep-build lockstep-build-delay2
	systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
		env VERILATOR_JOBS=1 ./sim/difftest/run_p6_stxr_irq_mon_we.sh

# P6 LSE128：固定 QEMU/Verilator 单步锁步，分别复现 base 与 I+D+L2
# 配置；不与 Linux 长跑共用目标或 checkpoint。
p6-lse128: lockstep-build lockstep-build-l1dl2
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_lse128_program("build/difftest/hard_lse128.bin")'
	IMAGE=$(CURDIR)/build/difftest/hard_lse128.bin MAX_INSNS=$(LSE128_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh
	IMAGE=$(CURDIR)/build/difftest/hard_lse128.bin MAX_INSNS=$(LSE128_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep_l1dl2/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p6-wfi:
	./sim/difftest/run_p6_wfi.sh

# P6：EL0 Generic Timer accessfn 与 CNTKCTL[0/1/8/9] gate；每个配置均
# 通过 handler 验证 EC=0x18 的同步 trap 和放行后的 MRS/MSR。
p6-timer-el0: lockstep-build lockstep-build-l1dl2
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_timer_el0_program("build/difftest/hard_timer_el0.bin")'
	IMAGE=$(CURDIR)/build/difftest/hard_timer_el0.bin MAX_INSNS=$(TIMER_EL0_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh
	IMAGE=$(CURDIR)/build/difftest/hard_timer_el0.bin MAX_INSNS=$(TIMER_EL0_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep_l1dl2/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# P6：ARMv8.2 DC CVAP 与 AT S1E0/S1E1P/W* 精确 tuple、PAN regime 和
# PAR_EL1 提交时机；base/cache 两种配置均运行同一条严格锁步程序。
p6-maint-v82: lockstep-build lockstep-build-l1dl2
	mkdir -p build/difftest
	$(MAKE) -C qemu/plugins
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_maint_v82_program("build/difftest/hard_maint_v82.bin"); test_program.build_hard_maint_v82_mmu_program("build/difftest/hard_maint_v82_mmu.bin"); test_program.build_hard_maint_v82_el0_program("build/difftest/hard_maint_v82_el0.bin")'
	IMAGE=$(CURDIR)/build/difftest/hard_maint_v82.bin MAX_INSNS=$(MAINT_V82_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh
	IMAGE=$(CURDIR)/build/difftest/hard_maint_v82.bin MAX_INSNS=$(MAINT_V82_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep_l1dl2/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh
	IMAGE=$(CURDIR)/build/difftest/hard_maint_v82_mmu.bin MAX_INSNS=$(MAINT_V82_MMU_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh
	IMAGE=$(CURDIR)/build/difftest/hard_maint_v82_mmu.bin MAX_INSNS=$(MAINT_V82_MMU_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep_l1dl2/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh
	IMAGE=$(CURDIR)/build/difftest/hard_maint_v82_el0.bin MAX_INSNS=$(MAINT_V82_EL0_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh
	IMAGE=$(CURDIR)/build/difftest/hard_maint_v82_el0.bin MAX_INSNS=$(MAINT_V82_EL0_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep_l1dl2/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# P7-1：A76 required strict lockstep。FP wire/FP_INIT/FP_COMMIT 已由 P7-0
# 冻结；本目标只验证受限 scalar FP 指令，不启用 Cache/AXI/FPGA 配置。
p7-1-fp-scalar: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_fp_scalar_program("build/difftest/hard_fp_scalar.bin")'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_fp_scalar.bin MAX_INSNS=$(P7_FP_SCALAR_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# P7-1 raw edge program：NaN payload/quieting、Inf、zero、subnormal、DN/FZ
# 和 S/D scalar memory；仍固定 A76 required，作为额外 L2 证据运行。
p7-1-fp-scalar-edge: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_fp_scalar_edge_program("build/difftest/hard_fp_scalar_edge.bin")'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_fp_scalar_edge.bin MAX_INSNS=$(P7_FP_SCALAR_EDGE_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-1-fp-scalar-rounding: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_fp_scalar_rounding_program("build/difftest/hard_fp_scalar_rounding.bin")'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_fp_scalar_rounding.bin MAX_INSNS=$(P7_FP_SCALAR_ROUNDING_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# P7-1：仓内可重建的 forwarding/sticky 压力序列。seed/rounds 显式传给
# test_program.py，seed=1、rounds=32 固定产生 388 条提交。
p7-1-fp-scalar-sequence: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_fp_scalar_sequence_program("build/difftest/hard_fp_scalar_sequence.bin", seed=1, rounds=32); assert n == $(P7_FP_SCALAR_SEQUENCE_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_fp_scalar_sequence.bin MAX_INSNS=$(P7_FP_SCALAR_SEQUENCE_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# P7-2：Q integer/单 Q 访存的独立 L1 入口与 A76 required lockstep。
sim-sv-p7-2-neon:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_neon_int_tb -Mdir obj_dir_neon -o lcvex_neon_int_tb \
		-f rtl/filelist.f tb/sv/lcvex_neon_int_tb.sv
	./obj_dir_neon/lcvex_neon_int_tb

# P7-2 negative memory-contract probe. It intentionally returns a fault for
# the second half after the first write request is accepted, so an
# assertion-enabled run must fail and leave the failure log. This target is
# not a green feature gate and must never be relabeled as a passing atomicity
# test.
sim-sv-p7-2-neon-fault-bfm:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_neon_fault_bfm_tb -Mdir obj_dir_neon_fault_bfm_assert \
		-o lcvex_neon_fault_bfm_tb -f rtl/filelist.f tb/sv/lcvex_neon_int_tb.sv
	mkdir -p build/agents/T-20260827-059
	./obj_dir_neon_fault_bfm_assert/lcvex_neon_fault_bfm_tb > build/agents/T-20260827-059/fault-bfm-assert.log 2>&1

# P7-3：NEON 2S/4S/2D raw FP execution unit，独立于 core pipeline 验证。
sim-sv-p7-3-neon-fp:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_neon_fp_tb -Mdir obj_dir_neon_fp -o lcvex_neon_fp_tb \
		-f rtl/filelist.f tb/sv/lcvex_neon_fp_tb.sv
	./obj_dir_neon_fp/lcvex_neon_fp_tb

sim-cocotb-p7-2-neon:
	$(CONDA_RUN) make -C sim/cocotb -f Makefile.p7_2_neon \
		SIM=verilator TOPLEVEL=lcvex_soc_tb \
		COCOTB_TEST_MODULES=test_p7_2_neon \
		MEM_DELAY_MODE=$(P7_NEON_MEM_DELAY_MODE) SIM_BUILD=$(P7_NEON_SIM_BUILD)

sim-cocotb-p7-3-neon-fp:
	$(CONDA_RUN) make -C sim/cocotb -f Makefile.p7_3_neon_fp \
		SIM=verilator TOPLEVEL=lcvex_soc_tb \
		COCOTB_TEST_MODULES=test_p7_3_neon_fp \
		MEM_DELAY_MODE=$(P7_NEON_FP_MEM_DELAY_MODE) SIM_BUILD=$(P7_NEON_FP_SIM_BUILD)

p7-3-neon-fp: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_neon_fp_program("build/difftest/hard_neon_fp.bin"); assert n == $(P7_NEON_FP_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_neon_fp.bin MAX_INSNS=$(P7_NEON_FP_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# P7-4：FMA 与 FP/整数转换的 raw unit / pipeline / A76 required lockstep。
sim-sv-p7-4-fma-convert:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_fp_scalar_p7_4_tb -Mdir obj_dir_fp_p7_4 \
		-o lcvex_fp_scalar_p7_4_tb rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv \
		tb/sv/lcvex_fp_scalar_p7_4_tb.sv
	./obj_dir_fp_p7_4/lcvex_fp_scalar_p7_4_tb
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_neon_fp_p7_4_tb -Mdir obj_dir_neon_p7_4 \
		-o lcvex_neon_fp_p7_4_tb rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv \
		rtl/lcvex_neon_fp.sv tb/sv/lcvex_neon_fp_p7_4_tb.sv
	./obj_dir_neon_p7_4/lcvex_neon_fp_p7_4_tb

sim-cocotb-p7-4-fma-convert:
	$(CONDA_RUN) make -C sim/cocotb -f Makefile.p7_4_fma_convert \
		SIM=verilator TOPLEVEL=lcvex_soc_tb \
		COCOTB_TEST_MODULES=test_p7_4_fma_convert \
		MEM_DELAY_MODE=$(P7_NEON_FP_MEM_DELAY_MODE) \
		SIM_BUILD=$(P7_4_FMA_CONVERT_SIM_BUILD)

p7-4-fma-convert: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_p7_4_fma_convert_program("build/difftest/hard_p7_4_fma_convert.bin"); assert n == $(P7_4_FMA_CONVERT_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_p7_4_fma_convert.bin MAX_INSNS=$(P7_4_FMA_CONVERT_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-4-fma-convert-edge: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_p7_4_fma_convert_edge_program("build/difftest/hard_p7_4_fma_convert_edge.bin"); assert n == $(P7_4_FMA_CONVERT_EDGE_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_p7_4_fma_convert_edge.bin MAX_INSNS=$(P7_4_FMA_CONVERT_EDGE_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-4-fma-convert-rounding: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_p7_4_fma_convert_rounding_program("build/difftest/hard_p7_4_fma_convert_rounding.bin"); assert n == $(P7_4_FMA_CONVERT_ROUNDING_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_p7_4_fma_convert_rounding.bin MAX_INSNS=$(P7_4_FMA_CONVERT_ROUNDING_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-4-fma-convert-sequence: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_p7_4_fma_convert_sequence_program("build/difftest/hard_p7_4_fma_convert_sequence.bin", seed=1, rounds=8); assert n == $(P7_4_FMA_CONVERT_SEQUENCE_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_p7_4_fma_convert_sequence.bin MAX_INSNS=$(P7_4_FMA_CONVERT_SEQUENCE_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# P7-5：FP16/sqrt/minmax/rint 的 raw unit / pipeline / A76 required lockstep。
sim-sv-p7-5-fp16-sqrt-minmax-round:
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_fp_scalar_p7_5_tb -Mdir obj_dir_fp_p7_5 \
		-o lcvex_fp_scalar_p7_5_tb rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv \
		tb/sv/lcvex_fp_scalar_p7_5_tb.sv
	./obj_dir_fp_p7_5/lcvex_fp_scalar_p7_5_tb
	$(CONDA_RUN) verilator --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_neon_fp_p7_5_tb -Mdir obj_dir_neon_p7_5 \
		-o lcvex_neon_fp_p7_5_tb rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv \
		rtl/lcvex_neon_fp.sv tb/sv/lcvex_neon_fp_p7_5_tb.sv
	./obj_dir_neon_p7_5/lcvex_neon_fp_p7_5_tb

sim-cocotb-p7-5-fp16-sqrt-minmax-round:
	$(CONDA_RUN) make -C sim/cocotb -f Makefile.p7_5_fp16_sqrt_minmax_round \
		SIM=verilator TOPLEVEL=lcvex_soc_tb \
		COCOTB_TEST_MODULES=test_p7_5_fp16_sqrt_minmax_round \
		MEM_DELAY_MODE=$(P7_NEON_FP_MEM_DELAY_MODE) \
		SIM_BUILD=$(P7_5_FP16_SQRT_MINMAX_ROUND_SIM_BUILD)

p7-5-fp16-sqrt-minmax-round: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_p7_5_fp16_sqrt_minmax_round_program("build/difftest/hard_p7_5_fp16_sqrt_minmax_round.bin"); assert n == $(P7_5_FP16_SQRT_MINMAX_ROUND_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_p7_5_fp16_sqrt_minmax_round.bin MAX_INSNS=$(P7_5_FP16_SQRT_MINMAX_ROUND_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-5-fp16-sqrt-minmax-round-edge: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_p7_5_fp16_sqrt_minmax_round_edge_program("build/difftest/hard_p7_5_fp16_sqrt_minmax_round_edge.bin"); assert n == $(P7_5_FP16_SQRT_MINMAX_ROUND_EDGE_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_p7_5_fp16_sqrt_minmax_round_edge.bin MAX_INSNS=$(P7_5_FP16_SQRT_MINMAX_ROUND_EDGE_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-5-fp16-sqrt-minmax-round-rounding: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_p7_5_fp16_sqrt_minmax_round_rounding_program("build/difftest/hard_p7_5_fp16_sqrt_minmax_round_rounding.bin"); assert n == $(P7_5_FP16_SQRT_MINMAX_ROUND_ROUNDING_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_p7_5_fp16_sqrt_minmax_round_rounding.bin MAX_INSNS=$(P7_5_FP16_SQRT_MINMAX_ROUND_ROUNDING_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-5-fp16-sqrt-minmax-round-sequence: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_p7_5_fp16_sqrt_minmax_round_sequence_program("build/difftest/hard_p7_5_fp16_sqrt_minmax_round_sequence.bin", seed=1, rounds=6); assert n == $(P7_5_FP16_SQRT_MINMAX_ROUND_SEQUENCE_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_p7_5_fp16_sqrt_minmax_round_sequence.bin MAX_INSNS=$(P7_5_FP16_SQRT_MINMAX_ROUND_SEQUENCE_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-2-neon-int: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; n=test_program.build_hard_neon_int_program("build/difftest/hard_neon_int.bin"); assert n == $(P7_NEON_INT_MAX_INSNS), n'
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_neon_int.bin MAX_INSNS=$(P7_NEON_INT_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

p7-2-neon-fetch-fault: lockstep-build
	mkdir -p build/difftest
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_neon_fetch_fault_program("build/difftest/hard_neon_fetch_fault.bin")'
	$(CONDA_RUN) python3 sim/difftest/check_neon_fetch_fault.py --image build/difftest/hard_neon_fetch_fault.bin --static-only
	$(MAKE) -C qemu/plugins
	FP_NEON=required IMAGE=$(CURDIR)/build/difftest/hard_neon_fetch_fault.bin MAX_INSNS=$(P7_NEON_FETCH_FAULT_MAX_INSNS) COORD=$(CURDIR)/build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh

# P7-2 page-end fault semantic sidecar.  The strict step runner remains the
# authority for architectural comparison; this target supplements it with a
# required-profile QEMU trace so a green 20/20 run cannot hide an early EC=0x07
# trap or a missing second 8-byte half of STR Q.  The trace and strict logs are
# intentionally supplied by the integrator's isolated heavy run.
p7-2-neon-fetch-fault-semantic:
	@test -n "$(NEON_FETCH_FAULT_TRACE)" || (echo 'NEON_FETCH_FAULT_TRACE 未设置' >&2; exit 2)
	@test -n "$(NEON_FETCH_FAULT_STRICT_LOG)" || (echo 'NEON_FETCH_FAULT_STRICT_LOG 未设置' >&2; exit 2)
	@test -n "$(NEON_FETCH_FAULT_COORD_LOG)" || (echo 'NEON_FETCH_FAULT_COORD_LOG 未设置' >&2; exit 2)
	@test -n "$(NEON_FETCH_FAULT_RUN_LOG)" || (echo 'NEON_FETCH_FAULT_RUN_LOG 未设置' >&2; exit 2)
	$(CONDA_RUN) python3 sim/difftest/check_neon_fetch_fault.py \
		--image build/difftest/hard_neon_fetch_fault.bin \
		--trace "$(NEON_FETCH_FAULT_TRACE)" \
		--strict-log "$(NEON_FETCH_FAULT_STRICT_LOG)" \
		--coord-log "$(NEON_FETCH_FAULT_COORD_LOG)" \
		--runner-log "$(NEON_FETCH_FAULT_RUN_LOG)" \
		$(if $(NEON_FETCH_FAULT_RUN_QEMU),--run-qemu,)

# Lightweight negative/positive guard test.  This deliberately mutates the
# generated image in memory (old FPEN layout and old read-only data page) and
# feeds synthetic trace/log records; it never launches a simulator or QEMU.
p7-2-neon-fetch-fault-semantic-selftest:
	mkdir -p build/agents/T-20260905-015/static
	$(CONDA_RUN) python3 -c 'import sys; sys.path.insert(0, "sim/difftest"); import test_program; test_program.build_hard_neon_fetch_fault_program("build/agents/T-20260905-015/static/hard_neon_fetch_fault.bin")'
	$(CONDA_RUN) python3 sim/difftest/check_neon_fetch_fault.py \
		--image build/agents/T-20260905-015/static/hard_neon_fetch_fault.bin --self-test

gate-d:
	./sim/difftest/run_gate_d.sh

# M2-5 Gate D：SV 单元 TB 覆盖率（Verilator --coverage，各 TB 独立目录
# 运行，输出合并到 build/coverage/merged.dat 并打印排名）。
COV_TBS = l1_d l1_i l2 mmu mem_if
COV_TARGETS = $(addprefix cov-,$(COV_TBS))

define cov_rule
cov-$(1):
	$$(CONDA_RUN) verilator --binary --timing --assert --coverage -Wall -Wno-fatal -Wno-UNUSEDPARAM -j $(VERILATOR_JOBS) \
		--top-module lcvex_$(1)_tb -Mdir obj_dir_$(1)_cov -o lcvex_$(1)_tb \
		-f rtl/filelist.f tb/sv/lcvex_$(1)_tb.sv
	cd obj_dir_$(1)_cov && ./lcvex_$(1)_tb >/dev/null
endef
$(foreach tb,$(COV_TBS),$(eval $(call cov_rule,$(tb))))

coverage: $(COV_TARGETS)
	mkdir -p build/coverage
	$(CONDA_RUN) verilator_coverage --write build/coverage/merged.dat \
		$(addsuffix /coverage.dat,$(addprefix obj_dir_,$(addsuffix _cov,$(COV_TBS))))
	$(CONDA_RUN) verilator_coverage --rank build/coverage/merged.dat

test: commit-digest-test toolcheck compile sim-sv sim-sv-backpressure sim-cocotb sim-cocotb-regfile \
	sim-cocotb-backpressure sim-cocotb-mmio sim-sv-memif sim-sv-l1d sim-sv-l1i sim-sv-l2 \
	sim-sv-mmu sim-sv-pl011 sim-sv-pl061 sim-sv-mmio sim-sv-crc check-encoders
	@echo "P0 检查全部通过"

check-encoders:
	$(CONDA_RUN) python3 sim/difftest/check_encoders.py

clean:
	rm -rf obj_dir
	$(CONDA_RUN) make -C sim/cocotb clean
