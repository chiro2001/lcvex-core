# T-20260826-006：strict root Linux lite/main 监控交接

日期：2026-08-26（Asia/Shanghai）  
证据：[T-20260826-006.json](../tasks/evidence/T-20260826-006.json)

## 结论

- QEMU plugin、\`lockstep-build-kernel-nofp\`、\`lockstep-build-kernel\` 和两个
  runner 的 \`bash -n\` 均通过；本任务未修改 RTL 或 QEMU fork。
- main 使用 \`/tmp/Image-t80000\`、\`max,has_el3=false,has_el2=false\`，PIN=1，
  从 reset 新建 strict root 链并完成 10,000 条（seq 0–9999）。manifest
  \`status/state=complete\`，\`read_manifest\` 通过，\`provenance.kind=root\`、
  \`global_seq_offset=0\`，TSV/artifact SHA 已回读。
- lite 的用户配置（INITRD 为空、默认 0x44000000/0x40080000）在 seq=4
  暴露 QEMU \`-kernel\` 实际 load address 与 DUT coordinator 不一致；现场保留在
  \`build/tmp/T-20260826-006/lite/\`，manifest 保持 pending。
- 按 handoff 080/081 的地址纠正（BOOT_DTB=0x44200000、BOOT_ENTRY=0x40200000）
  另建全新链，但在仍保持 INITRD 为空时 seq=0 暴露 QEMU FDT 仍位于
  0x44000000；现场保留在 \`build/tmp/T-20260826-006/lite-corrected/\`，也保持
  pending。handoff 081 将这两个地址与 lite initramfs 一起使用；该输入变体待
  集成者明确确认后再运行。
- 进一步以当前 QEMU 的实际 bootloader 行为为准，使用 INITRD 为空、
  BOOT_DTB=0x44000000、BOOT_ENTRY=0x40200000 的 lite 配置从头通过 10,000
  条；随后递归续跑 500,000 + 500,000 条，child manifest 的 global 保存点为
  509,999 和 1,009,999，parent SHA/offset 均回读通过。
- main strict root 10,000 条后递归续跑 500,000 + 500,000 条，global 保存点同为
  509,999/1,009,999；两线均使用 CKPT_EVERY=500000 自动 finalize。
- 再各续跑一个 500,000 child 窗口后，两线 global 保存点达到 **1,509,999**；
  每个 child 的 parent manifest SHA、global offset 与 artifact hash 均通过回读。
- 随后 lite/main 并行各运行 5,000,000 条（分别 PIN=0/1、单核 QEMU），
  两条链均退出 0；child local 最后 seq=4,999,999、global 保存点达到
  **6,509,999**，complete manifest 和 artifact 校验通过。
- 再次并行各运行 5,000,000 条，lite/main 均退出 0；strict child global 保存点
  达到 **11,509,999**，递归 parent/hash/offset 回读通过。

## 运行边界与现场

- 所有锁步作业均单核、无孤儿进程；main 观测峰值 RSS 约 167.4 MiB。任务
  checkpoint、日志和失败 dump 均在 worktree \`build/tmp/T-20260826-006/\`，
  没有使用新的系统 \`/tmp\` 输出。
- main 链：\`build/tmp/T-20260826-006/main/chain/\`；manifest SHA
  \`b780634bedf6c2e5888c4ea11edc87892752fc6973e4a1d9a6bd30a1665aaeba\`，TSV SHA
  \`2c26ada50fcf4c717b260c21195567a782a0b14cb030c9e746d18ab2ee9cfd82\`。
- lite 两条地址失败链不得作为 resume parent；正确配置的 strict root/child 链
  已完成并可作为后续输入。失败 pending manifest 仅用于复核现场。

## 下一步与限制

1. 当前 strict 链已达到每线约 11.51M 全局窗口；继续扩展前应先检查新窗口
   manifest/context 与资源峰值，不复用旧 init-only 链。
2. 任何长窗只作为 Gate E 候选证据，不宣称 Gate E 完成；PSCI reset/WFI/timeout
   或 MMU/取指分歧需按现场分类。
