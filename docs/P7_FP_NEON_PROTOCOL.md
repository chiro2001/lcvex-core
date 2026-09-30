# P7 FP/NEON 架构状态与差分协议

状态：**已落实 Sol 深度审查并于 2026-08-27 通过用户人工审核；可按任务流程拆分实现。**

本文冻结 ARMv8.2-A AArch64 的 P7 分批实现和验证契约。它不实现 RTL、QEMU
fork、协议代码、checkpoint 工具或生成器；P8 SVE 指令、谓词和完整 Z/P/FFR
状态不在本任务范围。

## 已冻结决策摘要

| 项 | 冻结决定 |
| --- | --- |
| Gate-F CPU | `cortex-a76,has_el3=false,has_el2=false` 是 P7 canonical Gate-F/checkpoint profile；既有 P6/Linux `max` 基线不替换。 |
| V/Z | P7 V0–V31 是 raw 128-bit，等于未来 Zn[127:0]。`max` 兼容线识别 zN 并只取低 128；所有高 Z 半非零即失败，且 max adapter 禁止发布 P7 checkpoint。 |
| scalar wire | header version=1 和原 HELLO/CONFIG/INIT/PRE/GO/COMMIT/ACK payload、seq 均不变。P7 只在 required capability 成功后添加 type16/17 状态帧。 |
| state oracle | QEMU wire/trace 只传 FP architecture state，不传“同值写”effect。RTL 可保留 effect，限 L1/SVA/定向检查；锁步由 raw state delta 比较。 |
| handshake | plugin `fp=required` 与 coordinator `--fp-neon=required` 配对；`HELLO.api_version==2` 加 `CONFIG.state_mask` bit31 是唯一启用条件。默认 off 时新旧组合均为纯 V1。 |
| memory ABI | RTL 一次预留四个 vector write slot、八个 8B store slot；P7 首批实际限制最多一个 V 写、两个连续 8B store。QEMU 旧 scalar COMMIT 的 store[8] 不变。 |
| FP checkpoint | 独立 `LCVXFP01` 552B raw sidecar、gzip、manifest.tsv 第13列；每行绑定 seq，严格 artifact/provenance 和原子发布。 |
| 比较 | V/FPCR/FPSR、NaN payload、signed zero、FPSR sticky flags 都 raw-bit；DN=1 用例 bit-exact，DN=0 多 NaN 合法差异仅按逐指令允许集合/掩码处理，绝无 epsilon。 |

## 1. QEMU profile、寄存器来源和 V/Z 边界

P7 Gate-F、所有 published P7 checkpoint 和新 ISA 定向锁步固定：

```text
-machine virt -cpu cortex-a76,has_el3=false,has_el2=false
-accel tcg,thread=single,tb-size=64 -icount shift=0,align=off,sleep=off
```

对于包含 Generic Timer sidecar 的 P7 checkpoint，实际启动参数还必须显式写出
`cntfrq=1000000000`：

```text
-cpu cortex-a76,cntfrq=1000000000,has_el3=false,has_el2=false
```

QEMU 11.1 的 A76 默认可能选择兼容用的 62.5 MHz；这与 RTL/P6 固定的 1 GHz
`CNTFRQ_EL0` 不相容。无 timer 的 required smoke 可以诊断性使用旧写法，但它不
能发布或恢复 P7 checkpoint；`qemu_cpu` 的完整字符串必须进入 manifest context，
并由 root/resume runner 复用和校验。

P7 required 的 checkpoint 必须使用差分 checkpoint 路径（`DIFF_CKPT=1`），以确保
13 列 `LCVXFP01` sidecar 与其它状态在同一事务中发布；旧的 QMP-only checkpoint
路径不携带 FP sidecar，必须拒绝。

这是 P7 canonical profile，不改写 P6/Linux 的
`max,has_el3=false,has_el2=false` 兼容线或其 ID/sysreg evidence。QEMU 11.1.0
若需要验证 max 的低 128-bit 兼容适配器，必须显式设置
`P7_MAX_ADAPTER=1` 且只运行无 checkpoint 的诊断 smoke；该适配器不能用于
resume、发布 P7 checkpoint 或 Gate-F 证据。
`qemu_plugin_get_registers()` 实际经 `gdb_get_register_list()` 枚举：
`gdbstub64.c` 在无 SVE/SME 时注册 `aarch64-fpu.xml` 的 `v0..v31`（各16B）及
`fpsr/fpcr`（各4B）；SVE/SME 时注册变长 `z0..z31`。

