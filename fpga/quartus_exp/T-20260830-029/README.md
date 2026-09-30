# T-20260830-029 FPGA-G2 BRAM explicit mapping artifacts

This directory contains the experimental SystemVerilog wrapper used for the
Quartus matrix and SoC-only black-box comparison.  No original RTL was changed;
the remote experiment root is:

`D:\Projects\fpga-altra\lcvex\build\T-20260830-029`

Files:

- `lcvex_bram_boot_altsyncram.sv` — explicit `altera_syncram` `BIDIR_DUAL_PORT`
  M20K wrapper.  To test a capacity, replace the `DEPTH_BYTES` default or use
  instance parameter override.
- `lcvex_bram_boot_shim.sv` — same-name shim that lets `lcvex_catapult_soc_top`
  instantiate the explicit wrapper without modifying the top RTL.

Key result: behavioral `logic [7:0] mem[0:DEPTH_BYTES-1]` is the direct cause of
the F3/F4 ~31.3GB SoC-only OOM; explicit M20K `altera_syncram` passes 1MiB in
~4s standalone and the SoC-only black-box top in ~8s / ~0.63GB.
See `docs/handoffs/T-20260830-029-fpga-g2.md` for full data.
