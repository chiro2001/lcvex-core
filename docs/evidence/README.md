# Repository Evidence Artifacts

> Approved persistent root for small, machine-reproducible evidence that must
> survive temporary worktree cleanup.

Rules:

1. Keep files small; do not commit large binaries or full traces/coverage DBs.
2. Each artifact package has a `README.md` and `manifest.json` with relative URI,
   SHA256, byte size, retention, and source URI/rebuild command.
3. This directory is documentation/evidence only; no RTL, testbench, QEMU, or
   FPGA build modifications.
4. Large artifacts remain in source worktrees or external stores; only hashes and
   recipes are recorded here.

Current packages:

- `T-20260829-099/` — Gate D local PASS/RED logs, random trace metadata, coverage
  summary, coordinator logs (AUD-05 / T-20260829-110).
- `T-20260829-108-AUD03/` — AUD-03 Gate D + CORE_COUNT=1 rerun logs and hashes.

Large artifacts are copied to the approved external store
`/home/chiro/projects/mycpu/artifacts`, organized by task/domain; only hashes and
recipes are recorded here.
