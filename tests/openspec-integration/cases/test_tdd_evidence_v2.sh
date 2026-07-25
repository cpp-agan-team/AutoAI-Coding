#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

run_managed_at() {
    local directory=$1
    shift
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$directory" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

assert_task_checked() {
    local repo=$1 expected=$2
    if [[ "$expected" == yes ]]; then
        grep -Eq '^- \[[xX]\] 1\.1 ' "$repo/openspec/changes/tdd-contract/tasks.md" || \
            fail 'task 1.1 should be checked'
    else
        grep -Eq '^- \[ \] 1\.1 ' "$repo/openspec/changes/tdd-contract/tasks.md" || \
            fail 'task 1.1 should remain unchecked'
    fi
}

write_change_artifacts() {
    local repo=$1 category=$2 task_count=${3:-1}
    node - "$repo" "$category" "$task_count" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, category, taskCountText] = process.argv.slice(2);
const taskCount = Number(taskCountText);
if (![1, 2].includes(taskCount)) throw new Error('unsupported fixture task count');
const change = 'tdd-contract';
const dir = path.join(root, 'openspec', 'changes', change);
const isNormal = category === 'normal';
const exception = isNormal ? [] : [{
  id: category === 'configuration_only' ? 'configuration-proof' : 'prototype-proof',
  category,
  task_ids: ['1.1'],
  paths: [category === 'configuration_only' ? 'config/**' : 'prototype/**'],
  reason: category === 'configuration_only'
    ? 'This fixture changes inert sample metadata and has no runtime behavior.'
    : 'This fixture proves that disposable exploration cannot close a production task.',
  alternative_verify_kinds: ['static'],
  exit_condition: category === 'configuration_only'
    ? 'Remove the exception if the configuration becomes executable behavior.'
    : 'Delete the prototype or re-plan it as a production TDD task.'
}];
const policy = {schema_version: 1, default: 'required', exceptions: exception};
const economy = {
  schema_version: 1,
  profile: 'small',
  rationale: taskCount === 1
    ? 'The fixture changes one existing value or creates one scoped sample file and one focused test only.'
    : 'The fixture exercises two planned tasks with at most two production files and one shared focused test.',
  classification: {
    production: ['src/**', 'config/**', 'prototype/**'],
    tests: ['tests/**'],
    project_docs: ['README.md'],
    project_tooling: ['CMakeLists.txt'],
    examples: ['examples/**'],
    generated: [],
    vendor: ['vendor/**']
  },
  thresholds: {
    production: {
      added_lines: {expected: 20, review_at: 40, hard_limit: 80},
      touched_files: {expected: 2, review_at: 4, hard_limit: 8},
      new_files: {expected: taskCount === 1 ? 1 : 2, review_at: 3, hard_limit: 4}
    },
    tests: {
      added_lines: {expected: 30, review_at: 60, hard_limit: 120},
      touched_files: {expected: 1, review_at: 2, hard_limit: 4},
      new_files: {expected: 1, review_at: 2, hard_limit: 4}
    },
    project_support: {
      added_lines: {expected: 0, review_at: 10, hard_limit: 20},
      new_files: {expected: 0, review_at: 1, hard_limit: 2}
    },
    generated: {
      files: {expected: 0, review_at: 1, hard_limit: 2},
      bytes: {expected: 0, review_at: 1024, hard_limit: 4096}
    }
  },
  structural_allowances: {public_contracts: [], cmake_targets: [], direct_dependencies: []},
  reuse_decisions: [],
  obsolete_items: [],
  exceptions: []
};
fs.mkdirSync(path.join(dir, 'specs', 'widget'), {recursive: true});
fs.writeFileSync(path.join(dir, 'proposal.md'), '# Change: Prove the TDD evidence contract\n\nThe selected task must be closed only by its approved verification policy.\n');
fs.writeFileSync(path.join(dir, 'specs', 'widget', 'spec.md'), `## ADDED Requirements

### Requirement: Managed evidence closure

The fixture SHALL accept only evidence produced by the approved task policy.

#### Scenario: Task closes with current evidence

- **WHEN** the managed task is completed
- **THEN** every required verification kind has current evidence
${taskCount === 2 ? `
#### Scenario: Later task changes source

- **WHEN** a later managed task changes production source
- **THEN** completed-task evidence can be refreshed without rewriting its original proof
` : ''}
`);
const verify = isNormal ? 'behavior' : 'static';
const secondTask = taskCount === 2 ? `
- [ ] 1.2 Implement the later source change
  - Covers: \`specs/widget/spec.md\` | \`ADDED\` | \`Managed evidence closure\` | \`Later task changes source\`
  - Verify: \`behavior\`
` : '';
fs.writeFileSync(path.join(dir, 'tasks.md'), `# Tasks

- [ ] 1.1 Implement the managed fixture
  - Covers: \`specs/widget/spec.md\` | \`ADDED\` | \`Managed evidence closure\` | \`Task closes with current evidence\`
  - Verify: \`${verify}\`
${secondTask}
`);
fs.writeFileSync(path.join(dir, 'design.md'), `# Design

Keep the implementation and its evidence deliberately small.

<!-- autoai:tdd-policy:v1 -->
\`\`\`json
${JSON.stringify(policy, null, 2)}
\`\`\`
<!-- /autoai:tdd-policy:v1 -->

<!-- autoai:implementation-economy:v1 -->
\`\`\`json
${JSON.stringify(economy, null, 2)}
\`\`\`
<!-- /autoai:implementation-economy:v1 -->
`);
if (isNormal) {
  fs.mkdirSync(path.join(root, 'src'), {recursive: true});
  fs.writeFileSync(path.join(root, 'src', 'widget.value'), 'old\n');
}
NODE
}

