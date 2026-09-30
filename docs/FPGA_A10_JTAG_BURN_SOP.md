# FPGA_A10_JTAG_BURN_SOP：LCVEX Catapult A10 JTAG 烧写标准作业程序

> 初始任务：T-20260902-002（A10-JTAG-BURN-REVIEW）；当前修订：T-20260920-040。
> 状态：**LCVEX 易失 SOF 与 JTAG-UART 真板路径已验证**。T-20260920-037 已完成
> `LCVEX25 BOOT/READY/?/PONG/RXDBG/Z`，T-20260920-038 已独立恢复并证明 exact
> golden。本 SOP 只覆盖易失配置；JIC/EPCQ/Flash 仍未授权、未验证。
> 读源：`/home/chiro/projects/a10-linux-riscv@3db828e74651fda377a33d84f2a2ca0e69901d72`（clean）、LCVEX `fpga/catapult_a10/**`、`docs/FPGA_A10_EXECUTION_PREFLIGHT.md`，以及远端只读工具/自建 server 目录。

## 0. 快速结论与使用提醒

1. 参考项目 a10-linux-riscv 的**真机验证路径是 SOF 直接 JTAG 配置**，不是 JIC/EPCQ 写入。
   - 出处：`docs/04-交接-软件链QEMU门全绿与cleanroom软件复现-20260826.md` §8.2 第 185-198 行；`AGENTS.md` 第 35-36、49-50 行。
2. 该路径使用**自建 jtagserver**：`D:\Projects\fpga-altra\jtag-30mhz` 中的 Quartus `jtagserver.exe` + 自定义 MBFTDI DLL，通过 TCP `127.0.0.1:1310` 提供 `MBFTDI-Blaster v2.1b (64)` 电缆，再运行 `quartus_pgm`。
3. 该自建 server 不是 Quartus 默认安装内容，而是 Marsohod `jtag_hw_mbftdi_blaster` 开源 Quartus DLL 驱动源码的 Windows 构建产物；在远端以 `jtag_hw_microsoft_catapult.dll` 名字与 `jtagserver.exe` 同目录自包含运行。
4. `jtagconfig` 的 `10AT115S(1|2)` 显示文本与 QSF `10AX115N4F40E3SG` 的关系已在
   实际交易中用 JTAG ID `0x02E060DD`、SOF checksum/hash 和 programmer 成功条件闭合；
   每个新 candidate 仍必须重新冻结这些身份，不能只匹配显示文本。
5. 历史 T-20260902-002 只读调研没有上板；实际 LCVEX 交易及失败/恢复经验以
   T-20260920-031～038 evidence/handoff 和本 SOP §8 为准。

## 1. 概念：jtag-30mhz / MBFTDI-Blaster 是什么、来自哪里

### 1.1 名词

- **jtag-30mhz**：远端自建 JTAG server 工作目录名（`D:\Projects\fpga-altra\jtag-30mhz`）。目录内不是单个烧写器，而是：
  - `jtagserver.exe`（Quartus Prime Pro 21.4 原版，457,120 B，SHA-256 `72562A0193AA2B4C0B6332256453F9F337AC61FB18CDAC8895F30706228314EE`）；
  - `jtag_client.dll`（Quartus 客户端组件，SHA-256 `A987A40EBB2630C4F5296E86373484769E9D87F26FBBDDA3F26CE9E940BE1969`）；
  - `jtag_hw_microsoft_catapult.dll`（**自定义 MBFTDI 驱动**，229,376 B，SHA-256 `B7FE801AE91C50BD7EA159EA905D732A0B13ADA9F7791B85384A6DC8167092F6`；另存原始官方 `jtag_hw_microsoft_catapult.dll.orig` 237,568 B，SHA-256 `E8AC5BA4170AAC6ED0B6478A8ACF3BB4516ED6771277C28FD62FCBE03C6CE24F`）；
  - `msftdi.cfg`（channel/frequency 配置，当前 `channel=0` / `frequency=15000000`，SHA-256 `36580939AB36D1B38A3A118C54B49529484B352B00D004F94FE0F7C8445F15EF`）；
  - `client.conf`（Quartus JTAG client 指向 `127.0.0.1:1310`，SHA-256 `850870F8867409ED2917275F1150192EB36D66B3ABF5F2EA00F74C09EB62BDEB`）；
  - `test-30mhz.ps1`（启动/校验/可选烧写脚本，SHA-256 `E413D06AA1B0DE75DCF92134DE490AF2015BC131B255E85B5A400673EFA25B3E`）；
  - `burn.log`（真实烧录日志，SHA-256 `B0311D71ABBC3555B4F8B1414AF765457D7DB87E500C8A6912FBA1F03E10E4DB`）。
