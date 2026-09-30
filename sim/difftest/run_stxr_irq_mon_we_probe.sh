#!/usr/bin/env bash
# T-055：独立 QEMU 协议 probe，确认 WFI 唤醒使用 ASYNC 且不携带 monitor。
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "用法：$0 IMAGE QEMU PLUGIN" >&2
  exit 2
fi

IMAGE="$1"
QEMU_BIN="$2"
PLUGIN="$3"
PYTHON="${PYTHON:-python3}"
SOCK="${SOCK:-build/tmp/t55-wfi-probe.sock}"
QEMU_LOG="${QEMU_LOG:-build/tmp/t55-wfi-probe.qemu}"
MAX_COMMITS="${MAX_COMMITS:-35}"

mkdir -p "$(dirname "$SOCK")" "$(dirname "$QEMU_LOG")"

exec "$PYTHON" - "$IMAGE" "$QEMU_BIN" "$PLUGIN" "$SOCK" "$QEMU_LOG" \
  "$MAX_COMMITS" <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import socket
import subprocess
import sys

from qemu.plugins.lcvex_protocol import (
    LCVEX_ACK,
    LCVEX_CONFIG,
    LCVEX_MSG_ACK,
    LCVEX_MSG_ASYNC,
    LCVEX_MSG_COMMIT,
    LCVEX_MSG_CONFIG,
    LCVEX_MSG_EXIT,
    LCVEX_MSG_GO,
    LCVEX_MSG_HELLO,
    LCVEX_MSG_INIT,
    LCVEX_MSG_PRE,
    LCVEX_MSG_STOP,
    LCVEX_MSG_WAIT,
    LCVEX_MSG_WAIT_RESUME,
    decode_message,
    encode_message,
    parse_commit,
)

image, qemu, plugin, sock_path, qemu_log, max_commits_s = sys.argv[1:]
max_commits = int(max_commits_s, 0)
server = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
server.bind(sock_path)
server.listen(1)
server.settimeout(30)
log = Path(qemu_log).open("wb")
proc = subprocess.Popen(
    [
        "env", "LCVEX_DIFFTEST_STEP=1", qemu,
        "-machine", "virt",
        "-cpu", "max,has_el3=false,has_el2=false",
        "-accel", "tcg,thread=single,tb-size=64",
        "-icount", "shift=0,align=off,sleep=off",
        "-rtc", "base=2000-01-01T00:00:00,clock=vm",
        "-nographic",
        "-plugin", f"file={plugin},mode=step,socket={sock_path}",
        "-device", f"loader,file={image},addr=0x44000000,cpu-num=0,force-raw=on",
    ],
    stdout=log,
    stderr=subprocess.STDOUT,
)

conn = None
commits = 0
waits = 0
async_packets = []
try:
    conn, _ = server.accept()
    server.close()
    conn.settimeout(30)

    def recv_frame():
        datagram = conn.recv(65536)
        if not datagram:
            raise RuntimeError("QEMU closed probe socket")
        return decode_message(datagram)

    def send_frame(msg_type, seq, payload=b""):
        conn.sendall(encode_message(msg_type, seq, payload))

    hello = recv_frame()
    if hello["type"] != LCVEX_MSG_HELLO or hello["seq"] != 0:
        raise RuntimeError("missing HELLO")
    send_frame(LCVEX_MSG_CONFIG, 0,
               LCVEX_CONFIG.pack(1, max_commits, 30000, 0xFFFF))

    while True:
        frame = recv_frame()
        msg_type = frame["type"]
        seq = frame["seq"]
        payload = frame["payload"]
        if msg_type == LCVEX_MSG_INIT:
            if seq != 0:
                raise RuntimeError(f"INIT seq={seq} != 0")
            continue
        if msg_type == LCVEX_MSG_PRE:
            send_frame(LCVEX_MSG_GO, seq)
            continue
        if msg_type == LCVEX_MSG_COMMIT:
            cm = parse_commit(payload)
            commits += 1
            if cm["mon_we"] and cm["mon_valid"] not in (0, 1):
                raise RuntimeError("invalid COMMIT monitor valid bit")
            send_frame(LCVEX_MSG_ACK, seq, LCVEX_ACK.pack(0, 0, b""))
            if commits >= max_commits:
                send_frame(LCVEX_MSG_STOP, seq)
                break
            continue
        if msg_type == LCVEX_MSG_WAIT:
            waits += 1
            continue
        if msg_type == LCVEX_MSG_WAIT_RESUME:
            continue
        if msg_type == LCVEX_MSG_ASYNC:
            cm = parse_commit(payload)
            if cm["exc_valid"] != 1 or cm["exc_code"] != 0x40:
                raise RuntimeError(
                    f"ASYNC exception fields invalid: valid={cm['exc_valid']} "
                    f"code={cm['exc_code']:#x}"
                )
            if cm["mon_we"] != 0 or cm["store_count"] != 0:
                raise RuntimeError(
                    f"WFI ASYNC leaked side effects: mon_we={cm['mon_we']} "
                    f"stores={cm['store_count']}"
                )
            async_packets.append((seq, cm["post"]["pc"], cm["post"]["next_pc"]))
            send_frame(LCVEX_MSG_ACK, seq, LCVEX_ACK.pack(0, 0, b""))
            continue
        if msg_type == LCVEX_MSG_EXIT:
            raise RuntimeError("QEMU exited before WFI ASYNC observation")
        if msg_type == LCVEX_MSG_STOP:
            break
        raise RuntimeError(f"unexpected protocol type={msg_type}")
finally:
    if conn is not None:
        conn.close()
    server.close()
    log.close()
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

if proc.returncode not in (0, -15):
    raise RuntimeError(f"QEMU probe returncode={proc.returncode}")
if waits == 0 or not async_packets:
    raise RuntimeError(f"WFI ASYNC not observed: waits={waits} async={async_packets}")
print(f"PASS: WFI WAIT/ASYNC monitor sidecar probe waits={waits} "
      f"async={len(async_packets)} packets={async_packets}")
PY
