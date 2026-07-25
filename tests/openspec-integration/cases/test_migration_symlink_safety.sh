#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

victim_file_signature() {
    local file=$1
    printf '%s\t%s\t%s\n' \
        "$(stat -c '%a' -- "$file")" \
        "$(stat -c '%s' -- "$file")" \
        "$(sha256sum -- "$file" | awk '{print $1}')"
}

create_symlink_legacy_repo() {
    local repo=$1 victim=$2
    init_git_repo "$repo"
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name 'OpenSpec Migration Symlink Test'
    seed_recognized_legacy_harness "$repo"
    rm -- "$repo/spec.md"
    ln -s "$victim" "$repo/spec.md"
    git -C "$repo" add -A
    git -C "$repo" commit -qm 'legacy fixture with unsafe recognized path'
}

note 'migration dry-run 把已识别 legacy 最终路径 symlink 标为 ambiguous 且保持只读'
victim="$tmp/final-victim.txt"
printf 'MIGRATION VICTIM MUST STAY BYTE IDENTICAL\n' > "$victim"
chmod 640 "$victim"
repo="$tmp/final symlink"
create_symlink_legacy_repo "$repo" "$victim"
before_tree=$(fingerprint_tree "$repo")
before_victim=$(victim_file_signature "$victim")
: > "$STUB_CALL_LOG"
run_setup "$repo" --migrate-openspec --dry-run
assert_status 0
assert_contains "$RUN_OUTPUT" 'spec.md'
assert_contains "$RUN_OUTPUT" 'formal migration is blocked'
[[ "$before_tree" == "$(fingerprint_tree "$repo")" ]] ||
    fail 'migration dry-run 修改了 symlink fixture'
[[ "$before_victim" == "$(victim_file_signature "$victim")" ]] ||
    fail 'migration dry-run 修改了仓库外 victim'
! grep -Fq $'npx\t' "$STUB_CALL_LOG" ||
    fail 'migration dry-run 在 symlink 拒绝路径调用了 npx'

note 'formal migration 在 npx 和任何工作区写入前拒绝 ambiguous symlink'
: > "$STUB_CALL_LOG"
run_setup "$repo" --migrate-openspec
assert_status 5
assert_contains "$RUN_OUTPUT" '所有权歧义'
[[ "$before_tree" == "$(fingerprint_tree "$repo")" ]] ||
    fail 'formal migration 在 symlink 拒绝路径修改了工作区'
[[ "$before_victim" == "$(victim_file_signature "$victim")" ]] ||
    fail 'formal migration 修改了仓库外 victim'
! grep -Fq $'npx\t' "$STUB_CALL_LOG" ||
    fail 'formal migration 在 symlink 拒绝路径调用了 npx'

note '已移除的 legacy 生成选项不再提供普通或 --force 写入旁路'
for args in '--no-openspec' '--force --no-openspec'; do
    before_tree=$(fingerprint_tree "$repo")
    # shellcheck disable=SC2086
    run_setup "$repo" $args
    assert_status 2
    assert_contains "$RUN_OUTPUT" '未知参数'
    [[ "$before_tree" == "$(fingerprint_tree "$repo")" ]] ||
        fail "被移除的参数组合修改了工作区：$args"
done
