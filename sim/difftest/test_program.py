"""P1/P2 差分测试裸机程序生成。"""

import struct
from pathlib import Path

from a64 import Insn, assemble, label

BASE = 0x44000000  # virt 机器 RAM 起始 0x40000000，避开 0x40000000 处的 DTB

# ---- P1：QEMU 导出验证程序（模型子集） ----
P1_INSN_LIST = [
    Insn("add", 0, 0, 1),     # x0 = 1
    Insn("sub", 1, 1, 1),     # x1 = 0xffffffffffffffff
    Insn("adds", 2, 2, 1),    # x2 = 1，NZCV 更新
    Insn("movz", 4, 0x4400, 1),  # x4 = 0x44000000（RAM 地址）
    Insn("str", 0, 4, 0),     # mem[0x44000000] = x0 = 1（64 位）
    Insn("nop"),
    Insn("b", "loop"),
    label("loop"),
    Insn("b", "loop"),
]


# ---- P2：RTL 差分程序（覆盖解码器/ALU/分支/访存子集） ----
def p2_program():
    return [
        label("start"),
        Insn("movz", 0, 1),            # x0 = 1
        Insn("movz", 4, 0x4400, 1),    # x4 = 0x44000000
        Insn("movk", 4, 0x1230),       # x4 = 0x44001230（8 字节对齐）
        Insn("movn", 5, 0),            # x5 = 0xffffffffffffffff
        Insn("add_reg", 6, 0, 4),      # x6 = x0 + x4 = 0x44001231
        Insn("subs", 7, 6, 0),         # x7 = 0x44001230，C=1
        Insn("str", 7, 4, 0),          # mem[0x44001230] = 0x44001230
        Insn("ldr", 8, 4, 0),          # x8 = 0x44001231
        Insn("ldrb", 9, 4, 0),         # w9 = 0x31
        Insn("ldrsw", 10, 4, 0),       # x10 = 0x44001231
        Insn("adds", 11, 0, 0),        # x11 = 2，Z=0
        Insn("cmp", 12, 5),            # N=1 Z=0 C=0 V=0
        Insn("b_cond", "eq", "skip1"),  # 不跳
        Insn("add", 13, 0, 0),         # x13 = 2
        label("skip1"),
        Insn("cbz", 0, "skip2"),       # 不跳（x0=1）
        Insn("cbnz", 0, "do_tbz"),     # 跳
        Insn("b", "skip2"),
        label("do_tbz"),
        Insn("tbz", 0, 0, "skip2"),    # x0[0]=1，不跳
        Insn("tbnz", 0, 0, "do_bl"),   # 跳
        Insn("b", "skip2"),
        label("do_bl"),
        Insn("bl", "target"),          # x30 = 链接地址
        Insn("b", "skip2"),
        label("target"),
        Insn("movz", 14, 0x42),        # x14 = 0x42
        Insn("ret"),
        label("skip2"),
        Insn("adr", 15, "start"),      # x15 = 0x44000000
        Insn("adrp", 16, "start"),     # x16 = 0x44000000
        Insn("orr", 17, 0, 1),         # x17 = 0xffffffffffffffff
        Insn("eor", 18, 17, 5),        # x18 = 0
        Insn("and", 19, 17, 4),        # x19 = 0x44001230
        Insn("add_reg", 20, 19, 0),    # x20 = 0x44001231
        Insn("subs_reg", 21, 19, 0),   # x21 = 0x4400122f，C=1
        Insn("nop"),
        Insn("b", "start"),            # 死循环
    ]


# ---- P3：流水线 hazard 定向程序（forwarding/stall/flush） ----
def hazard_program():
    return [
        label("start"),
        # 1) ALU->ALU 背靠背 RAW（EX->ID forwarding）
        Insn("movz", 0, 0x1234),        # x0 = 0x1234
        Insn("add", 1, 0, 1),           # x1 = x0 + 1
        Insn("add", 2, 1, 1),           # x2 = x1 + 1（依赖 x1）
        # 2) load-use：ldr 结果立即被 ALU 消费（stall + WB forward）
        Insn("movz", 3, 0x4408, 1),     # x3 = 0x44080000（数据区）
        Insn("str", 1, 3, 0),           # mem[0x44080000] = x1
        Insn("ldr", 4, 3, 0),           # x4 = x1（load）
        Insn("add", 5, 4, 7),           # x5 = x4 + 7（load-use）
        # 3) load->branch：cbz 依赖刚加载的 x6（load-use + flush 抑制）
        Insn("ldr", 6, 3, 0),           # x6 = x1
        Insn("cbz", 6, "skip1"),        # x6 != 0，不跳
        Insn("add", 7, 5, 6),
        label("skip1"),
        # 4) 无条件跳转冲刷 + 链接地址
        Insn("b", "target"),
        Insn("add", 8, 0, 1),           # 应被冲刷
        label("target"),
        Insn("movz", 9, 0x42),          # x9 = 0x42
        # 5) flag 依赖：adds -> b.eq（NZCV 前递）
        Insn("movz", 10, 0x1000),
        Insn("adds", 11, 10, 10),       # x11 = 0x2000，Z=0
        Insn("b_cond", "eq", "skip2"),  # Z=0 不跳
        Insn("movz", 12, 0x77),
        label("skip2"),
        # 6) MOVK 读 rd（rd 前递）
        Insn("movz", 13, 0xdead),
        Insn("movk", 13, 0xbeef, 1),    # x13 = 0xbeefdead
        # 7) 多周期乘除（EX 忙冻结 + 结果前递）
        Insn("movz", 16, 0x1234),
        Insn("movz", 17, 0x56),
        Insn("mul", 18, 16, 17),        # x18 = 0x1234 * 0x56
        Insn("udiv", 19, 18, 17),       # x19 = 商
        Insn("movn", 21, 0),            # x21 = -1
        Insn("sdiv", 20, 16, 21),       # 4660 / -1 = -4660
        Insn("udiv", 22, 21, 31),       # 除零 -> 0（除数 XZR）
        Insn("mul_w", 23, 16, 17),      # 32 位乘法
        Insn("sdiv_w", 24, 16, 17),     # 32 位有符号除法
        # 8) RET 式链接：BL -> RET（x30 前递）
        Insn("bl", "sub"),
        Insn("movz", 14, 0x11),
        Insn("b", "done"),
        label("sub"),
        Insn("movz", 15, 0x99),
        Insn("ret"),
        label("done"),
        Insn("b", "start"),             # 回环（trace 限制取前 N 条）
    ]


def build_program(path, words):
    data = struct.pack(f"<{len(words)}I", *words)
    Path(path).write_bytes(data)
    return BASE


def build_p1_program(path):
    return build_program(path, assemble(P1_INSN_LIST, BASE))


def build_p2_program(path):
    return build_program(path, assemble(p2_program(), BASE))


def build_hazard_program(path):
    return build_program(path, assemble(hazard_program(), BASE))


# ---- Q6：QEMU fork step hook 验证程序（SVC → 向量 → ERET 往返） ----
# 复位 EL1h（-cpu max,el3=off,el2=off），VBAR_EL1=0x44010000：
#   0x44000000  movz x5,#0x4401,lsl#16
#   0x44000004  msr vbar_el1, x5
#   0x44000008  movz x0,#0x42
#   0x4400000c  svc #0                 → ELR_EL1=0x44000010
#   0x44000010  movz x2,#0x66          （ERET 返回点）
#   0x44000014  udf #0                 （异常风暴，harness 提前 STOP）
#   向量 0x44010200（EL1→EL1 同步，SP=1）：
#   0x44010200  movz x1,#0x55
#   0x44010204  mrs x3, elr_el1
#   0x44010208  mrs x4, spsr_el1
#   0x4401020c  eret
def q6_svc_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 5),
        Insn("movz", 0, 0x42),
        Insn("svc", 0),
        Insn("movz", 2, 0x66),
    ], BASE)
    handler = assemble([
        Insn("movz", 1, 0x55),
        Insn("mrs_sys", 3, "elr_el1"),
        Insn("mrs_sys", 4, "spsr_el1"),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10000 + 0x400)  # 主程序 + 0x44010000 起的向量区
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


def build_q6_svc_program(path):
    return q6_svc_program(path)


# ---- P4b：EL0 SVC 往返（EL1h 预热 -> ERET 到 EL0 -> SVC -> 向量 -> ERET）
# 0x44000000  movz x5,#0x4401,lsl#16; msr vbar_el1, x5
# 0x44000008  movz x6,#0x4400,lsl#16; movk x6,#0x30; msr elr_el1, x6
# 0x44000010  movz x7,#0x3c0;         msr spsr_el1, x7   # EL0t, DAIF 全置位
# 0x44000018  eret                      -> EL0 @ 0x44000030
# 0x44000030  movz x0,#0x42; svc #0    # EL0 SVC
# 0x44000038  movz x2,#0x66            （ERET 返回点）
# 向量 0x44010400（EL0->EL1 同步，+0x400）：
# 0x44010400  movz x1,#0x55; mrs x3, elr_el1; mrs x4, spsr_el1; eret
def build_p4b_el0_svc_program(path):
    pre = assemble([
        Insn("movz", 5, 0x4401, 1),   # x5 = 0x44010000
        Insn("msr_sys", "vbar_el1", 5),
        Insn("movz", 6, 0x4400, 1),   # x6 = 0x44000000
        Insn("movk", 6, 0x30),        # x6 = 0x44000030
        Insn("msr_sys", "elr_el1", 6),
        Insn("movz", 7, 0x3c0),       # x7 = 0x3c0（EL0t + DAIF 全置位）
        Insn("msr_sys", "spsr_el1", 7),
        Insn("eret"),                 # -> EL0 @ 0x44000030
    ], BASE)
    el0 = assemble([
        Insn("movz", 0, 0x42),
        Insn("svc", 0),
        Insn("movz", 2, 0x66),
        Insn("udf", 0),               # 异常风暴，锁步提前 STOP
    ], 0x44000030)
    handler = assemble([
        Insn("movz", 1, 0x55),
        Insn("mrs_sys", 3, "elr_el1"),
        Insn("mrs_sys", 4, "spsr_el1"),
        Insn("eret"),
    ], 0x44010400)
    buf = bytearray(0x10000 + 0x600)
    for i, w in enumerate(pre):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(el0):
        off = 0x30 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x400 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- P4b：非法指令（UDF）-> UDEF 异常（EC=0x00）----
def build_p4b_invalid_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 5),
        Insn("movz", 0, 0x42),
        Insn("udf", 0),               # @0x4400000c：未定义指令
        Insn("movz", 2, 0x66),        # 不会执行
    ], BASE)
    handler = assemble([
        Insn("movz", 1, 0x55),
        Insn("mrs_sys", 3, "elr_el1"),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10000 + 0x400)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- P4b：数据异常（store 到 SRAM 外 0x50000000，EL1h -> EC=0x25）----
def build_p4b_dabt_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 5),
        Insn("movz", 0, 0x5000, 1),   # x0 = 0x50000000
        Insn("movz", 1, 0x77),
        Insn("str", 1, 0, 0),         # store 到未映射地址 -> DABT
        Insn("movz", 2, 0x66),        # 不会执行
    ], BASE)
    handler = assemble([
        Insn("movz", 3, 0x55),
        Insn("mrs_sys", 4, "elr_el1"),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10000 + 0x400)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- P4b：指令异常（BR 到未映射 0x50000000，EL1h -> EC=0x21）----
# 注意：0x45000000 在 QEMU virt 的 128MiB RAM 内（读到 0 -> UDEF），
# 只有 RTL 的 1MiB SRAM 视为越界，因此必须用 0x50000000。
def build_p4b_iabt_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 5),
        Insn("movz", 0, 0x5000, 1),   # x0 = 0x50000000（未映射）
        Insn("br", 0),                # 取指 0x50000000 -> IABT
        Insn("movz", 2, 0x66),        # 不会执行
    ], BASE)
    handler = assemble([
        Insn("movz", 1, 0x55),
        Insn("mrs_sys", 3, "elr_el1"),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10000 + 0x400)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- P4c：EL0 越权访问 EL1 系统寄存器 -> UDEF ----
# EL1h 预热 -> ERET 到 EL0 -> mrs elr_el1（EL0 越权）-> UDEF EC=0x00
# -> 向量 0x44010400（EL0->EL1）-> handler（EL1 可读 ELR）-> eret 返回
def build_p4c_el0_priv_program(path):
    pre = assemble([
        Insn("movz", 5, 0x4401, 1),   # x5 = 0x44010000
        Insn("msr_sys", "vbar_el1", 5),
        Insn("movz", 6, 0x4400, 1),   # x6 = 0x44000000
        Insn("movk", 6, 0x40),        # x6 = 0x44000040（EL0 入口）
        Insn("msr_sys", "elr_el1", 6),
        Insn("movz", 7, 0x3c0),       # EL0t + DAIF 全置位
        Insn("msr_sys", "spsr_el1", 7),
        Insn("eret"),
    ], BASE)
    el0 = assemble([
        Insn("mrs_sys", 3, "elr_el1"),  # EL0 越权 -> UDEF
        Insn("movz", 2, 0x66),
    ], 0x44000040)
    handler = assemble([
        Insn("movz", 1, 0x55),
        Insn("mrs_sys", 8, "elr_el1"),  # EL1 可读：应为 0x44000040
        Insn("eret"),
    ], 0x44010400)
    buf = bytearray(0x10000 + 0x600)
    for i, w in enumerate(pre):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(el0):
        off = 0x40 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x400 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- P4c：EL0 两次 SVC 往返（SPSR/ELR 复用，多轮 EL0/EL1 切换）----
# EL0 @ 0x44000040：mov x0,#1; svc #1 -> 返回 0x44000048
#   mov x2,#0x22; mov x0,#2; svc #2 -> 返回 0x44000054
#   mov x2,#0x33; udf #0
# 向量 0x44010400：mov x1,#0x55; mrs x8, elr_el1; eret
def build_p4c_el0_double_svc_program(path):
    pre = assemble([
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 5),
        Insn("movz", 6, 0x4400, 1),
        Insn("movk", 6, 0x40),        # EL0 入口 0x44000040
        Insn("msr_sys", "elr_el1", 6),
        Insn("movz", 7, 0x3c0),
        Insn("msr_sys", "spsr_el1", 7),
        Insn("eret"),
    ], BASE)
    el0 = assemble([
        Insn("movz", 0, 1),
        Insn("svc", 1),               # @0x44000044
        Insn("movz", 2, 0x22),        # @0x44000048 返回 1
        Insn("movz", 0, 2),
        Insn("svc", 2),               # @0x44000050
        Insn("movz", 2, 0x33),        # @0x44000054 返回 2
        Insn("udf", 0),
    ], 0x44000040)
    handler = assemble([
        Insn("movz", 1, 0x55),
        Insn("mrs_sys", 8, "elr_el1"),
        Insn("eret"),
    ], 0x44010400)
    buf = bytearray(0x10000 + 0x600)
    for i, w in enumerate(pre):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(el0):
        off = 0x40 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x400 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- P5a：MMU 数据翻译（EL1h，4 KiB 页表 + TLB + 权限 fault）----
# 页表（预构建在二进制内）：
#   L0 @0x44010000 [0] -> L1 @0x44011000
#   L1 @0x44011000 [1] -> L2 @0x44012000（VA 0x40000000..0x80000000）
#   L2 [0]  -> L3_data @0x44013000（VA 0x40000000 区域）
#   L2 [32] -> L3_code  @0x44015000（VA 0x44000000 区域）
#   L3_data [0] = PA 0x44080000, AP=01（EL0/EL1 rw）      # VA 0x40000000
#            [1] = PA 0x44081000, AP=11（EL1 只读）       # VA 0x40001000
#   L3_code [0]   = PA 0x44000000, AP=11（代码，恒等）
#            [0x10] = PA 0x44010000, AP=11（向量/handler）
# 取指在 P5a 为恒等映射（RTL 未做取指翻译，QEMU 用页表恒等翻译）。
def build_p5a_mmu_program(path):
    code = assemble([
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 0, 0x4000, 1),   # VA 0x40000000
        Insn("movz", 1, 0x1234),
        Insn("str", 1, 0, 0),         # -> PA 0x44080000
        Insn("ldr", 2, 0, 0),         # x2 = 0x1234
        Insn("movz", 3, 0x4000, 1),   # VA 0x40001000
        Insn("movk", 3, 0x1000),
        Insn("ldr", 4, 3, 0),         # 只读页读：OK
        Insn("str", 4, 3, 0),         # 只读页写：权限 fault -> DABT
        Insn("udf", 0),               # 不会执行
    ], BASE)
    handler = assemble([
        Insn("movz", 5, 0x55),
        Insn("mrs_sys", 6, "elr_el1"),
        Insn("eret"),                 # 返回 fault 指令 -> 循环
    ], 0x44010200)

    buf = bytearray(0x16000)  # 覆盖代码 + L0/L1/L2/L3 页表区
    for i, w in enumerate(code):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    # 页表项（8 字节，高 32 位为 0）
    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    l0 = 0x10000
    l1 = 0x11000
    l2 = 0x12000
    l3d = 0x13000
    l3c = 0x15000
    put64(l0 + 0 * 8, 0x44011003)                 # L0[0] -> L1
    put64(l1 + 1 * 8, 0x44012003)                 # L1[1] -> L2（共享）
    put64(l2 + 0 * 8, 0x44013003)                 # L2[0] -> L3_data
    put64(l2 + 32 * 8, 0x44015003)                # L2[32] -> L3_code
    put64(l3d + 0 * 8, 0x44080443)                # VA 0x40000000: PA 0x44080000 AP=01
    put64(l3d + 1 * 8, 0x440814c3)                # VA 0x40001000: PA 0x44081000 AP=11
    put64(l3c + 0 * 8, 0x440004c3)                # VA 0x44000000: PA 0x44000000 AP=11
    put64(l3c + 0x10 * 8, 0x440104c3)             # VA 0x44010000: PA 0x44010000 AP=11

    Path(path).write_bytes(buf)
    return BASE


def build_p5a_mmu_program_el0(path):
    """P5a 扩展：EL0 访问（AP=01 页允许 EL0 rw，验证 EL0 数据翻译）。"""
    code = assemble([
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x10), Insn("movk", 5, 0x1, 1),
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        # 准备 EL0 入口 0x44000040，SPSR=EL0t+DAIF
        Insn("movz", 6, 0x4400, 1),
        Insn("movk", 6, 0x40),
        Insn("msr_sys", "elr_el1", 6),
        Insn("movz", 7, 0x3c0),
        Insn("msr_sys", "spsr_el1", 7),
        Insn("eret"),
    ], BASE)
    el0 = assemble([
        Insn("movz", 0, 0x4000, 1),   # VA 0x40000000（AP=01，EL0 rw）
        Insn("movz", 1, 0x5678),
        Insn("str", 1, 0, 0),
        Insn("ldr", 2, 0, 0),
        Insn("movz", 3, 0x4000, 1),   # VA 0x40001000（AP=11，EL0 只读）
        Insn("movk", 3, 0x1000),
        Insn("ldr", 4, 3, 0),         # EL0 读只读页：OK
        Insn("str", 4, 3, 0),         # EL0 写只读页：权限 fault
    ], 0x44000040)
    handler = assemble([
        Insn("movz", 5, 0x77),
        Insn("mrs_sys", 6, "elr_el1"),
        Insn("eret"),
    ], 0x44010400)  # EL0->EL1 向量 +0x400
    buf = bytearray(0x16000)
    for i, w in enumerate(code):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(el0):
        off = 0x40 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x400 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 0 * 8, 0x44013003)
    put64(0x12000 + 32 * 8, 0x44015003)
    put64(0x13000 + 0 * 8, 0x44080443)   # AP=01
    put64(0x13000 + 1 * 8, 0x440814c3)   # AP=11
    put64(0x15000 + 0 * 8, 0x440004c3)
    put64(0x15000 + 0x10 * 8, 0x440104c3)
    Path(path).write_bytes(buf)
    return BASE


# ---- P5a-2：取指翻译 + IABT 提交合并 ----
# 主程序（恒等 @ PA 0x44000000）开 MMU 后 BR 到 VA 0x40000000（映射到
# PA 0x44000080）执行，验证取指翻译；随后：
#   code A @ VA 0x40000000（PA 0x44002000）：BR 0x50000000（未映射）
#     -> 分支取指 fault 合并到 BR 提交（IABT，ELR=0x50000000）
#   handler @ 0x44010200：判 ELR，分支 fault 时 ERET 到 VA 0x40001FFC
#     （code B @ VA 0x40001ffc / PA 0x44003ffc，下一条 VA 0x40002000
#       未映射）
#     -> 顺序取指 fault 合并到该指令提交（IABT，ELR=0x40002000）
#   handler 顺序分支：ERET 回 VA 0x40000000，循环交替覆盖两种合并。
def build_p5a2_fetch_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR M=1
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 0, 0x4000, 1),   # VA 0x40000000
        Insn("br", 0),                # 取指翻译：跳到 VA 0x40000000
    ], BASE)
    code_a = assemble([
        Insn("movz", 1, 0x11),
        Insn("movz", 2, 0x22),
        Insn("movz", 3, 0x5000, 1),   # x3 = 0x50000000
        Insn("br", 3),                # 未映射 -> 分支取指 fault 合并
    ], 0x40000000)
    code_b = assemble([
        Insn("movz", 7, 0x33),        # VA 0x40001ffc（页末）
    ], 0x40001ffc)
    handler = assemble([
        Insn("movz", 4, 0x55),
        Insn("mrs_sys", 5, "elr_el1"),
        Insn("movz", 6, 0x5000, 1),   # 0x50000000
        Insn("subs_reg", 31, 5, 6),   # cmp x5, x6（寄存器）
        Insn("b_cond", "ne", "seq_case"),
        # 分支 fault：ERET 到 VA 0x40001ffc（code B，顺序 fault）
        Insn("movz", 6, 0x4000, 1),
        Insn("movk", 6, 0x1ffc),
        Insn("msr_sys", "elr_el1", 6),
        Insn("eret"),
        Insn("label", "seq_case"),
        # 顺序 fault：ERET 回 VA 0x40000000（code A，分支 fault）
        Insn("movz", 6, 0x4000, 1),
        Insn("msr_sys", "elr_el1", 6),
        Insn("eret"),
    ], 0x44010200)

    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(code_a):
        off = 0x2000 + i * 4        # PA 0x44002000（VA 0x40000000）
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(code_b):
        off = 0x3ffc + i * 4        # PA 0x44003ffc（VA 0x40001ffc）
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)   # L0[0] -> L1
    put64(0x11000 + 1 * 8, 0x44012003)   # L1[1] -> L2（共享）
    put64(0x12000 + 0 * 8, 0x44013003)   # L2[0] -> L3_a
    put64(0x12000 + 32 * 8, 0x44015003)  # L2[32] -> L3_b（恒等区）
    put64(0x13000 + 0 * 8, 0x440024c3)   # VA 0x40000000: PA 0x44002000
    put64(0x13000 + 1 * 8, 0x440034c3)   # VA 0x40001000: PA 0x44003000
    put64(0x15000 + 0 * 8, 0x440004c3)   # VA 0x44000000: PA 0x44000000
    put64(0x15000 + 0x10 * 8, 0x440104c3)  # VA 0x44010000: PA 0x44010000
    Path(path).write_bytes(buf)
    return BASE


# ---- P5a-Hardening：NZCV 系统寄存器位域（[31:28]，评估 R0.3）----
# 权威行为（QEMU probe 已实跑确认）：
#   movz x4,#0x8000,lsl#16; msr nzcv,x4   -> N=1
#   mrs x3,nzcv                           -> x3=0x80000000（不是 0x8）
#   b.mi taken                            -> 跳转
# 当前 RTL：MRS 返回低 4 位、MSR 只写 wdata[3:0]、b.mi 不跳。
def build_hard_nzcv_program(path):
    main = assemble([
        Insn("movz", 4, 0x8000, 1),   # x4 = 0x80000000（N=1）
        Insn("msr_sys", "nzcv", 4),
        Insn("mrs_sys", 3, "nzcv"),   # x3 应为 0x80000000
        Insn("b_cond", "mi", "taken"),
        Insn("movz", 9, 0x11),        # QEMU 不执行（N=1 跳走）
        Insn("label", "taken"),
        Insn("movz", 5, 0x99),
        Insn("movz", 4, 0x2000, 1),   # x4 = 0x20000000（C=1, Z=0）
        Insn("msr_sys", "nzcv", 4),
        Insn("mrs_sys", 3, "nzcv"),   # x3 应为 0x20000000
        Insn("b_cond", "hi", "taken2"),  # hi=C&&!Z -> 跳
        Insn("movz", 9, 0x22),        # QEMU 不执行
        Insn("label", "taken2"),
        Insn("movz", 6, 0x77),
        Insn("b", "taken2"),          # 自循环（锁步按 max_insns 停止）
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- P5a-Hardening：MOV wide 保留 opc=01 -> UDEF（评估 R0.4）----
# 权威行为（QEMU probe 已确认）：0xB2800000（sf=1,opc=01）-> UDEF EC=0x00。
# 当前 RTL：落入 default 分支当作 MOV X0,#0 正常提交。
def build_hard_movwide_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),   # x5 = 0x44010000
        Insn("msr_sys", "vbar_el1", 5),
        Insn("raw", 0xB2800000),      # 保留 MOV wide opc=01 -> UDEF
        Insn("movz", 2, 0x66),        # 不会执行
    ], BASE)
    handler = assemble([
        Insn("movz", 1, 0x55),
        Insn("mrs_sys", 3, "elr_el1"),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10000 + 0x400)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- P5a-Hardening：ADD/SUB 立即数 shift=LSL#12（评估 R0.4）----
# 权威行为（QEMU probe 已确认）：
#   0x914004C7 ADD X7,X6,#1,LSL#12 -> x7 = x6 + 0x1000
#   0xD14004C8 SUB X8,X6,#1,LSL#12 -> x8 = x6 - 0x1000
# 当前 RTL：operand_b 忽略 insn[23:22]，按 x6 +/- 1 计算。
def build_hard_addsub_shift_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 6, 0x123),       # x6 = 0x123
        Insn("raw", 0x914004C7),      # add x7, x6, #1, lsl#12 -> 0x1123
        Insn("raw", 0xD14004C8),      # sub x8, x6, #1, lsl#12 -> 0xfffffffffffff123
        Insn("adds", 0, 0, 1),        # 常规 adds 仍应正确（回归锚点）
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- P5a-Hardening：B.cond cond=1111 按无条件分支处理（评估 R0.4）----
# 权威行为（QEMU probe 已确认）：trans_B_cond 将 0xe/0xf 都视为 always，
# 0x5400004f 直接跳转。当前 RTL cond_taken 的 default 曾将其当不跳。
def build_hard_bcond_f_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 1, 0x11),
        Insn("raw", 0x5400004F),      # B.cond #+8, cond=1111 -> 恒跳
        Insn("movz", 2, 0x22),        # 不执行
        Insn("movz", 3, 0x33),
        Insn("b", "main"),            # 自循环
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- P5a-Hardening：MMU AP 权限全矩阵（评估 R0.1）----
# 4 种 AP × EL0/EL1 × read/write，QEMU ptw.c 为权威（simple_ap_to_rw_prot）：
#   AP=00: EL1 RW, EL0 无；AP=01: EL1 RW, EL0 RW；AP=10: EL1 R, EL0 无；
#   AP=11: EL1 R, EL0 R。
# 当前 RTL perm_fault：EL1 读拒绝 AP=00、EL1 写放行 AP=10、EL0 读放行 AP=10。
# 每处访问若 fault -> DABT handler 将 ELR+4 后 ERET 继续；x9 标记异常路径。
def build_hard_ap_matrix_program(path):
    pre = assemble([
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 2, 0x4000, 1),   # x2 = VA 基址 0x40000000
        # EL1 矩阵（imm12 = 偏移 >> 3，64 位访问）：
        Insn("ldr", 0, 2, 0x000),     # AP=00 read  -> OK
        Insn("str", 0, 2, 0x000),     # AP=00 write -> OK
        Insn("ldr", 0, 2, 0x200),     # AP=01 read  -> OK
        Insn("str", 0, 2, 0x200),     # AP=01 write -> OK
        Insn("ldr", 0, 2, 0x400),     # AP=10 read  -> OK
        Insn("str", 0, 2, 0x400),     # AP=10 write -> FAULT
        Insn("ldr", 0, 2, 0x600),     # AP=11 read  -> OK
        Insn("str", 0, 2, 0x600),     # AP=11 write -> FAULT
        # 切到 EL0：
        Insn("movz", 6, 0x4400, 1),   # EL0 入口 0x44000080
        Insn("movk", 6, 0x80),
        Insn("msr_sys", "elr_el1", 6),
        Insn("movz", 7, 0x3c0),       # EL0t + DAIF 全置位
        Insn("msr_sys", "spsr_el1", 7),
        Insn("eret"),
    ], BASE)
    el0 = assemble([
        Insn("label", "el0"),
        Insn("movz", 2, 0x4000, 1),   # 重设 VA 基址
        Insn("ldr", 0, 2, 0x000),     # AP=00 read  -> FAULT（EL0 无权限）
        Insn("ldr", 0, 2, 0x200),     # AP=01 read  -> OK
        Insn("str", 0, 2, 0x200),     # AP=01 write -> OK
        Insn("ldr", 0, 2, 0x400),     # AP=10 read  -> FAULT（EL0 无权限）
        Insn("ldr", 0, 2, 0x600),     # AP=11 read  -> OK
        Insn("str", 0, 2, 0x600),     # AP=11 write -> FAULT
        Insn("b", "el0"),             # 自循环
    ], 0x44000080)
    handler_el1 = assemble([
        Insn("movz", 9, 0xdead),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("add", 10, 10, 4),
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010200)  # EL1->EL1 同步 +0x200
    handler_el0 = assemble([
        Insn("movz", 9, 0xbeef),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("add", 10, 10, 4),
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010400)  # EL0->EL1 同步 +0x400

    buf = bytearray(0x84000)  # 覆盖代码 + 页表 + 4 个数据页（PA 0x44080000..）
    for i, w in enumerate(pre):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(el0):
        off = 0x80 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler_el1):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler_el0):
        off = 0x400 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)   # L0[0] -> L1
    put64(0x11000 + 1 * 8, 0x44012003)   # L1[1] -> L2（共享）
    put64(0x12000 + 0 * 8, 0x44013003)   # L2[0] -> L3_data
    put64(0x12000 + 32 * 8, 0x44015003)  # L2[32] -> L3_code
    put64(0x13000 + 0 * 8, 0x44080403)   # VA 0x40000000: AP=00, AF=1
    put64(0x13000 + 1 * 8, 0x44081443)   # VA 0x40001000: AP=01, AF=1
    put64(0x13000 + 2 * 8, 0x44082483)   # VA 0x40002000: AP=10, AF=1
    put64(0x13000 + 3 * 8, 0x440834C3)   # VA 0x40003000: AP=11, AF=1
    put64(0x15000 + 0 * 8, 0x440004C3)   # VA 0x44000000: 恒等 AP=11
    put64(0x15000 + 0x10 * 8, 0x440104C3)  # VA 0x44010000: 向量区 AP=11
    # 数据页预填已知值（读取结果可比较）：
    put64(0x80000 + 0 * 8, 0x1111222233334444)
    put64(0x81000 + 0 * 8, 0x5555666677778888)
    put64(0x82000 + 0 * 8, 0x9999AAAABBBBCCCC)
    put64(0x83000 + 0 * 8, 0xDDDDEEEEFFFF0000)
    Path(path).write_bytes(buf)
    return BASE


