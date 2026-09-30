"""LCVEX 锁步差分二进制协议的 Python 镜像。

与 qemu/plugins/lcvex_protocol.h 保持一一对应（1 字节对齐，little-endian）。
供 Q6 harness 等 Python 工具使用；C 端结构变化时必须同步修改。
"""

import struct

LCVEX_MSG_MAGIC = 0x5446444C  # 'LDFT'
LCVEX_MSG_VERSION = 1

LCVEX_MSG_HELLO = 1
LCVEX_MSG_CONFIG = 2
LCVEX_MSG_INIT = 3
LCVEX_MSG_PRE = 4
LCVEX_MSG_GO = 5
LCVEX_MSG_COMMIT = 6
LCVEX_MSG_ACK = 7
LCVEX_MSG_DISCON = 8
LCVEX_MSG_STOP = 9
LCVEX_MSG_EXIT = 10
LCVEX_MSG_CKPT_REQ = 11
LCVEX_MSG_CKPT_READY = 12
LCVEX_MSG_ASYNC = 13
LCVEX_MSG_WAIT = 14
LCVEX_MSG_WAIT_RESUME = 15
LCVEX_MSG_FP_INIT = 16
LCVEX_MSG_FP_COMMIT = 17
LCVEX_MSG_P7_REJECT = 18

LCVEX_CFG_CAP_FP_NEON = 0x80000000
LCVEX_FP_FEATURE_NEON = 0x00000001
LCVEX_FP_VECTOR_BYTES = 16
LCVEX_FP_INIT_BYTES = 520
LCVEX_FP_COMMIT_HEADER_BYTES = 16
LCVEX_FP_COMMIT_MAX_BYTES = 528
LCVEX_FP_MAX_VECTORS = 4
LCVEX_FP_FILE_BYTES = 552
LCVEX_FP_FLAG_FPCR_CHANGED = 1 << 0
LCVEX_FP_FLAG_FPSR_CHANGED = 1 << 1
LCVEX_FP_FLAGS_MASK = LCVEX_FP_FLAG_FPCR_CHANGED | LCVEX_FP_FLAG_FPSR_CHANGED

LCVEX_P7_REJECT_NO_CAP = 1
LCVEX_P7_REJECT_DESCRIPTOR = 2
LCVEX_P7_REJECT_PROFILE = 3
LCVEX_P7_REJECT_UPPER_NONZERO = 4
LCVEX_P7_REJECT_PROTOCOL_LENGTH = 5

LCVEX_ACK_OK = 0
LCVEX_ACK_FAIL = 1

LCVEX_MAX_STORES = 8

# 固定头：magic, version, type, flags, payload_len, seq
MSG_HEADER = struct.Struct("<IHHIIQ")

# 架构状态：pc, next_pc, insn, x[31], sp, nzcv
LCVEX_STATE = struct.Struct("<QQI31QQI")

# 提交包：post + 写回事件 + 异常 + exclusive 监视器 + store 列表
# 与 lcvex_protocol.h 的 lcvex_commit 逐字段对应（1 字节对齐）：
#   post(280) B*4 Q Q I B 7x I Q I I B B 6x Q Q Q I + stores(8*(Q Q B 7x))
LCVEX_COMMIT = struct.Struct("<QQI31QQIBBBBQQIB7xIQIIBB6xQQQI" +
                             "QQB7x" * LCVEX_MAX_STORES)

LCVEX_PRE = struct.Struct("<QQI31QQI")  # 与 LCVEX_STATE 相同
LCVEX_ACK = struct.Struct("<II256s")
LCVEX_HELLO = struct.Struct("<IIIIII")
LCVEX_CONFIG = struct.Struct("<IQII")
LCVEX_DISCON = struct.Struct("<IIQQ")
LCVEX_EXIT = struct.Struct("<IIQ")
LCVEX_WAIT_RESUME = struct.Struct("<Q")
LCVEX_CKPT_REQ = struct.Struct("<512s512s512s512s")
LCVEX_CKPT_READY = struct.Struct("<i256s")
LCVEX_FP_STATE = struct.Struct("<II" + "QQ" * 32)
LCVEX_FP_COMMIT_HEADER = struct.Struct("<IIII")
LCVEX_FP_FILE = struct.Struct("<8sIIIIQII" + "QQ" * 32)