create_repo() {
    local repo=$1 category=$2 task_count=${3:-1}
    init_git_repo "$repo"
    reset_stub_environment
    run_setup "$repo"
    assert_status 0
    run_managed_at "$repo" scripts/change_new.sh tdd-contract
    assert_status 0
    use_modern_v2_fixture "$repo" tdd-contract
    write_change_artifacts "$repo" "$category" "$task_count"
}

approve_repo() {
    local repo=$1 task_count=${2:-1}
    git -C "$repo" config user.name 'AutoAI TDD Evidence Test'
    git -C "$repo" config user.email 'autoai-tdd@example.invalid'
    git -C "$repo" add -A
    git -C "$repo" commit -qm 'approved TDD fixture'
    export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
    export STUB_OPENSPEC_TASK_TOTAL=$task_count
    run_managed_at "$repo" scripts/snapshot_update.sh \
        --freeze-planning-baseline --freeze-implementation-base \
        --phase implementing --current-step implementation-base-frozen \
        --next-step implement-first-task
    assert_status 0
}

normal_repo="$tmp/normal TDD project"
create_repo "$normal_repo" normal

note '历史回归显式将 fresh v4/v3 fixture 降级为 snapshot v3 与 verification v2'
node - "$normal_repo/openspec/changes/tdd-contract/harness/ai_snapshot.json" \
    "$normal_repo/openspec/changes/tdd-contract/harness/verification.json" <<'NODE'
const fs = require('fs');
const [snapshotFile, verificationFile] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile));
const verification = JSON.parse(fs.readFileSync(verificationFile));
if (snapshot.schema_version !== 3) throw new Error('explicit modern fixture is not schema v3');
for (const key of ['planned_change_fingerprint', 'planned_tdd_policy_sha256', 'planning_approved_at']) {
  if (!(key in snapshot) || snapshot[key] !== null) throw new Error(`unexpected fresh snapshot field: ${key}`);
}
if (verification.schema_version !== 2 || verification.migration !== null || verification.tasks.length !== 0) {
  throw new Error('explicit modern verification is not an empty native v2 document');
}
NODE

note 'TDD Policy parser 接受闭合空策略并拒绝未知字段'
(
    cd "$normal_repo"
    node - <<'NODE'
const fs = require('fs');
const policy = require('./scripts/manifest_policy.js');
const design = fs.readFileSync('openspec/changes/tdd-contract/design.md', 'utf8');
const tasks = fs.readFileSync('openspec/changes/tdd-contract/tasks.md', 'utf8');
const parsed = policy.parseTddPolicy(design, tasks);
if (parsed.policy.default !== 'required' || parsed.policy.exceptions.length !== 0) {
  throw new Error('valid empty policy was not parsed');
}
const invalid = design.replace('"default": "required",', '"default": "required",\n  "allow_implicit_skip": true,');
let rejected = false;
try { policy.parseTddPolicy(invalid, tasks); } catch { rejected = true; }
if (!rejected) throw new Error('open TDD policy schema was accepted');
NODE
)

approve_repo "$normal_repo"