# ---- P5a-Hardening：L3 页描述符 AF=0 -> Access Flag fault（评估 R0.2）----
# 权威行为：TCR_EL1.HA=0（RTL 未实现 HAFDBS）时 AF=0 必须 fault（QEMU
# ptw.c: if (!(descriptor & (1 << 10)) && !param.ha) -> ARMFault_AccessFlag）。
# 当前 RTL：L3_WAIT 只查有效位与权限矩阵，未检查 AF -> 正常放行。
def build_hard_af_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16（HA=0）
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 2, 0x4000, 1),   # VA 0x40000000（AF=0 页）
        Insn("ldr", 0, 2, 0),         # -> Access Flag fault
        Insn("movz", 2, 0x66),        # 不会执行
    ], BASE)
    handler = assemble([
        Insn("movz", 9, 0xaffe),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("add", 10, 10, 4),       # 跳过 fault 指令
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 0 * 8, 0x44013003)
    put64(0x12000 + 32 * 8, 0x44015003)
    put64(0x13000 + 0 * 8, 0x44080043)   # VA 0x40000000: AP=01, AF=0
    put64(0x15000 + 0 * 8, 0x440004C3)
    put64(0x15000 + 0x10 * 8, 0x440104C3)
    Path(path).write_bytes(buf)
    return BASE


# ---- P5a-Hardening：取指 UXN/PXN 权限矩阵（评估 M0 第 3 项）----
# QEMU get_S1prot 权威行为：
#   EL1 取指：PXN=1 -> fault（IABT 0x21）；AP=01（EL0 可写）-> fault；
#             UXN=1 不影响 EL1。
#   EL0 取指：UXN=1 -> fault（IABT 0x20）；AP=00/10（无 EL0 读权限）
#             -> fault；PXN=1 不影响 EL0。
# 布局（恒等映射）：
#   VA 0x44001000: UXN=1, AP=11   （EL1 可执行，EL0 fault）
#   VA 0x44002000: PXN=1, AP=11   （EL1 fault，EL0 可执行）
#   VA 0x44003000: AP=01          （EL1/EL0 均可执行？EL1 取指 W^X fault）
def build_hard_uxn_pxn_program(path):
    def b_abs(pc, target):
        return 0x14000000 | (((target - pc) >> 2) & 0x3FFFFFF)

    # EL1 主流程（连续布局，续点固定）：
    # 0x44000034 br x1(UXN 页) -> OK -> 页代码 b 0x44000038（cont1）
    # 0x44000040 br x2(PXN 页) -> IABT -> handler -> cont2 0x44000044
    # 0x4400004c br x3(AP=01 页) -> IABT -> handler -> cont3 0x44000050
    main = assemble([
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 1, 0x4400, 1),   # x1 = 0x44001000（UXN=1 页）
        Insn("movk", 1, 0x1000),
        Insn("br", 1),                # @0x44000034：EL1 执行 UXN 页 -> OK
        Insn("movz", 2, 0x4400, 1),   # @0x44000038（cont1）
        Insn("movk", 2, 0x2000),      # x2 = 0x44002000（PXN=1 页）
        Insn("br", 2),                # @0x44000040：EL1 -> IABT
        Insn("movz", 3, 0x4400, 1),   # @0x44000044（cont2）
        Insn("movk", 3, 0x3000),      # x3 = 0x44003000（AP=01 页）
        Insn("br", 3),                # @0x4400004c：EL1 -> IABT（W^X）
        Insn("movz", 6, 0x4400, 1),   # @0x44000050（cont3）
        Insn("movk", 6, 0xa0),        # EL0 入口 0x440000a0
        Insn("msr_sys", "elr_el1", 6),
        Insn("movz", 7, 0x3c0),       # EL0t + DAIF 全置位
        Insn("msr_sys", "spsr_el1", 7),
        Insn("eret"),                 # @0x44000064
    ], BASE)
    el0 = assemble([
        Insn("movz", 14, 0x4400, 1),  # @0x440000a0
        Insn("movk", 14, 0x1000),
        Insn("br", 14),               # @0x440000a8：EL0 执行 UXN=1 -> IABT
        Insn("movz", 15, 0x4400, 1),  # @0x440000ac（cont4）
        Insn("movk", 15, 0x2000),
        Insn("br", 15),               # @0x440000b4：EL0 执行 PXN=1 -> OK
        Insn("movz", 16, 0x4400, 1),  # @0x440000b8（cont5）
        Insn("movk", 16, 0x3000),
        Insn("br", 16),               # @0x440000c0：EL0 执行 AP=01 -> OK
        Insn("b", "loop"),            # @0x440000c4（cont6）
        Insn("label", "loop"),        # 自循环
        Insn("b", "loop"),
    ], 0x440000a0)
    # 页代码：UXN 页（EL1 用）-> cont1；PXN/AP01 页（EL0 用）-> cont5/cont6
    page_uxn = assemble([
        Insn("movz", 11, 0x11),       # @0x44001000
        Insn("raw", b_abs(0x44001004, 0x44000038)),
    ], 0x44001000)
    page_pxn = assemble([
        Insn("movz", 12, 0x22),       # @0x44002000
        Insn("raw", b_abs(0x44002004, 0x440000b8)),
    ], 0x44002000)
    page_ap01 = assemble([
        Insn("movz", 13, 0x33),       # @0x44003000
        Insn("raw", b_abs(0x44003004, 0x440000c4)),
    ], 0x44003000)
    handler_el1 = assemble([
        Insn("movz", 9, 0xdead),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("movz", 11, 0x4400, 1),
        Insn("movk", 11, 0x2000),     # 与 PXN 页比较
        Insn("subs_reg", 31, 10, 11), # cmp
        Insn("b_cond", "ne", "is_ap01"),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, 0x44),       # cont2 = 0x44000044
        Insn("b", "wr_elr"),
        Insn("label", "is_ap01"),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, 0x50),       # cont3 = 0x44000050
        Insn("label", "wr_elr"),
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010200)
    handler_el0 = assemble([
        Insn("movz", 9, 0xbeef),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, 0xac),       # cont4 = 0x440000ac
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010400)

    buf = bytearray(0x19000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(el0):
        off = 0xa0 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(page_uxn):
        off = 0x1000 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(page_pxn):
        off = 0x2000 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(page_ap01):
        off = 0x3000 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler_el1):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler_el0):
        off = 0x400 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)          # L0[0] -> L1
    put64(0x11000 + 1 * 8, 0x44012003)          # L1[1] -> L2（共享）
    put64(0x12000 + 32 * 8, 0x44015003)         # L2[32] -> L3_code
    put64(0x15000 + 0 * 8, 0x440004C3)          # VA 0x44000000: AP=11
    put64(0x15000 + 0x10 * 8, 0x440104C3)       # VA 0x44010000: 向量区
    put64(0x15000 + 1 * 8, 0x400000440014C3)    # VA 0x44001000: AP=11, UXN=1
    put64(0x15000 + 2 * 8, 0x200000440024C3)    # VA 0x44002000: AP=11, PXN=1
    put64(0x15000 + 3 * 8, 0x44003443)          # VA 0x44003000: AP=01
    Path(path).write_bytes(buf)
    return BASE


# ---- P5a-Hardening：TTBR gap（非 canonical VA）-> 翻译 fault（M0 第 3 项）
# TCR T0SZ=16/T1SZ=16：T0 覆盖 [0, 2^48)，T1 覆盖 [0xFFFF..., 2^64)；
# VA 0x1000000000000 落在两区间的 gap 中。QEMU 报翻译 fault，
# RTL 以 TTBR1 遍历到无效描述符同样 fault，EC 一致（DABT 0x25）。
def build_hard_ttbr_gap_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = TTBR1 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("msr_sys", "ttbr1_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 0, 1, 3),        # x0 = 0x1000000000000（gap VA, 2^48）
        Insn("ldr", 1, 0, 0),         # -> 翻译 fault（DABT 0x25）
        Insn("movz", 2, 0x66),        # 不会执行
    ], BASE)
    handler = assemble([
        Insn("movz", 9, 0x5a5a),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("add", 10, 10, 4),       # 跳过 fault 指令
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)   # L0[0] -> L1（T0 用）
    put64(0x11000 + 1 * 8, 0x44012003)   # L1[1] -> L2（共享）
    put64(0x12000 + 32 * 8, 0x44015003)  # L2[32] -> L3_code（恒等）
    put64(0x15000 + 0 * 8, 0x440004C3)
    put64(0x15000 + 0x10 * 8, 0x440104C3)
    Path(path).write_bytes(buf)
    return BASE


# ---- P5a-Hardening：L3 PA 越界 -> fault（M0 第 3 项）----
# VA 0x40000000 映射到 PA 0x50000000：超出 RTL 1 MiB SRAM（0x44000000..
# 0x44100000）且超出 QEMU virt RAM，两侧均报 DABT（EC 0x25）。
def build_hard_pa_oob_program(path):
    main = assemble([
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR M=1
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 2, 0x4000, 1),   # VA 0x40000000
        Insn("ldr", 0, 2, 0),         # PA 0x50000000 越界 -> DABT
        Insn("movz", 1, 0x66),        # 不会执行
    ], BASE)
    handler = assemble([
        Insn("movz", 9, 0xc0de),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("add", 10, 10, 4),
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 0 * 8, 0x44013003)   # L2[0] -> L3_data
    put64(0x12000 + 32 * 8, 0x44015003)
    put64(0x13000 + 0 * 8, 0x50000443)   # VA 0x40000000 -> PA 0x50000000
    put64(0x15000 + 0 * 8, 0x440004C3)
    put64(0x15000 + 0x10 * 8, 0x440104C3)
    Path(path).write_bytes(buf)
    return BASE


# ---- M2-4a：ISB/DMB/DSB 屏障（顺序核语义）----
# 屏障在 ID 级等前方流水线（含未完成访存）排空后提交，并把取指重定向
# 到 next_pc 重新取（ISB 冲刷语义）。本程序验证屏障不改变架构状态、
# 与 QEMU 逐指令一致。
def build_hard_barrier_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 0, 0x11),
        Insn("dmb"),
        Insn("add", 1, 0, 1),
        Insn("dsb"),
        Insn("add", 2, 0, 1),
        Insn("isb"),
        Insn("add", 3, 0, 1),
        Insn("b", "main"),            # 自循环
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M2-4a/4b：自修改代码 + IC IVAU + ISB（验证冲刷后重取）----
# 0x44000038 处原始为 NOP；运行期用 32 位 store 覆盖为 movz x9,#0x1234，
# 然后 DMB、IC IVAU（失效 I-L1 对应行）、ISB。若无 IC IVAU/ISB 冲刷，
# 取指预取（或缓存命中）会拿到旧 NOP，x9 不变；有冲刷则 x9=0x1234
# （与 QEMU 一致）。全缓存（I+D+L2）配置下必须 IC IVAU 才能转绿。
def build_hard_selfmod_program(path):
    new_insn = 0xD2800000 | (0x1234 << 5) | 9    # movz x9, #0x1234
    hi = (new_insn >> 16) & 0xFFFF
    lo = new_insn & 0xFFFF
    words = assemble([
        Insn("label", "main"),
        Insn("movz", 0, 0x4400, 1),   # x0 = 0x44000038（目标指令地址）
        Insn("movk", 0, 0x38),
        Insn("movz", 1, hi, 1),       # x1 = new_insn
        Insn("movk", 1, lo),
        Insn("strw", 1, 0, 0),        # 32 位 store 到 0x44000038
        Insn("dmb"),
        Insn("ic_ivau", 0),           # M2-4b：失效 I-L1 中 0x44000038 行
        Insn("isb"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("nop"),
        Insn("raw", 0xD503201F),      # @0x44000038：原始 NOP
        Insn("b", "main"),            # 自循环
    ], BASE)
    Path(path).write_bytes(build_bytes(words))
    return BASE


# ---- M2-4b：TLBI 整表失效（改页表描述符后重新遍历）----
# 首次 ldr VA 0x40000000 -> PA 0x44008000（TLB 填充，x9=数据 A）；
# 运行时把 L3_data[0] 描述符改为 PA 0x44009000（数据 B），然后
# DC CIVAC/CVAU（写通层次无操作，验证识别提交）、TLBI VMALLE1IS、
# DSB/ISB、IC IVAU（MMU 开时数据翻译路径），再次 ldr 必须重新遍历
# 得到数据 B。RTL 若未实现 TLBI，会命中陈旧 TLB 得到 A 而与 QEMU 失配。
def build_hard_tlbi_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 0, 0x4000, 1),   # x0 = 0x40000000（数据 VA）
        Insn("ldr", 9, 0, 0),         # x9 = 数据 A（TLB 填充）
        Insn("movz", 1, 0x4400, 1),   # x1 = VA 0x44013000（L3_data 页）
        Insn("movk", 1, 0x1300),
        Insn("movz", 2, 0x94c3),      # 新描述符 = 0x440094C3
        Insn("movk", 2, 0x4400, 1),
        Insn("str", 2, 1, 0),         # 修改 L3_data[0] -> PA 0x44009000
        Insn("dsb"),
        Insn("dc_civac", 1),          # 写通层次无操作（验证识别提交）
        Insn("dc_cvau", 0),
        Insn("tlbi_vmalle1is"),       # 整表失效 TLB
        Insn("dsb"),
        Insn("isb"),
        Insn("ic_ivau", 0),           # MMU 开时维护 VA 数据翻译（无操作）
        Insn("isb"),
        Insn("ldr", 9, 0, 0),         # x9 = 数据 B（重新遍历）
        Insn("b", "main"),            # 自循环
    ], BASE)
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    # 页表：L0[0] -> L1；L1[1] -> L2；L2[0] -> L3_data（VA 0x40000000），
    # L2[32] -> L3_id（VA 0x44000000 恒等，L2 索引 = VA[29:21] = 32）
    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 0 * 8, 0x44013003)   # VA 0x40000000 -> L3_data
    put64(0x12000 + 32 * 8, 0x44014003)  # VA 0x44000000 -> L3_id（恒等）
    # L3_data[0]：VA 0x40000000 -> PA 0x44008000（数据 A）
    put64(0x13000 + 0 * 8, 0x440084C3)
    # L3_id：VA 0x44000000 起恒等映射（程序/向量/页表区）
    put64(0x14000 + 0 * 8, 0x440004C3)
    put64(0x14000 + 0x10 * 8, 0x440104C3)
    put64(0x14000 + 0x11 * 8, 0x440114C3)
    put64(0x14000 + 0x12 * 8, 0x440124C3)
    put64(0x14000 + 0x13 * 8, 0x440134C3)
    put64(0x14000 + 0x14 * 8, 0x440144C3)
    # 数据：A 在 PA 0x44008000，B 在 PA 0x44009000
    put64(0x8000, 0x1111111122222222)
    put64(0x9000, 0x3333333344444444)
    Path(path).write_bytes(buf)
    return BASE


# ---- ARMv8.2：DC CVAP 与 AT S1E0/S1E1P 定向差分 ----
# MMU 关闭时四类 AT 都应把 VA 直接编码为 PAR_EL1 成功结果；P 形式在
# PAN=0/1 两种状态都覆盖，DC CVAP 只验证权限和提交边界（当前模型没有
# 持久介质，因此不能产生伪 Store）。
def build_hard_maint_v82_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 0, 0x4400, 1),       # x0 = valid RAM VA
        Insn("at_s1e1r", 0),
        Insn("mrs_sys", 1, "par_el1"),
        Insn("at_s1e1w", 0),
        Insn("mrs_sys", 2, "par_el1"),
        Insn("at_s1e0r", 0),
        Insn("mrs_sys", 3, "par_el1"),
        Insn("at_s1e0w", 0),
        Insn("mrs_sys", 4, "par_el1"),
        Insn("at_s1e1rp", 0),            # PAN=0：E1 regime
        Insn("mrs_sys", 5, "par_el1"),
        Insn("msr_pan", 1),
        Insn("at_s1e1rp", 0),            # PAN=1：E1_PAN regime
        Insn("mrs_sys", 6, "par_el1"),
        Insn("at_s1e1wp", 0),
        Insn("mrs_sys", 7, "par_el1"),
        Insn("msr_pan", 0),
        Insn("dc_cvap", 0),
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


def build_hard_maint_v82_mmu_program(path):
    # 与 hard_tlbi 相同的 4K 页表：VA 0x40000000 -> PA 0x44008000
    #（AP=11，EL0 可读写），程序/向量页恒等映射到 L3_id。
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 0, 0x4000, 1),       # x0 = EL0 data VA
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("at_s1e1r", 0),
        Insn("mrs_sys", 1, "par_el1"),
        Insn("at_s1e1w", 0),
        Insn("mrs_sys", 2, "par_el1"),
        Insn("at_s1e0r", 0),
        Insn("mrs_sys", 3, "par_el1"),
        Insn("at_s1e0w", 0),
        Insn("mrs_sys", 4, "par_el1"),
        Insn("at_s1e1rp", 0),
        Insn("mrs_sys", 5, "par_el1"),
        Insn("msr_pan", 1),
        Insn("at_s1e1rp", 0),
        Insn("mrs_sys", 6, "par_el1"),
        Insn("at_s1e1wp", 0),
        Insn("mrs_sys", 7, "par_el1"),
        Insn("msr_pan", 0),
        Insn("dc_cvap", 0),
        Insn("b", "main"),
    ], BASE)
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 0 * 8, 0x44013003)
    put64(0x12000 + 32 * 8, 0x44014003)
    put64(0x13000 + 0 * 8, 0x440084C3)  # AP=11, AF=1, AttrIndx=0
    for idx in range(0, 0x15):
        put64(0x14000 + idx * 8, 0x44000000 + idx * 0x1000 + 0x4C3)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_maint_v82_el0_program(path):
    # EL0 的 DC CVAP 在 UCI=0 时由 QEMU trap 到 EL1（EC=0x18），而不是
    # UDEF；handler 读取 ESR、跳过 CVAP 后 ERET 回到 EL0。
    pre = assemble([
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 5),
        Insn("movz", 6, 0x4400, 1),
        Insn("movk", 6, 0x40),
        Insn("msr_sys", "elr_el1", 6),
        Insn("movz", 7, 0x3c0),
        Insn("msr_sys", "spsr_el1", 7),
        Insn("eret"),
    ], BASE)
    el0 = assemble([
        Insn("movz", 0, 0x4400, 1),
        Insn("dc_cvap", 0),
        Insn("movz", 1, 0x55),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], 0x44000040)
    handler = assemble([
        Insn("mrs_sys", 2, "esr_el1"),
        Insn("mrs_sys", 3, "elr_el1"),
        Insn("add", 4, 3, 4),
        Insn("msr_sys", "elr_el1", 4),
        Insn("eret"),
    ], 0x44010400)
    buf = bytearray(0x10600)
    for i, w in enumerate(pre):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(el0):
        off = 0x40 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x400 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- M2-4c：MAIR Device/不可缓存旁路 ----
# 三个 4 KiB 页分别用 MAIR attr0=Device-nGnRnE（0x00）、attr1=Normal NC
# （0x44）、attr2=Normal WB（0xFF），各映射到不同 PA；分别做 64 位读写。
# QEMU 不建模缓存行为，锁步验证的是旁路路径端到端正确（响应经
# L1D/L2 旁路直通 RAM）；“不分配行”由 L1D/L1I/L2 单元 TB 单独断言。
def build_hard_mair_bypass_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0x4400),      # MAIR：attr2=FF(WB), attr1=44(NC),
        Insn("movk", 5, 0xff, 1),     #       attr0=00(Device)
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        # Device 区域（attr0）：VA 0x40000000 -> PA 0x44008000
        Insn("movz", 0, 0x4000, 1),
        Insn("ldr", 9, 0, 0),         # x9 = 数据 A
        Insn("movz", 1, 0xaa),        # x1 = 0xAA（写 Device 区域）
        Insn("movk", 1, 0xbbbb, 1),
        Insn("str", 1, 0, 0),
        # Normal NC 区域（attr1）：VA 0x40001000 -> PA 0x44009000
        Insn("movz", 0, 0x4000, 1),
        Insn("movk", 0, 0x1000),
        Insn("ldr", 10, 0, 0),        # x10 = 数据 B
        Insn("movz", 2, 0xcc),
        Insn("movk", 2, 0xdddd, 1),
        Insn("str", 2, 0, 0),
        # Normal WB 区域（attr2）：VA 0x40002000 -> PA 0x4400A000
        Insn("movz", 0, 0x4000, 1),
        Insn("movk", 0, 0x2000),
        Insn("ldr", 11, 0, 0),        # x11 = 数据 C
        Insn("movz", 3, 0xee),
        Insn("movk", 3, 0xffff, 1),
        Insn("str", 3, 0, 0),
        # 回读 Device 区域确认旁路写生效
        Insn("movz", 0, 0x4000, 1),
        Insn("ldr", 12, 0, 0),        # x12 = 0xBBBB00AA
        Insn("b", "main"),            # 自循环
    ], BASE)
    buf = bytearray(0x17000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    # 页表：L0[0] -> L1；L1[1] -> L2；L2[0] -> L3_data（VA 0x40000000），
    # L2[32] -> L3_id（VA 0x44000000 恒等）
    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 0 * 8, 0x44013003)
    put64(0x12000 + 32 * 8, 0x44014003)
    # L3_data：Device(attr0) / NC(attr1) / WB(attr2) 三页
    put64(0x13000 + 0 * 8, 0x440084C3)   # VA 0x40000000 -> PA 0x44008000
    put64(0x13000 + 1 * 8, 0x440094C7)   # VA 0x40001000 -> PA 0x44009000, indx=1
    put64(0x13000 + 2 * 8, 0x4400A4CB)   # VA 0x40002000 -> PA 0x4400A000, indx=2
    # L3_id：恒等映射（程序/向量/页表区）
    put64(0x14000 + 0 * 8, 0x440004C3)
    put64(0x14000 + 0x10 * 8, 0x440104C3)
    put64(0x14000 + 0x11 * 8, 0x440114C3)
    put64(0x14000 + 0x12 * 8, 0x440124C3)
    put64(0x14000 + 0x13 * 8, 0x440134C3)
    put64(0x14000 + 0x14 * 8, 0x440144C3)
    # 数据：A / B / C
    put64(0x8000, 0x1111111122222222)
    put64(0x9000, 0x3333333344444444)
    put64(0xA000, 0x5555555566666666)
    Path(path).write_bytes(buf)
    return BASE


# ---- P6/Linux 前 R1：块描述符（2 MB / 1 GB）----
# L2[1] = 2 MB 块：VA 0x40200000 -> PA 0x44000000；L0[1]->L1b、
# L1b[0] = 1 GB 块：VA 0x8000000000 -> PA 0x40000000。两个块都在
# VA 偏移处落到 PA 0x44009000（标记数据），分别读/写验证。
def build_hard_block_desc_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF（WB）
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        # 2 MB 块：VA 0x40209000 -> PA 0x44009000
        Insn("movz", 0, 0x4020, 1),
        Insn("movk", 0, 0x9000),
        Insn("ldr", 9, 0, 0),         # x9 = 标记值
        Insn("movz", 2, 0xaa),
        Insn("movk", 2, 0xbbbb, 1),
        Insn("str", 2, 0, 0),         # 经 2MB 块写
        Insn("ldr", 10, 0, 0),        # x10 = 0xBBBB00AA
        # 1 GB 块：VA 0x8004009000 -> PA 0x44009000
        Insn("movz", 1, 0x8004, 1),
        Insn("movk", 1, 0x9000),
        Insn("ldr", 11, 1, 0),        # x11 = 0xBBBB00AA（块写后回读）
        Insn("movz", 3, 0xcc),
        Insn("movk", 3, 0xdddd, 1),
        Insn("str", 3, 1, 0),         # 经 1GB 块写
        Insn("ldr", 12, 1, 0),        # x12 = 0xDDDD00CC
        Insn("b", "main"),            # 自循环
    ], BASE)
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    # 页表：L0[0]->L1；L1[1]->L2；L2[32]->L3_id（恒等）；L2[1] 2MB 块；
    # L0[1]->L1b；L1b[0] 1GB 块
    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x10000 + 1 * 8, 0x44015003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 1 * 8, 0x440004C1)   # L2[1]：2MB 块 -> PA 0x44000000
    put64(0x12000 + 32 * 8, 0x44014003)  # L2[32] -> L3_id（恒等）
    put64(0x14000 + 0 * 8, 0x440004C3)
    put64(0x14000 + 0x10 * 8, 0x440104C3)
    put64(0x14000 + 0x11 * 8, 0x440114C3)
    put64(0x14000 + 0x12 * 8, 0x440124C3)
    put64(0x14000 + 0x13 * 8, 0x440134C3)
    put64(0x14000 + 0x14 * 8, 0x440144C3)
    put64(0x15000 + 0 * 8, 0x400004C1)   # L1b[0]：1GB 块 -> PA 0x40000000
    # 标记数据：PA 0x44009000
    put64(0x9000, 0x1122334455667788)
    Path(path).write_bytes(buf)
    return BASE


# ---- R1：空流水线取指 fault 合成提交 ----
# 使能 MMU（msr sctlr_el1, M=1）后，下一条指令 0x44001000 未映射：
# 取指翻译 fault 合并到 msr 的提交（QEMU step 插件同样把异常合并到前一条
# 指令的 pending 提交），RTL 若在空流水线下无法合并会死锁。
def build_hard_sys_fetch_fault_program(path):
    def b_abs(pc, target):
        return 0x14000000 | (((target - pc) >> 2) & 0x3FFFFFF)

    main = assemble([
        Insn("label", "main"),
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # x5 = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        # @0x44000028：b 0x44000FFC（映射页末尾，mmu_en=0 直取）
        Insn("raw", b_abs(0x44000028, 0x44000FFC)),
    ], BASE)
    # @0x44000FFC：msr sctlr_el1, x5（下一条 0x44001000 未映射）
    msr_sctlr = 0xD5181005
    handler = assemble([
        Insn("movz", 9, 0xdead),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], 0x44010200)
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    buf[0xFFC:0x1000] = struct.pack("<I", msr_sctlr)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)          # L0[0] -> L1
    put64(0x11000 + 1 * 8, 0x44012003)          # L1[1] -> L2
    put64(0x12000 + 32 * 8, 0x44014003)         # L2[32] -> L3_id
    put64(0x14000 + 0 * 8, 0x440004C3)          # VA 0x44000000（程序区）
    put64(0x14000 + 0x10 * 8, 0x440104C3)       # VA 0x44010000（向量区）
    put64(0x14000 + 0x11 * 8, 0x440114C3)
    put64(0x14000 + 0x12 * 8, 0x440124C3)
    put64(0x14000 + 0x13 * 8, 0x440134C3)
    put64(0x14000 + 0x14 * 8, 0x440144C3)
    # L3_id[1]（VA 0x44001000）保持 0：未映射 -> IABT
    Path(path).write_bytes(buf)
    return BASE


# ---- PE-F1A：system next-fetch context refresh 定向镜像 ----
def _mov_const_words(rd, value):
    """Return the shortest MOVZ/MOVK sequence for a 64-bit test constant."""
    value &= 0xFFFFFFFFFFFFFFFF
    parts = [(value >> (16 * i)) & 0xFFFF for i in range(4)]
    first = next((i for i, part in enumerate(parts) if part), 0)
    words = [Insn("movz", rd, parts[first], first)]
    for i in range(first + 1, 4):
        if parts[i]:
            words.append(Insn("movk", rd, parts[i], i))
    return words


def _build_hard_next_context_program(path, sys_reg, sys_value,
                                     old_target_mapped=True,
                                     new_target_mapped=True,
                                     new_ttbr0=None):
    """Build one same-PC context-refresh image for the F1a correction probe.

    The MSR is placed at VA 0x44000ffc, so its next PC is always
    0x44001000.  The old table can deliberately fault that page while a new
    TTBR0 table maps it, or both tables can map/fault it to exercise normal and
    fresh-fault outcomes without changing the public memory ABI.
    """
    def b_abs(pc, target):
        return 0x14000000 | (((target - pc) >> 2) & 0x3FFFFFF)

    setup = [
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x10),
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
    ]
    setup += _mov_const_words(5, sys_value)
    branch_pc = BASE + len(setup) * 4
    setup.append(Insn("raw", b_abs(branch_pc, BASE + 0xFFC)))
    main = assemble(setup, BASE)
    context_word = assemble([Insn("msr_sys", sys_reg, 5)], BASE + 0xFFC)[0]
    target = assemble([
        Insn("movz", 9, 0x55),
        Insn("b", "context_loop"),
        Insn("label", "context_loop"),
        Insn("b", "context_loop"),
    ], BASE + 0x1000)
    handler = assemble([
        Insn("movz", 9, 0xdead),
        Insn("label", "fault_loop"),
        Insn("b", "fault_loop"),
    ], BASE + 0x10200)

    image = bytearray(0x1C000)
    for i, word in enumerate(main):
        image[i * 4:i * 4 + 4] = struct.pack("<I", word)
    image[0xFFC:0x1000] = struct.pack("<I", context_word)
    if new_target_mapped:
        for i, word in enumerate(target):
            off = 0x1000 + i * 4
            image[off:off + 4] = struct.pack("<I", word)
    for i, word in enumerate(handler):
        off = 0x10000 + 0x200 + i * 4
        image[off:off + 4] = struct.pack("<I", word)

    def install_tables(off, map_target):
        put64(off + 0x0000, 0x44011003)
        put64(off + 0x1000 + 1 * 8, 0x44012003)
        put64(off + 0x2000 + 32 * 8, 0x44014003)
        put64(off + 0x4000 + 0 * 8, 0x440004C3)
        if map_target:
            put64(off + 0x4000 + 1 * 8, 0x440014C3)
        put64(off + 0x4000 + 0x10 * 8, 0x440104C3)

    def put64(off, value):
        image[off:off + 8] = struct.pack("<Q", value)

    install_tables(0x10000, old_target_mapped)
    if new_ttbr0 is not None:
        new_base = 0x18000
        put64(new_base + 0x0000, 0x44019003)
        put64(new_base + 0x1000 + 1 * 8, 0x4401A003)
        put64(new_base + 0x2000 + 32 * 8, 0x4401B003)
        put64(new_base + 0x3000 + 0 * 8, 0x440004C3)
        if new_target_mapped:
            put64(new_base + 0x3000 + 1 * 8, 0x440014C3)
        put64(new_base + 0x3000 + 0x10 * 8, 0x440104C3)

    Path(path).write_bytes(image)
    return BASE


def build_hard_next_context_tcr_program(path):
    """MMU-on TCR MSR with a same-PC normal FIFO refresh."""
    return _build_hard_next_context_program(path, "tcr_el1", 0x10)


def build_hard_next_context_ttbr0_fault_program(path):
    """Old TTBR0 fault head, refreshed TTBR0 fault, and merged MSR write."""
    return _build_hard_next_context_program(
        path, "ttbr0_el1", 0x44018000,
        old_target_mapped=False, new_target_mapped=False, new_ttbr0=0x44018000)


def build_hard_next_context_ttbr1_program(path):
    """MMU-on TTBR1 MSR with a same-PC normal FIFO refresh."""
    return _build_hard_next_context_program(path, "ttbr1_el1", 0x44018000)


def build_hard_next_context_mair_program(path):
    """MMU-on MAIR MSR with a same-PC normal FIFO refresh."""
    return _build_hard_next_context_program(path, "mair_el1", 0xff)


def _build_hard_next_context_fifo_program(path, sys_reg, sys_value):
    """Fill FIFO with an MSR and its next target behind a MUL stall."""
    setup = [
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x10),
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
    ]
    setup += _mov_const_words(5, sys_value)
    setup += [
        Insn("movz", 0, 3),
        Insn("movz", 1, 4),
        Insn("mul", 2, 0, 1),
        Insn("msr_sys", sys_reg, 5),
        Insn("movz", 9, 0x55),
        Insn("b", "context_fifo_loop"),
        Insn("label", "context_fifo_loop"),
        Insn("b", "context_fifo_loop"),
    ]
    main = assemble(setup, BASE)
    image = bytearray(0x16000)
    for i, word in enumerate(main):
        image[i * 4:i * 4 + 4] = struct.pack("<I", word)

    def put64(off, value):
        image[off:off + 8] = struct.pack("<Q", value)

    handler = assemble([
        Insn("movz", 9, 0xdead),
        Insn("label", "context_fifo_fault_loop"),
        Insn("b", "context_fifo_fault_loop"),
    ], BASE + 0x10200)
    for i, word in enumerate(handler):
        off = 0x10000 + 0x200 + i * 4
        image[off:off + 4] = struct.pack("<I", word)
    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 32 * 8, 0x44014003)
    put64(0x14000 + 0 * 8, 0x440004C3)
    put64(0x14000 + 0x10 * 8, 0x440104C3)
    Path(path).write_bytes(image)
    return BASE


def build_hard_next_context_tcr_fifo_program(path):
    """TCR same-PC refresh with old normal FIFO target behind MUL."""
    return _build_hard_next_context_fifo_program(path, "tcr_el1", 0x10)


def build_hard_next_context_ttbr1_fifo_program(path):
    """TTBR1 same-PC refresh with old normal FIFO target behind MUL."""
    return _build_hard_next_context_fifo_program(path, "ttbr1_el1", 0x44018000)


def build_hard_next_context_mair_fifo_program(path):
    """MAIR same-PC refresh with old normal FIFO target behind MUL."""
    return _build_hard_next_context_fifo_program(path, "mair_el1", 0xff)


def build_hard_next_context_sctlr_disable_program(path):
    """SCTLR.M=0 negative control: no MMU refresh redirect is required."""
    return _build_hard_next_context_program(path, "sctlr_el1", 0,
                                             old_target_mapped=True,
                                             new_target_mapped=True)


def build_hard_next_context_sctlr_disable_fault_program(path):
    """Old MMU fault followed by SCTLR.M=0 and MMU-off fresh normal fetch."""
    return _build_hard_next_context_program(path, "sctlr_el1", 0,
                                             old_target_mapped=False,
                                             new_target_mapped=True)


def build_hard_next_context_sctlr_disable_fault_fifo_program(path):
    """Fill an old fault FIFO head before committing SCTLR.M=0."""
    def b_abs(pc, target):
        return 0x14000000 | (((target - pc) >> 2) & 0x3FFFFFF)

    setup = [
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x10),
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 5, 0),
    ]
    branch_pc = BASE + len(setup) * 4
    setup.append(Insn("raw", b_abs(branch_pc, BASE + 0xFE8)))
    main = assemble(setup, BASE)
    tail = assemble([
        Insn("movz", 0, 3),
        Insn("movz", 1, 4),
        Insn("raw", 0xD503201F),
        Insn("raw", 0xD503201F),
        # Keep the long-latency operation immediately before the page-end
        # MSR.  While MUL holds the pipeline, the MSR remains in IF/ID and
        # the old-context fetch for 0x44001000 can become a FIFO fault head
        # even with MEM_DELAY_MODE=2.  Earlier placement filled the FIFO with
        # the two NOPs/MSR and made the d2 old-fault precondition unreachable.
        Insn("mul", 2, 0, 1),
        Insn("msr_sys", "sctlr_el1", 5),
    ], BASE + 0xFE8)
    target = assemble([
        Insn("movz", 9, 0x55),
        Insn("b", "context_disable_fault_loop"),
        Insn("label", "context_disable_fault_loop"),
        Insn("b", "context_disable_fault_loop"),
    ], BASE + 0x1000)
    handler = assemble([
        Insn("movz", 9, 0xDEAD),
        Insn("label", "context_disable_fault_handler_loop"),
        Insn("b", "context_disable_fault_handler_loop"),
    ], BASE + 0x10200)

    image = bytearray(0x1C000)
    for i, word in enumerate(main):
        image[i * 4:i * 4 + 4] = struct.pack("<I", word)
    for i, word in enumerate(tail):
        off = 0xFE8 + i * 4
        image[off:off + 4] = struct.pack("<I", word)
    for i, word in enumerate(target):
        off = 0x1000 + i * 4
        image[off:off + 4] = struct.pack("<I", word)
    for i, word in enumerate(handler):
        off = 0x10000 + 0x200 + i * 4
        image[off:off + 4] = struct.pack("<I", word)

    def put64(off, value):
        image[off:off + 8] = struct.pack("<Q", value)

    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 32 * 8, 0x44014003)
    put64(0x14000 + 0 * 8, 0x440004C3)
    put64(0x14000 + 0x10 * 8, 0x440104C3)
    Path(path).write_bytes(image)
    return BASE


