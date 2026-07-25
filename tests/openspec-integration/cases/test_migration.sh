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
ln -s "$STUB_BIN/npx" "$depbin/npx"
export PATH="$depbin:$PATH"
export STUB_CALL_LOG="$tmp/dependency-calls.log"
export STUB_NPX_MODE=success
export STUB_OPENSPEC_VERSION=1.6.0

create_committed_legacy_repo() {
    local repo=$1
    init_git_repo "$repo"
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name 'OpenSpec Migration Test'
    seed_recognized_legacy_harness "$repo"
    printf '# legacy migration fixture\nbuild/\n.ai-harness/logs/\n.ai-harness/migrations/\n' \
        > "$repo/.gitignore"
    local task task_dir
    for task in \
        TASK-20260715010101-preserve-alpha \
        TASK-20260715010102-preserve-beta; do
        task_dir="$repo/tasks/$task"
        mkdir -p "$task_dir"
        printf '# Task — %s\n\nLegacy task body unique to %s.\n' "$task" "$task" > "$task_dir/task.md"
        printf '{\n  "schema_version": 1,\n  "task_id": "%s",\n  "unique_probe": "%s-snapshot"\n}\n' \
            "$task" "$task" > "$task_dir/ai_snapshot.json"
        printf '# Verification — %s\n\nUnique verification probe: %s-verification.\n' \
            "$task" "$task" > "$task_dir/verification.md"
        printf '# Defect RCA — %s\n\nUnique RCA probe: %s-rca.\n' \
            "$task" "$task" > "$task_dir/defect-rca.md"
    done
    mkdir -p "$repo/tasks/user-data"
    printf 'project-owned\n' > "$repo/tasks/user-data/input.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -qm 'legacy harness fixture'
}

repo="$tmp/legacy project"
create_committed_legacy_repo "$repo"

task_expectations="$tmp/task-artifact-expectations.tsv"
(
    cd "$repo"
    for task in \
        TASK-20260715010101-preserve-alpha \
        TASK-20260715010102-preserve-beta; do
        for artifact in task.md ai_snapshot.json verification.md defect-rca.md; do
            path="tasks/$task/$artifact"
            printf '%s\t%s\t%s\n' \
                "$path" \
                "$(stat -c '%a' -- "$path")" \
                "$(sha256sum -- "$path" | awk '{print $1}')"
        done
    done
) > "$task_expectations"

note 'migration dry-run 逐项分类且不运行 npx、不修改工作区'
: > "$STUB_CALL_LOG"
before=$(fingerprint_tree "$repo")
run_setup "$repo" --migrate-openspec --dry-run
assert_status 0
assert_contains "$RUN_OUTPUT" 'AutoAI-owned ('
assert_contains "$RUN_OUTPUT" 'Ambiguous (0)'
assert_contains "$RUN_OUTPUT" 'spec.md'
assert_contains "$RUN_OUTPUT" 'todo.md'
assert_contains "$RUN_OUTPUT" 'ai_snapshot.json'
assert_contains "$RUN_OUTPUT" '.ai-harness/migrations/<UTC timestamp>/'
[[ ! -s "$STUB_CALL_LOG" ]] || fail "dry-run 调用了 npx：$(cat "$STUB_CALL_LOG")"
after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail 'dry-run 改变了工作区内容、类型或权限'

note 'formal migration 建立完整验签备份、审计副本并只删除确认的 legacy 制品'
: > "$STUB_CALL_LOG"
run_setup "$repo" --migrate-openspec
assert_status 0
assert_contains "$RUN_OUTPUT" 'Active migration change:'
grep -Fq $'npx\ttelemetry=0' "$STUB_CALL_LOG" || fail '正式迁移没有经过固定 npx runner'