mkdir -p "$normal_repo/tests"
cat > "$normal_repo/tests/widget_test.sh" <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$(tr -d '\r\n' < src/widget.value)" != new ]]; then
    echo 'widget-value-mismatch'
    exit 7
fi
echo 'widget-value-ok'
TEST
chmod 755 "$normal_repo/tests/widget_test.sh"
run_managed_at "$normal_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0

verification="$normal_repo/openspec/changes/tdd-contract/harness/verification.json"
tasks="$normal_repo/openspec/changes/tdd-contract/tasks.md"

note '错误 marker 与退出 0 都只能写 InvalidRed，RED 永远不能写普通 Pass'
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase red --cycle wrong-marker --kind behavior --expect-exit 7 \
    --test-path tests/widget_test.sh --failure-class assertion \
    --expected-failure 'widget must still reject the old value' \
    --match-output 'different-marker' --observed 'the focused assertion failed' -- \
    tests/widget_test.sh
assert_status 1
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase red --cycle passing-red --kind behavior --expect-exit 9 \
    --test-path tests/widget_test.sh --failure-class behavior \
    --expected-failure 'a passing command cannot establish RED' \
    --match-output 'widget-value-mismatch' --observed 'the synthetic command returned zero' -- \
    bash -c 'echo widget-value-mismatch; exit 0'
assert_status 1
node - "$verification" <<'NODE'
const fs = require('fs');
const doc = JSON.parse(fs.readFileSync(process.argv[2]));
const red = doc.tasks.flatMap(t => t.commands).filter(c => c.phase === 'RED');
if (red.length !== 2 || red.some(c => c.result !== 'InvalidRed')) {
  throw new Error('invalid RED attempts were not retained as InvalidRed');
}
if (red.some(c => c.result === 'Pass')) throw new Error('RED was recorded as Pass');
NODE

note '合法 RED 保存 ExpectedFailure，但 RED-only 不能完成 task'
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase red --cycle widget-value --kind behavior --expect-exit 7 \
    --path src/widget.value --test-path tests/widget_test.sh \
    --failure-class assertion --expected-failure 'the old widget value violates the new requirement' \
    --match-output 'widget-value-mismatch' --observed 'the focused assertion rejected old' -- \
    tests/widget_test.sh
assert_status 0
node - "$verification" <<'NODE'
const fs = require('fs');
const commands = JSON.parse(fs.readFileSync(process.argv[2])).tasks.flatMap(t => t.commands);
const valid = commands.filter(c => c.phase === 'RED' && c.result === 'ExpectedFailure');
if (valid.length !== 1) throw new Error('valid ExpectedFailure RED missing');
if (commands.some(c => c.phase === 'RED' && c.result === 'Pass')) throw new Error('RED contributed Pass');
NODE
tasks_before=$(sha256sum -- "$tasks" | awk '{print $1}')
run_managed_at "$normal_repo" scripts/task_verify.sh --complete 1.1
assert_status 6
tasks_after=$(sha256sum -- "$tasks" | awk '{print $1}')
[[ "$tasks_before" == "$tasks_after" ]] || fail 'RED-only completion modified tasks.md'
assert_task_checked "$normal_repo" no

note '超过五分钟的未来历史时间在执行新命令前拒绝，轻微时钟回拨仍由单调时间容忍'
cp -p "$verification" "$tmp/verification-before-future-time.json"
node - "$verification" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const doc = JSON.parse(fs.readFileSync(file));
const command = doc.tasks.find(task => task.task_id === '1.1').commands.at(-1);
command.finished_at = new Date(Date.now() + 3600000).toISOString();
fs.writeFileSync(file, JSON.stringify(doc, null, 2) + '\n');
NODE
future_marker="$tmp/future-timestamp-command-ran"
evidence_before=$(sha256sum -- "$verification" | awk '{print $1}')
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-value --kind behavior -- \
    bash -c 'touch "$1"' _ "$future_marker"
assert_status 6
[[ ! -e "$future_marker" ]] || fail 'far-future evidence allowed a new command to execute'
evidence_after=$(sha256sum -- "$verification" | awk '{print $1}')
[[ "$evidence_before" == "$evidence_after" ]] || fail 'far-future rejection changed verification evidence'
cp -p "$tmp/verification-before-future-time.json" "$verification"