FP_FILE_MAGIC = b"LCVXFP01"
FP_FILE_VERSION = 1


class ProtocolError(ValueError):
    """协议帧、FP delta 或 checkpoint sidecar 不符合冻结 ABI。"""


_FIXED_PAYLOAD_SIZES = {
    LCVEX_MSG_HELLO: LCVEX_HELLO.size,
    LCVEX_MSG_CONFIG: LCVEX_CONFIG.size,
    LCVEX_MSG_INIT: LCVEX_STATE.size,
    LCVEX_MSG_PRE: LCVEX_PRE.size,
    LCVEX_MSG_GO: 0,
    LCVEX_MSG_COMMIT: LCVEX_COMMIT.size,
    LCVEX_MSG_ACK: LCVEX_ACK.size,
    LCVEX_MSG_DISCON: LCVEX_DISCON.size,
    LCVEX_MSG_STOP: 0,
    LCVEX_MSG_EXIT: LCVEX_EXIT.size,
    LCVEX_MSG_CKPT_REQ: LCVEX_CKPT_REQ.size,
    LCVEX_MSG_CKPT_READY: LCVEX_CKPT_READY.size,
    LCVEX_MSG_ASYNC: LCVEX_COMMIT.size,
    LCVEX_MSG_WAIT: 0,
    LCVEX_MSG_WAIT_RESUME: LCVEX_WAIT_RESUME.size,
    LCVEX_MSG_FP_INIT: LCVEX_FP_STATE.size,
    LCVEX_MSG_P7_REJECT: 8,
}


def fp_mask_popcount(v_mask):
    if not isinstance(v_mask, int) or v_mask < 0 or v_mask > 0xffffffff:
        raise ProtocolError("v_mask 必须是 uint32")
    return v_mask.bit_count()


def fp_commit_payload_size(v_mask):
    count = fp_mask_popcount(v_mask)
    if count > LCVEX_FP_MAX_VECTORS:
        raise ProtocolError("v_mask popcount 超过 4")
    return LCVEX_FP_COMMIT_HEADER_BYTES + 16 * count


def validate_fp_commit_payload(payload, previous=None):
    """严格解码 FP_COMMIT；可选 previous 用于检查 unchanged 字段。"""

    if not isinstance(payload, (bytes, bytearray, memoryview)):
        raise ProtocolError("FP_COMMIT payload 必须是 bytes")
    payload = bytes(payload)
    if len(payload) < LCVEX_FP_COMMIT_HEADER_BYTES:
        raise ProtocolError("FP_COMMIT payload 不足 16B")
    flags, v_mask, fpcr, fpsr = LCVEX_FP_COMMIT_HEADER.unpack_from(payload)
    if flags & ~LCVEX_FP_FLAGS_MASK:
        raise ProtocolError("FP_COMMIT flags 含保留位")
    count = fp_mask_popcount(v_mask)
    expected = LCVEX_FP_COMMIT_HEADER_BYTES + 16 * count
    if expected != len(payload) or expected > LCVEX_FP_COMMIT_MAX_BYTES:
        raise ProtocolError(
            f"FP_COMMIT 长度错误：got={len(payload)} expected={expected}"
        )
    vectors = []
    offset = LCVEX_FP_COMMIT_HEADER_BYTES
    for reg in range(32):
        if v_mask & (1 << reg):
            lo, hi = struct.unpack_from("<QQ", payload, offset)
            vectors.append((reg, (lo, hi)))
            offset += 16
    if previous is not None:
        if not (flags & LCVEX_FP_FLAG_FPCR_CHANGED) and fpcr != previous["fpcr"]:
            raise ProtocolError("FP_COMMIT flags=0 却改变 FPCR")
        if not (flags & LCVEX_FP_FLAG_FPSR_CHANGED) and fpsr != previous["fpsr"]:
            raise ProtocolError("FP_COMMIT flags=0 却改变 FPSR")
    return {"flags": flags, "v_mask": v_mask, "fpcr": fpcr,
            "fpsr": fpsr, "vectors": vectors, "payload_len": len(payload)}


