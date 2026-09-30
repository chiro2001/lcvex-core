# T-20260829-086 C2 双核共享 L2 目录式 MSI（owner handoff）

状态：**owner active（系统接线完成；真实双核 message passing 已通过，CAS/barrier 等仍在继续）**。

```text
task=T-20260829-086 state=active base=c1273235028a54f2d8213a9c8ca0040ff0def609 head=c4931b0a40298cbe35296051c7096f991b6b2b9f branch=feature/T-20260829-086-c2-dualcore-msi worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-086 sent_at=2026-08-29T06:46:00+0800 received_at=2026-08-29T06:46:00+0800 reported_at=2026-08-29T10:40:00+0800 files=rtl/lcvex_cluster_pkg.sv,rtl/lcvex_l2_cluster.sv,rtl/lcvex_l1_coherence.sv,rtl/lcvex_core_wrap.sv,rtl/lcvex_cluster_top.sv,tb/sv/lcvex_c2_cluster_tb.sv,tb/sv/lcvex_c2_l1_msi_tb.sv,tb/sv/lcvex_c2_dualcore_tb.sv,docs/handoffs/T-20260829-086-c2-dualcore-msi.md,docs/tasks/evidence/T-20260829-086.json tests=cluster-module-TB-PASS,L1-plus-cluster-msi-TB-PASS,dualcore-message-passing-TB-PASS blockers=none next=add-CAS-barrier-litmus-dcic
```

## 续：C2 系统接线（系统级 RTL 已接入，真实双核 message passing 已跑通）

- 新增 `lcvex_c2_l1_coherent`：per-core 统一直连缓存，把 M1-B 请求转换为
  C2 line-level 命令；支持 dirty eviction、S 写命中 Upgrade、probe
  clean/invalidate 和 bypass。
- `lcvex_core_wrap` 新增 `COHERENCE_ENABLE` 参数：默认关闭时保持原 C1 私有
  RAM 路径；开启时把 core arb 接入 L1 → cluster。
- `lcvex_cluster_top` 新增 `COHERENCE_ENABLE` 参数：开启时实例化共享
  `lcvex_l2_cluster` + 共享 `lcvex_mem_ram`，并逐核连接 L1/coherence 端口；
  C2 模式下 per-core reset PC 偏移 0x100，便于双核独立程序。
- 新增 `tb/sv/lcvex_c2_l1_msi_tb.sv`：快速 L1+cluster 集成测试，已验证
  dirty owner 数据跨核传递、失效后 refill、bypass 写 PoC。
  结果：`LCVEX_C2_L1_MSI_TB PASS`。
- 新增 `tb/sv/lcvex_c2_dualcore_tb.sv`：真实双核 message-passing 程序 TB，
  已跑通：`LCVEX_C2_DUALCORE_TB PASS`（core0/core1 均读出 flag=0x5a，无 fault，
  双核在共享 coherent 内存上完成同步）。默认优化版与 O0 版均通过。
- 修复：L1 直接映射 dirty eviction 的 victim tag 保存、读/写命中使用当前请求偏移、
  cluster 在接受新请求时用新 line index 读取旧目录状态（避免旧 cur_idx 串行错位），
  以及 ReadShared 从 I 写入时不保留陈旧 sharer 位。
- 尚未运行：真实双核 instruction-level litmus、CAS/LDXR-STXR、barrier、
  DC clean + IC invalidate + ISB、reset/fault 的完整指令级证据。

## 此前模块级结论（保留）

- 在共享 L2 上游新增 C2 目录式 MSI 模块级实现 `rtl/lcvex_l2_cluster.sv`。
- 支持目录 `I/S/M`、`ReadShared/ReadUnique/Upgrade/WriteBack/Clean/
  Clean+Invalidate/Invalidate/Bypass`、每核 probe、dirty owner 下刷、
  PoC fault/abort 回滚、round-robin 单事务仲裁。
- 新增 `lcvex_cluster_pkg.sv` 中的 line-level 协议类型和 probe 命令常量，
  不修改 `lcvex_pkg` 既有 `mem_req_t/mem_rsp_t/commit_packet_t`。
- 新增 `tb/sv/lcvex_c2_cluster_tb.sv` 定向 SV TB，用两个 synthetic coherent
  L1 client 覆盖目录状态迁移、读写传递、dirty owner 数据、Upgrade 失效、
  WriteBack/Clean、bypass、PoC writeback fault 和 reset。
- C2 未接真实 `lcvex_core`/`lcvex_core_wrap`/`lcvex_cluster_top`；本任务是
  C2 目录/协议正确性的模块级 L0/L1 切片，后续 C3/系统接线需在独立集成任务完成。
- 未修改 `rtl/filelist.f`、`Makefile`、QEMU/checkpoint 共享热点。
- 不实现 ACE/CHI、E/O、4 核扩展、coherent DMA、Linux SMP，也不宣称完整 ARM
  memory model。

## 实现文件

- `rtl/lcvex_cluster_pkg.sv`：新增 COH 命令/请求/响应/状态类型和 probe 编码。
- `rtl/lcvex_l2_cluster.sv`：目录状态机、每核请求/响应、每核 probe、
  PoC M1-B 8B 端口、目录不变式 SVA、fault/abort 处理。
- `rtl/lcvex_l1_coherence.sv`：保留原单核 B4 wrapper，新增
  `lcvex_c2_l1_coherent` per-core 统一直连缓存。
