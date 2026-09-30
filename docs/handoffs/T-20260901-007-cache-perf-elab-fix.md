# Handoff T-20260901-007：可选 Cache 性能观测端口与 cache-off elaboration 修复

## 元数据

- task: T-20260901-007
- owner: luna-cache-perf-elaboration-fix
- date: 2026-09-01
- base_sha: `2f17d401e8d85847eaa80dc0a492aa3cd9c6643f`
- head_sha: `6a31cfe338e488a9201611e4564fc949ace43789`（技术实现提交）
- branch: `verify/T-20260901-007-cache-perf-elab-fix`
- worktree: `/home/chiro/projects/mycpu/lcvex-wt-T-20260901-007`
- dependencies: 无；由 T-20260901-005 cache-off elaboration 首因触发
- qemu_release: 本任务仅复用现有 QEMU 11.1.0 构建进行 random seed=1 差分
- qemu_commit: 见 evidence JSON；未修改 QEMU fork
- qemu_patches_sha: 见 evidence JSON；未修改 QEMU patch
- rtl_filelist_sha: `23e27cb9249c08be6e5d11fd8daa0d315d9859dc12b459473ed8f39dea92f46e`
- config/toolchain: Verilator 5.050；Cocotb 2.0.1；aarch64-linux-gnu-gcc 16.1.0
- evidence: `docs/tasks/evidence/T-20260901-007.json`

## 目标与边界

修复 `lcvex_soc_tb` 在 `I_L1_ENABLE=0`、`D_L1_ENABLE=0`、`L2_ENABLE=0` 时对
条件 generate 实例的 dotted reference，保持 cache 功能、请求/响应协议、默认
参数、性能计数定义、断言和参考结果不变。仅覆盖 L0/L1/L2 定向验证；不运行完整
Gate D、Linux、Quartus，也不处理 F1a delay2 性能回退。

## 实现摘要

- `rtl/lcvex_l1_d.sv`、`rtl/lcvex_l1_i.sv`、`rtl/lcvex_l2.sv`：增加纯组合、
  无状态的只读 `perf_hit` 和 `perf_refill_beat` 输出。前者为已有 valid/tag
  命中视图，后者保持 `S_REFILL && d_req_valid && d_req_ready` 握手语义；无
  新寄存器、reset 状态、架构状态、权限或提交时机。
- `tb/sv/lcvex_soc_tb.sv`：显式连接 cache 观测端口；hit/miss 仍由原有
  upstream valid/ready、读、bypass、maintenance 条件资格化；downstream 改用
  现有 `arb_*`/`l2_req_*` 顶层握手。cache-off 分支对内部视图和公开 counter
  均显式置零，不再引用 `dl1/il1/l2` 的内部 `hit/state/d_req_*`。
- `rtl/lcvex_catapult_soc_coh.sv`、三个 cache 单元 TB：对不使用的观测端口
  连接显式本地 sink，避免空 pin warning，且不引入 Catapult 功能/综合依赖。
- `Makefile`：新增 `cache-perf-elab-off`、`cache-perf-elab-on`、组合入口
  `cache-perf-elab`，以及独立目录的 `cache-perf-smoke`。
- `scripts/test_registry.json`：登记上述两个稳定验证入口。
- `docs/CACHE_PERF_OBSERVABILITY_ELABORATION_FIX.md`：记录接口资格化语义、
  reset 边界和使用方式。

## 验证证据

| Evidence run ID | 层级 | 结论/说明 |
| --- | --- | --- |
| owner-cache-elab-r2 | L0 | cache-off 0/0/0 与 cache-on 1/1/1 均独立 Verilator lint/elaboration 通过 |
| owner-cache-perf-smoke-r2 | L0/L1 | 缩小 `mem_ldst` off 全部 cache counter=0；on 三层 hit/refill/downstream 均非零，digest 相同 |
| owner-cache-tb-r2 | L1 | `sim-sv-l1d sim-sv-l1i sim-sv-l2` 全部 PASS |
| owner-cocotb-backpressure | L1 | `make sim-cocotb-backpressure` 2/2 PASS |
| owner-random-seed1 | L2 | `make difftest-random SEED=1 LENGTH=100000`，100002 条指令与 QEMU 完全一致 |
| owner-registry-check | L0 | registry 66 项及 Makefile/runner 一致性检查通过 |

精确命令、退出码、版本、计数、文件 hash 和受限资源配置以 evidence JSON 为准。

## 失败现场/重现

首次 `cache-perf-smoke` 尝试在构建 runner-off 前失败，原因是新 target 未创建
用户覆盖的嵌套 `CACHE_PERF_SMOKE_DIR`，Verilator 无法写 `-Mdir`；补充
`mkdir -p $(CACHE_PERF_SMOKE_DIR)` 后同一目标重跑完整通过。这是入口健壮性修正，
不是 RTL/elaboration 失败。

## 已知限制与后续任务

- 技术提交 `6a31cfe` 尚未包含集成者 merge SHA；集成者应在该提交（及后续 evidence
  文档提交）上复跑任务要求的 L0-L2 子集并补齐 merge metadata。
- 本任务没有验证完整 Gate D、Linux、Quartus/FPGA，也没有修改或签核 F1a
  `nocache_d2` 性能回退。
- QEMU plugin 构建保留既有 `QEMU_PLUGIN_MEM_VALUE_U128` switch warning；不影响
  本次 random 差分结果。

## 集成说明

可直接 cherry-pick 技术实现提交和随后 evidence/handoff 提交；合入后优先在新
冻结 candidate 上重跑 `make cache-perf-elab`、三个 cache TB、backpressure 与
random seed=1，再由集成者登记新的完整 Gate D。
