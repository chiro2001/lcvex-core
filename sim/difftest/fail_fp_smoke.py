#!/usr/bin/env python3
"""可重放的 FP failure-package 负路径 smoke。

该测试只启动本 worktree 的 Verilator 协调器，并用最小 SOCK_SEQPACKET
peer 模拟协议对端；不启动 QEMU，也不修改 QEMU fork。它覆盖：

* FP_INIT payload 合法但 raw state 不匹配；
* 完成有效 FP_INIT/标量 COMMIT 后，FP_COMMIT raw state 不匹配。

两条路径都必须生成相邻的 fail.txt 和 fail-fp.json。测试随后用 Python
标准库解析 JSON，并检查协议要求的完整字段与 32 个 V 寄存器展开。
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time


BASE = 0x44000000
MAGIC = 0x5446444C
VERSION = 1
HELLO = 1
CONFIG = 2
INIT = 3
PRE = 4
GO = 5
COMMIT = 6
ACK = 7
STOP = 9
FP_INIT = 16
FP_COMMIT = 17
FP_CAP = 0x80000000
HEADER = struct.Struct("<IHHIIQ")
STATE = struct.Struct("<QQI31QQI")
COMMIT_BYTES = 560
SOCKET_PATH = Path("build/tmp/fail-fp-smoke.sock")


def packet(msg_type: int, seq: int, payload: bytes = b"") -> bytes:
    return HEADER.pack(MAGIC, VERSION, msg_type, 0, len(payload), seq) + payload


def recv_packet(sock: socket.socket) -> tuple[int, int, bytes]:
    data = sock.recv(4096)
    if len(data) < HEADER.size:
        raise AssertionError(f"协议 peer 收到短消息：{len(data)} bytes")
    magic, version, msg_type, flags, payload_len, seq = HEADER.unpack_from(data)
    if (magic, version, flags) != (MAGIC, VERSION, 0):
        raise AssertionError(
            f"协议头错误 magic={magic:#x} version={version} flags={flags}"
        )
    if payload_len != len(data) - HEADER.size:
        raise AssertionError(
            f"payload 长度错误 declared={payload_len} actual={len(data)-HEADER.size}"
        )
    return msg_type, seq, data[HEADER.size:]


def send_packet(sock: socket.socket, msg_type: int, seq: int, payload: bytes = b"") -> None:
    sock.sendall(packet(msg_type, seq, payload))


def state_payload(insn: int = 0, pc: int = BASE, next_pc: int = BASE + 4) -> bytes:
    return STATE.pack(pc, next_pc, insn, *([0] * 31), 0, 4)


def fp_state_payload(fpcr: int = 0, fpsr: int = 0) -> bytes:
    return struct.pack("<II", fpcr, fpsr) + b"".join(
        struct.pack("<QQ", 0, 0) for _ in range(32)
    )


def nop_commit_payload() -> bytes:
    """构造 coordinator 对首条 NOP 所需的完整 scalar COMMIT。"""
    payload = bytearray(COMMIT_BYTES)
    struct.pack_into("<QQI", payload, 0, BASE, BASE + 4, 0xD503201F)
    for i in range(31):
        struct.pack_into("<Q", payload, 20 + i * 8, 0)
    struct.pack_into("<QI", payload, 268, 0, 4)
    # gpr_we/gpr_rd/sp_we/nzcv_we at 280..283, all false.
    struct.pack_into("<QQI", payload, 284, 0, 0, 4)
    # exc_valid/pad, exc_code/far/esr/pad2, monitor fields and stores remain 0.
    struct.pack_into("<I", payload, 364, 0)
    return bytes(payload)


def start_coordinator(coordinator: Path, case_dir: Path) -> tuple[subprocess.Popen[bytes], Path]:
    image = case_dir / "program.bin"
    image.write_bytes(struct.pack("<II", 0xD503201F, 0x14000000))
    # Linux sockaddr_un.sun_path is limited to 108 bytes.  Keep the socket at
    # a short, worktree-local path while retaining per-case logs/artifacts in
    # the longer evidence directory.
    sock_path = SOCKET_PATH
    log_path = case_dir / "coord.log"
    dump_path = case_dir / "fail.txt"
    log = log_path.open("wb")
    proc = subprocess.Popen(
        [
            str(coordinator),
            "--socket",
            str(sock_path),
            "--image",
            str(image),
            "--base",
            hex(BASE),
            "--fp-neon",
            "required",
            "--cpu-profile",
            "cortex-a76,has_el3=false,has_el2=false",
            "--max-insns",
            "4",
            "--timeout-ms",
            "2000",
            "--progress-every",
            "0",
            "--dump",
            str(dump_path),
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    # The coordinator creates the socket after Verilator reset/load.  Keep the
    # bounded wait deterministic and retain the log in the case directory.
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline and not sock_path.exists():
        if proc.poll() is not None:
            break
        time.sleep(0.01)
    if not sock_path.exists():
        proc.wait(timeout=2)
        log.close()
        raise AssertionError(
            f"协调器未创建 socket rc={proc.returncode} log={log_path}"
        )
    return proc, log_path


def handshake(sock: socket.socket) -> None:
    # qemu_major/minor/micro, api_version=2, arch=aarch64, vcpu_count=1.
    send_packet(sock, HELLO, 0, struct.pack("<6I", 11, 1, 0, 2, 1, 1))
    msg_type, seq, payload = recv_packet(sock)
    assert (msg_type, seq) == (CONFIG, 0), (msg_type, seq)
    assert len(payload) == 20, len(payload)
    _vcpu_count, _max_insns, _timeout_ms, state_mask = struct.unpack(
        "<IQII", payload
    )
    assert state_mask & FP_CAP, f"coordinator 未声明 FP capability: {state_mask:#x}"


def drive_init_mismatch(coordinator: Path, case_dir: Path) -> None:
    proc, log_path = start_coordinator(coordinator, case_dir)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as sock:
            sock.settimeout(5)
            sock.connect(str(SOCKET_PATH))
            handshake(sock)
            send_packet(sock, INIT, 0, state_payload())
            # FP_INIT is the first message after INIT in required mode.
            send_packet(sock, FP_INIT, 0, fp_state_payload(fpcr=1))
    finally:
        try:
            proc.wait(timeout=10)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    if proc.returncode != 1:
        raise AssertionError(f"FP_INIT mismatch rc={proc.returncode} log={log_path}")


def drive_commit_mismatch(coordinator: Path, case_dir: Path) -> None:
    proc, log_path = start_coordinator(coordinator, case_dir)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as sock:
            sock.settimeout(5)
            sock.connect(str(SOCKET_PATH))
            handshake(sock)
            send_packet(sock, INIT, 0, state_payload())
            send_packet(sock, FP_INIT, 0, fp_state_payload())
            send_packet(sock, PRE, 0, state_payload(insn=0xD503201F))
            msg_type, seq, payload = recv_packet(sock)
            assert (msg_type, seq, payload) == (GO, 0, b"")
            send_packet(sock, COMMIT, 0, nop_commit_payload())
            # Validly framed FP_COMMIT, but QEMU post FPCR=1 differs from DUT=0.
            send_packet(sock, FP_COMMIT, 0, struct.pack("<IIII", 1, 0, 1, 0))
            seen = []
            for _ in range(2):
                seen.append(recv_packet(sock)[0])
            assert seen == [ACK, STOP], seen
    finally:
        try:
            proc.wait(timeout=10)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    if proc.returncode != 1:
        raise AssertionError(f"FP_COMMIT mismatch rc={proc.returncode} log={log_path}")


def validate_failure(case_dir: Path, stage: str) -> None:
    json_path = case_dir / "fail-fp.json"
    text_path = case_dir / "fail.txt"
    assert json_path.is_file(), f"缺少 {json_path}"
    assert text_path.is_file(), f"缺少 {text_path}"
    data = json.loads(json_path.read_text(encoding="utf-8"))
    required = {
        "schema",
        "schema_version",
        "status",
        "stage",
        "seq",
        "first_raw_mismatch",
        "cpu_profile",
        "capability",
        "instruction",
        "fp",
        "scalar_stores",
        "checkpoint_provenance",
        "recent_records",
        "errors",
    }
    assert required <= data.keys(), sorted(required - data.keys())
    assert data["schema"] == "lcvex-fail-fp-v1"
    assert data["schema_version"] == 1
    assert data["status"] == "mismatch"
    assert data["stage"] == stage
    assert data["seq"] == 0
    assert data["cpu_profile"]

    capability = data["capability"]
    for key in (
        "fp_neon_required",
        "fp_neon_enabled",
        "hello_api_version",
        "config_state_mask",
        "protocol_version",
        "feature_bits",
        "vector_bytes",
        "max_vectors_per_commit",
        "fp_ready",
    ):
        assert key in capability, key
    assert capability["fp_neon_required"] is True
    assert capability["hello_api_version"] == 2
    assert capability["config_state_mask"] & FP_CAP

    instruction = data["instruction"]
    for key in ("seq", "encoding", "encoding_hex", "disassembly"):
        assert key in instruction, key
    assert instruction["disassembly"]

    fp = data["fp"]
    for side in ("pre", "post", "dut_pre", "dut_post"):
        assert side in fp, side
        assert "fpcr" in fp[side] and "fpsr" in fp[side]
        assert len(fp[side]["v"]) == 32, (side, len(fp[side]["v"]))
        for index, vector in enumerate(fp[side]["v"]):
            assert vector["index"] == index
            for key in ("lo", "hi", "raw"):
                assert key in vector, (side, index, key)

    stores = data["scalar_stores"]
    assert set(stores) == {"dut", "qemu"}
    assert isinstance(stores["dut"], list)
    assert isinstance(stores["qemu"], list)
    provenance = data["checkpoint_provenance"]
    for key in (
        "diff_ckpt",
        "restore_mode",
        "restore_fp_mode",
        "ckpt_every",
        "next_ckpt_seq",
        "image",
        "checkpoint_dir",
        "restore_fp_path",
    ):
        assert key in provenance, key
    assert len(data["recent_records"]) <= 32
    assert data["errors"]
    fail_text = text_path.read_text(encoding="utf-8")
    assert "first_fp_raw_mismatch:" in fail_text
    assert "FP raw state" in fail_text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--coordinator", required=True, type=Path)
    parser.add_argument("--output-root", type=Path, default=Path("build/tmp"))
    args = parser.parse_args()
    if not args.coordinator.is_file():
        raise SystemExit(f"找不到 coordinator: {args.coordinator}")
    args.output_root.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="fail-fp-smoke-", dir=args.output_root))
    init_dir = root / "fp-init"
    commit_dir = root / "fp-commit"
    init_dir.mkdir()
    commit_dir.mkdir()
    drive_init_mismatch(args.coordinator, init_dir)
    validate_failure(init_dir, "FP_INIT")
    drive_commit_mismatch(args.coordinator, commit_dir)
    validate_failure(commit_dir, "FP_COMMIT")
    print(f"PASS: fail-fp.json FP_INIT/FP_COMMIT 负路径与字段完整性（{root}）")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
