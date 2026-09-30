"""lcvex_alu 单元测试：算术/逻辑/移位与 NZCV。"""

import cocotb
from cocotb.triggers import Timer

OP = {"ADD": 0, "SUB": 1, "AND": 2, "ORR": 3, "EOR": 4,
      "LSL": 5, "LSR": 6, "ASR": 7, "ROR": 28, "BFM": 20,
      "RBIT": 30, "CRC": 32}


_DEFAULTS = {
    "op": 0, "a": 0, "b": 0, "c": 0,
    "use_shift": 0, "shift_type": 0, "shift_amt": 0,
    "inv_b": 0, "ccmp_nzcv_else": 0, "ccmp_taken": 0,
    "cin": 0, "is_32": 0,
}


async def drive(dut, **kw):
    for name, val in _DEFAULTS.items():
        getattr(dut, name).value = val
    for name, val in kw.items():
        getattr(dut, name).value = val
    await Timer(1, unit="ns")


@cocotb.test()
async def test_add_carry_zero(dut):
    await drive(dut, op=OP["ADD"], a=0xFFFFFFFFFFFFFFFF, b=1,
                use_shift=0, shift_type=0, shift_amt=0, is_32=0)
    assert int(dut.result.value) == 0, "0xffff...+1 应为 0"
    assert int(dut.flag_c.value) == 1, "进位应为 1"
    assert int(dut.flag_z.value) == 1, "结果为零，Z=1"
    assert int(dut.flag_v.value) == 0, "无符号溢出，V=0"


@cocotb.test()
async def test_sub_borrow(dut):
    await drive(dut, op=OP["SUB"], a=0, b=1,
                use_shift=0, shift_type=0, shift_amt=0, is_32=0)
    assert int(dut.result.value) == 0xFFFFFFFFFFFFFFFF
    assert int(dut.flag_c.value) == 0, "借位时 C=0"
    assert int(dut.flag_n.value) == 1, "结果为负，N=1"
    assert int(dut.flag_v.value) == 0


@cocotb.test()
async def test_add32_zero_extend(dut):
    await drive(dut, op=OP["ADD"], a=0xFFFFFFFF, b=1,
                use_shift=0, shift_type=0, shift_amt=0, is_32=1)
    assert int(dut.result.value) == 0, "32 位加法结果应为 0（高 32 位清零）"
    assert int(dut.flag_c.value) == 1, "32 位进位"
    assert int(dut.flag_z.value) == 1


@cocotb.test()
async def test_add_signed_overflow(dut):
    await drive(dut, op=OP["ADD"], a=0x7FFFFFFFFFFFFFFF, b=1,
                use_shift=0, shift_type=0, shift_amt=0, is_32=0)
    assert int(dut.flag_v.value) == 1, "正溢出 V=1"
    assert int(dut.flag_n.value) == 1, "结果符号翻转 N=1"


@cocotb.test()
async def test_sub_signed_overflow(dut):
    await drive(dut, op=OP["SUB"], a=0x8000000000000000, b=1,
                use_shift=0, shift_type=0, shift_amt=0, is_32=0)
    assert int(dut.flag_v.value) == 1, "负溢出 V=1"


@cocotb.test()
async def test_logic_flags(dut):
    await drive(dut, op=OP["AND"], a=0xF0F0, b=0x0F0F,
                use_shift=0, shift_type=0, shift_amt=0, is_32=0)
    assert int(dut.result.value) == 0
    assert int(dut.flag_z.value) == 1, "逻辑零 Z=1"
    assert int(dut.flag_c.value) == 0, "逻辑指令 C=0（核心保留旧值）"
    assert int(dut.flag_v.value) == 0


@cocotb.test()
async def test_shifts(dut):
    await drive(dut, op=OP["LSL"], a=0, b=0x1,
                use_shift=1, shift_type=0, shift_amt=4, is_32=0)
    assert int(dut.result.value) == 0x10, "LSL #4"
    await drive(dut, op=OP["LSR"], a=0, b=0x100,
                use_shift=1, shift_type=1, shift_amt=4, is_32=0)
    assert int(dut.result.value) == 0x10, "LSR #4"
    await drive(dut, op=OP["ASR"], a=0, b=0x8000000000000000,
                use_shift=1, shift_type=2, shift_amt=4, is_32=0)
    assert int(dut.result.value) == 0xF800000000000000, "ASR 符号扩展"