# ---- R1：MMU 使能后 MSR 提交（修潜在死锁）----
# 此前 mmu_en=1 时任何 MSR（如 tcr_el1）都要求 fetch_next_settled 但
# 没有取指重定向，永不满足而死锁。修复后 MSR 提交前预翻译下一条取指
# （映射成功则正常提交）。本程序在 MMU 开启后执行 msr tcr_el1 并继续
# 已映射代码，验证不再死锁且与 QEMU 锁步。
def build_hard_msr_mmu_on_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 5, 0x4401, 1),   # TTBR0 = 0x44010000
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),    # TCR：T0SZ=16, T1SZ=16
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),        # MAIR attr0 = 0xFF
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),     # SCTLR = 0xC50839（M=1）
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        # MMU 已开启：msr tcr_el1（写回 0x100010 同值）必须提交且不阻塞
        Insn("movz", 5, 0x100010),
        Insn("msr_sys", "tcr_el1", 5),
        # 继续已映射代码
        Insn("b", "main"),            # 自循环
    ], BASE)
    # 注意：0x44000028 的 msr sctlr 后继续 0x4400002c（已映射恒等页），
    # 因此本程序聚焦“mmu_en=1 时 MSR 不阻塞”，取指全部映射。
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 32 * 8, 0x44014003)
    put64(0x14000 + 0 * 8, 0x440004C3)
    put64(0x14000 + 0x10 * 8, 0x440104C3)
    put64(0x14000 + 0x11 * 8, 0x440114C3)
    put64(0x14000 + 0x12 * 8, 0x440124C3)
    put64(0x14000 + 0x13 * 8, 0x440134C3)
    put64(0x14000 + 0x14 * 8, 0x440144C3)
    Path(path).write_bytes(buf)
    return BASE


# ---- R1：ESR_EL1/FAR_EL1 完整 syndrome + MRS 回读 ----
# EL1 下对未映射 VA 0x50000000 做 32 位 store -> DABT；handler 用 MRS
# 读 ESR_EL1/FAR_EL1 到 x9/x10，验证异常入口写入的 syndrome 与故障地址
# 架构可见（QEMU 锁步比较 GPR 写回）。
def build_hard_esr_far_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 0, 0x5000, 1),   # x0 = 0x50000000（未映射）
        Insn("movz", 1, 0x77),
        Insn("strw", 1, 0, 0),        # 32 位 store -> DABT（EC=0x25）
        Insn("movz", 2, 0x66),        # 不会执行
        Insn("b", "main"),
    ], BASE)
    handler = assemble([
        Insn("mrs_sys", 9, "esr_el1"),   # x9 = ESR_EL1
        Insn("mrs_sys", 10, "far_el1"),  # x10 = FAR_EL1（= 0x50000000）
        Insn("mrs_sys", 11, "elr_el1"),
        Insn("add", 11, 11, 4),          # 跳过 strw
        Insn("msr_sys", "elr_el1", 11),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10600)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- M3：编译器常用指令形式（逻辑位掩码立即数 + 位域）----
# 编码取自 aarch64-linux-gnu-as（objdump 校验）：mov(位掩码)/lsr/asr
# 立即数（UBFM/SBFM）/and/eor/orr 移位/sxtb/ubfx/lsl 立即数。
def build_hard_compiler_isa_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("raw", 0x3204cfe0),   # mov w0, #0xf0f0f0f0（ORR 位掩码）
        Insn("raw", 0xd344fc01),   # lsr x1, x0, #4（UBFM）
        Insn("raw", 0x9344fc02),   # asr x2, x0, #4（SBFM）
        Insn("raw", 0x8a010003),   # and x3, x0, x1
        Insn("raw", 0xca020004),   # eor x4, x0, x2
        Insn("raw", 0xaa011005),   # orr x5, x0, x1, lsl #4
        Insn("raw", 0x13001c06),   # sxtb w6, w0
        Insn("raw", 0xd3482c07),   # ubfx x7, x0, #8, #4
        Insn("raw", 0xd37df008),   # lsl x8, x0, #3
        Insn("movz", 9, 0x1234),
        Insn("movz", 10, 0xf0f0),  # 32 位 ORR-imm 第二例
        Insn("raw", 0x3200cfeb),   # mov w11, #0x0f0f0f0f
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：LDP/STP（成对 load/store，全寻址模式）----
# 编码取自 aarch64-linux-gnu-as/objdump：offset / pre-index / post-index，
# X 对与 W 对。覆盖双 GPR 写回与双存储提交。
def build_hard_pair_ldst_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 8, 0x4401, 1),   # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 0, 0x1111),
        Insn("movz", 1, 0x2222),
        Insn("movz", 2, 0x4408, 1),   # 数据区基址 0x44080000
        Insn("raw", 0xa9000440),      # stp x0, x1, [x2]（offset）
        Insn("raw", 0xa9401043),      # ldp x3, x4, [x2]
        Insn("movz", 5, 0x5555),
        Insn("movz", 6, 0x6666),
        Insn("movz", 4, 0x4408, 1),
        Insn("movk", 4, 0x1000),      # x4 = 0x44081000（基址）
        Insn("raw", 0xa9bf1885),      # stp x5, x6, [x4, #-16]!（pre）
        Insn("raw", 0xa8c12087),      # ldp x7, x8, [x4], #16（post）
        Insn("movz", 9, 0x99),
        Insn("movz", 10, 0xaa),
        Insn("movz", 11, 0x4408, 1),
        Insn("movk", 11, 0x2000),
        Insn("raw", 0x29012969),      # stp w9, w10, [x11, #8]（W 对）
        Insn("movz", 14, 0x4408, 1),
        Insn("movk", 14, 0x3000),
        Insn("raw", 0x2940b5cc),      # ldp w12, w13, [x14, #4]
        # LDPSW：两个相邻 W 分别符号扩展到 X，覆盖低/高半各自写回。
        # 使用 x22–x26，避免破坏下方故意以 x17=0 触发的 DABT。
        Insn("movz", 22, 0x4408, 1),
        Insn("movk", 22, 0x4000),     # x22 = 0x44084000
        Insn("movz", 23, 0x8000),
        Insn("movk", 23, 0xffff, 1),  # w23 = 0xffff8000
        Insn("strw", 23, 22, 0),
        Insn("movz", 24, 8),
        Insn("strw", 24, 22, 1),
        Insn("ldpsw", 25, 26, 22, 0),
        Insn("movz", 15, 0x1),
        Insn("movz", 16, 0x2),
        Insn("raw", 0xa93e422f),      # stp x15, x16, [x17, #-32]
        Insn("b", "main"),
    ], BASE)
    handler = assemble([
        Insn("movz", 9, 0xcafe),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], 0x44010200)
    buf = bytearray(0x10400)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- M3：寄存器偏移寻址（数组访问）----
# ldr/str [rn, rm, lsl #shift]，含 byte/half/word/dword、LDRSW、LDRSB、
# LDRSH、SP 基址；编码取自 aarch64-linux-gnu-as/objdump。
def build_hard_reg_offset_program(path):
    main = assemble([
        Insn("label", "main"),
        # X 对寄存器偏移：x4 基址 0x44080000，索引 x1=2 -> off 16
        Insn("movz", 4, 0x4408, 1),
        Insn("movz", 1, 0x2),
        Insn("movz", 2, 0x4408, 1),
        Insn("movz", 0, 0x2),
        Insn("movz", 1, 0x99),
        Insn("raw", 0xf8207841),      # str x1, [x2, x0, lsl 3] -> mem[0x44080010]
        Insn("movz", 1, 0x2),         # 恢复索引 x1=2
        Insn("raw", 0xf8617882),      # ldr x2, [x4, x1, lsl 3] -> x2 = 0x99
        # byte（LDRB）：x5 基址 0x44080100，x6=0
        Insn("movz", 5, 0x4408, 1),
        Insn("movk", 5, 0x100),
        Insn("movz", 6, 0),
        Insn("movz", 7, 0xcc),
        Insn("strb", 7, 5, 0),
        Insn("raw", 0x386668a3),      # ldrb w3, [x5, x6] -> w3 = 0xcc
        # half（LDRH）：x8 基址 0x44080200，x9=2 -> off 2
        Insn("movz", 8, 0x4408, 1),
        Insn("movk", 8, 0x200),
        Insn("movz", 9, 0x2),
        Insn("movz", 10, 0xbeef),
        Insn("strh", 10, 8, 0),
        Insn("raw", 0x78697907),      # ldrh w7, [x8, x9, lsl 1] -> w7 = 0xbeef
        # word（STRW）：x11 基址 0x44080400，x12=4 -> off 16
        Insn("movz", 11, 0x4408, 1),
        Insn("movk", 11, 0x400),
        Insn("movz", 12, 0x4),
        Insn("movz", 10, 0xdead),
        Insn("raw", 0xb82c796a),      # str w10, [x11, x12, lsl 2]
        Insn("movz", 14, 0x4408, 1),
        Insn("movk", 14, 0x400),
        Insn("movz", 15, 0x4),
        Insn("raw", 0xb8af69cd),      # ldrsw x13, [x14, x15, lsl 2]
        # SP 基址（无移位）
        Insn("movz", 15, 0x4408, 1),
        Insn("movk", 15, 0x600),
        Insn("add", 31, 15, 0),       # sp = 0x44080600
        Insn("movz", 16, 0x55),
        Insn("str", 16, 31, 0),
        Insn("movz", 0, 0),
        Insn("raw", 0xf8606bf0),      # ldr x16, [sp, x0] -> x16 = 0x55
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：扩展寄存器 ADD/SUB（数组索引计算）----
# add/sub Rd, Rn, Rm, <ext> #<shift>；编码取自 aarch64-linux-gnu-as。
def build_hard_ext_addsub_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 2, 0x1000),
        Insn("movz", 0, 0x8),
        Insn("raw", 0x8b204c41),      # add x1, x2, w0, uxtw #3 -> x1 = 0x1040
        Insn("movz", 4, 0x2000),
        Insn("movz", 5, 0x4),
        Insn("raw", 0xcb25c883),      # sub x3, x4, w5, sxtw #2 -> x3 = 0x1ff0
        Insn("movz", 7, 0x10),
        Insn("movz", 8, 0x3),
        Insn("raw", 0x0b2800e6),      # add w6, w7, w8, uxtb -> w6 = 0x13
        Insn("movz", 10, 0x100),
        Insn("movz", 11, 0x2),
        Insn("raw", 0xcb0b0549),      # sub x9, x10, x11, lsl #1 -> x9 = 0xfe
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：乘除 request-capture 定向程序 ----
# 显式覆盖 MUL/UDIV/SDIV 的 W/X 形式、UMULH/SMULH 以及 W/X 除零；
# 该程序供 T-20260905-004 的 batch L2 锁步入口复用，避免把已有 hazard
# 程序中的部分覆盖误当成完整 request 边界覆盖。
def build_hard_muldiv_request_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movn", 0, 9),             # x0 = -10（W 低半也为 -10）
        Insn("movz", 1, 3),
        Insn("mul", 2, 0, 1),           # X：-10 * 3
        Insn("mul_w", 3, 0, 1),         # W：低 32 位乘法、结果零扩展
        Insn("umulh", 4, 0, 1),         # unsigned high: (2^64-10)*3 -> 2
        Insn("smulh", 5, 0, 1),         # signed high: -10*3 -> all ones
        Insn("udiv", 6, 0, 1),          # X unsigned
        Insn("sdiv", 7, 0, 1),          # X signed
        Insn("udiv_w", 8, 0, 1),        # W unsigned
        Insn("sdiv_w", 9, 0, 1),         # W signed
        Insn("udiv", 10, 0, 31),        # X div0 (XZR)
        Insn("sdiv", 11, 0, 31),        # X div0 (XZR)
        Insn("udiv_w", 12, 0, 31),      # W div0 (XZR)
        Insn("sdiv_w", 13, 0, 31),      # W div0 (XZR)
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：MADD/MSUB/SMADDL/UMADDL 乘加族 ----
# 编码取自 aarch64-linux-gnu-as/objdump。加/减由 bit15 区分
# （bit15=1 为 MSUB/SMSUBL/UMSUBL 族）。
def build_hard_madd_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 2, 0x10),
        Insn("movz", 3, 0x5),
        Insn("movz", 4, 0x7),
        Insn("raw", 0x9b031041),      # madd x1, x2, x3, x4 -> 0x57
        Insn("movz", 6, 0x100),
        Insn("movz", 7, 0x3),
        Insn("movz", 8, 0x1),
        Insn("raw", 0x1b07a0c5),      # msub w5, w6, w7, w8 -> 1 - 0x300 = -0x2ff
        Insn("movz", 10, 0xffff),     # w10 = -1
        Insn("movz", 11, 0x2),
        Insn("movz", 12, 0x1000),
        Insn("raw", 0x9b2b3149),      # smaddl x9, w10, w11, x12 -> 0x1000 - 2
        Insn("movz", 14, 0xff),
        Insn("movz", 15, 0x2),
        Insn("movz", 16, 0x1),
        Insn("raw", 0x9b2fc1cd),      # smsubl x13, w14, w15, x16 -> 1 - 0x1fe
        Insn("movz", 0, 0x1234),
        Insn("movz", 1, 0x5678),
        Insn("movz", 2, 0x10),
        Insn("raw", 0x9ba10811),      # umaddl x17, w0, w1, x2
        Insn("movz", 4, 0x5),
        Insn("movz", 5, 0x100),
        Insn("movz", 6, 0x3),
        Insn("raw", 0x9ba59883),      # umsubl x3, w4, w5, x6
        # 边界：b=0（RTL 曾误走除零短路，结果应为 Ra 而非 0）
        Insn("movz", 19, 0x33),
        Insn("movz", 20, 0x55),
        Insn("raw", 0x9b1f5272),      # madd x18, x19, xzr, x20 -> 0x55
        # 边界：a=0
        Insn("movz", 22, 0x77),
        Insn("movz", 23, 0x99),
        Insn("raw", 0x9b165ff5),      # madd x21, xzr, x22, x23 -> 0x99
        # 边界：32 位乘积溢出（0x10000 * 0x20000 33 位，需截断低 32 位）
        Insn("movz", 25, 0x10000),
        Insn("movz", 26, 0x20000),
        Insn("movz", 27, 0x123),
        Insn("raw", 0x1b1a6f38),      # madd w24, w25, w26, w27 -> 0x123
        # SMULH：负数×正数，验证有符号乘积高半
        Insn("movn", 28, 0),
        Insn("movz", 29, 1),
        Insn("smulh", 30, 28, 29),
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：CSEL/CSINC/CSINV/CSNEG 条件选择族 ----
# 编码取自 aarch64-linux-gnu-as/objdump。每例前面用 subs_reg 显式设置
# NZCV，覆盖条件真/假两分支与 32/64 位语义。
def build_hard_csel_program(path):
    main = assemble([
        Insn("label", "main"),
        # CSEL/CSINC（X）：eq/ne 两分支
        Insn("movz", 1, 0x1111),
        Insn("movz", 2, 0x2222),
        Insn("subs_reg", 3, 31, 31),       # n=0 z=1 c=1 v=0
        Insn("raw", 0x9a820020),           # csel x0, x1, x2, eq -> 0x1111（真）
        Insn("raw", 0x9a821424),           # csinc x4, x1, x2, ne -> 0x2223（假）
        Insn("raw", 0x9a820424),           # csinc x4, x1, x2, eq -> 0x1111（真）
        Insn("subs_reg", 3, 1, 31),        # 0x1111 -> n=0 z=0 c=1
        Insn("raw", 0x9a821020),           # csel x0, x1, x2, ne -> 0x1111（真）
        Insn("raw", 0x9a820020),           # csel x0, x1, x2, eq -> 0x2222（假）
        # CSINV/CSNEG（X）：ls/cs 两分支
        Insn("movz", 7, 0x77),
        Insn("movz", 8, 0x88),
        Insn("subs_reg", 3, 31, 31),       # z=1 c=1 -> ls 假
        Insn("raw", 0xda8890e6),           # csinv x6, x7, x8, ls -> ~0x88
        Insn("subs_reg", 3, 31, 31),
        Insn("raw", 0xda8820e6),           # csinv x6, x7, x8, cs -> 0x77（真）
        Insn("movz", 10, 0xa0),
        Insn("movz", 11, 0xb0),
        Insn("subs_reg", 3, 31, 31),       # c=1 -> cs 真
        Insn("raw", 0xda8b2549),           # csneg x9, x10, x11, cs -> 0xa0
        Insn("subs_reg", 3, 31, 11),       # 0-0xb0 -> c=0 n=1 z=0
        Insn("raw", 0xda8b9549),           # csneg x9, x10, x11, ls -> -0xb0
        # W 形式：csel/csinc
        Insn("movz_w", 13, 0x13),
        Insn("movz_w", 14, 0x14),
        Insn("subs_reg", 3, 31, 31),       # z=1 -> gt 假 / le 真
        Insn("raw", 0x1a8ec1ac),           # csel w12, w13, w14, gt -> 0x14
        Insn("raw", 0x1a8ed1ac),           # csel w12, w13, w14, le -> 0x13
        Insn("movz_w", 16, 0x16),
        Insn("movz_w", 17, 0x17),
        Insn("subs_reg", 3, 31, 31),       # z=1 -> gt 假
        Insn("raw", 0x1a91c60f),           # csinc w15, w16, w17, gt -> 0x18
        Insn("subs_reg", 3, 31, 1),        # n=1 z=0 v=0 -> le 真
        Insn("raw", 0x1a91d60f),           # csinc w15, w16, w17, le -> 0x16
        # W 形式：csinv/csneg（32 位取反/取负回绕）
        Insn("movz_w", 19, 0x19),
        Insn("movz_w", 20, 0x20),
        Insn("subs_reg", 3, 31, 31),       # n=0 -> pl 真 / mi 假
        Insn("raw", 0x5a945272),           # csinv w18, w19, w20, pl -> 0x19
        Insn("raw", 0x5a944272),           # csinv w18, w19, w20, mi -> ~0x20
        Insn("subs_reg", 3, 31, 1),        # n=1 -> mi 真
        Insn("raw", 0x5a944272),           # csinv w18, w19, w20, mi -> 0x19
        Insn("movz_w", 22, 0x22),
        Insn("movz_w", 23, 0),
        Insn("movk_w", 23, 0x8000, 1),     # w23 = 0x80000000
        Insn("subs_reg", 3, 31, 31),       # n=0 -> pl 真
        Insn("raw", 0x5a9756d5),           # csneg w21, w22, w23, pl -> 0x22
        Insn("subs_reg", 3, 31, 1),        # n=1 -> pl 假
        Insn("raw", 0x5a9756d5),           # csneg w21, w22, w23, pl -> 0x80000000
        # XZR 操作数（条件选择用 XZR 而非 SP）
        Insn("movz", 25, 0x25),
        Insn("raw", 0x9a99e3f8),           # csel x24, xzr, x25, al -> 0
        Insn("movz", 26, 0x26),
        Insn("raw", 0x9a9fe358),           # csel x24, x26, xzr, al -> 0x26
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：BFM 位域插入（BFI/BFXIL/BFC 别名）----
# 编码取自 aarch64-linux-gnu-as/objdump。覆盖 si>=ri（提取插入）、
# si<ri（左移插入）、r==s 单比特、全宽 64、W 形式高 32 清零、源 XZR。
def build_hard_bfm_program(path):
    main = assemble([
        Insn("label", "main"),
        # X：bfi（si<ri 左移插入）
        Insn("movn", 0, 0),              # x0 = -1（旧 Rd）
        Insn("movz", 1, 0xab),
        Insn("raw", 0xb37c1c20),         # bfi x0, x1, #4, #8 -> 0xfffffffffffffabf
        # X：bfxil（si>=ri 提取插入低位）
        Insn("movn", 2, 0),
        Insn("movz", 3, 0xabcd),
        Insn("raw", 0xb3442c62),         # bfxil x2, x3, #4, #8 -> 0xffffffffffffffbc
        # r==s 单比特
        Insn("movz", 5, 0xffff),
        Insn("raw", 0xb34618a4),         # bfm x4, x5, #6, #6 -> x4 = x5[6] = 1
        # 全宽 64 位覆盖（si=63, ri=0）
        Insn("movz", 7, 0xdead),
        Insn("movk", 7, 0xbeef, 1),
        Insn("raw", 0xb340fce6),         # bfm x6, x7, #0, #63 -> x6 = x7
        # W：bfi 高 32 位清零
        Insn("movn", 8, 0),              # w8 = -1
        Insn("movz_w", 9, 0x1234),
        Insn("raw", 0x33103d28),         # bfi w8, w9, #16, #16 -> 0x1234ffff（字段外保留）
        # W：bfxil
        Insn("movn", 10, 0),
        Insn("movz_w", 11, 0xabcd),
        Insn("raw", 0x33042d6a),         # bfxil w10, w11, #4, #8 -> 0xffffffbc
        # W：bfm 宽字段（si=28>=ri=3，len=26）
        Insn("movz_w", 12, 0),
        Insn("movn_w", 13, 0),           # w13 = -1
        Insn("raw", 0x330371ac),         # bfm w12, w13, #3, #28 -> 0x03ffffff
        # 源 XZR：字段清 0，字段外保留旧 Rd
        Insn("movn", 14, 0),
        Insn("raw", 0xb37c1fee),         # bfi x14, xzr, #4, #8 -> 0xfffffffffffff00f
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：覆盖率补缺（BLR + LDRSB/LDRSH + PRFM）----
# 编码取自 aarch64-linux-gnu-as/objdump。BLR 验证间接调用链接写回与
# 冲刷；LDRSB/LDRSH 覆盖 unsigned-immediate 与寄存器偏移两种寻址、
# W/X 两种符号扩展宽度（W=32 位符号扩展+零扩展，X=64 位符号扩展）；
# PRFM 按 NOP 与 QEMU 一致。
def build_hard_insn_gaps_program(path):
    main = assemble([
        Insn("label", "main"),
        # ---- BLR：x30 = pc+4，跳 target；中间的 movz 应被跳过 ----
        Insn("adr", 0, "target"),
        Insn("raw", 0xd63f0000),           # blr x0（x0 = &target）
        Insn("movz", 1, 0xdead),           # 不应执行
        Insn("label", "target"),
        Insn("movz", 2, 0x42),
        # ---- LDRSB/LDRSH（unsigned immediate）----
        Insn("movz", 4, 0x4408, 1),        # 0x44080000
        Insn("movz_w", 5, 0x80),
        Insn("strb", 5, 4, 0),             # mem[0x44080000] = 0x80
        Insn("raw", 0x39c00086),           # ldrsb w6, [x4] -> 0xffffff80
        Insn("raw", 0x39800087),           # ldrsb x7, [x4] -> 0xffffffffffffff80
        Insn("movz", 8, 0x4408, 1),
        Insn("movk", 8, 0x20),             # 0x44080020
        Insn("movz_w", 9, 0xbeef),
        Insn("strh", 9, 8, 0),             # mem[0x44080020] = 0xbeef
        Insn("raw", 0x79c00106),           # ldrsh w6, [x8] -> 0xffffbeef
        Insn("raw", 0x79800107),           # ldrsh x7, [x8] -> 0xffffffffffffbeef
        # ---- LDRSB/LDRSH（寄存器偏移）----
        Insn("movz", 10, 0x4408, 1),
        Insn("movk", 10, 0x40),            # 0x44080040
        Insn("movz_w", 11, 0x80),
        Insn("strb", 11, 10, 0),
        Insn("movz", 12, 0),               # 索引 0
        Insn("raw", 0x38ec694d),           # ldrsb w13, [x10, x12] -> 0xffffff80
        Insn("raw", 0x38ac694e),           # ldrsb x14, [x10, x12] -> 0xffffffffffffff80
        Insn("movz", 15, 0x4408, 1),
        Insn("movk", 15, 0x60),            # 0x44080060
        Insn("movz_w", 16, 0xbeef),
        Insn("strh", 16, 15, 0),
        Insn("movz", 17, 0),               # 索引 0
        Insn("raw", 0x78f169f2),           # ldrsh w18, [x15, x17] -> 0xffffbeef
        Insn("raw", 0x78b169f3),           # ldrsh x19, [x15, x17] -> 0xffffffffffffbeef
        # ---- PRFM 按 NOP（两种寻址）----
        Insn("raw", 0xf9800080),           # prfm pldl1keep, [x4]
        Insn("raw", 0xf8ac6940),           # prfm pldl1keep, [x10, x12]
        Insn("b", "main"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：LDR literal（PC 相对加载，W/X/LDRSW/PRFM）----
# 编码由 a64.py 按标签两遍汇编生成（imm19 ±1MiB）。literal 池放在
# 程序末尾作为死数据，循环回 main 后不会被取指。
def build_hard_ldr_literal_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("ldr_w_lit", 0, "lit32"),      # w0 = 0x11223344（零扩展）
        Insn("ldr_lit", 1, "lit64"),        # x1 = 0x11223344_44556677
        Insn("ldrsw_lit", 2, "litneg"),     # x2 = 0xfffffffff1234567
        Insn("prfm_lit", 0, "lit32"),       # PRFM literal 按 NOP
        Insn("b", "main"),
        Insn("label", "lit32"),
        Insn("raw", 0x11223344),
        Insn("label", "lit64"),             # 8 字节对齐（0x44000018）
        Insn("raw", 0x44556677),
        Insn("raw", 0x11223344),
        Insn("label", "litneg"),
        Insn("raw", 0xf1234567),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- M3：exclusive 指令（LDXR/LDAXR/STXR/STLXR/CLREX）----
# 覆盖：同地址同值通过、直接 STXR 失败、CLREX 清、跨 size（LDXR X
# 后 STXR W，QEMU 按 STXR 宽度截取比较）、普通 STR 改值后失败、
# 地址不匹配失败、rs=31 结果丢弃、byte/half/word/dword 尺寸、
# LDAXR/STLXR、异常入口不清 + ERET 清（SVC 往返）。
# 编码由 a64.py 生成（check_encoders 已与 GNU as 对照）。
def build_hard_exclusive_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 20, 0x4408, 1),     # 数据基址 0x44080000
        Insn("movz", 1, 0x4401, 1),      # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 1),
        # A: LDXR X -> STXR X 同地址同值：通过 w4=0，mem=0x55
        Insn("movz", 2, 0x55),
        Insn("ldxr", 3, 20),
        Insn("stxr", 4, 2, 20),
        # B: 直接 STXR（无 LDXR）：失败 w6=1，不写
        Insn("movz", 5, 0x66),
        Insn("stxr", 6, 5, 20),
        # C: LDXR -> CLREX -> STXR：失败 w8=1
        Insn("ldxr", 7, 20),
        Insn("clrex"),
        Insn("stxr", 8, 5, 20),
        # D: LDXR X -> STXR W（低 32 位相等）：QEMU 允许跨 size，
        #    按 STXR 宽度截取比较 -> 通过 w10=0，写 4 字节
        Insn("ldxr", 9, 20),
        Insn("stxr_w", 10, 5, 20),
        # E: LDXR X -> STR X 改值 -> STXR X：失败 w12=1
        Insn("ldxr", 11, 20),
        Insn("movz", 13, 0x99),
        Insn("str", 13, 20, 0),
        Insn("stxr", 12, 13, 20),
        # F: 地址不匹配：失败 w16=1
        Insn("ldxr", 14, 20),
        Insn("movz", 15, 0x4408, 1),
        Insn("movk", 15, 0x80),          # 0x44080080
        Insn("stxr", 16, 14, 15),
        # G: STXR rs=31：结果丢弃，但通过时照写 mem=0xaa
        Insn("ldxr", 17, 20),
        Insn("movz", 18, 0xaa),
        Insn("stxr", 31, 18, 20),
        Insn("ldr", 19, 20, 0),          # x19 = 0xaa（验证写入）
        # H: LDAXR -> STLXR：通过 w22=0
        Insn("ldaxr", 21, 20),
        Insn("stlxr", 22, 21, 20),
        # I: byte/half 尺寸
        Insn("movz", 23, 0x4408, 1),
        Insn("movk", 23, 0x100),         # 0x44080100
        Insn("movz_w", 24, 0),
        Insn("strb", 24, 23, 0),         # 清零该字节
        Insn("ldxrb", 25, 23),
        Insn("movz_w", 26, 0x7b),
        Insn("stxrb", 27, 26, 23),       # 通过 w27=0
        Insn("ldrb", 28, 23, 0),         # x28 = 0x7b
        Insn("movz", 23, 0x4408, 1),
        Insn("movk", 23, 0x200),         # 0x44080200
        Insn("movz_w", 24, 0),
        Insn("strh", 24, 23, 0),
        Insn("ldxrh", 25, 23),
        Insn("movz_w", 26, 0xbeef),
        Insn("stxrh", 27, 26, 23),       # 通过 w27=0
        Insn("ldrh", 28, 23, 0),         # x28 = 0xbeef
        # K: LDXP X -> STLXP X 同地址同值：通过 w9=0，写 {x6,x7} 两段
        Insn("movz", 6, 0x1122, 1),
        Insn("movk", 6, 0x3344, 2),
        Insn("movk", 6, 0x5566, 3),      # x6 = 0x5566334400001122
        Insn("ldxp", 7, 8, 20),          # x7=mem[20], x8=mem[20+8]
        Insn("stlxp", 9, 6, 7, 20),      # 写 {x6,x7}，w9=0
        Insn("ldr", 10, 20, 0),          # x10 = 0x5566334400001122
        # L: LDXP -> STR 改低半 -> STXP：失败 w3=1，不写
        Insn("ldxp", 11, 12, 20),        # 记录 {x11,x12}
        Insn("movz", 13, 0xff),
        Insn("str", 13, 20, 0),          # 改 mem[20]
        Insn("stxp", 3, 11, 12, 20),     # 低半不匹配 -> w3=1
        # J: 异常入口不清 + ERET 清（探针实测语义）：
        Insn("ldxr", 0, 20),             # monitor: addr=0x44080000
        Insn("svc", 0),                  # -> handler（EL1h +0x200）
        Insn("stxr", 3, 5, 20),          # 返回后：ERET 已清 -> 失败 w3=1
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    handler = assemble([
        Insn("stxr", 1, 5, 20),          # 异常入口未清 -> 通过 w1=0
        Insn("mrs_sys", 2, "elr_el1"),   # ELR = svc+4
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10400)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    off = 0x10200
    for i, w in enumerate(handler):
        buf[off + i * 4:off + i * 4 + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


# ---- P6：LSE 原子指令定向测试 ----
# 覆盖单寄存器 LDADD/LDCLR/LDEOR/LDSET/LDSMAX/LDSMIN/LDUMAX/LDUMIN/SWP
# 的 W/X 形式、ST*（Rt=XZR）别名、CAS/CASA/CASL/CASAL 的匹配/不匹配，
# 以及 32 位加法回绕和 acquire/release 位。原子操作均使用独立字节/字
# 地址，锁步同时比较旧值写回和条件 Store 副作用。
def build_hard_lse_atomic_program(path):
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 20, 0x4408, 1),       # x20 = 0x44080000
        # LDADDAL W：0xffffffff + 1 按 32 位回绕为 0，旧值写 x3
        Insn("movz_w", 1, 1),
        Insn("strw", 1, 20, 0),
        Insn("movn_w", 2, 0),
        Insn("lse", "add", 2, 3, 2, 20, 1, 1),
        # LDCLR W
        Insn("movz_w", 1, 0x0f), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 0x03),
        Insn("lse", "clr", 2, 4, 2, 20),
        # LDSET W
        Insn("movz_w", 1, 1), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 4),
        Insn("lse", "set", 2, 5, 2, 20, 1, 0),
        # LDEOR W
        Insn("movz_w", 1, 0xaa), Insn("strw", 1, 20, 0),
        Insn("movn_w", 2, 0),
        Insn("lse", "eor", 2, 6, 2, 20, 0, 1),
        # LDSMAX/LDSMIN W（有符号 -1/1）
        Insn("movn_w", 1, 0), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 1),
        Insn("lse", "smax", 2, 7, 2, 20),
        Insn("movn_w", 1, 0), Insn("strw", 1, 20, 0),
        Insn("lse", "smin", 2, 8, 2, 20),
        # LDUMAX/LDUMIN W（无符号 0xffffffff/1）
        Insn("movn_w", 1, 0), Insn("strw", 1, 20, 0),
        Insn("lse", "umax", 2, 9, 2, 20),
        Insn("movn_w", 1, 0), Insn("strw", 1, 20, 0),
        Insn("lse", "umin", 2, 10, 2, 20),
        # SWP W
        Insn("movz_w", 1, 0x11), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 0x22),
        Insn("lse", "swp", 2, 11, 2, 20, 1, 1),
        # STCLR/STADD/STSET/STEOR W（Rt=XZR，不写回旧值）
        Insn("movz_w", 1, 0xff), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 0x0f), Insn("lse", "clr", 2, 31, 2, 20),
        Insn("movz_w", 1, 1), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 2), Insn("lse", "add", 2, 31, 2, 20, 0, 1),
        Insn("movz_w", 1, 0x01), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 0x04), Insn("lse", "set", 2, 31, 2, 20),
        Insn("movz_w", 1, 0xaa), Insn("strw", 1, 20, 0),
        Insn("movn_w", 2, 0), Insn("lse", "eor", 2, 31, 2, 20),
        # CASAL W 匹配：Rs 读回旧值，Rt 写入新值
        Insn("movz_w", 1, 0x33), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 0x44),
        Insn("cas", 2, 1, 2, 20, 1, 1),
        # CASL W 不匹配：不写内存，Rs 得到内存旧值
        Insn("movz_w", 1, 0x44), Insn("strw", 1, 20, 0),
        Insn("movz_w", 1, 0x55), Insn("movz_w", 2, 0x66),
        Insn("cas", 2, 1, 2, 20, 0, 1),
        # CASAL W Rs=XZR 不匹配：比较 0，QEMU 的幻影 MEM_W 必须丢弃
        Insn("movz_w", 1, 0x77), Insn("strw", 1, 20, 0),
        Insn("movz_w", 2, 0x88), Insn("cas", 2, 31, 2, 20, 1, 1),
        # CASPAL X 对匹配：比较 {x0,x1}，写入 {x2,x3}，返回旧对
        Insn("movz", 0, 0x1111), Insn("movz", 1, 0x2222),
        Insn("str", 0, 20, 0), Insn("str", 1, 20, 1),
        Insn("movz", 2, 0x3333), Insn("movz", 3, 0x4444),
        Insn("casp", 0, 2, 20, 1, 1),
        # CASP X 对不匹配：不产生两段 Store
        Insn("movz", 0, 0x5555), Insn("movz", 1, 0x6666),
        Insn("str", 0, 20, 0), Insn("str", 1, 20, 1),
        Insn("movz", 0, 0x7777), Insn("movz", 1, 0x8888),
        Insn("movz", 2, 0x9999), Insn("movz", 3, 0xaaaa),
        Insn("casp", 0, 2, 20, 0, 0),
        # LDADD X 与 CAS X（匹配/不匹配）
        Insn("movz", 1, 0x5678), Insn("movk", 1, 0x1234, 1),
        Insn("str", 1, 20, 0),
        Insn("movz", 2, 1), Insn("lse", "add", 3, 3, 2, 20),
        Insn("movz", 1, 0x1111), Insn("movk", 1, 0x2222, 1),
        Insn("str", 1, 20, 0),
        Insn("movz", 2, 0x3333), Insn("movk", 2, 0x4444, 1),
        Insn("cas", 3, 1, 2, 20, 1, 0),
        Insn("movz", 1, 0x7777), Insn("str", 1, 20, 0),
        Insn("movz", 1, 0x8888), Insn("movz", 2, 0x9999),
        Insn("cas", 3, 1, 2, 20, 0, 0),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