- `rtl/lcvex_core_wrap.sv`、`rtl/lcvex_cluster_top.sv`：新增
  `COHERENCE_ENABLE` 系统接线路径，默认关闭保持 C1 私有 RAM。
- `tb/sv/lcvex_c2_cluster_tb.sv`：双核合成 L1 client + PoC BFM 定向测试。
- `tb/sv/lcvex_c2_l1_msi_tb.sv`：L1+cluster 快速系统边界集成测试。
- `tb/sv/lcvex_c2_dualcore_tb.sv`：真实双核 message-passing TB（O0 build 已 PASS）。

## 目录/协议要点

- 目录为 line-indexed metadata（不含数据阵列），数据源为 PoC 或 dirty owner
  probe 返回值；PoC 保持现有 8B M1-B。
- `M ⇒ owner 唯一 && sharers==owner && dirty=1`；`S ⇒ sharers!=0 &&
  owner=0 && dirty=0`；`I ⇒ sharers=0 && owner=0 && dirty=0`；SVA 已在
  `lcvex_l2_cluster.sv` 中按行检查。
- `ReadShared` 从 M owner 取数时先 `clean+invalidate` probe，8-beat 写回 PoC
  成功后才释放 probe response，随后旧 owner 失效、请求者进入 S。
- `ReadUnique/Upgrade` 会先使其它 sharer/owner 失效；fault 时不会产生新的
  M owner，也不会发出 stale success response。
- 仲裁为全局单事务、round-robin，且有 liveness fallback：指针核无请求时
  选择下一个有效请求核。

## 本轮默认优化构建

- 已 cherry-pick 主线 FP scalar Verilator 优化修复（`0288e25`，
  `fp: rewrite FP scalar op dispatch as if/else to avoid Verilator case blowup`）。
- 默认优化（不带 `-O0`）构建 `lcvex_c2_dualcore_tb` 在约 226s 完成并运行通过：
  `LCVEX_C2_DUALCORE_TB PASS`。
- 因此不再依赖 `-O0`/UNOPTFLAT 组合环运行该双核 TB。

## 验证摘要

- `git diff --check`：通过。
- `verilator --lint-only --no-assert --no-timing --top-module lcvex_l2_cluster -GCORE_COUNT=2 -GMEM_LINES=16 rtl/lcvex_pkg.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv`：通过。
- `verilator --lint-only --no-assert --no-timing --top-module lcvex_l2_cluster -GCORE_COUNT=1 -GMEM_LINES=16 ...`：通过。
- `verilator --binary --timing --assert ... --top-module lcvex_c2_cluster_tb` 后运行：
  `LCVEX_C2_CLUSTER_TB PASS`。
- `verilator --binary --timing --assert ... --top-module lcvex_c2_l1_msi_tb` 后运行：
  `LCVEX_C2_L1_MSI_TB PASS`（L1+cluster 系统边界，dirty 数据跨核、失效 refill、bypass）。
- `lcvex_c2_dualcore_tb` 使用 O0 Verilator build 运行通过：
  `LCVEX_C2_DUALCORE_TB PASS`；覆盖真实双核共享 coherent 内存 message passing、
  双核读 flag=0x5a、无 fault、双核各自完成同步。
- 定向 TB 覆盖：ReadShared I->S/S->SS、Upgrade 失效其它 sharer、
  ReadUnique 转移 dirty owner 并写回 PoC、message passing（dirty 数据跨核可见）、
  WriteBack/Clean、bypass、PoC writeback fault 不产生新 M、reset 清目录。
- 未运行完整 Gate D；本任务只做 L0/L1。

## 已知限制 / 未覆盖

1. 系统级 RTL 已接入 `lcvex_core_wrap`/`lcvex_cluster_top`，`lcvex_c2_l1_msi_tb`
   通过；但真实双核 `lcvex_c2_dualcore_tb` 的完整 Verilator build 未完成，
   因此还没有真实双核指令级 litmus、CAS/LDXR-STXR、DMB/DSB/ISB 和
   self-modifying code 的通过证据。
2. 未修改 `lcvex_core.sv` 的 per-core MPIDR/exclusive monitor；`COHERENCE_ENABLE=0`
   仍走原 C1 私有 RAM 路径。
3. 目录表按 `MEM_LINES` 有限行索引；本文不声称完整物理地址空间或无限 tag。
4. 没有实现 E/O、ACE/CHI、coherent DMA、4 核、TLB shootdown、Linux SMP。
5. 没有声明完整 ARM memory model；store/load buffering 只作为后续 litmus 的
   目录线性化基础。
6. C1/`CORE_COUNT=1` 未重跑完整 C1 shell lint/TB（本任务未改动 C1 壳层
   RTL，且完整 C1 lint 耗时长）；新增 package 类型为 additive。

## 下一步

1. 在独立/后台资源中完成 `lcvex_c2_dualcore_tb` 的 Verilator binary build
   （双完整 `lcvex_core` 耗时/内存较大，需避开本轻量会话）。
2. 跑通真实双核 message passing，然后追加 CAS/LDXR-STXR、store/load
   buffering、DMB/DSB/ISB、DC clean + IC invalidate + ISB、reset/fault
   的指令级定向证据。
3. 完成后再回写 handoff/evidence 为 review/done。
4. 若进入 C3，再扩展四核仲裁/位图、IPI/SEV 广播、TLB shootdown 和
   GIC/PSCI。
