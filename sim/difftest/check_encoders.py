#!/usr/bin/env python3
"""a64.py 编码器与 GNU 交叉汇编器逐字对照自检（M3 新族回归保护）。

用 aarch64-linux-gnu-as 汇编同一批指令，与 sim/difftest/a64.py 的
编码结果逐字比较；覆盖 CSEL 族、BFM/SBFM/UBFM/BFI/BFXIL、MADD 族、
LDP/STP（offset/pre/post）、寄存器偏移 LDR/STR、扩展 ADD/SUB。

用法：
  python3 sim/difftest/check_encoders.py
退出码：全部一致=0；交叉工具链缺失=3（跳过）；不一致=1。
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "sim" / "difftest"))

from a64 import Insn, assemble  # noqa: E402


# (编码器参数构造, 汇编源码行)
CASES = [
    (lambda: Insn("csel", 0, 1, 2, "eq"), "csel x0, x1, x2, eq"),
    (lambda: Insn("csinc_w", 9, 10, 11, "lt"), "csinc w9, w10, w11, lt"),
    (lambda: Insn("csinv", 12, 13, 14, "ls"), "csinv x12, x13, x14, ls"),
    (lambda: Insn("csneg_w", 21, 22, 23, "al"), "csneg w21, w22, w23, al"),
    (lambda: Insn("bfm", 0, 1, 4, 11), "bfm x0, x1, #4, #11"),
    (lambda: Insn("bfm_w", 2, 3, 5, 7), "bfm w2, w3, #5, #7"),
    (lambda: Insn("sbfm", 0, 1, 5, 7), "sbfm x0, x1, #5, #7"),
    (lambda: Insn("ubfm_w", 2, 3, 4, 6), "ubfm w2, w3, #4, #6"),
    (lambda: Insn("bfi", 4, 5, 4, 8), "bfi x4, x5, #4, #8"),
    (lambda: Insn("bfi_w", 6, 7, 16, 16), "bfi w6, w7, #16, #16"),
    (lambda: Insn("bfxil", 8, 9, 4, 8), "bfxil x8, x9, #4, #8"),
    (lambda: Insn("bfxil_w", 10, 11, 4, 8), "bfxil w10, w11, #4, #8"),
    (lambda: Insn("madd", 1, 2, 3, 4), "madd x1, x2, x3, x4"),
    (lambda: Insn("msub_w", 13, 14, 15, 16), "msub w13, w14, w15, w16"),
    (lambda: Insn("smaddl", 17, 18, 19, 20), "smaddl x17, w18, w19, x20"),
    (lambda: Insn("smsubl", 21, 22, 23, 24), "smsubl x21, w22, w23, x24"),
    (lambda: Insn("umaddl", 25, 26, 27, 28), "umaddl x25, w26, w27, x28"),
    (lambda: Insn("umsubl", 0, 1, 2, 3), "umsubl x0, w1, w2, x3"),
    (lambda: Insn("umulh", 4, 5, 6), "umulh x4, x5, x6"),
    (lambda: Insn("stp", 0, 1, 2), "stp x0, x1, [x2]"),
    (lambda: Insn("ldp_w", 12, 13, 14, 4), "ldp w12, w13, [x14, #4]"),
    (lambda: Insn("stp", 5, 6, 4, -16, "pre"), "stp x5, x6, [x4, #-16]!"),
    (lambda: Insn("ldp", 7, 8, 4, 16, "post"), "ldp x7, x8, [x4], #16"),
    (lambda: Insn("str_reg", 1, 2, 0, 1), "str x1, [x2, x0, lsl #3]"),
    (lambda: Insn("ldr_reg", 2, 4, 1, 1), "ldr x2, [x4, x1, lsl #3]"),
    (lambda: Insn("ldrb_reg", 3, 5, 6), "ldrb w3, [x5, x6]"),
    (lambda: Insn("ldrsw_reg", 13, 14, 15, 1), "ldrsw x13, [x14, x15, lsl #2]"),
    (lambda: Insn("ldrsb_reg", 13, 10, 12), "ldrsb w13, [x10, x12]"),
    (lambda: Insn("ldrsh_x_reg", 19, 15, 17), "ldrsh x19, [x15, x17]"),
    (lambda: Insn("add_ext", 1, 2, 0, 2, 3), "add x1, x2, w0, uxtw #3"),
    (lambda: Insn("sub_ext", 3, 4, 5, 6, 2), "sub x3, x4, w5, sxtw #2"),
    (lambda: Insn("add_ext_w", 6, 7, 8, 0, 0), "add w6, w7, w8, uxtb"),
    (lambda: Insn("bic", 0, 1, 2), "bic x0, x1, x2"),
    (lambda: Insn("orn_w", 6, 7, 8, 1, 5), "orn w6, w7, w8, lsr #5"),
    (lambda: Insn("eon", 9, 10, 11), "eon x9, x10, x11"),
    # ---- M3：exclusive 族（LDXR/STXR/CLREX，含 acquire/release）----
    (lambda: Insn("ldxrb", 0, 20), "ldxrb w0, [x20]"),
    (lambda: Insn("ldxrh", 1, 20), "ldxrh w1, [x20]"),
    (lambda: Insn("ldxr_w", 2, 20), "ldxr w2, [x20]"),
    (lambda: Insn("ldxr", 3, 20), "ldxr x3, [x20]"),
    (lambda: Insn("stxrb", 4, 0, 20), "stxrb w4, w0, [x20]"),
    (lambda: Insn("stxrh", 5, 1, 20), "stxrh w5, w1, [x20]"),
    (lambda: Insn("stxr_w", 6, 2, 20), "stxr w6, w2, [x20]"),
    (lambda: Insn("stxr", 7, 3, 20), "stxr w7, x3, [x20]"),
    (lambda: Insn("ldaxrb", 8, 20), "ldaxrb w8, [x20]"),
    (lambda: Insn("ldaxrh", 9, 20), "ldaxrh w9, [x20]"),
    (lambda: Insn("ldaxr_w", 10, 20), "ldaxr w10, [x20]"),
    (lambda: Insn("ldaxr", 11, 20), "ldaxr x11, [x20]"),
    (lambda: Insn("stlxrb", 12, 0, 20), "stlxrb w12, w0, [x20]"),
    (lambda: Insn("stlxrh", 13, 1, 20), "stlxrh w13, w1, [x20]"),
    (lambda: Insn("stlxr_w", 14, 2, 20), "stlxr w14, w2, [x20]"),
    (lambda: Insn("stlxr", 15, 3, 20), "stlxr w15, x3, [x20]"),
    (lambda: Insn("clrex"), "clrex"),
    # ---- P6：REV/CLZ/CLS + CCMP/CCMN + BTI + MSR immediate ----
    (lambda: Insn("rbit", 0, 1), "rbit x0, x1"),
    (lambda: Insn("rbit_w", 2, 3), "rbit w2, w3"),
    (lambda: Insn("rev16", 0, 1), "rev16 x0, x1"),
    (lambda: Insn("rev16_w", 2, 3), "rev16 w2, w3"),
    (lambda: Insn("rev32", 4, 5), "rev32 x4, x5"),
    (lambda: Insn("rev", 6, 7), "rev x6, x7"),
    (lambda: Insn("rev_w", 8, 9), "rev w8, w9"),
    (lambda: Insn("crc32b", 0, 1, 2), "crc32b w0, w1, w2"),
    (lambda: Insn("crc32h", 3, 4, 5), "crc32h w3, w4, w5"),
    (lambda: Insn("crc32w", 6, 7, 8), "crc32w w6, w7, w8"),
    (lambda: Insn("crc32x", 9, 10, 11), "crc32x w9, w10, x11"),
    (lambda: Insn("crc32cb", 12, 13, 14), "crc32cb w12, w13, w14"),
    (lambda: Insn("crc32ch", 15, 16, 17), "crc32ch w15, w16, w17"),
    (lambda: Insn("crc32cw", 18, 19, 20), "crc32cw w18, w19, w20"),
    (lambda: Insn("crc32cx", 21, 22, 23), "crc32cx w21, w22, x23"),
    (lambda: Insn("clz", 10, 11), "clz x10, x11"),
    (lambda: Insn("clz_w", 12, 13), "clz w12, w13"),
    (lambda: Insn("cls", 14, 15), "cls x14, x15"),
    (lambda: Insn("cls_w", 16, 17), "cls w16, w17"),
    (lambda: Insn("ccmp", 0, 1, 0, "eq"), "ccmp x0, #1, #0, eq"),
    (lambda: Insn("ccmp_w", 1, 2, 3, "ne"), "ccmp w1, #2, #3, ne"),
    (lambda: Insn("ccmn", 2, 3, 4, "ge"), "ccmn x2, #3, #4, ge"),
    (lambda: Insn("ccmn_w", 4, 5, 5, "lt"), "ccmn w4, #5, #5, lt"),
    (lambda: Insn("ccmp_reg", 6, 7, 6, "cs"), "ccmp x6, x7, #6, cs"),
    (lambda: Insn("ccmp_reg_w", 8, 9, 7, "eq"), "ccmp w8, w9, #7, eq"),
    (lambda: Insn("ccmn_reg", 10, 11, 8, "hi"), "ccmn x10, x11, #8, hi"),
    (lambda: Insn("bti"), "bti c"),
    (lambda: Insn("bti", "j"), "bti j"),
    (lambda: Insn("bti", "jc"), "bti jc"),
    (lambda: Insn("hvc", 0), "hvc #0"),
    (lambda: Insn("smc", 0), "smc #0"),
    (lambda: Insn("daifset", 1), "msr daifset, #1"),
    (lambda: Insn("daifclr", 8), "msr daifclr, #8"),
    (lambda: Insn("spsel", 1), "msr spsel, #1"),
]


def main():
    as_bin = "aarch64-linux-gnu-as"
    try:
        subprocess.run([as_bin, "--version"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        print("WARN: 缺少 aarch64-linux-gnu-as，编码器对照跳过")
        return 3

    src = ".text\n.arch armv8-a+crc\n" + "\n".join(c[1] for c in CASES) + "\n"
    with tempfile.NamedTemporaryFile("w", suffix=".s", delete=False) as f:
        f.write(src)
        s_path = f.name
    obj_path = s_path[:-2] + ".o"
    try:
        subprocess.run([as_bin, "-o", obj_path, s_path], check=True)
        out = subprocess.run(["aarch64-linux-gnu-objdump", "-d", obj_path],
                             check=True, capture_output=True, text=True).stdout
    finally:
        Path(s_path).unlink(missing_ok=True)
        Path(obj_path).unlink(missing_ok=True)

    expected = [
        int(m.group(1), 16)
        for line in out.splitlines()
        if (m := re.match(r"\s*[0-9a-f]+:\s*([0-9a-f]{8})\s+", line))
    ]
    assert len(expected) == len(CASES), (len(expected), len(CASES))

    got = assemble([case[0]() for case in CASES])
    fails = 0
    for i, (g, e) in enumerate(zip(got, expected)):
        if g != e:
            print(f"MISMATCH [{i}] {CASES[i][1]}: "
                  f"a64=0x{g:08X} as=0x{e:08X}")
            fails += 1
    if fails:
        print(f"FAIL: {fails}/{len(CASES)} 编码器不一致")
        return 1
    print(f"PASS: a64.py 编码器与交叉汇编器一致（{len(CASES)} 条）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
