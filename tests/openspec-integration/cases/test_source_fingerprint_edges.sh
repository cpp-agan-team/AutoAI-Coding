#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/source fingerprint edge project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0
export PATH=$REAL_TEST_PATH

git -C "$repo" config user.name 'AutoAI Fingerprint Edge Test'
git -C "$repo" config user.email 'autoai-fingerprint-edge@example.invalid'
mkdir -p "$repo/src"
printf 'int rename_probe() { return 1; }\n' > "$repo/src/rename-me.cpp"
git -C "$repo" add -A
git -C "$repo" commit -qm 'source fingerprint baseline'

source_fp() {
    (cd "$repo" && scripts/source_fingerprint.sh --kind source)
}

baseline=$(source_fp)
[[ "$baseline" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'baseline source fingerprint shape is invalid'

note 'Git 合法的换行文件名通过 NUL 边界稳定计入 fingerprint'
newline_path=$'src/line\nbreak.cpp'
printf 'int newline_probe() { return 2; }\n' > "$repo/$newline_path"
newline_fp_1=$(source_fp)
newline_fp_2=$(source_fp)
[[ "$newline_fp_1" == "$newline_fp_2" && "$newline_fp_1" != "$baseline" ]] || fail 'newline path was unstable or omitted from source fingerprint'
printf 'int newline_probe() { return 3; }\n' > "$repo/$newline_path"
newline_changed=$(source_fp)
[[ "$newline_changed" != "$newline_fp_1" ]] || fail 'newline-path content change did not change source fingerprint'
rm -f -- "$repo/$newline_path"
[[ "$(source_fp)" == "$baseline" ]] || fail 'removing the newline-path probe did not restore baseline fingerprint'

note 'tracked rename 和 delete 都改变 fingerprint，恢复路径/字节后可回到原值'
git -C "$repo" mv -- src/rename-me.cpp src/renamed.cpp
rename_fp=$(source_fp)
[[ "$rename_fp" != "$baseline" ]] || fail 'tracked rename was omitted from source fingerprint'
git -C "$repo" mv -- src/renamed.cpp src/rename-me.cpp
[[ "$(source_fp)" == "$baseline" ]] || fail 'renaming the tracked file back did not restore fingerprint'

rm -f -- "$repo/src/rename-me.cpp"
delete_fp=$(source_fp)
[[ "$delete_fp" != "$baseline" ]] || fail 'tracked deletion was omitted from source fingerprint'
printf 'int rename_probe() { return 1; }\n' > "$repo/src/rename-me.cpp"
[[ "$(source_fp)" == "$baseline" ]] || fail 'restoring deleted file bytes did not restore fingerprint'

note '本地 gitlink 的 index OID、HEAD 与 dirty status 都进入 source fingerprint'
suborigin="$tmp/submodule origin"
init_git_repo "$suborigin"
git -C "$suborigin" config user.name 'AutoAI Gitlink Origin'
git -C "$suborigin" config user.email 'autoai-gitlink@example.invalid'
printf 'int module_value() { return 4; }\n' > "$suborigin/module.cpp"
git -C "$suborigin" add module.cpp
git -C "$suborigin" commit -qm 'initial module'
git -c protocol.file.allow=always -C "$repo" submodule add -q "$suborigin" deps/module
git -C "$repo" add .gitmodules deps/module
gitlink_clean_1=$(source_fp)
gitlink_clean_2=$(source_fp)
[[ "$gitlink_clean_1" == "$gitlink_clean_2" && "$gitlink_clean_1" != "$baseline" ]] || fail 'clean gitlink fingerprint is unstable or omitted'

note '未初始化 gitlink 的 checkout 缺失或仅剩空目录时必须 fail-closed'
git -C "$repo" submodule deinit -f --quiet -- deps/module
rm -rf -- "$repo/deps/module"
set +e
missing_gitlink_output=$(source_fp 2>&1)
missing_gitlink_rc=$?
set -e
[[ "$missing_gitlink_rc" -eq 6 ]] || fail "missing uninitialized gitlink 应 rc=6，实际 rc=$missing_gitlink_rc: $missing_gitlink_output"
assert_contains "$missing_gitlink_output" 'gitlink'

mkdir -p "$repo/deps/module"
set +e
empty_gitlink_output=$(source_fp 2>&1)
empty_gitlink_rc=$?
set -e
[[ "$empty_gitlink_rc" -eq 6 ]] || fail "empty uninitialized gitlink 应 rc=6，实际 rc=$empty_gitlink_rc: $empty_gitlink_output"
assert_contains "$empty_gitlink_output" 'gitlink'

git -c protocol.file.allow=always -C "$repo" submodule update --init -- deps/module >/dev/null
[[ "$(source_fp)" == "$gitlink_clean_1" ]] || fail '重新初始化 gitlink 后 source fingerprint 未恢复'

printf 'int module_value() { return 5; }\n' > "$repo/deps/module/module.cpp"
gitlink_dirty=$(source_fp)
[[ "$gitlink_dirty" != "$gitlink_clean_1" ]] || fail 'dirty tracked content inside gitlink did not affect source fingerprint'
printf 'int module_value() { return 6; }\n' > "$repo/deps/module/module.cpp"
gitlink_dirty_second=$(source_fp)
gitlink_failures=0
if [[ "$gitlink_dirty_second" == "$gitlink_dirty" ]]; then
    printf '[ASSERT] changing bytes inside an already-dirty gitlink did not change source fingerprint\n' >&2
    gitlink_failures=$((gitlink_failures + 1))
fi
printf 'int module_value() { return 4; }\n' > "$repo/deps/module/module.cpp"
[[ "$(source_fp)" == "$gitlink_clean_1" ]] || fail 'restoring gitlink tracked bytes did not restore fingerprint'

printf 'untracked inside gitlink\n' > "$repo/deps/module/untracked.txt"
gitlink_untracked=$(source_fp)
[[ "$gitlink_untracked" != "$gitlink_clean_1" ]] || fail 'untracked gitlink state did not affect source fingerprint'
rm -f -- "$repo/deps/module/untracked.txt"
[[ "$(source_fp)" == "$gitlink_clean_1" ]] || fail 'removing gitlink untracked state did not restore fingerprint'

git -C "$repo/deps/module" config user.name 'AutoAI Gitlink Child'
git -C "$repo/deps/module" config user.email 'autoai-gitlink-child@example.invalid'
printf 'int module_value() { return 7; }\n' > "$repo/deps/module/module.cpp"
git -C "$repo/deps/module" add module.cpp
git -C "$repo/deps/module" commit -qm 'advance gitlink HEAD'
gitlink_head_changed=$(source_fp)
[[ "$gitlink_head_changed" != "$gitlink_clean_1" ]] || fail 'child gitlink HEAD change did not affect source fingerprint'
git -C "$repo" add deps/module
gitlink_index_updated=$(source_fp)
[[ "$gitlink_index_updated" != "$gitlink_head_changed" ]] || fail 'superproject gitlink index OID change did not affect source fingerprint'

(( gitlink_failures == 0 )) || fail "gitlink dirty-content fingerprint regression failed ($gitlink_failures assertions)"
note 'newline path、rename/delete 与 gitlink 状态都具有稳定且敏感的 source digest'