note 'v2 参数和失败摘要在命令执行及 evidence 写入前拒绝 secret-like 内容'
evidence_before=$(sha256sum -- "$verification" | awk '{print $1}')
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-value --kind behavior -- \
    bash -c 'exit 0' --header 'Authorization: Bearer tdd-secret-1'
assert_status 2
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase red --cycle secret-summary --kind behavior --expect-exit 7 \
    --test-path tests/widget_test.sh --failure-class assertion \
    --expected-failure 'token=tdd-secret-2' --match-output widget-value-mismatch \
    --observed 'secret metadata must be rejected' -- tests/widget_test.sh
assert_status 2
evidence_after=$(sha256sum -- "$verification" | awk '{print $1}')
[[ "$evidence_before" == "$evidence_after" ]] || fail 'secret-like v2 attempt changed verification evidence'

note 'RED 后测试文件变化使 GREEN 失效，恢复原测试后最小生产变更才能进入 GREEN'
cp -p "$normal_repo/tests/widget_test.sh" "$tmp/widget-test.approved"
printf '# weakened after RED\n' >> "$normal_repo/tests/widget_test.sh"
printf 'new\n' > "$normal_repo/src/widget.value"
run_managed_at "$normal_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0
evidence_before=$(sha256sum -- "$verification" | awk '{print $1}')
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase green --cycle widget-value --kind behavior --path src/widget.value -- \
    tests/widget_test.sh
assert_status 6
evidence_after=$(sha256sum -- "$verification" | awk '{print $1}')
[[ "$evidence_before" == "$evidence_after" ]] || fail 'changed RED test was appended as GREEN evidence'
cp -p "$tmp/widget-test.approved" "$normal_repo/tests/widget_test.sh"
run_managed_at "$normal_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase green --cycle widget-value --kind behavior --path src/widget.value -- \
    tests/widget_test.sh
assert_status 0

note '批准后的 planning metadata 漂移使 REGRESSION 陈旧并阻止完成，恢复后须重跑当前证据'
cp -p "$normal_repo/openspec/changes/tdd-contract/proposal.md" "$tmp/proposal.approved"
printf '\nUnapproved planning drift.\n' >> "$normal_repo/openspec/changes/tdd-contract/proposal.md"
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-value --kind behavior --path src/widget.value -- \
    tests/widget_test.sh
assert_status 0
run_managed_at "$normal_repo" scripts/task_verify.sh --complete 1.1
assert_status 6
assert_task_checked "$normal_repo" no
cp -p "$tmp/proposal.approved" "$normal_repo/openspec/changes/tdd-contract/proposal.md"
run_managed_at "$normal_repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-value --kind behavior --path src/widget.value -- \
    tests/widget_test.sh
assert_status 0
run_managed_at "$normal_repo" scripts/task_verify.sh --complete 1.1
assert_status 0
assert_task_checked "$normal_repo" yes

note '最后一条 Generator 证据超过五分钟时，独立 Evaluation 必须在建立 baseline 前拒绝'
cp -p "$verification" "$tmp/verification-before-final-future-time.json"
node - "$verification" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const doc = JSON.parse(fs.readFileSync(file));
const command = doc.tasks.find(task => task.task_id === '1.1').commands.at(-1);
command.finished_at = new Date(Date.now() + 3600000).toISOString();
fs.writeFileSync(file, JSON.stringify(doc, null, 2) + '\n');
NODE
run_managed_at "$normal_repo" scripts/evaluator_check.sh --begin tdd-contract
assert_status 6
assert_path_absent "$normal_repo/openspec/changes/tdd-contract/harness/evaluation-baseline.json"
assert_path_absent "$normal_repo/openspec/changes/tdd-contract/harness/evaluation-command-ledger.json"
cp -p "$tmp/verification-before-final-future-time.json" "$verification"

note '已完成普通任务在后续 task 改变 source 后只能追加当前 REGRESSION，旧 GREEN 不可重写'
cross_repo="$tmp/cross-task TDD project"
create_repo "$cross_repo" normal 2
approve_repo "$cross_repo" 2
mkdir -p "$cross_repo/tests"
cat > "$cross_repo/tests/value_test.sh" <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
path=$1 expected=$2
if [[ ! -f "$path" || "$(tr -d '\r\n' < "$path" 2>/dev/null || true)" != "$expected" ]]; then
    echo "value-mismatch:$path"
    exit 7