- **MBFTDI-Blaster v2.1b (64)**：自定义 DLL 对 Quartus 暴露的电缆名。源码头文件定义 `PROGRAMER_NAME "MBFTDI-Blaster v2.1b"`、设备名 `MBUSB-0`，支持 FT232H/FT2232/FT4232；并明确注释 FT232H 可为 “Microsoft Catapult debug dongle”（VID/PID `0x0403/0x6014`）。
- **MBFTDI**：基于 FTDI MPSSE 的 JTAG 编程器驱动，开源项目见远端 `D:\Projects\fpga-altra\jtag_hw_mbftdi_blaster`（或同一内容的 zip `jtag_hw_mbftdi_blaster.zip`）。项目 readme 声明来源：Marsohod MBFTDI JTAG programmer（`https://marsohod.org/prodmbftdi`），Windows 用 VS2019 构建出 `jtag_hw_mbftdi_blaster64.dll`，放入 Quartus `bin64` 后被 `jtagserver.exe` 加载。

### 1.2 关键实现细节（来自只读源码）

- `jtag_hw_mbftdi_blaster_src/jtag_hw_mbftdi_blaster.h` 第 11、25-26、41 行：cable 名 / FT232H（Catapult debug dongle）VIDPID / 设备名。
- `jtag_hw_mbftdi_blaster.cpp` 第 28-31、57、73-78、335-380、841-846 行：
  - DLL 从自身所在目录读取 `msftdi.cfg`（第 57 行），支持 `channel`（FT232H 固定 channel 0）和 `frequency`（合法范围 `1000..30000000` Hz，默认 10 MHz；当前 15 MHz）。
  - `configure()` 中把 `msftdi.cfg` 的 frequency 应用到 FTDI MPSSE TCK。
- 因此“MBFTDI-Blaster”在 LCVEX 语境下是**通过板载/调试 FTDI 通道仿真出的 Altera 烧写电缆**，不是物理 USB-Blaster。

## 2. 前置身份确认与冻结

### 2.1 必须人工/宿主确认的身份项

1. 板卡实际是 Microsoft Catapult v3 / Mg Catapult，物理标记与参考基线 `10AXF40GAA`（参考 `docs/01-...` 第 27-39 行）一致；不得用历史 `10AXF40GAE` 等字符串替代。
2. `jtagconfig` 当前读到的 JTAG ID 应为 `0x02E060DD`；设备文本为 `10AT115S(1|2)`，而 Quartus QSF `DEVICE` 为 `10AX115N4F40E3SG`。该文本差必须由人有机关闭/记录，未确认前禁止编程（preflight 第 109、153-156、194-195 行）。
3. 确认要使用哪条 cable/接口：
   - **编程**：自建 MBFTDI server 的 `MBFTDI-Blaster v2.1b (64)`（`127.0.0.1:1310`）；
   - **JTAG-UART 控制台**：参考路径使用 `JTAG-MPSSE-Blaster`（不是 MBFTDI 电缆），且通常需先停掉自建 jtagserver 释放 FTDI 通道（a10 §8.2 第 187-189 行）。
4. 确认当前没有其他 Quartus/编程会话占用同一 FTDI；按 a10 `AGENTS.md` 第 66-68 行，禁止按进程名批量杀 `jtagserver*`，只允许停止本次启动并记录过 PID 的进程。

### 2.2 工具路径与版本（远端只读确认，2026-09-02）