# ---- P6：LSE128 LDCLRP/LDSETP/SWPP 定向测试 ----
# 三族只有 X 寄存器对；W 形式通过 W 写入源/旧值覆盖 32 位初始化和
# 零扩展边界。rt2 使用非连续字段，另覆盖 rn=SP、a/r 组合、非法
# rt2=rt/31，以及对齐、物理越界和 MMU 翻译 fault。异常 handler 只跳过
# faulting instruction，便于在同一条锁步窗口继续验证后续事务。
def build_hard_lse128_program(path):
    main = assemble([
        Insn("movz", 8, 0x4401, 1),       # VBAR = 0x44010000
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 20, 0x4408, 1),      # x20 = 0x44080000

        # LDCLRP X：非连续 rt2=7，a/r=11；W 初始化源值，验证高半
        # 新值来自 old & ~source 而不是原始 source 高值。
        Insn("movz_w", 1, 0x00f0), Insn("str", 1, 20, 0),
        Insn("movz_w", 3, 0x003f), Insn("str", 3, 20, 1),
        Insn("movz_w", 2, 0x000f), Insn("movz_w", 7, 0x0030),
        Insn("lse128", "clrp", 2, 7, 20, 1, 1),

        # LDSETP X：rt2=9，a/r=10。
        Insn("movz_w", 1, 0x0001), Insn("str", 1, 20, 0),
        Insn("movz_w", 3, 0x0002), Insn("str", 3, 20, 1),
        Insn("movz_w", 4, 0x0004), Insn("movz_w", 9, 0x0008),
        Insn("lse128", "setp", 4, 9, 20, 1, 0),

        # SWPP X：rt2=11，a/r=01。
        Insn("movz_w", 1, 0x0011), Insn("str", 1, 20, 0),
        Insn("movz_w", 3, 0x0022), Insn("str", 3, 20, 1),
        Insn("movz_w", 6, 0x0033), Insn("movz_w", 11, 0x0044),
        Insn("lse128", "swpp", 6, 11, 20, 0, 1),

        # rn=31 is SP, not XZR.  Use a separate aligned location.
        Insn("add", 21, 20, 0x40),
        Insn("add", 31, 21, 0),
        Insn("movz_w", 12, 0x0055), Insn("str", 12, 31, 0),
        Insn("movz_w", 14, 0x0066), Insn("str", 14, 31, 1),
        Insn("movz_w", 12, 0x0077), Insn("movz_w", 14, 0x0088),
        Insn("lse128", "swpp", 12, 14, 31, 1, 1),

        # QEMU decode rejects rt2=rt and rt2=31 as UDEF; handler advances.
        Insn("lse128", "clrp", 2, 2, 20),
        Insn("lse128", "setp", 4, 31, 20),

        # Alignment fault (no Store request is allowed).
        Insn("add", 23, 20, 1),
        Insn("lse128", "clrp", 2, 7, 23),

        # Start outside SRAM: DABT before the first read/write.
        Insn("movz", 23, 0x4800, 1),
        Insn("lse128", "setp", 4, 9, 23),

        # Enable a minimal identity code/vector map, then fault on a
        # canonical-gap VA to exercise the second (data) translation path.
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 5, 0x100010),
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1), Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 23, 1, 3),             # VA 0x1000000000000 gap
        Insn("lse128", "clrp", 2, 7, 23, 1, 0),
        Insn("b", "loop"),
        Insn("label", "loop"), Insn("b", "loop"),
    ], BASE)
    handler = assemble([
        Insn("mrs_sys", 18, "elr_el1"),
        Insn("add", 18, 18, 4),
        Insn("msr_sys", "elr_el1", 18),
        Insn("eret"),
    ], 0x44010200)

    # Code/vector plus the same 4 KiB page tables used by the P5a MMU tests.
    buf = bytearray(0x16000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x10200 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    # L0 -> L1 -> L2; L2[32] covers VA 0x44000000 and L3 maps code/vector.
    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 32 * 8, 0x44015003)
    put64(0x15000 + 0x00 * 8, 0x440004C3)   # code, AP=11
    put64(0x15000 + 0x10 * 8, 0x440104C3)   # vector/handler, AP=11
    Path(path).write_bytes(buf)
    return BASE


# ---- P6：WFI/WFE 等待边界 smoke ----
# 第一阶段先验证等待指令自身退休、QEMU idle 回调与下一条 PC；IRQ
# 唤醒/向量入口由后续 hard_wfi_timer_irq 覆盖。
def build_hard_wfi_program(path):
    main = assemble([
        Insn("movz", 0, 1),
        Insn("wfi"),
        Insn("movz", 1, 2),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


def build_hard_wfe_program(path):
    main = assemble([
        Insn("movz", 0, 1),
        Insn("wfe"),
        Insn("b", "loop"),
        Insn("label", "loop"), Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


def build_hard_wfit_wfet_timer_program(path):
    """WFIT/WFET 超时等待：验证 Xt 依赖、虚拟计数到期和无 IRQ 恢复。"""
    main = assemble([
        Insn("mrs_sys", 0, "cntvct_el0"),
        Insn("add", 0, 0, 8),
        Insn("wfit", 0),
        Insn("movz", 1, 0x1234),
        Insn("mrs_sys", 2, "cntvct_el0"),
        Insn("add", 2, 2, 8),
        Insn("wfet", 2),
        Insn("movz", 3, 0x5678),
        # 已到期的 WFIT 不应进入 idle；SEVL 后的 WFET 应消费事件并继续。
        Insn("movz", 4, 0),
        Insn("wfit", 4),
        Insn("sevl"),
        Insn("wfet", 4),
        Insn("movz", 5, 0x9abc),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(build_bytes(main))
    return BASE


def _build_hard_wfi_timer_irq_program(path, virtual=False):
    """WFI 后由 Generic Timer PPI 唤醒，验证合成 IRQ 提交与 ERET。"""
    cval_reg = "cntv_cval_el0" if virtual else "cntp_cval_el0"
    ctl_reg = "cntv_ctl_el0" if virtual else "cntp_ctl_el0"
    ppi_value = 0x0800 if virtual else 0x4000
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 10, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 10),
        # GICD/GICC 基本使能，打开 PPI26（physical timer）
        Insn("movz", 20, 0x0800, 1),
        Insn("movz", 21, 0x0801, 1),
        Insn("movz_w", 1, 1), Insn("strw", 1, 20, 0),
        Insn("strw", 1, 21, 0),
        Insn("movz_w", 1, 0xff), Insn("strw", 1, 21, 1),
        Insn("movz_w", 1, 0), Insn("strw", 1, 21, 2),
        Insn("movz", 1, ppi_value, 1),    # virtual=PPI27, physical=PPI30
        Insn("strw", 1, 20, 0x40),        # GICD_ISENABLER0 +0x100
        # CNTP CVAL = current + 50; enable timer, unmask IRQ
        Insn("mrs_sys", 0, "cntpct_el0"),
        Insn("add", 0, 0, 50),
        Insn("msr_sys", cval_reg, 0),
        Insn("movz", 1, 1), Insn("msr_sys", ctl_reg, 1),
        Insn("daifclr", 2),
        Insn("wfi"),
        Insn("movz", 5, 0x55),
        Insn("b", "loop"),
        Insn("label", "loop"), Insn("b", "loop"),
    ], BASE)
    handler = assemble([
        Insn("mrs_sys", 2, "elr_el1"),
        Insn("mrs_sys", 3, "spsr_el1"),
        Insn("ldrw", 4, 21, 3),
        Insn("strw", 4, 21, 4),
        Insn("msr_sys", ctl_reg, 31),
        Insn("eret"),
    ], 0x44010280)
    buf = bytearray(0x10400)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x10280 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_wfi_timer_irq_program(path):
    return _build_hard_wfi_timer_irq_program(path, virtual=False)


def build_hard_wfi_virtual_timer_irq_program(path):
    return _build_hard_wfi_timer_irq_program(path, virtual=True)


# ---- P6：固定 QEMU ID/CLIDR 只读清单差分 ----
QEMU_ID_SYSREGS = [
    "id_aa64pfr0_el1", "id_aa64pfr1_el1", "id_aa64pfr2_el1",
    "id_aa64smfr0_el1", "id_aa64fpfr0_el1",
    "id_aa64dfr0_el1", "id_aa64dfr1_el1",
    "id_aa64afr0_el1", "id_aa64afr1_el1",
    "id_aa64isar0_el1", "id_aa64isar1_el1",
    "id_aa64isar2_el1", "id_aa64isar3_el1",
    "id_aa64mmfr0_el1", "id_aa64mmfr1_el1",
    "id_aa64mmfr2_el1", "id_aa64mmfr3_el1",
    "id_aa64mmfr4_el1",
    "id_pfr0_el1", "id_pfr1_el1", "id_dfr0_el1", "id_afr0_el1",
    "id_mmfr0_el1", "id_mmfr1_el1", "id_mmfr2_el1", "id_mmfr3_el1",
    "id_isar0_el1", "id_isar1_el1", "id_isar2_el1", "id_isar3_el1",
    "id_isar4_el1", "id_isar5_el1", "id_mmfr4_el1", "id_isar6_el1",
    "mvfr0_el1", "mvfr1_el1", "mvfr2_el1", "id_pfr2_el1",
    "id_dfr1_el1", "id_mmfr5_el1", "clidr_el1",
    "id_aa64zfr0_el1", "ctr_el0", "dczid_el0",
]


def build_hard_id_sysreg_program(path):
    main = [Insn("mrs_sys", i % 31, reg)
            for i, reg in enumerate(QEMU_ID_SYSREGS)]
    main += [Insn("b", "loop"), Insn("label", "loop"), Insn("b", "loop")]
    build_program(path, assemble(main, BASE))
    return BASE


# ---- P6：SVE/SME 探测兼容（ZCR/SMCR/SMPRI/CSSELR + RDVL/RDSVL）----
# 覆盖：ZCR_EL1/SMCR_EL1 LEN 写读往返、SMPRI_EL1（QEMU SMPS=0）RES0
# 读写、SMPRI 写不影响 SMCR、RDVL/RDSVL 按当前 LEN 的标量 VL 计算、
# CSSELR_EL1 低 5 位写读。全部与 QEMU -cpu max 逐条锁步比较。
def build_hard_sve_probe_program(path):
    main = assemble([
        Insn("label", "main"),
        # ---- 先使能 EL1 的 FP/SVE/SME 访问（FPEN/ZEN/SMEN=3）----
        Insn("movz", 0, 0x333, 1),           # x0 = 0x03330000
        Insn("msr_sys", "cpacr_el1", 0),
        # ---- ZCR_EL1：LEN=0xf -> RDVL#1 = (0xf+1)*16 = 256 ----
        Insn("movz", 0, 0xf),
        Insn("msr_sys", "zcr_el1", 0),
        Insn("mrs_sys", 1, "zcr_el1"),       # 0xf
        Insn("rdvl", 2, 1),                  # 256
        Insn("rdvl", 3, 2),                  # 512
        # ---- SMCR_EL1：LEN=0xf -> RDSVL#1 = 256 ----
        Insn("msr_sys", "smcr_el1", 0),
        Insn("mrs_sys", 4, "smcr_el1"),      # 0xf
        Insn("rdsvl", 5, 1),                 # 256
        # ---- SMPRI_EL1：RES0，写忽略，SMCR 不受影响 ----
        Insn("mrs_sys", 6, "smpri_el1"),     # 0
        Insn("msr_sys", "smpri_el1", 0),     # 写 0xf 被忽略
        Insn("mrs_sys", 7, "smpri_el1"),     # 仍 0
        Insn("mrs_sys", 8, "smcr_el1"),      # 仍 0xf
        # ---- SMCR 写 0x40（低 4 位为 0）后读回 0（Linux 探测模式）----
        Insn("movz", 14, 0x40),
        Insn("msr_sys", "smcr_el1", 14),
        Insn("mrs_sys", 15, "smcr_el1"),     # 0
        Insn("movz", 16, 0xf),
        Insn("msr_sys", "smcr_el1", 16),     # 恢复 0xf
        Insn("mrs_sys", 17, "smcr_el1"),     # 0xf
        # ---- Linux sme_probe 精确模式：mrs;and;orr;msr 后读回 0 ----
        Insn("movz", 1, 0x40),
        Insn("mrs_sys", 0, "smcr_el1"),      # 0xf
        Insn("raw", 0x927cec00),             # and x0, x0, #~0xf
        Insn("orr", 0, 0, 1),                # orr x0, x0, x1 -> 0x40
        Insn("msr_sys", "smcr_el1", 0),
        Insn("mrs_sys", 2, "smcr_el1"),      # 0
        # ---- ZCR LEN=0 -> RDVL#1 = 16 ----
        Insn("movz", 9, 0),
        Insn("msr_sys", "zcr_el1", 9),
        Insn("mrs_sys", 10, "zcr_el1"),      # 0
        Insn("rdvl", 11, 1),                 # 16
        # ---- ZCR LEN=0xe 与 SMCR LEN=0xe：QEMU 按支持 VL 映射取最高档 ----
        Insn("movz", 9, 0xe),
        Insn("msr_sys", "zcr_el1", 9),
        Insn("mrs_sys", 10, "zcr_el1"),      # 0xe
        Insn("rdvl", 11, 1),                 # 与 QEMU sve_vq 映射一致
        Insn("movz", 14, 0xe),
        Insn("msr_sys", "smcr_el1", 14),
        Insn("mrs_sys", 15, "smcr_el1"),     # 0xe
        # QEMU sme_vq.map 只有 2 的幂档：LEN=14 取整到 7 -> 128 字节
        Insn("rdsvl", 11, 1),                # 0x80
        # ---- CSSELR_EL1：写 0xb（Level=5、Ind=1），读回低 4 位 ----
        Insn("movz", 12, 0xb),
        Insn("msr_sys", "csselr_el1", 12),
        Insn("mrs_sys", 13, "csselr_el1"),   # 0xb
        # ---- SMIDR_EL1 / AIDR_EL1（QEMU IMPDEF 恒 0）----
        Insn("mrs_sys", 18, "smidr_el1"),    # 0
        Insn("mrs_sys", 19, "aidr_el1"),     # 0
        # ---- RNDR/RNDRRS：difftest 确定性镜像 + NZCV=0000 ----
        Insn("mrs_sys", 20, "rndr"),         # = timer_count
        Insn("mrs_sys", 21, "rndrrs"),       # = timer_count
        Insn("mrs_sys", 22, "nzcv"),         # RNDR 置 ZF=1 -> 0
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


# ---- P6：Linux 启动 ISA 缺口（REV/CLZ/CLS/CCMP/CCMN/BTI + MSR-i +
# 系统寄存器）----
# 覆盖：REV/REV16/REV32（W/X 字节反转）、CLZ/CLS 边界（0/全 1/MSB）、
# CCMP/CCMN 立即数/寄存器（条件真=比较标志、条件假=NZCV 立即数）、
# BTI 提示按 NOP、DAIFSet/DAIFClr（经 SVC 的 SPSR 观察）、SPSel
# （SP 银行切换 + EL1t 向量偏移 + ERET 恢复）、新系统寄存器 MRS/MSR
# 往返与只读 ID 寄存器（与 QEMU -cpu max 值逐寄存器比较）。
def build_hard_p6_isa_program(path):
    main = assemble([
        Insn("label", "main"),
        # ---- RBIT/REV/REV16/REV32/CLZ/CLS ----
        Insn("movz", 0, 0x1234),
        Insn("movk", 0, 0x5678, 1),
        Insn("movk", 0, 0x9abc, 2),
        Insn("movk", 0, 0xdef0, 3),   # x0 = 0xdef09abc56781234
        Insn("rbit", 1, 0),            # 按位反转（X）
        Insn("rbit_w", 2, 0),          # 按位反转（W，零扩展）
        Insn("rev", 1, 0),            # 0x34127856bc9af0de
        Insn("rev16", 2, 0),          # 0xf0debc9a78563412
        Insn("rev32", 3, 0),          # 0x9abcdef034127856
        Insn("rev_w", 4, 0),          # 0x34127856
        Insn("rev16_w", 5, 0),        # 0x78563412
        Insn("clz", 6, 0),            # MSB 置位 -> 0
        Insn("clz", 7, 31),           # clz xzr -> 64
        Insn("movz", 8, 1),
        Insn("clz", 9, 8),            # 1 -> 63
        Insn("movz", 10, 0x8000, 1),
        Insn("clz_w", 11, 10),        # 0x80000000 -> 0
        Insn("cls", 12, 0),           # 0xdef0.. bit62=1 bit61=0 -> 1
        Insn("cls", 13, 31),          # cls xzr -> 63
        Insn("movn", 14, 0),
        Insn("cls", 15, 14),          # cls -1 -> 63
        # ---- CCMP/CCMN（经 mrs nzcv 观察）----
        Insn("movz", 16, 0x10),
        Insn("cmp", 16, 0x10),        # Z=1 C=1
        Insn("ccmp", 16, 0x10, 0x5, "eq"),   # 条件真 -> sub 标志 0101
        Insn("mrs_sys", 17, "nzcv"),          # x17 = 0x50000000
        Insn("cmp", 16, 0x20),        # N=1 C=0
        Insn("ccmp", 16, 0x20, 0x7, "eq"),   # 条件假 -> NZCV=0111
        Insn("mrs_sys", 18, "nzcv"),          # x18 = 0x70000000
        Insn("ccmn", 16, 16, 0x9, "eq"),      # 条件真 -> add 标志 0000
        Insn("mrs_sys", 19, "nzcv"),          # x19 = 0
        Insn("ccmp_reg", 16, 16, 0xa, "ne"),  # 条件假 -> NZCV=1010
        Insn("mrs_sys", 20, "nzcv"),          # x20 = 0xa0000000
        Insn("ccmp_reg_w", 16, 16, 0x4, "eq"),  # W 形式条件真 -> 0101
        Insn("mrs_sys", 21, "nzcv"),          # x21 = 0x50000000
        Insn("ccmn_w", 16, 1, 0x6, "lt"),     # W 条件假 -> NZCV=0110
        Insn("mrs_sys", 22, "nzcv"),          # x22 = 0x60000000
        # ---- BTI 提示（NOP）----
        Insn("bti"),
        Insn("bti", "j"),
        Insn("bti", "jc"),
        # ---- 新系统寄存器 MRS/MSR 往返 ----
        Insn("movz", 23, 0x4408, 1),
        Insn("msr_sys", "tpidr_el0", 23),
        Insn("mrs_sys", 24, "tpidr_el0"),     # x24 = 0x44080000
        Insn("msr_sys", "cpacr_el1", 23),
        Insn("mrs_sys", 25, "cpacr_el1"),
        Insn("msr_sys", "mdscr_el1", 23),
        Insn("mrs_sys", 26, "mdscr_el1"),
        Insn("msr_sys", "osdlr_el1", 31),  # Linux debug shim：RAZ/WI
        Insn("mrs_sys", 30, "osdlr_el1"),
        Insn("msr_sys", "oslar_el1", 31),  # Linux debug shim：RAZ/WI
        # Linux 关闭 hardware breakpoint/watchpoint：P6 对全部 n 接受零写，
        # 返回零；这里覆盖 BVR/BCR/WVR/WCR 四类与非零槽位 n=5。
        Insn("msr_sys", "dbgbvr0_el1", 31),
        Insn("mrs_sys", 30, "dbgbvr0_el1"),
        Insn("msr_sys", "dbgbcr0_el1", 31),
        Insn("mrs_sys", 30, "dbgbcr0_el1"),
        Insn("msr_sys", "dbgwvr0_el1", 31),
        Insn("mrs_sys", 30, "dbgwvr0_el1"),
        Insn("msr_sys", "dbgwcr0_el1", 31),
        Insn("mrs_sys", 30, "dbgwcr0_el1"),
        Insn("msr_sys", "dbgbcr5_el1", 31),
        Insn("mrs_sys", 30, "dbgbcr5_el1"),
        Insn("msr_sys", "pmuserenr_el0", 23),
        Insn("mrs_sys", 27, "pmuserenr_el0"),
        Insn("msr_sys", "cntkctl_el1", 23),
        Insn("mrs_sys", 28, "cntkctl_el1"),
        Insn("msr_sys", "tpidrro_el0", 23),
        Insn("mrs_sys", 29, "tpidrro_el0"),
        Insn("msr_sys", "sp_el0", 23),
        Insn("mrs_sys", 1, "sp_el0"),
        Insn("msr_sys", "tcr2_el1", 23),
        Insn("mrs_sys", 2, "tcr2_el1"),
        Insn("msr_sys", "pir_el1", 23),
        Insn("mrs_sys", 3, "pir_el1"),
        # ---- 只读 ID 寄存器（QEMU -cpu max 值）----
        Insn("mrs_sys", 4, "midr_el1"),
        Insn("mrs_sys", 10, "revidr_el1"),    # QEMU -cpu max = 0
        Insn("mrs_sys", 11, "id_aa64isar2_el1"),
        Insn("mrs_sys", 12, "id_aa64smfr0_el1"),
        Insn("mrs_sys", 13, "id_dfr0_el1"),
        Insn("mrs_sys", 14, "id_dfr1_el1"),
        Insn("mrs_sys", 5, "ctr_el0"),
        Insn("mrs_sys", 6, "cntfrq_el0"),     # 0x3b9aca00
        Insn("mrs_sys", 7, "currentel"),      # EL1 -> 4
        Insn("mrs_sys", 8, "id_aa64pfr0_el1"),
        Insn("mrs_sys", 9, "id_aa64mmfr0_el1"),
        Insn("mrs_sys", 0, "id_aa64mmfr3_el1"),
        # ---- DAIF/SPSel + SVC 往返（EL1t 与 EL1h 双向量）----
        Insn("movz", 10, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 10),      # VBAR = 0x44010000
        Insn("movz", 14, 0x4408, 1),
        Insn("movk", 14, 0x300),
        Insn("add", 31, 14, 0),               # sp_el1 = 0x44080300
        Insn("movz", 15, 0x4408, 1),
        Insn("movk", 15, 0x200),
        Insn("msr_sys", "sp_el0", 15),        # sp_el0 = 0x44080200
        Insn("daifclr", 8),                   # 清 D
        # MSR DAIF（寄存器形式）写后读回（Linux 退出 critical section）
        Insn("movz", 9, 0x3c0),
        Insn("msr_sys", "daif", 9),           # D=1 I=1 F=1
        Insn("mrs_sys", 10, "daif"),          # 0x3c0
        Insn("movz", 9, 0),
        Insn("msr_sys", "daif", 9),           # 全部清除
        Insn("mrs_sys", 10, "daif"),          # 0
        Insn("spsel", 0),                     # EL1t：可见 SP=sp_el0
        Insn("svc", 0),                       # EL1t -> VBAR+0x000
        # 返回 EL1t：用 sp_el0 访存
        Insn("movz", 8, 0x55),
        Insn("str", 8, 31, 0),                # mem[0x44080200] = 0x55
        Insn("ldr", 9, 31, 0),                # x9 = 0x55
        Insn("daifset", 8),                   # 置回 D
        Insn("spsel", 1),                     # EL1h：可见 SP=sp_el1
        Insn("svc", 1),                       # EL1h -> VBAR+0x200
        # 返回 EL1h：用 sp_el1 访存
        Insn("movz", 12, 0x66),
        Insn("str", 12, 31, 0),               # mem[0x44080300] = 0x66
        Insn("ldr", 13, 31, 0),               # x13 = 0x66
        # ---- EXTR（ror #imm 别名，Linux alternatives 实测）----
        Insn("movz", 0, 0x1234, 1),
        Insn("movk", 0, 0x89ab, 2),
        Insn("movk", 0, 0xcdef, 3),           # x0 = 0xcdef89ab00001234
        Insn("movz", 1, 0x1122, 1),
        Insn("movk", 1, 0x5566, 2),
        Insn("movk", 1, 0x99aa, 3),           # x1 = 0x99aa556600001122
        Insn("extr", 2, 0, 1, 8),             # X：{x0,x1}>>8
        Insn("extr", 8, 0, 1, 32),            # X：高半部/低半部方向边界
        Insn("extr", 3, 0, 1, 0),             # X：lsb=0 -> x0
        Insn("extr", 4, 0, 0, 31),            # X：ror x0,#31
        Insn("extr", 5, 0, 1, 16, 0),         # W：{w0,w1}>>16（32 位）
        Insn("extr", 6, 0, 0, 8, 0),          # W：ror w0,#8
        Insn("extr", 7, 0, 0, 7, 0),          # W：ror w0,#7（bit10=1）
        Insn("extr", 7, 0, 0, 31, 0),         # W：ror w0,#31（bit14=1）
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    # EL1t 同步向量（VBAR+0x000）：handler 运行在 EL1h（异常入口置 SP=1）
    handler_t = assemble([
        Insn("mrs_sys", 6, "spsr_el1"),       # SP bit=0、D=0
        Insn("mrs_sys", 7, "elr_el1"),
        Insn("eret"),
    ], 0x44010000)
    # EL1h 同步向量（VBAR+0x200）
    handler_h = assemble([
        Insn("mrs_sys", 10, "spsr_el1"),      # SP bit=1、D=1
        Insn("mrs_sys", 11, "elr_el1"),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10400)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler_t):
        off = 0x10000 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler_h):
        off = 0x10200 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_big_mem_program(path):
    """P6 内存模型冒烟：>1 MiB 镜像经加载口写入后锁步执行。

    代码在基址（movz x2,#0x4410,lsl16; ldr x3,[x2]; b .），标记数据放在
    base+1 MiB（旧 SRAM_TOP，现 128 MiB 窗口内）。若 RTL RAM 在 1 MiB
    回绕，x3 会读到 NOP 而 QEMU 读到标记 -> 锁步差分失败。
    """
    nops = 0xD503201F
    marker = 0x1122334455667788
    buf = bytearray(0x100000 + 0x1000)   # 1 MiB + 4 KiB
    for i in range(0, len(buf), 4):
        buf[i:i + 4] = struct.pack("<I", nops)
    code = assemble([
        Insn("movz", 2, 0x4410, 1),  # x2 = 0x44100000（base + 1 MiB）
        Insn("ldr", 3, 2, 0),        # x3 = marker（或回绕后的 NOP）
        Insn("b", "loop"),
        label("loop"),
        Insn("b", "loop"),
    ], BASE)
    for i, w in enumerate(code):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    buf[0x100000:0x100000 + 8] = struct.pack("<Q", marker)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_uart_program(path):
    """P6 PL011 UART 定向锁步：复位寄存器、TX/INT、LBE 回环、FEN FIFO、ID。

    期望值全部来自 QEMU 11.1.0 pl011.c + 探针实证（handoff 036）：
    FR=0x90/CR=0x300 复位；TX 后 RIS=0x20（INT_TX）；LBE 回环
    FR=0xC0（深度 1 满）且 DR 可读回、空读残留；FEN=1 深度 16；
    PeripheralID0=0x11、PrimeCellID0=0x0D；8B 读 FR 高字为下一字。
    """
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 20, 0x0900, 1),      # x20 = 0x09000000（UART 基址）
        # ---- 复位值 ----
        Insn("ldrw", 0, 20, 6),           # FR = 0x90
        Insn("ldrw", 1, 20, 12),          # CR = 0x300
        Insn("ldrw", 2, 20, 15),          # RIS = 0
        Insn("ldrw", 3, 20, 16),          # MIS = 0
        Insn("ldrw", 4, 20, 11),          # LCR_H = 0
        Insn("ldrw", 5, 20, 18),          # DMACR = 0
        # ---- 配置并读回 ----
        Insn("movz", 1, 0x301),
        Insn("strw", 1, 20, 12),          # CR = UARTEN|TXE|RXE
        Insn("movz", 1, 0x30),
        Insn("strw", 1, 20, 11),          # LCR_H = 8N1
        Insn("movz", 1, 0x27),
        Insn("strw", 1, 20, 9),           # IBRD
        Insn("movz", 1, 0x04),
        Insn("strw", 1, 20, 10),          # FBRD
        Insn("ldrw", 6, 20, 9),           # IBRD 读回 0x27
        Insn("ldrw", 7, 20, 10),          # FBRD 读回 0x4
        # ---- TX：INT_TX / MIS ----
        Insn("movz", 1, 0x20),
        Insn("strw", 1, 20, 14),          # IMSC = INT_TX
        Insn("movz", 1, 0x41),
        Insn("strw", 1, 20, 0),           # UARTDR = 'A'
        Insn("ldrw", 8, 20, 15),          # RIS = 0x20
        Insn("ldrw", 9, 20, 16),          # MIS = 0x20
        Insn("movz", 1, 0x42),
        Insn("strw", 1, 20, 0),           # UARTDR = 'B'
        Insn("movz", 1, 0x43),
        Insn("strw", 1, 20, 0),           # UARTDR = 'C'
        Insn("ldrw", 10, 20, 6),          # FR 仍 0x90
        Insn("movz", 1, 0x20),
        Insn("strw", 1, 20, 17),          # ICR = INT_TX
        Insn("ldrw", 11, 20, 15),         # RIS = 0
        # ---- LBE 回环（FEN 关，深度 1）----
        Insn("movz", 1, 0x00),
        Insn("strw", 1, 20, 11),          # LCR_H = 0
        Insn("movz", 1, 0x381),
        Insn("strw", 1, 20, 12),          # CR |= LBE
        Insn("movz", 1, 0x44),
        Insn("strw", 1, 20, 0),           # UARTDR = 'D'（回环入 RX）
        Insn("ldrw", 12, 20, 6),          # FR = 0xC0（RXFF，深度 1 满）
        Insn("ldrw", 13, 20, 0),          # DR = 0x44
        Insn("ldrw", 14, 20, 6),          # FR = 0x90
        Insn("ldrw", 15, 20, 0),          # 空读残留 = 0x44
        Insn("ldrw", 16, 20, 1),          # RSR = 0
        # ---- FEN=1 FIFO（深度 16）----
        Insn("movz", 1, 0x70),
        Insn("strw", 1, 20, 11),          # LCR_H = FEN|8N1
        Insn("movz", 1, 0x45),
        Insn("strw", 1, 20, 0),           # 'E'
        Insn("movz", 1, 0x46),
        Insn("strw", 1, 20, 0),           # 'F'
        Insn("ldrw", 17, 20, 6),          # FR = 0x80（非满）
        Insn("ldrw", 18, 20, 0),          # DR = 0x45
        Insn("ldrw", 19, 20, 0),          # DR = 0x46
        # ---- ID 寄存器与 8B 读 ----
        Insn("ldrw", 21, 20, 0x3F8),      # PeripheralID0 = 0x11
        Insn("ldrw", 22, 20, 0x3FC),      # PrimeCellID0 = 0x0D
        Insn("ldr", 23, 20, 3),           # 8B 读 FR -> x23 = 0x90
        Insn("b", "loop"),
        label("loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_pl061_program(path):
    """P6 QEMU virt PL061 GPIO 定向锁步：数据/方向与 PrimeCell ID。"""
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 20, 0x0903, 1),       # x20 = 0x09030000
        # QEMU pl061_id[]：PID0/1/2 与 CID0/3。
        Insn("ldrw", 0, 20, 0x3f8),        # PID0 @0xfe0 = 0x61
        Insn("ldrw", 1, 20, 0x3f9),        # PID1 = 0x10
        Insn("ldrw", 2, 20, 0x3fa),        # PID2 = 0x04
        Insn("ldrw", 3, 20, 0x3fc),        # CID0 @0xff0 = 0x0d
        Insn("ldrw", 4, 20, 0x3ff),        # CID3 = 0xb1
        # 复位 DIR/DATA=0；设置低四位输出，data aperture 用地址 mask 读回。
        Insn("movz", 5, 0x0f),
        Insn("strw", 5, 20, 0x100),        # GPIODIR @0x400
        Insn("movz", 5, 0x03),
        Insn("strw", 5, 20, 0x0ff),        # GPIODATA mask=0xff @0x3fc
        Insn("ldrw", 6, 20, 0x0ff),        # -> 3
        Insn("ldrw", 7, 20, 3),            # data mask=3 @0x00c -> 3
        Insn("ldrw", 8, 20, 0x106),        # GPIO_MIS @0x418 = 0
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_pl031_program(path):
    """P6 PL031 RTC C++ fabric：ID、固定 vm RTC、LR/MR/中断状态。"""
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 20, 0x0901, 1),       # x20 = 0x09010000
        # QEMU 固定 -rtc base=2000-01-01T00:00:00,clock=vm。
        Insn("ldrw", 0, 20, 0),            # DR = 946684800（该秒内稳定）
        Insn("ldrw", 1, 20, 0x3f8),        # PID0 @ 0xfe0 = 0x31
        Insn("ldrw", 2, 20, 0x3f9),        # PID1 = 0x10
        Insn("ldrw", 3, 20, 0x3fa),        # PID2 = 0x14
        Insn("ldrw", 4, 20, 0x3fc),        # CID0 @ 0xff0 = 0x0d
        Insn("ldrw", 5, 20, 3),            # CR @ 0x0c = 1
        Insn("movz", 6, 0x5678),
        Insn("movk", 6, 0x1234, 1),
        Insn("strw", 6, 20, 2),            # LR @ 0x08
        Insn("ldrw", 7, 20, 0),            # DR = 0x12345678
        Insn("movz", 8, 1),
        Insn("strw", 8, 20, 4),            # IMSC @ 0x10
        Insn("strw", 6, 20, 1),            # MR @ 0x04，当前秒立即 match
        Insn("ldrw", 9, 20, 5),            # RIS @ 0x14 = 1
        Insn("strw", 8, 20, 7),            # ICR @ 0x1c
        Insn("ldrw", 10, 20, 6),           # MIS @ 0x18 = 0
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_crc32_program(path):
    """ARMv8 CRC32/CRC32C B/H/W/X 定向锁步（结果均为 W 零扩展）。"""
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 1, 0xffff),
        Insn("movk", 1, 0xffff, 1),       # w1 = CRC seed 0xffffffff
        Insn("movz", 2, 0xcdef),
        Insn("movk", 2, 0x89ab, 1),
        Insn("movk", 2, 0x4567, 2),
        Insn("movk", 2, 0x0123, 3),       # x2 = 0x0123456789abcdef
        # IEEE CRC32（B/H/W/X）
        Insn("crc32b", 3, 1, 2),
        Insn("crc32h", 4, 1, 2),
        Insn("crc32w", 5, 1, 2),
        Insn("crc32x", 6, 1, 2),
        # Castagnoli CRC32C（B/H/W/X）
        Insn("crc32cb", 7, 1, 2),
        Insn("crc32ch", 8, 1, 2),
        Insn("crc32cw", 9, 1, 2),
        Insn("crc32cx", 10, 1, 2),
        # 结果继续作为 seed，覆盖寄存器相关与 W 写回零扩展。
        Insn("crc32x", 11, 3, 2),
        Insn("crc32cx", 12, 7, 2),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_checkpoint_sys_v3_program(path):
    """LCVXSYS3 恢复：PMUSERENR/TCR2 与 exclusive monitor。"""
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 0, 0xf),
        Insn("msr_sys", "pmuserenr_el0", 0),
        Insn("movz", 1, 0x12),
        Insn("movk", 1, 0x7, 1),             # x1 = 0x0007_0012
        Insn("msr_sys", "tcr2_el1", 1),
        Insn("movz", 2, 0x5aa),
        Insn("msr_sys", "pire0_el1", 2),
        Insn("movz", 20, 0x1000),
        Insn("movk", 20, 0x4400, 1),         # x20 = 0x44001000
        Insn("movz", 21, 0x55),
        Insn("str", 21, 20, 0),
        Insn("ldxr", 22, 20),                # seq=11：保存有效 monitor
        # 从 checkpoint 恢复后，必须同时保留两个 sysreg 和 monitor。
        Insn("mrs_sys", 23, "pmuserenr_el0"),
        Insn("mrs_sys", 24, "tcr2_el1"),
        Insn("movz", 25, 0x66),
        Insn("stxr", 26, 25, 20),            # 恢复的 monitor 应使 w26=0
        Insn("ldr", 27, 20, 0),              # x27 = 0x66
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_checkpoint_sys_v4_program(path):
    """LCVXSYS4 恢复：写 CONTEXTIDR_EL1 -> checkpoint -> MRS 读回。"""
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 0, 0x1234),
        Insn("movk", 0, 0x5678, 1),          # x0 = 0x56781234
        Insn("msr_sys", "contextidr_el1", 0),
        # 保存点通常落在 MSR 之后；恢复后下面这条 MRS 必须读回原值。
        Insn("mrs_sys", 1, "contextidr_el1"),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_timer_program(path):
    """P6 Generic Timer 定向锁步（QEMU 需 -icount shift=0）。

    CNTPCT/CNTVCT 读、CNTP_TVAL/CVAL/CTL 读写、istatus 0->1 翻转、
    TVAL 写（cval = count + sext32）、禁用清 istatus、CNTV 族、imask。
    期望值不硬编码：锁步直接比较 RTL 与 QEMU 提交流（icount 下计数器
    确定性 = 已执行指令数）。
    """
    main = assemble([
        Insn("label", "main"),
        # ---- 计数器与频率 ----
        Insn("mrs_sys", 0, "cntpct_el0"),    # x0 = 当前指令计数
        Insn("mrs_sys", 1, "cntvct_el0"),    # x1 = cntpct（无 CNTVOFF）
        Insn("mrs_sys", 2, "cntfrq_el0"),    # x2 = 0x3b9aca00
        # ---- 物理定时器：enable + cval = count+12，istatus 0 -> 1 ----
        Insn("mrs_sys", 3, "cntpct_el0"),
        Insn("add", 4, 3, 12),
        Insn("msr_sys", "cntp_cval_el0", 4),
        Insn("movz", 5, 1),
        Insn("msr_sys", "cntp_ctl_el0", 5),  # enable
        Insn("mrs_sys", 6, "cntp_ctl_el0"),  # istatus=0（count < cval）
        Insn("mrs_sys", 7, "cntp_cval_el0"), # cval 原样读回
        Insn("nop"), Insn("nop"), Insn("nop"), Insn("nop"),
        Insn("nop"), Insn("nop"), Insn("nop"), Insn("nop"),
        Insn("mrs_sys", 8, "cntp_ctl_el0"),  # istatus=1（已越过）
        Insn("mrs_sys", 9, "cntp_tval_el0"), # (u32)(cval - count)
        # ---- TVAL 写：cval = count + sext32(value) ----
        Insn("movz", 10, 5),
        Insn("msr_sys", "cntp_tval_el0", 10),
        Insn("mrs_sys", 11, "cntp_tval_el0"),
        Insn("mrs_sys", 12, "cntp_cval_el0"),
        # ---- 禁用：istatus 清 ----
        Insn("msr_sys", "cntp_ctl_el0", 31), # xzr
        Insn("mrs_sys", 13, "cntp_ctl_el0"), # 0
        # ---- 虚拟定时器族 + imask ----
        Insn("movz", 14, 2),
        Insn("msr_sys", "cntv_ctl_el0", 14), # imask only
        Insn("mrs_sys", 15, "cntv_ctl_el0"),
        Insn("mrs_sys", 16, "cntv_tval_el0"),
        # ---- 重新 enable：istatus 立即为 1 ----
        Insn("movz", 17, 1),
        Insn("msr_sys", "cntp_ctl_el0", 17),
        Insn("mrs_sys", 18, "cntp_ctl_el0"),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_timer_el0_program(path):
    """EL0 Generic Timer CNTKCTL gate matrix（QEMU EC=0x18）。

    第一阶段在 CNTKCTL=0 下逐一触发 CNTFRQ、CNTP/CNTVCT（含 ECV 视图）
    和 CNTP/CNTV TVAL/CTL/CVAL 的同步 System Register Trap。随后只开放
    bit0、再开放 bit9、最后开放 bit8，验证每一组寄存器从 trap 到正常
    MRS/MSR 的边界。异常 handler 读取 ESR/ELR 并跳过 faulting 指令，故
    `exc_code=0x18`、完整 SYSREG_ISS 和异常返回状态都会进入锁步比较。
    """
    def set_addr(reg, address):
        return [Insn("movz", reg, (address >> 16) & 0xffff, 1),
                Insn("movk", reg, address & 0xffff)]

    phase0 = assemble([
        Insn("mrs_sys", 0, "cntfrq_el0"),
        Insn("mrs_sys", 0, "cntpct_el0"),
        Insn("mrs_sys", 0, "cntvct_el0"),
        Insn("mrs_sys", 0, "cntpctss_el0"),
        Insn("mrs_sys", 0, "cntvctss_el0"),
        Insn("mrs_sys", 0, "cntp_tval_el0"),
        Insn("mrs_sys", 0, "cntp_ctl_el0"),
        Insn("mrs_sys", 0, "cntp_cval_el0"),
        Insn("mrs_sys", 0, "cntv_tval_el0"),
        Insn("mrs_sys", 0, "cntv_ctl_el0"),
        Insn("mrs_sys", 0, "cntv_cval_el0"),
        Insn("b", "phase0_loop"),
        Insn("label", "phase0_loop"), Insn("b", "phase0_loop"),
    ], 0x44000080)

    phase1 = assemble([
        Insn("mrs_sys", 0, "cntfrq_el0"),
        Insn("mrs_sys", 1, "cntpct_el0"),
        Insn("mrs_sys", 2, "cntpctss_el0"),
        Insn("mrs_sys", 3, "cntvct_el0"),  # bit1=0 -> trap
        Insn("b", "phase1_loop"),
        Insn("label", "phase1_loop"), Insn("b", "phase1_loop"),
    ], 0x440000c0)

    phase2 = assemble([
        Insn("mrs_sys", 0, "cntp_tval_el0"),
        Insn("mrs_sys", 1, "cntp_ctl_el0"),
        Insn("mrs_sys", 2, "cntp_cval_el0"),
        Insn("movz", 3, 1),
        Insn("msr_sys", "cntp_ctl_el0", 3),
        Insn("mrs_sys", 4, "cntp_ctl_el0"),
        Insn("movz", 5, 0x40),
        Insn("msr_sys", "cntp_cval_el0", 5),
        Insn("mrs_sys", 6, "cntp_cval_el0"),
        Insn("movz", 7, 5),
        Insn("msr_sys", "cntp_tval_el0", 7),
        Insn("mrs_sys", 8, "cntp_tval_el0"),
        Insn("mrs_sys", 9, "cntv_tval_el0"),  # bit8=0 -> trap
        Insn("b", "phase2_loop"),
        Insn("label", "phase2_loop"), Insn("b", "phase2_loop"),
    ], 0x44000100)

    phase3 = assemble([
        Insn("mrs_sys", 0, "cntv_tval_el0"),
        Insn("mrs_sys", 1, "cntv_ctl_el0"),
        Insn("mrs_sys", 2, "cntv_cval_el0"),
        Insn("movz", 3, 1),
        Insn("msr_sys", "cntv_ctl_el0", 3),
        Insn("mrs_sys", 4, "cntv_ctl_el0"),
        Insn("movz", 5, 0x40),
        Insn("msr_sys", "cntv_cval_el0", 5),
        Insn("mrs_sys", 6, "cntv_cval_el0"),
        Insn("movz", 7, 5),
        Insn("msr_sys", "cntv_tval_el0", 7),
        Insn("mrs_sys", 8, "cntv_tval_el0"),
        Insn("b", "phase3_loop"),
        Insn("label", "phase3_loop"), Insn("b", "phase3_loop"),
    ], 0x44000140)

    pre = []
    pre += set_addr(5, 0x44010000)
    pre += [Insn("msr_sys", "vbar_el1", 5),
            Insn("movz", 20, 0),
            Insn("movz", 11, 0x3c0),
            Insn("msr_sys", "spsr_el1", 11)]
    pre += set_addr(12, 0x44000080)
    pre += [Insn("msr_sys", "elr_el1", 12), Insn("eret")]
    pre = assemble(pre, BASE)

    # Each denied access returns to EL0 after ELR += 4. At the phase boundary
    # switch SPSR to EL1h and jump to a setup block that changes CNTKCTL.
    handler = [
        Insn("mrs_sys", 21, "esr_el1"),
        Insn("mrs_sys", 22, "far_el1"),
        Insn("add", 20, 20, 1),
        Insn("cmp", 20, 11), Insn("b_cond", "eq", "to_setup1"),
        Insn("cmp", 20, 12), Insn("b_cond", "eq", "to_setup2"),
        Insn("cmp", 20, 13), Insn("b_cond", "eq", "to_setup3"),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("add", 10, 10, 4),
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
        Insn("label", "to_setup1"),
        Insn("movz", 11, 0x3c5),
        Insn("msr_sys", "spsr_el1", 11),
    ]
    handler += set_addr(12, 0x44000200)
    handler += [Insn("msr_sys", "elr_el1", 12), Insn("eret"),
                Insn("label", "to_setup2"),
                Insn("movz", 11, 0x3c5),
                Insn("msr_sys", "spsr_el1", 11)]
    handler += set_addr(12, 0x44000240)
    handler += [Insn("msr_sys", "elr_el1", 12), Insn("eret"),
                Insn("label", "to_setup3"),
                Insn("movz", 11, 0x3c5),
                Insn("msr_sys", "spsr_el1", 11)]
    handler += set_addr(12, 0x44000280)
    handler += [Insn("msr_sys", "elr_el1", 12), Insn("eret")]
    handler = assemble(handler, 0x44010400)

    setup1 = assemble([
        Insn("movz", 13, 1), Insn("msr_sys", "cntkctl_el1", 13),
        Insn("movz", 11, 0x3c0), Insn("msr_sys", "spsr_el1", 11),
        *set_addr(12, 0x440000c0), Insn("msr_sys", "elr_el1", 12), Insn("eret")
    ], 0x44000200)
    setup2 = assemble([
        Insn("movz", 13, 0x201), Insn("msr_sys", "cntkctl_el1", 13),
        Insn("movz", 11, 0x3c0), Insn("msr_sys", "spsr_el1", 11),
        *set_addr(12, 0x44000100), Insn("msr_sys", "elr_el1", 12), Insn("eret")
    ], 0x44000240)
    setup3 = assemble([
        Insn("movz", 13, 0x303), Insn("msr_sys", "cntkctl_el1", 13),
        Insn("movz", 11, 0x3c0), Insn("msr_sys", "spsr_el1", 11),
        *set_addr(12, 0x44000140), Insn("msr_sys", "elr_el1", 12), Insn("eret")
    ], 0x44000280)

    buf = bytearray(0x10000 + 0x600)
    for offset, words in ((0, pre), (0x80, phase0), (0xc0, phase1),
                          (0x100, phase2), (0x140, phase3),
                          (0x200, setup1), (0x240, setup2), (0x280, setup3),
                          (0x400, handler)):
        for index, word in enumerate(words):
            absolute = (0x10000 + offset + index * 4
                        if offset >= 0x400 else offset + index * 4)
            buf[absolute:absolute + 4] = struct.pack("<I", word)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_gic_program(path):
    """P6 GICv2 定向锁步（DAIF.I=1 屏蔽 IRQ 入口，只测 GIC 寄存器语义）。

    复位值/读写/SGIR/IAR/HPPIR/EOIR/优先级/组/使能等全部与 QEMU 逐条
    比较（期望值不硬编码，锁步差分）。GICD=0x08000000、GICC=0x08010000。
    """
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 20, 0x0800, 1),       # GICD
        Insn("ldrw", 0, 20, 0),            # GICD_CTLR=0
        Insn("ldrw", 1, 20, 1),            # GICD_TYPER=0x8
        Insn("ldrw", 2, 20, 2),            # GICD_IIDR=0x43b
        Insn("ldrw", 3, 20, 0x40),         # GICD_ISENABLER0=0xffff
        Insn("ldrw", 4, 20, 0x60),         # GICD_ICENABLER0 读=0xffff
        Insn("ldrw", 5, 20, 0x200),        # GICD_ITARGETSR0=0（单核 RAZ）
        Insn("ldrw", 6, 20, 0x300),        # GICD_ICFGR0=0xaaaaaaaa
        Insn("ldrw", 7, 20, 0x301),        # GICD_ICFGR1=0
        Insn("ldrw", 8, 20, 0x100),        # GICD_IPRIORITYR0=0
        Insn("ldrw", 9, 20, 0x20),         # GICD_IGROUPR0=0
        Insn("movz", 21, 0x0801, 1),       # GICC
        Insn("ldrw", 10, 21, 0),           # GICC_CTLR=0
        Insn("ldrw", 11, 21, 1),           # GICC_PMR=0
        Insn("ldrw", 12, 21, 2),           # GICC_BPR=0
        Insn("ldrw", 13, 21, 3),           # GICC_IAR=0x3ff
        Insn("ldrw", 14, 21, 6),           # GICC_HPPIR=0x3ff
        Insn("ldrw", 15, 21, 5),           # GICC_RPR=0xff
        Insn("ldrw", 16, 21, 7),           # GICC_ABPR=1
        Insn("ldrw", 17, 21, 0x3F),        # GICC_IIDR=0x2043b
        # ---- 使能 + 软中断 ----
        Insn("movz", 1, 1),
        Insn("strw", 1, 20, 0),            # GICD_CTLR=1（EN_GRP0）
        Insn("strw", 1, 21, 0),            # GICC_CTLR=1
        Insn("movz", 1, 0xff),
        Insn("strw", 1, 21, 1),            # GICC_PMR=0xff
        Insn("movz", 1, 0),
        Insn("strw", 1, 21, 2),            # GICC_BPR=0
        Insn("movz", 1, 1),
        Insn("strw", 1, 20, 0x3C0),        # GICD_SGIR：SGI#1 -> CPU0
        Insn("ldrw", 18, 21, 3),           # GICC_IAR=1
        Insn("ldrw", 19, 21, 6),           # GICC_HPPIR=1
        Insn("ldrw", 22, 21, 5),           # GICC_RPR=0（运行优先级）
        Insn("movz", 1, 1),
        Insn("strw", 1, 21, 4),            # GICC_EOIR=1
        Insn("ldrw", 23, 21, 3),           # GICC_IAR=0x3ff（已清）
        Insn("ldrw", 24, 21, 6),           # GICC_HPPIR=0x3ff
        # ---- ISENABLER/优先级写读回 ----
        Insn("movz", 1, 0x100000),         # 使能 PPI 20（bit20）
        Insn("strw", 1, 20, 0x40),         # GICD_ISENABLER0
        Insn("ldrw", 25, 20, 0x40),        # 读回 0x0010ffff
        Insn("movz", 1, 0x10),
        Insn("strw", 1, 20, 0x60),         # GICD_ICENABLER0：清 SGI4
        Insn("ldrw", 26, 20, 0x40),        # 读回 0x0010ffef
        # 优先级：IRQ3 优先级 0x40
        Insn("movz", 1, 0x40),
        Insn("strw", 1, 20, 0x103),        # GICD_IPRIORITYR3 字节
        Insn("ldrw", 26, 20, 0x100),       # IPRIORITYR0 读回 0x00400000
        # ---- 组写读回（IGROUPR）----
        Insn("movz", 1, 0x4),              # SGI#2 置组1
        Insn("strw", 1, 20, 0x20),         # GICD_IGROUPR0
        Insn("ldrw", 27, 20, 0x20),        # 读回 0x4
        # ---- GICv2m MSI frame（QEMU virt: 0x08020000）----
        Insn("movz", 21, 0x0802, 1),       # GICv2m frame
        Insn("ldrw", 28, 21, 2),            # MSI_TYPER=0x00500040
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_irq_program(path):
    """P6 异步 IRQ 入口定向锁步（QEMU fork step 模式 async 提交 + RTL）。

    GIC 使能 + SGIR 软中断 + DAIF.I 清 -> 下一条指令边界进入 VBAR+0x280
    （EL1h IRQ）：handler 读 GICC_IAR/EOI 后 ERET；SPSR 保存的 I 位=0、
    ELR=被中断指令的下一条。QEMU 侧由 fork 插件把异步异常转为
    exc_code=0x40 的 COMMIT，与 RTL EXC_IRQ 一致。
    """
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 20, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 20),   # VBAR = 0x44010000
        Insn("movz", 20, 0x0800, 1),       # GICD
        Insn("movz", 21, 0x0801, 1),       # GICC
        Insn("movz", 1, 1),
        Insn("strw", 1, 20, 0),            # GICD_CTLR = 1
        Insn("strw", 1, 21, 0),            # GICC_CTLR = 1
        Insn("movz", 1, 0xff),
        Insn("strw", 1, 21, 1),            # GICC_PMR = 0xff
        Insn("movz", 1, 0),
        Insn("strw", 1, 21, 2),            # GICC_BPR = 0
        Insn("movz", 0, 0x77),
        Insn("daifclr", 2),                # 清 I（IRQ 使能）
        Insn("movz", 1, 1),
        Insn("strw", 1, 20, 0x3C0),        # SGIR：SGI#1 -> CPU0
        # IRQ 在下一指令边界取走（进入 VBAR+0x280），此处不继续
        Insn("movz", 5, 0x55),             # 不应执行（被中断前）
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
        # EL1h IRQ 向量（VBAR+0x280）
        Insn("label", "irq_handler"),
        Insn("mrs_sys", 2, "elr_el1"),     # 被中断指令的下一条
        Insn("mrs_sys", 3, "spsr_el1"),    # PSTATE（I 位=0）
        Insn("ldrw", 4, 21, 3),            # GICC_IAR = 1
        Insn("strw", 4, 21, 4),            # GICC_EOIR = 1
        Insn("eret"),                      # 返回
    ], BASE)
    # 把 handler 放到 VBAR+0x280 = 0x44010280
    words = main
    handler = assemble([
        Insn("label", "h"),
        Insn("mrs_sys", 2, "elr_el1"),
        Insn("mrs_sys", 3, "spsr_el1"),
        Insn("ldrw", 4, 21, 3),
        Insn("strw", 4, 21, 4),
        Insn("eret"),
    ], 0x44010280)
    buf = bytearray(0x10400)
    for i, w in enumerate(words):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x10280 + i * 4
        buf[off:off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_irq_daif_program(path):
    """P6：MSR DAIF 解屏蔽后同一提交边界接收 pending IRQ。

    先在复位 I=1 时通过 SGIR 挂起 SGI#1，再执行 ``msr daif, x1``（x1=0）。
    QEMU 在该 MSR 退休后、顺序下一条之前进入 EL1h IRQ 向量；这专门覆盖
    ID 级系统提交，不依赖普通 WB commit_fire 的 IRQ 路径。
    """
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 20, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 20),
        Insn("movz", 20, 0x0800, 1),       # GICD
        Insn("movz", 21, 0x0801, 1),       # GICC
        Insn("movz", 1, 1),
        Insn("strw", 1, 20, 0),            # GICD_CTLR
        Insn("strw", 1, 21, 0),            # GICC_CTLR
        Insn("movz", 1, 0xff),
        Insn("strw", 1, 21, 1),            # GICC_PMR
        Insn("movz", 1, 0),
        Insn("strw", 1, 21, 2),            # GICC_BPR
        Insn("movz", 1, 1),
        Insn("strw", 1, 20, 0x3c0),        # SGI#1 pending，但复位 I=1
        Insn("movz", 1, 0),
        Insn("msr_sys", "daif", 1),       # 写后 I=0，必须同条提交取 IRQ
        Insn("movz", 5, 0x55),             # 从 handler ERET 后才执行
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    handler = assemble([
        Insn("mrs_sys", 2, "elr_el1"),
        Insn("mrs_sys", 3, "spsr_el1"),
        Insn("ldrw", 4, 21, 3),            # GICC_IAR = 1
        Insn("strw", 4, 21, 4),            # GICC_EOIR
        Insn("eret"),
    ], 0x44010280)
    buf = bytearray(0x10400)
    for i, word in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", word)
    for i, word in enumerate(handler):
        off = 0x10280 + i * 4
        buf[off:off + 4] = struct.pack("<I", word)
    Path(path).write_bytes(buf)
    return BASE


