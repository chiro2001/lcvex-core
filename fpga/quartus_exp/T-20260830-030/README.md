# T-20260830-030 FPGA-G3 artifacts (local pointer)

Remote experiment root (isolated, original untouched):

`D:\Projects\fpga-altra\lcvex\build\T-20260830-030`

Local branch: `feature/T-20260830-030-fpga-g3`
Worktree: `/home/chiro/projects/mycpu/lcvex-wt-T-20260830-030`

Status: **effective**. The G2 explicit altsyncram BRAM shim also unblocks the real
A10 black-box top. With the shim, `lcvex_catapult_a10_top` + `lcvex_catapult_soc_top`
+ core/coh/AXI stubs completed synthesis, fitter, timing signoff and assembler on
the isolated remote project.

Key remote outputs:

- `projects/a10_top_altsync/output_files/a10_top_altsync.sof`
- `projects/a10_top_altsync/output_files/a10_top_altsync.fit.rpt`
- `projects/a10_top_altsync/output_files/a10_top_altsync.sta.rpt`
- `projects/a10_top_altsync/output_files/a10_top_altsync.syn.rpt`
- `projects/a10_top_altsync/output_files/a10_top_altsync.flow.rpt`
- `logs/*`  (monitor samples, stdout/stderr)
- `logs/soc_bu_altsync_rerun.*` (SoC-only shim baseline re-run)
- `logs/a10_top_behav_synth.*` (behavioral-BRAM control, killed)
- `logs/origcopy_*` (full original-path-copy experiments)

Remote full-tree copy used for the path-copy test:

`D:\Projects\fpga-altra\lcvex_bu_T30` (non-`build` source tree).

Full narrative and evidence: `docs/handoffs/T-20260830-030-fpga-g3.md`,
`docs/tasks/evidence/T-20260830-030.json`.