| 工具 | 远端路径 | SHA-256 |
|---|---|---|
| Quartus jtagserver | `D:\Software\intelFPGA_pro\21.4\quartus\bin64\jtagserver.exe` | `72562A...`（与 jtag-30mhz 内相同） |
| jtagconfig | `D:\Software\intelFPGA_pro\21.4\quartus\bin64\jtagconfig.exe` | `BBE3E525...` |
| quartus_pgm | `D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_pgm.exe` | `B5D5A4C3...` |
| nios2-terminal | `D:\Software\intelFPGA_pro\21.4\quartus\bin64\nios2-terminal.exe` | `E5FACE86...` |
| quartus_cpf | `D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_cpf.exe` | `218E1E04...` |

Quartus 版本：`21.4.0 Build 67 12/06/2021 SC Pro Edition`（preflight 第 140-141 行）。

### 2.3 链确认命令

（1）普通只读枚举（参考 preflight 实际执行）：

```powershell
& 'D:\Software\intelFPGA_pro\21.4\quartus\bin64\jtagconfig.exe'
```

预期（2026-08-31 preflight，第 153-155 行）：

```text
1) JTAG-MPSSE-Blaster [00 Single RS232-HS (0403:6014)]
2) Microsoft Catapult (64) [USB-0]
02E060DD 10AT115S(1|2)
02E060DD 10AT115S(1|2)
```

（2）使用自建 server 时，让 `jtagconfig`/`quartus_pgm` 作为客户端连接，不启动本地 server：

```powershell
$client = 'D:\Projects\fpga-altra\jtag-30mhz\client.conf'
$env:QUARTUS_JTAG_CLIENT_CONFIG = $client
$env:QUARTUS_JTAG_CLIENT_NO_LOCAL_SERVER = '1'
& 'D:\Software\intelFPGA_pro\21.4\quartus\bin64\jtagconfig.exe'
```

参考出处：`test-30mhz.ps1` 第 14-15 行设置这两个环境变量；`client.conf` 第 1-5 行指向 `127.0.0.1:1310`。

（3）`quartus_pgm -l` 是列出可用编程电缆的常见 Quartus 命令。**本任务未执行**，且参考项目中未见可直接引用的 `-l` 输出；LCVEX 首次实测时应记录输出并冻结。不要把它当作已验证命令。

## 3. 自建 jtag server 的启动、校验与停止

### 3.1 推荐启动方式（参考脚本）

直接运行远端已有脚本，或拆分执行。以下为关键参数，出处 `test-30mhz.ps1` 第 9-30、33-44 行：

```powershell
# 工作目录必须是自包含 server 目录（DLL 从这里加载 msftdi.cfg）
$wd = 'D:\Projects\fpga-altra\jtag-30mhz'
$q  = 'D:\Software\intelFPGA_pro\21.4\quartus\bin64'

# 先写频率配置（FT232H 只接受 channel=0）
[System.IO.File]::WriteAllText("$wd\msftdi.cfg", "channel=0`nfrequency=15000000`n")

# 客户端配置
$env:QUARTUS_JTAG_CLIENT_CONFIG = "$wd\client.conf"
$env:QUARTUS_JTAG_CLIENT_NO_LOCAL_SERVER = '1'

# 启动自建 jtagserver（记录 PID；不要用进程名批量杀）
$server = Start-Process -FilePath "$wd\jtagserver.exe" `
    -ArgumentList '--foreground','--no-config','--port','1310','--port-file','port.txt' `
    -WorkingDirectory $wd -WindowStyle Hidden -PassThru
$server.Id
```

要点：

- **端口**：`--port 1310`（`client.conf` 的 `Host="127.0.0.1:1310"`）。
- **模式**：`--foreground`、`--no-config`、`--port-file port.txt` 是脚本中使用的参数；`port.txt` 当前内容为 `1`，脚本同时显式给 `--port 1310`，以脚本为准。
- **DLL 加载目录**：`jtagserver.exe` 从自身/工作目录加载 `jtag_hw_microsoft_catapult.dll` 和读取 `msftdi.cfg`，因此必须保持 `-WorkingDirectory $wd`，不要从别处复制单个 exe 运行。
- **频率**：参考验证中 `msftdi.cfg` 为 `15000000`（15 MHz）。虽然目录名是“30MHz”，且测试脚本默认 `-Frequency 30000000`，但 a10 §8.2 记录的是 **15MHz jtagserver**；LCVEX 初次建议沿用 15 MHz，待实测后再评估 30 MHz。
- **不要修改 Quartus bin64**：当前官方驱动仍是原版；自包含 server 路径不需要 `install_local_mbftdi.ps1`，也避免动全局 Quartus 安装。若未来要安装到 bin64，见 §3.4 警告。

