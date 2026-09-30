# T-20260902-002 A10-JTAG-BURN-REVIEW：LCVEX Catapult A10 JTAG 烧写 SOP

```text
task=T-20260902-002 state=review
base=73897911a81aa8a8833a4d6d457f3e27a01e3c29
head=a943110629007645941b31cd7eed47d5d0787ea8
branch=docs/T-20260902-002-a10-jtag-burn-review
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-002
model=deepseek-v4-flash reasoning_effort=max
sent_at=2026-09-02T01:29:20+08:00
received_at=2026-09-02T01:30:00+08:00
reported_at=2026-09-02T01:41:10+08:00
```

## 结论

本任务只进行只读调研与文档产出，**没有启动 jtagserver、没有调用 quartus_pgm、没有烧写、没有上板、未修改 a10-linux-riscv**。

- 已产出完整 SOP：`docs/FPGA_A10_JTAG_BURN_SOP.md`。
- 参考项目 a10-linux-riscv 的真机成功路径明确为：
  `jtag-30mhz` 自建 jtagserver（端口 1310，15 MHz）+ `quartus_pgm -c 'MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310' -m JTAG -o 'p;<sof>'`，随后杀自建 server，用 `nios2-terminal -c JTAG-MPSSE-Blaster -i 0` 读控制台。
- 找到了自建 server 的远端实体与来源：
  `D:\Projects\fpga-altra\jtag-30mhz`（自包含 jtagserver.exe + 自定义 MBFTDI DLL + msftdi.cfg + client.conf + test-30mhz.ps1 + burn.log），自定义 DLL 来自 Marsohod `jtag_hw_mbftdi_blaster` 开源项目，构建后命名为 `jtag_hw_microsoft_catapult.dll`。
- **JTAG identity 仍未闭合**：`jtagconfig` 链显示 `02E060DD 10AT115S(1|2)`，与 QSF `10AX115N4F40E3SG` 不一致；LCVEX program 阶段在 preflight 中是 WAIT。
- **JIC/EPCQ 真机烧写没有参考项目成功记录**：a10 已验证的是 SOF 直接 JTAG 配置；JIC 仅验证了 `quartus_cpf -c output_file.cof` 能生成 JIC。LCVEX 首次 EPCQ 写入必须单独授权、冻结 hash、明确回滚。
- 远端当前 Quartus `bin64` 仍是原版 Microsoft Catapult 驱动（未安装自定义 DLL），因此推荐使用自包含 server 目录而不是全局安装脚本；安装脚本存在按进程名杀 jtagserver 的违规风险。

## 关键参考文件

- SOP：`docs/FPGA_A10_JTAG_BURN_SOP.md`
- 参考仓：`/home/chiro/projects/a10-linux-riscv@3db828e74651fda377a33d84f2a2ca0e69901d72`
  - `AGENTS.md` 第 35-36、49-50、64-68 行
  - `docs/04-交接-软件链QEMU门全绿与cleanroom软件复现-20260826.md` §8.2（第 185-198 行）
  - `scripts/reproduce_hardware.ps1` 第 50-61 行
  - `hw/quartus/vex_soc_ddr/output_file.cof` 第 1-39 行
- 远端只读实体：
  - `D:\Projects\fpga-altra\jtag-30mhz\test-30mhz.ps1`（启动参数/校验）
  - `D:\Projects\fpga-altra\jtag-30mhz\burn.log`（真实烧录日志：48s、0 errors、JTAG ID 0x02E060DD）
  - `D:\Projects\fpga-altra\jtag_hw_mbftdi_blaster\readme` 与源码（MBFTDI 来源）
- LCVEX：
  - `docs/FPGA_A10_EXECUTION_PREFLIGHT.md` 第 109、153-156、216-217、236-238 行
  - `fpga/catapult_a10/boot/README.md` 第 3-16 行；`boot.S` 第 53-55 行；`ddr.S` 第 23-25 行

## 下一步（给集成者/现场）

1. 人工/宿主确认板卡与 cable/device identity；冻结 `jtagconfig`/`quartus_pgm -l` 输出文本。
2. 先完成当前 LCVEX candidate 的 full flow/SOF 并冻结 SHA-256/输入 hash；program 前更新 preflight 的 WAIT 状态。
3. 在上板现场执行 SOP §3（自建 server 启停）、§4（SOF 直接 JTAG 配置，首个 LCVEX 实验建议仅 SOF、不写 Flash），并记录 server PID、耗时、退出码、控制台输出。
4. 若需要持久化/Flash/JIC，另立精确任务；本 SOP 对 JIC 的板级写入仅给出待实测框架，不视为已验证。
5. 任何停止动作只针对记录过 PID 的进程，禁止按进程名杀 `jtagserver*`/`quartus*`。

精确 hash、远端探测记录和出处见 `docs/tasks/evidence/T-20260902-002.json`。
