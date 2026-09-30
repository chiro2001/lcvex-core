# T-20260829-099 Gate D Artifact Retention Package

> AUD-05 / T-20260829-110
> Source task: T-20260829-099 (Gate D local pass)
> Source head: `3dcffe0e6ddd7946c0bf560ca36778c6a1531f28`
> Audit reference: EXT-05-001
> Created: 2026-08-30 (Asia/Shanghai)

## Purpose

Persist the **small, key** Gate D artifacts from the T-099 detached worktree into
the repository so the 13-step PASS and the first RED log are not lost when that
worktree is cleaned. Large trace/coverage/coordinator binaries are **not** added
to Git; they are referenced by SHA256 and rebuild commands in `manifest.json`.

## Persisted files in this directory

| File | Size | SHA256 |
| --- | ---: | --- |
| `gate-d-pass.log.txt` | 332K | `c3ef8e5c...` |
| `gate-d-fail.log.txt` | 91K | `700fb2a1...` |
| `random_1_results.xml` | 401B | `6a460500...` |
| `random_2_results.xml` | 401B | `cc99f8ac...` |
| `random_3_results.xml` | 400B | `89d455b3...` |
| `insn_map.txt` | 1.3K | `f4a2fcba...` |
| `step-coord.log.txt` | 13K | `54e5e3ef...` |
| `step-qemu.log.txt` | 70B | `208b9320...` |
| `random-trace-excerpts.txt` | 25K | `1a369bf6...` |
| `manifest.json` | - | see git SHA |

Full SHA256 values are in `manifest.json`.

## Referenced but not in Git

| Artifact | Original URI | SHA256 |
| --- | --- | --- |
| `random_1.trace` | `build/difftest/random_1.trace` in T-099 worktree | `f0b30da6...` |
| `random_2.trace` | `build/difftest/random_2.trace` in T-099 worktree | `6338f450...` |
| `random_3.trace` | `build/difftest/random_3.trace` in T-099 worktree | `343b2952...` |
| `coverage/merged.dat` | `build/coverage/merged.dat` in T-099 worktree | `6e14afc9...` |
| coordinator base | `build/verilator_lockstep/lockstep_coordinator` | `38d84dc9...` |
| coordinator L1DL2 | `build/verilator_lockstep_l1dl2/lockstep_coordinator` | `94c7b439...` |
| coordinator L1DL2 delay2 | `build/verilator_lockstep_l1dl2_d2/lockstep_coordinator` | `3af91757...` |

These large files can be regenerated with the commands recorded in
`docs/tasks/evidence/T-20260829-099.json`.

## How to verify

```bash
cd <repo root>
sha256sum -c <(awk '/^[0-9a-f]{64}  /{print $2"  "$1}' docs/evidence/artifacts/T-20260829-099/manifest.json) 2>/dev/null || true
```

For the copied files, compare against the values in `manifest.json`.

## Retention

- Persisted text/XML files: **permanent in Git** (small).
- Full traces, coverage DB, coordinators: **not in Git**; available in the T-099
  worktree until that worktree is cleaned, and then need recovery/re-generation
  via the recorded commands.