### 3.2 启动后校验

```powershell
# 重试链识别（FTDI 抢占是瞬时的）
for ($i=1; $i -le 8; $i++) {
  $out = & "$q\jtagconfig.exe" 2>&1 | Out-String
  if ($out -match '02E060DD') { "chain OK try $i"; break }
  Start-Sleep -Seconds 2
}
```

参考 `test-30mhz.ps1` 第 33-44 行：判定条件是输出包含 JTAG ID `02E060DD`，失败则停止该 server 并退出。

也可以运行 `quartus_pgm -l` 确认看到 `MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310`（**待 LCVEX 实测确认**，参考没有保存 `-l` 输出）。

### 3.3 停止方式

只允许停止自己启动、记录了 PID 的 server：

```powershell
Stop-Process -Id <PID> -Force
```

禁止：

```powershell
Get-Process jtagserver | Stop-Process   # 违反 a10 AGENTS.md 第 66 行
Stop-Process -Name jtagserver -Force    # 禁止
```

参考脚本中 `test-30mhz.ps1` 第 17-20 行只按“可执行路径位于本工作区”过滤后停止，这是合规写法；a10 §8.2 也是在完成烧录后杀掉自己启动的 jtagserver 再读控制台。

### 3.4 不推荐：安装到 Quartus bin64

可行但需人工谨慎，且有风险：

- `install_local_mbftdi.ps1` 第 5、12-18 行会把自定义 DLL 覆盖到 `D:\Software\intelFPGA_pro\21.4\quartus\bin64\jtag_hw_microsoft_catapult.dll`，并写 `msftdi.cfg`。
- **警告**：该脚本第 7-9 行使用 `Get-Process jtagserver | Stop-Process -Force`，会按进程名杀掉所有 jtagserver，与 a10 `AGENTS.md` 第 66 行冲突；LCVEX 使用前必须改成只停记录的 PID。
- 该路径会改变全局 Quartus 安装，回滚依赖 `.orig` 备份；在并行工程场景风险高。**推荐优先使用 §3.1 自包含目录方案。**

## 4. SOF 直接 JTAG 配置（参考已验证路径）

这是 a10-linux-riscv 在真机上实际通过的主路径，只配置 FPGA SRAM，**不写 EPCQ Flash**。

### 4.1 命令

在自建 jtagserver 已启动、客户端环境变量已设置后：

```powershell
& 'D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_pgm.exe' `
  -c 'MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310' `
  -m JTAG `
  -o 'p;<绝对路径>\xxx.sof'
