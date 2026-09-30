# LCVEX 交接文档 071：P6 LSE128 CASP 深段缺口

日期：2026-08-25（Asia/Shanghai）  
前置：`070-p6-lse-atomic-family-verified.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 新缺口与复现证据

在完成单寄存器 LSE 后，从同一链继续 1,000,000 条时，Linux 在本地
`seq=113834` 首次遇到：

```text
0xffff800080315c78: 0x48207c82  casp x0, x1, x2, x3, [x4]
```

旧 DUT 把 CASP 误判为 `STXP`/未定义路径，QEMU 继续执行而 RTL 进入异常。
这不是 WFI/Timer 问题；它是 Linux `cmpxchg128` 使用的 FEAT_LSE128
CASP 原子族。

## 2. 当前未提交实现

- `ATOMIC_CASP` 加入 RTL 原子操作枚举；`decoded_insn_t/ex_pipe_t` 增加第二个
  CAS 比较值，decoder 识别 `CASP/CASPA/CASPL/CASPAL`，要求 Rs/Rt 寄存器
  对为偶数，奇数编码保持 UDEF。
- EX/MEM 增加四阶段事务：低 64 位读、 高 64 位读、低 64 位写、高 64 位写；
  两个旧值复用 LDP 双写回，比较失败不发任一 Store，成功时 commit packet
  上报两段内存副作用。
- ID hazard 新增 `rs4/rs5`，覆盖基址、比较寄存器对和新值寄存器对的依赖。
- `a64.py` 增加 `casp` 编码器；`hard_lse_atomic` 新增 CASPAL 匹配与 CASP
  不匹配用例。
- QEMU 插件排除 CASP 被误判为 STXP，并读取 U128 原子旧值；比较失败时丢弃
  两段幻影 `MEM_W` 回调，成功时保留 QEMU 的两个 8 字节 Store。

## 3. 已验证结果

```text
make compile                                      PASS
make -C qemu/plugins                               PASS（仅已有 U128 switch 警告）
make lockstep-build / lockstep-build-l1dl2         PASS
hard_lse_atomic, base, 100 条                      PASS
hard_lse_atomic, I+D+L2 cache, 100 条              PASS
```

定向用例覆盖 CASPAL 匹配、CASP 不匹配、W/X 单寄存器 LSE、ST* 别名、
CAS Rs=XZR 不匹配和 32 位回绕。Linux 1M 窗口在 CASP 缺口处停止，CASP
修复后的更长 Linux 续跑尚未重新执行。

## 4. 下一步

1. 先检查当前 diff，分别提交 CASP RTL、QEMU U128 过滤、定向测试和文档；
2. 从 `tail-resume-ckpt17-20260825` `RESUME_SEQ=999999` 重新续跑至少
   1,000,000 条，确认越过 CASP 后再定位下一个真实缺口；
3. 重点观察 `LDCLRP/LDSETP/SWPP`、WFE/WFI 和 Timer IRQ；
4. CASP 仅代表 LSE128 CAS 交换，不代表完整 LSE128 原子族已经完成。

不要删除已有 checkpoint，也不要回退 `../qemu` fork 的 dirty 改动。
