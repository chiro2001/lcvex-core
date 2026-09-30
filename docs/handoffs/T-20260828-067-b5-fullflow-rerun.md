# Handoff T-20260828-067: B5 fullflow rerun（host 重启后重跑 Catapult A10 full flow + signoff STA）

## 元数据
- task: T-20260828-067
- owner: execution-agent
- date: 2026-08-29
- base_sha: 23218fb4
- head_sha: 344a8247792c55bdc36d59d8e13388450a068943
- branch: verify/T-20260828-067-b5-fullflow-rerun
- worktree: /home/chiro/projects/mycpu/lcvex-wt-T-20260828-067
- dependencies: T-064, T-065
- config/toolchain: Quartus Prime Pro 21.4 Build 67, 远端 Windows GamePC
- evidence: docs/tasks/evidence/T-20260828-067.json
- state: **blocked**

## 目标与边界
在宿主已重启、残留 Quartus 已清理、内存充足的远端 Windows 环境，对已合入 FPGA 线的
B5 SoC/Boot 工程执行 `quartus_sh --flow compile catapult_a10 -c catapult_a10`
完整 full flow + signoff STA，采集 fit/STA/SOF 证据。L2/L3/L4 不做，DDR March/板测不上板。

## 结果
**未取得 B5 新 fit/STA/SOF；任务 blocked。**

- L0 通过：SSH/pwsh 可达，远端无 `quartus_syn` 残留，工程存在，远端 RTL/QSF/SDC 与
  本地 344a824 工作树 SHA256 全部一致，Free 约 44 GB。
- 三次独立 full flow 均复现同一阻塞，且 `serv_req_info.txt` 记录 Quartus Synthesis
  内部 OOM：
  - 第一次：2026-08-28 23:01:40 启动，IP Generation 0 errors/0 warnings；
    Analysis & Synthesis 约 38 分钟后 CPU 冻结在约 2268s；serv_req 记录 OOM 76291 MB。
  - 第二次：2026-08-28 23:49:13 启动（强制停止第一次后），外部 `quartus_pgm` 已结束；
    约 40 分钟后 CPU 冻结在约 2356s；serv_req 记录 OOM 74962 MB。
  - 第三次：2026-08-29 00:40:15 启动（write_rule 放宽后），约 40 分钟后 CPU 冻结在
    2140.75s；serv_req 记录 OOM 75425 MB；按集成者指示保留现场未强杀。
- 挂起特征：`quartus_syn` 与 `quartus_sh` 线程均为 `Wait/ExecutionDelay`，CPU 不再增长；
  日志 0 errors，但 Quartus 服务请求文件显示 synthesis 进程实际达到约 75 GB 私有内存后
  发生内部 Out of Memory，随后进程挂起。未写出新 syn/flow/fit/sta/sof。
- 本轮没有可用的 fit summary、STA slack、Fmax、SOF 哈希；`output_files` 中仍是 T-064
  旧平台产物，不能当作 B5 证据。

## 验证证据
| Evidence run ID | 层级 | 结论/说明 |
| --- | --- | --- |
| owner-l0-connect-001 | L0 | SSH/资源/工程/残留检查通过 |
| owner-source-match-002 | L0 | 远端与本地 B5 源码/QSF/SDC 哈希一致 |
| owner-fullflow-b5l-001 | L3 | full flow blocked（Synthesis OOM/挂起，无 fit/STA/SOF） |
| owner-fullflow-b5l-002 | L3 | full flow blocked（Synthesis OOM/挂起，复现） |
| owner-fullflow-b5l-003 | L3 | full flow blocked（write_rule 放宽后仍复现 OOM/挂起，现场保留） |

精确命令、时间、日志路径见 evidence JSON。

## 失败现场/重现
- 执行命令：
  - `ssh 192.168.101.5 pwsh -NoProfile -NonInteractive -EncodedCommand <UTF-16LE base64>` 启动
  - 远端工作目录：`D:\Projects\fpga-altra\lcvex\quartus`
  - `D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_sh.exe --flow compile catapult_a10 -c catapult_a10`
- 日志：
  - `D:\Projects\fpga-altra\lcvex\build\T-20260828-067\fullflow_b5l.log`
  - `D:\Projects\fpga-altra\lcvex\build\T-20260828-067\fullflow_b5l.err.log`
  - `D:\Projects\fpga-altra\lcvex\build\T-20260828-067\fullflow_b5l_rerun.log`
  - `D:\Projects\fpga-altra\lcvex\build\T-20260828-067\fullflow_b5l_rerun.err.log`
  - `D:\Projects\fpga-altra\lcvex\build\T-20260828-067\fullflow_b5l_third.log`
  - `D:\Projects\fpga-altra\lcvex\build\T-20260828-067\fullflow_b5l_third.err.log`
- 服务请求证据：`D:\Projects\fpga-altra\lcvex\quartus\serv_req_info.txt` 中三次 OOM
  （76291 MB / 74962 MB / 75425 MB used）。
- 重复步骤：清理 Quartus 进程后重新执行上述 full flow；Synthesis 后期可复现 OOM 后挂起。

## 阻塞原因
Quartus Prime Pro 21.4 的 full flow 在 B5 SoC/Boot 工程 Synthesis 阶段三次可复现：
quartus_syn 私有内存达到约 75 GB 后内部 OOM（serv_req_info.txt），随后进程挂起
（线程 Wait/ExecutionDelay）。不是远端不可达、不是残留进程、不是源码语法错误；
根本上是该 B5 SoC 综合内存需求或 Quartus 21.4 对超大设计的处理限制/环境页大小限制。

## 已知限制与后续任务
- 未取得 B5 fit/STA/SOF，验收不通过。
- 不得将 T-064 旧 SOF/STA 当作 B5 结果。
- 下步建议见 evidence `recovery_steps`：增大内存/页文件后重试 → 分离
  `quartus_ipgenerate`/`quartus_syn` 定位 → 收集 runlog/serv_req/事件提交工具支持。
- 本轮未修改 QSF/SDC/RTL，未读取 license，未删除未知远端文件。
- Write-rule 已由集成者放宽，允许 Quartus 工程内部构建产物；第三次现场按指示保留
  （quartus_sh PID 36652 / quartus_syn PID 37916）。

## 集成说明
当前 blocked。三次尝试均在 Synthesis 达到约 75 GB 私有内存后内部 OOM 并挂起，需要
先解决内存/工具链问题（增大物理内存或页文件、减少综合规模、或 Quartus/设计排查），
在解决前不应再启动 full flow。第三次现场保留供诊断。