plugin 在 vCPU init 只做 descriptor preflight，不在每条指令扫描 descriptor：

- canonical A76 必须只有 `v0..v31`，每个 16B，且有 4B `fpsr/fpcr`；
- max adapter 可有 `z0..z31`，每个至少16B；它将低端 little-endian 16B解释为
  `Zn[127:0]`，记录 descriptor 全长度；
- 缺失、重复、v/z 混用、错误长度或无法读 FPCR/FPSR 都触发 P7_REJECT；
- 热路径改用将来 QEMU patch 的一次性
  `qemu_lcvex_difftest_read_fp_state()`，它返回 FPCR、FPSR、32×low128、
  `vector_bytes` 和 `upper_nonzero`。该 patch 必须随 QEMU 11.1.0 fork patch
  重放；不得把 plugin 多次 register read 当作最终热路径。

max adapter 每个 snapshot 的 `upper_nonzero` 都必须为零，且 P7 程序不得包含
SVE 指令。这样可让既有 main 线运行无 SVE 的 P7 smoke，但不会把未保存的高 Z
半伪装成 P8 state。adapter 运行永不发布 P7 checkpoint；P8 也不得把 P7 V
sidecar 解释为完整 Z/P/FFR state。

普通 plugin 只有 instruction callback：本条 post-state 在下一条 callback 读取，
与既有 scalar COMMIT 相同。fork step hook 目前负责精确异常、device/sys/timer/gic
checkpoint；P7 新增可重放 fork API 仅用于一次取得 FP snapshot，QEMU incoming
仍由原 dev vmstate 恢复，DUT sidecar 永不回灌 QEMU。

## 2. 架构状态、权限、掩码与提交

| 状态 | reset | 权限 | 更新时机 |
| --- | --- | --- | --- |
| V0–V31 | 32×128bit 为零 | FP/Advanced SIMD，受 FPEN | 普通 WB/COMMIT；restore 与 scalar state 同一时钟边界。 |
| FPCR | `0x00000000` | EL0/EL1 MRS/MSR，受 FPEN | MSR 在既有 ID system commit；测试在 MSR 后 ISB。 |
| FPSR | `0x00000000` | EL0/EL1 MRS/MSR，受 FPEN | MSR 在 ID commit；运算在 WB/COMMIT 与 V 同步更新。 |
| CPACR_EL1.FPEN[21:20] | `0b00` | CPACR 仅 EL1 MRS/MSR | MSR ID commit；00/10 trap EL0+EL1，01 只 trap EL0，11 不 trap。 |

FPEN 不允许时，FP/Advanced SIMD 指令和 FPCR/FPSR access 产生同步 FP access
trap：`exc_valid=1`、`exc_code=0x00000007`（ESR.EC），`exc_esr` 为完整 QEMU
syndrome。trap 指令不得写 V/FPCR/FPSR，年轻指令清空。

```text
CPACR_P7_OWNED_FPEN_MASK = 0x0000000000300000
FPCR_P7_WRMASK           = 0x07c80000  # AHP, DN, FZ, RMode, FZ16
FPSR_P7_WRMASK           = 0xf800009f  # NZCV, QC, IDC, IXC..IOC
```

P7 **只消费** CPACR 的 FPEN 字段；正常 CPACR MSR、LCVXSYS3 和 checkpoint
restore 必须保留当前 P6 的完整 CPACR 值及 ZEN/SMEN 等非 FPEN 位，不能把
`0x00300000` 当作整个 CPACR write mask。P7 程序用 MRS/RMW/MSR 更新 FPEN。

FPCR 的 IOE/DZE/OFE/UFE/IXE/IDE 是 RAZ/WI，因为 QEMU 11.1
`vfp_set_fpcr_masked()` 明确没有实现 FP exception trap handling。P7 也不实现
FEAT_AFP FIZ/AH/NEP、EBF 或 AArch32 LEN/STRIDE。QEMU A76 的共享 helper 会
保存 LEN/STRIDE，这是 AArch32 compatibility quirk 而非 P7 AArch64 语义；P7
输入只写 `FPCR_P7_WRMASK`，从而两端 reserved 位保持 reset 0 并继续 raw
difftest。若要测试 reserved write，必须另开 QEMU 对齐任务。

