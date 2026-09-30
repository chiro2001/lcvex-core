#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
BUILD_SCRIPT="$REPO/scripts/build-linux-catapult.sh"
BUILD_ROOT="${CATAPULT_TEST_BUILD_ROOT:-$REPO/build/tmp}"

command -v git >/dev/null || { echo "ERROR: git is required" >&2; exit 1; }
mkdir -p "$BUILD_ROOT"
OUT="$(mktemp -d "$BUILD_ROOT/kernel-source-id.XXXXXX")"
trap 'rm -rf -- "$OUT"' EXIT

# A directory below the LCVEX checkout is not a Linux Git source root.
NESTED_SOURCE="$OUT/nested-linux-source"
mkdir -p "$NESTED_SOURCE"
PARENT_SHA="$(git -C "$REPO" rev-parse HEAD)"
PARENT_TOP="$(git -C "$NESTED_SOURCE" rev-parse --show-toplevel)"
[[ "$PARENT_TOP" == "$REPO" ]] || {
	echo "ERROR: fixture did not resolve to the parent LCVEX Git root" >&2
	exit 1
}

SOURCE_ID="$("$BUILD_SCRIPT" --kernel-src "$NESTED_SOURCE" --source-id-only)"
[[ "$SOURCE_ID" == "no-git-metadata" && "$SOURCE_ID" != "$PARENT_SHA" ]] || {
	echo "ERROR: nested source inherited parent Git identity: $SOURCE_ID" >&2
	exit 1
}

SOURCE_ID="$(KERNEL_SOURCE_ID=archive-sha256:test "$BUILD_SCRIPT" \
	--kernel-src "$NESTED_SOURCE" --source-id-only)"
[[ "$SOURCE_ID" == "archive-sha256:test" ]] || {
	echo "ERROR: KERNEL_SOURCE_ID fallback was ignored: $SOURCE_ID" >&2
	exit 1
}

# A standalone Git checkout still reports its own revision.
GIT_SOURCE="$OUT/linux-source-git"
git -c init.defaultBranch=main init -q "$GIT_SOURCE"
printf 'VERSION = 6\nPATCHLEVEL = 6\n' > "$GIT_SOURCE/Makefile"
git -C "$GIT_SOURCE" add Makefile
git -C "$GIT_SOURCE" -c user.name=SourceTest -c user.email=source-test@example.invalid \
	commit -qm initial
EXPECTED_SHA="$(git -C "$GIT_SOURCE" rev-parse HEAD)"
SOURCE_ID="$("$BUILD_SCRIPT" --kernel-src "$GIT_SOURCE" --source-id-only)"
[[ "$SOURCE_ID" == "$EXPECTED_SHA" ]] || {
	echo "ERROR: standalone source revision mismatch: got $SOURCE_ID expected $EXPECTED_SHA" >&2
	exit 1
}

echo "PASS: kernel source identity rejects parent Git roots and accepts its own revision"
