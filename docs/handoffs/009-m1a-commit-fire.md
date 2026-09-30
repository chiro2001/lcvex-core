# LCVEX 交接文档 009：M1-A 完成（显式 commit_fire 与背压）

日期：2026-08-23（Asia/Shanghai）
前置：handoff 008（P5a-Hardening 完成）、PROJECT_STATUS M1。
分支：`feature/commit-memory-handshake`（`ef2f9b3`、`3a277a6`、`a2ba9e7`）。

## 1. 本阶段完成

### 核心（`ef2f9b3`）

1. **显式 commit_fire（R0.5）**：替换 WB 提交的 `memwb_valid` 0->1
   边沿依赖为 `commit_fire = memwb_valid && !memwb_committed_r &&
   commit_ready`。条目进入 WB 首周期即提交（与旧边沿同拍），连续 WB
   有效时每周期提交一条，不再依赖单端口 SRAM 的自然气泡。
2. **背压 valid/ready**：`commit_ready=0` 时 WB 条目保持（不丢不重），
   沿 WB->EX/MEM->ID/EX->IF/ID 逐级传播；释放后排队条目连续提交。
3. **潜伏流水线 bug 修复**：
   - `mmu_req_issue` 冻结 ID/EX 但 EX/MEM/MEM-WB 仍推进，导致同一条
     指令相邻两级同驻（重复提交）——现在翻译请求当拍冻结三个下游级，
     并用 `memwb_committed_r` 防止翻译冻结期保持的已提交条目重提交。
   - WB 保持的已提交“幽灵”条目不参与 gpr/sp/nzcv 前递（load 的
     `wb_wdata` 依赖实时 `mem_rdata`，保持期间端口已复用会污染前递）。
   - `stall_id` 增加 `(exmem_valid && !exmem_can_adv)`：EX/MEM 被 WB
     阻塞时 IF/ID 不得继续捕获，修复背压期指令覆盖丢失。

### 验证（SV + Cocotb 双轨）

- `tb/sv/lcvex_commit_backpressure_tb.sv`（`make sim-sv-backpressure`）：
  8 条纯 ALU 流中途拉低 `commit_ready` 7 周期，验证不丢不重、释放后
  连续提交（实测 max_consec=2）。
- `sim/cocotb/test_commit_backpressure.py`（`make sim-cocotb-backpressure`）：
  等价场景独立复现。
- 两者并入 `make test`。

### 回归（M1-A 后全绿）

P0+背压双轨、P1/P2 difftest+lockstep 36 条、hazard、random seed 1~3
× 100k、p4c 7 组、p5a 3 组、p5a-hardening 9 组、q6、lockstep-q5。

## 2. 关键经验

- 修改提交/冻结时序会暴露潜伏的流水线一致性问题；每个新冻结条件必须
  沿“WB->EX/MEM->ID/EX->IF/ID->取指”整条链核对，不能只改一级。
- “同一条指令不得同时驻留相邻两级”这类不变式应尽早以断言固化
  （M1-C 的 SVA 项）。
- 1-cycle SRAM 下背压/连续提交测试只能靠纯 ALU 流构造；load 数据在
  WB 保持期的保持问题（实时 mem_rdata 依赖）将在 M1-B 的
  request/response 协议中彻底解决（响应数据随请求一对一返回）。

## 3. 下一步（M1-B：内存 request/response）

1. 在 `lcvex_pkg` 定义 `mem_req_t`（valid/addr/we/strb/wdata）与
   `mem_rsp_t`（valid/rdata/fault），统一取指、数据访问、PTW 三路。
2. 抽离 `lcvex_mem_ram`（1-cycle SRAM 包装：请求接受、响应一周期后
   返回、rsp_ready 背压保持）与 `lcvex_mem_delay`（0/1/随机延迟注入）。
3. `lcvex_mem_arb`：PTW > 数据 > 取指仲裁 + 响应按请求路由。
4. 核心改造：取指 issue-on-capture 改为请求/响应；Store 副作用只在
   请求被接受且不会被 flush/fault 时产生一次；PTW 走同一接口。
5. SVA（M1-C）：单提交、提交顺序、无重复 Store、request 保持、
   response 对应、XZR/32-bit 零扩展。

退出条件见 PROJECT_STATUS M1：0/1/随机延迟与背压无丢失/重复提交、
连续 WB valid 每周期一条、Store+iTLB miss/fault 交叉场景、旧回归全绿。