```

参考出处：

- a10 `docs/04` §8.2 第 187-189 行：`jtag-30mhz` 15MHz jtagserver（端口 1310）+ `quartus_pgm -c 'MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310' -m JTAG -o 'p;<sof>'`。
- 远端 `burn.log` 第 21-30 行：同款命令，实际烧录 48 秒、0 errors、JTAG ID `0x02E060DD`。
- 若 LCVEX 后续用脚本封装，可参考 `test-30mhz.ps1` 第 46-50 行（该脚本目前指向 `a10-jtag-uart.sof`，必须替换成 LCVEX 的 SOF 路径）。

### 4.2 已验证结果（参考项目）

| 项 | 证据 |
|---|---|
| Golden SOF `290AB3CF...` | 烧录 44s，0 errors；输出 OpenSBI、Linux、`Run /init as init process`（a10 `docs/04` 第 192-193 行） |
| fresh-clone SOF `2E3DD191...` | 同样烧录 44s；到 `Run /init as init process`（a10 `docs/04` 第 194-195 行） |
| 另一个早期 `burn.log` | `a10_ddr_io.sof`，48s，0 errors，注释 `10AXF40AA@1`（远端 burn.log 第 21-30 行） |

### 4.3 LCVEX 已验证身份与注意事项

- T-20260920-030 candidate：36,842,105 bytes，SHA-256
  `bb292699cced5ba988c20b852914c2478f6ef2e5385695e299558bbc582fd264`，checksum
  `0x315AC2B3`，design hash `0CC907F3DD48A9C78864E3C5BD66B9AF`。
- exact golden：36,844,906 bytes，SHA-256
  `290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92`，checksum
  `0x31510BB6`，design hash `193DE4BC8A30F3ED5F1F`。
- 上述 candidate 只对应已封存的 T-030 payload；新 firmware/MIF/RTL 必须生成新的
  content-addressed physical/assembler evidence，不能继续使用该身份。
- 当前 monitor marker 为 `LCVEX25 BOOT`、`CAL-*`、`DDR-*`、`READY`。启动期
  `CAL-WAIT/DDR-FAIL` 是允许的延迟校准路径；后续 `?` 显示 `CAL-OK` 时需用 `m`
  重跑 DDR 诊断，不能把旧状态直接解释为 DDR 硬件故障。

### 4.4 Flash 启动基线与标准 server 的 design hash

a10-linux-riscv 的已验证上电路径是 EPCQL1024 Flash 加载 VexRiscv/Linux；运行 LCVEX
一次 SOF 直接 JTAG 测试只会临时覆盖 FPGA 配置，不写 Flash。若用户/现场明确确认当前
板卡已从 Flash 启动该参考系统，可以把此确认登记为一次性 board task 的初始状态
attestation；不能把标准 `jtagconfig -n` 的 design hash 单独解释为 live image identity。

默认 board contract 仍要求 initial chain design hash 与 frozen golden SOF 相符。只有
T-053 固定的 corrected candidate/golden 身份允许使用
`initial_chain_policy=user_attested_flash_boot`：它仍检查 present-only FTDI 枚举、精确
cable/JTAG ID、JTAG UART/PHY 节点、SOF 文件 hash、EDA/port 冲突；只把初始标准 server
design hash 留作诊断。T-053 仍必须通过一次 candidate programmer transaction、唯一
`t/v/c` terminal session 和一次 final golden programmer + postflight，最终 exact golden
证明不能被用户 attestation 或缓存 hash 替代。其他 board task 不允许使用该例外。

## 5. EPCQ Flash 烧写 / JIC / RBF（未在参考项目真机验证，待 LCVEX 确认）

### 5.1 与 SOF 的区别

- **SOF 直接 JTAG 配置**：易失，掉电丢失；只把 bitstream 载入 FPGA。
- **JIC/RBF + EPCQ**：把配置位流和/或 Flash 数据写入 EPCQL1024；掉电后从 Flash 配置/启动。参考项目 a10 的 §8.1 规划了“helper SFL / JIC 烧到 EPCQL1024”，但**没有在已归档文档中记录一次成功的 JIC 真机写入**；a10 已记录的成功是 SOF 直接 JTAG 配置（§8.2）。因此 JIC 烧写必须标为【待 LCVEX 实测确认】。
- **RBF**：Raw Binary File 通常用于被动/串行配置或第三方烧码器；在 a10-linux-riscv 与 LCVEX 当前材料中未找到已验证的板级 RBF 生成/烧写路径。LCVEX 若需要 RBF，应作为独立未验证项，先确认目标接口与生成命令，不要沿用未引用的旧命令。

### 5.2 JIC 生成（已验证“能生成”，未验证“能烧板”）

参考 a10 工程中的 `hw/quartus/vex_soc_ddr/output_file.cof`（1-39 行）：

```xml
<eprom_name>EPCQL1024</eprom_name>
<flash_loader_device>10AX115N4</flash_loader_device>
<output_filename>output_file.jic</output_filename>
<sof_filename>output_files/vex_soc_ddr.sof</sof_filename>
<hex_filename>../../../build/software/flash_data.hex</hex_filename>
<hex_offset>1048576</hex_offset>
```

生成命令（a10 `scripts/reproduce_hardware.ps1` 第 50-52 行）：

```powershell
& 'D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_cpf.exe' -c output_file.cof
```

- 已生成项目内 JIC `0538BCC0EA4CE811D42EE54B348B159EDD112B197DC06F58964171C4F9DF20FB`（134,217,955 B，0 errors），证明编程管线可用（a10 `docs/04` 第 129-132、136-138 行）。
- 黄金 JIC `86EE77AD2E69AFEE7E5280B54C84D24821B1DA3838E8803D882AFBA272CC3196` 也是同一 CFG 管线产物（`AGENTS.md` 第 50 行）。
- **`convert_to_hex`**：在 a10-linux-riscv 和 LCVEX 当前仓库中未找到任何使用/调用证据。LCVEX 不要把“convert_to_hex”当作已验证命令；如需使用 Quartus 转换工具，请以 `quartus_cpf`/COF 的实测输出为准，并单独记录命令、版本和 exit code。

### 5.3 建议的 LCVEX JIC 烧写步骤（全部标为待实测）

前置：已有冻结 SOF、对应 `flash_data`/启动镜像、COF 指向正确工程内相对路径；已确认 cable/device identity；已有回滚方案（可重新烧写原 JIC/SOF 或使用 SFL helper）。

```powershell
# 1) 启动自建 server（同 §3.1）
# 2) 设置客户端环境变量（同 §3.1）
# 3) 列出/确认电缆（待实测）
& 'D:\...\quartus_pgm.exe' -l