@cocotb.test()
async def test_ror_64_and_32(dut):
    # BASE-DP-018 的 ALU 旋转基础：移位单元已支持 ROR，64/32 位都需验证。
    await drive(dut, op=OP["ROR"], a=0, b=0x8000000000000001,
                use_shift=1, shift_type=3, shift_amt=1, is_32=0)
    assert int(dut.result.value) == 0xC000000000000000, "X ROR #1"
    await drive(dut, op=OP["ROR"], a=0, b=0x8000000000000001,
                use_shift=1, shift_type=3, shift_amt=63, is_32=0)
    assert int(dut.result.value) == 0x3, "X ROR #63"
    await drive(dut, op=OP["ROR"], a=0, b=0x80000001,
                use_shift=1, shift_type=3, shift_amt=8, is_32=1)
    assert int(dut.result.value) == 0x01800000, "W ROR #8 零扩展"


@cocotb.test()
async def test_logic_ror_with_inverted_b(dut):
    # 逻辑移位寄存器 ROR 后续与 inv_b 组合（BIC/ORN/EON 路径）。
    await drive(dut, op=OP["ORR"], a=0x8000000000000001,
                b=0x8000000000000001, inv_b=0,
                use_shift=1, shift_type=3, shift_amt=1, is_32=0)
    assert int(dut.result.value) == 0xC000000000000001, "ORR X, X, X, ROR #1"
    # EON: a ^ ~(b ROR #8)，b=0xFF -> ROR=0xFF00000000000000
    # 全 1 ^ 0x00FFFFFFFFFFFFFF = 0xFF00000000000000
    await drive(dut, op=OP["EOR"], a=0xFFFFFFFFFFFFFFFF,
                b=0x00000000000000FF, inv_b=1,
                use_shift=1, shift_type=3, shift_amt=8, is_32=0)
    assert int(dut.result.value) == 0xFF00000000000000, "EON ROR #8"


@cocotb.test()
async def test_rbit_wide_and_word(dut):
    await drive(dut, op=OP["RBIT"], a=1, b=0,
                use_shift=0, shift_type=0, shift_amt=0, is_32=0)
    assert int(dut.result.value) == 0x8000000000000000, "RBIT X"
    await drive(dut, op=OP["RBIT"], a=1, b=0,
                use_shift=0, shift_type=0, shift_amt=0, is_32=1)
    assert int(dut.result.value) == 0x0000000080000000, "RBIT W 零扩展"


@cocotb.test()
async def test_bfm_insert(dut):
    # bfi x0, x1, #4, #8：immr=(64-4)&63=60, imms=7 -> x0[11:4]=x1[7:0]
    await drive(dut, op=OP["BFM"], a=0xAB, b=(60 << 6) | 7,
                c=0xFFFFFFFFFFFFFFFF,
                use_shift=0, shift_type=0, shift_amt=0, is_32=0)
    assert int(dut.result.value) == 0xFFFFFFFFFFFFFABF, "BFI 插入字段保留其余位"


@cocotb.test()
async def test_bfm_extract_insert(dut):
    # bfxil x0, x1, #4, #8：immr=4, imms=11 -> x0[7:0]=x1[11:4]
    await drive(dut, op=OP["BFM"], a=0xABCD, b=(4 << 6) | 11,
                c=0xFFFFFFFFFFFFFFFF,
                use_shift=0, shift_type=0, shift_amt=0, is_32=0)
    assert int(dut.result.value) == 0xFFFFFFFFFFFFFFBC, "BFXIL 低字段替换"


@cocotb.test()
async def test_bfm32_zero_extend(dut):
    # bfi w0, w1, #16, #16：immr=(32-16)&31=16, imms=15，高 32 位清零
    await drive(dut, op=OP["BFM"], a=0x1234, b=(16 << 6) | 15,
                c=0,
                use_shift=0, shift_type=0, shift_amt=0, is_32=1)
    assert int(dut.result.value) == 0x12340000, "W 形式高 32 位清零"


@cocotb.test()
async def test_sub32_no_borrow(dut):
    await drive(dut, op=OP["SUB"], a=5, b=1,
                use_shift=0, shift_type=0, shift_amt=0, is_32=1)
    assert int(dut.result.value) == 4
    assert int(dut.flag_c.value) == 1, "无借位 C=1"


@cocotb.test()
async def test_crc32_and_crc32c_all_widths(dut):
    values = {
        False: [0x1D48EF9B, 0x8215BC2E, 0x10472A38, 0xBBC41DB8],
        True:  [0x10A13890, 0xEE1D3738, 0xEE8C8012, 0x9A4F27DC],
    }
    for castagnoli, expected in values.items():
        for size, want in enumerate(expected):
            await drive(dut, op=OP["CRC"], a=0xFFFFFFFF,
                        b=0x0123456789ABCDEF, c=0,
                        use_shift=0, shift_type=0, shift_amt=size,
                        inv_b=int(castagnoli), ccmp_nzcv_else=0,
                        ccmp_taken=0, is_32=1)
            assert int(dut.result.value) == want, \
                f"CRC size={size} C={castagnoli}: {int(dut.result.value):#x}"
