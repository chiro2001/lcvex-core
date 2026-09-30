# LCVEX 交接文档 070：P6 单寄存器 LSE 原子族验证完成

日期：2026-08-25（Asia/Shanghai）  
前置：`069-p6-lse-atomic-implementation-wip.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 本轮结果

从 `tail-resume-ckpt17-20260825` 的 `diff-999999` 复现后，原先的
`LDADDAL` 骨架首先通过了 Linux 分歧点；随后按真实轨迹关闭了：

1. `CASA/CASL`：比较值为 `Rs`，旧值写回 `Rs`，仅匹配时写 `Rt`；
2. `CNTVCTSS_EL0`：FEAT_ECV 自同步计数器视图，与 `CNTVCT_EL0` 同值；
3. `STCLR` 及其余单寄存器 LD/ST 原子操作；
4. 32 位 `LDADD` 进位回绕和提交 Store 数据高位清零。

Linux checkpoint 续跑命令：

```bash
CHAIN=/home/chiro/projects/mycpu/lcvex/build/difftest/tail-resume-ckpt17-20260825 \
RESUME_SEQ=999999 MAX_INSNS=100000 PIN=0 PROGRESS_EVERY=10000 \
bash sim/difftest/run_lockstep_resume.sh
```

结果：`PASS: 从 seq=999999 续跑 100000 条通过`。

## 2. 实现边界

RTL 新增 `atomic_op_t` 和 EX/MEM 原子状态。单发射顺序模型下，原子事务
固定为：

```text
读旧值 -> 计算/比较 -> （需要时）一次写请求 -> WB/commit
```

当前实现的单寄存器操作：

- `LDADD/LDCLR/LDEOR/LDSET/LDSMAX/LDSMIN/LDUMAX/LDUMIN/SWP`；
- `STADD/STCLR/STEOR/STSET/STSMAX/STSMIN/STUMAX/STUMIN/STSWP` 的
  `Rt=XZR` 别名语义（实际编码由同一操作族产生）；
- `CAS/CASA/CASL/CASAL` 的 W/X 形式；
- B/H/W/X 宽度回绕、符号/无符号 max/min、CAS 成功/失败副作用。

`CASP`、LSE128 其他操作、WFI/WFE 和真正的 acquire/release 微架构语义仍
不在本轮范围；在单核顺序模型中 acquire/release 位只影响编码接受，不额外
改变事务顺序。

`CNTVCTSS_EL0`/`CNTPCTSS_EL0` 在系统寄存器枚举、解码、EX timer read
路径均已加入，读值与普通 `CNT*` 相同。

## 3. QEMU 插件差分修正

QEMU TCG 对 CAS 比较失败仍会触发一次 `MEM_W` 插件回调，但内存实际不变。
`qemu/plugins/lcvex_difftest.c` 现在保存当前指令 PRE 状态，并在提交时用
`Rs(PRE)` 与 `Rs(POST)` 按访问宽度判断 CAS 是否失败；失败时丢弃幻影 Store。
既有 STXR 失败过滤也统一到 `drop_failed_atomic_stores`。这不是跳过差分，
而是还原 QEMU 插件回调与架构内存副作用的区别。

## 4. 定向测试

新增：

- `sim/difftest/a64.py`：`lse`、`cas` 编码器；
- `sim/difftest/test_program.py`：`build_hard_lse_atomic_program`，81 条
  镜像（其中 79 条覆盖至最后一条原子指令）；
- `sim/difftest/run_p6_lse.sh`；
- `make p6-lse`。

已验证：

```text
make compile                         PASS
make lockstep-build-kernel           PASS
hard_lse_atomic, base, 79 条         PASS
hard_lse_atomic, I+D+L2, 79 条       PASS
Linux checkpoint 续跑 100000 条      PASS
```

定向镜像包含 W/X 的所有单寄存器操作、ST 别名、CAS 匹配/不匹配、
acquire/release 编码和 32 位回绕。`make p6-lse` 会重新构建 base/cache
协调器，避免使用 stale build 产物。

## 5. 当前工作区与下一步

本轮实现、测试、QEMU 插件和文档均尚未提交；提交前必须保留并检查：

```text
rtl/lcvex_core.sv
rtl/lcvex_decode.sv
rtl/lcvex_pkg.sv
sim/difftest/a64.py
sim/difftest/test_program.py
sim/difftest/run_p6_lse.sh
qemu/plugins/lcvex_difftest.c
Makefile
docs/ISA_SCOPE.md
docs/ROADMAP.md
docs/PROJECT_STATUS.md
```

下一步建议：

1. 先运行 `make p6-lse` 完整入口并记录结果；
2. 单独提交 LSE RTL/解码、QEMU 插件过滤、定向测试、文档四个逻辑变更；
3. 从新的 checkpoint 继续更长 Linux 窗口，确认没有 LSE128 `CASP` 或 WFI/WFE
   缺口；
4. 然后进入 Timer IRQ/WFI 唤醒和 Gate E early boot 验收。

不要回退 `../qemu` dirty fork，也不要删除现有 checkpoint 链。
