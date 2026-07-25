#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
repo="$tmp/lock protocol project"
holder_pid=
release_fifo="$tmp/release.fifo"

stop_holder() {
    if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
        printf 'release\n' >&9 2>/dev/null || true
        wait "$holder_pid" 2>/dev/null || true
    fi
    exec 9>&- 2>/dev/null || true
    rm -rf -- "$tmp"
}
trap stop_holder EXIT

init_git_repo "$repo"
export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0
(
    cd "$repo"
    scripts/change_new.sh lock-probe >/dev/null
)

mkfifo "$release_fifo"
exec 9<> "$release_fifo"
ready="$tmp/holder.ready"
(
    cd "$repo"
    source scripts/harness_lock.sh
    harness_lock_acquire task-verify lock-probe
    : > "$ready"
    read -r _ < "$release_fifo"
) &
holder_pid=$!

for _ in $(seq 1 100); do
    [[ -e "$ready" ]] && break
    kill -0 "$holder_pid" 2>/dev/null || fail 'lock holder exited before publishing readiness'
    sleep 0.05
done
[[ -e "$ready" ]] || fail 'lock holder did not become ready'
lock_dir="$repo/.ai-harness/locks/managed-operation.lock"
assert_path_exists "$lock_dir/token"
lock_before=$(fingerprint_tree "$lock_dir")
root_before=$(sha256sum -- "$repo/ai_snapshot.json" | awk '{print $1}')

run_locked() {
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

note '已有 owner lock 时第二个受管写入口在任何 snapshot/evidence 写入前拒绝'
run_locked scripts/change_select.sh --clear
assert_status 4
assert_contains "$RUN_OUTPUT" 'lock is held'
[[ "$root_before" == "$(sha256sum -- "$repo/ai_snapshot.json" | awk '{print $1}')" ]] || fail 'contending selector mutated root snapshot'
[[ "$lock_before" == "$(fingerprint_tree "$lock_dir")" ]] || fail 'contending selector modified the owner lock'

note 'setup --force 同样服从共享锁，不能更新模板或创建备份'
tree_before=$(fingerprint_tree "$repo")
run_setup "$repo" --force
assert_status 4
assert_contains "$RUN_OUTPUT" '正被另一个受管入口使用'
tree_after=$(fingerprint_tree "$repo")
[[ "$tree_before" == "$tree_after" ]] || fail 'contending setup --force changed the worktree'

note '伪造 inherited token 和错误 parent purpose 都在 helper 执行前拒绝'
run_locked env AUTOAI_LOCK_TOKEN=definitely-wrong AUTOAI_PARENT_PURPOSE=task-verify \
    scripts/change_footprint.sh lock-probe --check --json
assert_status 4
assert_contains "$RUN_OUTPUT" 'token mismatch'
[[ "$lock_before" == "$(fingerprint_tree "$lock_dir")" ]] || fail 'wrong inherited token modified the owner lock'

owner_token=$(cat "$lock_dir/token")
run_locked env AUTOAI_LOCK_TOKEN="$owner_token" AUTOAI_PARENT_PURPOSE=evaluation-abort \
    scripts/change_footprint.sh lock-probe --check --json
assert_status 4
assert_contains "$RUN_OUTPUT" 'parent purpose does not authorize'
[[ "$lock_before" == "$(fingerprint_tree "$lock_dir")" ]] || fail 'wrong inherited parent modified the owner lock'

note '正确 token/purpose 复用 owner lock，不重入死锁；后续业务门禁仍独立生效'
run_locked env AUTOAI_LOCK_TOKEN="$owner_token" AUTOAI_PARENT_PURPOSE=task-verify \
    scripts/change_footprint.sh lock-probe --check --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'design and local snapshot required'
[[ "$lock_before" == "$(fingerprint_tree "$lock_dir")" ]] || fail 'authorized nested read check modified the owner lock'

printf 'release\n' >&9
wait "$holder_pid"
holder_pid=
assert_path_absent "$lock_dir"

note '并发 lock、错误 token/purpose 和授权嵌套检查均符合单写者协议'
