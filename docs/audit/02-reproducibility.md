# 02 可复现性：工具链、构建入口、QEMU patch、文件清单、CORE_COUNT

> 状态：**本地可复现链路已建立并有 evidence；交叉编译器和远端 Quartus 仍不是全封闭本地工具链。**

## 1. 固定工具链

| 工具 | 固定版本 | 来源/说明 |
| --- | --- | --- |
| Verilator | 5.050 | conda-forge，`env/environment.yml` |
| Cocotb | 2.0.1 | pip，`env/environment.yml` |
| Python | 3.12 | conda-forge |
| GNU Make | 4.4.1 | conda-forge |
| pytest | 8.3.5 | 辅助断言/输出 |
| QEMU | 11.1.0 | 固定 release tag `v11.1.0`，commit `84f07211cc5b4fc6a371559bf8a5de4fb068e648` |

- QEMU 官方发布：2026-08-11（仓库 `qemu/VERSION`）。
- 环境文件 SHA256：`716b5206638400e4c6f3ec4274d2fe18ae48fcb76bb48619361f5bbd29df7501`。
- `scripts/toolcheck.sh` 自动核对上述版本；`make toolcheck` 入口。
- 已知缺口：`aarch64-none-elf-gcc` 目前不是 conda 环境固定依赖，P2 软件测试
  需要时仍需补齐并固定版本。

## 2. 仓库关键 SHA（本材料生成基线）

| 项目 | 值 |
| --- | --- |
| 材料生成 head | `5f78319234a603f522af407e5378b7ef786fa1d1` |
| 分支 | `feature/T-20260829-104-external-audit` |
| RTL filelist | `rtl/filelist.f` |
| RTL filelist SHA256 | `404108df9586747b6993e490fdda9d223112c0513041926f59d65cda499154c8` |
| QEMU 固定 fork commit | `84f07211cc5b4fc6a371559bf8a5de4fb068e648` |
| QEMU fork trace 分支 | `lcvex-step-hook`，fork commit 记录 `ccd819d`（仅追溯） |

## 3. QEMU patch 清单与 hash

仓库跟踪 13 个可重放 patch，按文件名顺序应用（AUD-13FIX 后）：

| Patch | SHA256 |
| --- | --- |
| 0001-tcg-arm-lcvex-difftest-step-hook.patch | `6ac5a638208e4c72bd5b4cc0ef73615cd436a36718b2712d5c6b7a02d2a191ec` |
| 0002-lcvex-checkpoint-hook.patch | `291ab2d5e9bdaa83ec462616a89fd742448e3624f579e35ff04d814048bd22ba` |
| 0003-lcvex-wfi-idle-plugin-hook.patch | `763f1b422aadc641ad98c818c994ad984470b536be065d710bf7c4717db32035` |
| 0004-lcvex-timer-recalc-after-restore.patch | `8971b2eb8d9dda15cb00a870f4975d5d04b0f7139d2882321a461597eb5e6eaf` |
| 0005-lcvex-wfxt-idle-plugin-hook.patch | `c5c92a17d13108c0ea5a8ae561cae08452ed448ee61c69f90e6e02e1554aa9af` |
| 0006-lcvex-timer-offset-schedule.patch | `69b2c41d30472eac580570d6ce281dd5ec917248442bb1d359cf86fc5a50fc24` |
| 0007-lcvex-generic-timer-step-kick.patch | `29372142eb1301d6ed7c740bb680a6af22e6404e9560a75d6ff8a149b2428fc2` |
| 0008-lcvex-wait-resume-cntvct.patch | `515f86fefcd488879f4eb3080437a61636dd5a802aceddb6449e4f62a6bd34f3` |
| 0009-lcvex-sys-sidecar-v4.patch | `40e4f54133f1d1b4c69c1389b1f10f7a1ce3e45595ce2daf9f166641bdfd5a30` |
| 0010-lcvex-plugin-exception-note-context.patch | `d4a29a9beb76731bfe3d354a5923d083fa841ffd1a7e62fd9cfee96230781b1e` |
| 0011-lcvex-aarch64-vfpd32-off.patch | `f84212831ff25ff2d40f314024925ec2c735674a6f08ddb4b9fa5e56ddc12f9c` |
| 0012-lcvex-fp-state.patch | `18de377fb4b893cd6f66ebca5014b64ffdd6e800c42262387dd91c6c4562f78d` |
| 0013-lcvex-timer-cnto-kick.patch | `86707c4febbd2cc351f6ba92522fbd06798d6dbeeead1aa8c0a6ee23bcac9a56` |
| **全部 patch 内容组合 SHA256（canonical）** | `b6b820249650b92ec9842da4e6492bdc8fb5dc12e2f2fc1ed0090069294e1119` |

