#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/adopt and recovery project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/setup-dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
ln -s "$STUB_BIN/npx" "$runtime_bin/npx"
export PATH="$runtime_bin:$REAL_TEST_PATH"
export STUB_OPENSPEC_STATUS_MODE=adopt-safe

new_external_change() {
    local change=$1
    mkdir -p "$repo/openspec/changes/$change/specs/sample"
    printf 'schema: spec-driven\n' > "$repo/openspec/changes/$change/.openspec.yaml"
    printf '# Proposal sentinel for %s\n' "$change" > "$repo/openspec/changes/$change/proposal.md"
    cat > "$repo/openspec/changes/$change/specs/sample/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: External sample
The sample SHALL remain byte-for-byte unchanged while evidence is attached.

#### Scenario: Preserve external artifact
- **WHEN** the change is adopted
- **THEN** its existing proposal and delta spec remain unchanged
EOF
}

run_runtime() {
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

note '显式接管已有 spec-driven change，只 create 初始 evidence 并自动选择'
new_external_change existing-one
proposal_before=$(sha256sum "$repo/openspec/changes/existing-one/proposal.md")
spec_before=$(sha256sum "$repo/openspec/changes/existing-one/specs/sample/spec.md")
run_runtime scripts/change_adopt.sh existing-one
assert_status 0
assert_contains "$RUN_OUTPUT" 'without replacing artifacts or evidence'
assert_path_exists "$repo/openspec/changes/existing-one/harness/ai_snapshot.json"
assert_path_exists "$repo/openspec/changes/existing-one/harness/verification.json"
assert_path_exists "$repo/openspec/changes/existing-one/harness/verification.md"
assert_path_exists "$repo/openspec/changes/existing-one/harness/evaluation.md"
assert_path_exists "$repo/openspec/changes/existing-one/harness/defect-rca.md"
if find "$repo/openspec/changes/existing-one" -maxdepth 1 -name '.harness-adopt-*' -print -quit | grep -q .; then fail 'atomic adopt 遗留 staging 目录'; fi
[[ "$proposal_before" == "$(sha256sum "$repo/openspec/changes/existing-one/proposal.md")" ]] || fail 'adopt 修改了已有 proposal'
[[ "$spec_before" == "$(sha256sum "$repo/openspec/changes/existing-one/specs/sample/spec.md")" ]] || fail 'adopt 修改了已有 delta spec'
node - "$repo/ai_snapshot.json" \
    "$repo/openspec/changes/existing-one/harness/ai_snapshot.json" \
    "$repo/openspec/changes/existing-one/harness/verification.json" <<'NODE'
const fs=require('fs');
const [rootFile,localFile,verificationFile]=process.argv.slice(2),root=JSON.parse(fs.readFileSync(rootFile)),local=JSON.parse(fs.readFileSync(localFile)),verification=JSON.parse(fs.readFileSync(verificationFile));
if(root.active_change!=='existing-one'||local.schema_version!==4||'active_change' in local||local.planned_base_specs_fingerprint!==null||local.planned_change_fingerprint!==null||local.planned_tdd_policy_sha256!==null||local.planned_integration_completeness_sha256!==null||local.planning_approved_at!==null||local.implementation_base_commit!==null)throw Error('adopted snapshot v4 contract mismatch');
if(verification.schema_version!==3||verification.change_name!=='existing-one'||verification.migration!==null||!Array.isArray(verification.tasks)||verification.tasks.length)throw Error('adopted verification v3 contract mismatch');
NODE

note '已有 harness/evidence 永不覆盖；其他 active change 要求显式 --switch'
evidence_before=$(fingerprint_tree "$repo/openspec/changes/existing-one/harness")
run_runtime scripts/change_adopt.sh existing-one
assert_status 4
assert_contains "$RUN_OUTPUT" 'refusing to overwrite'
[[ "$evidence_before" == "$(fingerprint_tree "$repo/openspec/changes/existing-one/harness")" ]] || fail '重复 adopt 改写了 evidence'

new_external_change existing-two
run_runtime scripts/change_adopt.sh existing-two
assert_status 4
assert_contains "$RUN_OUTPUT" 'pass --switch explicitly'
assert_path_absent "$repo/openspec/changes/existing-two/harness"
run_runtime scripts/change_adopt.sh existing-two --switch
assert_status 0
node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1]));if(d.active_change!=="existing-two")process.exit(1)' "$repo/ai_snapshot.json" || fail '--switch 未更新唯一 active pointer'

