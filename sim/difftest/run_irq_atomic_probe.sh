#!/usr/bin/env bash
# T-054：独立 QEMU step protocol probe。
#
# 该 helper 由 run_p6_irq_atomic_overlap.sh 调用，读取真实 QEMU COMMIT
# payload，核对目标指令/IRQ 指令、exc_code 和 store tuples；不驱动 DUT。
set -euo pipefail

if [[ "$#" -ne 14 ]]; then
  echo "用法：$0 IMAGE QEMU PLUGIN SOCKET QEMU_LOG OP_PC OP_INSN OP_STORES IRQ_PC IRQ_INSN IRQ_STORES EXPECT_STORES POST_LOADS MAX_INSNS" >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON="${PYTHON:-python3}"
exec "$PYTHON" - "$@" <<'PY'
import os
import socket
import struct
import subprocess
import sys

(
    image, qemu, plugin, sock_path, qemu_log_path, op_pc_s, op_insn_s,
    op_stores_s, irq_pc_s, irq_insn_s, irq_stores_s, expected_stores_s,
    post_loads_s, max_insns_s,
) = sys.argv[1:]

op_pc = int(op_pc_s, 0)
op_insn = int(op_insn_s, 0)
op_stores = int(op_stores_s, 0)
irq_pc = int(irq_pc_s, 0)
irq_insn = int(irq_insn_s, 0)
irq_stores = int(irq_stores_s, 0)
max_insns = int(max_insns_s, 0)


def parse_stores(text):
    values = []
    if text:
        for item in text.split(','):
            addr, data, strb = item.split('/')
            values.append((int(addr, 16), int(data, 16), int(strb, 16)))
    return values


def parse_loads(text):
    values = {}
    if text:
        for item in text.split(','):
            pc, rd = item.split('/')
            values[int(pc, 16)] = int(rd, 0)
    return values


expected_stores = parse_stores(expected_stores_s)
post_loads = parse_loads(post_loads_s)

with open(image, 'rb') as stream:
    stream.seek(op_pc - 0x44000000)
    encoded = struct.unpack('<I', stream.read(4))[0]
if encoded != op_insn:
    raise RuntimeError(
        f'image target encoding {encoded:#x} != expected {op_insn:#x}')

try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
server.bind(sock_path)
server.listen(1)
server.settimeout(30)
qemu_log = open(qemu_log_path, 'w', encoding='utf-8')
cmd = [
    'env', 'LCVEX_DIFFTEST_STEP=1', qemu,
    '-machine', 'virt',
    '-cpu', 'max,has_el3=false,has_el2=false',
    '-accel', 'tcg,thread=single,tb-size=64',
    '-icount', 'shift=0,align=off,sleep=off',
    '-rtc', 'base=2000-01-01T00:00:00,clock=vm',
    '-nographic',
    '-plugin', f'file={plugin},mode=step,socket={sock_path}',
    '-device', f'loader,file={image},addr=0x44000000,cpu-num=0,force-raw=on',
]
proc = subprocess.Popen(cmd, stdout=qemu_log, stderr=subprocess.STDOUT)
conn = None


def recv_msg():
    datagram = conn.recv(65536)
    if not datagram:
        raise RuntimeError('QEMU closed probe socket')
    if len(datagram) < MSG_HEADER.size:
        raise RuntimeError('short protocol datagram')
    magic, version, msg_type, flags, payload_len, seq = MSG_HEADER.unpack_from(datagram)
    if magic != LCVEX_MSG_MAGIC or version != LCVEX_MSG_VERSION or flags != 0:
        raise RuntimeError('bad protocol header')
    payload = datagram[MSG_HEADER.size:]
    if len(payload) != payload_len:
        raise RuntimeError('payload length mismatch')
    return msg_type, seq, payload


def send_msg(msg_type, seq, payload=b''):
    conn.sendall(MSG_HEADER.pack(LCVEX_MSG_MAGIC, LCVEX_MSG_VERSION,
                                 msg_type, 0, len(payload), seq) + payload)


