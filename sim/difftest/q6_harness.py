#!/usr/bin/env python3
"""Q6 验证 harness：QEMU fork step hook 的轻量协调器。

只驱动 QEMU（LCVEX_DIFFTEST_STEP=1 + plugin mode=step），不驱动 DUT，
用于验证 fork 能精确上报：
  1. 指令正常退休（COMMIT exc_valid=0）；
  2. 同步异常未退休（COMMIT exc_valid=1, exc_code=ESR.EC,
     post.pc=异常指令 PC, post.next_pc=异常向量入口）；
  3. 异常入口 PC discontinuity（向量入口成为下一条指令）；
  4. ERET 正常退休（next_pc=ELR_EL1）。

用法：
  python3 q6_harness.py --image build/difftest/q6_svc.bin --base 0x44000000 \
      --max-insns 12 [--dump build/difftest/q6.log] [--check-svc]
"""

import argparse
import os
from pathlib import Path
import socket
import struct
import sys

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
sys.path.insert(0, REPO)

from qemu.plugins.lcvex_protocol import (  # noqa: E402
    LCVEX_MSG_MAGIC,
    LCVEX_MSG_VERSION,
    LCVEX_MSG_HELLO,
    LCVEX_MSG_CONFIG,
    LCVEX_MSG_INIT,
    LCVEX_MSG_PRE,
    LCVEX_MSG_GO,
    LCVEX_MSG_COMMIT,
    LCVEX_MSG_ACK,
    LCVEX_MSG_DISCON,
    LCVEX_MSG_STOP,
    LCVEX_MSG_EXIT,
    LCVEX_ACK_OK,
    MSG_HEADER,
    LCVEX_STATE,
    LCVEX_COMMIT,
    LCVEX_CONFIG,
    LCVEX_ACK,
    LCVEX_MAX_STORES,
    parse_commit as proto_parse_commit,
)


class Msg:
    def __init__(self, htype, seq, payload):
        self.type = htype
        self.seq = seq
        self.payload = payload


def recv_msg(sock):
    buf = sock.recv(65536)  # SOCK_SEQPACKET：一次收一个完整消息
    if not buf:
        raise EOFError("对端关闭")
    if len(buf) < MSG_HEADER.size:
        raise RuntimeError("消息短于协议头")
    hdr = buf[:MSG_HEADER.size]
    magic, version, htype, flags, plen, seq = MSG_HEADER.unpack(hdr)
    if magic != LCVEX_MSG_MAGIC or version != LCVEX_MSG_VERSION:
        raise RuntimeError("协议头错误 magic=%#x version=%d" % (magic, version))
    payload = buf[MSG_HEADER.size:MSG_HEADER.size + plen]
    if len(payload) != plen:
        raise RuntimeError("消息载荷不完整")
    return Msg(htype, seq, payload)


def send_msg(sock, htype, seq, payload=b""):
    sock.sendall(MSG_HEADER.pack(LCVEX_MSG_MAGIC, LCVEX_MSG_VERSION, htype, 0,
                                 len(payload), seq) + payload)


def parse_state(b):
    st = LCVEX_STATE.unpack(b[:LCVEX_STATE.size])
    return {"pc": st[0], "next_pc": st[1], "insn": st[2], "x": st[3:34],
            "sp": st[34], "nzcv": st[35]}


def fmt_state(st):
    return "pc=%#x next_pc=%#x insn=%#08x sp=%#x nzcv=%#x x0=%#x x1=%#x x3=%#x x4=%#x" % (
        st["pc"], st["next_pc"], st["insn"], st["sp"], st["nzcv"],
        st["x"][0], st["x"][1], st["x"][3], st["x"][4])


def parse_commit(b):
    return proto_parse_commit(b)


