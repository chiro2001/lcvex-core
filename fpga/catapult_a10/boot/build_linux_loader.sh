#!/usr/bin/env bash
# Assemble/link the standalone 64 KiB BRAM Linux loader.
#
# This image is a Linux boot configuration that replaces the B25 resident
# monitor image. It does not link boot.S, the existing monitor, or CoreMark.
# The linker reserves [0xF000,0x10000) for the downward-growing loader stack.
# Outputs include independent linux_loader.hex/linux_loader.mif images; no
# Quartus source selector or board routing is changed by this script.
set -euo pipefail

DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
OUT="${LCVEX_LINUX_LOADER_BUILD_DIR:-$DIR/build/linux-loader}"
LAYOUT="$DIR/linux_flash_layout.json"
PYTHON="${PYTHON:-python3}"
AS="${AARCH64_AS:-aarch64-linux-gnu-as}"
LD="${AARCH64_LD:-aarch64-linux-gnu-ld}"
OBJCOPY="${AARCH64_OBJCOPY:-aarch64-linux-gnu-objcopy}"
NM="${AARCH64_NM:-aarch64-linux-gnu-nm}"
READELF="${AARCH64_READELF:-aarch64-linux-gnu-readelf}"
OBJDUMP="${AARCH64_OBJDUMP:-aarch64-linux-gnu-objdump}"

for tool in "$PYTHON" "$AS" "$LD" "$OBJCOPY" "$NM" "$READELF" "$OBJDUMP"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "LINUX_LOADER_TOOL_MISSING tool=$tool"
        exit 127
    fi
done

mkdir -p "$OUT"
echo "LCVEX_LINUX_LOADER_BUILD"
echo "as=$AS ld=$LD objcopy=$OBJCOPY readelf=$READELF objdump=$OBJDUMP python=$PYTHON"
echo "layout=$LAYOUT output=$OUT"

# The assembler constants and host packer consume the same JSON layout.
"$PYTHON" "$DIR/linux_image_format.py" emit-asm \
    --layout "$LAYOUT" --output "$OUT/linux_layout.inc"
"$PYTHON" "$DIR/linux_image_format.py" emit-crc32-table \
    --output "$OUT/linux_crc32_table.inc"
"$AS" -I "$OUT" -o "$OUT/linux_loader.o" "$DIR/linux_loader.S"
"$LD" --build-id=none -T "$DIR/linux_loader.ld" \
    -o "$OUT/linux_loader.elf" "$OUT/linux_loader.o"

if [[ -n "$("$NM" -u "$OUT/linux_loader.elf")" ]]; then
    echo "LINUX_LOADER_UNDEFINED_SYMBOLS"
    "$NM" -u "$OUT/linux_loader.elf"
    exit 1
fi

"$OBJCOPY" -O binary "$OUT/linux_loader.elf" "$OUT/linux_loader.bin"
loader_size="$(stat -c '%s' "$OUT/linux_loader.bin")"
max_size="$("$PYTHON" -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["bram"]["loader_max_bytes"], 0))' "$LAYOUT")"
if (( loader_size > max_size )); then
    echo "LINUX_LOADER_TOO_LARGE bytes=$loader_size limit=$max_size"
    exit 1
fi

# Generate the same byte-HEX and fully populated 64 KiB MIF form used by the
# existing BRAM flow, then let bin_to_mif.py read every byte back.
"$PYTHON" "$DIR/bin_to_mif.py" \
    --input "$OUT/linux_loader.bin" \
    --hex "$OUT/linux_loader.hex" \
    --output "$OUT/linux_loader.mif"

"$READELF" -h -S "$OUT/linux_loader.elf"
"$OBJDUMP" -d "$OUT/linux_loader.elf" > "$OUT/linux_loader.dis"
sha256sum "$OUT/linux_loader.elf" "$OUT/linux_loader.bin" \
    "$OUT/linux_loader.hex" "$OUT/linux_loader.mif"
echo "LINUX_LOADER_SIZE bytes=$loader_size capacity=$max_size bram=65536"
echo "LCVEX_LINUX_LOADER_BUILD_PASS"
