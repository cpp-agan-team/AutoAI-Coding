#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/verification workspace project with spaces"
change=temporary-consumer
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/setup-dependency-calls.log"
install_stub_path
reset_stub_environment

note '离线生成包含临时验证工作区入口的 Harness'
run_setup "$repo"
assert_status 0
export PATH=$REAL_TEST_PATH
assert_path_exists "$repo/scripts/verification_workspace.sh"

mkdir -p "$repo/openspec/changes/$change/harness"

run_at_repo() {
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

run_under_lock() {
    local purpose=$1
    shift
    (
        cd "$repo"
        source scripts/harness_lock.sh
        harness_lock_acquire "$purpose" ""
        harness_lock_bind_change "$change"
        "$@"
    )
}

success_path_record="$tmp/success workspace path.txt"
note 'task-verify 锁内的成功命令获得空工作区、保留 argv 边界并在退出时清理'
run_under_lock task-verify \
    harness_run_evidence_command "$change" \
    scripts/verification_workspace.sh run "$change" -- \
    bash -c '
        set -euo pipefail
        [[ "${AUTOAI_VERIFY_TMPDIR:-}" == "$TMPDIR" ]]
        [[ -z "${AUTOAI_VERIFICATION_WORKSPACE_TOKEN:-}" ]]
        [[ ! -e "$PWD/.ai-harness/locks/managed-operation.lock/verification-workspace-token" ]]
        case "$AUTOAI_VERIFY_TMPDIR" in
            "$PWD/.ai-harness/logs/verification-workspaces/temporary-consumer/run."*) ;;
            *) exit 81 ;;
        esac
        [[ "$1" == "argument with spaces" ]]
        [[ "$2" == "literal-*?[value]" ]]
        [[ -z "$(find "$AUTOAI_VERIFY_TMPDIR" -mindepth 1 -print -quit)" ]]
        printf "temporary source\n" > "$AUTOAI_VERIFY_TMPDIR/probe source.cpp"
        printf "%s\n" "$AUTOAI_VERIFY_TMPDIR" > "$3"
    ' verification-driver 'argument with spaces' 'literal-*?[value]' "$success_path_record"

IFS= read -r success_workspace < "$success_path_record"
assert_path_absent "$success_workspace"
assert_path_absent "$repo/.ai-harness/logs/verification-workspaces/$change"

failure_path_record="$tmp/failure workspace path.txt"
note 'evaluation-run 锁内的失败命令保留原退出码，同时清理一次性源码和输出'
RUN_OUTPUT=
RUN_STATUS=0
set +e
RUN_OUTPUT=$(
    run_under_lock evaluation-run \
        harness_run_evidence_command "$change" \
        scripts/verification_workspace.sh run "$change" -- \
        bash -c '
            set -euo pipefail
            printf "temporary executable\n" > "$AUTOAI_VERIFY_TMPDIR/probe binary"
            printf "%s\n" "$AUTOAI_VERIFY_TMPDIR" > "$1"
            exit 23
        ' verification-driver "$failure_path_record" 2>&1
)
RUN_STATUS=$?
set -e
assert_status 23
IFS= read -r failure_workspace < "$failure_path_record"
assert_path_absent "$failure_workspace"
assert_path_absent "$repo/.ai-harness/logs/verification-workspaces/$change"

note 'assert-clean 能发现残留，cleanup 只清理固定 change 工作区并恢复 clean'
run_under_lock task-verify bash -c '
    set -euo pipefail
    mkdir -p ".ai-harness/logs/verification-workspaces/$1"
    printf "stale probe\n" > ".ai-harness/logs/verification-workspaces/$1/stale.cpp"
' workspace-cleanup-driver "$change"
RUN_OUTPUT=
RUN_STATUS=0
set +e
RUN_OUTPUT=$(run_under_lock task-verify \
    harness_verification_workspace_control assert-clean "$change" 2>&1)
RUN_STATUS=$?
set -e
assert_status 6
assert_contains "$RUN_OUTPUT" 'temporary verification workspace is not empty'
run_under_lock task-verify \
    harness_verification_workspace_control cleanup "$change"
run_under_lock task-verify \
    harness_verification_workspace_control assert-clean "$change"
assert_path_absent "$repo/.ai-harness/logs/verification-workspaces/$change"

note '只读 purpose 可以检查但不能调用破坏性 cleanup'
run_under_lock integration-check \
    harness_verification_workspace_control assert-clean "$change"
RUN_OUTPUT=
RUN_STATUS=0
set +e
RUN_OUTPUT=$(run_under_lock integration-check \
    harness_verification_workspace_control cleanup "$change" 2>&1)
