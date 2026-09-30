# LCVEX 交接文档 039：Linux 启动 trace 推进 + LDUR 缺口关闭

日期：2026-08-24（Asia/Shanghai）
前置：handoff 038（GICv2 + 异步 IRQ）。

## 1. 内核启动 trace（QEMU 侧）

建立可复现的内核启动 trace 基建：

1. **DTB**：`-machine virt,gic-version=2,dumpdtb=...` 提取，`dtc -I dtb
   -O dtb` 重编译去掉 1 MiB 填充（真实内容 ~7.8 KB）；
2. **Image**：把头部 text_offset 补丁为 0x80000（原 build 为 0），使
   QEMU 加载内核到 0x40080000、DTB 到 0x40000000（不重叠）；
3. **启动命令**：`-kernel /tmp/Image-t80000 -dtb <compact> -append
   "console=ttyAMA0,115200 earlycon=pl011,0x09000000 rdinit=/bin/sh"`，
   `-icount shift=0,align=off,sleep=off` + lcvex 插件 trace。

结果：800k 条提交，内核打印到 **"alternatives: applying system-wide
alternatives"**（此前 handoff 034 仅到 "random: crng init"）——
CPU feature 探测、SVE/SME 报告、EL1 启动、alternative 打补丁均已
执行，说明 UART/Timer/GIC 与已实现系统寄存器覆盖了内核早期初始化。

## 2. 新实证缺口与实现

`scripts/kernel_trace_gap.py` 对 800k trace 反汇编比对：

- **误报**：bti/ccmp/clz/rev 已由 handoff 034 实现——缺口脚本 SUPPORTED
  集过旧，已补全（bti/ccmp/ccmn/clz/cls/rev/rev16/rev32/cset/csetm +
  ldur 族）；
- **cset/csetm/cinc/cinv/cneg**：CSEL 族别名（cset = csinc xd, xzr,
  xzr, **!cond** 等），a64.py 新增条件取反别名编码器；RTL 的 csinc 族
  已天然支持 rn/rm=31（XZR）；
- **LDUR/STUR 族（唯一真实新指令缺口）**：非缩放 9 位有符号偏移访存
  （bits[25:24]=00、bit21=0、bits[11:10]=00），此前 UDEF。RTL decode
  新增分支（STUR/LDUR/LDURW/LDURH/LDURB/LDURSW/LDURSB/LDURSH X/W、
  PRFUM=NOP），a64.py 补 13 个编码器。

## 3. 验证

- `hard_ldur` 定向锁步 45 条（base/全缓存/随机延迟全绿）：X/W/H/B
  读写、负偏移、LDURSW/LDURSB/LDURSH 符号扩展（X 与 W 形式）、PRFUM、
  cset/csetm/cinc/cinv/cneg；
- `make test`/`make coverage` 全绿；check-encoders 73 条 PASS；
- **Gate D 全量 PASS**（`build/logs/gate_d_p6_ldur_20260824_060400.log`）：
  114 个 OK(green) 步骤、0 失败——M2-4b 24 组（含 hard_ldur）×
  base/cache、delay2 并行 25 项、P5a-Hardening、Gate C/P5a/P4b、
  随机 300,007 条、覆盖记账、baremetal-C。

## 4. 关键命令

```bash
../qemu/build/qemu-system-aarch64 -machine virt,gic-version=2,dumpdtb=/tmp/v.dtb \
  -cpu max -display none -serial null </dev/null
dtc -I dtb -O dtb /tmp/v.dtb -o /tmp/v-compact.dtb
python3 -c "import struct; d=bytearray(open('Image','rb').read()); struct.pack_into('<Q',d,8,0x80000); open('/tmp/Image-t80000','wb').write(bytes(d))"
# trace：
timeout 180 qemu-system-aarch64 -machine virt,gic-version=2 \
  -cpu max,has_el3=false,has_el2=false -accel tcg,thread=single \
  -icount shift=0,align=off,sleep=off -kernel /tmp/Image-t80000 \
  -dtb /tmp/v-compact.dtb \
  -append "console=ttyAMA0,115200 earlycon=pl011,0x09000000 rdinit=/bin/sh" \
  -display none -serial stdio \
  -plugin "file=.../lcvex_difftest.so,trace=/tmp/kb.trace,limit=800000"
python3 scripts/kernel_trace_gap.py /tmp/kb.trace --limit-insns 800000
```

## 5. 已知限制与下一步

- 内核锁步差分尚未启动：协调器需支持双镜像加载（内核 0x40080000 +
  DTB 0x40000000）与 `RESET_PC=0x40080000` 的 Verilator 变体；
- 更深的启动阶段（timer/GIC 中断使能、内存初始化、rootfs）将暴露下一
  批指令/系统寄存器缺口（预期 LSE 原子、LDXP/STXP、WFE/SEV、更多
  ID 寄存器、内存拷贝指令等）；
- **P6 剩余**：协调器内核锁步 -> 迭代缺口 -> Device Tree 核对 -> PSCI
  -> Gate E。
