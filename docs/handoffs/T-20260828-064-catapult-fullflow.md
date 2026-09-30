# T-20260828-064：Catapult A10 真实顶层 full flow / STA 与 SFL 输入补齐

状态：**review（本任务已完成，待集成者审阅）**

时间：2026-08-28 Asia/Shanghai（01:18 dispatch，01:52 – 02:10 执行 full flow，
文档于 02:14 前后落盘）

## 摘要

在 T-063 创建的远端 Quartus 工程上补齐 SFL/EPCQ 生成输入，并以真实顶层
`lcvex_catapult_a10_top` 跑通 **full compile + signoff STA**：

- SFL 输入补齐：从远端已验证工程 `a10-linux-riscv/hw/ip/sfl` 同步完整生成目录
  （39 个文件：顶层 qip/bb/inst/cmp/regmap/sopcinfo + `synth/sfl_sys.v` +
  `ip/sfl_sys/{clk,epcq,rst}` 组件输入与生成 HDL），QSF 改为 `QIP_FILE` +
  逐项显式引用 8 个生成 HDL（与权威工程一致的引用方式）。
- full flow：`quartus_sh --flow compile catapult_a10 -c catapult_a10`
  **exit 0**，0 errors / 68 warnings，02:02:55 → 02:10:06（约 7 分 11 秒）。
- Fitter：4,468 ALMs / 8,641 registers / 141 pins / 27 RAM blocks / 3 PLL。
- STA：0 errors；最差 setup +0.220 ns（EMIF core user clock，Slow 900mV
  100C）；最差 hold +0.017 ns（sys_clk_50，Fast 900mV 0C）；recovery/removal/
  min-pulse 全正；Fmax：sys_clk_50 213.49 MHz、clk_y3 499.25 MHz、EMIF core
  user clock 283.29 MHz（Slow corner）。
- DDR report：Address/Command、DQS Gating、Read Capture、Write、Write
  Levelling 全部正；Core setup +1.772 ns（Fast 900mV 0C）。
- SOF：`catapult_a10.sof`（36,842,105 B），SHA-256
  `04130f9d0cf8b42afe1fe56a428d6a6af0bdc9b510bf72fd00eccabe60896028`。

## 基线和提交

- base：096900b9aead7264a0dacdad4296a8970c7505b
- branch：feature/T-20260828-064-catapult-fullflow
- worktree：/home/chiro/projects/mycpu/lcvex-wt-T-20260828-064
- evidence：docs/tasks/evidence/T-20260828-064.json
- implementation head：见 git log（提交后由集成者复核）

## 已交付

- `fpga/catapult_a10/flash/sfl/`：从 4 个输入快照补齐为完整 39 文件生成输入
  （本地 LF 规范；远端编译使用同源 CRLF 权威目录）。
- `fpga/catapult_a10/quartus/catapult_a10.qsf`：SFL 引用从仅 `QIP_FILE` 扩展为
  `QIP_FILE` + 8 个生成 HDL（clk/rst/epcq 及其底层 EPCQ 控制器源）。
- `fpga/catapult_a10/quartus/catapult_a10.sdc`：CDC 约束从
  `set_clock_groups`（EMIF 时钟名在用户 SDC 读取时不可解析，被 Quartus 忽略）
  改为 reset_gate 两条同步器输入的寄存器级 `set_false_path`，真实 STA 确认
  时序全正。
- `platform_manifest.json` / `source.lock`：payload 文件集从 15 扩展到 50，
  qsf/sdc target 哈希与字节更新，SFL 新增 35 条来源与目标记录。
- `SHA256SUMS`：同步为 50 个 payload 文件的本地哈希。
- `tools/check_platform.py`：SDC anchor 更新为 `set_false_path` +
  `cal_success_sync_q[0]`。
- `skeleton_manifest.json` / `README.md`：锚点、已知限制与 T-064 full flow
  结果记录。

## 验证（精确命令、版本、日志与哈希见 evidence）

- `check_platform.py`：PLATFORM_CHECK_PASS files=50，exit 0。
- `check_skeleton.py`：SKELETON_CHECK_PASS files=5，exit 0（离线
  TOOLCHAIN_MISSING 报告为预期）。
- JSON 校验、`bash -n`、`git diff --check`、`sha256sum -c SHA256SUMS`：
  全部 exit 0。
- 远端 full flow（compile6）：exit 0，0 errors / 68 warnings，见
  `build/T-20260828-064/compile6.log` 与 `compile6_out/`。

## 过程中发现与处置

1. **QIP+QSYS 同名冲突**：首轮在 QSF 同时登记 `QIP_FILE` 与重建
   `sfl_sys.qsys` 触发 Error 19021（同名 IP 不能同时引用）且重建 qsys 生成的
   子模块（`sfl_sys_clk/epcq/rst`）无对应 `.ip`，synthesis 失败。
2. **重建 qsys 的 EPCQ 时钟校验**：用官方组件重建的 `sfl_sys.qsys` 把
   clock bridge 声明为 100 MHz，qsys-generate 对 EPCQ 报“最大输入时钟 25 MHz”
   失败。旧快照 `epcq.ip` 的 `clkFreq=0` 属于未推导时钟的生成上下文；最终
   采用与 `a10-linux-riscv` 权威工程一致、已经真实编译验证的完整生成目录，
   不引入新的 Qsys 重建/时钟修改。
3. **权威目录定位**：远端 `D:\Projects\fpga-altra\a10-linux-riscv\hw\ip\sfl`
   （及 `a10-linux/riscv/vex_soc_ddr/sfl_sys` 同源副本）包含 39 文件完整生成
   目录，且 `hw/quartus/vex_soc_ddr` 有 8/27 成功 fit/STA 产物，是最佳来源。
   同步后本地旧 4 个快照哈希与权威目录 LF 规范化版本完全一致（差异仅行尾）。
4. **SSH 会话杀子进程**：Windows OpenSSH 会话退出会终止其后代 Quartus 进程，
   因此 full flow 在单个 SSH 长会话内同步等待完成。
5. **STA CDC 违规**：首轮 STA 最差 setup -2.970 ns，DDR Core 也报负；根因是
   `set_clock_groups` 在用户 SDC 读取时找不到 EMIF 时钟（Quartus warning
   332174/332054，约束被忽略）。改为寄存器级 false path 后全正。

## 已知限制

- DDR March、板级校准与上板测试不在本任务范围；STA 为 signoff 报告，不代表
  板上 DDR 已校准。
- 9 个引脚无精确位置、48 个 HSSI RX/TX 未使用、CLKUSR 自动保留为 Quartus
  Critical Warning（非时序违规；CLKUSR 上 100 MHz 满足 100–125 MHz 要求）。
- 本地 SFL 生成文件做了 LF 规范化（同内容、仅行尾差异）；远端编译现场保留
  原始 CRLF 权威目录与备份。
- 重建 `sfl_sys.qsys` 尝试（build/T-20260828-064 内脚本/产物）因 EPCQ 时钟
  校验失败未采用；当前编译输入为权威完整生成目录，QSF 不再引用 `.qsys`。

## 下一步

- 集成者在合并 SHA 复跑受影响 L0（check_platform/check_skeleton/json/diff）并
  复核 evidence；如需 Gate D，可在冻结 candidate 的 detached worktree 复跑
  本地 L0（远端 full flow 已由本任务完成，不重复占资源）。
- B5 接线后接入 SoC/CPU 时，`reset_gate` 的 CDC false path 范围需随新跨域
  路径复核。
