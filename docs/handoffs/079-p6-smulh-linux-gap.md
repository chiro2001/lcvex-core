# LCVEX 交接文档 079：P6 SMULH Linux 缺口

日期：2026-08-25（Asia/Shanghai）
前置：`078-p6-osdlr-linux-gap.md`
当前分支：`feature/p6-system-reg-shim`

## 1. OSDL/OSLAR 复验

OSDLR/OSLAR 修复后，`hard_p6_isa` 共 104 条在 base/cache 均通过；第四条
Linux 链重新从 `linux-timer-irq-3-20260825/diff-999999` 启动，已经越过
局部 `seq=20243/20244` 的 OSDLR/OSLAR 两个系统寄存器写入。

## 2. 新缺口

在同一恢复窗口局部 `seq=527841` 首次遇到：

```text
PC    = 0xffff8000801e97ac
insn  = 0x9b417c61
disas = smulh x1, x3, x1
```

旧 RTL 只识别 `UMULH`，把 `SMULH` 作为 UDEF；QEMU 正常写回有符号
64×64 乘积的高 64 位。

## 3. 修复与测试

- decoder 识别 SMULH 主类，复用 `ALU_UMULH` 标记并按 bit23 选择有符号路径；
- `lcvex_muldiv` 新增 op10，锁存有符号操作数并在 64 周期槽位输出高半；
- `a64.py` 增加 `smulh` 编码器；
- `hard_madd` 增加负数×正数的 SMULH 定向用例，提交数更新为 43。

验证：

```text
make compile                     PASS
hard_madd, base                 43 条 PASS
hard_madd, I+D+L2               43 条 PASS
```

失败运行目录 `build/difftest/resume-run.zytvoA` 保留了完整 PRE/COMMIT 状态；
修复后的第四条链尚未从 `seq=527841` 之后重新续跑。

## 4. 下一步

从 `linux-timer-irq-3-20260825/diff-999999` 重新建立第五条压缩链，验证
OSDLR、OSLAR、SMULH 连续越过，再继续定位 Linux 用户空间入口前的缺口。
保持单物理核、每 100,000 条 checkpoint 和总磁盘空间限制。