note '不可信 status JSON、metadata 或已有 evidence 都在写入前失败'
new_external_change invalid-status
export STUB_OPENSPEC_STATUS_MODE=malformed
run_runtime scripts/change_adopt.sh invalid-status --switch
assert_status 6
assert_path_absent "$repo/openspec/changes/invalid-status/harness"
export STUB_OPENSPEC_STATUS_MODE=adopt-safe

new_external_change invalid-schema
printf 'schema: custom\n' > "$repo/openspec/changes/invalid-schema/.openspec.yaml"
run_runtime scripts/change_adopt.sh invalid-schema --switch
assert_status 6
assert_path_absent "$repo/openspec/changes/invalid-schema/harness"
rm -rf "$repo/openspec/changes/invalid-schema"

new_external_change existing-evidence
mkdir "$repo/openspec/changes/existing-evidence/harness"
printf 'do-not-touch\n' > "$repo/openspec/changes/existing-evidence/harness/sentinel.txt"
sentinel_before=$(sha256sum "$repo/openspec/changes/existing-evidence/harness/sentinel.txt")
run_runtime scripts/change_adopt.sh existing-evidence --switch
assert_status 4
[[ "$sentinel_before" == "$(sha256sum "$repo/openspec/changes/existing-evidence/harness/sentinel.txt")" ]] || fail '已有 evidence sentinel 被改写'

set_archive_failure() {
    local change=$1
    local state=$2
    local log_rel=".ai-harness/logs/archive-$change-fixture.log"
    printf 'manual recovery fixture for %s\n' "$change" > "$repo/$log_rel"
    node - "$repo/ai_snapshot.json" "$change" "$state" "$log_rel" <<'NODE'
const fs=require('fs'),path=require('path');
const [file,change,state,logPath]=process.argv.slice(2),d=JSON.parse(fs.readFileSync(file)),date='2026-07-14',source=`openspec/changes/${change}`,archive=`openspec/changes/archive/${date}-${change}`,archived=state==='archived';
d.active_change=archived?null:change;
d.phase='archive_failed';
d.current_step='archive-partial-failure';
d.next_step='Inspect archive log and all recorded OpenSpec locations; do not retry automatically';
d.archive_failure={
  change,
  message:'injected non-transactional archive failure',
  recorded_at:'2026-07-14T12:00:00Z',
  active_cleared:archived,
  actual_locations:{
    main_specs:{path:'openspec/specs',kind:'directory'},
    source_change:{path:source,kind:archived?'missing':'directory'},
    utc_archive:{path:archive,kind:archived?'directory':'missing'},
    actual_archive:archived?{path:archive,kind:'directory'}:null,
    archive_candidates:archived?[{path:archive,kind:'directory'}]:[]
  },
  log_path:logPath
};
d.updated_at=d.archive_failure.recorded_at;
const temp=path.join(path.dirname(file),'.test-recovery-snapshot');fs.writeFileSync(temp,JSON.stringify(d,null,2)+'\n');fs.renameSync(temp,file);
NODE
}

