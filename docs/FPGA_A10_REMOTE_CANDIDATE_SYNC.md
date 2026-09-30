# FPGA-G6-SYNC：Catapult A10 current candidate 远端隔离同步

```text
task=T-20260831-003
label=FPGA-G6-SYNC
base=19d266a7dcffe43de7e0fdcc7057f8881be6a47f
candidate_commit=19d266a7dcffe43de7e0fdcc7057f8881be6a47f
branch=infra/T-20260831-003-a10-candidate-sync
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260831-003
remote_root=D:\Projects\fpga-altra\lcvex\build\T-20260831-003\candidate
date=2026-08-31
```

## 结论

当前集成候选 `19d266a7dcffe43de7e0fdcc7057f8881be6a47f` 已同步到远端全新隔离
candidate 根。远端回读结果与本地 machine-readable manifest 精确一致：closure
共 150 个文件、3,476,191 bytes，包含 121 个 Git tracked 文件和 29 个为 QSF
相对路径补齐的逐字节 alias；source file-set、bytes、SHA-256 均为 0 mismatch。
QSF 的 49 个 file references 全部存在，manifest sidecar 校验通过。

本任务只建立供后续资源实验使用的 candidate，不运行 Quartus/Qsys、仿真、编程或
板卡动作，也不代表最终 release candidate。后续 core/F1a/H-04/H-03 等变更合入后，
必须从新的 commit 重新同步。

## 本地 closure 与 manifest

同步源由 `git archive HEAD rtl fpga/catapult_a10` 建立，排除了 `.git`、build、
obj/log、SOF/JIC/RBF、license、QEMU 和 cache。基础 tracked closure 为：

```text
tracked_roots=rtl,fpga/catapult_a10
tracked_file_count=121
tracked_bytes=2730112
```

现有 `fpga/catapult_a10/quartus/catapult_a10.qsf` 的 B5 RTL assignment 使用
`../../rtl/*.sv`，在保留仓库层次 `fpga/catapult_a10/quartus` + 根 `rtl` 时会指向
不存在的 `fpga/rtl`。本任务没有修改 QSF 或任何 RTL；仅在 candidate staging 和
远端新根生成 29 个 `fpga/rtl/*.sv` aliases，`source_path` 指向相应的根 `rtl`
文件，内容逐字节相同。根 `rtl/**` 仍完整保留，`rtl/filelist.f` 的 repo-relative
路径也保持不变。manifest 的 `qsf_relative_aliases` 记录了全部映射，避免把 alias
误认成新的 RTL 实现。

本地 manifest 位于 build-only staging（不进入 Git）：

```text
path=build/agents/T-20260831-003/candidate/candidate_manifest.json
file_count=150
total_bytes=3476191
tracked_file_count=121
derived_alias_file_count=29
qsf_reference_count=49
qsf_missing_before_alias_count=29
canonical_sha256=ea5c72e4944980492e38587897edffa2efd2c89872191d703e5666d9dd216521
manifest_file_sha256=f17df639c0b33eb55f46d76801f51215b88ba8a4f181066cb3035af27ec55e59
manifest_bytes=58311
sidecar=candidate_manifest.sha256
sidecar_sha256=7d459a41314490950db7d366f7f26b8963b1596e05ad7cacbe2c3934f8f099bd7
```

manifest 的 `canonical_sha256` 是将自身字段置空后按
`UTF-8 JSON, sort_keys=true, indent=2, trailing newline` 计算；完整文件 hash
另由 `candidate_manifest.sha256` 绑定。QPF/QSF/SDC 当前条目为：

| 文件 | bytes | SHA-256 |
| --- | ---: | --- |
| `fpga/catapult_a10/quartus/catapult_a10.qpf` | 34 | `38ac01ac2dfc0dbf28fc5bb2be22e2323606c18716b46ec6c5d048e5fe4ec1dd` |
| `fpga/catapult_a10/quartus/catapult_a10.qsf` | 13647 | `78032dc5634dc08bf15e916fb70e9f2f6ddefd6b2dd5d59600b3c4c3a236f19d` |
| `fpga/catapult_a10/quartus/catapult_a10.sdc` | 5656 | `caf847755a8c42f2e88ea09e434888938ad4382193400593ddcc986f26154a8c` |

## 本地校验

在打包前，worktree HEAD 精确为 `19d266a7...` 且 clean。以下检查均为 L0/static
或 hash 操作：

