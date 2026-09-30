"""A64 指令编码与极简汇编器（P1/P2 测试用子集）。"""


def _addsub_imm(rd, rn, imm12, sf, op, s):
    return (sf << 31) | (op << 30) | (s << 29) | (0b100010 << 23) | \
        ((imm12 & 0xFFF) << 10) | ((rn & 31) << 5) | (rd & 31)


def _addsub_reg(rd, rn, rm, sf, op, s, shift_type=0, shift_amt=0):
    return (sf << 31) | (op << 30) | (s << 29) | (0b01011 << 24) | \
        ((shift_type & 3) << 22) | ((rm & 31) << 16) | \
        ((shift_amt & 0x3F) << 10) | ((rn & 31) << 5) | (rd & 31)


def _logic_reg(rd, rn, rm, sf, opc, n=0, shift_type=0, shift_amt=0):
    return (sf << 31) | ((opc & 3) << 29) | (0b01010 << 24) | \
        ((n & 1) << 21) | ((shift_type & 3) << 22) | ((rm & 31) << 16) | \
        ((shift_amt & 0x3F) << 10) | ((rn & 31) << 5) | (rd & 31)


def _movwide(rd, imm16, sf, opc, hw=0):
    base = {0: 0x12800000, 2: 0x52800000, 3: 0x72800000}[opc]
    if sf:
        base |= 0x80000000
    return base | ((hw & 3) << 21) | ((imm16 & 0xFFFF) << 5) | (rd & 31)


def _enc_svc(labels, pc, imm16=0):
    return 0xD4000001 | ((imm16 & 0xFFFF) << 5)


def _enc_hvc(labels, pc, imm16=0):
    return 0xD4000002 | ((imm16 & 0xFFFF) << 5)


def _enc_smc(labels, pc, imm16=0):
    return 0xD4000003 | ((imm16 & 0xFFFF) << 5)


def _enc_eret(labels, pc):
    return 0xD69F03E0


def _enc_isb(labels, pc):
    return 0xD5033FDF   # ISB sy


def _enc_wait(labels, pc, name):
    return {"wfe": 0xD503205F, "wfi": 0xD503207F,
            "sev": 0xD503209F, "sevl": 0xD50320BF}[name]


def _enc_wfx_t(labels, pc, name, rt):
    # WFET/WFIT Xt：QEMU a64.decode 的系统指令寄存器编码。
    base = {"wfet": 0xD5031000, "wfit": 0xD5031020}[name]
    return base | (rt & 31)


def _enc_dmb(labels, pc):
    return 0xD50330BF   # DMB sy


def _enc_dsb(labels, pc):
    return 0xD5033F9F   # DSB sy


def _enc_udf(labels, pc, imm16=0):
    return imm16 & 0xFFFF


def _enc_msr_sys(labels, pc, reg, rt):
    return _sysreg(0, reg, rt)


def _enc_mrs_sys(labels, pc, rt, reg):
    return _sysreg(1, reg, rt)


def _enc_rdvl(labels, pc, rd, imm6, sme=False):
    # RDVL Rd,#imm6 = 0x04BF5000 | (imm6<<5) | rd
    # RDSVL（sme=True，按 SMCR LEN）= 0x04BF5800 | (imm6<<5) | rd
    base = 0x04BF5800 if sme else 0x04BF5000
    return base | ((imm6 & 0x3F) << 5) | (rd & 31)


def _enc_extr(rd, rn, rm, imm, sf):
    # EXTR：sf 00 100111 N 0 rm imm6 rn rd（X 为 imm6，W 为 imm5+bit10=0）
    base = 0x93800000 if sf else 0x13800000
    if sf:
        return base | ((rm & 31) << 16) | ((imm & 0x3F) << 10) | \
            ((rn & 31) << 5) | (rd & 31)
    return base | ((rm & 31) << 16) | ((imm & 0x1F) << 11) | \
        ((rn & 31) << 5) | (rd & 31)


def _enc_ldxp(rt1, rt2, rn):
    # LDXP Xt1, Xt2, [Xn]：sf=1 11 001000 0 1 rs=31 rt2 rn rt1。
    # 基址按 rs=0 计算（rs 单独置 31）。
    return 0xC8600000 | (31 << 16) | ((rt2 & 31) << 10) | \
        ((rn & 31) << 5) | (rt1 & 31)


def _enc_stxp(rs, rt1, rt2, rn, release=False):
    # STXP/STLXP Ws, Xt1, Xt2, [Xn]：sf=1 11 001000 0 0 rs rt2 rn rt1
    # release（STLXP）置 bit15。
    base = 0xC8208000 if release else 0xC8200000
    return base | ((rs & 31) << 16) | ((rt2 & 31) << 10) | \
        ((rn & 31) << 5) | (rt1 & 31)


def _sysreg(read, reg, rt):
    op0, op1, crn, crm, op2 = _SYSREG[reg]
    # SYS 编码：1101010100 l op0[20:19] op1[18:16] crn[15:12] crm[11:8]
    # op2[7:5] rt[4:0]（见 QEMU a64.decode SYS 模式）
    return 0xD5000000 | ((read & 1) << 21) | ((op0 & 3) << 19) | \
        ((op1 & 7) << 16) | ((crn & 0xF) << 12) | ((crm & 0xF) << 8) | \
        ((op2 & 7) << 5) | (rt & 31)


def _sysw(op0, op1, crn, crm, op2, rt):
    # SYS（写）编码，op0 恒为 01：IC/DC/TLBI 维护指令（M2-4b）。
    # 编码表见 QEMU helper.c v8_cp_reginfo（op0,op1,crn,crm,op2）。
    return 0xD5000000 | ((op0 & 3) << 19) | ((op1 & 7) << 16) | \
        ((crn & 0xF) << 12) | ((crm & 0xF) << 8) | ((op2 & 7) << 5) | \
        (rt & 31)


