# T-20260829-080 A1 Generic Open-Source Synthesis Proxy

## Metadata

```text
task=T-20260829-080
state=review
base=3d717e763209923f5ddaedeeeafa9d0b9985ba6c
head=378b7a3a9442b1d8d7ab67b9984287ed4e8f0368
branch=feature/T-20260829-080-a1-generic-synth
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-080
sent_at=2026-08-29T02:26:00+0800
received_at=2026-08-29T02:37:08+0800
reported_at=2026-08-29T02:37:08+0800
```

## Outcome

A1 delivered a replayable Yosys/ABC generic-synthesis proxy for three real
LCVEX modules. Two identical runs per module produced identical LUT/FF/memory
statistics and identical `netlist.v` SHA256 hashes.

| Module | Config | LUT(4) | FF | RAM bits | DSP | Area |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `lcvex_axi4_master` | ADDR=64, DATA=128, ID=4, MAX_BURST_LEN=16 | 1870 | 2406 | 0 | N/A | N/A |
| `lcvex_mem_delay` | DELAY_MODE=1, RAND_MAX=4, SEED=8'hA5 | 63 | 241 | 0 | N/A | N/A |
| `lcvex_mem_arb` | PORTS=3 | 20 | 3 | 0 | N/A | N/A |

The work is a **generic logic proxy only**. These numbers are not Arria 10 or
ECP5 vendor resource counts, do not represent Fmax, and do not replace Quartus
or T-067.

## Files produced

- `scripts/opensynth/run_opensynth_a1.py` — flatten + two-run Yosys/ABC runner.
- `fpga/opensynth/generated/lcvex_axi4_master_flat.v`
- `fpga/opensynth/generated/lcvex_mem_delay_flat.v`
- `fpga/opensynth/generated/lcvex_mem_arb_flat.v`
- `fpga/opensynth/lcvex_axi4_master.ys`
- `fpga/opensynth/lcvex_mem_delay.ys`
- `fpga/opensynth/lcvex_mem_arb.ys`
- `fpga/opensynth/README.md`
- `fpga/opensynth/a1_generic_synth_stats.json`
- `docs/tasks/evidence/T-20260829-080.json`

Untracked replay logs/netlists are under `build/tmp/opensynth/<module>/run-00{1,2}/`.

## Commands

```sh
python3 scripts/opensynth/run_opensynth_a1.py
```

Each module was synthesized twice with:

```text
read_verilog -sv <flat>
synth -top <module> -lut 4
write_verilog -noattr -noexpr netlist.v
stat -json
```

Tool versions: Yosys 0.66 (git 86f2ddebc-dirty), ABC 1.01, Python 3.12.10.

## Stability

For all three modules:

- LUT/FF/memory statistics identical across run 1 and run 2.
- `netlist.v` SHA256 identical across runs.
- Detailed hashes and per-run metrics are in `a1_generic_synth_stats.json`.

## Blocker / not run

- `lcvex_core`: Yosys 0.66 cannot parse the core's unpacked-array ports
  (`fp_v_lo[0:31]`, `fp_v_hi[0:31]`); error:
  `syntax error, unexpected '[', expecting ')' or ',' or '='`.
- `lcvex_l2`: flattening parses after syntax-only shims, but full generic
  synthesis maps cache tag/data arrays to registers/gates and exceeds the local
  time/resource budget. No L2 resource numbers are claimed.
- RAM/DSP/area: `N/A` because no device memory/DSP or real FPGA device mapping
  was performed in this proxy.

## Next

- If A-line continues: add a memory-blackbox or `$mem`-preserving proxy for
  `lcvex_l2`, and a deeper port expansion (unpacked vector ports) if `lcvex_core`
  synthesis is required.
- Do not use these numbers for Quartus Fmax or resource signoff.