write_complete_archived_evidence() {
    local change=$1
    local harness="$repo/openspec/changes/$change/harness"
    node - "$harness" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [harness, change] = process.argv.slice(2);
const digest = bytes => 'sha256:' + crypto.createHash('sha256').update(bytes).digest('hex');
const writeJson = (name, value) => fs.writeFileSync(
  path.join(harness, name), JSON.stringify(value, null, 2) + '\n', {mode: 0o644}
);
const evaluationId = 'eval-20260714T120000Z-a11ce0';
const budgetDigest = digest(Buffer.from('archived recovery budget fixture\n'));

// This helper deliberately models retained evidence created before the v2/v3
// upgrade. Archive recovery must continue to recognize that complete legacy
// tuple; normal adopted changes above start with integrated snapshot v4/evidence v3.
writeJson('ai_snapshot.json', {
  schema_version: 2,
  phase: 'evaluated',
  planned_base_specs_fingerprint: null,
  implementation_base_commit: null,
  adopted_preexisting_paths: [],
  implementation_baselined_at: null,
  current_step: 'legacy evaluation retained for archive recovery',
  next_step: 'perform explicit archive recovery review'
});
writeJson('verification.json', {
  schema_version: 1,
  change_name: change,
  tasks: []
});

writeJson('change-footprint.json', {
  schema_version: 1,
  change_name: change,
  status: 'within_expected',
  budget_block_sha256: budgetDigest,
  production: {added_lines: 0, touched_files: 0, new_files: 0},
  tests: {added_lines: 0, touched_files: 0, new_files: 0},
  project_support: {added_lines: 0, new_files: 0},
  generated: {files: 0, bytes: 0}
});

const footprint = fs.readFileSync(path.join(harness, 'change-footprint.json'));
const footprintDigest = digest(footprint);
writeJson('evaluation.json', {
  schema_version: 1,
  evaluation_id: evaluationId,
  change_name: change,
  verdict: 'Pass',
  evaluation_started_at: '2026-07-14T12:00:00Z',
  evaluated_at: '2026-07-14T12:01:00Z',
  openspec_version: '1.6.0',
  budget_block_sha256: budgetDigest,
  change_footprint_json_sha256: footprintDigest,
  implementation_economy: {result: 'Pass'},
  blocking_untested: []
});
fs.writeFileSync(
  path.join(harness, 'evaluation.md'),
  `# Evaluation History\n\n## ${evaluationId} — Pass\n\nDigest-bound retained evidence fixture.\n`,
  {mode: 0o644}
);

const verification = fs.readFileSync(path.join(harness, 'verification.json'));
const evaluation = fs.readFileSync(path.join(harness, 'evaluation.json'));
writeJson('evaluation-baseline.json', {
  schema_version: 1,
  evaluation_id: evaluationId,
  change_name: change,
  status: 'complete',
  started_at: '2026-07-14T12:00:00Z',
  source_fingerprint: digest(Buffer.from('archived recovery source fixture\n')),
  artifact_fingerprint: digest(Buffer.from('archived recovery artifact fixture\n')),
  base_specs_fingerprint: digest(Buffer.from('archived recovery base specs fixture\n')),
  verification_json_sha256: digest(verification),
  budget_block_sha256: budgetDigest,
  change_footprint_json_sha256: footprintDigest,
  completed_at: '2026-07-14T12:01:00Z',
  evaluation_json_sha256: digest(evaluation)
});
NODE
}

assert_archived_evidence_fixture() {
    local archive_dir=$1
    local change=$2
    node - "$archive_dir/harness" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [harness, change] = process.argv.slice(2);
const required = [
  'ai_snapshot.json',
  'verification.json',
  'verification.md',
  'evaluation.md',
  'defect-rca.md',
  'change-footprint.json',
  'evaluation-baseline.json',
  'evaluation.json'
];
for (const name of required) {
  const file = path.join(harness, name);
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('unsafe archived evidence fixture: ' + name);
}
const read = name => JSON.parse(fs.readFileSync(path.join(harness, name), 'utf8'));
const baseline = read('evaluation-baseline.json');
const evaluation = read('evaluation.json');
const verification = read('verification.json');
const footprint = read('change-footprint.json');
const evaluationDigest = 'sha256:' + crypto.createHash('sha256')
  .update(fs.readFileSync(path.join(harness, 'evaluation.json'))).digest('hex');
if (baseline.status !== 'complete' || baseline.change_name !== change ||
    evaluation.change_name !== change || verification.change_name !== change ||
    footprint.change_name !== change || baseline.evaluation_id !== evaluation.evaluation_id ||
    baseline.evaluation_json_sha256 !== evaluationDigest || evaluation.verdict !== 'Pass' ||
    evaluation.implementation_economy?.result !== 'Pass' ||
    !Array.isArray(evaluation.blocking_untested) || evaluation.blocking_untested.length !== 0) {
  throw new Error('archived evidence fixture is not identity- and digest-bound');
}
NODE
}

assert_archive_gate_preserved() {
    local expected_sha=$1
    local change=$2
    [[ "$expected_sha" == "$(sha256sum "$repo/ai_snapshot.json")" ]] || fail '缺失 archived evidence 时 root snapshot hash 发生变化'
    node - "$repo/ai_snapshot.json" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
if (snapshot.phase !== 'archive_failed' || snapshot.active_change !== null ||
    snapshot.archive_failure?.change !== change || snapshot.archive_failure?.active_cleared !== true) {
  throw new Error('missing archived evidence cleared or changed the global recovery gate');
}
NODE
}

