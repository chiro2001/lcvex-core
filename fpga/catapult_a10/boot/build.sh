#!/usr/bin/env bash
# Build the single AArch64 BRAM image and its simulation/Quartus mirrors.
#
# Outputs (boot/build/ by default):
#   boot.elf  linked at 0x00000000, with stack [0xF000,0x10000)
#   boot.bin  exact ELF load image
#   boot.hex  one little-endian byte per line for $readmemh
#   boot.mif  WIDTH=64, DEPTH=8192, byte0 in bits [7:0] for M20K
#
# The legacy ddr.bin/ddr.hex pair is still emitted when ddr.S/ddr.ld exist so
# older standalone smoke harnesses can diagnose an image-build mismatch.  The
# B25 monitor never branches to that image.
set -euo pipefail

DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
OUT="${LCVEX_BOOT_BUILD_DIR:-$DIR/build}"
mkdir -p "$OUT"

AS="${AARCH64_AS:-aarch64-linux-gnu-as}"
CC="${AARCH64_CC:-aarch64-linux-gnu-gcc}"
LD="${AARCH64_LD:-aarch64-linux-gnu-ld}"
OBJCOPY="${AARCH64_OBJCOPY:-aarch64-linux-gnu-objcopy}"
READELF="${AARCH64_READELF:-aarch64-linux-gnu-readelf}"
NM="${AARCH64_NM:-aarch64-linux-gnu-nm}"
OBJDUMP="${AARCH64_OBJDUMP:-aarch64-linux-gnu-objdump}"
XXD="${XXD:-xxd}"
PYTHON="${PYTHON:-python3}"
COREMARK_DIR="$DIR/../coremark"

for tool in "$AS" "$CC" "$LD" "$OBJCOPY" "$READELF" "$NM" "$OBJDUMP" "$PYTHON"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "BOOT_TOOL_MISSING tool=$tool"
        exit 127
    fi
done

echo "LCVEX_BOOT_BUILD"
echo "asm=$AS cc=$CC ld=$LD objcopy=$OBJCOPY readelf=$READELF nm=$NM objdump=$OBJDUMP python=$PYTHON"
echo "output=$OUT"

"$AS" -o "$OUT/boot.o" "$DIR/boot.S"
# GCC 16 reports a false-positive maybe-uninitialized in the byte-for-byte
# upstream core_list_join.c; keep every other warning fatal without patching
# the benchmark algorithm source.
cflags=(
    -std=c11 -O2 -Wall -Wextra -Werror -Wno-maybe-uninitialized
    -march=armv8.2-a -mgeneral-regs-only -mstrict-align
    -ffreestanding -fno-builtin -fno-pie -fno-stack-protector
    -fno-unwind-tables -fno-asynchronous-unwind-tables
    -fno-tree-loop-distribute-patterns
    -I"$COREMARK_DIR" -I"$COREMARK_DIR/upstream"
)
echo "cflags=${cflags[*]}"

"$CC" "${cflags[@]}" -c "$COREMARK_DIR/lcvex_bench.c" -o "$OUT/lcvex_bench.o"
"$CC" "${cflags[@]}" -c "$COREMARK_DIR/core_portme.c" -o "$OUT/core_portme.o"
"$CC" "${cflags[@]}" -c "$COREMARK_DIR/ee_printf.c" -o "$OUT/ee_printf.o"
"$CC" "${cflags[@]}" -Dmain=coremark_main \
    -c "$COREMARK_DIR/upstream/core_main.c" -o "$OUT/core_main.o"
for source in core_list_join core_matrix core_state core_util; do
    "$CC" "${cflags[@]}" -c "$COREMARK_DIR/upstream/$source.c" \
        -o "$OUT/$source.o"
done

"$LD" --build-id=none -T "$DIR/boot.ld" -o "$OUT/boot.elf" \
    "$OUT/boot.o" "$OUT/lcvex_bench.o" "$OUT/core_portme.o" \
    "$OUT/ee_printf.o" "$OUT/core_main.o" "$OUT/core_list_join.o" \
    "$OUT/core_matrix.o" "$OUT/core_state.o" "$OUT/core_util.o"

if [[ -n "$("$NM" -u "$OUT/boot.elf")" ]]; then
    echo "BOOT_UNDEFINED_SYMBOLS"
    "$NM" -u "$OUT/boot.elf"
    exit 1
fi
"$OBJCOPY" -O binary "$OUT/boot.elf" "$OUT/boot.bin"

# bin_to_mif.py writes both mirrors and reads every generated MIF word back,
# comparing all bytes against boot.bin (including zero-filled unused words).
"$PYTHON" "$DIR/bin_to_mif.py" \
    --input "$OUT/boot.bin" \
    --hex "$OUT/boot.hex" \
    --output "$OUT/boot.mif"

boot_size="$(stat -c '%s' "$OUT/boot.bin")"
if (( boot_size > 0x10000 )); then
    echo "BOOT_IMAGE_TOO_LARGE bytes=$boot_size capacity=65536"
    exit 1
fi
echo "BOOT_IMAGE_SIZE bytes=$boot_size capacity=65536"
"$READELF" -h -S "$OUT/boot.elf"
"$OBJDUMP" -d "$OUT/boot.elf" > "$OUT/boot.dis"
"$PYTHON" "$COREMARK_DIR/emit_build_manifest.py" \
    --output "$OUT/microbench-build-manifest.json" \
    --elf "$OUT/boot.elf" --bin "$OUT/boot.bin" \
    --hex "$OUT/boot.hex" --mif "$OUT/boot.mif" \
    --compiler "$CC" --cflags "${cflags[*]}"

# Keep the pre-B25 DDR image available for old image-loader harnesses.  It is
# not part of the B25 execution path and is deliberately not placed in MIF.
if [[ -f "$DIR/ddr.S" && -f "$DIR/ddr.ld" ]]; then
    if ! command -v "$XXD" >/dev/null 2>&1; then
        echo "BOOT_TOOL_MISSING tool=$XXD (needed only for legacy ddr.hex)"
        exit 127
    fi
    "$AS" -o "$OUT/ddr.o" "$DIR/ddr.S"
    "$LD" -T "$DIR/ddr.ld" -o "$OUT/ddr.elf" "$OUT/ddr.o"
    "$OBJCOPY" -O binary "$OUT/ddr.elf" "$OUT/ddr.bin"
    "$XXD" -p -c 1 "$OUT/ddr.bin" > "$OUT/ddr.hex"
fi

sha256sum "$OUT/boot.elf" "$OUT/boot.bin" "$OUT/boot.hex" "$OUT/boot.mif"
if [[ -f "$OUT/ddr.bin" ]]; then
    sha256sum "$OUT/ddr.bin" "$OUT/ddr.hex"
fi
ls -l "$OUT/boot.elf" "$OUT/boot.bin" "$OUT/boot.hex" "$OUT/boot.mif"
echo "LCVEX_BOOT_BUILD_PASS"
