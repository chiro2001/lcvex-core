#!/usr/bin/env bash
# A0 lightweight reproducible attempt script.
# Set OSS_CAD_SUITE to an oss-cad-suite root (e.g. /tmp/oss_cad/oss-cad-suite).
# The heavy full-core/SoC Verilator lints are intentionally not run by default.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"
OSS="${OSS_CAD_SUITE:-/tmp/oss_cad/oss-cad-suite}"
OUT=fpga/opensynth/logs
mkdir -p "$OUT"

echo "== Verilator minimal =="
conda run --no-capture-output -n lcvex verilator --lint-only \
  --top-module minimal_counter -Wall fpga/opensynth/examples/minimal_counter.sv \
  > "$OUT/verilator_minimal.log" 2>&1

echo "== Verilator package/struct =="
conda run --no-capture-output -n lcvex verilator --lint-only \
  --top-module pkg_struct_sample fpga/opensynth/examples/sv_pkg_struct.sv \
  > "$OUT/verilator_pkg_struct_nowall.log" 2>&1

echo "== Verilator interface/modport =="
conda run --no-capture-output -n lcvex verilator --lint-only \
  --top-module feature_sample fpga/opensynth/examples/sv_features.sv \
  > "$OUT/verilator_sv_features_nowall.log" 2>&1

echo "== Verilator real lcvex_axi4_master =="
conda run --no-capture-output -n lcvex verilator --lint-only \
  --top-module lcvex_axi4_master rtl/lcvex_axi4_pkg.sv rtl/lcvex_axi4_master.sv \
  > "$OUT/verilator_lcvex_axi4_master.log" 2>&1

echo "== Verilator real lcvex_l2 =="
conda run --no-capture-output -n lcvex verilator --lint-only \
  --top-module lcvex_l2 rtl/lcvex_pkg.sv rtl/lcvex_l2.sv \
  > "$OUT/verilator_lcvex_l2.log" 2>&1

echo "== Yosys minimal synth (if suite present) =="
if [ -x "$OSS/bin/yosys" ]; then
  LD_LIBRARY_PATH="$OSS/lib:$OSS/lib64" "$OSS/bin/yosys" -q -p \
    'read_verilog -sv fpga/opensynth/examples/minimal_counter.sv; synth_ecp5 -json /tmp/a0_minimal_ecp5.json' \
    > "$OUT/oss_yosys_minimal_synth.log" 2>&1
fi

echo "== Yosys package/struct (expected fail) =="
if [ -x "$OSS/bin/yosys" ]; then
  set +e
  LD_LIBRARY_PATH="$OSS/lib:$OSS/lib64" "$OSS/bin/yosys" -q -p \
    'read_verilog -sv fpga/opensynth/examples/sv_pkg_struct.sv; hierarchy -top pkg_struct_sample' \
    > "$OUT/oss_yosys_pkg_struct.log" 2>&1
  set -e
fi

echo "All lightweight attempts completed"