change=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).active_change" "$repo/ai_snapshot.json")
[[ "$change" == migrate-legacy-harness-* ]] || fail "迁移 change 名称无效：$change"
change_dir="$repo/openspec/changes/$change"
node - "$change_dir/harness/ai_snapshot.json" "$change_dir/harness/verification.json" "$change" <<'NODE'
const fs = require('fs');
const [snapshotFile, verificationFile, change] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
const verification = JSON.parse(fs.readFileSync(verificationFile, 'utf8'));
if (snapshot.schema_version !== 4 || snapshot.planned_integration_completeness_sha256 !== null ||
    verification.schema_version !== 3 || verification.change_name !== change ||
    verification.migration !== null || verification.tasks.length !== 0) {
  throw new Error('migration change did not start with the integrated v4/v3 evidence family');
}
NODE
assert_path_exists "$change_dir/harness/legacy/MIGRATION.md"
assert_file_contains "$change_dir/harness/legacy/MIGRATION.md" 'non-canonical'
assert_path_exists "$change_dir/harness/legacy/spec.md"
assert_path_exists "$change_dir/harness/legacy/todo.md"
assert_path_exists "$change_dir/harness/legacy/ai_snapshot.json"
assert_path_exists "$repo/tasks/user-data/input.txt"
assert_file_contains "$repo/tasks/user-data/input.txt" 'project-owned'
assert_path_exists "$repo/tasks"

for legacy_path in \
    spec.md todo.md; do
    assert_path_absent "$repo/$legacy_path"
done
node - "$repo/ai_snapshot.json" <<'NODE' || fail '迁移没有用统一根 selector 替换 legacy snapshot'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(d.schema_version!==2||typeof d.active_change!=='string'||!d.active_change.startsWith('migrate-legacy-harness-'))process.exit(1);
NODE
assert_path_exists "$repo/scripts/change_new.sh"
assert_path_exists "$repo/docs/ai/implementation-economy.md"
assert_file_contains "$repo/.gitignore" '.ai-harness/migrations/'

manifest=$(find "$repo/.ai-harness/migrations" -mindepth 2 -maxdepth 2 -name manifest.json -print -quit)
[[ -n "$manifest" ]] || fail '正式迁移没有生成本机 manifest'
for legacy_output in spec.md todo.md ai_snapshot.json; do
    expected="$TEST_ROOT/fixtures/legacy/recognized/$legacy_output"
    for retained in \
        "$(dirname "$manifest")/legacy/$legacy_output" \
        "$change_dir/harness/legacy/$legacy_output"; do
        assert_path_exists "$retained"
        [[ "$(stat -c '%a' -- "$retained")" == "$(stat -c '%a' -- "$expected")" ]] ||
            fail "迁移没有保留 recognized fixture 权限：$legacy_output"
        [[ "$(sha256sum -- "$retained" | awk '{print $1}')" == \
           "$(sha256sum -- "$expected" | awk '{print $1}')" ]] ||
            fail "迁移没有逐字节保留 recognized fixture：$legacy_output"
    done
done
while IFS=$'\t' read -r legacy_output expected_mode expected_sha; do
    [[ -n "$legacy_output" ]] || continue
    assert_path_absent "$repo/$legacy_output"
    for retained in \
        "$(dirname "$manifest")/legacy/$legacy_output" \
        "$change_dir/harness/legacy/$legacy_output"; do
        assert_path_exists "$retained"
        [[ "$(stat -c '%a' -- "$retained")" == "$expected_mode" ]] || \
            fail "迁移没有保留 $legacy_output 的权限：$retained"
        [[ "$(sha256sum -- "$retained" | awk '{print $1}')" == "$expected_sha" ]] || \
            fail "迁移没有逐字节保留 $legacy_output：$retained"
    done