# ---- T-054：原子/维护操作与 Generic Timer IRQ 的架构边界回归 ----
#
# QEMU step hook 只在完整 A64 指令边界采样，不能把它当作 CASP/STXR/DC ZVA
# 内部微相位注入器。这里仍用真实 Generic Timer PPI 产生 IRQ，令目标指令
# 在其自然 COMMIT 边界携带 exc_code=0x40；SV 入口另在 EX/MEM/FSM 中间相位
# 直接驱动 GIC 线。每个场景单独生成，便于 runner 检查 CASP 两段写、STXR
# success/fail 和 DC ZVA 后续 64B 读回。
def _build_hard_irq_atomic_overlap_program(path, scenario, timer_delay=12):
    if scenario not in {"casp_match", "casp_mismatch", "stxr_success",
                        "stxr_fail", "dc_zva"}:
        raise ValueError(f"unknown T-054 scenario: {scenario}")

    # QEMU virt GICv2 的 PPI30 接受 Generic Timer physical IRQ；把 GICD
    # bit30 显式打开，避免把 bit14 的旧 fixture 常量误当成 PPI30。
    prefix = [
        Insn("label", "main"),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 20, 0x0800, 1),       # GICD
        Insn("movz", 21, 0x0801, 1),       # GICC
        Insn("movz_w", 1, 1),
        Insn("strw", 1, 20, 0),            # GICD_CTLR
        Insn("strw", 1, 21, 0),            # GICC_CTLR
        Insn("movz_w", 1, 0xff),
        Insn("strw", 1, 21, 1),            # GICC_PMR
        Insn("movz_w", 1, 0),
        Insn("strw", 1, 21, 2),            # GICC_BPR
        Insn("movz", 1, 0x4000, 1),        # 1 << 30
        Insn("strw", 1, 20, 0x40),         # GICD_ISENABLER0 bit30
        # Read back the live GIC programming in the strict trace.  These
        # probes make a bad PPI mask/CPU-interface setup diagnosable without
        # relying on a plugin-side interrupt injection.
        Insn("ldrw", 4, 20, 0x40),
        Insn("ldrw", 5, 21, 0),
        Insn("ldrw", 6, 21, 1),
        Insn("mrs_sys", 0, "cntpct_el0"),
        Insn("add", 0, 0, timer_delay),
        Insn("msr_sys", "cntp_cval_el0", 0),
        Insn("movz", 1, 1),
        Insn("msr_sys", "cntp_ctl_el0", 1),
        Insn("daifclr", 2),
    ]

    if scenario == "casp_match":
        body = [
            Insn("movz", 20, 0x4408, 1),
            Insn("movk", 20, 0x2000),
            Insn("movz", 0, 0x11),
            Insn("movz", 1, 0x22),
            Insn("str", 0, 20, 0),
            Insn("str", 1, 20, 1),
            Insn("movz", 2, 0x33),
            Insn("movz", 3, 0x44),
            Insn("casp", 0, 2, 20, 1, 1),
        ]
    elif scenario == "casp_mismatch":
        body = [
            Insn("movz", 20, 0x4408, 1),
            Insn("movk", 20, 0x2000),
            Insn("movz", 0, 0x11),
            Insn("movz", 1, 0x22),
            Insn("str", 0, 20, 0),
            Insn("str", 1, 20, 1),
            Insn("movz", 0, 0x55),
            Insn("movz", 1, 0x66),
            Insn("movz", 2, 0x77),
            Insn("movz", 3, 0x88),
            Insn("casp", 0, 2, 20),
        ]
    elif scenario == "stxr_success":
        body = [
            Insn("movz", 20, 0x4408, 1),
            Insn("movk", 20, 0x3000),
            Insn("movz", 0, 0x11),
            Insn("str", 0, 20, 0),
            Insn("ldxr", 5, 20),
            Insn("movz", 6, 0xaa),
            Insn("stxr_w", 7, 6, 20),
        ]
    elif scenario == "stxr_fail":
        body = [
            Insn("movz", 20, 0x4408, 1),
            Insn("movk", 20, 0x3000),
            Insn("movz", 6, 0xbb),
            Insn("stxr_w", 7, 6, 20),
        ]
    else:  # dc_zva
        body = [
            Insn("movz", 9, 0x4409, 1),
            Insn("movk", 9, 0x0010),
            Insn("dc_zva", 9),
            # Read all eight 8-byte beats after the IRQ/ERET return.  The
            # strict lockstep packet stream checks each load against QEMU.
            Insn("ldr", 10, 9, 0),
            Insn("ldr", 11, 9, 1),
            Insn("ldr", 12, 9, 2),
            Insn("ldr", 13, 9, 3),
            Insn("ldr", 14, 9, 4),
            Insn("ldr", 15, 9, 5),
            Insn("ldr", 16, 9, 6),
            Insn("ldr", 17, 9, 7),
        ]

    main = prefix + body + [Insn("b", "loop"),
                            Insn("label", "loop"), Insn("b", "loop")]
    handler = assemble([
        # Disable the level PPI before returning.  The timer PPI is a level
        # source; no synthetic SGI/IAR action is used by this live boundary
        # test.  The handler itself is ordinary code, so all state remains in
        # the strict trace.
        Insn("movz", 2, 0),
        Insn("msr_sys", "cntp_ctl_el0", 2),
        Insn("eret"),
    ], 0x44010280)

    # Keep enough space for code, vector handler and (for DC ZVA) a non-zero
    # 64B block.  The byte image uses the same BASE-relative indexing as the
    # existing hard_* builders.
    data_end = 0x90000 + 64 if scenario == "dc_zva" else 0
    vector_end = 0x10000 + 0x280 + len(handler) * 4
    buf = bytearray(max(0x10400, data_end, vector_end))
    words = assemble(main, BASE)
    for i, word in enumerate(words):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", word)
    for i, word in enumerate(handler):
        off = 0x10000 + 0x280 + i * 4
        buf[off:off + 4] = struct.pack("<I", word)
    if scenario == "dc_zva":
        # Preload every beat with a distinct non-zero pattern; eight post-ZVA
        # loads must all observe zero, proving the full multi-beat clear.
        for i in range(8):
            value = (0x1122334455667788 + i) & ((1 << 64) - 1)
            off = 0x90000 + i * 8
            buf[off:off + 8] = struct.pack("<Q", value)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_irq_atomic_overlap_program(path, scenario="casp_match",
                                           timer_delay=12):
    return _build_hard_irq_atomic_overlap_program(path, scenario, timer_delay)


def build_hard_irq_atomic_casp_match_program(path):
    # The CASP is at 0x44000078 after the explicit GIC readback probes.
    # CVAL=current+14 places the IRQ on the CASP COMMIT boundary.
    return _build_hard_irq_atomic_overlap_program(path, "casp_match", 14)


def build_hard_irq_atomic_casp_mismatch_program(path):
    # The mismatch CASP is at 0x44000080 (four body instructions later).
    return _build_hard_irq_atomic_overlap_program(path, "casp_mismatch", 16)


def build_hard_irq_atomic_stxr_success_program(path):
    # Let the STXR retire normally (and publish mon_we=1), then take the
    # level-timer IRQ at the following architectural boundary.  A timer IRQ
    # on the same STXR packet would expose the pre-existing QEMU plugin gap:
    # its monitor sidecar suppresses mon_we for exc_code=0x40.
    return _build_hard_irq_atomic_overlap_program(path, "stxr_success", 13)


def build_hard_irq_atomic_stxr_fail_program(path):
    return _build_hard_irq_atomic_overlap_program(path, "stxr_fail", 13)


def build_hard_irq_atomic_dc_zva_program(path):
    # CVAL=current+8 places the live QEMU IRQ on the DC ZVA instruction
    # boundary; the subsequent eight loads prove the completed 64B clear.
    return _build_hard_irq_atomic_overlap_program(path, "dc_zva", 8)