def pack_fp_commit(flags, v_mask, fpcr, fpsr, vectors):
    """按 Vn 升序打包一条无损 FP_COMMIT delta。"""

    expected = fp_mask_popcount(v_mask)
    if flags & ~LCVEX_FP_FLAGS_MASK:
        raise ProtocolError("FP_COMMIT flags 含保留位")
    if len(vectors) != expected:
        raise ProtocolError("vectors 数量与 v_mask 不一致")
    indexes = [item[0] for item in vectors]
    wanted = [i for i in range(32) if v_mask & (1 << i)]
    if indexes != wanted:
        raise ProtocolError("FP_COMMIT vectors 必须按 Vn 升序")
    out = bytearray(LCVEX_FP_COMMIT_HEADER.pack(flags, v_mask, fpcr, fpsr))
    for reg, value in vectors:
        if not isinstance(value, (tuple, list)) or len(value) != 2:
            raise ProtocolError(f"V{reg} 必须是 (lo, hi)")
        out.extend(struct.pack("<QQ", value[0], value[1]))
    if len(out) not in (16, 32, 48, 64, 80):
        raise ProtocolError("FP_COMMIT 只允许 16/32/48/64/80B")
    return bytes(out)


def parse_fp_state(payload):
    if len(payload) != LCVEX_FP_STATE.size:
        raise ProtocolError(f"FP_INIT 长度必须为 520B，实际 {len(payload)}B")
    values = LCVEX_FP_STATE.unpack(payload)
    return {"fpcr": values[0], "fpsr": values[1],
            "v": [(values[i], values[i + 1]) for i in range(2, 66, 2)]}


def pack_fp_state(fpcr, fpsr, vectors):
    if len(vectors) != 32:
        raise ProtocolError("FP state 必须包含 32 个 V 寄存器")
    flat = []
    for value in vectors:
        if not isinstance(value, (tuple, list)) or len(value) != 2:
            raise ProtocolError("V state 必须是 (lo, hi)")
        flat.extend(value)
    return LCVEX_FP_STATE.pack(fpcr, fpsr, *flat)


def apply_fp_commit(previous, delta):
    """返回应用 delta 后的新 shadow；previous 不会被原地修改。"""

    parsed = (validate_fp_commit_payload(delta, previous)
              if isinstance(delta, (bytes, bytearray, memoryview)) else delta)
    if not isinstance(parsed, dict):
        raise ProtocolError("FP delta 对象无效")
    current = {"fpcr": previous["fpcr"], "fpsr": previous["fpsr"],
               "v": list(previous["v"])}
    current["fpcr"] = parsed["fpcr"]
    current["fpsr"] = parsed["fpsr"]
    for reg, value in parsed["vectors"]:
        current["v"][reg] = tuple(value)
    return current


def pack_fp_sidecar(seq, fpcr, fpsr, vectors, feature_bits=LCVEX_FP_FEATURE_NEON,
                    vector_bytes=LCVEX_FP_VECTOR_BYTES):
    if feature_bits != LCVEX_FP_FEATURE_NEON:
        raise ProtocolError("LCVXFP01 feature_bits 必须为 1")
    if vector_bytes != LCVEX_FP_VECTOR_BYTES:
        raise ProtocolError("LCVXFP01 vector_bytes 必须为 16")
    if len(vectors) != 32:
        raise ProtocolError("LCVXFP01 必须包含 32 个 V 寄存器")
    flat = []
    for value in vectors:
        if not isinstance(value, (tuple, list)) or len(value) != 2:
            raise ProtocolError("LCVXFP01 V state 必须是 (lo, hi)")
        flat.extend(value)
    return LCVEX_FP_FILE.pack(FP_FILE_MAGIC, FP_FILE_VERSION,
                              LCVEX_FP_FILE.size, feature_bits, vector_bytes,
                              seq, fpcr, fpsr, *flat)


def parse_fp_sidecar(raw, expected_seq=None):
    if len(raw) != LCVEX_FP_FILE.size:
        raise ProtocolError(f"LCVXFP01 长度必须为 552B，实际 {len(raw)}B")
    values = LCVEX_FP_FILE.unpack(raw)
    magic, version, size, feature_bits, vector_bytes, seq, fpcr, fpsr = values[:8]
    if magic != FP_FILE_MAGIC or version != FP_FILE_VERSION or \
            size != LCVEX_FP_FILE.size or feature_bits != LCVEX_FP_FEATURE_NEON or \
            vector_bytes != LCVEX_FP_VECTOR_BYTES:
        raise ProtocolError("LCVXFP01 header 不匹配")
    if expected_seq is not None and seq != expected_seq:
        raise ProtocolError(f"LCVXFP01 seq={seq} != TSV seq={expected_seq}")
    return {"seq": seq, "fpcr": fpcr, "fpsr": fpsr,
            "feature_bits": feature_bits, "vector_bytes": vector_bytes,
            "v": [(values[i], values[i + 1]) for i in range(8, 72, 2)]}


