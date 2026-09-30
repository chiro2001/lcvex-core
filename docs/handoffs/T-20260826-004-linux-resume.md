# T-20260826-004：P6 Linux checkpoint 续跑交接

日期：2026-08-26（Asia/Shanghai）  
验证基线：`aac7daf`（包含 T-003 LSE128 实现）  
证据：[T-20260826-004.json](../tasks/evidence/T-20260826-004.json)

## 结果摘要

- lite 使用带当前 QEMU SHA 的 `lite-scalar2-20260825/chain`，seq=6,999,999，
  显式传入 Image/DTB、nofp QEMU CPU、nofp coordinator、`PIN=0`：10,000 条
  和随后 500,000 条逐指令恢复均通过。
- 旧 main `main-scalar-20260825/chain` 的 Image/DTB/QEMU hash 虽记录完整，
  但当前 QEMU 以多种 CPU 配置载入 seq=7,999,999 均在 CPU vmstate post-load
  阶段失败（0 条提交；部分组合报告 incoming cpreg unknown）。该链不能继续
  使用，也不能把失败算作 RTL mismatch 或通过证据。
- 为隔离旧链配置问题，使用当前 QEMU/当前 CPU 配置从头建立新的 main
  bootstrap chain（20,000 条、每 10,000 条 checkpoint），全程通过；从 seq=19,999
  恢复再通过 10,000 条，`PIN=1`。该 bootstrap 仅是后续主线长跑的起点，不是
  Gate E 完成证据。
- 随后从同一 bootstrap seq=19,999 再恢复 **500,000 条**（`PIN=1`）通过；
  当前主线可审计窗口为 20k 首跑 + 10k + 500k，仍未覆盖完整 Linux 深段。
- 尝试在续跑中设置 `CKPT_EVERY=500000` 时生成了未发布的局部链
  `main-extend/chain/base-499999.*`：`run_lockstep_resume.sh` 当前没有自动
  写输入绑定 `manifest.json`，且 seq 是本窗口局部编号。该目录仅作为调试
  现场保留，**不**作为可恢复证据或全局进度计数。

## 输入与配置不变量

- lite：Image SHA `2f61…6543`、DTB SHA `0d1a…1941`、QEMU SHA `4cf4…eba6`；
  `QEMU_CPU=max,has_el3=false,has_el2=false,vfp=off,neon=off,vfp-d32=off`，
  `rdinit=/init`，无 INITRD。
- main bootstrap：Image `/tmp/Image-t80000` SHA `5029…5c68`、导出 DTB SHA
  `ce3a…c3c9`、QEMU SHA `4cf4…eba6`；`QEMU_CPU=max,has_el3=false,has_el2=false`，
  `rdinit=/bin/sh`，无 INITRD。
- 两条线均使用 `BOOT_DTB=0x44000000`、`BOOT_ENTRY=0x40080000`、
  `-icount shift=0`，QEMU/协调器均单核并绑定物理核。

## 资源与清理

- 短/长窗口均串行执行，最多一个 QEMU+一个 Verilator coordinator；CPU 预算
  低于本地默认 50%，未申请 75% 提升。
- QEMU/协调器均已回收，无孤儿进程；运行目录、旧 main 失败诊断和 bootstrap
  manifest 保留在 `build/tmp/T-20260826-004/` 供复核，不写系统 `/tmp` 新文件。
- bootstrap 原始 128 MiB RAM 仅为恢复便利暂留；确认链发布后可删除，不影响
  `restore-ram` 重建。

## 限制与下一步

1. 旧 main 链缺少可复现的 CPU feature context；需新建并持续扩展 bootstrap 链，
   不能仅改 `QEMU_CPU` 或跳过 migration 校验。
2. main 当前为 20k+10k+500k，lite 已有 500k；这些窗口仍只是 Gate E 候选
   证据，不宣称 Gate E 通过。
3. 下一任务应把 main bootstrap 逐步扩展到 100k/500k，并在每个窗口保留
   manifest、QEMU CPU 参数、失败现场和资源峰值；随后再决定 Gate E 冻结候选。
4. 另登记 checkpoint resume provenance 修复：续跑链需记录 parent/global 起点，
   自动生成并校验 `manifest.json` 后才能继续作为下一窗口输入。