"""AArch64 系统寄存器编码（op0, op1, CRn, CRm, op2）。"""
_SYSREG = {
    "vbar_el1": (3, 0, 12, 0, 0),
    "elr_el1":  (3, 0, 4, 0, 1),
    "spsr_el1": (3, 0, 4, 0, 0),
    "sctlr_el1": (3, 0, 1, 0, 0),
    "tcr_el1":   (3, 0, 2, 0, 2),
    "ttbr0_el1": (3, 0, 2, 0, 0),
    "ttbr1_el1": (3, 0, 2, 0, 1),
    "mair_el1":  (3, 0, 10, 2, 0),
    "esr_el1":   (3, 0, 5, 2, 0),
    "far_el1":   (3, 0, 6, 0, 0),
    "par_el1":   (3, 0, 7, 4, 0),
    "nzcv":      (3, 3, 4, 2, 0),
    "daif":      (3, 3, 4, 2, 1),
    # P6：Linux 启动补充（op0/op1/CRn/CRm/op2）
    "currentel":     (3, 0, 4, 2, 2),
    "midr_el1":      (3, 0, 0, 0, 0),
    "revidr_el1":    (3, 0, 0, 0, 6),
    "id_aa64pfr0_el1":  (3, 0, 0, 4, 0),
    "id_aa64pfr1_el1":  (3, 0, 0, 4, 1),
    "id_aa64pfr2_el1":  (3, 0, 0, 4, 2),
    "id_aa64dfr0_el1":  (3, 0, 0, 5, 0),
    "id_aa64dfr1_el1":  (3, 0, 0, 5, 1),
    "id_aa64afr0_el1":  (3, 0, 0, 5, 4),
    "id_aa64afr1_el1":  (3, 0, 0, 5, 5),
    "id_aa64isar0_el1": (3, 0, 0, 6, 0),
    "id_aa64isar1_el1": (3, 0, 0, 6, 1),
    "id_aa64isar2_el1": (3, 0, 0, 6, 2),
    "id_aa64isar3_el1": (3, 0, 0, 6, 3),
    "id_aa64mmfr0_el1": (3, 0, 0, 7, 0),
    "id_aa64mmfr1_el1": (3, 0, 0, 7, 1),
    "id_aa64mmfr2_el1": (3, 0, 0, 7, 2),
    "id_aa64mmfr3_el1": (3, 0, 0, 7, 3),
    "id_aa64mmfr4_el1": (3, 0, 0, 7, 4),
    "id_aa64fpfr0_el1":  (3, 0, 0, 4, 7),
    "id_pfr0_el1":       (3, 0, 0, 1, 0),
    "id_pfr1_el1":       (3, 0, 0, 1, 1),
    "dczid_el0":        (3, 3, 0, 0, 7),
    "id_aa64mmfr2_el1": (3, 0, 0, 7, 2),
    "id_aa64mmfr3_el1": (3, 0, 0, 7, 3),
    "id_aa64zfr0_el1":  (3, 0, 0, 4, 4),
    "id_aa64smfr0_el1":  (3, 0, 0, 4, 5),
    "id_dfr0_el1":       (3, 0, 0, 1, 2),
    "id_dfr1_el1":       (3, 0, 0, 3, 5),
    "id_afr0_el1":       (3, 0, 0, 1, 3),
    "id_mmfr0_el1":      (3, 0, 0, 1, 4),
    "id_mmfr1_el1":      (3, 0, 0, 1, 5),
    "id_mmfr2_el1":      (3, 0, 0, 1, 6),
    "id_mmfr3_el1":      (3, 0, 0, 1, 7),
    "id_isar0_el1":      (3, 0, 0, 2, 0),
    "id_isar1_el1":      (3, 0, 0, 2, 1),
    "id_isar2_el1":      (3, 0, 0, 2, 2),
    "id_isar3_el1":      (3, 0, 0, 2, 3),
    "id_isar4_el1":      (3, 0, 0, 2, 4),
    "id_isar5_el1":      (3, 0, 0, 2, 5),
    "id_mmfr4_el1":      (3, 0, 0, 2, 6),
    "id_isar6_el1":      (3, 0, 0, 2, 7),
    "mvfr0_el1":         (3, 0, 0, 3, 0),
    "mvfr1_el1":         (3, 0, 0, 3, 1),
    "mvfr2_el1":         (3, 0, 0, 3, 2),
    "id_pfr2_el1":       (3, 0, 0, 3, 4),
    "id_mmfr5_el1":      (3, 0, 0, 3, 6),
    "clidr_el1":         (3, 1, 0, 0, 1),
    "zcr_el1":           (3, 0, 1, 2, 0),
    "smcr_el1":          (3, 0, 1, 2, 6),
    "smpri_el1":         (3, 0, 1, 2, 4),
    "smidr_el1":         (3, 1, 0, 0, 6),
    "aidr_el1":          (3, 1, 0, 0, 7),
    "rndr":              (3, 3, 2, 4, 0),
    "rndrrs":            (3, 3, 2, 4, 1),
    "csselr_el1":        (3, 2, 0, 0, 0),
    "ctr_el0":      (3, 3, 0, 0, 1),
    "cpacr_el1":    (3, 0, 1, 0, 2),
    "mdscr_el1":    (2, 0, 0, 2, 2),
    "osdlr_el1":    (2, 0, 1, 3, 4),
    "oslar_el1":    (2, 0, 1, 0, 4),
    "dbgbvr0_el1":  (2, 0, 0, 0, 4),
    "dbgbcr0_el1":  (2, 0, 0, 0, 5),
    "dbgwvr0_el1":  (2, 0, 0, 0, 6),
    "dbgwcr0_el1":  (2, 0, 0, 0, 7),
    "dbgbcr5_el1":  (2, 0, 0, 5, 5),
    "pmuserenr_el0": (3, 3, 9, 14, 0),
    "cntkctl_el1":  (3, 0, 14, 1, 0),
    "cntfrq_el0":   (3, 3, 14, 0, 0),
    "cntpct_el0":   (3, 3, 14, 0, 1),
    "cntvct_el0":   (3, 3, 14, 0, 2),
    "cntpctss_el0":  (3, 3, 14, 0, 5),
    "cntvctss_el0":  (3, 3, 14, 0, 6),
    "cntp_tval_el0": (3, 3, 14, 2, 0),
    "cntp_ctl_el0":  (3, 3, 14, 2, 1),
    "cntp_cval_el0": (3, 3, 14, 2, 2),
    "cntv_tval_el0": (3, 3, 14, 3, 0),
    "cntv_ctl_el0":  (3, 3, 14, 3, 1),
    "cntv_cval_el0": (3, 3, 14, 3, 2),
    "tpidr_el0":    (3, 3, 13, 0, 2),
    "tpidrro_el0":  (3, 3, 13, 0, 3),
    "contextidr_el1": (3, 0, 13, 0, 1),
    "tpidr_el1":    (3, 0, 13, 0, 4),
    "tcr2_el1":     (3, 0, 2, 0, 3),
    "sctlr2_el1":   (3, 0, 1, 0, 3),
    "apia_keylo_el1": (3, 0, 2, 1, 0),
    "apia_keyhi_el1": (3, 0, 2, 1, 1),
    "apib_keylo_el1": (3, 0, 2, 1, 2),
    "apib_keyhi_el1": (3, 0, 2, 1, 3),
    "apda_keylo_el1": (3, 0, 2, 2, 0),
    "apda_keyhi_el1": (3, 0, 2, 2, 1),
    "apdb_keylo_el1": (3, 0, 2, 2, 2),
    "apdb_keyhi_el1": (3, 0, 2, 2, 3),
    "apga_keylo_el1": (3, 0, 2, 3, 0),
    "apga_keyhi_el1": (3, 0, 2, 3, 1),
    "tpidr2_el0":    (3, 3, 13, 0, 5),
    "dit":           (3, 3, 4, 2, 5),
    "isr_el1":       (3, 0, 12, 1, 0),
    "disr_el1":      (3, 0, 12, 1, 1),
    "pir_el1":      (3, 0, 10, 2, 3),
    "pire0_el1":    (3, 0, 10, 2, 2),
    "sctlr_el2":    (3, 4, 1, 0, 0),
    "hcr_el2":      (3, 4, 1, 1, 0),
    "vbar_el2":     (3, 4, 12, 0, 0),
    "sp_el0":       (3, 0, 4, 1, 0),
}


def _ldst_uimm(rt, rn, imm12, size, opc):
    # unsigned immediate：bits[25:24]=01（00 为 unscaled，即 STUR）
    return (size << 30) | (0b111 << 27) | (0b01 << 24) | ((opc & 3) << 22) | \
        ((imm12 & 0xFFF) << 10) | ((rn & 31) << 5) | (rt & 31)


def _b(imm26, bl=False):
    return (0x94000000 if bl else 0x14000000) | (imm26 & 0x3FFFFFF)


def _b_cond(cond, imm19):
    return 0x54000000 | ((imm19 & 0x7FFFF) << 5) | (cond & 0xF)


def _cbz(rt, imm19, sf, op):
    base = 0x34000000 | (sf << 31) | (op << 24)
    return base | ((imm19 & 0x7FFFF) << 5) | (rt & 31)


def _tbz(rt, bit, imm14, op):
    return (0x36000000 | (op << 24)) | ((bit >> 5) << 31) | \
        ((bit & 0x1F) << 19) | ((imm14 & 0x3FFF) << 5) | (rt & 31)


def _adr(rd, imm, page=False):
    base = 0x90000000 if page else 0x10000000
    imm &= 0x1FFFFF
    immlo = imm & 3
    immhi = (imm >> 2) & 0x7FFFF
    return base | (immlo << 29) | (immhi << 5) | (rd & 31)


def _enc_mul(rd, rn, rm, sf):
    # MUL = MADD Rd, Rn, Rm, XZR（Data-processing 3-source）
    return (sf << 31) | (0b11011000 << 21) | ((rm & 31) << 16) | \
        (0b11111 << 10) | ((rn & 31) << 5) | (rd & 31)


def _enc_div(rd, rn, rm, sf, signed):
    # UDIV/SDIV（Data-processing 2-source，bit10 区分有/无符号）
    return (sf << 31) | (0b11010110 << 21) | ((rm & 31) << 16) | \
        (0b00001 << 11) | ((signed & 1) << 10) | ((rn & 31) << 5) | (rd & 31)


def _enc_vshift(labels, pc, name, rd, rn, rm):
    # LSLV/LSRV/ASRV/RORV：sf 0 0 11010110 Rm 0010 opc[1:0] Rn Rd
    sf = 0 if name.endswith("_w") else 1
    base = name.replace("_w", "")
    opc = {"lslv": 0, "lsrv": 1, "asrv": 2, "rorv": 3}[base]
    return (sf << 31) | (0b0011010110 << 21) | ((rm & 31) << 16) | \
        (0b0010 << 12) | ((opc & 3) << 10) | ((rn & 31) << 5) | (rd & 31)


def _enc_adc(labels, pc, name, rd, rn, rm):
    # ADC/ADCS/SBC/SBCS：sf op[1:0] 11010000 Rm 000000 Rn Rd；
    # NGC/NGCS = SBC/SBCS 且 Rn=31（op 在 bits[30:29]，非 [15:12]）。
    sf = 0 if name.endswith("_w") else 1
    base = name.replace("_w", "").replace("ngc", "sbc").replace("ngcs", "sbcs")
    op = {"adc": 0, "adcs": 1, "sbc": 2, "sbcs": 3}[base]
    if name.startswith("ngc"):
        rn = 31
    return (sf << 31) | ((op & 3) << 29) | (0b11010000 << 21) | \
        ((rm & 31) << 16) | ((rn & 31) << 5) | (rd & 31)


def nop():
    return 0xD503201F


_COND = {"eq": 0, "ne": 1, "cs": 2, "hs": 2, "cc": 3, "lo": 3, "mi": 4,
         "pl": 5, "vs": 6, "vc": 7, "hi": 8, "ls": 9, "ge": 10, "lt": 11,
         "gt": 12, "le": 13, "al": 14}


