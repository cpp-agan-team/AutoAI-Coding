#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT

real_node=$(command -v node)
depbin="$tmp/dependencies"
mkdir -p "$depbin"
ln -s "$real_node" "$depbin/node"
ln -s "$STUB_BIN/npm" "$depbin/npm"
export STUB_CALL_LOG="$tmp/dependency-calls.log"
export STUB_NPX_MODE=success STUB_OPENSPEC_VERSION=1.6.0

repo="$tmp/concurrent migration project"
init_git_repo "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name 'OpenSpec Migration Concurrency Test'
seed_recognized_legacy_harness "$repo"
printf '# legacy migration fixture\nbuild/\n.ai-harness/logs/\n.ai-harness/migrations/\n' \
    > "$repo/.gitignore"
git -C "$repo" add -A
git -C "$repo" commit -qm 'legacy harness fixture'

note '正式迁移获取 setup lock 后必须重验 clean worktree，不吸收并发用户改动'
lock_hook_bin="$tmp/lock-window-bin"
mkdir -p "$lock_hook_bin"
real_mkdir=$(command -v mkdir)
cat > "$lock_hook_bin/mkdir" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'.ai-harness/locks'* && ! -e "${MIGRATION_LOCK_HOOK_DONE:?}" ]]; then
    case "${MIGRATION_LOCK_MUTATION:?}" in
        tracked)
            printf '\nconcurrent-user-edit-after-clean-check\n' >> "${MIGRATION_LOCK_REPO:?}/spec.md"
            ;;
        untracked)
            printf 'concurrent untracked user file\n' > "${MIGRATION_LOCK_REPO:?}/user-lock-window.txt"
            ;;
        *)
            exit 98
            ;;
    esac
    : > "$MIGRATION_LOCK_HOOK_DONE"
fi
exec "${MIGRATION_REAL_MKDIR:?}" "$@"
HOOK
chmod 755 "$lock_hook_bin/mkdir"

for mutation in tracked untracked; do
    lock_repo="$tmp/migration lock window $mutation"
    cp -a -- "$repo" "$lock_repo"
    hook_done="$tmp/lock-window-$mutation.done"
    export MIGRATION_LOCK_HOOK_DONE="$hook_done"
    export MIGRATION_LOCK_MUTATION="$mutation"
    export MIGRATION_LOCK_REPO="$lock_repo"
    export MIGRATION_REAL_MKDIR="$real_mkdir"
    todo_lock_before=$(sha256sum -- "$lock_repo/todo.md" | awk '{print $1}')
    snapshot_lock_before=$(sha256sum -- "$lock_repo/ai_snapshot.json" | awk '{print $1}')

    PATH="$lock_hook_bin:$depbin:$STUB_BIN:$PATH" run_setup "$lock_repo" --migrate-openspec
    assert_status 5
    [[ -e "$hook_done" ]] || fail "$mutation lock-window hook 未在 setup lock 获取时执行"
    assert_path_absent "$lock_repo/openspec"
    assert_path_exists "$lock_repo/spec.md"
    assert_path_exists "$lock_repo/todo.md"
    assert_path_absent "$lock_repo/scripts/change_new.sh"
    [[ ! -d "$lock_repo/.ai-harness/migrations" ]] || \
        [[ -z "$(find "$lock_repo/.ai-harness/migrations" -mindepth 1 -print -quit)" ]] || \
        fail "$mutation lock-window failure 在 clean recheck 前创建了 migration backup/manifest"
    [[ "$todo_lock_before" == "$(sha256sum -- "$lock_repo/todo.md" | awk '{print $1}')" ]] || \
        fail "$mutation lock-window failure 覆盖了 legacy todo.md"
    [[ "$snapshot_lock_before" == "$(sha256sum -- "$lock_repo/ai_snapshot.json" | awk '{print $1}')" ]] || \
        fail "$mutation lock-window failure 覆盖或移动了 legacy ai_snapshot.json"
    if [[ "$mutation" == tracked ]]; then
        assert_file_contains "$lock_repo/spec.md" 'concurrent-user-edit-after-clean-check'
    else
        assert_file_contains "$lock_repo/user-lock-window.txt" 'concurrent untracked user file'
    fi
done
unset MIGRATION_LOCK_HOOK_DONE MIGRATION_LOCK_MUTATION MIGRATION_LOCK_REPO MIGRATION_REAL_MKDIR

todo_before=$(sha256sum "$repo/todo.md" | awk '{print $1}')
snapshot_before=$(sha256sum "$repo/ai_snapshot.json" | awk '{print $1}')

cat > "$depbin/npx" <<'NPX'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == openspec && "${args[$((i + 1))]:-}" == new ]]; then
        printf '\nconcurrent-user-edit-must-survive\n' >> "${CONCURRENT_TARGET:?}"
        break
    fi
done
exec "${OPEN_SPEC_STUB:?}" "$@"
NPX
chmod +x "$depbin/npx"
export CONCURRENT_TARGET="$repo/spec.md" OPEN_SPEC_STUB="$STUB_BIN/npx"

note '备份后并发修改 legacy 源时，迁移在覆盖/删除前停止且不回写旧备份'
PATH="$depbin:$PATH" run_setup "$repo" --migrate-openspec
assert_status 5
assert_contains "$RUN_OUTPUT" '迁移源在备份后发生变化'
assert_file_contains "$repo/spec.md" 'concurrent-user-edit-must-survive'
[[ "$todo_before" == "$(sha256sum "$repo/todo.md" | awk '{print $1}')" ]] || fail '并发停止路径改写了 todo.md'
[[ "$snapshot_before" == "$(sha256sum "$repo/ai_snapshot.json" | awk '{print $1}')" ]] || fail '并发停止路径改写了 ai_snapshot.json'
assert_path_absent "$repo/openspec"

manifest=$(find "$repo/.ai-harness/migrations" -mindepth 2 -maxdepth 2 -name manifest.json -print -quit)
[[ -n "$manifest" ]] || fail '并发停止路径没有保留迁移诊断 manifest'
node - "$manifest" <<'NODE' || fail '并发停止 manifest 未准确标记人工恢复'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
if(d.status!=='failed'||d.failure_step!=='install-openspec-harness'||d.recovery_status!=='manual-attention-required'||!(d.manual_attention||[]).some(x=>x.startsWith('spec.md:')))process.exit(1);
NODE

note '并发用户内容被原样保留，且未进入 legacy 模板覆盖/删除阶段'
