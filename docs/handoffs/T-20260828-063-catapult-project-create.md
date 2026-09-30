# T-20260828-063：Catapult Windows 命令行 Quartus 工程创建与 Qsys/IP 再生成

状态：**review（本任务已完成，待集成者审阅）**

时间：2026-08-28 Asia/Shanghai（00:41 – 01:02 执行，文档于 01:10 前后落盘）

## 摘要

在远端 Windows（GAMEPC，PowerShell 7.6.3）用户指定目录
`D:\Projects\fpga-altra\lcvex` 创建了可重生成的 Catapult A10 工程骨架，并打通了
Qsys/IP 再生成与 synthesis/fit/STA/assembler 全流程：

- 工程骨架：从仓库 `fpga/catapult_a10/` 拷贝 21 个文件（QPF/QSF/SDC/Qsys/IP/SFL/
  JTAG-UART/manifest/hash），远端 SHA256 与仓库 `SHA256SUMS` 完全一致。
- Qsys 再生成：`qsys-generate Qsys.qsys --synthesis=VERILOG --parallel=4` 退出码 0
  （00:43:10 → 00:44:00），生成 177 个文件，含 EMIF 子系统 24 模块/105 文件。
- IP 再生成：`quartus_ipgenerate catapult_a10 --generate_project_ip_files
  --synthesis=verilog --parallel=on --clear_ip_generation_dirs` 退出码 0，
  0 errors / 6 warnings（00:44:53 → 00:46:20），识别并再生成 5 个 IP（Qsys +
  4 个 .ip）。
- 遗留 `ip-generate.exe` 在该 Pro 安装中仅限 acdstest 资源（exit 3）；Pro 官方替代
  `quartus_ipgenerate` 工作正常。
- `flash/sfl/ip/sfl_sys/epcq.ip` 独立再生成成功（exit 0，6 模块/7 文件）；但仓库
  B0 包缺少 `sfl_sys.qsys`，完整 SFL 再生成仍缺输入（见“阻塞与下一步”）。
- 主工程 `catapult_a10` 按设计是“无顶层实体”的平台片段：dry-run 通过（5 个 flow
  任务），`-start ipgenerate -end synthesis` 退出码 3，错误为顶层实体
  `catapult_a10` 未定义，另有 1 个非致命 warning（`flash/sfl/synth/sfl_sys.v`
  缺失）。
- 为验证工具链，在 `build/T-20260828-063/smoke/` 建了 smoke 工程（顶层为仅测试用
  `lcvex_smoke_top`，实例化生成的 Qsys 并把 Avalon-MM 用户端口 Tie-off）：
  `quartus_sh --flow compile smoke_qsys` **退出码 0，全流程通过**（00:55:07 →
  01:01:58，6 分 51 秒）。

## 精确命令与退出码

### 1. 环境与工具探测

```text
ssh -o BatchMode=yes -o ConnectTimeout=10 192.168.101.5 pwsh -NoProfile -NonInteractive -EncodedCommand <UTF-16LE base64>
```

- 主机 GAMEPC，PowerShell 7.6.3 Core。
- `D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_sh.exe --version` →
  `Quartus Prime Shell Version 21.4.0 Build 67 12/06/2021 SC Pro Edition`，exit 0。
- `quartus_syn / quartus_fit / quartus_sta / quartus_ipgenerate` 均为
  21.4.0 Build 67，exit 0。
- `qsys-generate --help` exit 0；`ip-generate --help` exit 3（acdstest 限制）。
- license 路径存在性检查 `Test-Path` 为 True；**未读取 license 内容**。
- D 盘空闲 112.5 GB；24 核；总内存 61.6 GB、空闲 27.2 GB。

### 2. 创建工程骨架

```text
New-Item -ItemType Directory -Path D:\Projects\fpga-altra\lcvex\... (quartus/qsys/flash/jtag_uart/tools/build)
scp fpga/catapult_a10/{README.md,SHA256SUMS,platform_manifest.json,source.lock,quartus,qsys,flash,jtag_uart,tools} 192.168.101.5:D:/Projects/fpga-altra/lcvex/
```

远端 15 项平台 payload 哈希与仓库 `SHA256SUMS` 完全一致；provenance 清单保存于
`build/T-20260828-063/provenance/remote_sha256.txt`。

### 3. Qsys/IP 再生成

```text
D:\Software\intelFPGA_pro\21.4\qsys\bin\qsys-generate.exe D:\Projects\fpga-altra\lcvex\qsys\ddr4_bot\Qsys.qsys --synthesis=VERILOG --parallel=4
```

- exit 0，日志：`build/T-20260828-063/qsys-ip-regen/qsys_generate_Qsys.log`。
- 生成的 `qsys/ddr4_bot/Qsys/Qsys_bb.v`：3165 B，SHA256
  `083b56d54accaa99f66f1013f2a9d7e98721f35e7cdd5a19e88ec265a1a8f616`；
  与仓库基线 `91076193…`（3161 B）**内容一致、仅行尾/末尾空行不同**；与 T-057
  记录的 PoC Windows 原文件字节级一致。