class Insn:
    def __init__(self, name, *args):
        self.name = name
        self.args = args

    def encode(self, labels, pc):
        return _ENCODERS[self.name](labels, pc, *self.args)


def label(name):
    return Insn("label", name)


def _enc_nop(labels, pc):
    return nop()


def _enc_raw(labels, pc, w):
    return w


def _enc_addsub_imm(labels, pc, name, rd, rn, imm):
    s = name in ("adds", "subs", "cmp", "cmn", "adds_w", "subs_w",
                 "cmp_w", "cmn_w")
    op = 1 if name in ("sub", "subs", "cmp", "sub_w", "subs_w", "cmp_w") else 0
    sf = 0 if name.endswith("_w") else 1
    rd = 31 if name in ("cmp", "cmn", "cmp_w", "cmn_w") else rd
    return _addsub_imm(rd, rn, imm, sf, op, s)


def _enc_addsub_reg(labels, pc, name, rd, rn, rm, shift_type=0, shift_amt=0):
    s = name.endswith("s")
    op = 1 if name.startswith("sub") else 0
    sf = 0 if name.endswith("_w") else 1
    return _addsub_reg(rd, rn, rm, sf, op, s, shift_type, shift_amt)


def _enc_logic_reg(labels, pc, name, rd, rn, rm, shift_type=0, shift_amt=0):
    base = name.replace("_w", "")
    opc = {"and": 0, "bic": 0, "orr": 1, "orn": 1,
           "eor": 2, "eon": 2, "ands": 3, "bics": 3}[base]
    n = 1 if base in ("bic", "bics", "orn", "eon") else 0
    sf = 0 if name.endswith("_w") else 1
    return _logic_reg(rd, rn, rm, sf, opc, n, shift_type, shift_amt)


def _enc_movwide(labels, pc, name, rd, imm16, hw=0):
    base = name.replace("_w", "")
    opc = {"movn": 0, "movz": 2, "movk": 3}[base]
    sf = 0 if name.endswith("_w") else 1
    return _movwide(rd, imm16, sf, opc, hw)


def _enc_ldst(labels, pc, name, rt, rn, imm12):
    size = {"str": 3, "ldr": 3, "strw": 2, "ldrw": 2, "strh": 1, "ldrh": 1,
            "strb": 0, "ldrb": 0}[name]
    opc = 0 if name.startswith("str") else 1
    return _ldst_uimm(rt, rn, imm12, size, opc)


def _enc_ldur(rt, rn, imm9, size, opc):
    # LDUR/STUR 非缩放：size 111 0 00 0 opc 0 imm9[20:12] 00 rn rt
    return (size << 30) | (0b111 << 27) | (0 << 26) | (0 << 25) | \
        (0 << 24) | ((opc & 3) << 22) | (0 << 21) | \
        ((imm9 & 0x1FF) << 12) | (0 << 11) | (0 << 10) | \
        ((rn & 31) << 5) | (rt & 31)


def _enc_ldtr(rt, rn, imm9, size, opc):
    # LDTR/STTR 非特权：与 LDUR/STUR 相同，仅 bits[11:10]=10。
    return (size << 30) | (0b111 << 27) | (0 << 26) | (0 << 25) | \
        (0 << 24) | ((opc & 3) << 22) | (0 << 21) | \
        ((imm9 & 0x1FF) << 12) | (1 << 11) | (0 << 10) | \
        ((rn & 31) << 5) | (rt & 31)


def _enc_stur(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 3, 0)


def _enc_ldur_x(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 3, 1)


def _enc_sturw(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 2, 0)


def _enc_ldurw(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 2, 1)


def _enc_sturh(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 1, 0)


def _enc_ldurh(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 1, 1)


def _enc_sturb(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 0, 0)


def _enc_ldurb(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 0, 1)


def _enc_ldursw(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 2, 2)


def _enc_ldursb(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 0, 2)


def _enc_ldursh(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 1, 2)


def _enc_ldursb_w(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 0, 3)


def _enc_ldursh_w(labels, pc, rt, rn, imm9):
    return _enc_ldur(rt, rn, imm9, 1, 3)


def _enc_ldur_idx(rt, rn, imm9, size, opc, idx):
    """LDR/STR 单寄存器 pre/post-index（P6 Linux 启动缺口）：
    bits[11:10]=01 为 post-index（先访存后写回基址），=11 为 pre-index
    （先更新基址再访存）；imm9 有符号 9 位。与 LDUR/STUR 共用 0x38 编码
    空间，仅 bits[11:10] 不同。"""
    return (size << 30) | (0b111 << 27) | (0 << 26) | (0 << 25) | \
        (0 << 24) | ((opc & 3) << 22) | (0 << 21) | \
        ((imm9 & 0x1FF) << 12) | ((idx & 3) << 10) | \
        ((rn & 31) << 5) | (rt & 31)


def _enc_ldr_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 3, 1, 1)


def _enc_str_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 3, 0, 1)


def _enc_ldrw_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 2, 1, 1)


def _enc_strw_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 2, 0, 1)


def _enc_ldrh_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 1, 1, 1)


def _enc_strh_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 1, 0, 1)


def _enc_ldrb_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 0, 1, 1)


def _enc_strb_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 0, 0, 1)


def _enc_ldrsw_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 2, 2, 1)


def _enc_ldrsb_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 0, 2, 1)


def _enc_ldrsh_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 1, 2, 1)


def _enc_ldrsb_w_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 0, 3, 1)


def _enc_ldrsh_w_post(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 1, 3, 1)


def _enc_ldr_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 3, 1, 3)


def _enc_str_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 3, 0, 3)


def _enc_ldrw_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 2, 1, 3)


def _enc_strw_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 2, 0, 3)


def _enc_ldrh_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 1, 1, 3)


def _enc_strh_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 1, 0, 3)


def _enc_ldrb_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 0, 1, 3)


def _enc_strb_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 0, 0, 3)


def _enc_ldrsw_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 2, 2, 3)


def _enc_ldrsb_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 0, 2, 3)


def _enc_ldrsh_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 1, 2, 3)


def _enc_ldrsb_w_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 0, 3, 3)


def _enc_ldrsh_w_pre(labels, pc, rt, rn, imm9):
    return _enc_ldur_idx(rt, rn, imm9, 1, 3, 3)


def _enc_muldiv(labels, pc, name, rd, rn, rm):
    base = name.replace("_w", "")
    sf = 0 if name.endswith("_w") else 1
    if base == "mul":
        return _enc_mul(rd, rn, rm, sf)
    return _enc_div(rd, rn, rm, sf, base == "sdiv")


def _enc_ldrsw(labels, pc, rt, rn, imm12):
    return _ldst_uimm(rt, rn, imm12, 2, 2)


def _enc_b(labels, pc, name, target):
    imm26 = (labels[target] - pc) >> 2
    return _b(imm26, bl=(name == "bl"))


def _enc_b_cond(labels, pc, cond, target):
    imm19 = (labels[target] - pc) >> 2
    return _b_cond(_COND[cond], imm19)


def _enc_cbz(labels, pc, name, rt, target):
    imm19 = (labels[target] - pc) >> 2
    return _cbz(rt, imm19, 1, op=(name == "cbnz"))


def _enc_tbz(labels, pc, name, rt, bit, target):
    imm14 = (labels[target] - pc) >> 2
    return _tbz(rt, bit, imm14, op=(name == "tbnz"))


def _enc_br(labels, pc, name, rn=30):
    return {"br": 0xD61F0000, "blr": 0xD63F0000, "ret": 0xD65F0000}[name] | \
        ((rn & 31) << 5)


def _enc_adr(labels, pc, name, rd, target):
    page = (name == "adrp")
    if page:
        imm = ((labels[target] & ~0xFFF) - (pc & ~0xFFF)) >> 12
    else:
        imm = labels[target] - pc
    return _adr(rd, imm, page)


def _enc_ldr_lit(labels, pc, name, rt, target):
    # LDR（literal）：opc 00=LDR W 01=LDR X 10=LDRSW 11=PRFM。
    # addr = pc + SignExtend(imm19)<<2，imm19 范围 ±1 MiB。
    # target 可以是标签名（程序内）或绝对地址（随机程序指向数据区）。
    if isinstance(target, int):
        imm = target - pc
    else:
        imm = labels[target] - pc
    if imm % 4 != 0 or not (-(1 << 20) <= imm < (1 << 20)):
        raise ValueError(f"literal 目标超出 ±1MiB 或未 4 字节对齐: {imm:#x}")
    opc = {"ldr_w_lit": 0, "ldr_lit": 1, "ldrsw_lit": 2, "prfm_lit": 3}[name]
    return (opc << 30) | (0b011000 << 24) | \
        (((imm >> 2) & 0x7FFFF) << 5) | (rt & 31)