def build_hard_ldur_program(path):
    """P6 Linux 启动缺口：LDUR/STUR（非缩放 9 位有符号偏移）+ cset 别名。

    覆盖 X/W/H/B 读写、负偏移、LDURSW/LDURSB/LDURSH 符号扩展、
    PRFUM（NOP）、cset/csetm/cinc/cinv/cneg（csinc 族 XZR 别名）。
    期望值不硬编码，锁步差分与 QEMU 逐条比较。
    """
    main = assemble([
        Insn("label", "main"),
        # 数据区基址 x20 = 0x44008000
        Insn("movz", 20, 0x4408, 1),
        Insn("movk", 20, 0x10),            # x20 = 0x44080010
        # 负偏移 STUR/LDUR（imm9 = -8）
        Insn("movz", 0, 0x1234),
        Insn("stur", 0, 20, -8),           # mem[0x44080008] = 0x1234
        Insn("ldur", 1, 20, -8),           # x1 = 0x1234
        Insn("ldurw", 2, 20, -8),          # w2 = 0x1234（零扩展）
        # 正偏移各宽度
        Insn("movz", 3, 0xaa),
        Insn("sturb", 3, 20, 4),           # mem[0x44080014] = 0xaa
        Insn("ldurb", 4, 20, 4),           # x4 = 0xaa
        Insn("movz", 5, 0xbb),
        Insn("movk", 5, 0xcc, 1),
        Insn("sturh", 5, 20, 8),           # mem[0x44080018] = 0xccbb
        Insn("ldurh", 6, 20, 8),           # x6 = 0xccbb
        Insn("sturw", 5, 20, 12),          # mem[0x4408001c] = 0xccbb
        Insn("ldurw", 7, 20, 12),          # x7 = 0xccbb
        # 符号扩展：ldursw/ldursb/ldursh
        Insn("movz", 8, 0xff80),           # 0x0000...ff80
        Insn("movk", 8, 0xffff, 1),
        Insn("movk", 8, 0xffff, 2),
        Insn("movk", 8, 0xffff, 3),        # x8 = 0xffffffffffff8000
        Insn("sturw", 8, 20, 16),          # mem[0x44080020] = 0xffff8000
        Insn("ldursw", 9, 20, 16),         # x9 = 0xffffffffffff8000
        Insn("sturb", 8, 20, 20),          # mem[0x44080024] = 0x00
        Insn("ldursb", 10, 20, 20),        # x10 = 0
        Insn("sturb", 3, 20, 21),          # mem[0x44080025] = 0xaa
        Insn("ldursb", 11, 20, 21),        # x11 = 0xffffffffffffffaa
        Insn("sturh", 8, 20, 24),          # mem[0x44080028] = 0x8000
        Insn("ldursh", 12, 20, 24),        # x12 = 0xffffffffffff8000
        # W 形式符号扩展（ldursb_w/ldursh_w）：高 32 位清零
        Insn("ldursb_w", 13, 20, 21),      # w13 = 0xffffffaa（x13=0xffffffaa）
        Insn("ldursh_w", 14, 20, 24),      # w14 = 0xffff8000
        # PRFUM 按 NOP
        Insn("sturb", 3, 20, 28),
        # cset/csetm/cinc/cinv/cneg（csinc 族 XZR 别名）
        Insn("movz", 0, 0),                # x0 = 0
        Insn("cmp", 0, 0),                 # Z=1
        Insn("cset", 15, "eq"),            # x15 = 1（Z=1 -> 1）
        Insn("cset", 16, "ne"),            # x16 = 0
        Insn("csetm", 17, "eq"),           # x17 = -1
        Insn("cinc", 18, 0, "eq"),         # x18 = x0 + 1 = 1
        Insn("cinv", 19, 0, "eq"),         # x19 = ~x0 = -1
        Insn("cneg", 20, 0, "ne"),         # x20 = x0（条件不满足）= 0
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_postpre_program(path):
    """P6 Linux 启动缺口：LDR/STR 单寄存器 pre/post-index + DC ZVA +
    DCZID_EL0。

    覆盖 X/W/H/B 的 post/pre-index（正/负偏移）、符号扩展
    （ldrsw/ldrsb/ldrsh X/W 形式）、str pre/post、dc zva 64B 清零
    与 DCZID_EL0 读取。期望值不硬编码，锁步差分与 QEMU 逐条比较。
    数据区 0x44090010..0x4409001f（dc zva 清 0x44090000 64B 块）。
    """
    main = assemble([
        Insn("label", "main"),
        # 基址 x21 = 0x44090010（普通寄存器；post/pre 基址写回用 wb3）
        Insn("movz", 21, 0x4409, 1),
        Insn("movk", 21, 0x10),
        # 初始化数据区
        Insn("movz", 0, 0xaa),
        Insn("sturb", 0, 21, 0),        # [0x10] = 0xaa
        Insn("movz", 0, 0xbb),
        Insn("sturb", 0, 21, 1),        # [0x11] = 0xbb
        Insn("movz", 0, 0x1234, 1),     # x0 = 0x1234
        Insn("sturh", 0, 21, 4),        # [0x14] = 0x1234
        Insn("movz", 0, 0x5678, 1),
        Insn("movk", 0, 0x1234),        # x0 = 0x12345678
        Insn("sturw", 0, 21, 8),        # [0x18] = 0x12345678
        Insn("movz", 0, 0xdef0, 3),
        Insn("movk", 0, 0x9abc, 2),
        Insn("movk", 0, 0x5678, 1),
        Insn("movk", 0, 0x1234),        # x0 = 0x123456789abcdef0
        Insn("stur", 0, 21, 8),         # [0x18] = 0x123456789abcdef0（8B 对齐）
        # post-index ldrb（内核 strlen 场景：ldrb w6,[x0],#1）
        Insn("orr", 20, 21, 31),        # x20 = 0x44090010
        Insn("ldrb_post", 2, 20, 1),    # x2 = [0x10] = 0xaa，x20 += 1
        Insn("ldrb_post", 3, 20, 1),    # x3 = [0x11] = 0xbb，x20 += 1
        Insn("ldrb_post", 4, 20, -1),   # x4 = [0x12] = 0，x20 -= 1
        # pre-index 各宽度
        Insn("orr", 20, 21, 31),
        Insn("ldrb_pre", 5, 20, 4),     # x20 += 4，x5 = [0x14] = 0x34
        Insn("orr", 20, 21, 31),
        Insn("ldrh_pre", 6, 20, 4),     # x20 += 4，x6 = [0x14] = 0x1234
        Insn("orr", 20, 21, 31),
        Insn("ldrw_pre", 7, 20, 8),     # x20 += 8，x7 = 0x12345678
        Insn("orr", 20, 21, 31),
        Insn("ldr_pre", 8, 20, 8),      # x20 += 8，x8 = 0x123456789abcdef0
        # 符号扩展
        Insn("orr", 20, 21, 31),
        Insn("ldrsw_post", 9, 20, 8),   # x9 = 0x12345678，x20 += 8
        Insn("orr", 20, 21, 31),
        Insn("ldrsb_post", 10, 20, 1),  # x10 = 0xffffffffffffffbb
        Insn("orr", 20, 21, 31),
        Insn("ldrsh_post", 11, 20, 4),  # x11 = 0x1234
        Insn("orr", 20, 21, 31),
        Insn("ldrsb_w_post", 12, 20, 1),  # w12 = 0xffffffbb
        Insn("orr", 20, 21, 31),
        Insn("ldrsh_w_post", 13, 20, 4),  # w13 = 0x1234
        # str pre/post
        Insn("orr", 20, 21, 31),
        Insn("strb_pre", 2, 20, 2),     # x20 += 2，[0x12] = 0xaa
        Insn("orr", 20, 21, 31),
        Insn("str_post", 8, 20, 8),     # x20 += 8，[0x18] = x8
        Insn("orr", 20, 21, 31),
        Insn("strb_post", 3, 20, 1),    # [0x10] = 0xbb，x20 += 1
        # DCZID_EL0（QEMU virt = 4）
        Insn("mrs_sys", 14, "dczid_el0"),
        # dc zva：清 [x20 & ~63] 64B（0x44090000 块，破坏数据区）
        Insn("orr", 20, 21, 31),
        Insn("dc_zva", 20),
        # 验证清零：读 [0x10..17] 应为 0
        Insn("orr", 20, 21, 31),
        Insn("ldr_post", 15, 20, 0),    # x15 = [0x10] = 0
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_ttbr1_program(path):
    """P6 MMU 锁步：39 位 TTBR0/TTBR1 根表与高 VA 线性映射。

    TCR.T0SZ/T1SZ=25（39 位 VA，Linux arm64 常用配置），所以两个 TTBR
    根表都是 L1 表：不能错误地固定从 L0 开始。TTBR0=0x44010000 恒等映射
    代码区（VA 0x44000000）；TTBR1=0x44016000 把高 VA
    0xffffff8040000000 映射到 PA 0x40000000（2 MiB block）。MMU 开启后经
    高 VA 写/读 PA 0x40000004，并用 TTBR0 恒等 VA 交叉验证。
    """
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 5, 0x4401, 1),
        Insn("movk", 5, 0x6000),        # TTBR1 = 0x44016000
        Insn("msr_sys", "ttbr1_el1", 5),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x19),          # TCR：T0SZ=25（39 位 VA）
        Insn("movk", 5, 0x19, 1),       # T1SZ=25，两个根表均从 L1 开始
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),          # MAIR attr0 = 0xFF（WB）
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),
        Insn("movk", 5, 0x839),         # SCTLR = 0xC50839（M=1）
        Insn("msr_sys", "sctlr_el1", 5),
        # 高 VA 线性映射：0xffffff8040000000 + 4
        Insn("movz", 0, 0xffff, 3),
        Insn("movk", 0, 0xff80, 2),
        Insn("movk", 0, 0x4000, 1),     # x0 = 0xffffff8040000000
        Insn("movz", 1, 0x1234),
        Insn("movk", 1, 0x5678, 1),     # x1 = 0x56781234
        Insn("str", 1, 0, 4),           # mem[VA 0xffff000040000004] = x1
        Insn("ldr", 2, 0, 4),           # 高 VA 读回
        # 恒等 VA 交叉验证（PA 0x40000004）
        Insn("movz", 3, 0x4000, 1),
        Insn("ldr", 4, 3, 4),           # x4 = mem[0x40000004]（恒等）
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    handler = assemble([
        Insn("movz", 9, 0x5a5a),
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("add", 10, 10, 4),
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x19000)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)

    def put64(off, val):
        buf[off:off + 8] = struct.pack("<Q", val)

    # T0（TTBR0=0x44010000）：39 位输入从 L1[1] 开始 -> L2 -> L3_code。
    put64(0x10000 + 1 * 8, 0x44012003)
    put64(0x12000 + 32 * 8, 0x44015003)
    put64(0x15000 + 0 * 8, 0x440004C3)
    put64(0x15000 + 0x10 * 8, 0x440104C3)
    # T1（TTBR1=0x44016000）：同样从 L1[1] 开始，L2[0]=2 MiB block。
    # VA 0xffffff8040000000 -> PA 0x40000000。
    put64(0x16000 + 1 * 8, 0x44018003)
    put64(0x18000 + 0 * 8, 0x400000C1)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_psci_program(path):
    """PSCI HVC 最小子集：VERSION、MIGRATE_INFO_TYPE、FEATURES、
    AFFINITY_INFO、CPU_ON。

    QEMU virt 默认使用 HVC conduit；每次 HVC 都应作为普通顺序提交，
    返回值写入 x0 且 PC 前进 4。该镜像不触发 SYSTEM_OFF/RESET，末尾
    进入自旋，便于 step 锁步在固定提交数停止。
    """
    main = assemble([
        Insn("label", "main"),
        # PSCI_VERSION -> 0x00010001
        Insn("movz", 0, 0x8400, 1),
        Insn("hvc", 0),
        # MIGRATE_INFO_TYPE -> 2（QEMU 无 Trusted OS）
        Insn("movz", 0, 0x8400, 1),
        Insn("movk", 0, 0x0006),
        Insn("hvc", 0),
        # PSCI_FEATURES(PSCI_VERSION) -> 0
        Insn("movz", 0, 0x8400, 1),
        Insn("movk", 0, 0x000a),
        Insn("movz", 1, 0x8400, 1),
        Insn("hvc", 0),
        # AFFINITY_INFO(MPIDR=0, level=0) -> 0（QEMU mp_affinity 不含 U 位）
        Insn("movz", 0, 0x8400, 1),
        Insn("movk", 0, 0x0004),
        Insn("movz", 1, 0),
        Insn("movz", 2, 0),
        Insn("hvc", 0),
        # CPU_ON(CPU0=0) -> ALREADY_ON (-4)
        Insn("movz", 0, 0x8400, 1),
        Insn("movk", 0, 0x0003),
        Insn("movz", 1, 0),
        Insn("movz", 2, 0x1000),
        Insn("movz", 3, 0x1234),
        Insn("hvc", 0),
        # CPU_ON(不存在的 MPIDR=0x80000000) -> INVALID_PARAMS (-2)
        Insn("movz", 0, 0x8400, 1),
        Insn("movk", 0, 0x0003),
        Insn("movz", 1, 0x8000, 1),
        Insn("movz", 2, 0x1000),
        Insn("movz", 3, 0x5678),
        Insn("hvc", 0),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(struct.pack(f"<{len(main)}I", *main))
    return BASE


def build_hard_psci_reset_program(path):
    """PSCI SYSTEM_RESET 差分终止语义：访客请求整机复位。

    QEMU 对 SYSTEM_RESET 执行 qemu_system_reset_request（寄存器清零、
    PC 回到复位向量），RTL 当前按 NOT_SUPPORTED 返回 -1 继续；锁步
    协调器收到 kind=4 DISCON 后把窗口定义为“访客复位/关机终止”
    （退出码 3），而不是逐指令比较失败。该镜像只验证协议终止路径，
    不参与普通 PASS 门。
    """
    main = assemble([
        Insn("label", "main"),
        # PSCI SYSTEM_RESET -> QEMU machine reset
        Insn("movz", 0, 0x8400, 1),
        Insn("movk", 0, 0x0009),
        Insn("hvc", 0),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(struct.pack(f"<{len(main)}I", *main))
    return BASE


def build_hard_varshift_program(path):
    """变量移位 LSLV/LSRV/ASRV/RORV 的 32 位移位量掩码。

    W 形式移位量取 Rm[4:0]（掩码到 31），X 形式取 Rm[5:0]。此前 32 位
    LSLV 用完整 6 位量，Wm=0x21 时 1<<33 得 0（QEMU 得 2）。
    """
    main = assemble([
        Insn("label", "main"),
        # W 形式：W1=0x21 -> 掩码 1
        Insn("movz", 1, 0x21),
        Insn("movz", 2, 1),
        Insn("lslv_w", 2, 2, 1),        # W2 = 1 << 1 = 2
        Insn("movz", 3, 1),
        Insn("lsrv_w", 3, 3, 1),        # W3 = 1 >> 1 = 0
        Insn("movz", 4, 0x4000, 1),     # W4 = 0x40000000
        Insn("lsrv_w", 4, 4, 1),        # W4 = 0x40000000 >> 1 = 0x20000000
        Insn("movz", 5, 0x8000, 1),     # W5 = 0x80000000
        Insn("movk", 5, 0x1),           # W5 = 0x80000001
        Insn("asrv_w", 5, 5, 1),        # W5 = 0x80000001 >> 1 = 0xc0000000
        Insn("movz", 6, 1),
        Insn("rorv_w", 6, 6, 1),        # W6 = 1 ror 1 = 0x80000000
        # W 形式：W1=0x20 -> 掩码 0（移位 32 视为 0）
        Insn("movz", 1, 0x20),
        Insn("movz", 2, 1),
        Insn("lslv_w", 2, 2, 1),        # W2 = 1 << 0 = 1
        # X 形式：X1=0x21 -> 完整 33
        Insn("movz", 1, 0x21),
        Insn("movz", 2, 1),
        Insn("lslv", 2, 2, 1),          # X2 = 1 << 33 = 0x200000000
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(struct.pack(f"<{len(main)}I", *main))
    return BASE


def build_hard_ldtr_sttr_program(path):
    """LDTR/STTR（非特权访存）：与 LDUR/STUR 同址语义，bits[11:10]=10。

    Linux /init 启动的 kernel copy 路径使用 STTR；旧 decode 把 2'b10
    排除导致 UDEF（ESR=0x02000000）。MMU 关闭时无权限检查，逐位对照
    QEMU 验证解码与访存。
    """
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 4, 0x4401, 1),     # x4 = 0x44010000（数据区）
        Insn("movz", 1, 0x1234),
        Insn("sttr", 1, 4, 0),          # STTR X1, [X4]
        Insn("ldtr", 2, 4, 0),          # LDTR X2, [X4] = 0x1234
        Insn("movz", 5, 0x4401, 1),
        Insn("movk", 5, 0x0008),        # x5 = 0x44010008
        Insn("movz", 3, 0x55),
        Insn("sttr", 3, 5, -8),         # STTR X3, [X5, #-8] -> 0x44010000
        Insn("ldtr", 6, 5, -8),         # LDTR X6, [X5, #-8] = 0x55
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(struct.pack(f"<{len(main)}I", *main))
    return BASE


def build_hard_adc_sbc_program(path):
    """ADC/ADCS/SBC/SBCS/NGC/NGCS（带进位/借位，0x1A000000 族）。

    Linux syscall 返回路径用 ngc x0,xzr 计算 -1 错误码；旧 decode 缺失
    导致 UDEF（ESR=0x02000000）。覆盖 C=0/1 两态与 W/X 形式。
    """
    main = assemble([
        Insn("label", "main"),
        # C=0：adds x5,#1（x5=1，无进位）
        Insn("movz", 5, 0),
        Insn("adds", 5, 5, 1),        # x5=1, C=0
        Insn("ngc", 0, 31),           # x0 = -0 - !0 = -1
        Insn("ngcs", 1, 31),          # x1 = -1, 标志更新
        Insn("adc", 2, 5, 5),         # x2 = 1 + 1 + C(0) = 2
        Insn("sbc", 3, 5, 5),         # x3 = 1 - 1 - !0 = -1
        # C=1：movn x5; adds x5,#1（x5=0，进位）
        Insn("movn", 5, 0),
        Insn("adds", 5, 5, 1),        # x5=0, C=1
        Insn("ngc", 4, 31),           # x4 = -0 - !1 = 0
        Insn("adc", 6, 5, 5),         # x6 = 0 + 0 + C(1) = 1
        Insn("sbcs", 7, 5, 5),        # x7 = 0 - 0 - !1 = 0, 标志更新
        # W 形式：32 位进位传播
        Insn("movz", 8, 0xffff),      # W8 = 0xffff
        Insn("movk", 8, 0xffff, 1),   # W8 = 0xffffffff
        Insn("movz", 9, 1),
        Insn("adds_w", 9, 9, 0x7ff),  # W9 = 0x800, C=0
        Insn("adc_w", 10, 8, 8),      # W10 = 0xffffffff + 0xffffffff + 0
        Insn("adcs_w", 11, 8, 9),     # W11 = 0xffffffff + 0x800, C=1
        Insn("sbc_w", 12, 9, 8),      # W12 = 0x800 - 0xffffffff - !C
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    Path(path).write_bytes(struct.pack(f"<{len(main)}I", *main))
    return BASE


def build_hard_dit_program(path):
    """PSTATE.DIT：立即数/寄存器写入和异常入口 SPSR 保存恢复。"""
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("raw", 0xD503415F),      # MSR DIT, #1
        Insn("mrs_sys", 0, "dit"),
        Insn("svc", 0),
        Insn("mrs_sys", 3, "dit"),
        Insn("raw", 0xD503405F),      # MSR DIT, #0
        Insn("mrs_sys", 4, "dit"),
        Insn("movz", 0, 0x100, 1),    # x0 = 0x1000000
        Insn("msr_sys", "dit", 0),
        Insn("mrs_sys", 5, "dit"),
        Insn("svc", 0),
        Insn("mrs_sys", 6, "dit"),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    handler = assemble([
        Insn("mrs_sys", 1, "spsr_el1"),
        Insn("mrs_sys", 2, "dit"),
        Insn("mrs_sys", 11, "elr_el1"),
        Insn("add", 11, 11, 4),
        Insn("msr_sys", "elr_el1", 11),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10600)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_allint_program(path):
    """PSTATE.ALLINT（bit13）：立即数/寄存器往返与异常保存恢复。

    ALLINT 是 FEAT_NMI 引入的独立总中断屏蔽位。QEMU 在 SCTLR.SPINTMASK=0
    的异常入口自动置位该位，SPSR_EL1 保存入口前值，ERET 再恢复。
    这里使用 raw 编码，避免测试生成器在系统寄存器表扩展前误用别名。
    """
    # d501401f/#0，d501411f/#1；d5384300/d5184300 为 MRS/MSR ALLINT。
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("raw", 0xd501411f),       # MSR ALLINT, #1
        Insn("raw", 0xd5384300),       # MRS X0, ALLINT -> 0x2000
        Insn("raw", 0xd501401f),       # MSR ALLINT, #0
        Insn("raw", 0xd5384301),       # MRS X1, ALLINT -> 0
        Insn("movz", 2, 0x2000),       # X2 = 0x2000
        Insn("raw", 0xd5184302),       # MSR ALLINT, X2
        Insn("raw", 0xd5384303),       # MRS X3, ALLINT -> 0x2000
        Insn("movz", 2, 0),
        Insn("raw", 0xd5184302),       # MSR ALLINT, X2(0)
        Insn("raw", 0xd5384304),       # MRS X4, ALLINT -> 0
        Insn("raw", 0xd501411f),       # 让异常前 ALLINT=1
        Insn("svc", 0),
        Insn("raw", 0xd5384305),       # ERET 后 ALLINT 应恢复为 1
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    handler = assemble([
        Insn("mrs_sys", 6, "spsr_el1"),  # bit13 应为 1
        Insn("raw", 0xd5384307),         # MRS X7, ALLINT（异常入口自动置 1）
        Insn("mrs_sys", 10, "elr_el1"),
        Insn("add", 10, 10, 4),
        Insn("msr_sys", "elr_el1", 10),
        Insn("eret"),
    ], 0x44010200)
    buf = bytearray(0x10600)
    for i, w in enumerate(main):
        buf[i * 4:i * 4 + 4] = struct.pack("<I", w)
    for i, w in enumerate(handler):
        off = 0x200 + i * 4
        buf[0x10000 + off:0x10000 + off + 4] = struct.pack("<I", w)
    Path(path).write_bytes(buf)
    return BASE


def build_hard_sctlr_pauth_program(path):
    """SCTLR_EL1 的 Pointer Authentication 使能位写掩码。

    当前 P6 标量目标不实现 PAuth，QEMU difftest 路径会把 EnIA/EnIB/
    EnDA/EnDB（bit31/30/27/13）按 WI 清零。写入复位值加四个使能位后，
    MRS 必须仍只读回 0x00c50838。
    """
    main = assemble([
        Insn("movz", 0, 0x2838),       # SCTLR reset low16 + EnDB
        Insn("movk", 0, 0xc8c5, 1),   # EnIA/EnIB/EnDA + reset high16
        Insn("msr_sys", "sctlr_el1", 0),
        Insn("mrs_sys", 1, "sctlr_el1"),
        Insn("movz", 2, 0x55aa),       # 后续普通提交，确认无错误重定向
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    build_program(path, main)
    return BASE


# ---- P7-1：FP32/FP64 标量垂直切片（A76 required lockstep）----
# 所有 FP 指令都使用 raw encoding；常量由 VFPExpandImm 编码得到，测试
# 程序不依赖 host 浮点或编译器生成的未选 FP 指令族。
def _fp3_raw(base, rd, rn, rm):
    return base | (rm << 16) | (rn << 5) | rd


def _fcmp_raw(rn, rm, dbl=False):
    return (0x1E602000 if dbl else 0x1E202000) | (rm << 16) | (rn << 5)


def _fcmp_zero_raw(rn, dbl=False):
    return (0x1E602008 if dbl else 0x1E202008) | (rn << 5)


def _fpmem_raw(base, rt, rn, imm12=0):
    return base | (imm12 << 10) | (rn << 5) | rt


def build_hard_fp_scalar_program(path):
    """Build the exact P7-1 directed program used by required lockstep.

    The program deliberately exercises every selected operation in both S and
    D forms, register FMOV, FCMP #0, and one S/D scalar store-load round trip.
    It ends in a self branch so the runner can stop at the known commit count.
    """
    main = assemble([
        # CPACR_EL1.FPEN=11, followed by ISB as required by AArch64 software.
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),                 # isb
        # FP32 arithmetic.
        Insn("raw", 0x1E2E1000),                 # fmov s0, #1.0
        Insn("raw", 0x1E201001),                 # fmov s1, #2.0
        Insn("raw", _fp3_raw(0x1E202800, 2, 0, 1)),  # fadd s2,s0,s1
        Insn("raw", _fp3_raw(0x1E203800, 3, 1, 0)),  # fsub s3,s1,s0
        Insn("raw", _fp3_raw(0x1E200800, 4, 0, 1)),  # fmul s4,s0,s1
        Insn("raw", _fp3_raw(0x1E201800, 5, 1, 0)),  # fdiv s5,s1,s0
        Insn("raw", _fcmp_raw(2, 1)),            # fcmp s2,s1
        # Data area 0x44001000 is outside the code image.
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, 0x1000),
        Insn("raw", _fpmem_raw(0xBD000000, 2, 10)),  # str s2,[x10]
        Insn("raw", _fpmem_raw(0xBD400000, 6, 10)),  # ldr s6,[x10]
        # FP64 arithmetic and scalar register move.
        Insn("raw", 0x1E6E1008),                 # fmov d8, #1.0
        Insn("raw", 0x1E601009),                 # fmov d9, #2.0
        Insn("raw", _fp3_raw(0x1E602800, 10, 8, 9)),  # fadd d10,d8,d9
        Insn("raw", _fp3_raw(0x1E603800, 11, 9, 8)),  # fsub d11,d9,d8
        Insn("raw", _fp3_raw(0x1E600800, 12, 8, 9)),  # fmul d12,d8,d9
        Insn("raw", _fp3_raw(0x1E601800, 13, 9, 8)),  # fdiv d13,d9,d8
        Insn("raw", _fcmp_raw(10, 9, dbl=True)),       # fcmp d10,d9
        Insn("raw", _fpmem_raw(0xFD000000, 10, 10, 1)), # str d10,[x10,#8]
        Insn("raw", _fpmem_raw(0xFD400000, 14, 10, 1)), # ldr d14,[x10,#8]
        Insn("raw", _fp3_raw(0x1E604000, 15, 14, 0)),  # fmov d15,d14
        Insn("raw", _fcmp_zero_raw(15, dbl=True)),      # fcmp d15,#0
        Insn("raw", _fp3_raw(0x1E204000, 15, 6, 0)),   # fmov s15,s6
        Insn("raw", _fcmp_zero_raw(15)),                # fcmp s15,#0
        Insn("raw", 0x14000000),                 # b .
    ], BASE)
    build_program(path, main)
    return BASE


def build_hard_fp_scalar_edge_program(path):
    """Build raw NaN/zero/infinity/subnormal and FPCR edge vectors.

    Constants are placed in a separate RAM page and loaded through the same
    selected scalar FP load path, so no host floating-point conversion is used.
    """
    data_base = 0x1000
    main = assemble([
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),                 # isb
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
        Insn("raw", _fpmem_raw(0xBD400000, 0, 10, 0)),  # qNaN S
        Insn("raw", _fpmem_raw(0xBD400000, 1, 10, 6)),  # +1.0 S
        Insn("raw", _fp3_raw(0x1E202800, 2, 0, 1)),     # qNaN + 1
        Insn("raw", _fpmem_raw(0xBD400000, 3, 10, 1)),  # sNaN S
        Insn("raw", _fp3_raw(0x1E202800, 4, 3, 1)),     # sNaN + 1
        Insn("raw", _fpmem_raw(0xBD400000, 5, 10, 2)),  # +Inf S
        Insn("raw", _fpmem_raw(0xBD400000, 6, 10, 3)),  # -Inf S
        Insn("raw", _fp3_raw(0x1E202800, 7, 5, 6)),     # Inf - Inf
        Insn("raw", _fpmem_raw(0xBD400000, 9, 10, 4)),  # +0 S
        Insn("raw", _fpmem_raw(0xBD400000, 13, 10, 5)), # min subnormal S
        Insn("raw", _fp3_raw(0x1E202800, 14, 13, 13)), # FZ=0: min+min
        Insn("raw", _fpmem_raw(0xFD400000, 21, 10, 11)), # min subnormal D
        Insn("raw", _fp3_raw(0x1E602800, 22, 21, 21)), # FZ=0: min+min
        Insn("raw", _fp3_raw(0x1E201800, 15, 5, 9)),    # Inf / 0: no DZC
        Insn("raw", _fp3_raw(0x1E201800, 8, 1, 9)),     # 1 / 0
        Insn("raw", _fp3_raw(0x1E201800, 10, 9, 9)),    # 0 / 0
        Insn("raw", _fcmp_raw(0, 1)),                   # qNaN unordered
        Insn("raw", _fcmp_raw(3, 1)),                   # sNaN unordered
        Insn("movz", 11, 0x300, 1),                     # DN|FZ
        Insn("raw", 0xD51B440B),                         # msr fpcr,x11
        Insn("raw", _fp3_raw(0x1E202800, 12, 0, 1)),   # DN qNaN
        Insn("raw", _fp3_raw(0x1E202800, 14, 13, 9)),  # FZ subnormal + 0
        Insn("raw", _fcmp_raw(13, 9)),                  # FZ compare
        # FP64 edge path: qNaN + 1, Inf/Inf, and scalar D load/store.
        Insn("raw", _fpmem_raw(0xFD400000, 15, 10, 8)), # qNaN D
        Insn("raw", _fpmem_raw(0xFD400000, 16, 10, 9)), # +1 D
        Insn("raw", _fp3_raw(0x1E602800, 17, 15, 16)),  # qNaN + 1
        Insn("raw", _fpmem_raw(0xFD400000, 18, 10, 10)), # +Inf D
        Insn("raw", _fpmem_raw(0xFD400000, 23, 10, 12)), # +0 D
        Insn("raw", _fp3_raw(0x1E601800, 24, 18, 23)),   # Inf / 0: no DZC
        Insn("raw", _fp3_raw(0x1E601800, 19, 18, 18)),  # Inf / Inf
        Insn("raw", _fpmem_raw(0xFD000000, 17, 10, 11)), # str d17
        Insn("raw", _fpmem_raw(0xFD400000, 20, 10, 11)), # ldr d20
        Insn("raw", 0x14000000),
    ], BASE)

    # Raw data page: S constants at byte offsets 0..20; D constants at
    # offsets 64,72,80. The image is loaded by QEMU and the RTL loader alike.
    data = bytearray(0x1000 + 104)
    data[:len(build_bytes(main))] = build_bytes(main)
    data[0x1000 + 0:0x1000 + 4] = struct.pack("<I", 0x7FC12345)
    data[0x1000 + 4:0x1000 + 8] = struct.pack("<I", 0x7FA12345)
    data[0x1000 + 8:0x1000 + 12] = struct.pack("<I", 0x7F800000)
    data[0x1000 + 12:0x1000 + 16] = struct.pack("<I", 0xFF800000)
    data[0x1000 + 16:0x1000 + 20] = struct.pack("<I", 0x00000000)
    data[0x1000 + 20:0x1000 + 24] = struct.pack("<I", 0x00000001)
    data[0x1000 + 24:0x1000 + 28] = struct.pack("<I", 0x3F800000)
    data[0x1000 + 64:0x1000 + 72] = struct.pack(
        "<Q", 0x7FF8123456789ABC)
    data[0x1000 + 72:0x1000 + 80] = struct.pack(
        "<Q", 0x3FF0000000000000)
    data[0x1000 + 80:0x1000 + 88] = struct.pack(
        "<Q", 0x7FF0000000000000)
    data[0x1000 + 88:0x1000 + 96] = struct.pack(
        "<Q", 0x0000000000000001)
    data[0x1000 + 96:0x1000 + 104] = struct.pack(
        "<Q", 0x0000000000000000)
    Path(path).write_bytes(data)
    return BASE


def build_hard_fp_scalar_rounding_program(path):
    """Build a tie case for all four architected FPCR.RMode values."""
    main = assemble([
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),                 # isb
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, 0x1000),
        Insn("raw", _fpmem_raw(0xBD400000, 0, 10, 0)),  # 1.0
        Insn("raw", _fpmem_raw(0xBD400000, 1, 10, 1)),  # 2^-24
        Insn("raw", _fp3_raw(0x1E202800, 2, 0, 1)),  # nearest-even
        Insn("movz", 11, 0x40, 1),
        Insn("raw", 0xD51B440B),                 # rmode=+Inf
        Insn("raw", _fp3_raw(0x1E202800, 3, 0, 1)),
        Insn("movz", 11, 0x80, 1),
        Insn("raw", 0xD51B440B),                 # rmode=-Inf
        Insn("raw", _fp3_raw(0x1E202800, 4, 0, 1)),
        Insn("movz", 11, 0xC0, 1),
        Insn("raw", 0xD51B440B),                 # rmode=zero
        Insn("raw", _fp3_raw(0x1E202800, 5, 0, 1)),
        Insn("raw", 0x14000000),
    ], BASE)
    data = bytearray(0x1000 + 8)
    data[:len(build_bytes(main))] = build_bytes(main)
    data[0x1000:0x1004] = struct.pack("<I", 0x3F800000)
    data[0x1004:0x1008] = struct.pack("<I", 0x33800000)
    Path(path).write_bytes(data)
    return BASE


def build_hard_fp_scalar_sequence_program(path, seed=1, rounds=32):
    """Build the deterministic 388-commit S/D forwarding stress sequence.

    ``seed`` is intentionally part of the public generator contract. A seed
    offset changes the finite FMOV immediate selection while seed=1 preserves
    the canonical sequence used by T-20260827-058 evidence.
    """
    if rounds <= 0:
        raise ValueError("rounds must be positive")
    values_s = [0x1E2E1000, 0x1E201000, 0x1E2C1000,
                0x1E2F1000, 0x1E2A1000]
    values_d = [0x1E6E1000, 0x1E601000, 0x1E6C1000,
                0x1E6F1000, 0x1E6A1000]
    ops_s = [0x1E202800, 0x1E203800, 0x1E200800, 0x1E201800]
    ops_d = [0x1E602800, 0x1E603800, 0x1E600800, 0x1E601800]
    offset = (seed - 1) % 5
    items = [Insn("movz", 0, 0x30, 1),
             Insn("msr_sys", "cpacr_el1", 0),
             Insn("raw", 0xD5033FDF)]
    for i in range(rounds):
        j = i + offset
        s0, s1 = j % 5, (j * 3 + 1) % 5
        d0, d1 = (j + 1) % 5, (j * 2 + 2) % 5
        items.extend([Insn("raw", values_s[s0] | 2),
                      Insn("raw", values_s[s1] | 3)])
        items.extend(Insn("raw", base | (3 << 16) | (2 << 5) | 4)
                     for base in ops_s)
        items.extend([Insn("raw", values_d[d0] | 8),
                      Insn("raw", values_d[d1] | 9)])
        items.extend(Insn("raw", base | (9 << 16) | (8 << 5) | 10)
                     for base in ops_d)
    items.append(Insn("raw", 0x14000000))
    words = assemble(items, BASE)
    build_program(path, words)
    return len(words)


# ---- P7-2：Advanced SIMD/Q 整数与单 Q 访存（A76 required lockstep）----
# 只生成协议已选定的 Q register-form/modified-immediate/unsigned-offset
# 指令；所有常量均为 raw 编码或 raw byte 数据，不经 host SIMD/float。
def _neon_3same(base, rd, rn, rm, size=0):
    return base | ((size & 3) << 22) | ((rm & 31) << 16) | \
        ((rn & 31) << 5) | (rd & 31)


def _neon_movi(rd, imm8, cmode=0xE):
    if cmode not in (0x0, 0x8, 0xE) or not 0 <= imm8 < 0x100:
        raise ValueError("P7-2 MOVI only accepts .4S/.8H/.16B byte immediates")
    base = {0x0: 0x4F000400, 0x8: 0x4F008400,
            0xE: 0x4F00E400}[cmode]
    return base | (((imm8 >> 5) & 7) << 16) | \
        ((imm8 & 0x1F) << 5) | (rd & 31)


def _neon_imm_shift(base, rd, rn, size, amount, right=True):
    width = 8 << size
    if amount <= 0 or amount > (width if right else width - 1):
        raise ValueError("invalid P7-2 immediate shift")
    encoded = (2 * width - amount) if right else (width + amount)
    return base | (((encoded >> 3) & 0xF) << 19) | \
        ((encoded & 7) << 16) | ((rn & 31) << 5) | (rd & 31)


def _neon_qmem(load, rt, rn, imm12=0):
    if not 0 <= imm12 < 0x1000:
        raise ValueError("invalid P7-2 Q memory immediate")
    return (0x3DC00000 if load else 0x3D800000) | \
        ((imm12 & 0xFFF) << 10) | ((rn & 31) << 5) | (rt & 31)


def build_hard_neon_int_program(path):
    """Build the P7-2 Q integer/load-store required-lockstep program.

    The image has two raw Q operands at DATA_BASE and a destination slot at
    DATA_BASE+0x20. The sequence deliberately exercises forwarding, every
    supported lane width, both signed/unsigned compare families, all five
    selected immediate shifts, a Q store/load round trip, and a load-use ORR.
    """
    data_base = 0x1000
    items = [
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),                 # ISB
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
        Insn("raw", _neon_qmem(True, 0, 10, 0)),
        Insn("raw", _neon_qmem(True, 1, 10, 1)),
        Insn("raw", _neon_movi(2, 0x5A)),
        Insn("raw", _neon_3same(0x4EA01C00, 3, 0, 1)),  # ORR
        Insn("raw", _neon_3same(0x4E201C00, 4, 0, 1)),  # AND
        Insn("raw", _neon_3same(0x6E201C00, 5, 0, 1)),  # EOR
        Insn("raw", _neon_3same(0x4E601C00, 6, 0, 1)),  # BIC
        Insn("raw", _neon_3same(0x4EE01C00, 7, 0, 1)),  # ORN
        Insn("raw", _neon_3same(0x4E208400, 8, 0, 1, 0)),
        Insn("raw", _neon_3same(0x4E208400, 9, 0, 1, 1)),
        Insn("raw", _neon_3same(0x4E208400, 10, 0, 1, 2)),
        Insn("raw", _neon_3same(0x6E208400, 11, 0, 1, 3)),
        Insn("raw", _neon_3same(0x6E208C00, 12, 0, 1, 0)),  # CMEQ
        Insn("raw", _neon_3same(0x4E203C00, 13, 0, 1, 1)),  # CMGE
        Insn("raw", _neon_3same(0x4E203400, 14, 0, 1, 2)),  # CMGT
        Insn("raw", _neon_3same(0x6E203400, 15, 0, 1, 3)),  # CMHI
        Insn("raw", _neon_3same(0x6E203C00, 16, 0, 1, 0)),  # CMHS
        Insn("raw", _neon_imm_shift(0x4F005400, 17, 8, 1, 3,
                                     right=False)),
        Insn("raw", _neon_imm_shift(0x4F000400, 18, 9, 2, 2)),
        Insn("raw", _neon_imm_shift(0x6F000400, 19, 10, 3, 4)),
        Insn("raw", _neon_imm_shift(0x4F001400, 20, 8, 0, 1)),
        Insn("raw", _neon_imm_shift(0x6F001400, 21, 9, 1, 2)),
        Insn("raw", _neon_qmem(False, 21, 10, 2)),
        Insn("raw", _neon_qmem(True, 22, 10, 2)),
        Insn("raw", _neon_3same(0x4EA01C00, 23, 22, 22)),
        Insn("raw", 0x14000000),                 # b .
    ]
    main = assemble(items, BASE)
    image = bytearray(data_base + 0x30)
    image[:len(build_bytes(main))] = build_bytes(main)
    # Q0: mixed signed/unsigned lanes; Q1: values chosen to exercise wrap,
    # equality and signed-vs-unsigned ordering without host arithmetic.
    q0_lo = 0x80000000_7fffffff_00010002_ffff0001
    q0_hi = 0x00000000_ffffffff_7fff8000_01020304
    q1_lo = 0x00000000_80000000_00020001_00010002
    q1_hi = 0xffff0000_00000001_80000000_01020304
    image[data_base:data_base + 8] = struct.pack("<Q", q0_lo & ((1 << 64) - 1))
    image[data_base + 8:data_base + 16] = struct.pack("<Q", q0_hi & ((1 << 64) - 1))
    image[data_base + 16:data_base + 24] = struct.pack("<Q", q1_lo & ((1 << 64) - 1))
    image[data_base + 24:data_base + 32] = struct.pack("<Q", q1_hi & ((1 << 64) - 1))
    Path(path).write_bytes(image)
    return len(main)


def _neon_fp_3same(base, rd, rn, rm, quad, double):
    """Encode only the P7-3 2S/4S/2D vector FP shapes."""
    if double and not quad:
        raise ValueError("P7-3 D.2/Q=0 is unsupported")
    return base | ((1 if quad else 0) << 30) | \
        ((1 if double else 0) << 22) | ((rm & 31) << 16) | \
        ((rn & 31) << 5) | (rd & 31)


def build_hard_neon_fp_program(path):
    """Build the A76-required P7-3 complete selected-shape raw FP program.

    Operands are loaded as raw Q state from the image.  The program covers
    every 2S/4S/2D x FADD/FSUB/FMUL/FCMEQ combination, vector FZ, all four
    RMode encodings, DN NaN propagation, signed-zero/NaN compare and V
    forwarding.  All inputs remain raw integer bit patterns.
    """
    data_base = 0x1000
    main = assemble([
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),                 # ISB
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
        Insn("raw", _neon_qmem(True, 0, 10, 0)),
        Insn("raw", _neon_qmem(True, 1, 10, 1)),
        Insn("raw", _neon_qmem(True, 2, 10, 2)),
        Insn("raw", _neon_qmem(True, 3, 10, 3)),
        Insn("raw", _neon_qmem(True, 6, 10, 6)),
        Insn("raw", _neon_qmem(True, 7, 10, 7)),
        Insn("raw", _neon_qmem(True, 8, 10, 8)),
        Insn("raw", _neon_qmem(True, 9, 10, 9)),
        Insn("raw", _neon_qmem(True, 24, 10, 24)),
        Insn("raw", _neon_qmem(True, 25, 10, 25)),
        Insn("raw", _neon_qmem(True, 27, 10, 27)),
        Insn("raw", _neon_qmem(True, 28, 10, 28)),
        # Complete selected 2S/4S/2D x FADD/FSUB/FMUL/FCMEQ matrix.
        Insn("raw", _neon_fp_3same(0x0E20D400, 12, 0, 1, False, False)),
        Insn("raw", _neon_fp_3same(0x0E20D400, 13, 0, 1, True, False)),
        Insn("raw", _neon_fp_3same(0x0E20D400, 14, 2, 3, True, True)),
        Insn("raw", _neon_fp_3same(0x0EA0D400, 15, 1, 0, False, False)),
        Insn("raw", _neon_fp_3same(0x0EA0D400, 16, 1, 0, True, False)),
        Insn("raw", _neon_fp_3same(0x0EA0D400, 17, 3, 2, True, True)),
        Insn("raw", _neon_fp_3same(0x2E20DC00, 18, 0, 1, False, False)),
        Insn("raw", _neon_fp_3same(0x2E20DC00, 19, 0, 1, True, False)),
        Insn("raw", _neon_fp_3same(0x2E20DC00, 20, 2, 3, True, True)),
        Insn("raw", _neon_fp_3same(0x0E20E400, 21, 6, 7, False, False)),
        Insn("raw", _neon_fp_3same(0x0E20E400, 22, 6, 7, True, False)),
        Insn("raw", _neon_fp_3same(0x0E20E400, 23, 8, 9, True, True)),
        # FZ input flush: min-subnormal + zero -> zero, FPSR.IDC.
        Insn("movz", 11, 0x100, 1),
        Insn("raw", 0xD51B440B),                # MSR FPCR, X11 (FZ)
        Insn("raw", _neon_fp_3same(0x0E20D400, 26, 24, 25, True, False)),
        # Four raw RMode settings using 1.0 + 2^-24 (a halfway case).
        Insn("movz", 11, 0),
        Insn("raw", 0xD51B440B),                # nearest-even
        Insn("raw", _neon_fp_3same(0x0E20D400, 29, 27, 28, True, False)),
        Insn("movz", 11, 0x40, 1),
        Insn("raw", 0xD51B440B),                # toward +Inf
        Insn("raw", _neon_fp_3same(0x0E20D400, 30, 27, 28, True, False)),
        Insn("movz", 11, 0x80, 1),
        Insn("raw", 0xD51B440B),                # toward -Inf
        Insn("raw", _neon_fp_3same(0x0E20D400, 31, 27, 28, True, False)),
        Insn("movz", 11, 0xC0, 1),
        Insn("raw", 0xD51B440B),                # toward zero
        Insn("raw", _neon_fp_3same(0x0E20D400, 27, 27, 28, True, False)),
        # DN qNaN propagation remains a raw vector-state comparison.
        Insn("movz", 11, 0x200, 1),
        Insn("raw", 0xD51B440B),                # MSR FPCR, X11 (DN)
        Insn("raw", _neon_fp_3same(0x0E20D400, 28, 8, 1, True, False)),
        Insn("raw", 0x14000000),                # b .
    ], BASE)

    raw_vectors = {
        0: 0x4080000040400000400000003F800000,
        1: 0x4100000040E0000040C0000040A00000,
        2: 0xC0000000000000003FF8000000000000,
        3: 0x40100000000000004000000000000000,
        6: 0x7FA012347FC01234800000003F800000,
        7: 0x3F8000007FC01234000000003F800000,
        8: 0x7FF80000000012348000000000000000,
        9: 0x7FF00000000012340000000000000000,
        24: 0x00000001000000010000000100000001,
        25: 0x00000000000000000000000000000000,
        27: 0x3F8000003F8000003F8000003F800000,
        28: 0x33800000338000003380000033800000,
    }
    image = bytearray(data_base + 0x200)
    image[:len(build_bytes(main))] = build_bytes(main)
    for slot, value in raw_vectors.items():
        off = data_base + slot * 16
        image[off:off + 8] = struct.pack("<Q", value & ((1 << 64) - 1))
        image[off + 8:off + 16] = struct.pack("<Q", value >> 64)
    Path(path).write_bytes(image)
    return len(main)




# ---- P7-4：FMA 与 FP/整数转换（A76 required lockstep）----
# 所有 FP/NEON 指令均为 raw encoding；常量按 raw bit 写入镜像数据页。
def _fma_raw(m, s, dbl, rd, rn, rm, ra):
    return (0x1F000000 | (int(dbl) << 22) | (m << 21) | ((rm & 31) << 16) |
            (s << 15) | ((ra & 31) << 10) | ((rn & 31) << 5) | (rd & 31))


def _cvt_g_raw(op6, sf, dbl, rd, rn, scale):
    """SCVTF/UCVTF/FCVTZS/FCVTZU scalar：整数形式 scale=0。

    op6：SCVTF 整数 100010 / 定点 000010；UCVTF 100011/000011；
    FCVTZS 111000/011000；FCVTZU 111001/011001。
    """
    width = 64 if sf else 32
    if scale == 0:
        return (0x1E000000 | (int(sf) << 31) | (int(dbl) << 22) |
                (op6 << 16) | ((rn & 31) << 5) | (rd & 31))
    field = width - scale
    insn = (0x1E000000 | (int(sf) << 31) | (int(dbl) << 22) | (op6 << 16))
    if sf:
        insn |= (field & 0x3F) << 10
    else:
        insn |= (1 << 15) | ((field & 0x1F) << 10)
    return insn | ((rn & 31) << 5) | (rd & 31)


def _scvtf_raw(sf, dbl, rd, rn, scale=0):
    return _cvt_g_raw(0b100010 if scale == 0 else 0b000010,
                      sf, dbl, rd, rn, scale)


def _ucvtf_raw(sf, dbl, rd, rn, scale=0):
    return _cvt_g_raw(0b100011 if scale == 0 else 0b000011,
                      sf, dbl, rd, rn, scale)


def _fcvtzs_raw(sf, dbl, rd, rn, scale=0):
    return _cvt_g_raw(0b111000 if scale == 0 else 0b011000,
                      sf, dbl, rd, rn, scale)


def _fcvtzu_raw(sf, dbl, rd, rn, scale=0):
    return _cvt_g_raw(0b111001 if scale == 0 else 0b011001,
                      sf, dbl, rd, rn, scale)


def _fcvt_raw(rd, rn, to_double):
    # FCVT S->D 编码 bit22=0；D->S bit22=1（objdump 实测）。
    opbits = 0b000101 if to_double else 0b000100
    return (0x1E000000 | (int(not to_double) << 22) | (1 << 21) |
            (opbits << 15) | (0b10000 << 10) | ((rn & 31) << 5) |
            (rd & 31))


def _neon_conv_raw(base, rd, rn, quad, dbl):
    return (base | (int(quad) << 30) | (int(dbl) << 22) |
            ((rn & 31) << 5) | (rd & 31))


_P74_VEC = {
    # S 数据（4 个 lane）
    0: 0x40000000400000004000000040000000,   # {2.0 x4}
    1: 0x40400000404000004040000040400000,   # {3.0 x4}
    2: 0x41200000412000004120000041200000,   # {10.0 x4}
    6: 0x4080000040400000400000003F800000,   # {1,2,3,4}
    7: 0x40C0000040A000004080000040600000,   # {5,6,7,8}
    18: 0x00000001000000010000000100000001,  # min subnormal S x4
    16: 0x7FC333337FC333337FC333337FC33333,  # qNaN 4S（DN 用）
    17: 0x7FC333337FC333337FC333337FC33333,  # qNaN 4S
    27: 0x41200000412000000000000000000000,  # 2S addend {10,10}
    28: 0x41200000412000004120000041200000,  # 4S addend {10,10,10,10}
    30: 0x41200000412000000000000000000000,  # 2S addend {10,10}
    # D 数据（2 个 lane）
    3: 0x40000000000000004000000000000000,   # {2,2}
    4: 0x40080000000000004008000000000000,   # {3,3}
    5: 0x40240000000000004024000000000000,   # {10,10}
    8: 0x40080000000000004000000000000000,   # {2,3}
    9: 0x40140000000000004010000000000000,   # {4,5}
    19: 0x00000000000000010000000000000001,  # min subnormal D x2
    29: 0x40240000000000004024000000000000,  # 2D addend {10,10}
    31: 0x40240000000000004024000000000000,  # 2D addend {10,10}
    # 整数源
    24: 0x0000000000000000FFFFFFFE00000001,  # 2S int {1,-2}
    25: 0xFFFFFFFC00000003FFFFFFFE00000001,  # 4S int {1,-2,3,-4}
    26: 0x00000000000000017FFFFFFFFFFFFFFF,  # 2D int {INT64_MAX,1}
}


def _p74_write_image(path, main, handler, data_base=0x1000,
                     handler_base=0x2000):
    image = bytearray(handler_base + 0x800)
    image[:len(build_bytes(main))] = build_bytes(main)
    if handler:
        off = handler_base + 0x400   # EL1 sync vector
        image[off:off + len(build_bytes(handler))] = build_bytes(handler)
    for slot, value in _P74_VEC.items():
        off = data_base + slot * 16
        image[off:off + 8] = struct.pack("<Q", value & ((1 << 64) - 1))
        image[off + 8:off + 16] = struct.pack("<Q", value >> 64)
    Path(path).write_bytes(image)


def build_hard_p7_4_fma_convert_program(path):
    """P7-4 主定向程序：四 FMA 族、标量转换/FCVT、向量 FMA 与 12 个
    转换形状、DN/FZ/四种 RMode、以及 FPEN=00 的 FP access trap。
    """
    data_base = 0x1000
    main = assemble([
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),                 # ISB
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
    ] + [Insn("raw", _neon_qmem(True, i, 10, i)) for i in range(10)] + [
        Insn("raw", _neon_qmem(True, 18, 10, 18)),
        Insn("raw", _neon_qmem(True, 19, 10, 19)),
        Insn("raw", _neon_qmem(True, 24, 10, 24)),
        Insn("raw", _neon_qmem(True, 25, 10, 25)),
        Insn("raw", _neon_qmem(True, 26, 10, 26)),
        Insn("raw", _neon_qmem(True, 27, 10, 27)),
        Insn("raw", _neon_qmem(True, 28, 10, 28)),
        Insn("raw", _neon_qmem(True, 29, 10, 29)),
        Insn("raw", _neon_qmem(True, 30, 10, 30)),
        Insn("raw", _neon_qmem(True, 31, 10, 31)),
        # 标量 FMA 四族 S/D。
        Insn("raw", _fma_raw(0, 0, False, 11, 0, 1, 2)),
        Insn("raw", _fma_raw(0, 1, False, 12, 0, 1, 2)),
        Insn("raw", _fma_raw(1, 0, False, 13, 0, 1, 2)),
        Insn("raw", _fma_raw(1, 1, False, 14, 0, 1, 2)),
        Insn("raw", _fma_raw(0, 0, True, 15, 3, 4, 5)),
        Insn("raw", _fma_raw(0, 1, True, 16, 3, 4, 5)),
        Insn("raw", _fma_raw(1, 0, True, 17, 3, 4, 5)),
        Insn("raw", _fma_raw(1, 1, True, 18, 3, 4, 5)),
        # 标量转换与 FCVT。
        Insn("movz", 21, 3),
        Insn("raw", _scvtf_raw(False, False, 20, 21, 3)),   # 3/8 S
        Insn("raw", _ucvtf_raw(True, True, 22, 21, 32)),    # 3/2^32 D
        Insn("raw", _fcvtzs_raw(False, False, 23, 20, 0)),  # 0, IXC
        Insn("raw", _fcvtzu_raw(True, True, 24, 22, 63)),   # 3*2^31
        Insn("raw", _fcvt_raw(25, 20, True)),               # S->D
        Insn("raw", _fcvt_raw(26, 25, False)),              # D->S
        # 向量 FMA/FMLS：2S/4S/2D 全组合。
        Insn("raw", _neon_fp_3same(0x0E20CC00, 27, 0, 1, False, False)),
        Insn("raw", _neon_fp_3same(0x0E20CC00, 28, 6, 7, True, False)),
        Insn("raw", _neon_fp_3same(0x0E20CC00, 29, 8, 9, True, True)),
        Insn("raw", _neon_fp_3same(0x0EA0CC00, 30, 0, 1, False, False)),
        Insn("raw", _neon_fp_3same(0x0EA0CC00, 31, 8, 9, True, True)),
        # 向量整数转换 12 形状。
        Insn("raw", _neon_conv_raw(0x0E21D800, 20, 24, False, False)),
        Insn("raw", _neon_conv_raw(0x2E21D800, 21, 24, False, False)),
        Insn("raw", _neon_conv_raw(0x0E21D800, 22, 25, True, False)),
        Insn("raw", _neon_conv_raw(0x2E21D800, 23, 25, True, False)),
        Insn("raw", _neon_conv_raw(0x0E21D800, 26, 26, True, True)),
        Insn("raw", _neon_conv_raw(0x2E21D800, 27, 26, True, True)),
        Insn("raw", _neon_conv_raw(0x0EA1B800, 20, 0, False, False)),
        Insn("raw", _neon_conv_raw(0x2EA1B800, 21, 0, False, False)),
        Insn("raw", _neon_conv_raw(0x0EA1B800, 22, 0, True, False)),
        Insn("raw", _neon_conv_raw(0x2EA1B800, 23, 0, True, False)),
        Insn("raw", _neon_conv_raw(0x0EA1B800, 26, 8, True, True)),
        Insn("raw", _neon_conv_raw(0x2EA1B800, 27, 8, True, True)),
        # FZ：标量/向量输入 subnormal flush -> IDC。
        Insn("raw", _neon_qmem(True, 18, 10, 18)),   # 重载 min sub S
        Insn("movz", 11, 0x100, 1),
        Insn("raw", 0xD51B440B),                 # MSR FPCR, X11 (FZ)
        Insn("raw", _fma_raw(0, 0, False, 20, 0, 1, 18)),  # min sub addend
        Insn("raw", _neon_fp_3same(0x0E20CC00, 18, 0, 1, False, False)),
        # DN：FMA 的 qNaN addend -> default NaN。
        Insn("raw", _neon_qmem(True, 16, 10, 16)),   # 重载 qNaN 4S
        Insn("movz", 11, 0x200, 1),
        Insn("raw", 0xD51B440B),                 # MSR FPCR, X11 (DN)
        Insn("raw", _fma_raw(0, 0, False, 21, 0, 1, 16)),   # qNaN addend
        Insn("raw", _neon_fp_3same(0x0E20CC00, 16, 6, 7, True, False)),
        # 四种 RMode：UCVTF 0xffffffff,#32 的舍入边界。
        Insn("movz", 21, 0xffff),
        Insn("movk", 21, 0xffff, 1),
        Insn("movz", 11, 0),
        Insn("raw", 0xD51B440B),
        Insn("raw", _ucvtf_raw(False, False, 22, 21, 32)),
        Insn("movz", 11, 0x40, 1),
        Insn("raw", 0xD51B440B),
        Insn("raw", _ucvtf_raw(False, False, 23, 21, 32)),
        Insn("movz", 11, 0x80, 1),
        Insn("raw", 0xD51B440B),
        Insn("raw", _ucvtf_raw(False, False, 24, 21, 32)),
        Insn("movz", 11, 0xC0, 1),
        Insn("raw", 0xD51B440B),
        Insn("raw", _ucvtf_raw(False, False, 25, 21, 32)),
        # FPEN=00：FMA 触发 FP access trap，handler 跳过陷阱指令后 ERET。
        Insn("movz", 3, 0x4400, 1),
        Insn("movk", 3, 0x2000),
        Insn("msr_sys", "vbar_el1", 3),
        Insn("msr_sys", "cpacr_el1", 31),        # FPEN=00
        Insn("raw", 0xD5033FDF),                 # ISB
        Insn("raw", _fma_raw(0, 0, False, 20, 0, 1, 2)),  # trap
        Insn("msr_sys", "cpacr_el1", 0),         # 恢复 FPEN=11
        Insn("raw", 0xD5033FDF),                 # ISB
        Insn("raw", 0x14000000),                 # b .
    ], BASE)
    handler = assemble([
        Insn("mrs_sys", 4, "elr_el1"),
        Insn("add", 4, 4, 4),
        Insn("msr_sys", "elr_el1", 4),
        Insn("eret"),
    ], BASE)
    _p74_write_image(path, main, handler)
    return len(main) + len(handler)


def build_hard_p7_4_fma_convert_edge_program(path):
    """P7-4 边界程序：NaN 优先级/符号、Inf*0、饱和、定点边界、subnormal。
    """
    data_base = 0x1000
    main = assemble([
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
    ] + [Insn("raw", _neon_qmem(True, i, 10, i)) for i in range(20)] + [
        # FMA NaN：c,a,b 优先级；SNaN 先于 QNaN；FN* 翻转输入符号。
        Insn("raw", _fma_raw(0, 0, False, 20, 0, 1, 2)),
        Insn("raw", _fma_raw(0, 0, False, 21, 3, 1, 2)),
        Insn("raw", _fma_raw(1, 0, False, 22, 0, 1, 2)),
        Insn("raw", _fma_raw(1, 1, False, 23, 3, 1, 2)),
        Insn("raw", _fma_raw(0, 0, True, 24, 4, 5, 6)),
        # 0*Inf、Inf-Inf、零符号。
        Insn("raw", _fma_raw(0, 0, False, 25, 7, 8, 9)),
        Insn("raw", _fma_raw(0, 0, False, 26, 7, 7, 10)),
        Insn("raw", _fma_raw(0, 0, False, 27, 11, 11, 12)),
        Insn("raw", _fma_raw(0, 0, False, 28, 11, 12, 12)),
        # 标量转换饱和/边界。
        Insn("movz", 21, 0xffff),                # w21 = 0xffffffff
        Insn("movk", 21, 0xffff, 1),
        Insn("raw", _ucvtf_raw(False, False, 29, 21, 32)),   # -> 1.0 IXC
        Insn("raw", _fcvtzu_raw(False, False, 22, 29, 0)),   # -> 1
        Insn("raw", _fcvtzs_raw(False, True, 23, 6, 0)),     # qNaN -> 0 IOC
        Insn("raw", _fcvtzu_raw(True, True, 24, 13, 0)),     # -1 -> 0 IOC
        Insn("raw", _fcvtzs_raw(False, False, 25, 14, 0)),   # 2^31 sat
        Insn("raw", _fcvtzu_raw(False, False, 26, 15, 0)),   # 2^32 sat
        Insn("raw", _fcvtzs_raw(True, True, 27, 16, 63)),    # Inf -> max
        Insn("raw", _fcvt_raw(28, 17, True)),    # S sub -> D 精确
        Insn("raw", _fcvt_raw(29, 18, False)),   # D sub -> S 0 UFC|IXC
        # 向量 lane NaN/saturation/FZ。
        Insn("raw", _neon_fp_3same(0x0E20CC00, 20, 0, 1, False, False)),
        Insn("raw", _neon_conv_raw(0x0EA1B800, 21, 6, False, False)),
        Insn("raw", _neon_conv_raw(0x2EA1B800, 22, 7, True, False)),
        Insn("raw", _neon_conv_raw(0x0EA1B800, 23, 8, True, True)),
        Insn("raw", _neon_conv_raw(0x2EA1B800, 24, 9, True, True)),
        Insn("movz", 11, 0x100, 1),
        Insn("raw", 0xD51B440B),                 # FZ
        Insn("raw", _neon_conv_raw(0x0EA1B800, 25, 19, True, False)),
        Insn("raw", 0x14000000),
    ], BASE)
    # 边界数据：S 槽 0-3 与 D 槽 4-6 是 NaN/Inf/zero，槽 7-9 是 2^31/2^32。
    edge = {
        0: 0x7FC333337FC333337FC333337FC33333,   # qNaN
        1: 0x7FA111117FA111117FA111117FA11111,   # sNaN
        2: 0x3F8000003F8000003F8000003F800000,   # 1.0
        3: 0x7FC111117FC111117FC111117FC11111,   # qNaN（FN* 符号翻转）
        4: 0x7FF8123456789ABC7FF8123456789ABC,   # D qNaN
        5: 0x40000000000000004000000000000000,   # D 2.0
        6: 0x40240000000000004024000000000000,   # D 10.0
        7: 0x7F8000007F8000007F8000007F800000,   # +Inf
        8: 0x00000000000000000000000000000000,   # +0
        9: 0x3F8000003F8000003F8000003F800000,   # 1.0
        10: 0xFF800000FF800000FF800000FF800000,  # -Inf
        11: 0x00000000000000000000000000000000,  # +0
        12: 0x80000000800000008000000080000000,  # -0
        13: 0xBFF0000000000000BFF0000000000000,  # -1.0 D
        14: 0x4F0000004F0000004F0000004F000000,  # 2^31 S
        15: 0x4F8000004F8000004F8000004F800000,  # 2^32 S
        16: 0x7FF00000000000007FF0000000000000,  # +Inf D
        17: 0x00000001000000010000000100000001,  # min sub S
        18: 0x00000000000000010000000000000001,  # min sub D
        19: 0x00000001000000010000000100000001,  # min sub S（FZ 转换）
    }
    image = bytearray(0x1000 + 20 * 16)
    image[:len(build_bytes(main))] = build_bytes(main)
    for slot, value in edge.items():
        off = data_base + slot * 16
        image[off:off + 8] = struct.pack("<Q", value & ((1 << 64) - 1))
        image[off + 8:off + 16] = struct.pack("<Q", value >> 64)
    Path(path).write_bytes(image)
    return len(main)


def build_hard_p7_4_fma_convert_rounding_program(path):
    """四种 RMode 下 FMA 与转换的 raw 舍入对照。"""
    data_base = 0x1000
    main = assemble([
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
        Insn("raw", _neon_qmem(True, 0, 10, 0)),
        Insn("raw", _neon_qmem(True, 1, 10, 1)),
        Insn("raw", _neon_qmem(True, 2, 10, 2)),
        Insn("movz", 21, 0xffff),
        Insn("movk", 21, 0xffff, 1),
        Insn("movz", 11, 0),
        Insn("raw", 0xD51B440B),
        Insn("raw", _fma_raw(0, 0, False, 3, 0, 1, 2)),
        Insn("raw", _ucvtf_raw(False, False, 4, 21, 32)),
        Insn("movz", 11, 0x40, 1),
        Insn("raw", 0xD51B440B),
        Insn("raw", _fma_raw(0, 0, False, 5, 0, 1, 2)),
        Insn("raw", _ucvtf_raw(False, False, 6, 21, 32)),
        Insn("movz", 11, 0x80, 1),
        Insn("raw", 0xD51B440B),
        Insn("raw", _fma_raw(0, 0, False, 7, 0, 1, 2)),
        Insn("raw", _ucvtf_raw(False, False, 8, 21, 32)),
        Insn("movz", 11, 0xC0, 1),
        Insn("raw", 0xD51B440B),
        Insn("raw", _fma_raw(0, 0, False, 9, 0, 1, 2)),
        Insn("raw", _ucvtf_raw(False, False, 10, 21, 32)),
        Insn("raw", 0x14000000),
    ], BASE)
    data = bytearray(0x1000 + 3 * 16)
    data[:len(build_bytes(main))] = build_bytes(main)
    # 1.0 + 2^-23（S 的 tie 附近）、2.0、10.0。
    data[0x1000:0x1004] = struct.pack("<I", 0x3F800001)
    data[0x1004:0x1008] = struct.pack("<I", 0x3F800001)
    data[0x1008:0x100C] = struct.pack("<I", 0x3F800001)
    data[0x100C:0x1010] = struct.pack("<I", 0x3F800001)
    data[0x1010:0x1014] = struct.pack("<I", 0x3F800000)
    data[0x1014:0x1018] = struct.pack("<I", 0x3F800000)
    data[0x1018:0x101C] = struct.pack("<I", 0x3F800000)
    data[0x101C:0x1020] = struct.pack("<I", 0x3F800000)
    data[0x1020:0x1024] = struct.pack("<I", 0x3F800000)
    data[0x1024:0x1028] = struct.pack("<I", 0x3F800000)
    data[0x1028:0x102C] = struct.pack("<I", 0x3F800000)
    data[0x102C:0x1030] = struct.pack("<I", 0x3F800000)
    Path(path).write_bytes(data)
    return len(main)

def build_hard_p7_4_fma_convert_sequence_program(path, seed=1, rounds=8):
    """确定性 FMA/转换背靠背压力序列（forwarding + sticky）。

    ``seed`` 只平移每轮整数初值；rounds=8 固定产生 100 条提交。
    """
    if rounds <= 0:
        raise ValueError("rounds must be positive")
    items = [Insn("movz", 0, 0x30, 1),
             Insn("msr_sys", "cpacr_el1", 0),
             Insn("raw", 0xD5033FDF),
             Insn("movz", 10, 0x4400, 1),
             Insn("movk", 10, 0x1000)]
    for i in range(rounds):
        a = ((i + seed) * 3 + 1) & 0xFFFF
        b = ((i + seed) * 7 + 2) & 0xFFFF
        items += [
            Insn("movz", 21, a),
            Insn("movz", 22, b),
            Insn("raw", _scvtf_raw(False, False, 0, 21, 0)),
            Insn("raw", _scvtf_raw(False, False, 1, 22, 0)),
            Insn("raw", _fma_raw(0, 0, False, 2, 0, 1, 0)),
            Insn("raw", _fma_raw(0, 1, False, 3, 1, 0, 2)),
            Insn("raw", _fma_raw(1, 0, False, 4, 0, 2, 3)),
            Insn("raw", _fma_raw(1, 1, False, 5, 1, 3, 4)),
            Insn("raw", _fcvtzs_raw(False, False, 23, 5, 0)),
            Insn("raw", _scvtf_raw(True, True, 7, 21, 0)),
            Insn("raw", _fcvtzu_raw(True, True, 24, 7, 0)),
            Insn("raw", _neon_qmem(True, 20, 10, 20)),
            Insn("raw", _neon_qmem(True, 21, 10, 21)),
            Insn("raw", _neon_fp_3same(0x0E20CC00, 20, 20, 21,
                                       False, False)),
            Insn("raw", _neon_qmem(True, 22, 10, 22)),
            Insn("raw", _neon_qmem(True, 23, 10, 23)),
            Insn("raw", _neon_fp_3same(0x0EA0CC00, 22, 22, 23,
                                       True, True)),
        ]
    items.append(Insn("raw", 0x14000000))
    main = assemble(items, BASE)
    image = bytearray(0x1000 + 24 * 16)
    image[:len(build_bytes(main))] = build_bytes(main)
    seq_vec = {
        20: 0x40400000400000000000000000000000,   # 2S {2,3}
        21: 0x40A00000408000000000000000000000,   # 2S {4,5}
        22: 0x40080000000000004000000000000000,   # 2D {2,3}
        23: 0x40140000000000004010000000000000,   # 2D {4,5}
    }
    for slot in (20, 21, 22, 23):
        value = seq_vec[slot]
        off = 0x1000 + slot * 16
        image[off:off + 8] = struct.pack("<Q", value & ((1 << 64) - 1))
        image[off + 8:off + 16] = struct.pack("<Q", value >> 64)
    Path(path).write_bytes(image)
    return len(main)

# ---- P7-5：FP16/sqrt/minmax/rint（A76 required lockstep）----
# 所有 FP/NEON 指令均为 raw encoding；常量按 raw bit 写入镜像数据页。
def _fp_h3(base, rd, rn, rm):
    """Scalar FP16 three-same（esz=11 已含在 base）。"""
    return base | ((rm & 31) << 16) | ((rn & 31) << 5) | (rd & 31)


def _fp_h1(base, rd, rn):
    """Scalar FP16 one-source。"""
    return base | ((rn & 31) << 5) | (rd & 31)


def _fp_sd3(base, rd, rn, rm, dbl):
    return base | (int(dbl) << 22) | ((rm & 31) << 16) | \
        ((rn & 31) << 5) | (rd & 31)


def _fp_sd1(base, rd, rn, dbl):
    return base | (int(dbl) << 22) | ((rn & 31) << 5) | (rd & 31)


def _fp_fcvt(rd, rn, esz, op6):
    """FCVT：esz=源格式（0=S,1=D,3=H），op6 选目的。"""
    return 0x1E000000 | ((esz & 3) << 22) | (1 << 21) | \
        ((op6 & 0x3F) << 15) | (0b10000 << 10) | \
        ((rn & 31) << 5) | (rd & 31)


def _neon_v3(base, rd, rn, rm, quad):
    return base | (int(quad) << 30) | ((rm & 31) << 16) | \
        ((rn & 31) << 5) | (rd & 31)


def _neon_v2(base, rd, rn, quad):
    return base | (int(quad) << 30) | ((rn & 31) << 5) | (rd & 31)


def _p75_write_image(path, main, handler, vec, data_base=0x1000,
                     handler_base=0x2000):
    image = bytearray(handler_base + 0x800)
    image[:len(build_bytes(main))] = build_bytes(main)
    if handler:
        off = handler_base + 0x400   # EL1 sync vector
        image[off:off + len(build_bytes(handler))] = build_bytes(handler)
    for slot, (lo, hi) in vec.items():
        off = data_base + slot * 16
        image[off:off + 8] = struct.pack("<Q", lo & ((1 << 64) - 1))
        image[off + 8:off + 16] = struct.pack("<Q", hi & ((1 << 64) - 1))
    Path(path).write_bytes(image)


def _p75_skip_handler():
    return assemble([
        Insn("mrs_sys", 4, "elr_el1"),
        Insn("add", 4, 4, 4),
        Insn("msr_sys", "elr_el1", 4),
        Insn("eret"),
    ], BASE)


# FP16 值：1.0=3C00 2.0=4000 1.5=3E00 3.0=4200 0.5=3800 -1.0=BC00
# 2.5=4100 4.0=4400 -2.0=C000 8.0=4800 0.25=3400。
_P75_H_LO = 0x42003E0040003C00
_P75_H_HI = 0x44004100BC003800
_P75_H2_LO = 0x38003C0044004000
_P75_H2_HI = 0x34003E004800C000


def build_hard_p7_5_fp16_sqrt_minmax_round_program(path):
    """P7-5 主定向程序：标量 H/S/D 算术、sqrt、min/max、rint、FCVT、
    4H/8H 向量 add/sub/mul/cmp、2S/4S/2D sqrt/minmax/rint、FZ16/AHP、
    四种 RMode、FPEN=00 trap 与 UDEF。
    """
    data_base = 0x1000
    items = [
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),                 # ISB
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
    ]
    for i in range(8):
        items.append(Insn("raw", _neon_qmem(True, i, 10, i)))
    items += [
        # ---- 标量 H 算术 ----
        Insn("raw", _fp_h3(0x1EE02800, 4, 0, 1)),   # fadd h4,h0,h1
        Insn("raw", _fp_h3(0x1EE03800, 5, 1, 0)),   # fsub h5,h1,h0
        Insn("raw", _fp_h3(0x1EE00800, 6, 0, 1)),   # fmul h6,h0,h1
        Insn("raw", _fp_h3(0x1EE01800, 7, 1, 0)),   # fdiv h7,h1,h0
        Insn("raw", 0x1EE02000 | (5 << 16) | (4 << 5)),  # fcmp h4,h5
        Insn("raw", 0x1EE02008 | (4 << 5)),              # fcmp h4,#0
        Insn("raw", 0x1EEE1008),                    # fmov h8,#1.0
        Insn("raw", _fp_h1(0x1EE04000, 9, 8)),      # fmov h9,h8
        # ---- FCVT H<->S/D ----
        Insn("raw", _fp_fcvt(10, 9, 3, 0b000100)),  # fcvt s10,h9
        Insn("raw", _fp_fcvt(11, 9, 3, 0b000101)),  # fcvt d11,h9
        Insn("raw", _fp_fcvt(12, 10, 0, 0b000111)), # fcvt h12,s10
        Insn("raw", _fp_fcvt(13, 11, 1, 0b000111)), # fcvt h13,d11
        # ---- 标量 H sqrt/minmax/rint ----
        Insn("raw", _fp_h1(0x1EE1C000, 14, 2)),     # fsqrt h14,h2（4.0）
        Insn("raw", _fp_h3(0x1EE04800, 15, 0, 1)),  # fmax h15,h0,h1
        Insn("raw", _fp_h3(0x1EE05800, 16, 0, 1)),  # fmin h16,h0,h1
        Insn("raw", _fp_h3(0x1EE06800, 17, 0, 1)),  # fmaxnm h17,h0,h1
        Insn("raw", _fp_h3(0x1EE07800, 18, 0, 1)),  # fminnm h18,h0,h1
        Insn("raw", _fp_h1(0x1EE44000, 19, 3)),     # frintn h19,h3
        Insn("raw", _fp_h1(0x1EE4C000, 20, 3)),     # frintp h20,h3
        Insn("raw", _fp_h1(0x1EE54000, 21, 3)),     # frintm h21,h3
        Insn("raw", _fp_h1(0x1EE5C000, 22, 3)),     # frintz h22,h3
        Insn("raw", _fp_h1(0x1EE64000, 23, 3)),     # frinta h23,h3
        Insn("raw", _fp_h1(0x1EE74000, 24, 3)),     # frintx h24,h3
        Insn("raw", _fp_h1(0x1EE7C000, 25, 3)),     # frinti h25,h3
        # 加载专用 S/D 常量到 V28/V29（H 数据槽不被复用）。
        Insn("raw", _neon_qmem(True, 28, 10, 28)),
        Insn("raw", _neon_qmem(True, 29, 10, 29)),
        # ---- 标量 S/D sqrt/minmax/rint ----
        Insn("raw", _fp_sd1(0x1E21C000, 26, 28, False)),  # fsqrt s26,s28
        Insn("raw", _fp_sd1(0x1E61C000, 27, 29, True)),   # fsqrt d27,d29
        Insn("raw", _fp_sd3(0x1E204800, 28, 28, 28, False)),  # fmax s28
        Insn("raw", _fp_sd3(0x1E605800, 29, 29, 29, True)),   # fmin d29
        Insn("raw", _fp_sd1(0x1E25C000, 30, 28, False)),  # frintz s30,s28
        Insn("raw", _fp_sd1(0x1E644000, 31, 29, True)),   # frintn d31,d29
        # ---- 向量 4H/8H ----
        Insn("raw", _neon_v3(0x0E401400, 2, 0, 1, False)),   # fadd v2.4h
        Insn("raw", _neon_v3(0x0EC01400, 3, 1, 0, False)),   # fsub v3.4h
        Insn("raw", _neon_v3(0x2E401C00, 4, 0, 1, False)),   # fmul v4.4h
        Insn("raw", _neon_v3(0x0E402400, 5, 0, 1, False)),   # fcmeq v5.4h
        Insn("raw", _neon_v3(0x0E401400, 6, 0, 1, True)),    # fadd v6.8h
        Insn("raw", _neon_v3(0x0E402400, 7, 0, 1, True)),    # fcmeq v7.8h
        # ---- 向量 2S/4S/2D sqrt/minmax/rint ----
        Insn("raw", _neon_v2(0x2EA1F800, 8, 28, False)),   # fsqrt v8.2s
        Insn("raw", _neon_v3(0x0E20F400, 9, 28, 28, False)),  # fmax v9.2s
        Insn("raw", _neon_v3(0x0EA0F400, 10, 28, 28, False)), # fmin v10.2s
        Insn("raw", _neon_v2(0x2EE1F800, 11, 29, True)),     # fsqrt v11.2d
        Insn("raw", _neon_v3(0x0E60F400, 12, 29, 29, True)),  # fmax v12.2d
        Insn("raw", _neon_v3(0x0EE0F400, 13, 29, 29, True)),  # fmin v13.2d
        Insn("raw", _neon_v3(0x0E20C400, 14, 28, 28, True)),  # fmaxnm v14.4s
        Insn("raw", _neon_v3(0x0EE0C400, 15, 29, 29, True)),  # fminnm v15.2d
        Insn("raw", _neon_v2(0x0EA19800, 16, 28, False)),    # frintz v16.2s
        Insn("raw", _neon_v2(0x2EA19800, 17, 28, True)),     # frinti v17.4s
        Insn("raw", _neon_v2(0x0EE19800, 18, 29, True)),     # frintz v18.2d
        Insn("raw", _neon_v2(0x2EE19800, 19, 29, True)),     # frinti v19.2d
        # ---- FZ16：subnormal 输入/输出 flush，不置 IDC ----
        Insn("raw", _fp_h3(0x1EE02800, 20, 6, 6)),   # fadd h20,h6,h6（FZ16=0）
        Insn("movz", 11, 0x8, 1),
        Insn("raw", 0xD51B440B),                     # MSR FPCR,X11（FZ16=bit19）
        Insn("raw", _fp_h3(0x1EE02800, 21, 6, 6)),   # FZ16 flush -> +0
        Insn("raw", _neon_v3(0x0E401400, 22, 6, 6, False)),  # 4H FZ16 add
        # ---- AHP：FCVT H<->S 的 NaN/Inf 特殊规则 ----
        Insn("movz", 11, 0x408, 1),
        Insn("raw", 0xD51B440B),                     # MSR FPCR,X11（FZ16|AHP）
        Insn("raw", _fp_fcvt(23, 7, 0, 0b000111)),   # fcvt h23,s7（1.0）
        Insn("raw", _fp_fcvt(24, 7, 3, 0b000100)),   # fcvt s24,h7（1.0）
        Insn("movz", 11, 0),
        Insn("raw", 0xD51B440B),                     # 恢复 FPCR=0
        # ---- 四种 RMode：H 1.5+1.5 ----
        Insn("raw", _fp_h3(0x1EE02800, 26, 3, 3)),   # RN：3.0
        Insn("movz", 11, 0x40, 1),
        Insn("raw", 0xD51B440B),                     # RP
        Insn("raw", _fp_h3(0x1EE02800, 27, 3, 3)),
        Insn("movz", 11, 0x80, 1),
        Insn("raw", 0xD51B440B),                     # RM
        Insn("raw", _fp_h3(0x1EE02800, 28, 3, 3)),
        Insn("movz", 11, 0xC0, 1),
        Insn("raw", 0xD51B440B),                     # RZ
        Insn("raw", _fp_h3(0x1EE02800, 29, 3, 3)),
        Insn("movz", 11, 0),
        Insn("raw", 0xD51B440B),
        # ---- FPEN=00：H 指令 trap ----
        Insn("movz", 3, 0x4400, 1),
        Insn("movk", 3, 0x2000),
        Insn("msr_sys", "vbar_el1", 3),
        Insn("msr_sys", "cpacr_el1", 31),
        Insn("raw", 0xD5033FDF),
        Insn("raw", _fp_h3(0x1EE02800, 30, 0, 1)),   # trap
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),
        # ---- UDEF（QEMU 与 RTL 两侧均未定义）：esz=10 one-source/
        # three-same、D.2 转换 Q=0 ----
        Insn("raw", 0x1EA1C000),                     # fsqrt esz=10
        Insn("raw", 0x1EA02800),                     # fadd esz=10
        Insn("raw", 0x0EE1B800),                     # fcvtzs v0.2d, Q=0
        Insn("raw", 0x14000000),                     # b .
    ]
    main = assemble(items, BASE)
    vec = {
        0: (_P75_H_LO, _P75_H_HI),
        1: (_P75_H2_LO, _P75_H2_HI),
        2: (0x4400440044004400, 0x4400440044004400),   # 4.0 x8 H
        3: (0x3E003E003E003E00, 0x3E003E003E003E00),   # 1.5 x8 H
        4: (0x400000003FC00000, 0x4100000040800000),   # 2S/4S {1.5,2,4,8}
        5: (0x4000000000000000, 0x4010000000000000),   # 2D {2,4}
        6: (0x0001000100010001, 0x0001000100010001),   # min-sub x8 H
        7: (0x3F8000003F800000, 0x3F8000003F800000),   # 1.0 x4 S（AHP 用）
        28: (0x400000003FC00000, 0x4100000040800000),  # 2S/4S {1.5,2,4,8}
        29: (0x4000000000000000, 0x4010000000000000),  # 2D {2,4}
    }
    _p75_write_image(path, main, _p75_skip_handler(), vec)
    return len(main) + 4


