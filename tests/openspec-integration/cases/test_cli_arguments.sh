#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/cli project"
mkdir -p "$repo"
removed_legacy_option=--no-openspec

note '--help 在依赖检查和写入前成功退出'
before=$(fingerprint_tree "$repo")
run_setup "$repo" --help
assert_status 0
assert_contains "$RUN_OUTPUT" '--migrate-openspec'
[[ "$RUN_OUTPUT" != *'--no-openspec'* ]] ||
    fail '--help 仍公开已经移除的 --no-openspec'
after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail '--help 修改了目标工作树'

note '-h alias 与 --version 都在依赖检查和写入前终止'
run_setup "$repo" -h
assert_status 0
assert_contains "$RUN_OUTPUT" '--detect-project'
run_setup "$repo" --version
assert_status 0
assert_contains "$RUN_OUTPUT" 'AutoAI Harness'
after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail '-h/--version 修改了目标工作树'

note '未知参数返回稳定的参数错误退出码'
run_setup "$repo" --definitely-unknown
assert_status 2
assert_contains "$RUN_OUTPUT" '未知参数'

note '--dry-run 不能脱离迁移模式使用'
run_setup "$repo" --dry-run
assert_status 2
assert_contains "$RUN_OUTPUT" '--dry-run'

note '已移除的 --no-openspec 作为未知参数拒绝'
run_setup "$repo" "$removed_legacy_option"
assert_status 2
assert_contains "$RUN_OUTPUT" '未知参数'

note '--no-openspec 不能与 migration 组合成隐藏兼容入口'
run_setup "$repo" --migrate-openspec "$removed_legacy_option"
assert_status 2
assert_contains "$RUN_OUTPUT" '未知参数'

note '--force 不能与 dry-run 组合成隐式迁移授权'
run_setup "$repo" --migrate-openspec --dry-run --force
assert_status 2
assert_contains "$RUN_OUTPUT" '--force'

after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail '无效 CLI 参数组合修改了目标工作树'
