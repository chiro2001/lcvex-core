"""固定种子随机标量程序生成（D0/D1 随机回归，Q4 里程碑）。

约束：
- 只用 RTL 已支持指令（见 docs/ISA_SCOPE.md 实现状态）。
- 分支只向前、目标必须是程序内指令边界：QEMU 与 RTL 的动态指令流
  完全一致，trace 行数与 RTL 提交数可严格对齐。
- 程序末尾追加自循环 `b .`，两条路径（QEMU/RTL）都会持续提交，
  trace 截断行数 = 程序长度，两边前 N 条提交必然一一对应。
- 访存基址固定 x20 = 0x44000000，imm12 偏移按访问宽度天然对齐，
  避免 QEMU 复位状态下非对齐访问对齐异常。
"""

import random

from a64 import Insn, label

CONDITIONS = ["eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc",
              "hi", "ls", "ge", "lt", "gt", "le"]

# 分支/地址指令的目标参数位置
TARGET_POS = {"b": 0, "bl": 0, "b_cond": 1, "cbz": 1, "cbnz": 1,
              "tbz": 2, "tbnz": 2, "adr": 1, "adrp": 1}


class _Fwd:
    """前向目标占位：最终解析为标签名。"""

    def __init__(self, idx):
        self.idx = idx


def gen_program(rng, length, data_base=0x44080000):
    # 数据区必须避开程序区，防止随机 STR 覆盖指令（早期禁用自修改代码）
    insns = []

    def reg():
        return rng.randrange(0, 8)

    def fwd(cur):
        return _Fwd(min(cur + rng.randint(1, 10), length - 1))

    # 初始化段：给 x0..x7 写随机值，x20 = 数据基址
    for rd in range(8):
        kind = rng.choice(("movz", "movk", "movn", "movz_w", "movn_w"))
        hw = rng.randrange(2) if kind.endswith("_w") else rng.randrange(4)
        insns.append(Insn(kind, rd, rng.randrange(0x10000), hw))
    insns.append(Insn("movz", 20, (data_base >> 16) & 0xFFFF, 1))
    # pre/post pair（x21/x22）与 exclusive（x24）专用基址恒为数据基址：
    # 即使分支跳过序列开头的 movz，残留值也在数据区内且对齐，DUT/QEMU
    # 以相同 pre-state 执行必然一致（x23 由 reg_offset 带约束保持 0..7，
    # 不能在此初始化）。
    insns.append(Insn("movz", 21, (data_base >> 16) & 0xFFFF, 1))
    insns.append(Insn("movz", 22, (data_base >> 16) & 0xFFFF, 1))
    insns.append(Insn("movz", 24, (data_base >> 16) & 0xFFFF, 1))

    alu64 = ["add", "sub", "adds", "subs"]
    alu32 = ["add_w", "sub_w", "adds_w", "subs_w"]
    logic64 = ["and", "orr", "eor", "ands", "bic", "bics", "orn", "eon"]
    logic32 = ["and_w", "orr_w", "eor_w", "ands_w",
               "bic_w", "bics_w", "orn_w", "eon_w"]
    muldiv = ["mul", "udiv", "sdiv", "mul_w", "udiv_w", "sdiv_w",
              "umulh", "smulh"]
    movs = ["movz", "movk", "movn", "movz_w", "movk_w", "movn_w"]
    ldst = ["ldr", "str", "ldrw", "strw", "ldrh", "strh",
            "ldrb", "strb", "ldrsw"]
    csel = ["csel", "csinc", "csinv", "csneg",
            "csel_w", "csinc_w", "csinv_w", "csneg_w"]
    madd = ["madd", "msub", "madd_w", "msub_w",
            "smaddl", "smsubl", "umaddl", "umsubl"]
    pair_w = ("x", "w")
    reg_ldst = [
        ("ldr_reg", 3), ("str_reg", 3), ("ldrw_reg", 2), ("strw_reg", 2),
        ("ldrh_reg", 1), ("strh_reg", 1), ("ldrb_reg", 0), ("strb_reg", 0),
        ("ldrsw_reg", 2), ("ldrsb_reg", 0), ("ldrsb_x_reg", 0),
        ("ldrsh_reg", 1), ("ldrsh_x_reg", 1),
    ]
    ext_ops = ["add_ext", "sub_ext", "add_ext_w", "sub_ext_w"]

    while len(insns) < length:
        op = rng.random()
        if op < 0.14:
            name = rng.choice(alu64 + alu32)
            rd = rng.choice([reg(), 31])  # 偶尔写 XZR / SP
            rn = rng.choice([reg(), 31])
            insns.append(Insn(name, rd, rn, rng.randrange(0x1000)))
        elif op < 0.23:
            name = rng.choice(logic64 + logic32)
            amt = rng.randrange(64)
            if name.endswith("_w"):
                amt = rng.randrange(32)  # W 形式移位必须 < 32
            insns.append(Insn(name, reg(), reg(), reg(),
                              rng.randrange(3), amt))
        elif op < 0.31:
            name = rng.choice(movs)
            hw = rng.randrange(2) if name.endswith("_w") else rng.randrange(4)
            insns.append(Insn(name, reg(), rng.randrange(0x10000), hw))
        elif op < 0.35:
            insns.append(Insn(rng.choice(muldiv), reg(), reg(), reg()))
        elif op < 0.45:
            name = rng.choice(ldst)
            insns.append(Insn(name, reg(), 20, rng.randrange(0x1000)))
        elif op < 0.55:
            insns.append(Insn("b_cond", rng.choice(CONDITIONS),
                              fwd(len(insns))))
        elif op < 0.62:
            name = rng.choice(("cbz", "cbnz"))
            insns.append(Insn(name, reg(), fwd(len(insns))))
        elif op < 0.69:
            name = rng.choice(("tbz", "tbnz"))
            insns.append(Insn(name, reg(), rng.randrange(64),
                              fwd(len(insns))))
        elif op < 0.72:
            insns.append(Insn("b", fwd(len(insns))))
        elif op < 0.75:
            name = rng.choice(("adr", "adrp"))
            insns.append(Insn(name, reg(), fwd(len(insns))))
        elif op < 0.81:
            # CSEL 族：条件两分支取值，覆盖 NZCV 依赖（与 B.cond 同机制）
            insns.append(Insn(rng.choice(csel), reg(), reg(), reg(),
                              rng.choice(CONDITIONS)))
        elif op < 0.84:
            # P6：REV/REV16/REV32/CLZ/CLS（W/X）
            insns.append(Insn(rng.choice(
                ("rbit", "rbit_w", "rev", "rev_w", "rev16", "rev16_w", "rev32",
                 "clz", "clz_w", "cls", "cls_w")), reg(), reg()))
        elif op < 0.87:
            # P6：CCMP/CCMN（立即数/寄存器，W/X，随机条件与 NZCV 立即数）
            w = rng.random() < 0.5
            suffix = "_w" if w else ""
            kind = rng.choice(("ccmp", "ccmn"))
            nzcv = rng.randrange(16)
            cond = rng.choice(CONDITIONS)
            if rng.random() < 0.5:
                insns.append(Insn(kind + suffix, reg(), rng.randrange(32),
                                  nzcv, cond))
            else:
                insns.append(Insn(kind + "_reg" + suffix, reg(), reg(),
                                  nzcv, cond))
        elif op < 0.88:
            insns.append(Insn("bti", rng.choice(("c", "j", "jc"))))
        elif op < 0.89:
            # DAIFSet/DAIFClr：随机程序无异常，DAIF 变化不影响提交比较
            insns.append(Insn(rng.choice(("daifset", "daifclr")),
                              rng.randrange(16)))
        elif op < 0.92:
            # BFM/BFI/BFXIL：合法 lsb/width（X/W）
            w32 = rng.random() < 0.5
            bits = 32 if w32 else 64
            lsb = rng.randrange(bits)
            width = rng.randrange(1, bits - lsb + 1)
            kind = rng.choice(("bfi", "bfxil", "bfm", "sbfm", "ubfm"))
            if kind in ("bfm", "sbfm", "ubfm"):
                # 原始位域指令：immr 独立取值；UBFM X 形式 imms=31 是
                # 保留编码（uxtw 别名走 ORR），故 imms 上限收窄到 30。
                name = kind + ("_w" if w32 else "")
                imms_max = 30 if (kind == "ubfm" and not w32) else bits - 1
                insns.append(Insn(name, reg(), reg(), rng.randrange(bits),
                                  rng.randrange(imms_max + 1)))
            else:
                name = kind + ("_w" if w32 else "")
                insns.append(Insn(name, reg(), reg(), lsb, width))
        elif op < 0.94:
            # MADD/MSUB/SMADDL/SMSUBL/UMADDL/UMSUBL（含 W 形式）
            insns.append(Insn(rng.choice(madd), reg(), reg(), reg(), reg()))
        elif op < 0.96:
            # exclusive 对：LDXR/LDAXR -> STXR/STLXR 同地址同大小（通过），
            # 或直接 STXR（监视器无效 -> 失败不写）、LDXR->CLREX->STXR
            # （失败）。专用基址 x24 每对重置；不生成“LDXR->STR 改值->
            # STXR”序列（值不匹配失败且 rs=31 时插件无法丢弃幻影 store，
            # 该组合留给定向测试）。
            sz = rng.choice((0, 1, 2, 3))
            names = {
                0: ("ldxrb", "stxrb", "ldaxrb", "stlxrb"),
                1: ("ldxrh", "stxrh", "ldaxrh", "stlxrh"),
                2: ("ldxr_w", "stxr_w", "ldaxr_w", "stlxr_w"),
                3: ("ldxr", "stxr", "ldaxr", "stlxr"),
            }
            l, s, la, sla = names[sz]
            r = rng.random()
            if r < 0.2:
                insns.append(Insn("movz", 24,
                                  (data_base >> 16) & 0xFFFF, 1))
                insns.append(Insn(s, reg(), reg(), 24))
            elif r < 0.3:
                insns.append(Insn("movz", 24,
                                  (data_base >> 16) & 0xFFFF, 1))
                insns.append(Insn(rng.choice((l, la)), reg(), 24))
                insns.append(Insn("clrex"))
                insns.append(Insn(s, reg(), reg(), 24))
            else:
                off = rng.randrange(0, 128) << sz
                addr = data_base + off
                insns.append(Insn("movz", 24, (addr >> 16) & 0xFFFF, 1))
                insns.append(Insn("movk", 24, addr & 0xFFFF))
                insns.append(Insn(rng.choice((l, la)), reg(), 24))
                insns.append(Insn(rng.choice((s, sla)), reg(), reg(), 24))
                insns.append(Insn("movz", 24,
                                  (data_base >> 16) & 0xFFFF, 1))
        elif op < 0.975:
            # LDP/STP：offset/pre/post，X/W 对；基址 x20（数据区），
            # rt/rt2 与基址不同（写回不可预测），偏移按 scale 对齐。
            # offset 模式用 x20（不动基址）；pre/post 写回用专用基址
            # x21（X 对）/ x22（W 对），每次执行前重置为数据基址，
            # 避免 4 对齐漂移破坏 x20 的 8 字节对齐。
            w = rng.choice(pair_w)
            scale = 8 if w == "x" else 4
            off = rng.randrange(-64, 64) * scale  # imm7 ∈ [-64, 63]
            mode = rng.choice(("offset", "pre", "post"))
            rt = reg()
            rt2 = reg()
            while rt2 == rt:
                rt2 = reg()
            base = 20
            if mode != "offset":
                base = 21 if w == "x" else 22
                insns.append(Insn("movz", base, (data_base >> 16) & 0xFFFF, 1))
            name = ("stp" if rng.random() < 0.5 else "ldp") + \
                ("" if w == "x" else "_w")
            insns.append(Insn(name, rt, rt2, base, off, mode))
            if mode != "offset":
                # 恢复基址：pre/post 写回会漂移，残留值必须仍在数据区内
                #（分支可能跳过下一次 movz）。
                insns.append(Insn("movz", base,
                                  (data_base >> 16) & 0xFFFF, 1))
        elif op < 0.99:
            # 寄存器偏移 LDR/STR（含 LDRSW/LDRSB/LDRSH W/X）；
            # 非 byte 操作固定 S=1：地址 = x20 + x23 << sz，天然按
            # 宽度对齐且与 x23 具体值无关（分支可能跳过 movz 重置，
            # 不能用 S=0 + 缩放索引值这种依赖寄存器状态的方案）。
            name, sz = rng.choice(reg_ldst)
            sh = 0 if sz == 0 else 1
            insns.append(Insn("movz", 23, rng.randrange(8)))
            insns.append(Insn(name, reg(), 20, 23, sh))
        elif op < 0.995:
            # 扩展寄存器 ADD/SUB：随机 option（0..7），imm3 合法范围 0..4
            insns.append(Insn(rng.choice(ext_ops), reg(), reg(), reg(),
                              rng.randrange(8), rng.randrange(5)))
        else:
            # LDR（literal）：先写数据槽，再 PC 相对读同一地址；偶尔 NOP
            if rng.random() < 0.2:
                insns.append(Insn("nop"))
            else:
                slot = rng.randrange(1, 512)
                addr = data_base + slot * 8
                insns.append(Insn("str", reg(), 20, slot))
                lit = rng.choice(("ldr_lit", "ldr_w_lit", "ldrsw_lit",
                                  "prfm_lit"))
                rt = 31 if lit == "prfm_lit" else reg()
                insns.append(Insn(lit, rt, addr))

    return _finalize(insns)


def _finalize(insns):
    """把前向目标解析为标签：在目标索引处插入 label，分支改用标签名。"""
    targets = set()
    for insn in insns:
        pos = TARGET_POS.get(insn.name)
        if (pos is not None and pos < len(insn.args) and
                isinstance(insn.args[pos], _Fwd)):
            targets.add(insn.args[pos].idx)

    out = []
    for i, insn in enumerate(insns):
        if i in targets:
            out.append(label(f"L{i}"))
        pos = TARGET_POS.get(insn.name)
        if (pos is not None and pos < len(insn.args) and
                isinstance(insn.args[pos], _Fwd)):
            args = list(insn.args)
            args[pos] = f"L{insn.args[pos].idx}"
            insn = Insn(insn.name, *args)
        out.append(insn)
    return out


def with_loop(insns):
    """末尾追加自循环，保证 QEMU/RTL 持续提交且动态流一致。"""
    return insns + [Insn("b", "loop"), label("loop"), Insn("b", "loop")]