RUN_STATUS=$?
set -e
assert_status 4
assert_contains "$RUN_OUTPUT" 'not authorized for this verification workspace action'

note 'change 工作区自身为 symlink 时 cleanup fail closed，不能触碰外部 victim'
change_root="$repo/.ai-harness/logs/verification-workspaces/$change"
change_root_victim="$tmp/change-root symlink victim"
mkdir -p "$change_root_victim/run.victim"
printf 'must survive change-root symlink cleanup\n' > "$change_root_victim/run.victim/keep.txt"
ln -s "$change_root_victim" "$change_root"
RUN_OUTPUT=
RUN_STATUS=0
set +e
RUN_OUTPUT=$(run_under_lock task-verify \
    harness_verification_workspace_control cleanup "$change" 2>&1)
RUN_STATUS=$?
set -e
[[ "$RUN_STATUS" -ne 0 ]] || fail 'change_root symlink cleanup should fail closed'
[[ -L "$change_root" ]] || fail 'change_root symlink was removed despite failed cleanup'
assert_file_contains "$change_root_victim/run.victim/keep.txt" \
    'must survive change-root symlink cleanup'
unlink -- "$change_root"

note 'change 工作区内部含 nested symlink 时 cleanup 同样拒绝，且不删除链接及其目标'
nested_victim="$tmp/nested symlink victim"
mkdir -p "$change_root" "$nested_victim"
printf 'must survive nested symlink cleanup\n' > "$nested_victim/keep.txt"
ln -s "$nested_victim" "$change_root/run.nested"
RUN_OUTPUT=
RUN_STATUS=0
set +e
RUN_OUTPUT=$(run_under_lock task-verify \
    harness_verification_workspace_control cleanup "$change" 2>&1)
RUN_STATUS=$?
set -e
[[ "$RUN_STATUS" -ne 0 ]] || fail 'nested workspace symlink cleanup should fail closed'
[[ -L "$change_root/run.nested" ]] || fail 'nested workspace symlink was removed despite failed cleanup'
assert_file_contains "$nested_victim/keep.txt" \
    'must survive nested symlink cleanup'

note 'wrapper 脱离受管锁时拒绝执行任何验证命令'
outside_marker="$tmp/outside-lock-command-ran"
run_at_repo scripts/verification_workspace.sh run "$change" -- \
    bash -c 'touch "$1"' verification-driver "$outside_marker"
assert_status 4
assert_contains "$RUN_OUTPUT" 'available only inside a managed task/Evaluation lifecycle command'
assert_path_absent "$outside_marker"

note '陈旧锁即使携带旧 capability 也不能授权执行'
stale_lock="$repo/.ai-harness/locks/managed-operation.lock"
mkdir "$stale_lock"
printf '%s\n' stale-owner-token > "$stale_lock/token"
printf '%s\n' 99999999 > "$stale_lock/pid"
printf '%s\n' task-verify > "$stale_lock/purpose"
printf '%s\n' "$change" > "$stale_lock/change"
printf '%s\n' 2026-01-01T00:00:00Z > "$stale_lock/started_at"
stale_capability=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' "$stale_capability" > "$stale_lock/verification-workspace-token"
chmod 600 "$stale_lock/verification-workspace-token"
run_at_repo env AUTOAI_VERIFICATION_WORKSPACE_TOKEN="$stale_capability" \
    scripts/verification_workspace.sh run "$change" -- \
    bash -c 'touch "$1"' verification-driver "$outside_marker"
assert_status 4
assert_contains "$RUN_OUTPUT" 'stale managed lock cannot authorize'
assert_path_absent "$outside_marker"
rm -rf -- "$stale_lock"

note 'Generator 路径和 Evaluator argv 不能把临时工作区伪装成最终证据'
retained_marker="$tmp/retained-command-ran"
run_at_repo scripts/task_verify.sh 1.1 --kind behavior \
    --path ".ai-harness/logs/verification-workspaces/$change/retained.cpp" -- \
    bash -c 'touch "$1"' verification-driver "$retained_marker"
assert_status 2
assert_contains "$RUN_OUTPUT" 'path escapes the durable project/evidence boundary'
assert_path_absent "$retained_marker"

run_at_repo scripts/evaluator_check.sh --run --kind behavior -- \
    bash -c 'touch "$1"' verification-driver "$retained_marker" \
    'AUTOAI_VERIFY_TMPDIR/retained-consumer.cpp'
assert_status 2
assert_contains "$RUN_OUTPUT" 'Evaluation evidence cannot depend on a temporary verification workspace path'
assert_path_absent "$retained_marker"

note '成功、失败、显式清理和证据保留边界均符合临时验证零留存契约'