fi
echo "value-ok:$path"
TEST
chmod 755 "$cross_repo/tests/value_test.sh"
run_managed_at "$cross_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0
run_managed_at "$cross_repo" scripts/task_verify.sh 1.1 \
    --phase red --cycle widget-value --kind behavior --expect-exit 7 \
    --path src/widget.value --test-path tests/value_test.sh \
    --failure-class assertion --expected-failure 'the approved old value does not satisfy task 1.1' \
    --match-output 'value-mismatch:src/widget.value' --observed 'the shared focused test rejected the old widget value' -- \
    tests/value_test.sh src/widget.value new
assert_status 0
printf 'new\n' > "$cross_repo/src/widget.value"
run_managed_at "$cross_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0
run_managed_at "$cross_repo" scripts/task_verify.sh 1.1 \
    --phase green --cycle widget-value --kind behavior --path src/widget.value -- \
    tests/value_test.sh src/widget.value new
assert_status 0
run_managed_at "$cross_repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-value --kind behavior --path src/widget.value -- \
    tests/value_test.sh src/widget.value new
assert_status 0
run_managed_at "$cross_repo" scripts/task_verify.sh --complete 1.1
assert_status 0

note 'task 1.2 建立自己的 RED/GREEN/REGRESSION，并通过新增 production source 使 task 1.1 的旧 REGRESSION 陈旧'
run_managed_at "$cross_repo" scripts/task_verify.sh 1.2 \
    --phase red --cycle later-value --kind behavior --expect-exit 7 \
    --path src/later.value --test-path tests/value_test.sh \
    --failure-class assertion --expected-failure 'task 1.2 production value does not exist yet' \
    --match-output 'value-mismatch:src/later.value' --observed 'the shared focused test rejected the missing later value' -- \
    tests/value_test.sh src/later.value ready
assert_status 0
printf 'ready\n' > "$cross_repo/src/later.value"
run_managed_at "$cross_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0
run_managed_at "$cross_repo" scripts/task_verify.sh 1.2 \
    --phase green --cycle later-value --kind behavior --path src/later.value -- \
    tests/value_test.sh src/later.value ready
assert_status 0
run_managed_at "$cross_repo" scripts/task_verify.sh 1.2 \
    --phase regression --cycle later-value --kind behavior --path src/later.value -- \
    tests/value_test.sh src/later.value ready
assert_status 0
run_managed_at "$cross_repo" scripts/task_verify.sh --complete 1.2
assert_status 0

cross_verification="$cross_repo/openspec/changes/tdd-contract/harness/verification.json"
green_before=$(node -p "JSON.stringify(JSON.parse(require('fs').readFileSync(process.argv[1])).tasks.find(x=>x.task_id==='1.1').commands.find(x=>x.phase==='GREEN'))" "$cross_verification")
evidence_before=$(sha256sum -- "$cross_verification" | awk '{print $1}')
completed_green_marker="$tmp/completed-green-command-ran"
run_managed_at "$cross_repo" scripts/task_verify.sh 1.1 \
    --phase green --cycle widget-value --kind behavior --path src/widget.value -- \
    bash -c 'touch "$1"' _ "$completed_green_marker"
assert_status 6
[[ ! -e "$completed_green_marker" ]] || fail 'completed-task GREEN rewrite executed its command'
evidence_after=$(sha256sum -- "$cross_verification" | awk '{print $1}')
[[ "$evidence_before" == "$evidence_after" ]] || fail 'completed-task GREEN rewrite changed evidence'

run_managed_at "$cross_repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-value --kind behavior --path src/widget.value -- \
    tests/value_test.sh src/widget.value new
assert_status 0
green_after=$(node -p "JSON.stringify(JSON.parse(require('fs').readFileSync(process.argv[1])).tasks.find(x=>x.task_id==='1.1').commands.find(x=>x.phase==='GREEN'))" "$cross_verification")
[[ "$green_before" == "$green_after" ]] || fail 'cross-task refresh rewrote the original GREEN record'
node - "$cross_repo" <<'NODE'
const path = require('path');
const root = process.argv[2];
process.chdir(root);
const result = require(path.join(root, 'scripts', 'manifest_policy.js'))
  .verifyTddEvidence(root, 'tdd-contract', {requireDone: true});
if (!result.source_fingerprint) throw new Error('cross-task TDD evidence did not close');
const doc = JSON.parse(require('fs').readFileSync(
  path.join(root, 'openspec/changes/tdd-contract/harness/verification.json')));
