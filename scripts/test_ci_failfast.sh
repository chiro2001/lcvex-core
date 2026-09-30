#!/usr/bin/env bash
# 负向测试：ci-difftest/ci-nightly 任一前置步骤失败必须使总结果非零。
# 本测试只做 shell 级注入，不运行 QEMU、Verilator 或真实镜像生成。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/lcvex-ci-failfast-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/scripts" "$SANDBOX/qemu/scripts" \
         "$SANDBOX/qemu/plugins" "$SANDBOX/build/difftest" "$SANDBOX/bin"

cp "$REPO_ROOT/scripts/ci-difftest.sh" "$SANDBOX/scripts/"
cp "$REPO_ROOT/scripts/ci-nightly.sh" "$SANDBOX/scripts/"

cat > "$SANDBOX/qemu/scripts/apply-patches.sh" <<'STUB'
#!/usr/bin/env bash
exit "${APPLY_RC:-0}"
STUB
chmod +x "$SANDBOX/qemu/scripts/apply-patches.sh"

cat > "$SANDBOX/scripts/build-qemu.sh" <<'STUB'
#!/usr/bin/env bash
exit "${BUILD_QEMU_RC:-0}"
STUB
chmod +x "$SANDBOX/scripts/build-qemu.sh"

cat > "$SANDBOX/bin/make" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" lockstep-build-delay2 "*) exit "${MAKE_DELAY2_RC:-0}" ;;
  *" lockstep-build "*)      exit "${MAKE_LOCKSTEP_RC:-0}" ;;
  *" qemu/plugins "*)        exit "${MAKE_PLUGIN_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/bin/make"

cat > "$SANDBOX/bin/python3" <<'STUB'
#!/usr/bin/env bash
exit "${PYTHON_RC:-0}"
STUB
chmod +x "$SANDBOX/bin/python3"

export PATH="$SANDBOX/bin:$PATH"

run_negative() {
  local label="$1" script="$2"
  shift 2
  local rc=0
  set +e
  env "$@" bash "$script" >"$SANDBOX/$label.out" 2>&1
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "FAIL(negative): $label 预期非零退出，实际 0" >&2
    tail -40 "$SANDBOX/$label.out" >&2
    return 1
  fi
  echo "OK(negative): $label 非零退出 rc=$rc"
  return 0
}

run_negative "difftest-qemu-apply"   "$SANDBOX/scripts/ci-difftest.sh" APPLY_RC=1
run_negative "difftest-qemu-build"   "$SANDBOX/scripts/ci-difftest.sh" APPLY_RC=0 BUILD_QEMU_RC=1
run_negative "difftest-plugin-build" "$SANDBOX/scripts/ci-difftest.sh" APPLY_RC=0 BUILD_QEMU_RC=0 MAKE_PLUGIN_RC=1

run_negative "nightly-qemu-apply"    "$SANDBOX/scripts/ci-nightly.sh" APPLY_RC=1
run_negative "nightly-qemu-build"    "$SANDBOX/scripts/ci-nightly.sh" APPLY_RC=0 BUILD_QEMU_RC=1
run_negative "nightly-plugin-build"  "$SANDBOX/scripts/ci-nightly.sh" APPLY_RC=0 MAKE_PLUGIN_RC=1
run_negative "nightly-lockstep"      "$SANDBOX/scripts/ci-nightly.sh" APPLY_RC=0 MAKE_PLUGIN_RC=0 MAKE_LOCKSTEP_RC=1
run_negative "nightly-delay2-build"  "$SANDBOX/scripts/ci-nightly.sh" APPLY_RC=0 MAKE_PLUGIN_RC=0 MAKE_LOCKSTEP_RC=0 MAKE_DELAY2_RC=1
run_negative "nightly-image-gen"     "$SANDBOX/scripts/ci-nightly.sh" APPLY_RC=0 MAKE_PLUGIN_RC=0 MAKE_LOCKSTEP_RC=0 MAKE_DELAY2_RC=0 PYTHON_RC=1

echo "PASS: ci fail-fast 负向测试全部通过"