sys.path.insert(0, os.getcwd())
from qemu.plugins.lcvex_protocol import (  # noqa: E402
    LCVEX_ACK,
    LCVEX_CONFIG,
    LCVEX_MSG_ACK,
    LCVEX_MSG_COMMIT,
    LCVEX_MSG_CONFIG,
    LCVEX_MSG_GO,
    LCVEX_MSG_HELLO,
    LCVEX_MSG_INIT,
    LCVEX_MSG_PRE,
    LCVEX_MSG_STOP,
    LCVEX_MSG_MAGIC,
    LCVEX_MSG_VERSION,
    MSG_HEADER,
    parse_commit,
)

seen_op = False
seen_irq = False
post_load_seen = set()
commit_count = 0
try:
    conn, _ = server.accept()
    server.close()
    conn.settimeout(30)
    msg_type, seq, payload = recv_msg()
    if msg_type != LCVEX_MSG_HELLO or seq != 0:
        raise RuntimeError('missing HELLO')
    send_msg(LCVEX_MSG_CONFIG, 0,
             LCVEX_CONFIG.pack(1, max_insns, 30000, 0xFFFF))
    while commit_count < max_insns:
        msg_type, seq, payload = recv_msg()
        if msg_type == LCVEX_MSG_INIT:
            if seq != 0:
                raise RuntimeError('INIT seq must be zero')
            continue
        if msg_type == LCVEX_MSG_PRE:
            send_msg(LCVEX_MSG_GO, seq)
            continue
        if msg_type == LCVEX_MSG_STOP:
            raise RuntimeError('QEMU stopped before expected target IRQ COMMIT')
        if msg_type != LCVEX_MSG_COMMIT:
            raise RuntimeError(f'unexpected protocol type={msg_type}')
        cm = parse_commit(payload)
        pc = cm['post']['pc']
        insn = cm['post']['insn']
        stores = cm['stores']
        if pc == op_pc and insn == op_insn:
            # Step-mode MEM_W is intentionally checked by the companion
            # trace helper; keep this probe focused on the actual instruction
            # and IRQ COMMIT fields.
            seen_op = True
        if pc in post_loads:
            rd = post_loads[pc]
            if cm['post']['x'][rd] != 0:
                raise RuntimeError(f'post-load pc={pc:#x} x{rd} not zero')
            post_load_seen.add(pc)
        if pc == irq_pc:
            # A timer interrupt on a branch can be reported by the QEMU
            # callback one boundary after the first ordinary COMMIT at the
            # same PC.  Only the packet carrying exc_valid is the IRQ packet;
            # keep the ordinary one and continue until the noted exception.
            if cm['exc_valid']:
                if insn != irq_insn:
                    raise RuntimeError(f'IRQ insn={insn:#x} != {irq_insn:#x}')
                if cm['exc_code'] != 0x40:
                    raise RuntimeError(
                        'IRQ COMMIT has exc_valid=1 but exc_code != 0x40')
                if len(stores) != irq_stores:
                    raise RuntimeError(
                        f'IRQ store_count={len(stores)} != {irq_stores}')
                seen_irq = True
        send_msg(LCVEX_MSG_ACK, seq, LCVEX_ACK.pack(0, 0, b''))
        commit_count += 1
        if seen_op and seen_irq and post_load_seen == set(post_loads):
            break
    if not seen_op:
        raise RuntimeError(f'target op COMMIT not observed pc={op_pc:#x}')
    if not seen_irq:
        raise RuntimeError(f'IRQ COMMIT not observed pc={irq_pc:#x}')
    if post_load_seen != set(post_loads):
        raise RuntimeError(
            f'post-load coverage {post_load_seen!r} != {set(post_loads)!r}')
    print(
        f'probe PASS op_pc={op_pc:#x} op_insn={op_insn:#x} '
        f'irq_pc={irq_pc:#x} irq_insn={irq_insn:#x} '
        f'irq_stores={irq_stores} commits={commit_count}')
finally:
    if conn is not None:
        conn.close()
    server.close()
    qemu_log.close()
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
PY
