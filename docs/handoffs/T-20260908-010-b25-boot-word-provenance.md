# T-20260908-010：B25 boot reset word provenance 交接

```text
task=T-20260908-010 state=done-stale-test
verdict=STALE_TEST; authoritative_word=0x9100001f58001700
base=8f8faac30119c1db734a2ecd0394b4aad24e881b
head=8f8faac30119c1db734a2ecd0394b4aad24e881b
dispatch_parent=193cf281f55c9c3792737c73b4adfec2a86d027c
dispatch_commit=62e8d62114027ab619785ed4e257e1763fee95b4
branch=verify/T-20260908-010-b25-boot-word-provenance
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-010
sent_at=2026-09-09T00:01:15+08:00 received_at=2026-09-09T00:01:15+08:00
reported_at=2026-09-09T00:18:57+08:00
files=docs/tasks/evidence/T-20260908-010.json,docs/handoffs/T-20260908-010-b25-boot-word-provenance.md
tests=boot build + ELF/objdump/history/static payload checks; no Verilator/SV test
blockers=tb/sv/lcvex_bram_init25_tb.sv:115 stale layout-dependent c0 constant
next=T-011 choose non-circular BRAM init oracle; integration reruns focused TB
evidence=docs/tasks/evidence/T-20260908-010.json
```

## 结论

当前 source `8f8faac3` 重建出的权威 reset vector 为：

```text
boot.bin bytes 0..7 = 00 17 00 58 1f 00 00 91
little-endian 64-bit word = 0x9100001f58001700
boot.mif record 0000 = 0000 : 9100001F58001700;
```

这不是坏镜像，也不是端序生成器错误。ELF 的唯一 `PT_LOAD`、`boot.bin`、解码后的
byte HEX 和完整 MIF payload 全部一致；不一致的是
`tb/sv/lcvex_bram_init25_tb.sv:115` 仍硬编码旧布局的
`0x9100001f580017c0`。最终判定：

```text
stale-test=true
bad-image=false
generator-endian-bug=false
indeterminate=false
```

## 当前镜像和全 payload 证据

使用任务专用输出目录运行：

```text
LCVEX_BOOT_BUILD_DIR=build/agents/T-20260908-010/boot \
  bash fpga/catapult_a10/boot/build.sh
```

结果为 `LCVEX_BOOT_BUILD_PASS`；第二次重建 hash 相同，shell time 为 0.063 s。ELF
为 ELF64 little-endian AArch64，entry=`0x0`，唯一 `PT_LOAD` 为
`offset=0x10000, vaddr=0, filesz=0x3bd (957), memsz=0x3c8`。因此：

- `dd if=boot.elf bs=1 skip=65536 count=957 | cmp - boot.bin`：0 mismatch；
- `boot.bin` 957 B，解码 byte HEX 957 B，二者逐字节一致；
- MIF 为 WIDTH=64、DEPTH=8192、8192 条显式 record，解码 payload 65536 B；
- MIF 的前 957 B 等于 `boot.bin`，后 64579 B 全为零，最后地址为 `0x1fff`；
- `boot.bin` SHA-256=`aa4a8bbe2a71affe281c8b60922ee27dfc0b2a99a7f645d5ed53767ff192f0c6`；
  解码 HEX 相同；MIF 文件 SHA-256=`614d4505f8a6836eeb73e92ff5f2ba43ed9e3be27df6ef450675e651db280cd7`。

链接符号也符合当前 contract：`__image_end=0x3c8`、`__stack_limit=0xf000`、
`__stack_top=0x10000`，没有覆盖栈区。MIF 生成器使用
`int.from_bytes(..., "little")`，并在生成后回读 HEX/MIF；独立解析也得到 0 个 mismatch。

## 两个 LDR literal 的解码

AArch64 `LDR (literal)` 的 `imm19` 是 instruction[23:5]，字节偏移为
`sign_extend(imm19) << 2`，目标是 `PC + offset`。首条指令之后两版都为
`0x9100001f`（`mov sp, x0`），变化只在首条指令引用的 literal pool 地址：

