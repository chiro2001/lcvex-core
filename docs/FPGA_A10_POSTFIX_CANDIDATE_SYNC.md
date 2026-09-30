# FPGA-G6-POSTFIX-SYNC：A10 final-core candidate 隔离同步

```text
task=T-20260831-008
label=FPGA-G6-POSTFIX-SYNC
state=review
base=291018d9a63efe549be589d1127e424e1118ed8a
source_commit=291018d9a63efe549be589d1127e424e1118ed8a
branch=infra/T-20260831-008-a10-postfix-sync
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260831-008
remote_root=D:\Projects\fpga-altra\lcvex\build\T-20260831-008\candidate
sent_at=2026-08-31T20:26:25+08:00
received_at=2026-08-31T20:26:25+08:00
reported_at=2026-08-31T20:50:15+08:00
```

## 结论

候选源 `291018d9a63efe549be589d1127e424e1118ed8a` 已从独立 worktree 归档到新的
build-only staging，并同步至远端全新根。tracked closure、QSF 相对路径 aliases、
manifest、sidecar 和远端逐项回读均闭合；没有写入 T-003 或任何旧 build 工程。

本任务只建立后续 resource/reduced probe 的 candidate，不代表 synthesis、fit、STA、
SOF/JIC、release 或上板通过。

## 本地 closure

源 closure 使用：

```text
git archive --format=tar HEAD rtl fpga/catapult_a10
```

随后依据当前 QSF 的 49 个 file references 重新计算并生成 29 个 candidate-only
`fpga/rtl/*.sv` aliases；每个 alias 与根 `rtl` 对应文件逐字节相等。T-003 的旧
manifest/hash 未复用。

```text
tracked_file_count=121
tracked_total_bytes=2738282
derived_alias_file_count=29
alias_total_bytes=754249
file_count=150
total_bytes=3492531
qsf_reference_count=49
qsf_missing_before_alias=29
qsf_missing_after_alias=0
canonical_sha256=c8c3caa599e86ef397a1cada33b9e951c4862891f10c94298f5a2b69cb1823b9
manifest_sha256=64a4612979960fa9d01a734a151710b45be76c8335f63197a772067dc0c162a7
manifest_bytes=88604
sidecar_sha256=0b4d912c8e291aba3e5dd7264cd420a97a8024085ec4dd9e9e62e3741091c855
```

平台离线门与严格来源门均针对当前 worktree 执行。严格来源仅核对已锁定的
`a10-linux-riscv@3db828e74651fda377a33d84f2a2ca0e69901d72` 平台 payload；candidate
自身 source identity 仍是 `291018d...`。

```text
platform offline: PLATFORM_CHECK_PASS files=50 strict_source=OFF
platform strict: PLATFORM_CHECK_PASS files=50 strict_source=PASS
SHA256SUMS: 50/50 OK
skeleton: SKELETON_CHECK_PASS files=6
```

QPF/QSF/SDC 当前 hash：

| 文件 | bytes | SHA-256 |
| --- | ---: | --- |
| `fpga/catapult_a10/quartus/catapult_a10.qpf` | 34 | `38ac01ac2dfc0dbf28fc5bb2be22e2323606c18716b46ec6c5d048e5fe4ec1dd` |
| `fpga/catapult_a10/quartus/catapult_a10.qsf` | 13647 | `78032dc5634dc08bf15e916fb70e9f2f6ddefd6b2dd5d59600b3c4c3a236f19d` |
| `fpga/catapult_a10/quartus/catapult_a10.sdc` | 5656 | `caf847755a8c42f2e88ea09e434888938ad4382193400593ddcc986f26154a8c` |

## 远端安全与回读

远端为 `192.168.101.5`（`GAMEPC`），shell 为显式 `pwsh.exe -NoLogo -NoProfile
-NonInteractive -EncodedCommand`。同步前快照（`2026-08-31T20:33:21.4907554+08:00`）确认
目标根不存在且 child count 为 0。固定 Quartus/Qsys 可执行文件均存在；没有
`quartus_syn`、`quartus_fit`、`qsys`、`vsim`、`questa` 或 ModelSim 编译/仿真作业。

快照中有 `jtagserver.exe`（PID 5700，JTAG 服务，未停止）和 SlimeVR 的 Java
服务（PID 18104，非 EDA，未停止）；两者均未被本任务改变。物理内存总量/空闲为
`63092.3/42146.4 MB`，pagefile 为 `12800 MB` allocated、`259 MB` current、
`12541 MB` available，D 盘空闲 `95.61 GB`。candidate 根于
`2026-08-31T20:34:17.3172491+08:00` 创建并再次确认为空。

只向该新根传输 `rtl/`、`fpga/`、`candidate_manifest.json` 和 sidecar。同步后快照
（`2026-08-31T20:42:26.5627333+08:00`）仍无 Quartus/Qsys/vsim/questa 编译作业；
candidate 根 child count 为 4，物理内存空闲 `42943.3 MB`，pagefile available
`12541 MB`，D 盘空闲 `95.59 GB`。

远端闭包回读：

```text
root_total_file_count=152
closure_file_count=150
manifest_file_count=150
actual_total_bytes=3492531
file_set_match=true
missing_count=0
extra_count=0
hash_bytes_bad_count=0
manifest_file_sha256=64a4612979960fa9d01a734a151710b45be76c8335f63197a772067dc0c162a7
sidecar_match=true
candidate_commit=291018d9a63efe549be589d1127e424e1118ed8a
qsf_reference_count=49
qsf_missing_count=0
alias_count=29
alias_mismatch_count=0
```

关键 hash 回读包括 `platform_manifest.json`、`source.lock`、`SHA256SUMS`、
`skeleton_manifest.json`、QPF/QSF/SDC、Qsys/Qsys_bb、SFL QIP/synth、A10 top、
`rtl/filelist.f` 和 `rtl/lcvex_catapult_soc_top.sv`，共 14 项，均与本地一致。

## 非动作、限制与下一步

- 未运行 `quartus_sh`、`quartus_syn`、`quartus_fit`、`quartus_sta`、`quartus_asm`、
  `qsys`、`vsim`、`questa`、`quartus_pgm` 或任何生成器。
- 未读取 license 内容；未改 pagefile、系统配置、远端进程或旧工程；未生成/写入
  SOF、JIC、RBF、Flash 或板卡。
- candidate 仅供后续不超过约 35 GB 先验资源门的 reduced/partition probe；full
  synthesis 仍受历史 75--77 GB 峰值与资源门约束。
- JTAG chain/device identity 仍需人工确认，programming 保持 WAIT。
- 后续 T-007 释放资源门后，才可登记独立 reduced/partition experiment；任何输入
  或 QSF 路径变化都必须重新建立新 candidate 根和新 manifest。

精确运行命令、时间、artifact hash、远端前后快照与非动作记录见
[`docs/tasks/evidence/T-20260831-008.json`](tasks/evidence/T-20260831-008.json)。