const task = doc.tasks.find(x => x.task_id === '1.1');
if (task.commands.filter(x => x.phase === 'GREEN').length !== 1) {
  throw new Error('completed task gained a replacement GREEN');
}
if (task.commands.filter(x => x.phase === 'REGRESSION').length !== 2) {
  throw new Error('completed task did not gain exactly one REGRESSION refresh');
}
NODE

note '批准的 configuration_only 例外用 ALTERNATIVE 闭合，disposable_prototype 永远不能完成'
alternative_repo="$tmp/alternative TDD project"
create_repo "$alternative_repo" configuration_only
approve_repo "$alternative_repo"
mkdir -p "$alternative_repo/config"
printf 'mode=sample\n' > "$alternative_repo/config/widget.conf"
run_managed_at "$alternative_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0
note 'ALTERNATIVE changed path 必须落在批准例外的 config/** 范围内，并在执行命令前拒绝 src/**'
outside_marker="$tmp/out-of-scope-alternative-command-ran"
alternative_evidence="$alternative_repo/openspec/changes/tdd-contract/harness/verification.json"
evidence_before=$(sha256sum -- "$alternative_evidence" | awk '{print $1}')
run_managed_at "$alternative_repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-proof --kind static \
    --path src/outside.txt --observed 'an out-of-scope path must be rejected' -- \
    bash -c 'touch "$1"' _ "$outside_marker"
assert_status 6
[[ ! -e "$outside_marker" ]] || fail 'out-of-scope ALTERNATIVE executed its command'
evidence_after=$(sha256sum -- "$alternative_evidence" | awk '{print $1}')
[[ "$evidence_before" == "$evidence_after" ]] || fail 'out-of-scope ALTERNATIVE changed verification evidence'
run_managed_at "$alternative_repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-proof --kind static \
    --path config/widget.conf --observed 'the inert sample key is present' -- \
    bash -c 'grep -qx "mode=sample" config/widget.conf'
assert_status 0
run_managed_at "$alternative_repo" scripts/task_verify.sh --complete 1.1
assert_status 0
assert_task_checked "$alternative_repo" yes

note '已完成例外任务在其他 task 改变 source 后只能追加当前 ALTERNATIVE，且不得扩大批准 changed paths'
exception_cross_repo="$tmp/exception cross-task project"
create_repo "$exception_cross_repo" configuration_only 2
approve_repo "$exception_cross_repo" 2
mkdir -p "$exception_cross_repo/config"
printf 'mode=sample\n' > "$exception_cross_repo/config/widget.conf"
run_managed_at "$exception_cross_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0
run_managed_at "$exception_cross_repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-proof --kind static \
    --path config/widget.conf --observed 'the approved inert sample key is present' -- \
    bash -c 'grep -qx "mode=sample" config/widget.conf'
assert_status 0
run_managed_at "$exception_cross_repo" scripts/task_verify.sh --complete 1.1
assert_status 0
mkdir -p "$exception_cross_repo/src"
printf 'later task source\n' > "$exception_cross_repo/src/later.value"
run_managed_at "$exception_cross_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0

exception_verification="$exception_cross_repo/openspec/changes/tdd-contract/harness/verification.json"
exception_before=$(sha256sum -- "$exception_verification" | awk '{print $1}')
run_managed_at "$exception_cross_repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle forbidden-refresh --kind static \
    --path config/widget.conf -- bash -c 'exit 0'
assert_status 6
exception_after=$(sha256sum -- "$exception_verification" | awk '{print $1}')
[[ "$exception_before" == "$exception_after" ]] || fail 'completed exception task accepted non-ALTERNATIVE evidence'

run_managed_at "$exception_cross_repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-proof --kind static \
    --path config/expanded.conf --observed 'completed exception evidence must not expand its path set' -- \
    bash -c 'exit 0'
assert_status 6
exception_after=$(sha256sum -- "$exception_verification" | awk '{print $1}')
[[ "$exception_before" == "$exception_after" ]] || fail 'completed exception task expanded its approved changed paths'

run_managed_at "$exception_cross_repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-proof --kind static \
    --path config/widget.conf --observed 'the original approved path remains valid after later source change' -- \
    bash -c 'grep -qx "mode=sample" config/widget.conf'
assert_status 0
node - "$exception_cross_repo" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
process.chdir(root);
require(path.join(root, 'scripts', 'manifest_policy.js'))
  .verifyTddEvidence(root, 'tdd-contract', {taskId: '1.1'});