| 版本 | 首条 instruction | imm19 | offset/target | pool value | 反汇编 |
| --- | ---: | ---: | ---: | ---: | --- |
| 当前 `fbec08af` / `8f8faac3` | `0x58001700` | `0x0b8` (184) | `0x2e0` | `0x10000` (`__stack_top`) | `ldr x0, 2e0` |
| 旧 `91d53be5` / T-039 head | `0x580017c0` | `0x0be` (190) | `0x2f8` | `0x10000` (`__stack_top`) | `ldr x0, 2f8` |

当前 literal pool 的关键项为 `0x2dc` 的 `DDR_MAGIC_A`、`0x2e0=0x10000`、
`0x2e8=cal_state(0x3c0)`、`0x2f0=ddr_state(0x3c4)`、`0x2f8=msg_boot(0x368)`。
旧 pool 则在 `0x2f8` 放置相同的 `__stack_top=0x10000`，所以两条 reset 路径的
运行时栈顶相同；不能用旧的 PC-relative encoding 断言新的布局。

## 历史定位与 T-039 为什么通过

以同一 Binutils 2.47 对历史 commit 的 raw `boot.S`/`boot.ld` 重新汇编、链接、
objcopy（产物均在 `build/agents/T-20260908-010/history/`）得到：

| commit | 角色 | `boot.bin` | 首 word | `__stack_top` pool |
| --- | --- | ---: | ---: | ---: |
| `1e3187cf` | 初始 B25 image/monitor | 1013 B | `0x9100001f580017c0` | `0x2f8` |
| `3d0e055e` | UART timeout 修改 | 1013 B | `0x9100001f580017c0` | `0x2f8` |
| `91d53be5` | T-039 owner/test head | 1013 B | `0x9100001f580017c0` | `0x2f8` |
| `fbec08af` | B25 resident monitor integration | 957 B | `0x9100001f58001700` | `0x2e0` |

首 word 第一次从 `c0` 变为 `00` 的具体提交是
`fbec08af334fafc3f9aa7801399f409301c20618`（parent
`cbdcfac8106e3d532b451f892f601f886e8466c8`）。该提交只修改了 `boot.S` 的布局相关
内容（23 additions/34 deletions；`boot.ld` 未改）：

- 删除 `DDR_TEST_B..E` 和四组额外 store/test，只保留单点 uncached store/DSB/load；
- 启动 CAL 状态后增加 CRLF 输出；
- 四个 helper 的栈帧从 pre-index `STR` 改为 `SUB` + `STR`，改变代码放置；
- 代码和 literal pool 因此重新布局，`__stack_top` pool entry 从 `0x2f8` 移到 `0x2e0`。

T-039 的 `BRAM_INIT25_TB` 是在 `91d53be5` head 上运行的，那个 source 的
`boot.S` hash 为 `f32ca7de...`、镜像为 1013 B、首 word 正是 `c0`；该 TB 的
`0x...17c0` 期望值由早期 image 引入，之后没有随 `fbec08af` 修改。故 T-039 当时
通过是正常的旧候选结果，不能替代当前 957 B image 的验证。T-039 后续 integrator
记录虽已列出新的 957 B artifact，但没有同步更新这个 layout-dependent TB oracle。

## 最小后续写集

本任务不修改任何 source 或期望。后续应由 T-011/测试契约 lane 完成：

1. 最小即时修复是把 TB 第 115 行期望改为
   `64'h9100_001f_5800_1700`；更稳妥的方案是解码首条 `LDR literal`，计算目标，
   读取该目标并断言其值为 `__stack_top=0x10000`，避免未来 monitor 布局变化再次产生
   stale immediate。
2. 保留独立的首字节/端序、完整 MIF、零填充、`0xFFFC`、`0xFFFF` 和 `0x10000`
   边界检查；不能把 DUT 当前读值作为期望值，也不能删除 FAIL 检查。
3. 用新生成 `boot.hex` 重跑 focused BRAM init TB；集成 physical candidate 时重新
   生成并 hash-bind ignored `boot.mif`。本任务没有运行 Verilator/SV TB、Quartus、
   GamePC、assembler、SOF、JTAG、板卡或 Flash。

工具版本、完整 artifact/hash、机器可读比较结果和注册缺口见
[`T-20260908-010.json`](../tasks/evidence/T-20260908-010.json)。
