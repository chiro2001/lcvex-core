#!/usr/bin/env python3
"""QEMU step 模式探针：跑一个小程序并打印提交流（权威参考行为）。

用法：
  python3 qemu_probe.py --image build/difftest/probe.bin --max-insns N
"""

import argparse
import os
from pathlib import Path
import socket
import sys
import time

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
sys.path.insert(0, REPO)

from qemu.plugins.lcvex_protocol import (  # noqa: E402
    LCVEX_MSG_MAGIC,
    LCVEX_MSG_VERSION,
    LCVEX_MSG_HELLO,
    LCVEX_MSG_CONFIG,
    LCVEX_MSG_PRE,
    LCVEX_MSG_GO,
    LCVEX_MSG_COMMIT,
    LCVEX_MSG_ACK,
    LCVEX_MSG_DISCON,
    LCVEX_MSG_EXIT,
    MSG_HEADER,
    LCVEX_CONFIG,
    LCVEX_ACK,
    parse_commit,
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--max-insns", type=int, default=12)
    ap.add_argument("--base", default="0x44000000")
    ap.add_argument("--qemu", default="",
                    help="QEMU 可执行文件（默认 ../qemu/build/...）")
    ap.add_argument("--el1", action="store_true",
                    help="QEMU 以 EL1h 复位（has_el3=false,has_el2=false）")
    ap.add_argument("--icount", default="",
                    help="追加 -icount 参数（如 shift=0,align=off,sleep=off）")
    args = ap.parse_args()

    tmp_root = Path(os.environ.get("LCVEX_TMP_DIR", os.path.join(REPO, "build", "tmp")))
    tmp_root.mkdir(parents=True, exist_ok=True)
    sock_path = str(tmp_root / ("qemu_probe_%d.sock" % os.getpid()))
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(30)

    cpu = ("-cpu", "max,has_el3=false,has_el2=false") if args.el1 \
        else ("-cpu", "max")
    qemu = args.qemu or os.path.join(
        REPO, "..", "qemu", "build", "qemu-system-aarch64")
    icount = ["-icount", args.icount] if args.icount else []
    cmd = ["env", "LCVEX_DIFFTEST_STEP=1", qemu,
           "-machine", "virt", *cpu,
           "-accel", "tcg,thread=single", *icount, "-nographic",
           "-plugin",
           "file=%s/qemu/plugins/lcvex_difftest.so,mode=step,socket=%s"
           % (REPO, sock_path),
           "-device",
           "loader,file=%s,addr=%s,cpu-num=0,force-raw=on"
           % (args.image, args.base)]
    import subprocess
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)

    conn, _ = srv.accept()
    srv.close()
    os.unlink(sock_path)
    conn.settimeout(30)

    def recv():
        b = conn.recv(65536)
        h = MSG_HEADER.unpack(b[:MSG_HEADER.size])
        return h[2], h[5], b[MSG_HEADER.size:]

    def send(t, seq, payload=b""):
        conn.sendall(MSG_HEADER.pack(LCVEX_MSG_MAGIC, LCVEX_MSG_VERSION, t,
                                     0, len(payload), seq) + payload)

    t, seq, p = recv()
    assert t == LCVEX_MSG_HELLO
    send(LCVEX_MSG_CONFIG, 0, LCVEX_CONFIG.pack(1, args.max_insns, 30000,
                                                0xFFFF))
    committed = 0
    try:
        while committed < args.max_insns:
            t, seq, p = recv()
            if t == LCVEX_MSG_PRE:
                send(LCVEX_MSG_GO, seq)
            elif t == LCVEX_MSG_COMMIT:
                cm = parse_commit(p)
                st = cm["post"]
                x = st["x"]
                print("commit pc=%#x insn=%#08x next=%#x exc=%d ec=%#x "
                      "x0=%#x x1=%#x x2=%#x x3=%#x x4=%#x x5=%#x "
                      "x6=%#x x7=%#x x8=%#x x9=%#x x10=%#x nzcv=%#x" % (
                          st["pc"], st["insn"], st["next_pc"],
                          cm["exc_valid"], cm["exc_code"],
                          x[0], x[1], x[2], x[3], x[4], x[5],
                          x[6], x[7], x[8], x[9], x[10], st["nzcv"]))
                send(LCVEX_MSG_ACK, seq, LCVEX_ACK.pack(0, 0, b""))
                committed += 1
            elif t == LCVEX_MSG_DISCON:
                print("DISCON")
                break
            elif t == LCVEX_MSG_EXIT:
                print("EXIT")
                break
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


if __name__ == "__main__":
    main()