def build_hard_p7_5_fp16_sqrt_minmax_round_edge_program(path):
    """P7-5 边界：NaN payload/quieting、signed zero min/max、sqrt 负输入、
    FZ16 flush、FCVT NaN/AHP 映射与 subnormal 精确转换。"""
    data_base = 0x1000
    items = [
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
    ]
    for i in range(19):
        items.append(Insn("raw", _neon_qmem(True, i, 10, i)))
    items += [
        # H NaN：qNaN+qNaN（A 优先）、sNaN quiet+IOC、DN default。
        Insn("raw", _fp_h3(0x1EE02800, 16, 0, 1)),    # qNaN + qNaN
        Insn("raw", _fp_h3(0x1EE02800, 17, 2, 1)),    # sNaN + qNaN
        Insn("movz", 11, 0x200, 1),
        Insn("raw", 0xD51B440B),                       # DN
        Insn("raw", _fp_h3(0x1EE02800, 18, 0, 1)),    # DN -> default NaN
        Insn("movz", 11, 0),
        Insn("raw", 0xD51B440B),
        # H min/max signed zero 与 NaN。
        Insn("raw", _fp_h3(0x1EE04800, 19, 3, 4)),    # fmax(+0,-0)=+0
        Insn("raw", _fp_h3(0x1EE05800, 20, 3, 4)),    # fmin(+0,-0)=-0
        Insn("raw", _fp_h3(0x1EE04800, 21, 3, 5)),    # fmax(+0,+Inf)=+Inf
        Insn("raw", _fp_h3(0x1EE04800, 22, 0, 1)),    # fmax(qNaN,qNaN)
        Insn("raw", _fp_h3(0x1EE06800, 23, 0, 3)),    # fmaxnm(qNaN,+0)=+0
        Insn("raw", _fp_h3(0x1EE07800, 24, 2, 3)),    # fminnm(sNaN,+0) IOC
        # sqrt：-1 -> default NaN+IOC；-0 -> -0；+Inf；subnormal FZ16。
        Insn("raw", _fp_h1(0x1EE1C000, 25, 8)),       # fsqrt h25,h8（-1）
        Insn("raw", _fp_h1(0x1EE1C000, 26, 9)),       # fsqrt h26,h9（-0）
        Insn("raw", _fp_h1(0x1EE1C000, 27, 6)),       # fsqrt h27,h6（+Inf）
        Insn("movz", 11, 0x8, 1),
        Insn("raw", 0xD51B440B),                       # FZ16
        Insn("raw", _fp_h1(0x1EE1C000, 28, 10)),      # sub -> 0（无 IDC）
        # FCVT NaN payload：S qNaN -> H、D qNaN -> H、H qNaN -> S/D。
        Insn("movz", 11, 0),
        Insn("raw", 0xD51B440B),
        Insn("raw", _fp_fcvt(29, 11, 0, 0b000111)),   # fcvt h29,s11
        Insn("raw", _fp_fcvt(30, 12, 1, 0b000111)),   # fcvt h30,d12
        Insn("raw", _fp_fcvt(31, 13, 3, 0b000100)),   # fcvt s31,h13
        Insn("raw", _fp_fcvt(0, 13, 3, 0b000101)),    # fcvt d0,h13
        # FCVT subnormal：H sub -> S 精确；S sub -> H 精确。
        Insn("raw", _fp_fcvt(1, 14, 3, 0b000100)),    # fcvt s1,h14
        Insn("raw", _fp_fcvt(2, 15, 0, 0b000111)),    # fcvt h2,s15
        # AHP：S +Inf -> H max normal + IOC；S qNaN -> H +0 + IOC；
        # H 0x7C00 -> S 65536.0。
        Insn("movz", 11, 0x400, 1),
        Insn("raw", 0xD51B440B),                       # AHP
        Insn("raw", _fp_fcvt(3, 16, 0, 0b000111)),    # fcvt h3,s16（+Inf）
        Insn("raw", _fp_fcvt(4, 17, 0, 0b000111)),    # fcvt h4,s17（qNaN）
        Insn("raw", _fp_fcvt(5, 18, 3, 0b000100)),    # fcvt s5,h18（0x7C00）
        Insn("movz", 11, 0),
        Insn("raw", 0xD51B440B),
        Insn("raw", 0x14000000),
    ]
    main = assemble(items, BASE)

    def hvec(*vals):
        lo = 0
        hi = 0
        for i, v in enumerate(vals):
            if i < 4:
                lo |= (v & 0xFFFF) << (16 * i)
            else:
                hi |= (v & 0xFFFF) << (16 * (i - 4))
        return (lo, hi)
    vec = {
        0: hvec(0x7E00, 0x7E01, 0x7E02, 0x7E03, 0x7E04, 0x7E05, 0x7E06, 0x7E07),
        1: hvec(0x7E10, 0x7E11, 0x7E12, 0x7E13, 0x7E14, 0x7E15, 0x7E16, 0x7E17),
        2: hvec(0x7C01, 0x7C01, 0x7C01, 0x7C01, 0x7C01, 0x7C01, 0x7C01, 0x7C01),
        3: hvec(0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000),
        4: hvec(0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000),
        5: hvec(0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00),
        6: hvec(0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00),
        7: hvec(0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00, 0x7C00),
        8: hvec(0xBC00, 0xBC00, 0xBC00, 0xBC00, 0xBC00, 0xBC00, 0xBC00, 0xBC00),
        9: hvec(0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000),
        10: hvec(0x0001, 0x0001, 0x0001, 0x0001,
                 0x0001, 0x0001, 0x0001, 0x0001),
        11: (0x7FC12345, 0),        # S qNaN
        12: (0, 0x7FF8123456789ABC),  # D qNaN
        13: (0x7E12, 0),             # H qNaN
        14: (0x0001, 0),          # H min sub
        15: (0x00000001, 0),      # S min sub
        16: (0x7F800000, 0),         # S +Inf
        17: (0x7FC00000, 0),         # S qNaN
        18: (0x7C00, 0),   # H +Inf pattern（AHP 解释）
    }
    _p75_write_image(path, main, None, vec)
    return len(main)