## 3. 握手、互操作和精确时序

### 3.1 capability 与 fail-before-INIT

`LCVEX_MSG_VERSION` 保持1。P7 capability 是
`LCVEX_CFG_CAP_FP_NEON=0x80000000`（CONFIG state_mask bit31）。P7 required
模式中，plugin 的原24B HELLO 写 **`api_version==2`**；默认 `fp=off` 时仍写
`api_version=1`。coordinator 的原20B
CONFIG 只有在 `--fp-neon=required`、收到 api_version=2 且自身实现 P7 时才置
bit31。所有 send/recv 必须验证 `recv_bytes == sizeof(header)+payload_len`，
payload_len 等于该 type 的精确 struct size，并拒绝 truncation/extra bytes。

type18 为 P7_REJECT（seq=0，固定 `{uint32_t reason, vector_bytes}`）只用于
诊断后关闭连接。`reason` 只可为 `NO_CAP=1`、`DESCRIPTOR=2`、`PROFILE=3`、
`UPPER_NONZERO=4`、`PROTOCOL_LENGTH=5`；plugin required 却未获 bit31，或
vCPU preflight 失败时，在
发送 INIT 前发出它；coordinator required 收到 api_version!=2 时在读取 INIT 前
记录原因并关闭 socket。这样 required 任一端不匹配不会等待超时或伪跑 scalar。

| plugin | coordinator | 结果 |
| --- | --- | --- |
| old / new 默认 `fp=off` | old / new 默认 `--fp-neon=off` | 原 V1，所有 payload/seq 不变。 |
| old / new 默认 off | new required | coordinator 在 INIT 前明确拒绝。 |
| new `fp=required` | old / new default off | CONFIG 无 bit31；plugin P7_REJECT 后在 INIT 前退出。 |
| new required | new required | api_version=2+bit31，执行 P7 流。 |

### 3.2 P7 frame 与时序

新 type 固定为 `FP_INIT=16`、`FP_COMMIT=17`；都不修改旧 scalar payload：

```c
struct lcvex_v128 { uint64_t lo, hi; };                 /* 16B */
struct lcvex_fp_state_v1 {
    uint32_t fpcr, fpsr;
    struct lcvex_v128 v[32];
};                                                       /* 520B */
struct lcvex_fp_commit_delta_v1 {
    uint32_t flags;       /* bit0 FPCR_CHANGED, bit1 FPSR_CHANGED；其余位必须为0 */
    uint32_t v_mask;      /* bit n: Vn differs；popcount 必须<=4 */
    uint32_t fpcr, fpsr;  /* post values; flags=0 时与 previous 相同 */
    struct lcvex_v128 v[];/* popcount(v_mask)，按 rd 升序 */
};                                                       /* 16..528B */
```

FP_INIT payload 恰为520B，建立完整 shadow。FP_COMMIT 是无损状态 delta：payload
长度必须恰为 `16 + 16*popcount(v_mask)`，最大528B；保留 flag 非零或
`popcount(v_mask)>4` 均为协议错误。flags 和 v_mask 都为零表示本条没有可观察
FP state 改变。QEMU public API没有同值写 effect oracle，
所以 wire/trace/diff **不得**含 `vec_we/fpcr_we/fpsr_we` 或尝试判定同值写。
RTL 保留 `vec_write_count` 等 effect 仅供 L1 SVA/定向检查。

P7 required 的精确消息序列：

```text
HELLO -> CONFIG -> INIT(0) -> FP_INIT(0)
PRE(N) -> GO(N) -> COMMIT(N) -> FP_COMMIT(N) -> [CKPT_REQ/READY]* -> ACK(N)
ASYNC(N) -> ACK(N)
WAIT(N) / WAIT_RESUME(N) 保持纯 V1
```