def exact_payload_size(msg_type, payload=b""):
    if msg_type == LCVEX_MSG_FP_COMMIT:
        return fp_commit_payload_size(LCVEX_FP_COMMIT_HEADER.unpack_from(payload)[1]) \
            if len(payload) >= LCVEX_FP_COMMIT_HEADER_BYTES else None
    return _FIXED_PAYLOAD_SIZES.get(msg_type)


def encode_message(msg_type, seq, payload=b"", flags=0):
    payload = bytes(payload)
    expected = exact_payload_size(msg_type, payload)
    if expected is None or expected != len(payload):
        raise ProtocolError(f"type={msg_type} payload 长度错误")
    if flags != 0:
        raise ProtocolError("消息 flags 必须为 0")
    return MSG_HEADER.pack(LCVEX_MSG_MAGIC, LCVEX_MSG_VERSION, msg_type,
                           flags, len(payload), seq) + payload


def decode_message(datagram, expected_type=None, expected_seq=None):
    """严格解析一个 SOCK_SEQPACKET datagram，拒绝 truncation/extra bytes。"""

    datagram = bytes(datagram)
    if len(datagram) < MSG_HEADER.size:
        raise ProtocolError("消息短于固定 header")
    magic, version, msg_type, flags, payload_len, seq = MSG_HEADER.unpack_from(datagram)
    if magic != LCVEX_MSG_MAGIC or version != LCVEX_MSG_VERSION:
        raise ProtocolError("消息 magic/version 不匹配")
    if flags != 0:
        raise ProtocolError("消息 flags 含保留位")
    if payload_len != len(datagram) - MSG_HEADER.size:
        raise ProtocolError(
            f"datagram 长度错误：header.payload_len={payload_len} "
            f"actual={len(datagram) - MSG_HEADER.size}"
        )
    if expected_type is not None and msg_type != expected_type:
        raise ProtocolError(f"消息 type={msg_type} != expected={expected_type}")
    if expected_seq is not None and seq != expected_seq:
        raise ProtocolError(f"消息 seq={seq} != expected={expected_seq}")
    payload = datagram[MSG_HEADER.size:]
    expected = exact_payload_size(msg_type, payload)
    if expected is None:
        raise ProtocolError(f"未知消息 type={msg_type}")
    if expected != len(payload):
        raise ProtocolError(f"type={msg_type} payload 长度错误")
    if msg_type == LCVEX_MSG_FP_COMMIT:
        validate_fp_commit_payload(payload)
    return {"type": msg_type, "flags": flags, "payload_len": payload_len,
            "seq": seq, "payload": payload}


def parse_state(b):
    v = LCVEX_STATE.unpack(b[:LCVEX_STATE.size])
    return {"pc": v[0], "next_pc": v[1], "insn": v[2], "x": v[3:34],
            "sp": v[34], "nzcv": v[35]}


def parse_commit(b):
    v = LCVEX_COMMIT.unpack(b[:LCVEX_COMMIT.size])
    stores = []
    for i in range(v[53]):  # store_count
        base = 54 + i * 3
        stores.append((v[base], v[base + 1], v[base + 2]))
    return {
        "post": parse_state(struct.pack("<QQI31QQI", v[0], v[1], v[2],
                                        *v[3:34], v[34], v[35])),
        "gpr_we": v[36],
        "gpr_rd": v[37],
        "sp_we": v[38],
        "nzcv_we": v[39],
        "gpr_wdata": v[40],
        "sp_wdata": v[41],
        "nzcv": v[42],
        "exc_valid": v[43],
        "exc_code": v[44],
        "exc_far": v[45],
        "exc_esr": v[46],
        "mon_we": v[48],
        "mon_valid": v[49],
        "mon_addr": v[50],
        "mon_data": v[51],
        "mon_data2": v[52],
        "store_count": v[53],
        "stores": stores,
    }