def _enc_csel(labels, pc, name, rd, rn, rm, cond):
    # CSEL/CSINC/CSINV/CSNEG：sf op 0011010100 Rm cond o2 Rn Rd，
    # op=1（bit30）为取反族（CSINV/CSNEG），o2=1（bit10）为 +1/取负族
    # （CSINC/CSNEG）。
    sf = 0 if name.endswith("_w") else 1
    base = name.replace("_w", "")
    op = 1 if base in ("csinv", "csneg") else 0
    o2 = 1 if base in ("csinc", "csneg") else 0
    return (sf << 31) | (op << 30) | (0b0011010100 << 21) | \
        ((rm & 31) << 16) | ((_COND[cond] & 0xF) << 12) | (o2 << 10) | \
        ((rn & 31) << 5) | (rd & 31)


_COND_INV = {"eq": "ne", "ne": "eq", "cs": "cc", "cc": "cs",
             "mi": "pl", "pl": "mi", "vs": "vc", "vc": "vs",
             "hi": "ls", "ls": "hi", "ge": "lt", "lt": "ge",
             "gt": "le", "le": "gt"}


def _enc_cset(labels, pc, rd, cond):
    # cset Rd, cond = csinc Rd, xzr, xzr, !cond（条件真取 1）
    return _enc_csel(labels, pc, "csinc", rd, 31, 31, _COND_INV[cond])


def _enc_csetm(labels, pc, rd, cond):
    # csetm Rd, cond = csinv Rd, xzr, xzr, !cond（条件真取 -1）
    return _enc_csel(labels, pc, "csinv", rd, 31, 31, _COND_INV[cond])


def _enc_cinc(labels, pc, rd, rn, cond):
    return _enc_csel(labels, pc, "csinc", rd, rn, rn, cond)


def _enc_cinv(labels, pc, rd, rn, cond):
    return _enc_csel(labels, pc, "csinv", rd, rn, rn, cond)


def _enc_cneg(labels, pc, rd, rn, cond):
    return _enc_csel(labels, pc, "csneg", rd, rn, rn, cond)


def _enc_bitfield(labels, pc, name, rd, rn, immr, imms):
    # SBFM/UBFM/BFM：sf op 100110 sf immr imms Rn Rd
    # （op=bits[30:29]：00=SBFM，01=BFM，10=UBFM；bit22=sf=N；
    #   immr=[21:16]，imms=[15:10]）。
    sf = 0 if name.endswith("_w") else 1
    base = name.replace("_w", "")
    op = {"sbfm": 0, "bfm": 1, "ubfm": 2}[base]
    return (sf << 31) | (op << 29) | (0b100110 << 23) | (sf << 22) | \
        ((immr & 0x3F) << 16) | \
        ((imms & 0x3F) << 10) | ((rn & 31) << 5) | (rd & 31)


def _enc_bfi(labels, pc, name, rd, rn, lsb, width):
    # BFI/BFC 别名：immr = (regbits - lsb) % regbits，imms = width - 1。
    sf = 0 if name.endswith("_w") else 1
    bits = 32 if name.endswith("_w") else 64
    immr = (bits - lsb) % bits
    return _enc_bitfield(labels, pc, "bfm" if not name.endswith("_w")
                         else "bfm_w", rd, rn, immr, width - 1)


def _enc_bfxil(labels, pc, name, rd, rn, lsb, width):
    # BFXIL 别名：immr = lsb，imms = lsb + width - 1。
    return _enc_bitfield(labels, pc, "bfm" if not name.endswith("_w")
                         else "bfm_w", rd, rn, lsb, lsb + width - 1)


def _enc_madd(labels, pc, name, rd, rn, rm, ra):
    # MADD/MSUB（W/X）+ SMADDL/SMSUBL/UMADDL/UMSUBL：sf M Rm o0 Ra Rn Rd。
    sf = 0 if name.endswith("_w") else 1
    base = name.replace("_w", "")
    if base in ("madd", "msub"):
        m = 0b0011011000
    elif base in ("smaddl", "smsubl"):
        m = 0b0011011001
    else:  # umaddl / umsubl
        m = 0b0011011101
    o0 = 1 if base in ("msub", "smsubl", "umsubl") else 0
    return (sf << 31) | (m << 21) | ((rm & 31) << 16) | (o0 << 15) | \
        ((ra & 31) << 10) | ((rn & 31) << 5) | (rd & 31)


def _enc_umulh(labels, pc, name, rd, rn, rm):
    # SMULH/UMULH：sf=1、Data-processing 3-source 高半乘法，Ra/副操作
    # 字段为 31；bit23 区分有符号/无符号。
    base = 0x9B407C00 if name == "smulh" else 0x9BC07C00
    return base | ((rm & 31) << 16) | ((rn & 31) << 5) | (rd & 31)


_PAIR_MODES = {"offset": 0b010, "pre": 0b011, "post": 0b001}


def _enc_pair_ldst(labels, pc, name, rt, rt2, rn, offset=0, mode="offset"):
    # LDP/STP（offset/pre/post）：size 101 0 mode L imm7 Rt2 Rn Rt。
    # size=bit31（0=W 对，1=X 对）；L=bit22；imm7 = 字节偏移/scale。
    # LDPSW 复用该格式的 size=01/L=1，两个 W 内存元素分别符号扩展到 X。
    if name == "ldpsw":
        scale = 4
        if offset % scale:
            raise ValueError(f"LDPSW 偏移 {offset} 未按 {scale} 字节对齐")
        imm7 = offset // scale
        if not (-64 <= imm7 <= 63):
            raise ValueError(f"LDPSW 偏移超出 ±{64 * scale} 字节: {offset}")
        return (0b01 << 30) | (0b101 << 27) | \
            (_PAIR_MODES[mode] << 23) | (1 << 22) | \
            ((imm7 & 0x7F) << 15) | ((rt2 & 31) << 10) | \
            ((rn & 31) << 5) | (rt & 31)
    ldp = name.startswith("ldp")
    size = 0 if name.endswith("_w") else 1
    scale = 8 if size else 4
    if offset % scale:
        raise ValueError(f"pair 偏移 {offset} 未按 {scale} 字节对齐")
    imm7 = offset // scale
    if not (-64 <= imm7 <= 63):
        raise ValueError(f"pair 偏移超出 ±{64 * scale} 字节: {offset}")
    return (size << 31) | (0b101 << 27) | \
        (_PAIR_MODES[mode] << 23) | (int(ldp) << 22) | \
        ((imm7 & 0x7F) << 15) | ((rt2 & 31) << 10) | ((rn & 31) << 5) | \
        (rt & 31)


def _enc_ldxr(labels, pc, name, rt, rn, lasr=0):
    # LDXR/LDAXR（Load Exclusive，非 pair）：size 001000 010 11111 lasr
    # 11111 Rn Rt。rs（bits[20:16]）与 rt2（bits[14:10]）固定 11111；
    # lasr=1 为 LDAXR（QEMU 单核顺序语义与 LDXR 相同，仅解码区分）。
    size = {"ldxrb": 0, "ldxrh": 1, "ldxr_w": 2, "ldxr": 3,
            "ldaxrb": 0, "ldaxrh": 1, "ldaxr_w": 2, "ldaxr": 3}[name]
    return (size << 30) | (0b001000 << 24) | (0b010 << 21) | \
        (0b11111 << 16) | ((lasr & 1) << 15) | (0b11111 << 10) | \
        ((rn & 31) << 5) | (rt & 31)


def _enc_stxr(labels, pc, name, rs, rt, rn, lasr=0):
    # STXR/STLXR（Store Exclusive，非 pair）：size 001000 000 Rs lasr
    # 11111 Rn Rt。Rs（bits[20:16]）为状态寄存器（成功 0 / 失败 1）；
    # lasr=1 为 STLXR。rt2（bits[14:10]）QEMU 不校验（恒 11111）。
    size = {"stxrb": 0, "stxrh": 1, "stxr_w": 2, "stxr": 3,
            "stlxrb": 0, "stlxrh": 1, "stlxr_w": 2, "stlxr": 3}[name]
    return (size << 30) | (0b001000 << 24) | (0b000 << 21) | \
        ((rs & 31) << 16) | ((lasr & 1) << 15) | (0b11111 << 10) | \
        ((rn & 31) << 5) | (rt & 31)


def _enc_lse(labels, pc, op, size, rt, rs, rn, acquire=0, release=0):
    """LSE 单寄存器原子操作。

    ``op`` 为 add/clear/eor/set/smax/smin/umax/umin/swp；Rt=31
    表示对应 ST* 别名（不写回旧值）。size=0/1/2/3 对应 B/H/W/X。
    acquire/release 分别置 A/R 位，供 LD* / ST* 四种内存序组合定向测试。
    """
    op4 = {"add": 0, "clr": 1, "eor": 2, "set": 3,
           "smax": 4, "smin": 5, "umax": 6, "umin": 7,
           "swp": 8}[op]
    return ((size & 3) << 30) | 0x38200000 | \
        ((acquire & 1) << 23) | ((release & 1) << 22) | \
        ((rs & 31) << 16) | ((op4 & 0xF) << 12) | \
        ((rn & 31) << 5) | (rt & 31)