```text
D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_ipgenerate.exe catapult_a10 --rev=catapult_a10 --generate_project_ip_files --synthesis=verilog --parallel=on --clear_ip_generation_dirs
```

- exit 0，0 errors / 6 warnings；日志：
  `build/T-20260828-063/qsys-ip-regen/quartus_ipgenerate_clear_project.log`。
- 单独 EPCQ：`--generate_ip_file --ip_file=../flash/sfl/ip/sfl_sys/epcq.ip`，
  exit 0（00:49:01 → 00:49:11）。

### 4. 主工程合成尝试

```text
quartus_sh --flow compile catapult_a10 -c catapult_a10 -print_only            # exit 0
quartus_sh --flow compile catapult_a10 -c catapult_a10 -start ipgenerate -end synthesis  # exit 3
```

- IP Generation 阶段成功；Analysis & Synthesis 失败：顶层实体 `catapult_a10`
  未定义（B0 片段有意无顶层，等待 LCVEX wrapper）。
- 日志：`build/T-20260828-063/qsys-ip-regen/quartus_sh_compile_to_synthesis.log`。

### 5. Smoke 工程（打通 synthesis/fit/STA/assembler）

```text
D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_sh.exe --flow compile smoke_qsys -c smoke_qsys
```

- 工程：`build/T-20260828-063/smoke/quartus/`（QPF/QSF/SDC + `../rtl/lcvex_smoke_top.v`）。
- **exit 0，0 errors / 10 warnings**，00:55:07 → 01:01:58。
- 日志：`build/T-20260828-063/smoke/smoke_compile_v3.log`。
- Fitter 摘要（`output_files/smoke_qsys.fit.summary`）：ALMs 4,413/427,200（1%），
  寄存器 8,538，引脚 133/826（16%），块 RAM 26/2,713（<1%），PLL 3/112。
- STA：0 errors / 1 warning（“Design is not fully constrained”，因 Avalon 用户
  端口在 smoke 中被 Tie-off）；EMIF 内部 setup/hold 全部正 slack；Fmax：
  clk_266_clk 476.64 MHz、clk_100_clk 1317.52/645.16 MHz（受最小脉宽限制）。
- 产物：`output_files/smoke_qsys.sof`（36,825,753 B，SHA256
  `ace39c87…`）、`.fit.rpt`、`.sta.rpt`、`.asm.rpt`、`.syn.rpt`。

## 远端目录结构（要点）

```text
D:\Projects\fpga-altra\lcvex\
├── quartus\            catapult_a10.{qpf,qsf,sdc} + 失败现场 output_files/
├── qsys\ddr4_bot\      Qsys.qsys、Qsys/（Qsys_bb.v、synth/Qsys.v、Qsys.qip）、ip/Qsys/*.ip + 生成目录
├── flash\sfl\          sfl_sys.qip/bb/inst、ip\sfl_sys\epcq.ip + epcq/ 生成目录
├── jtag_uart\          jtag_uart_std*.v
├── tools\              check_platform.py、regenerate_qsys.sh（provenance）
├── platform_manifest.json / source.lock / SHA256SUMS / README.md
└── build\T-20260828-063\  logs/、provenance/、qsys-ip-regen/、smoke/
```

全树：510 files / 165 dirs / 131,808,530 bytes（含 smoke db/生成物；不含 Git）。

## 阻塞与下一步

1. **主工程顶层缺失**（设计预期）：`catapult_a10` 无 `TOP_LEVEL_ENTITY`。下一步由
   LCVEX wrapper 任务提供顶层并在 QSF 中登记后，即可 `quartus_sh --flow compile
   catapult_a10` 全流程。
2. **SFL 再生成输入缺口**：仓库 B0 包没有 `flash/sfl/sfl_sys.qsys`，只有
   `epcq.ip` 与已生成 qip/bb/inst；完整 SFL 再生成需要补回该输入（T-052
   后续补录，建议保持 cleanroom 来源）。当前 `epcq.ip` 已单独生成。
3. **速度等级不一致**：manifest 记录 Qsys/system speed grade 2 与 EMIF/器件 E3
   grade 3 不一致；smoke STA 只证明路径可用，最终以真实 wrapper 的 STA 收口。
4. `ip-generate.exe` 受限（acdstest），后续统一使用 `quartus_ipgenerate` 与
   `qsys-generate`。
5. 可选整理：把 smoke 工程/脚本固化为仓库内 Windows 工具（本次按要求只保留
   handoff/evidence，smoke 文件留在远端）。

## 证据

- 精确命令/版本/退出码/日志/哈希：`docs/tasks/evidence/T-20260828-063.json`
- 远端 provenance：`build/T-20260828-063/provenance/remote_sha256.txt`、
  `generated_qsys_tree.sha256.txt`、`remote_artifacts.sha256.txt`
- 关键日志与报告均在 `D:\Projects\fpga-altra\lcvex\build\T-20260828-063\` 下
