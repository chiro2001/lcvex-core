#!/usr/bin/env bash
# T-054：QEMU trace-side memory-effect probe。
#
# QEMU step 模式的 plugin callback 会在阻塞 PRE/GO 时序下丢失 MEM_W；
# 非锁步 trace 模式仍由同一只读 plugin 记录真实 store tuples。该 helper
# 不驱动 DUT，仅为 strict coordinator 的状态结果补充可审计的 store count。
set -euo pipefail

if [[ "$#" -ne 9 ]]; then
  echo "用法：$0 IMAGE QEMU PLUGIN TRACE OP_PC OP_INSN OP_STORES EXPECT_STORES POST_LOADS" >&2
  exit 2
fi

PYTHON="${PYTHON:-python3}"
exec "$PYTHON" - "$@" <<'PY'
import gzip
import os
import re
import struct
import subprocess
import sys

(
    image, qemu, plugin, trace, op_pc_s, op_insn_s, op_stores_s,
    expected_stores_s, post_loads_s,
) = sys.argv[1:]
op_pc = int(op_pc_s, 0)
op_insn = int(op_insn_s, 0)
op_stores = int(op_stores_s, 0)


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
    raise RuntimeError(f'image target encoding {encoded:#x} != expected {op_insn:#x}')

try:
    os.unlink(trace)
except FileNotFoundError:
    pass
cmd = [
    'env', 'LCVEX_DIFFTEST_STEP=1', qemu,
    '-machine', 'virt',
    '-cpu', 'max,has_el3=false,has_el2=false',
    '-accel', 'tcg,thread=single,tb-size=64',
    '-icount', 'shift=0,align=off,sleep=off',
    '-rtc', 'base=2000-01-01T00:00:00,clock=vm',
    '-nographic',
    '-plugin', f'file={plugin},trace={trace},limit=180',
    '-device', f'loader,file={image},addr=0x44000000,cpu-num=0,force-raw=on',
]
# The image ends in a self-loop.  timeout=3 is expected once enough trace has
# been flushed; a non-timeout QEMU error is handled below by the trace checks.
run = subprocess.run(['timeout', '3', *cmd],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if run.returncode not in (0, 124, 143):
    raise RuntimeError(f'QEMU trace exited with rc={run.returncode}')
if not os.path.isfile(trace):
    raise RuntimeError('QEMU trace file was not created')

op_seen = False
op_stores_seen = None
post_load_seen = set()
memory_shadow = {}
hex_re = re.compile(r'\bpc=0x([0-9a-fA-F]+).*?insn=0x([0-9a-fA-F]+)')
store_re = re.compile(r'\bstores=(\d+)')
def parse_u64(line, key):
    match = re.search(rf'\b{re.escape(key)}=0x([0-9a-fA-F]+)', line)
    return int(match.group(1), 16) if match else None


with gzip.open(trace, 'rt', encoding='utf-8', errors='replace') as stream:
    for line in stream:
        match = hex_re.search(line)
        if not match:
            continue
        pc = int(match.group(1), 16)
        insn = int(match.group(2), 16)
        store_match = store_re.search(line)
        if store_match is None:
            continue
        count = int(store_match.group(1))
        stores = []
        for index in range(count):
            addr = parse_u64(line, f's{index}_addr')
            data = parse_u64(line, f's{index}_data')
            size_match = re.search(rf'\bs{index}_size=(\d+)', line)
            if addr is None or data is None or size_match is None:
                raise RuntimeError(f'trace store tuple {index} incomplete')
            size = int(size_match.group(1), 0)
            stores.append((addr, data, (1 << size) - 1))
        effective_stores = stores
        if pc == op_pc and insn == op_insn and op_stores == 0 and stores:
            # QEMU's cmpxchg helper may expose a failed CASP as a MEM_W tuple
            # containing the unchanged old value.  Treat only tuples proven
            # equal to the pre-operation shadow as phantom writes; any other
            # non-zero tuple is a real mismatch and must fail the probe.
            unchanged = all(
                address in memory_shadow and
                memory_shadow[address] == (data, strb)
                for address, data, strb in stores)
            if unchanged:
                effective_stores = []
        if pc == op_pc and insn == op_insn:
            op_seen = True
            op_stores_seen = effective_stores
            if len(effective_stores) != op_stores:
                raise RuntimeError(
                    f'op effective_store_count={len(effective_stores)} '
                    f'(raw={count}) != {op_stores}')
            if expected_stores and effective_stores != expected_stores:
                raise RuntimeError(
                    f'op stores={effective_stores!r} != {expected_stores!r}')
        if pc in post_loads:
            rd = post_loads[pc]
            value = parse_u64(line, f'x{rd}')
            if value != 0:
                raise RuntimeError(f'post-load pc={pc:#x} x{rd}={value:#x} != 0')
            post_load_seen.add(pc)
        if not (pc == op_pc and insn == op_insn and
                op_stores == 0 and effective_stores == []):
            for address, data, strb in stores:
                memory_shadow[address] = (data, strb)

if not op_seen:
    raise RuntimeError(f'target op trace not observed pc={op_pc:#x}')
if post_load_seen != set(post_loads):
    raise RuntimeError(
        f'post-load coverage {post_load_seen!r} != {set(post_loads)!r}')
print(f'trace PASS op_pc={op_pc:#x} op_insn={op_insn:#x} '
      f'op_stores={len(op_stores_seen)} post_loads={len(post_load_seen)}')
PY