def _enc_cas(labels, pc, size, rs, rt, rn, acquire=0, release=0):
    """CAS/CASA/CASL/CASAL；Rs 同时是比较输入和旧值输出。"""
    return ((size & 3) << 30) | 0x08A07C00 | \
        ((acquire & 1) << 22) | ((release & 1) << 15) | \
        ((rs & 31) << 16) | ((rn & 31) << 5) | (rt & 31)


def _enc_casp(labels, pc, rs, rt, rn, acquire=0, release=0):
    """CASP/CASPA/CASPL/CASPAL，固定 128 位、寄存器对必须偶数。"""
    return 0x48207C00 | ((acquire & 1) << 22) | ((release & 1) << 15) | \
        ((rs & 31) << 16) | ((rn & 31) << 5) | (rt & 31)


def _enc_lse128(labels, pc, op, rt, rt2, rn, acquire=0, release=0):
    """LDCLRP/LDSETP/SWPP，QEMU ``atomic128`` 固定编码。

    ``rt2`` 是 bits[20:16] 的独立字段，不能按 CASP 的 rt+1 规则推导。
    小端实现中 rt 为低 64 位、rt2 为高 64 位；a/r 只用于覆盖编码，
    RTL/QEMU 当前均按 full barrier 执行。
    """
    op6 = {"clrp": 0b000100, "setp": 0b001100, "swpp": 0b100000}[op]
    return 0x19200000 | ((acquire & 1) << 23) | \
        ((release & 1) << 22) | ((rt2 & 31) << 16) | \
        ((op6 & 0x3F) << 10) | ((rn & 31) << 5) | (rt & 31)


def _enc_clrex(labels, pc):
    return 0xD5033F5F


def _enc_rev(labels, pc, name, rd, rn):
    # RBIT/REV16/REV32/REV/CLZ/CLS（Data-processing 1-source，P6）：
    # sf 1011010110 00000 op2 rn rd
    base = name.replace("_w", "")
    op2 = {"rbit": 0b000000, "rev16": 0b000001, "rev32": 0b000010, "rev": 0b000011,
           "clz": 0b000100, "cls": 0b000101}[base]
    if base == "rev" and name.endswith("_w"):
        op2 = 0b000010   # REV W = REV32（sf=0）别名
    sf = 0 if name.endswith("_w") else 1
    return (sf << 31) | (0b1011010110 << 21) | (op2 << 10) | \
        ((rn & 31) << 5) | (rd & 31)


def _enc_crc32(labels, pc, name, rd, rn, rm):
    """CRC32/CRC32C B/H/W/X：结果始终写 Wd。"""
    variant = name.removeprefix("crc32")
    castagnoli = variant.startswith("c")
    if castagnoli:
        variant = variant[1:]
    size = {"b": 0, "h": 1, "w": 2, "x": 3}[variant]
    sf = 1 if size == 3 else 0
    return (sf << 31) | 0x1AC04000 | (castagnoli << 12) | (size << 10) | \
        ((rm & 31) << 16) | ((rn & 31) << 5) | (rd & 31)


def _enc_ccmp(labels, pc, name, rn, operand, nzcv, cond, reg=False):
    # CCMP/CCMN（条件比较，立即数或寄存器，P6）：
    # sf op 1 11010010 imm5/rm cond imm 0 rn 0 nzcv。
    # bit30：1=CCMP（减）0=CCMN（加）——与汇编器逐字对照确认。
    sf = 0 if name.endswith("_w") else 1
    op = 1 if name.replace("_w", "").startswith("ccmp") else 0
    imm = 0 if reg else 1
    return (sf << 31) | (op << 30) | (1 << 29) | (0b11010010 << 21) | \
        ((operand & 0x1F) << 16) | ((_COND[cond] & 0xF) << 12) | \
        (imm << 11) | ((rn & 31) << 5) | (nzcv & 0xF)


def _enc_bti(labels, pc, kind="c"):
    # BTI c/j/jc 提示（FEAT_BTI；无可见副作用，核按 NOP）
    return {"c": 0xD503245F, "j": 0xD503249F, "jc": 0xD50324DF}[kind]


def _enc_daif(labels, pc, name, imm):
    # MSR DAIFSet/DAIFClr：0xD5034000 | imm<<8 | op2<<5 | 0x1F
    op2 = 0b110 if name == "daifset" else 0b111
    return 0xD5034000 | ((imm & 0xF) << 8) | (op2 << 5) | 0x1F


def _enc_spsel(labels, pc, imm):
    # MSR SPSel：0xD5004000 | imm<<8 | 0b101<<5 | 0x1F
    return 0xD5004000 | ((imm & 1) << 8) | (0b101 << 5) | 0x1F


def _enc_pstate_imm(labels, pc, name, imm):
    # MSR UAO/PAN, #imm：op0=00, op1=000, CRn=4, op2=011/100。
    op2 = 0b011 if name == "msr_uao" else 0b100
    return 0xD5000000 | (4 << 12) | ((imm & 0xF) << 8) | \
        (op2 << 5) | 0x1F


def _enc_ldst_reg(labels, pc, name, rt, rn, rm, shift=0):
    # 寄存器偏移：size 111 0 0000 opc 1 Rm lsl S 10 Rn Rt。
    # opc[1:0]（bits[23:22]）：00=STR，01=LDR，10=符号扩展至 X，
    # 11=符号扩展至 W（LDRSB/LDRSH W 形式）。
    base = name.replace("_reg", "")
    size = {"strb": 0, "ldrb": 0, "ldrsb": 0, "ldrsb_x": 0,
            "strh": 1, "ldrh": 1, "ldrsh": 1, "ldrsh_x": 1,
            "strw": 2, "ldrw": 2, "ldrsw": 2,
            "str": 3, "ldr": 3}[base]
    if base.startswith("str"):
        opc = 0b00
    elif base in ("ldrsw", "ldrsb_x", "ldrsh_x"):
        opc = 0b10
    elif base in ("ldrsb", "ldrsh"):
        opc = 0b11
    else:  # ldr / ldrw / ldrh / ldrb（无符号）
        opc = 0b01
    return (size << 30) | (0b111 << 27) | (opc << 22) | (1 << 21) | \
        ((rm & 31) << 16) | (0b011 << 13) | ((shift & 1) << 12) | \
        (0b10 << 10) | ((rn & 31) << 5) | (rt & 31)


def _enc_addsub_ext(labels, pc, name, rd, rn, rm, opt=0, shift=0):
    # 扩展寄存器 ADD/SUB：sf op 001011001 Rm option imm3 Rn Rd。
    sf = 0 if name.endswith("_w") else 1
    op = 1 if name.startswith("sub") else 0
    return (sf << 31) | (op << 30) | (0b001011001 << 21) | \
        ((rm & 31) << 16) | ((opt & 7) << 13) | ((shift & 7) << 10) | \
        ((rn & 31) << 5) | (rd & 31)