AUD-13FIX 变更摘要：
- `0012-lcvex-fp-state.patch` 重新生成：补充真实上下文，`git apply` 会把
  FP state 声明插入 `qemu-plugin.h` include guard 内；幂等。
- 原 `0009-lcvex-sys-sidecar-v3.patch` 与后续 v4 修改合并为
  `0009-lcvex-sys-sidecar-v4.patch`，包含 `LCVXSYS4`、`CONTEXTIDR_EL1`。
- 新增 `0013-lcvex-timer-cnto-kick.patch`，补录 `gt_cntvoff_write` /
  `gt_cntpoff_write` 的 `qemu_cpu_kick()`。
- 新 patch 集在干净 QEMU 11.1.0 上 `apply-patches.sh` 13/13 应用成功，
  再次运行 13/13 跳过（幂等）；应用后 8 个 fork 文件与当前
  `/home/chiro/projects/mycpu/qemu` 完全一致。

### 3.1 Canonical combined hash 定义

- 文件范围：`qemu/patches/` 下匹配 `^[0-9]{4}-.*\.patch$` 的 13 个文件。
- 排序：按文件名做固定字节序排序（`LC_ALL=C`；Python 工具按 `name.encode()` 排序）。
- 文件边界：**不插入任何文件名、分隔符、NUL 或空行**。
- 内容边界：每个 patch 以仓库工作区中的**原始文件字节**参与哈希，包含各文件
  自身已有的结尾换行；不进行归一化、不追加 EOF。
- 组合摘要：对上述串接后的原始字节计算 SHA256。

Canonical shell 命令：

```sh
LC_ALL=C find qemu/patches -maxdepth 1 -type f -name '*.patch' -print0 \
  | sort -z | xargs -0 cat | sha256sum
```

机器校验入口：

```sh
python3 scripts/qemu_patch_hash.py
python3 scripts/qemu_patch_hash.py --check b6b820249650b92ec9842da4e6492bdc8fb5dc12e2f2fc1ed0090069294e1119
```

### 3.2 Correction（EXT-02-001）

- 旧值（T-104/审计材料曾声明）：`43095d343e8f80b0e145f0240f2f18663fb6be81e85222dd5add4cd0132c89af`
- 修正后 canonical 值：`33abdb70e02fbfd40b6fa784302c6f5ff25410960c97958cc1804f6070615c94`
- 结论：旧值没有对应任何已定义的排序/边界命令；外部审计实测
  `33abdb70...` 与本节 canonical 命令一致。单文件 SHA256 未受影响。
- 后续 CI/fresh replay（T-20260829-118）应使用修正后的 canonical 值。
- 本修正记录在 `docs/tasks/evidence/T-20260829-111.json`。

### 3.3 AUD-13FIX / EXT-02-001 后续修正（T-20260830-023）

- AUD-06 旧 canonical（仅文件 hash）：`33abdb70e02fbfd40b6fa784302c6f5ff25410960c97958cc1804f6070615c94`
- AUD-13 发现：该 hash 对应文件能重放，但应用后树不能构建、且与当前 fork 不一致。
- AUD-13FIX 新 canonical：`b6b820249650b92ec9842da4e6492bdc8fb5dc12e2f2fc1ed0090069294e1119`
- 新 canonical 定义仍为 RAW 字节串接；patch 数量由 12 变为 13。
- 当前 fork 对账与 fresh replay 证据见
  `docs/handoffs/T-20260830-023-aud-13-fix.md`、
  `docs/tasks/evidence/T-20260830-023.json`。

QEMU 插件/协议关键 hash（来自 T-098）：
- 插件源码 `qemu/plugins/lcvex_difftest.c`：
  `fb24cc183a497d8a3615283e0b74e095e82856105d86d354e6b3354326f9cb13`
- 协议头 `qemu/plugins/lcvex_protocol.h`：
  `af62b3d8e4dd4625d958aef222303a97f3828b6c5cf8fb5d76c20ce94868b6b1`
- 协议 py `qemu/plugins/lcvex_protocol.py`：
  `b93f14a5a9a45c7e2fe1ab0b2366bdf382dd2bd0dab7dcb5b11a2b91a08def22`

## 4. 可复现构建步骤

### 4.1 环境

```sh
conda env create -f env/environment.yml
conda activate lcvex
make toolcheck
```

