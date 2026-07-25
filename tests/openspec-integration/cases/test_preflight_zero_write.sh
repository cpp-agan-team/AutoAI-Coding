#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path

seed_target() {
    local directory=$1
    mkdir -p "$directory/existing dir"
    printf 'keep me\n' > "$directory/existing dir/user file.txt"
    printf 'user-ignore\n' > "$directory/.gitignore"
    chmod 640 "$directory/existing dir/user file.txt"
    chmod 750 "$directory/existing dir"
}

assert_no_target_write() {
    local name=$1
    local directory=$2
    local expected_status=$3
    shift 3
    local before after
    before=$(fingerprint_tree "$directory")
    run_setup "$directory" "$@"
    assert_status "$expected_status"
    after=$(fingerprint_tree "$directory")
    [[ "$before" == "$after" ]] || fail "$name 失败后修改了目标工作树内容、类型或权限"
}

assert_no_target_write_with_path() {
    local name=$1
    local directory=$2
    local expected_status=$3
    local restricted_path=$4
    local before after setup_input=${SETUP_INPUT:-$'\n\n\n'}
    before=$(fingerprint_tree "$directory")
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(
        cd "$directory" || exit 97
        printf '%s' "$setup_input" | env PATH="$restricted_path" /bin/bash "$SETUP_SCRIPT" 2>&1
    )
    RUN_STATUS=$?
    set -e
    assert_status "$expected_status"
    after=$(fingerprint_tree "$directory")
    [[ "$before" == "$after" ]] || fail "$name 失败后修改了目标工作树内容、类型或权限"
}

note '非 Git 仓库在任何目标写入前退出'
reset_stub_environment
repo="$tmp/not a git repo"
seed_target "$repo"
assert_no_target_write 'not-git' "$repo" 3

note 'Git 仓库子目录不是受支持的运行根，任何目标写入前退出'
reset_stub_environment
root_repo="$tmp/repository root"
repo="$root_repo/nested target"
seed_target "$repo"
init_git_repo "$root_repo"
assert_no_target_write 'not-repository-root' "$repo" 3
assert_contains "$RUN_OUTPUT" '仓库根目录'

note 'Node 版本不足在任何目标写入前退出'
reset_stub_environment
repo="$tmp/old node repo"
seed_target "$repo"
init_git_repo "$repo"
export STUB_NODE_VERSION=v20.18.0
assert_no_target_write 'old-node' "$repo" 3

note 'npm 与 npx 分别缺失时都在任何目标写入前退出'
restricted_base="$tmp/restricted dependency path"
mkdir -p "$restricted_base"
ln -s "$(command -v bash)" "$restricted_base/bash"
ln -s "$(command -v date)" "$restricted_base/date"
ln -s "$(command -v git)" "$restricted_base/git"
ln -s "$STUB_BIN/node" "$restricted_base/node"

reset_stub_environment
repo="$tmp/missing npm repo"
seed_target "$repo"
init_git_repo "$repo"
assert_no_target_write_with_path 'missing-npm' "$repo" 3 "$restricted_base"
assert_contains "$RUN_OUTPUT" '缺少 npm'

ln -s "$STUB_BIN/npm" "$restricted_base/npm"
reset_stub_environment
repo="$tmp/missing npx repo"
seed_target "$repo"
init_git_repo "$repo"
assert_no_target_write_with_path 'missing-npx' "$repo" 3 "$restricted_base"
assert_contains "$RUN_OUTPUT" '缺少 npx'

note 'npx registry/cache 失败在任何目标写入前退出'
reset_stub_environment
repo="$tmp/npx failure repo"
seed_target "$repo"
init_git_repo "$repo"
export STUB_NPX_MODE=fail
assert_no_target_write 'npx-failure' "$repo" 3

note '固定 runner 版本不匹配时拒绝降级且不写目标'
reset_stub_environment
repo="$tmp/version mismatch repo"
seed_target "$repo"
init_git_repo "$repo"
export STUB_OPENSPEC_VERSION=1.6.1
assert_no_target_write 'version-mismatch' "$repo" 3

note '只有 config 或缺少 archive 的部分 OpenSpec 结构必须在写入前退出'
reset_stub_environment
repo="$tmp/partial openspec config repo"
seed_target "$repo"
init_git_repo "$repo"
mkdir -p "$repo/openspec"
printf 'schema: spec-driven\n' > "$repo/openspec/config.yaml"
assert_no_target_write 'partial-openspec-config-only' "$repo" 4
assert_contains "$RUN_OUTPUT" '不完整 OpenSpec'

reset_stub_environment
repo="$tmp/partial openspec archive repo"
seed_target "$repo"
init_git_repo "$repo"
mkdir -p "$repo/openspec/specs" "$repo/openspec/changes"
printf 'schema: spec-driven\n' > "$repo/openspec/config.yaml"
assert_no_target_write 'partial-openspec-missing-archive' "$repo" 4
assert_contains "$RUN_OUTPUT" 'openspec/changes/archive'

note '固定 1.6.0 的 list JSON 项目根契约不匹配时在写入前退出'
reset_stub_environment
repo="$tmp/incompatible list repo"
seed_target "$repo"
init_git_repo "$repo"
mkdir -p "$repo/openspec/specs" "$repo/openspec/changes/archive"
printf 'schema: spec-driven\n' > "$repo/openspec/config.yaml"
export STUB_OPENSPEC_LIST_MODE=malformed
assert_no_target_write 'incompatible-list-contract' "$repo" 4
assert_contains "$RUN_OUTPUT" '项目列表契约'

note '识别到 legacy 时要求显式迁移，--force 也不能越过'
reset_stub_environment
repo="$tmp/legacy conflict repo"
seed_target "$repo"
init_git_repo "$repo"
cp -R "$TEST_ROOT/fixtures/legacy/recognized/." "$repo/"
assert_no_target_write 'legacy-conflict' "$repo" 4 --force
assert_contains "$RUN_OUTPUT" 'migrate'

note 'fresh init 后再次扫描；上游意外生成 /opsx asset 时停止而不继续写 Harness 模板'
reset_stub_environment
repo="$tmp/post init opsx repo"
seed_target "$repo"
init_git_repo "$repo"
export STUB_OPENSPEC_INIT_ASSET_MODE=opsx
run_setup "$repo"
assert_status 6
assert_contains "$RUN_OUTPUT" '/opsx Agent assets'
[[ -f "$repo/.claude/commands/opsx-injected.md" ]] || fail 'fixture did not inject the unsupported asset'
[[ ! -e "$repo/AGENTS.md" && ! -e "$repo/scripts/change_new.sh" ]] || fail 'Harness templates were written after the post-init asset gate failed'
