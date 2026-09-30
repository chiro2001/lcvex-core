# LCVEX 交接文档 044：差分 checkpoint 计划（省磁盘）

目标：周期 checkpoint 只存增量（CPU/设备状态 + RAM 脏页），全量只作为
base，把单次 checkpoint 从 15-110MB 降到 1-5MB 量级。

## 背景与观测

- QEMU `migrate exec:gzip` 全量 = 128MB RAM + 设备/CPU vmstate；
  boot 早期 gzip 后 ~15MB，中后期 100MB+（内存写满、压不动）。
- 差分面：CPU+设备状态很小（几十 KB~几 MB）；RAM 大部分页连续多个
  checkpoint 间不变（每 30 万条指令只改少量页）。
- 已验证：QEMU 11.1 保留 `qemu_save_device_state()`（migration/
  savevm.c:1954，不含 RAM）与 `qemu_loadvm_state_main()`（:3007，
  不带 RAM 恢复路径）——差分方案的 QEMU 侧接口现成。

## 方案分层

### L1：QEMU fork 差分保存/恢复（HMP 命令）

- fork 增加 HMP：
  - `lcvex-ckpt-save <dir> <seq>`：
    1) `qemu_save_device_state()` 序列化 CPU+设备 → `dev.bin`（小）；
    2) 读 TCG 运行期脏页位图 `ram_list.dirty_memory[]`（TCG 写内存会
       置迁移脏标记），只写“自上次 save 以来变脏的页”→ `ram.diff`
       （页表：页号+长度+数据；头记 seq/base_seq）；
    3) 保存后清除迁移脏位图（migration_dirty_pages=0）。
  - `lcvex-ckpt-load <base> [diff...]`：`qemu_loadvm_state_main()` 恢复
    CPU/设备 + 按 diff 写 RAM（或由协调器影子直接用）。
- 全量 base：首个 checkpoint 用全量 migrate（现状路径）或一次性
  `qemu_save_device_state()+全 RAM`；后续全为 diff。
- 待验证点：TCG 脏页位图在 -icount 下的置位时机与清除语义；设备流
  恢复时对 icount/定时器状态的重建。

### L2：协调器影子与文件链

- 内存影子 128MB + 4KB 页脏位图：每 commit 应用 store（magic 已有
  apply_commit 基础，扩为内存视图）。
- checkpoint 链：`base.seq=0 全量` → `diff.seq=300k` → `diff.seq=600k`
  …；保留策略：最近 1 个全量 + 最近 5 个差分（脚本 CKPT_KEEP 参数）。
- 恢复：QEMU `lcvex-ckpt-load`（或 -incoming 恢复 base 再应用 diff 由
  协调器驱动）+ DUT 灌注（RTL 注入口，见 043 遗留：Verilator 5.050
  conda 版 public 注释语法不可用，改走显式 ckpt 写端口方案）。
- 失败现场：dump-on-error 默认保留最近 checkpoint 链 + step_fail.txt。

## 执行顺序

1. savevm 接口最小实验：fork HMP `lcvex-ckpt-save/load` + 小镜像闭环
   （保存→load→继续运行 seq 衔接）。
2. 协调器内存影子 + 差分文件格式 + CKPT_KEEP 策略（`--diff-ckpt`）。
3. 集成验证：全量 base + 3 个 diff → 恢复 → 快进到分叉点附近再锁步。
4. 后续：RTL ckpt 注入口（DUT 恢复）与 PAR_EL1/AT 修复并行。

## 现状（2026-08-24）

> 本文是差分 checkpoint 设计基线；Linux 锁步后续进展见 handoff 048。

- 全量 checkpoint 已可用：每 N 条 OK 提交触发 QEMU migrate（轮询
  completed + 保留最近 3 个 + 目录落磁盘），验证进行中。
- tmpfs 已清理（042 kernel_boot*.trace 迁磁盘归档）。
- 内核锁步已推进到 14M；本轮另关闭 RBIT 缺口。差分 checkpoint 仍未
  实现，不能把当前全量 gzip 文件当作增量链恢复输入。

后续实施边界与恢复验收见 handoff 050；在 L1-L3 小镜像闭环完成前，Linux
长跑继续保持 `CKPT_EVERY=0`，避免产生无法恢复的伪 checkpoint。
