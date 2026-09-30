#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
BUILD_SCRIPT="$REPO/scripts/build-linux-catapult.sh"

DEFAULT_IDENTITY="$("$BUILD_SCRIPT" --resource-lock-identity-only)"
[[ "$DEFAULT_IDENTITY" == "local lcvex T-20260928-003 linux_software" ]] || {
	echo "ERROR: unexpected default resource-lock labels: $DEFAULT_IDENTITY" >&2
	exit 1
}

OVERRIDE_IDENTITY="$(RESOURCE_TASK_ID=T-20260928-002 RESOURCE_OWNER=root \
	"$BUILD_SCRIPT" --resource-lock-identity-only)"
[[ "$OVERRIDE_IDENTITY" == "local lcvex T-20260928-002 root" ]] || {
	echo "ERROR: resource-lock label overrides were ignored: $OVERRIDE_IDENTITY" >&2
	exit 1
}

echo "PASS: default and overridden resource-lock task/owner labels"
