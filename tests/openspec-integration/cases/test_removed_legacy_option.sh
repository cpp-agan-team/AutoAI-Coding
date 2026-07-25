#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/legacy project"
init_git_repo "$repo"
removed_legacy_option=--no-openspec
printf 'USER CONTENT MUST SURVIVE\n' > "$repo/user-owned.txt"
chmod 640 "$repo/user-owned.txt"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
export STUB_NODE_VERSION=v0.0.1
export STUB_NPX_MODE=fail

note '已移除的 legacy 生成选项在写入和依赖探测前拒绝'
before=$(fingerprint_tree "$repo")
run_setup "$repo" "$removed_legacy_option"
assert_status 2
assert_contains "$RUN_OUTPUT" '未知参数'
[[ ! -s "$STUB_CALL_LOG" ]] ||
    fail "被移除的 --no-openspec 调用了 Node/npm/npx：$(cat "$STUB_CALL_LOG")"
[[ "$before" == "$(fingerprint_tree "$repo")" ]] ||
    fail '被移除的 --no-openspec 修改了工作区'

note '--force 不能重新启用已移除的 legacy 生成模式'
run_setup "$repo" --force "$removed_legacy_option"
assert_status 2
assert_contains "$RUN_OUTPUT" '未知参数'
[[ ! -s "$STUB_CALL_LOG" ]] ||
    fail "--force --no-openspec 调用了 Node/npm/npx：$(cat "$STUB_CALL_LOG")"
[[ "$before" == "$(fingerprint_tree "$repo")" ]] ||
    fail '--force 接管了被移除的 legacy 模式或修改了工作区'