const task = JSON.parse(fs.readFileSync(path.join(
  root, 'openspec/changes/tdd-contract/harness/verification.json'
))).tasks.find(x => x.task_id === '1.1');
if (JSON.stringify(task.changed_paths) !== JSON.stringify(['config/widget.conf'])) {
  throw new Error('completed exception task changed_paths expanded');
}
if (task.commands.length !== 2 || task.commands.some(x => x.phase !== 'ALTERNATIVE')) {
  throw new Error('exception refresh was not append-only ALTERNATIVE evidence');
}
NODE

prototype_repo="$tmp/prototype TDD project"
create_repo "$prototype_repo" disposable_prototype
approve_repo "$prototype_repo"
mkdir -p "$prototype_repo/prototype"
printf 'exploration only\n' > "$prototype_repo/prototype/probe.txt"
run_managed_at "$prototype_repo" scripts/change_footprint.sh tdd-contract --json
assert_status 0
run_managed_at "$prototype_repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id prototype-proof --kind static \
    --path prototype/probe.txt --observed 'the disposable probe exists' -- \
    bash -c 'test -s prototype/probe.txt'
assert_status 0
run_managed_at "$prototype_repo" scripts/task_verify.sh --complete 1.1
assert_status 6
assert_task_checked "$prototype_repo" no

note '显式 v1 --upgrade-v2 保留原始 SHA，legacy Pass 只留审计且不参与 v2 closure'
legacy_repo="$tmp/legacy evidence project"
create_repo "$legacy_repo" normal
legacy_harness="$legacy_repo/openspec/changes/tdd-contract/harness"
node - "$legacy_harness/ai_snapshot.json" "$legacy_harness/verification.json" <<'NODE'
const fs = require('fs');
const [snapshotFile, verificationFile] = process.argv.slice(2);
fs.writeFileSync(snapshotFile, JSON.stringify({
  schema_version: 2,
  phase: 'planning',
  planned_base_specs_fingerprint: null,
  implementation_base_commit: null,
  adopted_preexisting_paths: [],
  implementation_baselined_at: null,
  current_step: 'legacy evidence',
  next_step: 'upgrade explicitly'
}, null, 2) + '\n');
fs.writeFileSync(verificationFile, JSON.stringify({
  schema_version: 1,
  change_name: 'tdd-contract',
  tasks: [{
    task_id: '1.1',
    requirement_refs: [],
    changed_paths: ['src/widget.value'],
    footprint_observation: {status: 'within_expected', drift_reason: null},
    commands: [{
      id: 'legacy-pass', kind: 'behavior', argv: ['true'], working_directory: '.',
      started_at: '2026-07-16T00:00:00Z', finished_at: '2026-07-16T00:00:01Z',
      expected_exit_codes: [0], exit_code: 0, result: 'Pass'
    }]
  }]
}, null, 2) + '\n');
NODE
legacy_sha="sha256:$(sha256sum -- "$legacy_harness/verification.json" | awk '{print $1}')"
run_managed_at "$legacy_repo" scripts/task_verify.sh --upgrade-v2 tdd-contract
assert_status 0
node - "$legacy_harness/verification.json" "$legacy_harness/ai_snapshot.json" "$legacy_sha" "$legacy_repo" <<'NODE'
const fs = require('fs');
const path = require('path');
const [verificationFile, snapshotFile, expectedSha, root] = process.argv.slice(2);
const verification = JSON.parse(fs.readFileSync(verificationFile));
const snapshot = JSON.parse(fs.readFileSync(snapshotFile));
if (verification.schema_version !== 2 || verification.migration?.source_sha256 !== expectedSha) {
  throw new Error('v1 source digest was not preserved by explicit upgrade');
}
if (verification.migration.legacy_verification.tasks[0].commands[0].result !== 'Pass') {
  throw new Error('legacy audit payload was not retained');
}
if (verification.tasks.length !== 0 || snapshot.schema_version !== 3) {
  throw new Error('legacy commands were inferred into native v2 evidence');
}
process.chdir(root);
let rejected = false;
try {
  require(path.join(root, 'scripts', 'manifest_policy.js')).verifyTddEvidence(root, 'tdd-contract', {taskId: '1.1'});
} catch { rejected = true; }
if (!rejected) throw new Error('legacy Pass closed a v2 task');
NODE

note 'schema v3/v2、RED/GREEN/REGRESSION、例外、漂移、升级和 secret 边界均已覆盖'