### 4.2 QEMU fork 与 patch

```sh
bash qemu/scripts/apply-patches.sh        # 默认 ../qemu，校验固定 commit 并重放 patch
bash scripts/build-qemu.sh                # 构建 QEMU
make -C qemu/plugins                      # 构建 difftest 插件
```

`apply-patches.sh` 支持 `--fresh DIR` 做干净克隆+重放；补丁幂等，已应用自动跳过。

### 4.3 P0 / 基础回归

```sh
make compile        # RTL lint (Verilator lint-only)
make test           # toolcheck + compile + SV TB + Cocotb + encoder check
make coverage       # L1/L2/MMU/PTW SV TB 覆盖率合并
```

### 4.4 QEMU 差分锁步与 Gate D

常用构建目标（Makefile）：
- `lockstep-build`（基础协调器）
- `lockstep-build-kernel` / `lockstep-build-kernel-nofp`（Linux 内核/无 FP lite）
- `lockstep-build-l1dl2-delay2`（全 Cache + 随机延迟）
- `make p7-*`（FP/NEON 定向）
- `bash sim/difftest/run_gate_d.sh --parallel`（完整 Gate D）

每次重型构建/运行应使用 cgroup 限制并记录 source SHA、seed、工具版本、资源。

## 5. manifest / checkpoint

- 差分 checkpoint 是 QEMU/Verilator 联合恢复的七分片 gz 链
  （ram/arch/dev/sys/timer/gic/mmio），带 parent/global provenance、TSV 和
  artifact SHA。
- P7 FP/NEON checkpoint 使用独立 552B `LCVXFP01` sidecar 与 manifest 第 13 列。
- 系统 sidecar 已升级到 v4（`LCVXSYS4`，548 字节，新增 `contextidr_el1`），
  代码已合入；AUD-12（T-20260829-117）已完成完整 DUT/QEMU 联合恢复，
  `CONTEXTIDR_EL1=0x56781234` 非零值经 QEMU `-incoming` + DUT restore 后
  继续锁步一致。
- `make checkpoint-*-smoke`、`make trace-manifest-smoke` 提供小规模验证入口。
- `scripts/trace_manifest.py`、`sim/difftest/checkpoint.py` 是机器工具。

## 6. CORE_COUNT 配置

CORE_COUNT 不是单一 Makefile 全局变量，而是 RTL 参数化：

| 参数/位置 | 现状 |
| --- | --- |
| `rtl/lcvex_cluster_top.sv` `CORE_COUNT` | 默认 2；`generate` 逐核复制 core wrap；C3 后支持 4 核，C4 测量支持 8/16/32 参数化 |
| `COHERENCE_ENABLE` | 默认 0（C1 私有 RAM 路径）；1 时启用共享目录 MSI |
| `CORE_ID_W` / `SOURCE_ID_W` / `TRANSACTION_ID_W` | 4/4/8（当前默认；32 核测量暴露 `CORE_ID_W`/sysctrl 位宽限制） |
| `LINE_BYTES` | 64 |
| `L1_SETS` / `L2_SETS` / `L2_WAYS` | 项目默认 64 / 256 / 2；FPGA-B 已将顶层可配置为 64 / 64 / 1 降规模 |
| `MEM_DEPTH` / `CLUSTER_MEM_LINES` | 64 KiB/核，1024 行（当前 C2） |
| `ARB_MODE` | FLAT_RR（全局 round-robin + liveness fallback） |
| `REQ_QUEUE_DEPTH` | 1（每核单 outstanding） |
| PoC | 64-bit beat，8 beats/line |

`CORE_COUNT=1` 是 F 单核回归锚点，T-20260830-022 已重跑；`CORE_COUNT=2` baseline
已测量（见 06）。C3 四核功能与 C4 8/16/32 规模/趋势测量见
`docs/C3_FOURCORE_PREWORK.md`、`docs/C4_SCALE_PREWORK.md` 及
T-20260829-095/T-20260830-018/T-20260830-019；这些是参数化/scaled smoke 数据，
不是多核架构合规或 Linux SMP。

## 7. 已知不可复现/外部依赖

- 远端 Quartus 工程和 Windows 工具链在仓库外；仓库只保留平台输入、manifest、
  SHA256SUMS 和远程实验 evidence，不保留 Quartus license 或远端凭据。
- 本地 QEMU fork 路径 `../qemu` 是仓库外共享依赖；必须用 `apply-patches.sh`
  重建。
- 交叉编译器版本尚未固定，裸机 C 的编译器产物复现性依赖宿主工具链。
