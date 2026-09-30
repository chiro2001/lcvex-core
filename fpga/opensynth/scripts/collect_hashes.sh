#!/usr/bin/env bash
# Collect SHA256 for A0 input files.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"
sha256sum \
  rtl/lcvex_pkg.sv \
  rtl/lcvex_core.sv \
  rtl/lcvex_axi4_master.sv \
  rtl/lcvex_l2.sv \
  rtl/lcvex_catapult_soc_top.sv \
  rtl/filelist.f \
  fpga/catapult_a10/tb/filelist_soc.f \
  fpga/opensynth/examples/minimal_counter.sv \
  fpga/opensynth/examples/sv_pkg_struct.sv \
  fpga/opensynth/examples/sv_features.sv
