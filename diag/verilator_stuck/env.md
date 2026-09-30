# Environment (T-20260829-090)

- Worktree: /home/chiro/projects/mycpu/lcvex-wt-T-20260829-090
- Branch: feature/T-20260829-090-verilator-stuck-diagnose
- Base SHA: 86186e2649e9af9420fb216d36c7bf3d44781457
- Verilator: $(/home/chiro/miniforge3/envs/lcvex/bin/verilator --version)
  Verilator 5.050 2026-07-01 rev conda-forge build 0
- CPU: 12 threads
- Memory at start: 29Gi total, ~11Gi available (host also running T-086 full dualcore Verilator and T-085 Cocotb build)
- OS: Linux server-mini 7.1.5-arch1-2 (Arch)
- TMPDIR for all experiments: /home/chiro/projects/mycpu/lcvex-wt-T-20260829-090/tmp_build
- User command observed in T-086:
  verilator --binary --timing --assert -j4 --top-module lcvex_c2_dualcore_tb -Mdir build/c2_dual ...