def main():
    ap = argparse.ArgumentParser()
    default_tmp = os.environ.get("LCVEX_TMP_DIR", os.path.join(REPO, "build", "tmp"))
    ap.add_argument("--socket", default=os.path.join(default_tmp, "q6.sock"))
    ap.add_argument("--max-insns", type=int, default=12)
    ap.add_argument("--dump")
    ap.add_argument("--check-svc", action="store_true",
                    help="校验 svc-eret 测试程序的关键提交")
    args = ap.parse_args()

    Path(args.socket).parent.mkdir(parents=True, exist_ok=True)
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    srv.bind(args.socket)
    srv.listen(1)
    print("Q6 harness 等待 QEMU 连接：%s" % args.socket)
    srv.settimeout(30)
    conn, _ = srv.accept()
    srv.close()
    os.unlink(args.socket)
    conn.settimeout(30)

    log = open(args.dump, "w") if args.dump else None
    failures = []

    def note(fmt, *a):
        line = fmt % a
        print(line)
        if log:
            log.write(line + "\n")
            log.flush()

    def check(cond, what):
        if not cond:
            failures.append(what)
            note("FAIL: %s", what)

    committed = 0
    seq = 0
    init = None

    m = recv_msg(conn)
    check(m.type == LCVEX_MSG_HELLO, "首条应为 HELLO")
    send_msg(conn, LCVEX_MSG_CONFIG, 0,
             LCVEX_CONFIG.pack(1, args.max_insns, 30000, 0xFFFF))

    while True:
        m = recv_msg(conn)
        if m.type == LCVEX_MSG_INIT:
            init = parse_state(m.payload)
            note("INIT %s", fmt_state(init))
            continue
        if m.type == LCVEX_MSG_PRE:
            pre = parse_state(m.payload)
            note("PRE seq=%d %s", m.seq, fmt_state(pre))
            check(m.seq == seq, "PRE seq 不连续（期望 %d 实得 %d）"
                  % (seq, m.seq))
            send_msg(conn, LCVEX_MSG_GO, m.seq)
            continue
        if m.type == LCVEX_MSG_COMMIT:
            cm = parse_commit(m.payload)
            note("COMMIT seq=%d exc_valid=%d exc_code=%#x stores=%d %s",
                 m.seq, cm["exc_valid"], cm["exc_code"],
                 cm["store_count"], fmt_state(cm["post"]))
            if args.check_svc:
                pc = cm["post"]["pc"]
                if pc == 0x4400000c:  # svc #0
                    check(cm["exc_valid"] == 1, "svc 应上报 exc_valid=1")
                    check(cm["exc_code"] == 0x15, "svc EC 应为 0x15")
                    check(cm["post"]["next_pc"] == 0x44010200,
                          "svc next_pc 应为向量 0x44010200")
                elif pc == 0x44010204:  # mrs x3, elr_el1
                    if m.seq == 5:
                        check(cm["post"]["x"][3] == 0x44000010,
                              "第一轮 ELR_EL1 应为 svc+4=0x44000010")
                    elif m.seq == 11:
                        check(cm["post"]["x"][3] == 0x44000014,
                              "第二轮 ELR_EL1 应为 udf 地址 0x44000014")
                elif pc == 0x44010208:  # mrs x4, spsr_el1
                    check(cm["post"]["x"][4] == 0x400003c5,
                          "SPSR_EL1 应为异常前 PSTATE 0x400003c5")
                elif pc == 0x4401020c:  # eret
                    check(cm["exc_valid"] == 0, "eret 应正常退休")
                    check(cm["post"]["next_pc"] == 0x44000010,
                          "eret next_pc 应为 ELR_EL1=0x44000010")
            send_msg(conn, LCVEX_MSG_ACK, m.seq,
                     LCVEX_ACK.pack(LCVEX_ACK_OK, 0, b""))
            committed += 1
            seq += 1
            if committed >= args.max_insns:
                send_msg(conn, LCVEX_MSG_STOP, m.seq)
                note("达到 max_insns=%d，结束", args.max_insns)
                break
            continue
        if m.type == LCVEX_MSG_DISCON:
            note("DISCON seq=%d payload=%s", m.seq, m.payload.hex())
            failures.append("收到 DISCON（step 模式同步异常不应走 DISCON）")
            break
        if m.type == LCVEX_MSG_EXIT:
            note("EXIT seq=%d payload=%s", m.seq, m.payload.hex())
            break
        note("未处理消息 type=%d seq=%d", m.type, m.seq)
        failures.append("未处理消息 type=%d" % m.type)
        break

    if log:
        log.close()
    if failures:
        print("FAIL：%d 处校验失败" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("PASS：Q6 fork step hook 精确上报验证通过（%d 条提交）"
          % committed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
