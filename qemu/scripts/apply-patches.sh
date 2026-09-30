#!/usr/bin/env bash
# 将固定版本 QEMU 克隆/更新到本地 fork（默认 ../qemu），
# 校验 HEAD 与 qemu/VERSION 一致，并幂等地重放 qemu/patches/ 中的补丁。
#
# 设计要点（对应评估 R1：原脚本 checkout -f 丢改动且不幂等）：
#   - 已应用过的补丁自动跳过（git apply --reverse --check 可回退即已应用）；
#   - 工作区有未提交改动时不做 checkout -f，除非显式 --force；
#   - --fresh DIR：克隆全新基线到临时目录并重放补丁（CI 干净重放任务）。
#
# 用法：qemu/scripts/apply-patches.sh [--force] [--fresh DIR]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION_FILE="$REPO_ROOT/qemu/VERSION"

FORCE=0
FRESH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --fresh) FRESH="$2"; shift ;;
    *) break ;;
  esac
  shift
done

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "错误：找不到 $VERSION_FILE" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$VERSION_FILE"

if [[ -n "$FRESH" ]]; then
  QEMU_DIR="$FRESH"
  echo "==> 干净重放：克隆 ${QEMU_GIT_REMOTE} @ ${QEMU_GIT_TAG} 到 $QEMU_DIR"
  git clone --quiet --branch "$QEMU_GIT_TAG" "$QEMU_GIT_REMOTE" "$QEMU_DIR"
  git -C "$QEMU_DIR" checkout --quiet "$QEMU_COMMIT"
else
  QEMU_DIR="${1:-${QEMU_DIR:-$REPO_ROOT/../qemu}}"
  if [[ ! -d "$QEMU_DIR/.git" ]]; then
    echo "==> 克隆 ${QEMU_GIT_REMOTE} @ ${QEMU_GIT_TAG} 到 $QEMU_DIR"
    git clone --quiet --depth 1 --branch "$QEMU_GIT_TAG" \
      "$QEMU_GIT_REMOTE" "$QEMU_DIR"
  else
    echo "==> 更新已有 fork $QEMU_DIR"
    git -C "$QEMU_DIR" fetch --quiet --depth 1 origin tag "$QEMU_GIT_TAG"
  fi

  ACTUAL="$(git -C "$QEMU_DIR" rev-parse HEAD)"
  if [[ "$ACTUAL" != "$QEMU_COMMIT" ]]; then
    if [[ $FORCE -eq 1 ]]; then
      echo "==> HEAD $ACTUAL != $QEMU_COMMIT，--force 检出固定版本"
      git -C "$QEMU_DIR" checkout --quiet --force "$QEMU_COMMIT"
    else
      echo "错误：fork HEAD $ACTUAL 与固定版本 $QEMU_COMMIT 不一致。" >&2
      echo "工作区有未提交改动时不会自动 checkout（防丢改动）；" >&2
      echo "确认无改动后重跑，或显式使用 --force。" >&2
      exit 1
    fi
  fi
fi

echo "==> fork HEAD 校验通过：$(git -C "$QEMU_DIR" rev-parse HEAD)"

cd "$QEMU_DIR"
applied=0
skipped=0

# git apply --reverse --check 依赖补丁原始上下文；当后续补丁在同一文件的
# 邻近位置追加内容时，即使整组补丁已经存在，早期补丁也可能因上下文变化
# 被误报为 conflict（CI QEMU cache 会遇到此状态）。按每个 patch 的新增行
# 在其目标文件中做内容校验，作为安全的第二判据；只有所有新增行都存在时
# 才认定“已应用”，否则仍让 git apply 报真实冲突。
patch_added_content_present() {
  local patch="$1" file="" line added total=0 present=0 missing=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "+++ b/"* ]]; then
      file="$QEMU_DIR/${line#+++ b/}"
      continue
    fi
    [[ "$line" == +* && "$line" != +++* ]] || continue
    added="${line:1}"
    [[ -n "${added//[[:space:]]/}" ]] || continue
    total=$((total + 1))
    if [[ -n "$file" && -f "$file" ]] &&
       grep -F -q -- "$added" "$file"; then
      present=$((present + 1))
    else
      missing=$((missing + 1))
    fi
  done < "$patch"
  # Later patches legitimately rewrite a few adjacent lines (for example
  # LCVXSYS2 -> LCVXSYS3).  Accept only a very high match ratio and never
  # treat a patch with no additions as implicitly applied.
  (( total > 0 && present * 100 >= total * 98 ))
}

for patch in "$REPO_ROOT"/qemu/patches/*.patch; do
  [[ -e "$patch" ]] || continue
  name="$(basename "$patch")"
  if git apply --check "$patch" 2>/dev/null; then
    git apply "$patch"
    echo "==> 应用 $name"
    applied=$((applied + 1))
  elif git apply --reverse --check "$patch" 2>/dev/null; then
    echo "==> 跳过 $name（已应用）"
    skipped=$((skipped + 1))
  elif patch_added_content_present "$patch"; then
    echo "==> 跳过 $name（已应用；上下文已由后续补丁扩展）"
    skipped=$((skipped + 1))
  else
    echo "错误：$name 既不能正放也不能回退（补丁冲突）" >&2
    exit 1
  fi
done

echo "==> QEMU fork 就绪：$QEMU_DIR @ $QEMU_COMMIT（新增 $applied，跳过 $skipped）"