# 4) 烧写 JIC（具体 -o 语法以 Quartus 21.4 Programmer 实测为准，下面为常见形式，待确认）
& 'D:\...\quartus_pgm.exe' `
  -c 'MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310' `
  -m JTAG `
  -o 'p;<绝对路径>\output_file.jic'
```

- 若需先烧 helper SFL（参考 a10 §8.1 第 165-166 行），也应单独立项；本 SOP 无已验证的 helper SFL 烧写命令。
- **绝不**在没有精确任务、目标确认、hash 冻结和人工批准时执行 EPCQ 擦写/覆盖配置区（preflight 第 236-238 行）。

### 5.4 LCVEX Linux 目标的 COF/JIC 与 golden 恢复包（2026-09-30 实测核对）

覆盖 Flash 前必须能够回到当前可启动的 VexRiscv/Linux 参考。两个参考文件在
GamePC 上仍然存在，本次已重新哈希核对：

| 项目 | GamePC 路径 | bytes | SHA-256 |
| --- | --- | ---: | --- |
| golden 参考 JIC | `D:\Projects\fpga-altra\a10-linux-riscv\dist\golden\output_file.jic` | 134217955 | `86ee77ad2e69afee7e5280b54c84d24821b1da3838e8803d882afba272cc3196` |
| golden 参考 SOF | `D:\Projects\fpga-altra\a10-linux-riscv\dist\golden\vex_soc_ddr.sof` | 36844906 | `290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92` |

LCVEX 目标 JIC 的生成链（全部在 `gamepc` 资源锁内执行）：

- `fpga/catapult_a10/boot/linux_flash_cof.py` 依据 layout 生成 COF；payload
  使用相对 Intel HEX，`hex_offset` 等于 `flash.payload_offset`（`0x04000000`），
  COF 只加一次偏移。
- `quartus_cpf -c linux_flash.cof` 生成 `lcvex_linux.jic`；`sof_filename`
  指向 Quartus 物理流程产出的 `catapult_a10.sof`。
- 目标 JIC 的 bytes/SHA-256 记录在
  `docs/tasks/evidence/T-20260928-002.json`。

如果目标 JIC 启动失败需要回滚，在同一个 gamepc 锁内执行（仍然是 Flash 擦写，
执行前重新核对上表哈希）：

```powershell
& 'D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_pgm.exe' `
  -c 'MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310' -m JTAG `
  -o 'p;D:/Projects/fpga-altra/a10-linux-riscv/dist/golden/output_file.jic'
```

## 6. JTAG-UART 控制台连接

### 6.1 参考已验证做法

a10 §8.2 第 187-189 行：烧录完成后**先杀掉自建 jtagserver**，再连接 `JTAG-MPSSE-Blaster` 读控制台：