```text
python3 fpga/catapult_a10/tools/check_platform.py
  PLATFORM_CHECK_PASS files=50 strict_source=OFF
python3 fpga/catapult_a10/tools/check_platform.py --strict-source \
  --source-repo /home/chiro/projects/a10-linux-riscv \
  --source-commit 3db828e74651fda377a33d84f2a2ca0e69901d72
  PLATFORM_CHECK_PASS files=50 strict_source=PASS
(cd fpga/catapult_a10 && sha256sum -c SHA256SUMS)
  50/50 OK
python3 fpga/catapult_a10/tools/check_skeleton.py
  SKELETON_CHECK_PASS files=6; TOOLCHAIN_MISSING quartus_sh,ip-generate,qsys-generate
local candidate manifest closure
  PASS tracked=121 aliases=29 files=150 total_bytes=3476191 canonical_binding=PASS
```

`check_skeleton.py` 默认生成的本地报告位于
`build/agents/T-20260831-003/skeleton-toolchain-report.json`，仅为 build 忽略的本地
证据，不同步该报告。没有运行任何实现/生成器测试。

## 远端同步与回读

同步前只读 probe（`2026-08-31T02:37:43.7904693+08:00`，`GAMEPC`）确认：

```text
root_exists=false
root_child_count=0
eda_process_count=0
java_process_count=1 (SlimeVR Server, PID 18104；非 EDA)
physical_total_mb=63092.3
physical_free_mb=38031.0
pagefile_allocated_mb=12800.0
pagefile_current_mb=363.0
pagefile_peak_mb=363.0
D_free_gb=100.29
```

随后只在 `D:\Projects\fpga-altra\lcvex\build\T-20260831-003\candidate` 创建空根，
用 `scp` 写入 `rtl/`、`fpga/`、`candidate_manifest.json` 和
`candidate_manifest.sha256`；未写入其父目录、原工程或既有 build。同步命令退出码
均为 0。

远端 closure 回读摘要：

```text
timestamp=2026-08-31T02:58:04.7339704+08:00
root_total_file_count=152 (150 closure + 2 manifest files)
closure_file_count=150
manifest_file_count=150
manifest_total_bytes=3476191
actual_total_bytes=3476191
file_set_match=true
missing=0
hash_bytes_bad=0
manifest_file_sha256=f17df639c0b33eb55f46d76801f51215b88ba8a4f181066cb3035af27ec55e59
manifest_sidecar_match=true
candidate_commit=19d266a7dcffe43de7e0fdcc7057f8881be6a47f
```

远端 QSF 路径检查：`REMOTE_QSF refs=49 missing=0`。远端关键输入 hash/bytes
回读与本地 manifest 相同，包括 platform/source/skeleton/SHA256SUMS、QPF/QSF/SDC、
Qsys/Qsys_bb、SFL `epcq.ip`/`synth/sfl_sys.v`、`rtl/filelist.f` 和 SoC top；完整
逐项闭包是最终判据，不复用远端旧工程 key hash。

同步后只读资源/进程 probe（`2026-08-31T02:52:09.6608939+08:00`）确认：

```text
root_exists=true
root_child_count=185 (包含目录)
eda_process_count=0
java_process_count=1 (同一 SlimeVR Server PID 18104；非 EDA)
physical_total_mb=63092.3
physical_free_mb=37548.9
pagefile_allocated_mb=12800.0
pagefile_current_mb=379.0
pagefile_peak_mb=379.0
D_free_gb=100.04
```

资源快照只用于安全审计；没有停止、暂停、改优先级、改 pagefile 或抢占任何进程。

## 边界、风险与下一步

- derived `fpga/rtl` aliases 是为现有 QSF 路径闭包建立的 candidate-only 物料，不能
  作为仓库 RTL source 或最终 release 目录；若 QSF 路径在后续任务修正，需重新生成
  manifest 并重新同步。
- 没有运行 `quartus_sh`、`quartus_syn`、`quartus_fit`、`quartus_sta`、`quartus_asm`、
  `qsys`、`vsim`、`questa`、`quartus_pgm`，没有读取 license，也没有生成 SOF/JIC。
- 远端 candidate 只供后续先验峰值不超过约 35 GB 的 reduced/partition experiment；
  full synthesis 仍受前序资源门阻断。
- 后续任何 core/F1a/H-04/H-03/平台路径变更，都必须从新 source commit 建立新隔离
  根；不得在该 candidate 内覆盖或追加不在 manifest 的输入。

精确命令、源/远端 manifest hash、前后资源/进程快照、写集与非动作记录见
[`docs/tasks/evidence/T-20260831-003.json`](tasks/evidence/T-20260831-003.json)。