done < "$task_expectations"
node - "$repo" "$manifest" <<'NODE' || fail 'manifest、备份或 change 审计副本验签失败'
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const [root,manifest]=process.argv.slice(2),d=JSON.parse(fs.readFileSync(manifest,'utf8'));
if(d.status!=='complete'||d.schema_version!==1||!d.final_audit_set_sha256||d.files.length<11)process.exit(1);
for(const source of ['spec.md','todo.md','ai_snapshot.json']){
  if(!d.files.some(x=>x.source_path===source&&x.classification==='autoai-owned'))process.exit(2);
}
for(const task of ['TASK-20260715010101-preserve-alpha','TASK-20260715010102-preserve-beta']){
  for(const artifact of ['task.md','ai_snapshot.json','verification.md','defect-rca.md']){
    const source=`tasks/${task}/${artifact}`;
    if(!d.files.some(x=>x.source_path===source&&x.classification==='autoai-owned'))process.exit(5);
  }
}
for(const x of d.files){
  const copies=[path.join(path.dirname(manifest),'legacy',x.source_path)];
  if(x.classification==='autoai-owned')copies.push(path.join(root,'openspec/changes',d.change_name,'harness/legacy',x.source_path));
  for(const p of copies){
    const b=fs.readFileSync(p),h='sha256:'+crypto.createHash('sha256').update(b).digest('hex');
    if(h!==x.sha256||b.length!==x.size)process.exit(4);
  }
}
NODE

[[ ! -e "$change_dir/proposal.md" && ! -e "$change_dir/design.md" && ! -e "$change_dir/tasks.md" ]] || \
    fail '迁移不应自动推断 canonical proposal/design/tasks'

note '成功迁移后的重复调用稳定报告无迁移源，不创建第二个 change'
git -C "$repo" add -A
git -C "$repo" commit -qm 'migrated harness'
before_changes=$(find "$repo/openspec/changes" -mindepth 1 -maxdepth 1 -type d ! -name archive | wc -l)
: > "$STUB_CALL_LOG"
run_setup "$repo" --migrate-openspec
assert_status 4
assert_contains "$RUN_OUTPUT" '没有可迁移的 legacy Harness'
[[ ! -s "$STUB_CALL_LOG" ]] || fail '无迁移源的重复调用不应运行 npx'
after_changes=$(find "$repo/openspec/changes" -mindepth 1 -maxdepth 1 -type d ! -name archive | wc -l)
[[ "$before_changes" -eq "$after_changes" ]] || fail '重复迁移创建了额外 change'

note '未知签名属于 ambiguous，正式迁移在任何写入和 npx 前停止'
ambiguous_repo="$tmp/ambiguous"
create_committed_legacy_repo "$ambiguous_repo"
mkdir -p "$ambiguous_repo/scripts"
printf '# user-owned task tool\n' > "$ambiguous_repo/scripts/task_new.sh"
git -C "$ambiguous_repo" add scripts/task_new.sh
git -C "$ambiguous_repo" commit -qm 'replace legacy-looking path'
ambiguous_before=$(fingerprint_tree "$ambiguous_repo")
run_setup "$ambiguous_repo" --migrate-openspec --dry-run
assert_status 0
assert_contains "$RUN_OUTPUT" 'scripts/task_new.sh'
assert_contains "$RUN_OUTPUT" 'formal migration is blocked'
[[ "$ambiguous_before" == "$(fingerprint_tree "$ambiguous_repo")" ]] || fail 'ambiguous dry-run 修改了工作区'
: > "$STUB_CALL_LOG"
run_setup "$ambiguous_repo" --migrate-openspec
assert_status 5
assert_contains "$RUN_OUTPUT" '所有权歧义'
[[ ! -s "$STUB_CALL_LOG" ]] || fail 'ambiguous 正式迁移不应运行 npx'
assert_file_contains "$ambiguous_repo/scripts/task_new.sh" '# user-owned task tool'
[[ -z "$(git -C "$ambiguous_repo" status --porcelain=v1 --untracked-files=all)" ]] || fail 'ambiguous 正式迁移改变了工作区'

note '混合状态迁移保留已有 config、主 specs 和其他 change，且不重复 init'
mixed_repo="$tmp/mixed"
create_committed_legacy_repo "$mixed_repo"
mkdir -p "$mixed_repo/openspec/specs/existing-capability" \
    "$mixed_repo/openspec/changes/team-change" "$mixed_repo/openspec/changes/archive"
