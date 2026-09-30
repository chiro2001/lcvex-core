# LCVEX 交接文档 010：M1 完成（提交握手 + 内存 request/response + SVA）

日期：2026-08-23（Asia/Shanghai）
前置：handoff 009（M1-A）、PROJECT_STATUS M1。
分支：`feature/commit-memory-handshake`（`ef2f9b3`、`3a277a6`、
`a2ba9e7`、`14f8104`、`043ba28`、`c19f7f6`）。

## 1. M1 完成内容

### M1-A：显式 commit_fire（`ef2f9b3`）

- WB 提交 = `memwb_valid && !memwb_committed_r && commit_ready`，
  不再依赖单端口 SRAM 自然气泡；背压沿 WB->EX/MEM->ID/EX->IF/ID
  逐级传播，释放后排队条目连续提交。
- 修复潜伏 bug：`mmu_req_issue` 当拍不同步冻结 EX/MEM/MEM-WB
  （相邻两级同驻重复提交）；WB 已提交“幽灵”条目前递污染 load 数据。
- SV + Cocotb 双轨背压测试并入 `make test`。

### M1-B：统一内存 request/response（`14f8104`、`043ba28`）

- `lcvex_pkg`：`mem_req_t/mem_rsp_t`（valid/ready + addr/we/strb/
  wdata 与 rdata/fault）。
- `lcvex_mem_ram`：1-cycle SRAM 包装，单 outstanding、rsp_ready
  背压保持、按 strb 实际跨度做越界/跨顶 fault、复位期程序加载口。
- `lcvex_mem_delay`：0/1/随机（LFSR）延迟注入。
- `lcvex_mem_arb`：PTW>数据>取指 + 响应按端口路由（修复 prio_sel
  反向与空请求误锁 in_flight）。
- `lcvex_core`：imem/dmem/ptw 三路全部 request/response；load 数据
  注册化（`exmem_rdata_r/memwb_rdata_r`）；Store 副作用与请求接受
  一一对应；响应 fault 提交为 DABT（含跨顶回绕 R0.7）；PTW 由 MMU
  内部 FSM 管理（REQ 等待接受、WAIT 等待响应）。
- `lcvex_soc_tb`：arb + delay + ram 串联，`MEM_DELAY_MODE` 参数。
- Makefile：`lockstep-build-delay1/delay2`（`-G` 注入 1 周期/随机延迟）。

### M1-C：SVA（`c19f7f6`）

- 单提交源互斥；提交源->脉冲对应（`|=>` 形式）；无重复 Store 接受；
  相邻两级不同驻（PC 识别）；32 位写回零扩展。
- 修复取指响应边界：分支冲刷取消在途取指并丢弃陈旧响应；
  `capture_now` 增加地址匹配防护。
- 所有运行构建启用 `--assert`。

## 2. 验证结果（M1 后全绿，含断言）

- P0：toolcheck/lint/SV smoke/背压/memif/Cocotb ALU+regfile。
- P1/P2：trace difftest + lockstep 36 条；hazard；random seed 1~3
  × 100k。
- P4/P5：p4c 7 组、p5a 3 组、p5a-hardening 9 组、q6、lockstep-q5。
- 延迟注入：`MEM_DELAY_MODE=1` 全部定向组锁步一致；`=2`（随机 0..4
  周期）MMU/异常组锁步一致。
- M1 退出条件：0/1/随机延迟与背压下无丢失/重复提交；连续 WB valid
  每周期一条（背压释放后实测）；Store+DABT/IABT 交叉场景通过。

## 3. 已知遗留（R1 状态，P5b 前需关闭）

- TLBI/TLB 一致性、SCTLR/TCR/TTBR 写后失效。
- ESR_EL1/FAR_EL1 完整 syndrome（当前只比较 EC）。
- 块描述符（1M/2M/1G）、跨页访问拆分。
- 真实负载下的 I-L1/D-L1 行为（M2）。

## 4. 下一步

按 PROJECT_STATUS 近期任务顺序 4：`infra/full-regression-ci`——把
fast 与 difftest gate 接入 CI，增加干净 QEMU patch 重放任务；
随后任务 5 `feature/p5b-l1-cache`（按 M2 模块化边界：cache line
单元测试 -> I-L1 -> D-L1 -> 统一 L2 -> maintenance/barrier）。
