#!/usr/bin/env python3
"""B25 post/pre-index writeback focused matrix image.

The runner compares every commit and memory side effect against QEMU; this
generator deliberately contains no expected architectural result table.
"""

import argparse
import sys

from a64 import Insn, assemble, label
from test_program import BASE, build_program


def program():
    # x21 = 0x44090080, a valid SRAM location with room for all accesses.
    p = [
        label("start"),
        Insn("movz", 21, 0x4409, 1),
        Insn("movk", 21, 0x80),
        # Seed B/H/W/X elements at offsets 0/2/4/8.
        Insn("movz", 0, 0x11),
        Insn("sturb", 0, 21, 0),
        Insn("movz", 0, 0x2233),
        Insn("sturh", 0, 21, 2),
        Insn("movz", 0, 0x5678, 1),
        Insn("movk", 0, 0x4455),
        Insn("sturw", 0, 21, 4),
        Insn("movz", 0, 0xdef0, 3),
        Insn("movk", 0, 0x9abc, 2),
        Insn("movk", 0, 0x5678, 1),
        Insn("movk", 0, 0x1234),
        Insn("stur", 0, 21, 8),
        # Unsigned post-index loads: B/H/W/X and signed post variants.
        Insn("orr", 20, 21, 31),
        Insn("ldrb_post", 1, 20, 1),
        Insn("orr", 20, 21, 31),
        Insn("ldrh_post", 2, 20, 2),
        Insn("orr", 20, 21, 31),
        Insn("ldrw_post", 3, 20, 4),
        Insn("orr", 20, 21, 31),
        Insn("ldr_post", 4, 20, 8),
        Insn("orr", 20, 21, 31),
        Insn("ldrsb_post", 5, 20, 0),
        Insn("orr", 20, 21, 31),
        Insn("ldrsh_post", 6, 20, 2),
        Insn("orr", 20, 21, 31),
        Insn("ldrsw_post", 7, 20, 4),
        # Unsigned pre-index loads: B/H/W/X.
        Insn("orr", 20, 21, 31),
        Insn("ldrb_pre", 8, 20, 1),
        Insn("orr", 20, 21, 31),
        Insn("ldrh_pre", 9, 20, 2),
        Insn("orr", 20, 21, 31),
        Insn("ldrw_pre", 10, 20, 4),
        Insn("orr", 20, 21, 31),
        Insn("ldr_pre", 11, 20, 8),
        # Pre/post stores at all sizes.
        Insn("movz", 0, 0xa5),
        Insn("orr", 20, 21, 31),
        Insn("strb_post", 0, 20, 1),
        Insn("orr", 20, 21, 31),
        Insn("strh_post", 0, 20, 2),
        Insn("orr", 20, 21, 31),
        Insn("strw_post", 0, 20, 4),
        Insn("orr", 20, 21, 31),
        Insn("str_post", 4, 20, 8),
        Insn("orr", 20, 21, 31),
        Insn("strb_pre", 0, 20, 1),
        Insn("orr", 20, 21, 31),
        Insn("strh_pre", 0, 20, 2),
        Insn("orr", 20, 21, 31),
        Insn("strw_pre", 0, 20, 4),
        Insn("orr", 20, 21, 31),
        Insn("str_pre", 4, 20, 8),
        # Rt == Rn loads: QEMU is the architectural reference for the
        # constrained-overlap encoding; base writeback must be compared too.
        Insn("orr", 20, 21, 31),
        Insn("ldrb_pre", 20, 20, 1),
        Insn("orr", 20, 21, 31),
        Insn("ldrh_post", 20, 20, 2),
        Insn("orr", 20, 21, 31),
        Insn("ldrw_pre", 20, 20, 4),
        Insn("orr", 20, 21, 31),
        Insn("ldr_post", 20, 20, 8),
        # Rt == Rn stores: source and writeback use the same architectural
        # register, but the memory address must use the pre/post effective
        # address rather than the updated base.
        Insn("orr", 20, 21, 31),
        Insn("strb_post", 20, 20, 1),
        Insn("orr", 20, 21, 31),
        Insn("strh_pre", 20, 20, 2),
        Insn("orr", 20, 21, 31),
        Insn("strw_post", 20, 20, 4),
        Insn("orr", 20, 21, 31),
        Insn("str_pre", 20, 20, 8),
        # SP base: ADD SP,X21,#0 is an architectural commit, then exercise
        # indexed B/H/W/X operations through the SP writeback channel.
        Insn("add", 31, 21, 0),
        Insn("ldrb_pre", 12, 31, 1),
        Insn("add", 31, 21, 0),
        Insn("ldrh_post", 13, 31, 2),
        Insn("add", 31, 21, 0),
        Insn("ldrw_pre", 14, 31, 4),
        Insn("add", 31, 21, 0),
        Insn("ldr_post", 15, 31, 8),
        Insn("add", 31, 21, 0),
        Insn("strb_post", 0, 31, 1),
        Insn("add", 31, 21, 0),
        Insn("strh_pre", 0, 31, 2),
        Insn("add", 31, 21, 0),
        Insn("strw_post", 0, 31, 4),
        Insn("add", 31, 21, 0),
        Insn("str_pre", 4, 31, 8),
        # Immediate consumer of a post-indexed base, exercising forwarding
        # at the commit/next-decode boundary without an intervening ORR.
        Insn("orr", 20, 21, 31),
        Insn("ldrb_post", 16, 20, 1),
        Insn("strb_post", 16, 20, 1),
        Insn("b", "loop"),
        label("loop"),
        Insn("b", "loop"),
    ]
    return assemble(p, BASE)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    args = parser.parse_args()
    build_program(args.output, program())
    print(f"B25 post/pre writeback matrix: {len(program())} words -> {args.output}")


if __name__ == "__main__":
    sys.exit(main())
