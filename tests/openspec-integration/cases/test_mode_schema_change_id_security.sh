#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
removed_legacy_option=--no-openspec
export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

seed_openspec_project() {
    local repo=$1 schema=$2
    init_git_repo "$repo"
    mkdir -p "$repo/openspec/specs" "$repo/openspec/changes/archive"
    printf 'schema: %s\n' "$schema" > "$repo/openspec/config.yaml"
    printf 'USER SENTINEL\n' > "$repo/user-sentinel.txt"
    chmod 640 "$repo/user-sentinel.txt"
}

note 'custom schema 在默认模式依赖探测后、任何目标写入前被拒绝'
custom_repo="$tmp/custom schema project"
seed_openspec_project "$custom_repo" custom-workflow
before=$(fingerprint_tree "$custom_repo")
run_setup "$custom_repo"
assert_status 4
assert_contains "$RUN_OUTPUT" 'spec-driven schema'
after=$(fingerprint_tree "$custom_repo")
[[ "$before" == "$after" ]] || fail 'custom schema 拒绝路径修改了目标工作树'

note '已移除的 --no-openspec 在任何依赖探测或写入前作为未知参数拒绝'
openspec_legacy_repo="$tmp/openspec plus legacy flag"
seed_openspec_project "$openspec_legacy_repo" spec-driven
before=$(fingerprint_tree "$openspec_legacy_repo")
: > "$STUB_CALL_LOG"
run_setup "$openspec_legacy_repo" "$removed_legacy_option"
assert_status 2
assert_contains "$RUN_OUTPUT" '未知参数'
after=$(fingerprint_tree "$openspec_legacy_repo")
[[ "$before" == "$after" ]] || fail '被移除的 --no-openspec 修改了目标工作树'
[[ ! -s "$STUB_CALL_LOG" ]] || fail '被移除的 --no-openspec 仍探测了 Node/npm/npx'

note '所有 change-aware 公开入口显式拒绝 traversal/reserved change ID'
runtime_base="$tmp/malicious change id base"
init_git_repo "$runtime_base"
reset_stub_environment
run_setup "$runtime_base"
assert_status 0
export PATH=$REAL_TEST_PATH

victim="$tmp/change-id-victim"
printf 'CHANGE ID VICTIM MUST STAY BYTE IDENTICAL\n' > "$victim"
chmod 640 "$victim"

run_bad_id() {
    local label=$1 script=$2 id=$3
    shift 3
    local runtime_repo="$tmp/malicious change id $label" victim_before victim_after tree_before tree_after bad=0
    cp -a -- "$runtime_base" "$runtime_repo"
    victim_before="$(stat -c '%a:%s' -- "$victim"):$(sha256sum -- "$victim" | awk '{print $1}')"
    tree_before=$(fingerprint_tree "$runtime_repo")
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$runtime_repo" && "$script" "$@" "$id" 2>&1)
    RUN_STATUS=$?
    set -e
    if [[ "$RUN_STATUS" -ne 2 || "$RUN_OUTPUT" != *'invalid change ID'* ]]; then
        printf '[ASSERT] %s 未以 rc=2 显式拒绝 change ID %q（rc=%s）\n' "$label" "$id" "$RUN_STATUS" >&2
        bad=1
    fi
    victim_after="$(stat -c '%a:%s' -- "$victim"):$(sha256sum -- "$victim" | awk '{print $1}')"
    tree_after=$(fingerprint_tree "$runtime_repo")
    if [[ "$victim_before" != "$victim_after" ]]; then
        printf '[ASSERT] %s malicious change ID 修改了仓库外 victim\n' "$label" >&2
        bad=1
    fi
    if [[ "$tree_before" != "$tree_after" ]]; then
        printf '[ASSERT] %s malicious change ID 拒绝路径留下了工作树写入\n' "$label" >&2
        bad=1
    fi
    (( bad == 0 ))
}

failures=0
traversal='../../../change-id-victim'
run_bad_id change-new scripts/change_new.sh "$traversal" || failures=$((failures + 1))
run_bad_id change-select scripts/change_select.sh "$traversal" || failures=$((failures + 1))
run_bad_id change-status scripts/change_status.sh "$traversal" --json || failures=$((failures + 1))
run_bad_id change-archive scripts/change_archive.sh "$traversal" || failures=$((failures + 1))
run_bad_id evaluator-recheck scripts/evaluator_check.sh "$traversal" --recheck || failures=$((failures + 1))
run_bad_id rca-new scripts/rca_new.sh "$traversal" || failures=$((failures + 1))
run_bad_id reserved-archive scripts/change_new.sh archive || failures=$((failures + 1))
run_bad_id reserved-stale scripts/change_select.sh stale-probe || failures=$((failures + 1))
run_bad_id newline-id scripts/change_new.sh $'safe-name\n../../victim' || failures=$((failures + 1))

(( failures == 0 )) || fail "mode/schema/change-id security regression failed ($failures assertions)"
note '模式互斥、官方 schema 和 change ID 路径边界均有显式负向回归'