_ENCODERS = {
    "nop": _enc_nop,
    "raw": _enc_raw,
    "wfe": lambda l, p: _enc_wait(l, p, "wfe"),
    "wfi": lambda l, p: _enc_wait(l, p, "wfi"),
    "sev": lambda l, p: _enc_wait(l, p, "sev"),
    "sevl": lambda l, p: _enc_wait(l, p, "sevl"),
    "wfet": lambda l, p, rt: _enc_wfx_t(l, p, "wfet", rt),
    "wfit": lambda l, p, rt: _enc_wfx_t(l, p, "wfit", rt),
    "svc": _enc_svc,
    "hvc": _enc_hvc,
    "smc": _enc_smc,
    "eret": _enc_eret,
    "isb": _enc_isb,
    "dmb": _enc_dmb,
    "dsb": _enc_dsb,
    "ic_ivau": lambda l, p, rt: _sysw(1, 3, 7, 5, 1, rt),
    "ic_iallu": lambda l, p: _sysw(1, 0, 7, 5, 0, 31),
    "dc_ivac": lambda l, p, rt: _sysw(1, 0, 7, 6, 1, rt),
    "dc_isw": lambda l, p, rt: _sysw(1, 0, 7, 6, 2, rt),
    "dc_cvac": lambda l, p, rt: _sysw(1, 3, 7, 10, 1, rt),
    "dc_cvau": lambda l, p, rt: _sysw(1, 3, 7, 11, 1, rt),
    "dc_cvap": lambda l, p, rt: _sysw(1, 3, 7, 12, 1, rt),
    "dc_civac": lambda l, p, rt: _sysw(1, 3, 7, 14, 1, rt),
    "at_s1e1r": lambda l, p, rt: _sysw(1, 0, 7, 8, 0, rt),
    "at_s1e1w": lambda l, p, rt: _sysw(1, 0, 7, 8, 1, rt),
    "at_s1e0r": lambda l, p, rt: _sysw(1, 0, 7, 8, 2, rt),
    "at_s1e0w": lambda l, p, rt: _sysw(1, 0, 7, 8, 3, rt),
    "at_s1e1rp": lambda l, p, rt: _sysw(1, 0, 7, 9, 0, rt),
    "at_s1e1wp": lambda l, p, rt: _sysw(1, 0, 7, 9, 1, rt),
    "tlbi_vmalle1is": lambda l, p: _sysw(1, 0, 8, 3, 0, 31),
    "tlbi_vmalle1": lambda l, p: _sysw(1, 0, 8, 7, 0, 31),
    "tlbi_vae1is": lambda l, p, rt: _sysw(1, 0, 8, 1, 0, rt),
    "udf": _enc_udf,
    "msr_sys": _enc_msr_sys,
    "mrs_sys": _enc_mrs_sys,
    "rdvl": lambda l, p, rd, imm6: _enc_rdvl(l, p, rd, imm6, sme=False),
    "rdsvl": lambda l, p, rd, imm6: _enc_rdvl(l, p, rd, imm6, sme=True),
    "extr": lambda l, p, rd, rn, rm, imm, sf=1: _enc_extr(rd, rn, rm, imm, sf),
    "adc": lambda l, p, rd, rn, rm: _enc_adc(l, p, "adc", rd, rn, rm),
    "adcs": lambda l, p, rd, rn, rm: _enc_adc(l, p, "adcs", rd, rn, rm),
    "sbc": lambda l, p, rd, rn, rm: _enc_adc(l, p, "sbc", rd, rn, rm),
    "sbcs": lambda l, p, rd, rn, rm: _enc_adc(l, p, "sbcs", rd, rn, rm),
    "ngc": lambda l, p, rd, rm: _enc_adc(l, p, "ngc", rd, 31, rm),
    "ngcs": lambda l, p, rd, rm: _enc_adc(l, p, "ngcs", rd, 31, rm),
    "adc_w": lambda l, p, rd, rn, rm: _enc_adc(l, p, "adc_w", rd, rn, rm),
    "adcs_w": lambda l, p, rd, rn, rm: _enc_adc(l, p, "adcs_w", rd, rn, rm),
    "sbc_w": lambda l, p, rd, rn, rm: _enc_adc(l, p, "sbc_w", rd, rn, rm),
    "sbcs_w": lambda l, p, rd, rn, rm: _enc_adc(l, p, "sbcs_w", rd, rn, rm),
    "ngc_w": lambda l, p, rd, rm: _enc_adc(l, p, "ngc_w", rd, 31, rm),
    "ngcs_w": lambda l, p, rd, rm: _enc_adc(l, p, "ngcs_w", rd, 31, rm),
    "ldxp": lambda l, p, rt1, rt2, rn: _enc_ldxp(rt1, rt2, rn),
    "stxp": lambda l, p, rs, rt1, rt2, rn: _enc_stxp(rs, rt1, rt2, rn),
    "stlxp": lambda l, p, rs, rt1, rt2, rn:
        _enc_stxp(rs, rt1, rt2, rn, release=True),
    "add": lambda l, p, rd, rn, i: _enc_addsub_imm(l, p, "add", rd, rn, i),
    "adds": lambda l, p, rd, rn, i: _enc_addsub_imm(l, p, "adds", rd, rn, i),
    "sub": lambda l, p, rd, rn, i: _enc_addsub_imm(l, p, "sub", rd, rn, i),
    "subs": lambda l, p, rd, rn, i: _enc_addsub_imm(l, p, "subs", rd, rn, i),
    "cmp": lambda l, p, rn, i: _enc_addsub_imm(l, p, "cmp", 0, rn, i),
    "cmn": lambda l, p, rn, i: _enc_addsub_imm(l, p, "cmn", 0, rn, i),
    "add_w": lambda l, p, rd, rn, i: _enc_addsub_imm(l, p, "add_w", rd, rn, i),
    "adds_w": lambda l, p, rd, rn, i: _enc_addsub_imm(l, p, "adds_w", rd, rn, i),
    "sub_w": lambda l, p, rd, rn, i: _enc_addsub_imm(l, p, "sub_w", rd, rn, i),
    "subs_w": lambda l, p, rd, rn, i: _enc_addsub_imm(l, p, "subs_w", rd, rn, i),
    "cmp_w": lambda l, p, rn, i: _enc_addsub_imm(l, p, "cmp_w", 0, rn, i),
    "cmn_w": lambda l, p, rn, i: _enc_addsub_imm(l, p, "cmn_w", 0, rn, i),
    "add_reg": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_addsub_reg(l, p, "add", rd, rn, rm, s, a),
    "adds_reg_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_addsub_reg(l, p, "adds_reg_w", rd, rn, rm, s, a),
    "subs_reg": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_addsub_reg(l, p, "subs", rd, rn, rm, s, a),
    "subs_reg_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_addsub_reg(l, p, "subs_reg_w", rd, rn, rm, s, a),
    "and": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "and", rd, rn, rm, s, a),
    "orr": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "orr", rd, rn, rm, s, a),
    "eor": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "eor", rd, rn, rm, s, a),
    "ands": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "ands", rd, rn, rm, s, a),
    "bic": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "bic", rd, rn, rm, s, a),
    "bics": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "bics", rd, rn, rm, s, a),
    "orn": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "orn", rd, rn, rm, s, a),
    "eon": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "eon", rd, rn, rm, s, a),
    "and_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "and_w", rd, rn, rm, s, a),
    "orr_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "orr_w", rd, rn, rm, s, a),
    "eor_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "eor_w", rd, rn, rm, s, a),
    "ands_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "ands_w", rd, rn, rm, s, a),
    "bic_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "bic_w", rd, rn, rm, s, a),
    "bics_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "bics_w", rd, rn, rm, s, a),
    "orn_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "orn_w", rd, rn, rm, s, a),
    "eon_w": lambda l, p, rd, rn, rm, s=0, a=0:
        _enc_logic_reg(l, p, "eon_w", rd, rn, rm, s, a),
    "mul": lambda l, p, rd, rn, rm: _enc_muldiv(l, p, "mul", rd, rn, rm),
    "mul_w": lambda l, p, rd, rn, rm: _enc_muldiv(l, p, "mul_w", rd, rn, rm),
    "udiv": lambda l, p, rd, rn, rm: _enc_muldiv(l, p, "udiv", rd, rn, rm),
    "udiv_w": lambda l, p, rd, rn, rm: _enc_muldiv(l, p, "udiv_w", rd, rn, rm),
    "sdiv": lambda l, p, rd, rn, rm: _enc_muldiv(l, p, "sdiv", rd, rn, rm),
    "sdiv_w": lambda l, p, rd, rn, rm: _enc_muldiv(l, p, "sdiv_w", rd, rn, rm),
    "movz": lambda l, p, rd, i, h=0: _enc_movwide(l, p, "movz", rd, i, h),
    "movk": lambda l, p, rd, i, h=0: _enc_movwide(l, p, "movk", rd, i, h),
    "movn": lambda l, p, rd, i, h=0: _enc_movwide(l, p, "movn", rd, i, h),
    "movz_w": lambda l, p, rd, i, h=0: _enc_movwide(l, p, "movz_w", rd, i, h),
    "movk_w": lambda l, p, rd, i, h=0: _enc_movwide(l, p, "movk_w", rd, i, h),
    "movn_w": lambda l, p, rd, i, h=0: _enc_movwide(l, p, "movn_w", rd, i, h),
    "str": lambda l, p, rt, rn, i: _enc_ldst(l, p, "str", rt, rn, i),
    "strw": lambda l, p, rt, rn, i: _enc_ldst(l, p, "strw", rt, rn, i),
    "strh": lambda l, p, rt, rn, i: _enc_ldst(l, p, "strh", rt, rn, i),
    "strb": lambda l, p, rt, rn, i: _enc_ldst(l, p, "strb", rt, rn, i),
    "ldr": lambda l, p, rt, rn, i: _enc_ldst(l, p, "ldr", rt, rn, i),
    "ldrw": lambda l, p, rt, rn, i: _enc_ldst(l, p, "ldrw", rt, rn, i),
    "ldrh": lambda l, p, rt, rn, i: _enc_ldst(l, p, "ldrh", rt, rn, i),
    "ldrb": lambda l, p, rt, rn, i: _enc_ldst(l, p, "ldrb", rt, rn, i),
    "ldrsw": _enc_ldrsw,
    "stur": _enc_stur,
    "sttr": lambda l, p, rt, rn, i: _enc_ldtr(rt, rn, i, 3, 0),
    "ldtr": lambda l, p, rt, rn, i: _enc_ldtr(rt, rn, i, 3, 1),
    "ldur": _enc_ldur_x,
    "sturw": _enc_sturw,
    "ldurw": _enc_ldurw,
    "sturh": _enc_sturh,
    "ldurh": _enc_ldurh,
    "sturb": _enc_sturb,
    "ldurb": _enc_ldurb,
    "ldursw": _enc_ldursw,
    "ldursb": _enc_ldursb,
    "ldursh": _enc_ldursh,
    "ldursb_w": _enc_ldursb_w,
    "ldursh_w": _enc_ldursh_w,
    # LDR/STR 单寄存器 pre/post-index（P6 Linux 启动实证缺口）
    "ldr_post": _enc_ldr_post,
    "str_post": _enc_str_post,
    "ldrw_post": _enc_ldrw_post,
    "strw_post": _enc_strw_post,
    "ldrh_post": _enc_ldrh_post,
    "strh_post": _enc_strh_post,
    "ldrb_post": _enc_ldrb_post,
    "strb_post": _enc_strb_post,
    "ldrsw_post": _enc_ldrsw_post,
    "ldrsb_post": _enc_ldrsb_post,
    "ldrsh_post": _enc_ldrsh_post,
    "ldrsb_w_post": _enc_ldrsb_w_post,
    "ldrsh_w_post": _enc_ldrsh_w_post,
    "ldr_pre": _enc_ldr_pre,
    "str_pre": _enc_str_pre,
    "ldrw_pre": _enc_ldrw_pre,
    "strw_pre": _enc_strw_pre,
    "ldrh_pre": _enc_ldrh_pre,
    "strh_pre": _enc_strh_pre,
    "ldrb_pre": _enc_ldrb_pre,
    "strb_pre": _enc_strb_pre,
    "ldrsw_pre": _enc_ldrsw_pre,
    "ldrsb_pre": _enc_ldrsb_pre,
    "ldrsh_pre": _enc_ldrsh_pre,
    "ldrsb_w_pre": _enc_ldrsb_w_pre,
    "ldrsh_w_pre": _enc_ldrsh_w_pre,
    "dc_zva": lambda l, p, rt: _sysw(1, 3, 7, 4, 1, rt),
    "msr_pan": lambda l, p, imm: _enc_pstate_imm(l, p, "msr_pan", imm),
    "lslv": lambda l, p, rd, rn, rm: _enc_vshift(l, p, "lslv", rd, rn, rm),
    "lsrv": lambda l, p, rd, rn, rm: _enc_vshift(l, p, "lsrv", rd, rn, rm),
    "asrv": lambda l, p, rd, rn, rm: _enc_vshift(l, p, "asrv", rd, rn, rm),
    "rorv": lambda l, p, rd, rn, rm: _enc_vshift(l, p, "rorv", rd, rn, rm),
    "lslv_w": lambda l, p, rd, rn, rm: _enc_vshift(l, p, "lslv_w", rd, rn, rm),
    "lsrv_w": lambda l, p, rd, rn, rm: _enc_vshift(l, p, "lsrv_w", rd, rn, rm),
    "asrv_w": lambda l, p, rd, rn, rm: _enc_vshift(l, p, "asrv_w", rd, rn, rm),
    "rorv_w": lambda l, p, rd, rn, rm: _enc_vshift(l, p, "rorv_w", rd, rn, rm),
    "ldr_w_lit": lambda l, p, rt, t: _enc_ldr_lit(l, p, "ldr_w_lit", rt, t),
    "ldr_lit": lambda l, p, rt, t: _enc_ldr_lit(l, p, "ldr_lit", rt, t),
    "ldrsw_lit": lambda l, p, rt, t: _enc_ldr_lit(l, p, "ldrsw_lit", rt, t),
    "prfm_lit": lambda l, p, rt, t: _enc_ldr_lit(l, p, "prfm_lit", rt, t),
    "csel": lambda l, p, rd, rn, rm, c: _enc_csel(l, p, "csel", rd, rn, rm, c),
    "csel_w": lambda l, p, rd, rn, rm, c:
        _enc_csel(l, p, "csel_w", rd, rn, rm, c),
    "csinc": lambda l, p, rd, rn, rm, c:
        _enc_csel(l, p, "csinc", rd, rn, rm, c),
    "cset": _enc_cset,
    "csetm": _enc_csetm,
    "cinc": _enc_cinc,
    "cinv": _enc_cinv,
    "cneg": _enc_cneg,
    "csinc_w": lambda l, p, rd, rn, rm, c:
        _enc_csel(l, p, "csinc_w", rd, rn, rm, c),
    "csinv": lambda l, p, rd, rn, rm, c:
        _enc_csel(l, p, "csinv", rd, rn, rm, c),
    "csinv_w": lambda l, p, rd, rn, rm, c:
        _enc_csel(l, p, "csinv_w", rd, rn, rm, c),
    "csneg": lambda l, p, rd, rn, rm, c:
        _enc_csel(l, p, "csneg", rd, rn, rm, c),
    "csneg_w": lambda l, p, rd, rn, rm, c:
        _enc_csel(l, p, "csneg_w", rd, rn, rm, c),
    "sbfm": lambda l, p, rd, rn, r, s:
        _enc_bitfield(l, p, "sbfm", rd, rn, r, s),
    "sbfm_w": lambda l, p, rd, rn, r, s:
        _enc_bitfield(l, p, "sbfm_w", rd, rn, r, s),
    "ubfm": lambda l, p, rd, rn, r, s:
        _enc_bitfield(l, p, "ubfm", rd, rn, r, s),
    "ubfm_w": lambda l, p, rd, rn, r, s:
        _enc_bitfield(l, p, "ubfm_w", rd, rn, r, s),
    "bfm": lambda l, p, rd, rn, r, s:
        _enc_bitfield(l, p, "bfm", rd, rn, r, s),
    "bfm_w": lambda l, p, rd, rn, r, s:
        _enc_bitfield(l, p, "bfm_w", rd, rn, r, s),
    "bfi": lambda l, p, rd, rn, b, w: _enc_bfi(l, p, "bfi", rd, rn, b, w),
    "bfi_w": lambda l, p, rd, rn, b, w:
        _enc_bfi(l, p, "bfi_w", rd, rn, b, w),
    "bfxil": lambda l, p, rd, rn, b, w:
        _enc_bfxil(l, p, "bfxil", rd, rn, b, w),
    "bfxil_w": lambda l, p, rd, rn, b, w:
        _enc_bfxil(l, p, "bfxil_w", rd, rn, b, w),
    "madd": lambda l, p, rd, rn, rm, ra:
        _enc_madd(l, p, "madd", rd, rn, rm, ra),
    "madd_w": lambda l, p, rd, rn, rm, ra:
        _enc_madd(l, p, "madd_w", rd, rn, rm, ra),
    "msub": lambda l, p, rd, rn, rm, ra:
        _enc_madd(l, p, "msub", rd, rn, rm, ra),
    "msub_w": lambda l, p, rd, rn, rm, ra:
        _enc_madd(l, p, "msub_w", rd, rn, rm, ra),
    "smaddl": lambda l, p, rd, rn, rm, ra:
        _enc_madd(l, p, "smaddl", rd, rn, rm, ra),
    "smsubl": lambda l, p, rd, rn, rm, ra:
        _enc_madd(l, p, "smsubl", rd, rn, rm, ra),
    "umaddl": lambda l, p, rd, rn, rm, ra:
        _enc_madd(l, p, "umaddl", rd, rn, rm, ra),
    "umsubl": lambda l, p, rd, rn, rm, ra:
        _enc_madd(l, p, "umsubl", rd, rn, rm, ra),
    "umulh": lambda l, p, rd, rn, rm:
        _enc_umulh(l, p, "umulh", rd, rn, rm),
    "smulh": lambda l, p, rd, rn, rm:
        _enc_umulh(l, p, "smulh", rd, rn, rm),
    "stp": lambda l, p, rt, rt2, rn, o=0, m="offset":
        _enc_pair_ldst(l, p, "stp", rt, rt2, rn, o, m),
    "ldp": lambda l, p, rt, rt2, rn, o=0, m="offset":
        _enc_pair_ldst(l, p, "ldp", rt, rt2, rn, o, m),
    "stp_w": lambda l, p, rt, rt2, rn, o=0, m="offset":
        _enc_pair_ldst(l, p, "stp_w", rt, rt2, rn, o, m),
    "ldp_w": lambda l, p, rt, rt2, rn, o=0, m="offset":
        _enc_pair_ldst(l, p, "ldp_w", rt, rt2, rn, o, m),
    "ldpsw": lambda l, p, rt, rt2, rn, o=0, m="offset":
        _enc_pair_ldst(l, p, "ldpsw", rt, rt2, rn, o, m),
    "ldxrb": lambda l, p, rt, rn: _enc_ldxr(l, p, "ldxrb", rt, rn),
    "ldxrh": lambda l, p, rt, rn: _enc_ldxr(l, p, "ldxrh", rt, rn),
    "ldxr_w": lambda l, p, rt, rn: _enc_ldxr(l, p, "ldxr_w", rt, rn),
    "ldxr": lambda l, p, rt, rn: _enc_ldxr(l, p, "ldxr", rt, rn),
    "ldaxrb": lambda l, p, rt, rn: _enc_ldxr(l, p, "ldaxrb", rt, rn, 1),
    "ldaxrh": lambda l, p, rt, rn: _enc_ldxr(l, p, "ldaxrh", rt, rn, 1),
    "ldaxr_w": lambda l, p, rt, rn: _enc_ldxr(l, p, "ldaxr_w", rt, rn, 1),
    "ldaxr": lambda l, p, rt, rn: _enc_ldxr(l, p, "ldaxr", rt, rn, 1),
    "stxrb": lambda l, p, rs, rt, rn: _enc_stxr(l, p, "stxrb", rs, rt, rn),
    "stxrh": lambda l, p, rs, rt, rn: _enc_stxr(l, p, "stxrh", rs, rt, rn),
    "stxr_w": lambda l, p, rs, rt, rn: _enc_stxr(l, p, "stxr_w", rs, rt, rn),
    "stxr": lambda l, p, rs, rt, rn: _enc_stxr(l, p, "stxr", rs, rt, rn),
    "stlxrb": lambda l, p, rs, rt, rn: _enc_stxr(l, p, "stlxrb", rs, rt, rn, 1),
    "stlxrh": lambda l, p, rs, rt, rn: _enc_stxr(l, p, "stlxrh", rs, rt, rn, 1),
    "stlxr_w": lambda l, p, rs, rt, rn: _enc_stxr(l, p, "stlxr_w", rs, rt, rn, 1),
    "stlxr": lambda l, p, rs, rt, rn: _enc_stxr(l, p, "stlxr", rs, rt, rn, 1),
    "lse": lambda l, p, op, size, rt, rs, rn, a=0, r=0:
        _enc_lse(l, p, op, size, rt, rs, rn, a, r),
    "cas": lambda l, p, size, rs, rt, rn, a=0, r=0:
        _enc_cas(l, p, size, rs, rt, rn, a, r),
    "casp": lambda l, p, rs, rt, rn, a=0, r=0:
        _enc_casp(l, p, rs, rt, rn, a, r),
    "lse128": lambda l, p, op, rt, rt2, rn, a=0, r=0:
        _enc_lse128(l, p, op, rt, rt2, rn, a, r),
    "clrex": _enc_clrex,
    "rev16": lambda l, p, rd, rn: _enc_rev(l, p, "rev16", rd, rn),
    "rev16_w": lambda l, p, rd, rn: _enc_rev(l, p, "rev16_w", rd, rn),
    "rev32": lambda l, p, rd, rn: _enc_rev(l, p, "rev32", rd, rn),
    "rev": lambda l, p, rd, rn: _enc_rev(l, p, "rev", rd, rn),
    "rev_w": lambda l, p, rd, rn: _enc_rev(l, p, "rev_w", rd, rn),
    "crc32b": lambda l, p, rd, rn, rm: _enc_crc32(l, p, "crc32b", rd, rn, rm),
    "crc32h": lambda l, p, rd, rn, rm: _enc_crc32(l, p, "crc32h", rd, rn, rm),
    "crc32w": lambda l, p, rd, rn, rm: _enc_crc32(l, p, "crc32w", rd, rn, rm),
    "crc32x": lambda l, p, rd, rn, rm: _enc_crc32(l, p, "crc32x", rd, rn, rm),
    "crc32cb": lambda l, p, rd, rn, rm: _enc_crc32(l, p, "crc32cb", rd, rn, rm),
    "crc32ch": lambda l, p, rd, rn, rm: _enc_crc32(l, p, "crc32ch", rd, rn, rm),
    "crc32cw": lambda l, p, rd, rn, rm: _enc_crc32(l, p, "crc32cw", rd, rn, rm),
    "crc32cx": lambda l, p, rd, rn, rm: _enc_crc32(l, p, "crc32cx", rd, rn, rm),
    "clz": lambda l, p, rd, rn: _enc_rev(l, p, "clz", rd, rn),
    "clz_w": lambda l, p, rd, rn: _enc_rev(l, p, "clz_w", rd, rn),
    "cls": lambda l, p, rd, rn: _enc_rev(l, p, "cls", rd, rn),
    "cls_w": lambda l, p, rd, rn: _enc_rev(l, p, "cls_w", rd, rn),
    "rbit": lambda l, p, rd, rn: _enc_rev(l, p, "rbit", rd, rn),
    "rbit_w": lambda l, p, rd, rn: _enc_rev(l, p, "rbit_w", rd, rn),
    "ccmp": lambda l, p, rn, i, n, c:
        _enc_ccmp(l, p, "ccmp", rn, i, n, c),
    "ccmp_w": lambda l, p, rn, i, n, c:
        _enc_ccmp(l, p, "ccmp_w", rn, i, n, c),
    "ccmn": lambda l, p, rn, i, n, c:
        _enc_ccmp(l, p, "ccmn", rn, i, n, c),
    "ccmn_w": lambda l, p, rn, i, n, c:
        _enc_ccmp(l, p, "ccmn_w", rn, i, n, c),
    "ccmp_reg": lambda l, p, rn, rm, n, c:
        _enc_ccmp(l, p, "ccmp", rn, rm, n, c, True),
    "ccmp_reg_w": lambda l, p, rn, rm, n, c:
        _enc_ccmp(l, p, "ccmp_w", rn, rm, n, c, True),
    "ccmn_reg": lambda l, p, rn, rm, n, c:
        _enc_ccmp(l, p, "ccmn", rn, rm, n, c, True),
    "ccmn_reg_w": lambda l, p, rn, rm, n, c:
        _enc_ccmp(l, p, "ccmn_w", rn, rm, n, c, True),
    "bti": lambda l, p, k="c": _enc_bti(l, p, k),
    "daifset": lambda l, p, i: _enc_daif(l, p, "daifset", i),
    "daifclr": lambda l, p, i: _enc_daif(l, p, "daifclr", i),
    "spsel": lambda l, p, i: _enc_spsel(l, p, i),
    "str_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "str_reg", rt, rn, rm, s),
    "ldr_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldr_reg", rt, rn, rm, s),
    "strw_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "strw_reg", rt, rn, rm, s),
    "ldrw_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldrw_reg", rt, rn, rm, s),
    "strh_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "strh_reg", rt, rn, rm, s),
    "ldrh_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldrh_reg", rt, rn, rm, s),
    "strb_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "strb_reg", rt, rn, rm, s),
    "ldrb_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldrb_reg", rt, rn, rm, s),
    "ldrsw_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldrsw_reg", rt, rn, rm, s),
    "ldrsb_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldrsb_reg", rt, rn, rm, s),
    "ldrsb_x_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldrsb_x_reg", rt, rn, rm, s),
    "ldrsh_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldrsh_reg", rt, rn, rm, s),
    "ldrsh_x_reg": lambda l, p, rt, rn, rm, s=0:
        _enc_ldst_reg(l, p, "ldrsh_x_reg", rt, rn, rm, s),
    "add_ext": lambda l, p, rd, rn, rm, o=0, s=0:
        _enc_addsub_ext(l, p, "add_ext", rd, rn, rm, o, s),
    "add_ext_w": lambda l, p, rd, rn, rm, o=0, s=0:
        _enc_addsub_ext(l, p, "add_ext_w", rd, rn, rm, o, s),
    "sub_ext": lambda l, p, rd, rn, rm, o=0, s=0:
        _enc_addsub_ext(l, p, "sub_ext", rd, rn, rm, o, s),
    "sub_ext_w": lambda l, p, rd, rn, rm, o=0, s=0:
        _enc_addsub_ext(l, p, "sub_ext_w", rd, rn, rm, o, s),
    "b": lambda l, p, t: _enc_b(l, p, "b", t),
    "bl": lambda l, p, t: _enc_b(l, p, "bl", t),
    "b_cond": lambda l, p, c, t: _enc_b_cond(l, p, c, t),
    "cbz": lambda l, p, rt, t: _enc_cbz(l, p, "cbz", rt, t),
    "cbnz": lambda l, p, rt, t: _enc_cbz(l, p, "cbnz", rt, t),
    "tbz": lambda l, p, rt, b, t: _enc_tbz(l, p, "tbz", rt, b, t),
    "tbnz": lambda l, p, rt, b, t: _enc_tbz(l, p, "tbnz", rt, b, t),
    "br": lambda l, p, rn: _enc_br(l, p, "br", rn),
    "blr": lambda l, p, rn: _enc_br(l, p, "blr", rn),
    "ret": lambda l, p, rn=30: _enc_br(l, p, "ret", rn),
    "adr": lambda l, p, rd, t: _enc_adr(l, p, "adr", rd, t),
    "adrp": lambda l, p, rd, t: _enc_adr(l, p, "adrp", rd, t),
}


def assemble(insns, base=0):
    """两遍汇编：先定标签地址，再编码。返回 32 位指令字列表。"""
    pcs = []
    pc = base
    for insn in insns:
        pcs.append(pc)
        if insn.name != "label":
            pc += 4
    labels = {insn.args[0]: pcs[i]
              for i, insn in enumerate(insns) if insn.name == "label"}
    words = []
    for insn, addr in zip(insns, pcs):
        if insn.name != "label":
            words.append(insn.encode(labels, addr))
    return words