note 'source-retained 失败现场形成全局门禁，status 只报告且不修改'
write_complete_archived_evidence existing-two
source_baseline="$repo/openspec/changes/existing-two/harness/evaluation-baseline.json"
source_evaluation="$repo/openspec/changes/existing-two/harness/evaluation.json"
source_baseline_before=$(sha256sum "$source_baseline")
set_archive_failure existing-two source-retained
snapshot_failed=$(sha256sum "$repo/ai_snapshot.json")
run_runtime scripts/archive_recover.sh --status
assert_status 0
status_json=$RUN_OUTPUT
node -e 'const x=JSON.parse(process.argv[1]);if(!x.unresolved||x.change_name!=="existing-two"||x.current_state!=="source-retained"||x.eligible!==true)process.exit(1)' "$status_json" || fail 'source-retained status 不可确认'
[[ "$snapshot_failed" == "$(sha256sum "$repo/ai_snapshot.json")" ]] || fail '--status 修改了 snapshot'
run_runtime scripts/change_select.sh existing-one
assert_status 4
assert_contains "$RUN_OUTPUT" 'archive recovery is unresolved'

note '单行 reason、change identity、唯一目录状态和 strict validation 任一失败都不能清门禁'
run_runtime scripts/archive_recover.sh --acknowledge existing-two --reason $'bad\nreason'
assert_status 2
[[ "$snapshot_failed" == "$(sha256sum "$repo/ai_snapshot.json")" ]] || fail '非法 reason 修改了 snapshot'

for credential_reason in \
    'Bearer secret-value' 'Authorization: Basic abc' 'X-API-Key=abc' \
    'Cookie: session=abc' 'token=abc' 'password=abc'; do
    run_runtime scripts/archive_recover.sh --acknowledge existing-two --reason "$credential_reason"
    assert_status 2
    assert_contains "$RUN_OUTPUT" 'must not contain credentials'
done
[[ "$snapshot_failed" == "$(sha256sum "$repo/ai_snapshot.json")" ]] || fail '含凭据 reason 修改了 snapshot'

run_runtime scripts/archive_recover.sh --acknowledge existing-one --reason 'wrong change'
assert_status 6
[[ "$snapshot_failed" == "$(sha256sum "$repo/ai_snapshot.json")" ]] || fail 'change mismatch 修改了 snapshot'

export STUB_OPENSPEC_VALIDATE_MODE=error
run_runtime scripts/archive_recover.sh --acknowledge existing-two --reason 'validation must fail closed'
assert_status 6
assert_contains "$RUN_OUTPUT" 'strict main specs validation'
[[ "$snapshot_failed" == "$(sha256sum "$repo/ai_snapshot.json")" ]] || fail 'strict validation 失败时清除了门禁'
export STUB_OPENSPEC_VALIDATE_MODE=success

log_path="$repo/.ai-harness/logs/archive-existing-two-fixture.log"
mv "$log_path" "$tmp/recovery-log-real"
ln -s "$tmp/recovery-log-real" "$log_path"
run_runtime scripts/archive_recover.sh --status
assert_status 0
node -e 'const x=JSON.parse(process.argv[1]);if(x.eligible!==false||!x.issues.some(v=>v.includes("archive log path")))process.exit(1)' "$RUN_OUTPUT" || fail 'symlink archive log 未使 status ineligible'
run_runtime scripts/archive_recover.sh --acknowledge existing-two --reason 'unsafe log must fail closed'
assert_status 6
rm "$log_path"
mv "$tmp/recovery-log-real" "$log_path"
[[ "$snapshot_failed" == "$(sha256sum "$repo/ai_snapshot.json")" ]] || fail '不安全 log path 清除了门禁'

ambiguous="$repo/openspec/changes/archive/2026-07-14-existing-two"
mkdir -p "$ambiguous/harness"
run_runtime scripts/archive_recover.sh --status
assert_status 0
node -e 'const x=JSON.parse(process.argv[1]);if(x.eligible!==false||x.current_state!=="ambiguous")process.exit(1)' "$RUN_OUTPUT" || fail '重复 source/archive 未被标为 ambiguous'
run_runtime scripts/archive_recover.sh --acknowledge existing-two --reason 'ambiguous state must fail'
assert_status 6
[[ "$snapshot_failed" == "$(sha256sum "$repo/ai_snapshot.json")" ]] || fail 'ambiguous 状态清除了门禁'
rm -rf "$ambiguous"
[[ "$source_baseline_before" == "$(sha256sum "$source_baseline")" ]] || fail '确认前的失败尝试提前失效了 Evaluation'

