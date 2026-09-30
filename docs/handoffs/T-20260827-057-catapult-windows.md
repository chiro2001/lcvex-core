# T-20260827-057：Catapult Windows/Quartus 环境调研

## 摘要

状态：blocked。SSH 到 `192.168.101.5` 成功，远程主机为 `GAMEPC`，PowerShell
为 `7.6.3 Core`；Quartus Prime Pro 固定根目录存在，`quartus_sh`、
`quartus_syn`、`quartus_sta`、`quartus_fit` 和 `quartus_asm` 均可启动并报告
21.4.0 Build 67。license 只做了固定路径存在性检查，未读取内容。

用户指定的 `D:\Projects\fpga-altra\lcvex` 不存在；对
`D:\Projects\fpga-altra` 的只读名称搜索也没有找到 `lcvex`。因此没有可盘点的
lcvex 顶层、QPF/QSF/SDC/Qsys/IP，也没有执行或生成 Windows 工程的 regenerate、
synthesis、fit/place-route 或 STA 报告。

仓库侧已有的 `fpga/catapult_a10/` B0 白名单包在本 worktree 通过平台检查、15
项 SHA256 校验、脚本语法和 `git diff --check`；这些结果仅证明仓库输入闭包，
不代表 Windows 工程或板级可综合。

## 边界

- 只在本 worktree 写入本 handoff 和对应 evidence；未修改 active task JSON、
  `TASKS.md`、`PROJECT_STATUS.md`、`ROADMAP.md`、Linux RTL、QEMU 或 P7 文件。
- `D:\Projects\fpga-altra` 下其他目录仅作只读参考。参考工程的 QSF 顶层为
  `vex_soc_ddr_top`，并含 VexRiscv/RISC-V PoC 引用，未收编、复制或执行。
- 未在缺失的 project root 下擅自创建工程、临时目录或生成物；没有 Windows
  build/report artifact 可交付。

## 风险

- 目标工程缺失是当前硬阻断，不能推断其器件、顶层、时钟/复位或工程引用。
- `qsys-generate` 可运行帮助但没有有效 `--version` 开关；`ip-generate` 在该
  Pro 安装中提示仅可用于 `acdstest resource`。固定路径工具可启动不等于目标
  工程已通过 license、生成、综合或时序。
- 仓库 B0 manifest 仍记录 Qsys/system speed grade 2 与 EMIF/器件 E3 speed
  grade 3 的不一致，必须在精确工程和工具环境中 regenerate 并由 STA 关闭。

## 下一步

由集成者或用户提供/恢复准确的 `D:\Projects\fpga-altra\lcvex` 工程路径和
访问权限后，在该目录内创建受控输出，先执行 Qsys/IP regenerate，再按绝对路径
运行 `quartus_sh` synthesis、fit/place-route 和 `quartus_sta`，保存报告及哈希。
在此之前不能解除本任务阻断，也不能把 sibling PoC 或仓库 B0 输入当作 lcvex
工程完成证据。