ASYNC 是既有 WFI IRQ 合成提交：P7 FP state 必须不变，DUT 不得给 FP effect，
也不得等待 FP_COMMIT，否则会造成 socket 死锁。DISCON/EXIT 同样没有 FP frame。
在普通 COMMIT 中 coordinator 先比较旧 scalar effect/store，再严格应用并比较
FP delta；CKPT_REQ 仍在 FP_COMMIT 后、ACK 前，QEMU 不得执行 guest。

### 3.3 RTL effect 与向量访存容量

未来 RTL commit packet 一次性预留：`vec_write_count`（0..4）、4 组
`vec_rd[4]/vec_wdata[4][127:0]`、`store_count`（0..8）与8组
`store_addr/data/strb`，另有 FPCR/FPSR post/effect。初期 P7 编码限制
`vec_write_count<=1`、`store_count<=2`，但 ABI 不再声称必须另开多副作用协议。
现有 QEMU scalar COMMIT 的 store[8] 保持原样；旧 RTL mem/mem2 只在初期两个
segment 作为镜像。结构化、多寄存器、pair Q、lane/replicate 等超过初期上限的
编码明确拒绝，不得截断。

## 4. trace、raw 比较与失败包

P7 batch trace header 为 `# lcvex-qemu-trace v2 gzip`：先写一次 full FP_INIT，
每条 commit 写同 wire 定义的 FP delta。`tail` 的首条保留 commit 以及每个
checkpoint trace 点之前必须先写 full `fp_sync`，使切片无需隐含旧状态即可回放。
v1 trace 继续只用于 scalar，P7 parser 只接受 v2。

传输和默认比较均为 raw bits。DN=1 的指定用例结果必须 bit-exact；DN=0 时某些
架构允许多个 NaN result，测试向量必须为该指令列出有限 allowed raw set 或掩码，
并同时严格比较 FPSR。不得使用 host float、epsilon、通配任意 NaN 或把 signed
zero 视为相等。失败包 `fail-fp.json` 展开 full pre/post 32×V、FPCR/FPSR、
CPU profile、capability、instruction/disassembly/seq、scalar stores、最近32条
记录及 checkpoint provenance；`fail.txt` 列首个 raw V/NaN/FPSR mismatch。

## 5. LCVXFP01 checkpoint 与原子发布

```c
struct lcvex_fp_state_file_v1 {
    char magic[8];            /* "LCVXFP01" */
    uint32_t version;         /* 1 */
    uint32_t size;            /* 552 */
    uint32_t feature_bits;    /* 必须恰为 1 (P7 FP/NEON) */
    uint32_t vector_bytes;    /* 必须为 16 */
    uint64_t seq;             /* 必须等于 TSV seq */
    uint32_t fpcr, fpsr;
    uint64_t v[32][2];        /* [n][0]=lo, [n][1]=hi */
} __attribute__((packed));
```

sidecar 和 wire 都是 little-endian。P7 manifest.tsv 是现有完整12列后追加第13列
`fp.gz`；`Entry.fp_path` 进入 strict artifact/provenance。context 有
`p7_state=LCVXFP01` 时，每一行均必须有 fp path、header seq==TSV seq，且记录
`p7_cpu_profile=a76-v1`、`p7_vector_bytes=16`。新 reader 接受7…13列；旧 P6
chain 仍可读但 P7 restore 缺 fp 必拒绝；旧工具遇13列也必须显式拒绝。

保存的单行事务如下：

1. plugin 验证 `sys_path` 以 `.dev.sys` 结束，精确替换末尾 `.sys` 为 `.fp`；
   拒绝其他路径。它写 `.fp.tmp`、完整 write/close 后 rename 为 `.fp`。
2. coordinator 压缩 `.fp` 到 `.fp.gz.tmp`，close 后 rename `.fp.gz`，成功后
   删除 raw `.fp`；QEMU
   hook 的 dev/sys/timer/gic 与 RAM/arch/mmio 也必须均已成功。
3. 任一 raw/tmp/final 失败都删除**本行**全部 raw/tmp/final artifact，且不更新
   in-memory chain。
4. TSV 以同目录临时文件写“旧全部内容+新行”，close 后 atomic rename；只有
   rename 成功才更新内存链。finalize 才发布 manifest JSON/artifact hash。

