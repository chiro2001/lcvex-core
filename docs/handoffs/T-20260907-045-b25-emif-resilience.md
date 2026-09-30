# T-20260907-045：B25 EMIF resilience 交接

```text
task=T-20260907-045 state=done
functional_base=fbec08af334fafc3f9aa7801399f409301c20618
dispatch_head=fc730d33adca5fd103cc634a0b2920c9da42ad1b
implementation_head=c660e13d2483f10d3e7592d7f3bc94d254247337
followup_head=6864e0ae21658a76aaab365cf06b65332f4beaf0
followup=production-default-timeout-4096-synchronized-cpu-reset-and-sva-epoch-split
branch=verify/T-20260907-045-b25-emif-resilience
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260907-045
received_at=2026-09-07T04:46:21+08:00
reported_at=2026-09-07T09:16:00+08:00
evidence=docs/tasks/evidence/T-20260907-045.json
```

## 结论

本 lane 已将 AXI4-to-Avalon EMIF 适配器从“后端无响应时无限等待/校准失败时丢事务”收敛为有界、可复现的错误协议：

- 新增 `AVALON_TIMEOUT_CYCLES` 参数。生产适配器默认 4096 个 `emif_clk` 周期；在
  266.666750 MHz EMIF user clock 下约为 15.36 us。Avalon 永久 `waitrequest`、已接受读却缺失 `readdatavalid` 均只产生一次 AXI `DECERR`。
- 独立 SV/Cocotb endpoint 显式使用 32 个 EMIF 周期，仅作为快速故障注入测试值；现有
  Qsys/平台资料与 BFM 没有给出 vendor EMIF 最坏 `waitrequest` 或
  `readdatavalid` latency 上界，因此不能据此证明生产默认 32 安全。
- 生产默认改为 4096 周期（约 15.36 us）；SV/Cocotb endpoint 仍显式传入 32，保持
  测试快速且不改变测试故障窗口。新增 `cpu_rst_emif_meta_q` →
  `cpu_rst_emif_sync_q` 两级 `emif_clk` 同步器（两级 power-up 值为 0，且不由
  `emif_rst_n` 清除），retention block 只使用第二级判断 CPU reset re-arm。
- `lcvex_axi4_avalon_sva` 现接收独立 CPU/EMIF reset：CPU reset 清空全部 checker
  状态；EMIF reset 只清空 `stalled_q` 与命令 hold 快照，保留
  `read_inflight_q` 以识别 late `readdatavalid`。命令已拉起且
  `waitrequest_n=0` 时的 EMIF-only reset 已有专门场景覆盖，无需关闭断言。
- 已接受的读在 timeout 或 EMIF-only reset 后进入 `EMIF_DRAIN`；迟到 `readdatavalid` 被消费但不写第二个 response。没有迟到响应时链路保持 poison，CPU 侧 READY 被阻塞，直到明确 CPU reset 重启 epoch。
- EMIF-only reset 不再复位 CPU transaction context；同步观察到 reset 后，处于 SEND/WAIT 的正常读写各返回一次 `DECERR`。校准失败同样返回 `DECERR`，不把失败伪装为 OKAY。
- BVALID/RVALID 进入 response state 后不再因后续 cal_fail 被撤回；ID、数据、RESP、RLAST 在 BREADY/RREADY 前保持稳定。
- `read_issued_q`/`emif_poisoned_q` 在 EMIF-only reset 中保留；它们在 CPU reset 采样为低时复位（reset 值 0），timeout counter reset 值为 0，response code reset 值沿用 `DECERR`。

## 修改文件

- `rtl/lcvex_axi4_avalon_adapter.sv`：timeout counter、DECERR packet、reset abort、late-response drain/poison、AXI response hold 和 timeout-aware SVA escape。
- `tb/sv/lcvex_axi4_avalon_bfm.sv`：缺失 `readdatavalid` 注入及跨 EMIF-only reset 保留 pending response/counters。
- `tb/sv/lcvex_axi4_avalon_tb.sv`：永久 wait、missing response/late drain、EMIF-only reset、held DECERR 与可配置 timeout 场景。
- `sim/cocotb/test_axi4_avalon.py`：更新原有 in-flight cal_fail 断言为 held DECERR，并新增 timeout、late response、reset epoch 测试。

## 验证

以下验证均在 task worktree 中执行；编译和仿真通过 `/home/chiro/projects/.resource-locks/resource-lock run local ...` 取得 `local`，`min_local_available_mib=4096`，Verilator 单线程，未使用系统 `/tmp`：

- L1 SV Verilator（endpoint timeout=32）：`PASS: B2 AXI4/Avalon SV regression writes=0 reads=0`，3 us 仿真完成。
- L1 Cocotb：7/7 通过，包含正常映射、cal_fail held DECERR、双 reset flush、bounded timeout/late drain（不同数据/ID）、AW/W 部分收集跨 reset、命令 stalled 时 EMIF-only reset/SVA split、EMIF-only reset/response hold 及不同地址 re-arm；4,616.01 ns 完成。
- `AVALON_TIMEOUT_CYCLES=1` Verilator lint：通过 dedicated generate 分支。
- 生产默认 `AVALON_TIMEOUT_CYCLES=4096` adapter-only lint：通过。
- follow-up 同步器/SVA reset split 修改后的 SV、Cocotb（7/7）和 `AVALON_TIMEOUT_CYCLES=1` lint：均通过。
- Python syntax 与 `git diff --check`：通过。

完整命令、source SHA、日志 hash、资源准入及文件 hash 见
`docs/tasks/evidence/T-20260907-045.json`。

## 边界与风险

本 lane 未运行 Quartus、fitter/STA、GamePC/JTAG、assembler/SOF、板级或 Linux 测试，也未修改 core、DDR bridge、QSF/SDC、时钟、QEMU 或 active task JSON。超时后已接受读若后端永不返回，链路按设计保持 poison；写在 Avalon 已接受后无法撤销外部副作用，但 CPU 仍严格返回单个 DECERR，重试幂等性由上层负责。

集成者应在 T-037 合并 SHA 上重跑受影响 L1 与 B25 SoC smoke；随后由物理 lane 在新 candidate 上确认 vendor EMIF 的实际 reset/cancel/readdatavalid 行为和 timing。