def build_hard_p7_5_fp16_sqrt_minmax_round_rounding_program(path):
    """四种 RMode 下 H/S/D 的 rounding 对照（add、sqrt、frint）。"""
    data_base = 0x1000
    items = [
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, data_base),
        Insn("raw", _neon_qmem(True, 0, 10, 0)),
        Insn("raw", _neon_qmem(True, 1, 10, 1)),
        Insn("raw", _neon_qmem(True, 2, 10, 2)),
        Insn("raw", _neon_qmem(True, 3, 10, 3)),
        Insn("raw", _neon_qmem(True, 4, 10, 4)),
        Insn("raw", _neon_qmem(True, 5, 10, 5)),
    ]
    # 每轮：H add 1.0+2^-11（RN/RM/RZ -> 1.0，RP -> 1+2^-10）、
    # H frint 1.5（RN/P/A -> 2，M/Z -> 1）、S sqrt(2)、D frint 2.5。
    for rmode in (0x0, 0x40, 0x80, 0xC0):
        items += [
            Insn("movz", 11, rmode, 1),
            Insn("raw", 0xD51B440B),
            Insn("raw", _fp_h3(0x1EE02800, 8, 0, 1)),
            Insn("raw", _fp_h1(0x1EE7C000, 9, 2)),
            Insn("raw", _fp_sd1(0x1E21C000, 10, 3, False)),
            Insn("raw", _fp_sd1(0x1E67C000, 11, 4, True)),
        ]
    # FRINTI 不置 IXC，FRINTX 置 IXC（RMode=RN）。
    items += [
        Insn("movz", 11, 0, 1),
        Insn("raw", 0xD51B440B),
        Insn("raw", _fp_h1(0x1EE7C000, 12, 2)),   # frinti h12,h2
        Insn("raw", _fp_h1(0x1EE74000, 13, 2)),   # frintx h13,h2
        Insn("raw", 0x14000000),
    ]
    main = assemble(items, BASE)
    # h0=1.0 x8、h1=2^-11 x8（0x3001）、h2=1.5 x8、S 2.0 x4、D 2.5 x2。
    vec = {
        0: (0x3C003C003C003C00, 0x3C003C003C003C00),
        1: (0x3001300130013001, 0x3001300130013001),
        2: (0x3E003E003E003E00, 0x3E003E003E003E00),
        3: (0x4000000040000000, 0x4000000040000000),   # 2.0 x4 S
        4: (0x4004000000000000, 0x4004000000000000),   # 2.5 x2 D
        5: (0, 0),
    }
    _p75_write_image(path, main, None, vec)
    return len(main)


def build_hard_p7_5_fp16_sqrt_minmax_round_sequence_program(
        path, seed=1, rounds=6):
    """确定性 H/S 背靠背压力序列（forwarding + sticky）。"""
    if rounds <= 0:
        raise ValueError("rounds must be positive")
    items = [
        Insn("movz", 0, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 0),
        Insn("raw", 0xD5033FDF),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, 0x1000),
    ]
    for i in range(6):
        items.append(Insn("raw", _neon_qmem(True, i, 10, i)))
    for i in range(rounds):
        # 每轮用固定 H 数据槽做背靠背 add/mul/sub/frint，并交替 S/D
        # sqrt/frint，覆盖 V 前递与 FPSR sticky 累积。
        items += [
            Insn("raw", _fp_h3(0x1EE02800, 0, 0, 1)),     # fadd h0,h0,h1
            Insn("raw", _fp_h3(0x1EE00800, 1, 0, 2)),     # fmul h1,h0,h2
            Insn("raw", _fp_h3(0x1EE03800, 2, 1, 0)),     # fsub h2,h1,h0
            Insn("raw", _fp_h1(0x1EE5C000, 3, 2)),        # frintz h3,h2
            Insn("raw", _fp_h1(0x1EE1C000, 4, 3)),        # fsqrt h4,h3
            Insn("raw", _fp_sd1(0x1E21C000, 5, 3, False)),  # fsqrt s5,s3
            Insn("raw", _fp_sd1(0x1E644000, 6, 4, True)),   # frintn d6,d4
            Insn("raw", _neon_v3(0x0E401400, 7, 0, 1, False)),  # fadd v7.4h
            Insn("raw", _neon_v2(0x2EA1F800, 8, 3, False)),     # fsqrt v8.2s
        ]
    items.append(Insn("raw", 0x14000000))
    main = assemble(items, BASE)
    vec = {
        0: (0x3C003C003C003C00, 0x3C003C003C003C00),   # 1.0 x8 H
        1: (0x4000400040004000, 0x4000400040004000),   # 2.0 x8 H
        2: (0x3E003E003E003E00, 0x3E003E003E003E00),   # 1.5 x8 H
        3: (0x400000003FC00000, 0x4100000040800000),   # 2S/4S {1.5,2,4,8}
        4: (0x4000000000000000, 0x4010000000000000),   # 2D {2,4}
        5: (0x0001000100010001, 0x0001000100010001),   # min-sub x8 H
    }
    _p75_write_image(path, main, None, vec)
    return len(main)


def build_hard_neon_fetch_fault_program(path):
    """Place STR Q at an identity-mapped page end and fault the next fetch.

    The Q store is at VA/PA 0x44000ffc; its destination page is EL1-RW and
    VA 0x44001000 is deliberately unmapped. This exercises the older STR Q
    commit plus the following IABT merge in one lockstep window, including
    both mem and mem2 store records.
    """
    def b_abs(pc, target):
        return 0x14000000 | (((target - pc) >> 2) & 0x3FFFFFF)

    main = assemble([
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x100010),
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, 0x2000),
        # Advanced SIMD is trapped while CPACR_EL1.FPEN==00.  Set FPEN=11
        # and execute an ISB before the first NEON instruction so this image
        # reaches the intended page-end fetch fault instead of the older
        # false-green EC=0x07 trap at the MOVI.
        Insn("movz", 5, 0x30, 1),
        Insn("msr_sys", "cpacr_el1", 5),
        Insn("raw", 0xD5033FDF),                 # ISB sy
        Insn("raw", _neon_movi(0, 0xA5)),
        Insn("movz", 5, 0xc5, 1),
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        # The FPEN/ISB prologue moves the branch to 0x44000044.  Keep the
        # source PC explicit so inserting another setup instruction cannot
        # silently retarget the absolute page-end branch.
        Insn("raw", b_abs(BASE + 0x44, 0x44000ffc)),
    ], BASE)
    q_store = _neon_qmem(False, 0, 10)
    handler = assemble([
        Insn("movz", 1, 0x55),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], 0x44010200)

    image = bytearray(0x16000)
    image[:len(build_bytes(main))] = build_bytes(main)
    image[0x0ffc:0x1000] = struct.pack("<I", q_store)
    for i, word in enumerate(handler):
        off = 0x10000 + 0x200 + i * 4
        image[off:off + 4] = struct.pack("<I", word)
    image[0x2000:0x2008] = struct.pack("<Q", 0x1122334455667788)
    image[0x2008:0x2010] = struct.pack("<Q", 0x99AABBCCDDEEFF00)

    def put64(off, value):
        image[off:off + 8] = struct.pack("<Q", value)

    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 32 * 8, 0x44014003)
    put64(0x14000 + 0 * 8, 0x440004C3)       # code page
    # [1] intentionally absent: next fetch 0x44001000 must IABT.
    # AP[7:6]=00 keeps the Q-store destination writable at EL1.  0x440024C3
    # would encode AP=11 (read-only) and turn the intended STR Q + following
    # IABT into an earlier EC=0x25 DABT at 0x44002000.
    put64(0x14000 + 2 * 8, 0x44002403)       # Q store data page, EL1 RW
    put64(0x14000 + 0x10 * 8, 0x440104C3)    # VBAR/handler page
    Path(path).write_bytes(image)
    return BASE


# ---- PE-F1a：fetch FIFO/epoch 定向镜像（实现与验证骨架） ----
def _f1a_branch_words():
    """Taken branch with two deliberately wrong-path instructions."""
    return assemble([
        Insn("movz", 0, 1),
        Insn("b", "target"),
        Insn("movz", 1, 0xdead),
        Insn("movz", 2, 0xbeef),
        Insn("label", "target"),
        Insn("movz", 3, 3),
        Insn("b", "target"),
    ], BASE)


def build_hard_fetch_epoch_program(path):
    """Taken-branch image for local epoch bump and stale response drop."""
    Path(path).write_bytes(build_bytes(_f1a_branch_words()))
    return BASE


def _f1a_duplicate_words():
    """Minimal load/ALU/load sequence that exercises the F1a WB hold.

    The second load can remain pending while the preceding ALU instruction is
    already visible in MEM/WB.  The image is intentionally self-contained and
    loops after the directed window so both QEMU and RTL can be stopped at a
    fixed retirement count.
    """
    return assemble([
        Insn("movz", 0, 0x4400, 1),  # x0 = 0x44000000
        Insn("movk", 0, 0x1000),     # x0 = 0x44001000
        Insn("movz", 1, 0x4400, 1),  # x1 = 0x44000000
        Insn("movk", 1, 0x2000),     # x1 = 0x44002000
        Insn("ldr", 2, 0, 0),        # older load
        Insn("add", 3, 1, 0),        # MEM/WB candidate while next load waits
        Insn("ldr", 4, 1, 0),        # younger load holds EX/MEM
        Insn("add", 5, 2, 3),
        Insn("b", "loop"),
        label("loop"),
        Insn("b", "loop"),
    ], BASE)


def build_hard_fetch_duplicate_program(path):
    """Directed F1a image for duplicate-retirement regression."""
    words = _f1a_duplicate_words()
    Path(path).write_bytes(build_bytes(words))
    return BASE


def _f1a_ready_hold_words():
    """Sequential frontend window used by the commit-ready hold regression.

    The multiply keeps the older pipeline occupied long enough for the
    two-entry fetch FIFO to fill behind a valid IF/ID entry.  The trailing
    branch loop keeps the image alive for both randomized backpressure and
    short strict-lockstep runs without introducing memory effects.
    """
    return assemble([
        Insn("movz", 0, 3),
        Insn("movz", 1, 4),
        Insn("mul", 2, 0, 1),
        Insn("movz", 3, 0x11),
        Insn("movz", 4, 0x22),
        Insn("movz", 5, 0x33),
        Insn("movz", 6, 0x44),
        Insn("movz", 7, 0x55),
        Insn("movz", 8, 0x66),
        Insn("movz", 9, 0x77),
        # The runner's normal completion protocol is a committed store to
        # the shared magic address; this keeps the off/on trace comparable.
        Insn("movz", 10, 0x4400, 1),
        Insn("movk", 10, 0xfe00),
        Insn("movz", 11, 0),
        Insn("str", 11, 10, 0),
        Insn("b", "ready_loop"),
        label("ready_loop"),
        Insn("b", "ready_loop"),
    ], BASE)


def build_hard_fetch_ready_hold_program(path):
    """Directed F1a image for commit_ready/IFID hold regression."""
    Path(path).write_bytes(build_bytes(_f1a_ready_hold_words()))
    return BASE


def build_hard_fetch_line_program(path):
    """Fetch a word at offset 0x3c and continue across a 64-byte line."""
    main = assemble([
        Insn("movz", 0, 0x4400, 1),
        Insn("movk", 0, 0x3c),
        Insn("br", 0),
    ], BASE)
    image = bytearray(0x100)
    image[:len(build_bytes(main))] = build_bytes(main)
    line = assemble([
        Insn("movz", 1, 0x11),
        Insn("movz", 2, 0x22),
        Insn("b", "line_loop"),
        Insn("label", "line_loop"),
        Insn("b", "line_loop"),
    ], BASE + 0x3c)
    for i, word in enumerate(line):
        off = 0x3c + i * 4
        if off + 4 <= len(image):
            image[off:off + 4] = struct.pack("<I", word)
    Path(path).write_bytes(image)
    return BASE


def build_hard_fetch_4k_program(path):
    """Fetch the final word of one 4 KiB page and the first word of the next."""
    main = assemble([
        Insn("movz", 0, 0x4400, 1),
        Insn("movk", 0, 0xffc),
        Insn("br", 0),
    ], BASE)
    image = bytearray(0x1010)
    image[:len(build_bytes(main))] = build_bytes(main)
    tail = assemble([
        Insn("movz", 1, 0x4),
        Insn("b", "page_loop"),
        Insn("label", "page_loop"),
        Insn("b", "page_loop"),
    ], BASE + 0xffc)
    for i, word in enumerate(tail):
        off = 0xffc + i * 4
        if off + 4 <= len(image):
            image[off:off + 4] = struct.pack("<I", word)
    Path(path).write_bytes(image)
    return BASE


def build_hard_fetch_reset_program(path):
    """Small deterministic image used by reset/in-flight response reruns."""
    words = assemble([
        Insn("movz", 0, 0x55),
        Insn("movz", 1, 0xaa),
        Insn("b", "reset_loop"),
        Insn("label", "reset_loop"),
        Insn("b", "reset_loop"),
    ], BASE)
    Path(path).write_bytes(build_bytes(words))
    return BASE


def build_bytes(words):
    return struct.pack(f"<{len(words)}I", *words)