恢复固定为：验证 finalized manifest/inputs→展开原 dev/RAM/timer/gic/mmio/fp→
QEMU 原 `-incoming`→DUT reset 保持装 RAM→同一 clock edge 采样既有
`difftest_restore_sys_valid` 与新增 `difftest_restore_fp_valid` 写 V/FPCR/FPSR→
清流水→从 next_pc 取指，并以首条 FP_INIT/FP delta 验证。禁止层级偷窥、逐条
回灌或把 DUT fp sidecar 写回 QEMU。

## 6. P7 分批 ISA 与 L0–L3

P7 分批通过不等于完整 ARMv8.2-A FP/Advanced SIMD 合规，未列架构族闭合前不得
作完整 ISA 声明。

| 层 | P7 首批 | 明确延后 |
| --- | --- | --- |
| P7-0 | V/FPCR/FPSR/FPEN state、trap、trace/checkpoint | SVE/SME、FP exception enable |
| P7-1 | 选定 FP32/FP64 FMOV/FADD/FSUB/FMUL/FDIV/FCMP 与基本标量访存 | FMA/sqrt/estimate/minmax/转换/round/fixed/FP16运算 |
| P7-2 | 选定 NEON move/bitwise/add-sub/compare/非饱和shift/单Q memory | saturating/narrow/widen/permute/table/across-lane/crypto/structured/lane/replicate/pair Q memory |
| P7-3 | 选定 2S/4S、2D add/sub/mul/compare | FMA、FP16/vector conversion 和未列 FP 族 |

| 层级 | 必须项 |
| --- | --- |
| L0 | ABI/frame length、descriptor preflight、mask、LCVXFP01 round-trip/corruption、7…13列、seq/path/原子发布失败注入。 |
| L1 | V reset/alias、FPEN四态 trap、MSR+ISB、CPACR非FPEN保留、FPCR/FPSR RAZ/WI、RTL effect上限、trap无副作用和同edge restore SVA/Cocotb。 |
| L2 | A76 strict lockstep：每个编码成功/NaN/FPSR/trap、v2 trace、required互操作、z adapter负测、checkpoint首条FP_INIT、超限store拒绝。 |
| L3 | 同一 frozen SHA 的 P7 L0–L2、P6 checkpoint/max兼容、**完整 Gate D**、固定输入/provenance；正式 Gate-F/main 晋级另需既定正式/CI条件。 |

按 T-046，P6 本地 Gate-E 入口已满足，允许在 feature 分支实施 P7；这不等于
正式 Gate-F/main/CI 晋级。Sol 建议“先完成可信 CI/正式 Gate-E 再编码”保留为
人工审核项，不覆盖用户已定的 feature 分支策略。

## 人工审核结论

- [x] 确认 A76 仅为 P7 Gate-F/checkpoint canonical profile；P6/Linux max
  基线不替换，max adapter 不发布 P7 checkpoint。
- [x] 确认 api_version==2、bit31、required fail-before-INIT 与完整互操作矩阵。
- [x] 确认 QEMU wire 是 full-init+state-delta，而 RTL effect 不作为同值写 oracle。
- [x] 确认初期1V/2store限制建立在4V/8store预留 ABI上。
- [x] 确认 LCVXFP01 552B、seq/path/TSV 原子发布及旧链拒绝规则。
- [x] 确认 FPCR LEN/STRIDE quirk 的“P7不写、reserved两端为零”处理；若要覆盖
  reserved write 则新建 QEMU 对齐任务。
- [x] 确认 NaN 双层策略：transport 始终 raw；DN=1/deterministic 用例 bit-exact；
  DN=0 仅使用逐指令 allowed-set/mask 并严格比较 FPSR，绝不使用 epsilon。
- [x] 确认 feature 分支可按已满足的 P6本地Gate-E进入实现，或选择采纳 Sol 更严格
  的“先CI/正式Gate-E”入口；无论选择，正式Gate-F/main仍须完整Gate-D和正式条件。
- [x] 确认 P7-0…P7-3 是分批门，不是完整 ARMv8.2-A FP/Advanced SIMD 声明。

用户已批准上述全部冻结决策。后续任务必须继续遵守本协议、独立写集、L0–L2
验收和集成者复跑规则；人工审核通过不等于 P7 功能或 Gate F 已完成。
