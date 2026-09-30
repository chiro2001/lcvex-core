"""AArch64 参考状态模型（P1 子集：NOP/ADD/SUB/ADDS/SUBS/B/BL）。

P2 之前用于验证 QEMU 差分导出的正确性；P2 起由 RTL 提交包替代本模型。
"""

from dataclasses import dataclass, field

MASK64 = (1 << 64) - 1


@dataclass
class A64State:
    pc: int
    x: list = field(default_factory=lambda: [0] * 31)
    sp: int = 0
    nzcv: int = 0
    pending_writes: list = field(default_factory=list)

    def step(self, insn, insn_pc=None):
        """执行一条 A64 指令，返回 (下一条 PC, 内存写列表)。

        内存写列表元素为 (addr, data, size)。
        """
        pc = insn_pc if insn_pc is not None else self.pc
        writes = []

        if insn == 0xD503201F:  # NOP
            return (pc + 4) & MASK64, writes

        if (insn & 0xFF800000) == 0xD2800000:  # MOVZ（64 位）
            hw = (insn >> 21) & 3
            imm16 = (insn >> 5) & 0xFFFF
            rd = insn & 31
            if rd != 31:
                self.x[rd] = (imm16 << (hw * 16)) & MASK64
            return (pc + 4) & MASK64, writes

        if (insn & 0xFFC00000) == 0xF9000000:  # STR Xt, [Xn, #imm12*8]
            imm12 = (insn >> 10) & 0xFFF
            rn = (insn >> 5) & 31
            rt = insn & 31
            addr = (self.x[rn] + imm12 * 8) & MASK64
            writes.append((addr, self.x[rt], 8))
            return (pc + 4) & MASK64, writes

        if (insn >> 26) & 0x3F == 0b000101:  # B / BL
            imm26 = insn & 0x3FFFFFF
            if imm26 & (1 << 25):
                imm26 -= 1 << 26
            target = (pc + (imm26 << 2)) & MASK64
            if (insn >> 31) & 1:  # BL
                self.x[30] = (pc + 4) & MASK64
            return target, writes

        # ---- MUL / UDIV / SDIV（Data-processing 2/3-source）----
        if (insn & 0xFFE0FC00) == 0x9B007C00:  # MUL Xd, Xn, Xm（Ra=31）
            rm = (insn >> 16) & 31
            rn = (insn >> 5) & 31
            rd = insn & 31
            if rd != 31:
                self.x[rd] = (self.x[rn] * self.x[rm]) & MASK64
            return (pc + 4) & MASK64, writes

        if (insn & 0xFFE0FC00) == 0x1B007C00:  # MUL Wd, Wn, Wm
            rm = (insn >> 16) & 31
            rn = (insn >> 5) & 31
            rd = insn & 31
            if rd != 31:
                self.x[rd] = ((self.x[rn] & 0xFFFFFFFF) *
                              (self.x[rm] & 0xFFFFFFFF)) & 0xFFFFFFFF
            return (pc + 4) & MASK64, writes

        def _div64(a, b, signed):
            if b == 0:
                return 0
            if not signed:
                return (a // b) & MASK64
            q = (abs(a) // abs(b))
            if (a < 0) != (b < 0):
                q = -q
            return q & MASK64

        def _div32(a, b, signed):
            if signed:
                a = (a & 0xFFFFFFFF) - (1 << 32) if a & (1 << 31) else a & 0xFFFFFFFF
                b = (b & 0xFFFFFFFF) - (1 << 32) if b & (1 << 31) else b & 0xFFFFFFFF
            else:
                a &= 0xFFFFFFFF
                b &= 0xFFFFFFFF
            return _div64(a, b, signed) & 0xFFFFFFFF

        if (insn & 0xFFE0FC00) == 0x9AC00800:  # UDIV Xd, Xn, Xm
            rd = insn & 31
            if rd != 31:
                self.x[rd] = _div64(self.x[(insn >> 5) & 31],
                                    self.x[(insn >> 16) & 31], False)
            return (pc + 4) & MASK64, writes

        if (insn & 0xFFE0FC00) == 0x9AC00C00:  # SDIV Xd, Xn, Xm
            rd = insn & 31
            if rd != 31:
                self.x[rd] = _div64(self.x[(insn >> 5) & 31],
                                    self.x[(insn >> 16) & 31], True)
            return (pc + 4) & MASK64, writes

        if (insn & 0xFFE0FC00) == 0x1AC00800:  # UDIV Wd, Wn, Wm
            rd = insn & 31
            if rd != 31:
                self.x[rd] = _div32(self.x[(insn >> 5) & 31],
                                    self.x[(insn >> 16) & 31], False)
            return (pc + 4) & MASK64, writes

        if (insn & 0xFFE0FC00) == 0x1AC00C00:  # SDIV Wd, Wn, Wm
            rd = insn & 31
            if rd != 31:
                self.x[rd] = _div32(self.x[(insn >> 5) & 31],
                                    self.x[(insn >> 16) & 31], True)
            return (pc + 4) & MASK64, writes

        if (insn & 0x1F800000) != 0x11000000:
            raise ValueError(f"不支持的指令 0x{insn:08x} @ 0x{pc:x}")

        sf = (insn >> 31) & 1
        op = (insn >> 30) & 1
        s = (insn >> 29) & 1
        imm12 = (insn >> 10) & 0xFFF
        rn = (insn >> 5) & 31
        rd = insn & 31

        width = 64 if sf else 32
        mask = (1 << width) - 1
        a = self.x[rn] if rn != 31 else 0
        b = imm12

        if op == 0:  # ADD/ADDS
            res = (a + b) & mask
            c = 1 if (a + b) > mask else 0
            v = 1 if (((a ^ b) & mask) == 0 and
                      ((a ^ res) & (1 << (width - 1)))) else 0
        else:  # SUB/SUBS
            res = (a - b) & mask
            c = 1 if a >= b else 0
            v = 1 if ((a ^ b) & (1 << (width - 1))) and \
                ((a ^ res) & (1 << (width - 1))) else 0

        if s:
            n = 1 if (res >> (width - 1)) & 1 else 0
            z = 1 if res == 0 else 0
            self.nzcv = (n << 3) | (z << 2) | (c << 1) | v
        if rd != 31:
            self.x[rd] = res

        return (pc + 4) & MASK64, writes


def compare_state(rec, state, label):
    """把 QEMU 一条 commit 记录与参考模型状态比较，返回错误列表。"""
    errors = []
    for i in range(31):
        want = int(rec[f"x{i}"], 16)
        if want != state.x[i]:
            errors.append(
                f"{label}: x{i} QEMU=0x{want:016x} 模型=0x{state.x[i]:016x}")
    for name, val in (("sp", state.sp), ("next_pc", state.pc),
                      ("nzcv", state.nzcv)):
        want = int(rec[name], 16)
        if want != val:
            errors.append(
                f"{label}: {name} QEMU=0x{want:016x} 模型=0x{val:016x}")

    nstores = int(rec.get("stores", 0))
    for i in range(nstores):
        want = (
            int(rec[f"s{i}_addr"], 16),
            int(rec[f"s{i}_data"], 16),
            int(rec[f"s{i}_size"]),
        )
        if want not in state.pending_writes:
            errors.append(f"{label}: 内存写 {want} 未在模型中发生")
    return errors
