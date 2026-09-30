# T-20260920-024：B25 逻辑立即数 Quartus-safe RTL 交接

```text
task=T-20260920-024 state=done-local-awaiting-integration partial=true
base=1ce74e9c81c40812ea93a161d52cad8dda807a0d
implementation=92bd167b71ce675969bad8235142d59db2f66e20
branch=fix/T-20260920-024-b25-logic-imm-quartus-safe-rtl
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-024
evidence=docs/tasks/evidence/T-20260920-024.json
```

## 结论

T-024 已将 `rtl/lcvex_decode.sv` 的 AArch64 logical-immediate decoder 改为
纯 packed return function。返回值为 `{valid, mask}`，所有局部量和 65 个返回位
均有默认值及最终赋值；函数不再有 `output/inout` 参数，不再使用 `break`、变步长
循环或 `1 << 64`/旋转零值导致的全宽移位。

len 仍严格取 `N:NOT(imms)` 的最高置位：`len=6` 为 64-bit element，`len=1..5`
为 2/4/8/16/32-bit element；`len<1` 与 `S==levels` 保留为 UDEF。元素 mask、
有界旋转和 64-bit 复制用固定表/常量宽度拼接实现，故 W/X 语义和公共 decode
接口、pipeline latency 均不变。

## 直接证据

独立验证 TB 位于 ignored build 目录（没有改 tracked test tree）：
`build/agents/T-20260920-024/logic_imm_exhaustive_tb.sv`。

- `sf=0/1 × N=0/1 × immr/imms=0..63`，共 16384 个编码，与独立 ARM
  参考算法逐项比较；合法/保留和 mask 全部通过。
- `0x12003C06`，`W0=0xA43F`：mask `0xFFFF`，AND 结果 `W6=0xA43F`。
- `0x12001C00`，`W0=0xA43F`：mask `0xFF`，AND 结果 `W0=0x3F`。

结果：

```text
PASS: T-024 exhaustive N/immr/imms sf=0/1 (16384 cases) and firmware masks
```

## 已运行验证

- decode-only Verilator lint：PASS。
- `make compile`：PASS。
- `make VERILATOR_JOBS=1 sim-sv`：PASS。
- `make VERILATOR_JOBS=1 microbench`：PASS，`mb_all (2411 cycles)`。
- `make check-encoders`：PASS，86 条编码器交叉检查。
- 所有重型本机步骤都在 `resource-lock` 的 `local` 槽中运行，最终 local 为
  `FREE`；未访问 GamePC、Quartus、JTAG 或板卡。

`make sim-cocotb-core` 的 Verilator 构建/elaboration 已成功，但测试入口要求
外部 `QEMU_TRACE`，因未设置该前置变量在 0 ns 处明确退出。该失败不是 RTL 编译
或断言失败；合并者应在已有 QEMU trace 生成后作为受影响 L2 入口重跑。

精确命令、source/artifact SHA、资源与安全声明见
[`docs/tasks/evidence/T-20260920-024.json`](../tasks/evidence/T-20260920-024.json)。

## 交接给集成者

1. 先 cherry-pick `92bd167b71ce675969bad8235142d59db2f66e20`。
2. 在合并 SHA 上复跑 T-023 的旧 SHA negative control 与 fixed-SHA synthesis/post-map
   semantic test；确认 warning 16788 不再属于该 cone。
3. 生成合并 SHA 的受影响 L0-L2、Gate D 和 boot-image identity 证据；此 lane 没有
   修改 firmware、QSF/SDC、测试、runner、registry 或 expected result。
4. Quartus fresh physical、assembler、SOF 和最终板测只能由后续授权的 integration/
   physical lane 执行，继续禁止 JIC/EPCQ/Flash、power cycle、板级 reset。

实现提交只包含 `rtl/lcvex_decode.sv`；证据/交接将在后续独立文档提交中加入。