```powershell
# 1) 停掉自己启动的 jtagserver（记录 PID）
Stop-Process -Id <serverPid> -Force
Start-Sleep -Seconds 1

# 2) 连接 JTAG-UART
& 'D:\Software\intelFPGA_pro\21.4\quartus\bin64\nios2-terminal.exe' `
  -c JTAG-MPSSE-Blaster `
  -i 0
```

参考 `scratc_bin64srv.ps1`（远端 `D:\Projects\fpga-altra\scratc_bin64srv.ps1`）也使用同样的 `-c JTAG-MPSSE-Blaster -i 0` 并捕获 30 秒。

### 6.2 LCVEX 控制台预期

LCVEX 的 JTAG-UART 在 `0x09000000`。易失配置后的已验证启动序列为：

```text
LCVEX25 BOOT
CAL-OK | CAL-WAIT | CAL-FAIL
DDR-OK | DDR-FAIL
READY
```

注意：`nios2-terminal` 通常需要释放 FTDI 通道，因此**编程 server 和 nios2-terminal 通常不能同时抢同一接口**；具体接口占用情况需在首次 LCVEX 实测时记录。

## 7. 上电/复位/超时/验证风险

### 7.1 上电与复位

- 确认板卡上电稳定后再连 server/编程；不要在 FTDI 枚举未完成时开始。
- CPU 从 BRAM 独立启动，EMIF calibration 未完成或失败也必须进入 `READY` 并保留
  JTAG-UART 诊断；DDR 请求在校准不可用时被阻止。`CAL-WAIT/DDR-FAIL/READY` 本身
  不是编程失败或 CPU hang。
- 复位/断电后，SOF 直接 JTAG 配置丢失；重新上电必须先重新烧 SOF（或使用已写好的 Flash 配置）。

### 7.2 超时与判定

- 参考烧录耗时：golden/fresh SOF 44s（a10 §8.2），burn.log 48s。LCVEX 首次建议用 5-10 分钟超时并记录 start/end。
- 如果 `quartus_pgm` 长时间卡在“Configuring device”，先检查 server 是否存活、`jtagconfig` 是否仍能看到 `02E060DD`、是否有其他进程占用 FTDI；**不要按进程名杀**。
- 控制台无输出不能单独判定 FPGA 死亡；LCVEX 的 boot 代码有 JTAG-UART marker，若连 marker 都没有，再查板卡供电、配置、cable/device 身份和 server 日志。
- 参考项目还指出内核把 JTAG UART 注册为 `ttyJ0` 而 boot 参数为 `ttyAL0`，导致用户态 HELLO 不上屏（a10 §8.2 第 200-203 行）。LCVEX 若运行 Linux，需核对 console= 设备名。

### 7.3 回滚

- **SOF 直接配置**：无持久化副作用；回滚 = 重新烧录已知良好 SOF（如 a10 golden `290AB3...`，或 LCVEX own previous good SOF）。
- **JIC/EPCQ**：破坏性。回滚需预先保留原 JIC/SOF/Flash 镜像 hash，并可重新烧写原 JIC 或烧 helper SFL。由于参考库没有已验证的 JIC 真机烧写记录，LCVEX 首次 Flash 写入必须作为独立、有人的授权任务。
- **自建 server/DLL**：如果安装了全局自定义 DLL，用 `.orig` 恢复；推荐不安装、只使用自包含目录，回滚即停止该 server，不影响 Quartus。

### 7.4 每个新 LCVEX candidate 上板前必须完成的确认清单（Gate）

- [ ] 工程侧：当前 AArch64/B5 candidate 的 source/QSF/SDC/MIF/fitted DB hash 已冻结，
      与 task contract 和 manifest 一致。
- [ ] 工具侧：Quartus 21.4 Build 67、`jtagconfig`/`quartus_pgm`/`nios2-terminal` 路径与 SHA-256 记录。
- [ ] 身份侧：人工确认板卡/电缆/FTDI 通道；解释 `10AT115S(1|2)` 与 QSF `10AX115N4F40E3SG`；确认 JTAG ID `0x02E060DD`。
- [ ] 文件侧：当前 LCVEX SOF 存在且 hash 已记录；若需 Flash/JIC，则 COF/JIC/flash 镜像 hash 已冻结。
- [ ] 进程侧：记录所有本任务启动进程 PID；禁止按进程名批量终止。
- [ ] 授权侧：用户对本任务的易失 candidate、terminal 和 golden 恢复授权仍在范围内；
      Flash/reset/power 不得由此推导。