printf 'schema: spec-driven\n# team-owned config\n' > "$mixed_repo/openspec/config.yaml"
printf '# Existing capability\n\nTeam-owned canonical spec.\n' > "$mixed_repo/openspec/specs/existing-capability/spec.md"
printf '# Team change proposal\n' > "$mixed_repo/openspec/changes/team-change/proposal.md"
git -C "$mixed_repo" add -A
git -C "$mixed_repo" commit -qm 'add existing OpenSpec team artifacts'
config_hash=$(sha256sum "$mixed_repo/openspec/config.yaml" | awk '{print $1}')
spec_hash=$(sha256sum "$mixed_repo/openspec/specs/existing-capability/spec.md" | awk '{print $1}')
team_change_hash=$(sha256sum "$mixed_repo/openspec/changes/team-change/proposal.md" | awk '{print $1}')
: > "$STUB_CALL_LOG"
run_setup "$mixed_repo" --migrate-openspec
assert_status 0
[[ "$config_hash" == "$(sha256sum "$mixed_repo/openspec/config.yaml" | awk '{print $1}')" ]] || fail '迁移覆盖了团队 config.yaml'
[[ "$spec_hash" == "$(sha256sum "$mixed_repo/openspec/specs/existing-capability/spec.md" | awk '{print $1}')" ]] || fail '迁移覆盖了主 spec'
[[ "$team_change_hash" == "$(sha256sum "$mixed_repo/openspec/changes/team-change/proposal.md" | awk '{print $1}')" ]] || fail '迁移覆盖了其他 change'
if grep -Fq $'openspec\tinit' "$STUB_CALL_LOG" || grep -Eq $'openspec\t.*\tinit(\t|$)' "$STUB_CALL_LOG"; then
    fail '已有 OpenSpec 项目不应重复 init'
fi

note 'OpenSpec change 创建失败会恢复旧树和原始 .gitignore，并留下 failed manifest'
failure_repo="$tmp/failure"
create_committed_legacy_repo "$failure_repo"
gitignore_hash=$(sha256sum "$failure_repo/.gitignore" | awk '{print $1}')
failbin="$tmp/failing-dependencies"
mkdir -p "$failbin"
ln -s "$real_node" "$failbin/node"
ln -s "$STUB_BIN/npm" "$failbin/npm"
export STUB_BIN
cat > "$failbin/npx" <<'NPX'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
index=-1
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == openspec ]]; then index=$i; break; fi
done
command=${args[$((index + 1))]:---help}
if [[ "$command" == new ]]; then
    mode=${MIGRATION_NEW_MODE:-exit}
    if [[ "$mode" == exit ]]; then printf 'injected new-change failure\n' >&2; exit 42; fi
    command_args=("${args[@]:index + 1}")
    change=${command_args[2]:-}
    change_path="$(pwd -P)/openspec/changes/$change"
    mkdir -p "$change_path"
    printf 'schema: spec-driven\n' > "$change_path/.openspec.yaml"
    if [[ "$mode" == wrong-json ]]; then
        printf '{"change":{"id":"%s","path":"/wrong/path","metadataPath":"%s/.openspec.yaml","schema":"spec-driven"}}\n' "$change" "$change_path"
        exit 0
    fi
    if [[ "$mode" == extra-entry ]]; then
        printf 'unexpected\n' > "$change_path/unexpected.txt"
        printf '{"change":{"id":"%s","path":"%s","metadataPath":"%s/.openspec.yaml","schema":"spec-driven"}}\n' "$change" "$change_path" "$change_path"
        exit 0
    fi
    exit 64
fi
exec "${STUB_BIN:?}/npx" "$@"
NPX
chmod +x "$failbin/npx"

