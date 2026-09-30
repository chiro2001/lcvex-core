# LCVEX 交接文档 042：P1 批量 trace difftest（gzip + 切片 + 回放）

日期：2026-08-24（Asia/Shanghai）
前置：handoff 041（内核锁步 713k + 3 缺口修复）。

## 1. 目标

把 QEMU 运行轨迹固化为文件（**压缩格式**），协调器**离线回放**与 DUT
逐条比较——不实时连 QEMU，可复现、可进 CI、可切片定位深启动分叉。

## 2. 已实现

### 2.1 gzip trace 生成（qemu/plugins/lcvex_difftest.c）

- trace 输出改 **gzip 流**（gzopen/gzprintf），10 行 ~10KB 明文压缩到
  ~730B（~13x）。
- 每行补 **exc_valid/exc_code/exc_esr/exc_far** 与
  **mon_we/mon_valid/mon_addr/mon_data** 字段（P1 回放精确比较；
  trace 模式无 fork step hook，EC/ESR/FAR 为 0，回放只比较 exc_valid）。
- `tail=N` 参数：trace 模式**只保留末尾 N 条提交**（深启动分叉定位，
  文件小；配合 `limit=` 截止条数）。
- `dbgmem=1` 可选（默认 MEM_W 保持性能）。
- **read_reg64 复用 GByteArray**（原来每指令 31 次分配，长跑内存/GC
  开销大）。

### 2.2 协调器回放（sim/difftest/lockstep_coordinator.cc）

- `--trace FILE`：读 gzip/明文 trace（自动检测 1f 8b magic），逐条
  驱动 DUT（step_until_commit）并与 trace 行比较：pc/insn/全部寄存器/
  sp/nzcv/next_pc/stores/exc_valid/mon；异常只比较 exc_valid（trace
  无 fork EC）。
- init 行初始化 shadow（与 socket 模式 INIT 一致，nzcv=4 复位）。
- `--skip N`：**切片快进**——DUT 先执行 N 条（apply_commit 同步
  shadow，不比较），从切片起点开始比较，**无需内存/系统寄存器快照**。
- `--max-insns` 限制回放条数；失败 dump 沿用 dump_failure。
- 编译链接 zlib（Makefile 各 lockstep-build* 目标加
  `-CFLAGS "-I/usr/include"` 与 `-LDFLAGS "-lz"`；conda 环境需
  `conda install -n lcvex zlib` 或系统 zlib 头）。

### 2.3 切片工具（scripts/trace_slice.py）

- 从完整 trace（gzip/明文）按全局 seq 截取 `[start, end)`，保留 header
  与 init 行，输出 gzip 或明文，末尾追加切片说明注释。
- 配合协调器 `--skip START`：DUT 快进到切片起点后比较。

### 2.4 内存控制

- **QEMU `-accel tcg,thread=single,tb-size=64`**（锁步脚本三处 QEMU
  调用）：长跑锁步 QEMU RSS 从 8.4GB 降到 **~133MB**。
- 协调器镜像加载（33MB Image 逐 4B tick 写入）约 25s；`run_lockstep_step.sh`
  的 socket 等待从 5s 加长到 **60s**。
- **已知**：QEMU trace 模式长跑（>5M 条）内存仍可到 ~4.7GB（TCG 翻译
  缓存，tb-size 对 trace 模式未完全约束），生成大 trace 前先确认可用
  内存；定向/CI trace 用 `tail=` 控制行数。

## 3. 使用流程

```bash
# 1. 生成 gzip trace（tail=3000 只留末尾，定位深启动分叉）
QEMU ... -plugin "file=...,trace=/tmp/kb.trace.gz,limit=5660000,tail=3000"

# 2. 切片（可选）
python3 scripts/trace_slice.py --in full.trace.gz --start 5652000 \
    --end 5653000 --out slice.trace.gz

# 3. 离线回放（不跑 QEMU）
COORD --trace slice.trace.gz --image kernel.bin --base 0x40000000 \
    --skip 5652000 [--max-insns 1000] [--dump fail.txt]
```

## 4. CI / release 管理建议

- **trace 文件不入 git**：作为 release artifact（GitHub Releases）或
  Git LFS 管理，CI 下载后回放。
- **总大小限制**：单 trace ≤ 50MB（gzip）、项目内 trace 资产总 ≤ 200MB；
  定向测试用 `tail=` 或小 `limit`（<10k 条）生成微型 trace。
- 每个 release trace 记录：QEMU commit、插件版本、`-cpu/-machine/
  -append` 参数、生成命令，保证可重现。

## 5. 验证

- hard_postpre gzip trace（120 条）回放 **PASS**（与 socket 锁步一致）。
- 切片 [30,80) + `--skip 30` 回放 **PASS**（DUT 快进后状态一致）。
- 内核锁步 200k（socket + tb-size=64）PASS，QEMU RSS 133MB。

## 6. 未提交修改

`qemu/plugins/lcvex_difftest.c`（gzip/tail/exc+mon 字段/read_reg64 优化/
dbgmem）、`sim/difftest/lockstep_coordinator.cc`（--trace/--skip 回放 +
init shadow + nzcv=4）、`scripts/trace_slice.py`（新）、
`sim/difftest/run_lockstep_step.sh`（tb-size=64 + 60s 等待）、
`Makefile`（zlib 链接）、`docs/handoffs/041`（若未提交）。

## 7. 下一步

1. 提交本工具链；ROADMAP/PROJECT_STATUS 更新。
2. **调试内核锁步 5.65M 分叉**（BL 目标 VA/PA 差异）：
   - 锁步 8M（tb-size 受控）复现 seq=5652559；
   - 分析 QEMU next_pc=0x41090ac0 vs DUT 0xffff800081090ac0（疑似
     fork step hook 对线性映射分支目标的 32 位截断或插件 next_pc）。
3. 大 trace 生成的内存优化（trace 模式 TCG 缓存）按需跟进。