note '唯一 source-retained 状态经 strict main specs validation 后原子记录 acknowledgment，并强制旧 Pass 失效'
run_runtime scripts/archive_recover.sh --acknowledge existing-two --reason 'reviewed source-retained state and archive log'
assert_status 0
assert_contains "$RUN_OUTPUT" 'no archive retry or rollback was performed'
node - "$repo/ai_snapshot.json" "$source_baseline" "$source_evaluation" <<'NODE'
const fs=require('fs');const [snapshotFile,baselineFile,evaluationFile]=process.argv.slice(2),d=JSON.parse(fs.readFileSync(snapshotFile)),a=d.last_archive_recovery_acknowledgment,b=JSON.parse(fs.readFileSync(baselineFile)),e=JSON.parse(fs.readFileSync(evaluationFile));
if('archive_failure' in d||d.active_change!=='existing-two'||d.phase!=='archive_recovery_acknowledged'||a?.change_name!=='existing-two'||a.recovered_state!=='source-retained'||a.strict_validation_failed_count!==0||a.reason!=='reviewed source-retained state and archive log')throw Error('source-retained acknowledgment contract mismatch');
if(b.status!=='aborted'||b.reason!=='Invalidated after source-retained archive recovery; begin a fresh independent Evaluation before archive retry'||!Number.isFinite(Date.parse(b.aborted_at))||Object.hasOwn(b,'completed_at')||Object.hasOwn(b,'evaluation_json_sha256')||e.verdict!=='Pass')throw Error('source-retained acknowledgment did not invalidate the old digest-bound Pass');
NODE
archive_calls_before=$(grep -Fc $'\topenspec\tarchive\texisting-two' "$STUB_CALL_LOG" || true)
run_runtime scripts/change_archive.sh existing-two
assert_status 6
assert_contains "$RUN_OUTPUT" 'fresh independent Evaluation required after source-retained archive recovery'
archive_calls_after=$(grep -Fc $'\topenspec\tarchive\texisting-two' "$STUB_CALL_LOG" || true)
[[ "$archive_calls_before" -eq "$archive_calls_after" ]] || fail 'source-retained 恢复后复用了旧 Pass 并调用 archive CLI'
run_runtime scripts/change_select.sh existing-one
assert_status 0

note 'source 已移动且只有一个安全 archive 时，可确认 archived 状态并保持 active=null'
archived_dir="$repo/openspec/changes/archive/2026-07-14-existing-one"
write_complete_archived_evidence existing-one
mv "$repo/openspec/changes/existing-one" "$archived_dir"
assert_archived_evidence_fixture "$archived_dir" existing-one
set_archive_failure existing-one archived

note 'archived recovery 缺少任一必须 evidence 时均 fail closed，不能清除 root gate'
required_archived_evidence=(
    ai_snapshot.json
    verification.json
    verification.md
    evaluation.md
    defect-rca.md
    change-footprint.json
    evaluation-baseline.json
    evaluation.json
)
archived_gate_sha=$(sha256sum "$repo/ai_snapshot.json")
for evidence_name in "${required_archived_evidence[@]}"; do
    evidence_path="$archived_dir/harness/$evidence_name"
    held_evidence="$tmp/missing-archived-$evidence_name"
    mv "$evidence_path" "$held_evidence"

    run_runtime scripts/archive_recover.sh --status
    assert_status 0
    node - "$RUN_OUTPUT" "$evidence_name" <<'NODE'
const state = JSON.parse(process.argv[2]);
const missing = process.argv[3];
if (!state.unresolved || state.current_state !== 'archived' || state.eligible !== false ||
    !Array.isArray(state.issues) || state.issues.length === 0) {
  throw new Error('missing ' + missing + ' did not make archived recovery ineligible');
}
NODE

    run_runtime scripts/archive_recover.sh --acknowledge existing-one \
        --reason "missing $evidence_name must retain recovery gate"
    assert_status 6
    assert_archive_gate_preserved "$archived_gate_sha" existing-one

    mv "$held_evidence" "$evidence_path"
    run_runtime scripts/archive_recover.sh --status
    assert_status 0
    node - "$RUN_OUTPUT" "$evidence_name" <<'NODE'