old_path=$PATH
export PATH="$failbin:$old_path"
export MIGRATION_NEW_MODE=exit
: > "$STUB_CALL_LOG"
run_setup "$failure_repo" --migrate-openspec
assert_status 5
assert_contains "$RUN_OUTPUT" '无法创建迁移 change'
[[ -z "$(git -C "$failure_repo" status --porcelain=v1 --untracked-files=all)" ]] || fail '失败恢复后 Git 工作树不是原始状态'
[[ "$gitignore_hash" == "$(sha256sum "$failure_repo/.gitignore" | awk '{print $1}')" ]] || fail '失败恢复没有还原 .gitignore'
assert_path_absent "$failure_repo/openspec"
assert_path_exists "$failure_repo/spec.md"
assert_path_exists "$failure_repo/todo.md"
assert_path_exists "$failure_repo/tasks/TASK-20260715010101-preserve-alpha/task.md"

failed_manifest=$(find "$failure_repo/.ai-harness/migrations" -mindepth 2 -maxdepth 2 -name manifest.json -print -quit)
[[ -n "$failed_manifest" ]] || fail '失败迁移没有保留诊断 manifest'
[[ "$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).status" "$failed_manifest")" == failed ]] || fail '失败 manifest 状态不是 failed'
[[ "$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).failure_step" "$failed_manifest")" == create-migration-change ]] || fail '失败 manifest 没有记录失败步骤'
[[ "$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).recovery_status" "$failed_manifest")" == restored ]] || fail '失败 manifest 没有确认原树恢复'

failed_count=$(find "$failure_repo/.ai-harness/migrations" -mindepth 2 -maxdepth 2 -name manifest.json | wc -l)
run_setup "$failure_repo" --migrate-openspec
assert_status 5
assert_contains "$RUN_OUTPUT" '相同源 hash 已有未清理迁移记录'
[[ "$failed_count" -eq "$(find "$failure_repo/.ai-harness/migrations" -mindepth 2 -maxdepth 2 -name manifest.json | wc -l)" ]] || fail '重试失败迁移创建了第二份 manifest'

assert_contract_failure_recovered() {
    local directory=$1
    [[ -z "$(git -C "$directory" status --porcelain=v1 --untracked-files=all)" ]] || fail 'new-change contract 失败后 Git 工作树未恢复'
    assert_path_absent "$directory/openspec"
    assert_path_exists "$directory/spec.md"
    assert_path_exists "$directory/todo.md"
    assert_path_exists "$directory/tasks/TASK-20260715010101-preserve-alpha/task.md"
    local record
    record=$(find "$directory/.ai-harness/migrations" -mindepth 2 -maxdepth 2 -name manifest.json -print -quit)
    [[ -n "$record" ]] || fail 'new-change contract 失败没有 manifest'
    node - "$record" <<'NODE' || fail 'new-change contract 失败 manifest 不完整'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));if(d.status!=='failed'||d.failure_step!=='create-migration-change'||d.recovery_status!=='restored'||(d.manual_attention||[]).length)process.exit(1);
NODE
}

note 'migration 拒绝 exit-0 但 absolute path 错误的 new-change JSON，并走原恢复流程'
wrong_json_repo="$tmp/wrong new JSON"
create_committed_legacy_repo "$wrong_json_repo"
export MIGRATION_NEW_MODE=wrong-json
run_setup "$wrong_json_repo" --migrate-openspec
assert_status 5
assert_contains "$RUN_OUTPUT" 'OpenSpec JSON/文件系统 contract 无效'
assert_contract_failure_recovered "$wrong_json_repo"

note 'migration 拒绝初始目录除 .openspec.yaml 外的额外条目，并走原恢复流程'
extra_entry_repo="$tmp/extra new entry"
create_committed_legacy_repo "$extra_entry_repo"
export MIGRATION_NEW_MODE=extra-entry
run_setup "$extra_entry_repo" --migrate-openspec
assert_status 5
assert_contains "$RUN_OUTPUT" 'OpenSpec JSON/文件系统 contract 无效'
assert_contract_failure_recovered "$extra_entry_repo"
unset MIGRATION_NEW_MODE
export PATH=$old_path