## 8. 受 Git 管理的 sealed runner（T-20260920-040）

正式入口位于 `fpga/catapult_a10/tools/board_runner/`。九个 T-036 脚本先逐字节迁入
并核对历史 SHA，再参数化为由 `board-contract.json` 提供 candidate/golden、工具、
server、电缆和 terminal plan。contract 与所有执行脚本共同进入 SHA-256 seal；远端
先做 PowerShell AST 和 seal 验证，任何失败都在 preflight/hardware 之前停止。

本地无硬件门：

```sh
make b25-board-runner-check
```

正式执行必须使用 task-owned contract/root/output，并整体位于 `gamepc` 资源锁内：

```sh
/home/chiro/projects/.resource-locks/resource-lock run gamepc lcvex T-ID root -- \
  fpga/catapult_a10/tools/board_runner/run_board_once.sh \
  build/agents/T-ID/board-contract.json build/agents/T-ID/run final
```

关键经验：

1. preserved standard jtagserver 的 design hash 可能是 cached observation；candidate live
   identity 必须由成功 programmer transaction 加 candidate-unique startup/命令响应证明，
   golden live identity 必须由成功 golden transaction 加随后一次 chain 枚举证明。
2. PowerShell `Parser::ParseFile` 的 ref 参数必须显式使用 `Token[]`/`ParseError[]`；避免
   Generic.List 与 `@(...)` binder 歧义。
3. 每次 programmer 调用前以 `CreateNew` marker 防重入；wrapper 从封存的
   `program-result.json` 读取 invocation count，不从被 PowerShell 捕获的 stdout 猜测。
4. terminal 结束后按 contract 等待有限 quiescence 窗口，再执行唯一 golden 恢复；
   等待不是 retry。
5. 只允许停止 runner 自己启动并保存 PID 的 server；标准/未知进程永不停止。
6. runner 源码可复现不等于授权自动延续；每个硬件任务仍须有独立 task/contract、
   resource lock、准确 artifact hash 和安全边界。

## 9. 出处索引（主要）

| 内容 | 出处 |
|---|---|
| JTAG ID / SOF / JIC 黄金值 | a10 `AGENTS.md` 第 35-36、49-50 行 |
| 进程隔离禁止 | a10 `AGENTS.md` 第 64-68 行 |
| 真机 SOF 烧写路径 | a10 `docs/04` 第 185-198 行 |
| JIC 生成管线 | a10 `docs/04` 第 129-138 行；`scripts/reproduce_hardware.ps1` 第 50-61 行；`hw/quartus/vex_soc_ddr/output_file.cof` 第 1-39 行 |
| JIC/SFL/正式 SOF 规划 | a10 `docs/01` 第 233-252 行；`docs/04` 第 161-183 行 |
| device identity 风险 | LCVEX `docs/FPGA_A10_EXECUTION_PREFLIGHT.md` 第 109、153-156、194-195、216-217 行 |
| EPCQ/Flash 禁止随意写 | LCVEX `docs/FPGA_A10_EXECUTION_PREFLIGHT.md` 第 236-238 行 |
| LCVEX 地址/启动 marker | LCVEX `fpga/catapult_a10/boot/README.md` 第 3-16 行；`boot.S` 第 53-55 行；`ddr.S` 第 23-25 行 |
| 自建 server 启动/校验 | 远端 `D:\Projects\fpga-altra\jtag-30mhz\test-30mhz.ps1` 第 9-44 行 |
| MBFTDI 来源/驱动 | 远端 `D:\Projects\fpga-altra\jtag_hw_mbftdi_blaster\readme` 第 1-16、31-34 行；`jtag_hw_mbftdi_blaster_src\jtag_hw_mbftdi_blaster.h` 第 11、25-26、41 行 |
| 真实烧录日志 | 远端 `D:\Projects\fpga-altra\jtag-30mhz\burn.log` 第 19-34 行 |