const state = JSON.parse(process.argv[2]);
const restored = process.argv[3];
if (state.current_state !== 'archived' || state.eligible !== true) {
  throw new Error('restoring ' + restored + ' did not restore archived recovery eligibility');
}
NODE
    assert_archive_gate_preserved "$archived_gate_sha" existing-one
done

note '完整、安全且 digest-bound 的 archived evidence 仍可经人工确认解除门禁'
run_runtime scripts/archive_recover.sh --status
assert_status 0
node -e 'const x=JSON.parse(process.argv[1]);if(x.current_state!=="archived"||x.eligible!==true||x.archive_candidates.length!==1)process.exit(1)' "$RUN_OUTPUT" || fail 'archived status 不可确认'
run_runtime scripts/archive_recover.sh --acknowledge existing-one --reason 'reviewed the single archived directory and retained evidence'
assert_status 0
node - "$repo/ai_snapshot.json" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2])),a=d.last_archive_recovery_acknowledgment;
if('archive_failure' in d||d.active_change!==null||d.phase!=='idle'||a?.change_name!=='existing-one'||a.recovered_state!=='archived')throw Error('archived acknowledgment contract mismatch');
NODE
run_runtime scripts/archive_recover.sh --status
assert_status 0
node -e 'const x=JSON.parse(process.argv[1]);if(x.unresolved!==false||x.last_acknowledgment?.change_name!=="existing-one")process.exit(1)' "$RUN_OUTPUT" || fail 'cleared recovery status 不正确'

note 'setup 前已存在的 Team/OpenSpec change 在普通与 --force setup 下保持无 harness，只有显式 adopt 才附加 evidence'
preexisting_repo="$tmp/preexisting OpenSpec project"
init_git_repo "$preexisting_repo"
mkdir -p "$preexisting_repo/openspec/specs" \
    "$preexisting_repo/openspec/changes/archive" \
    "$preexisting_repo/openspec/changes/team-existing/specs/sample"
printf 'schema: spec-driven\n' > "$preexisting_repo/openspec/config.yaml"
printf 'schema: spec-driven\n' > "$preexisting_repo/openspec/changes/team-existing/.openspec.yaml"
printf '# Team proposal sentinel\n' > "$preexisting_repo/openspec/changes/team-existing/proposal.md"
printf '# Team design sentinel\n' > "$preexisting_repo/openspec/changes/team-existing/design.md"
printf '# Team tasks sentinel\n- [ ] 1.1 keep\n' > "$preexisting_repo/openspec/changes/team-existing/tasks.md"
cat > "$preexisting_repo/openspec/changes/team-existing/specs/sample/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Preserve setup-time change
The project SHALL retain a pre-existing change until explicit adoption.

#### Scenario: Run setup
- **WHEN** setup runs normally or with force
- **THEN** no change-local harness is created implicitly
EOF
team_paths=(
    openspec/config.yaml
    openspec/changes/team-existing/.openspec.yaml
    openspec/changes/team-existing/proposal.md
    openspec/changes/team-existing/design.md
    openspec/changes/team-existing/tasks.md
    openspec/changes/team-existing/specs/sample/spec.md
)
team_before="$tmp/preexisting-before.txt"
team_after="$tmp/preexisting-after.txt"
fingerprint_paths "$preexisting_repo" "${team_paths[@]}" > "$team_before"
run_setup "$preexisting_repo"
assert_status 0
assert_path_absent "$preexisting_repo/openspec/changes/team-existing/harness"
fingerprint_paths "$preexisting_repo" "${team_paths[@]}" > "$team_after"
assert_files_equal "$team_before" "$team_after"
run_setup "$preexisting_repo" --force
assert_status 0
assert_path_absent "$preexisting_repo/openspec/changes/team-existing/harness"
fingerprint_paths "$preexisting_repo" "${team_paths[@]}" > "$team_after"
assert_files_equal "$team_before" "$team_after"
run_runtime bash -c 'cd "$1" && scripts/change_adopt.sh team-existing' _ "$preexisting_repo"
assert_status 0
assert_path_exists "$preexisting_repo/openspec/changes/team-existing/harness/verification.json"
fingerprint_paths "$preexisting_repo" "${team_paths[@]}" > "$team_after"
assert_files_equal "$team_before" "$team_after"
