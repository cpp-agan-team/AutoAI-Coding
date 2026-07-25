#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/review evidence v2 project"
init_git_repo "$repo"

fixed_clock="$tmp/fixed-clock.cjs"
cat > "$fixed_clock" <<'NODE'
const NativeDate = Date;
const fixed = Number(process.env.AUTOAI_TEST_NOW_MS);
if (!Number.isFinite(fixed)) throw new Error('AUTOAI_TEST_NOW_MS must be finite');
class FixedDate extends NativeDate {
  constructor(...args) { super(...(args.length ? args : [fixed])); }
  static now() { return fixed; }
}
global.Date = FixedDate;
NODE

export STUB_CALL_LOG="$tmp/setup-dependency-calls.log"
install_stub_path
reset_stub_environment

note '生成 OpenSpec Harness，并让运行期 OpenSpec stub 使用系统 Node'
run_setup "$repo"
assert_status 0

runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
cp -- "$STUB_BIN/npx" "$runtime_bin/npx"
chmod 755 "$runtime_bin/npx"
export PATH="$runtime_bin:$REAL_TEST_PATH"

change=review-evidence
change_dir="$repo/openspec/changes/$change"
harness_dir="$change_dir/harness"

(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
    use_modern_v2_fixture "$repo" "$change"
    mkdir -p "$change_dir/specs/review" src

    printf 'baseline\n' > src/unstaged.txt

    cat > "$change_dir/proposal.md" <<'EOF'
# Change: Preserve complete review evidence

Record a two-stage review over every implementation layer without persisting raw diff bodies.
EOF

    cat > "$change_dir/specs/review/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Review evidence completeness

The Harness SHALL bind independent review evidence to the complete implementation state.

#### Scenario: Every implementation layer is reviewed

- **WHEN** an Evaluation is completed
- **THEN** specification and code-quality review cover the frozen implementation diff
EOF

    cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Exercise the review evidence contract
  - Covers: `specs/review/spec.md` | `ADDED` | `Review evidence completeness` | `Every implementation layer is reviewed`
  - Verify: `behavior`
EOF

    cat > "$change_dir/design.md" <<'EOF'
# Design

Use a configuration-only TDD exception so this fixture can focus on Evaluation review evidence.

<!-- autoai:tdd-policy:v1 -->
```json
{
  "schema_version": 1,
  "default": "required",
  "exceptions": [
    {
      "id": "review-fixture",
      "category": "configuration_only",
      "task_ids": ["1.1"],
      "paths": ["src/**"],
      "reason": "This fixture validates review metadata rather than production behavior.",
      "alternative_verify_kinds": ["behavior"],
      "exit_condition": "Remove the exception when the fixture gains executable product behavior."
    }
  ]
}
```
<!-- /autoai:tdd-policy:v1 -->

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "micro",
  "rationale": "Four tiny fixture paths are enough to exercise committed, staged, unstaged and untracked review layers.",
  "classification": {
    "production": ["src/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md"],
    "project_tooling": ["CMakeLists.txt"],
    "examples": ["examples/**"],
    "generated": [],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 20, "review_at": 30, "hard_limit": 40},
      "touched_files": {"expected": 10, "review_at": 12, "hard_limit": 14},
      "new_files": {"expected": 10, "review_at": 12, "hard_limit": 14}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 5, "hard_limit": 10},
      "touched_files": {"expected": 0, "review_at": 2, "hard_limit": 4},
      "new_files": {"expected": 0, "review_at": 2, "hard_limit": 4}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 5, "hard_limit": 10},
      "new_files": {"expected": 0, "review_at": 2, "hard_limit": 4}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 2, "hard_limit": 4},
      "bytes": {"expected": 0, "review_at": 1024, "hard_limit": 4096}
    }
  },
  "structural_allowances": {
    "public_contracts": [],
    "cmake_targets": [],
    "direct_dependencies": []
  },
  "reuse_decisions": [],
  "obsolete_items": [],
  "exceptions": []
}
```
<!-- /autoai:implementation-economy:v1 -->
EOF

    git config user.name 'AutoAI Review Evidence Test'
    git config user.email 'autoai-review@example.invalid'
    git add -A
    git commit -qm 'approved review evidence fixture'

    export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
    scripts/snapshot_update.sh --freeze-planning-baseline --freeze-implementation-base >/dev/null
)

note '构造 committed、staged、unstaged、untracked 四层实现状态并记录替代验证'
raw_sentinel='RAW_DIFF_BODY_MUST_NOT_PERSIST_7f44a9'
(
    cd "$repo"
    export STUB_OPENSPEC_INSTRUCTIONS_MODE=success

    printf '%s committed\n' "$raw_sentinel" > src/committed.txt
    git add src/committed.txt
    git commit -qm 'committed implementation layer' -- src/committed.txt

    printf '%s staged\n' "$raw_sentinel" > src/staged.txt
    git add src/staged.txt
    printf '%s unstaged\n' "$raw_sentinel" > src/unstaged.txt
    printf '%s untracked\n' "$raw_sentinel" > src/untracked.txt

    scripts/change_footprint.sh "$change" --json >/dev/null 2>&1
    scripts/task_verify.sh 1.1 \
        --phase alternative \
        --exception-id review-fixture \
        --kind behavior \
        --path src/committed.txt \
        --path src/staged.txt \
        --path src/unstaged.txt \
        --path src/untracked.txt \
        --observed 'All four fixture files are present and non-empty.' \
        -- bash -c 'test -s src/committed.txt && test -s src/staged.txt && test -s src/unstaged.txt && test -s src/untracked.txt' >/dev/null 2>&1
    scripts/task_verify.sh --complete 1.1 >/dev/null
    scripts/evaluator_check.sh --begin "$change" >/dev/null
    scripts/evaluator_check.sh --run \
        --kind behavior \
        --expected 'Every review-layer fixture path is present and non-empty.' \
        --observed 'Every review-layer fixture path was present and non-empty.' \
        -- bash -c 'test -s src/committed.txt && test -s src/staged.txt && test -s src/unstaged.txt && test -s src/untracked.txt' >/dev/null
)

note 'Evaluation baseline v2 必须冻结所有 Git 层、路径并明确 raw diff 未持久化'
node - "$harness_dir/evaluation-baseline.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const baseline = JSON.parse(fs.readFileSync(file, 'utf8'));
if (baseline.schema_version !== 2 || baseline.status !== 'in_progress') {
  throw new Error('expected an in-progress Evaluation baseline v2');
}
const input = baseline.review_input;
const expectedLayers = ['effective', 'committed', 'staged', 'unstaged', 'untracked', 'dirty_gitlinks'];
if (!input || input.schema_version !== 1 || input.raw_diff_persisted !== false) {
  throw new Error('review_input identity or raw-diff policy missing');
}
if (JSON.stringify(Object.keys(input.layers)) !== JSON.stringify(expectedLayers)) {
  throw new Error(`unexpected review layers: ${Object.keys(input.layers)}`);
}
const has = (layer, value) => input.layers[layer].paths.includes(value);
if (!has('committed', 'src/committed.txt') || !has('staged', 'src/staged.txt') ||
    !has('unstaged', 'src/unstaged.txt') || !has('untracked', 'src/untracked.txt')) {
  throw new Error('a concrete Git review layer is missing its path');
}
const expectedPaths = ['src/committed.txt', 'src/staged.txt', 'src/unstaged.txt', 'src/untracked.txt'];
if (JSON.stringify([...input.review_paths].sort()) !== JSON.stringify(expectedPaths)) {
  throw new Error(`review_paths does not equal the full implementation union: ${input.review_paths}`);
}
for (const layer of Object.values(input.layers)) {
  if (!/^sha256:[0-9a-f]{64}$/.test(layer.state_fingerprint)) {
    throw new Error('review layer lacks a state fingerprint');
  }
}
if (!/^sha256:[0-9a-f]{64}$/.test(input.git_state_fingerprint)) {
  throw new Error('review_input lacks an aggregate Git-state fingerprint');
}
NODE

if grep -Fq -- "$raw_sentinel" "$harness_dir/evaluation-baseline.json"; then
    fail 'Evaluation baseline persisted a raw diff body'
fi

run_runtime_at() {
    local directory=$1
    shift
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$directory" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

assert_in_progress() {
    node - "$harness_dir/evaluation-baseline.json" <<'NODE'
const fs=require('fs');
if (JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).status !== 'in_progress') {
  throw new Error('rejected Evaluation changed the attempt terminal state');
}
NODE
}

write_evaluation() {
    local mode=$1
    node - "$harness_dir/evaluation-baseline.json" "$harness_dir/change-footprint.json" \
        "$harness_dir/evaluation-command-ledger.json" "$harness_dir/evaluation.json" \
        "$change" "$mode" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, outputFile, change, mode] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const footprint = JSON.parse(fs.readFileSync(footprintFile, 'utf8'));
const ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
const reviewPaths = baseline.review_input.review_paths;
const requirementRef = {
  spec_path: 'specs/review/spec.md',
  operation: 'ADDED',
  requirement: 'Review evidence completeness',
  scenarios: ['Every implementation layer is reviewed']
};
if (ledger.schema_version !== 1 || ledger.evaluation_id !== baseline.evaluation_id ||
    ledger.change_name !== change || !Array.isArray(ledger.commands)) {
  throw new Error('managed Evaluation command ledger does not match the active attempt');
}
const command = ledger.commands.find(item => item.kind === 'behavior' && item.result === 'Pass');
if (!command) throw new Error('fixture lacks a managed passing behavior command');
const evidenceFinished = Math.max(Date.parse(baseline.started_at), ...ledger.commands.map(item => Date.parse(item.finished_at)));
const reportObservedAt = Date.now();
if (!Number.isFinite(evidenceFinished) || evidenceFinished > reportObservedAt + 300000) {
  throw new Error('managed command timestamps extend beyond the report creation time');
}
const evaluatedAt = new Date(Math.max(reportObservedAt, evidenceFinished)).toISOString();
const reviewBoundary = new Date(evidenceFinished).toISOString();
const evaluationCommands = [...ledger.commands];
const stage = (name, started, completed, dimensions) => ({
  name,
  started_at: started,
  completed_at: completed,
  status: 'Pass',
  requirement_refs: [requirementRef],
  task_ids: ['1.1'],
  reviewed_paths: [...reviewPaths],
  dimensions,
  evidence_command_ids: [command.id],
  finding_ids: [],
  blocking_untested_ids: [],
  not_run_reason: null
});
const specification = stage(
  'specification_compliance', baseline.started_at,
  mode === 'reversed-order' ? evaluatedAt : reviewBoundary,
  ['requirements', 'scenarios', 'scope', 'contracts', 'traceability']
);
const quality = stage(
  'code_quality', mode === 'reversed-order' ? baseline.started_at : reviewBoundary, evaluatedAt,
  ['correctness', 'safety', 'regression_risk', 'reuse', 'complexity', 'test_quality', 'repository_impact']
);
const findings = [];
const residualRisks = [];
const findingBase = {
  id: 'finding-review-followup',
  stage: 'code_quality',
  category: 'maintainability',
  severity: 'Minor',
  status: 'Deferred',
  summary: 'The test fixture leaves a low-impact naming follow-up.',
  requirement_refs: [requirementRef],
  task_ids: ['1.1'],
  evidence_paths: [reviewPaths[0]],
  evidence_command_ids: [command.id],
  return_to: 'Generator',
  resolution: null,
  tracking: {kind: 'residual_risk', id: 'risk-review-followup'}
};
if (mode === 'deferred-minor') {
  findings.push(findingBase);
  residualRisks.push({
    id: 'risk-review-followup',
    impact: 'Only fixture naming remains imperfect.',
    rationale: 'The behavior and production contract are unaffected.'
  });
  quality.finding_ids = [findingBase.id];
} else if (mode === 'deferred-clock') {
  const finding = {
    ...findingBase,
    id: 'finding-clock-followup',
    summary: 'A rollback-window attempt introduced a distinct low-impact follow-up.',
    tracking: {kind: 'residual_risk', id: 'risk-clock-followup'}
  };
  findings.push(finding);
  residualRisks.push({
    id: 'risk-clock-followup',
    impact: 'Only the rollback-window fixture naming remains imperfect.',
    rationale: 'The finding must remain traceable across later Evaluation attempts.'
  });
  quality.finding_ids = [finding.id];
} else if (mode === 'resolved-clock') {
  const finding = {
    ...findingBase,
    id: 'finding-clock-followup',
    summary: 'A rollback-window attempt introduced a distinct low-impact follow-up.',
    status: 'Resolved',
    resolution: {
      summary: 'The rollback-window follow-up was independently checked and closed.',
      evidence_paths: [reviewPaths[0]],
      evidence_command_ids: [command.id]
    },
    tracking: null
  };
  findings.push(finding);
  quality.finding_ids = [finding.id];
} else if (mode === 'resolved-minor' || mode === 'resolved-missing-path' || mode === 'resolved-failed-command') {
  let resolutionPaths = [reviewPaths[0]];
  let resolutionCommandIds = [command.id];
  if (mode === 'resolved-missing-path') {
    resolutionPaths = ['src/resolution-evidence-does-not-exist.txt'];
  }
  if (mode === 'resolved-failed-command') {
    const failedResolutionCommand = ledger.commands.find(item => item.result === 'Fail');
    if (!failedResolutionCommand) throw new Error('fixture lacks a managed failed resolution command');
    resolutionCommandIds = [failedResolutionCommand.id];
  }
  findings.push({
    ...findingBase,
    status: 'Resolved',
    resolution: {
      summary: 'The naming follow-up was independently checked and closed.',
      evidence_paths: resolutionPaths,
      evidence_command_ids: resolutionCommandIds
    },
    tracking: null
  });
  quality.finding_ids = [findingBase.id];
} else if (mode === 'open-critical' || mode === 'open-important') {
  const finding = {
    ...findingBase,
    id: `finding-open-${mode === 'open-critical' ? 'critical' : 'important'}`,
    severity: mode === 'open-critical' ? 'Critical' : 'Important',
    status: 'Open',
    summary: `An open ${mode === 'open-critical' ? 'critical' : 'important'} issue still affects the implementation.`,
    resolution: null,
    tracking: null
  };
  findings.push(finding);
  quality.finding_ids = [finding.id];
  // Deliberately retain Pass to prove a blocking finding cannot be hidden in a fake aggregate.
} else if (mode === 'spec-minor') {
  const finding = {
    ...findingBase,
    id: 'finding-spec-minor',
    stage: 'specification_compliance',
    category: 'specification',
    summary: 'A specification mismatch was incorrectly downgraded to Minor.'
  };
  findings.push(finding);
  residualRisks.push({
    id: 'risk-review-followup',
    impact: 'A specification mismatch would remain unresolved.',
    rationale: 'This is intentionally invalid negative-test input.'
  });
  specification.finding_ids = [finding.id];
} else if (mode === 'missing-coverage') {
  specification.reviewed_paths = reviewPaths.slice(1);
}
const evaluation = {
  schema_version: 2,
  evaluation_id: baseline.evaluation_id,
  change_name: change,
  verdict: 'Pass',
  evaluation_started_at: baseline.started_at,
  evaluated_at: evaluatedAt,
  openspec_version: '1.6.0',
  evaluator_role: 'independent',
  input_source_fingerprint: baseline.source_fingerprint,
  input_artifact_fingerprint: baseline.artifact_fingerprint,
  input_base_specs_fingerprint: baseline.base_specs_fingerprint,
  source_fingerprint: baseline.source_fingerprint,
  artifact_fingerprint: baseline.artifact_fingerprint,
  base_specs_fingerprint: baseline.base_specs_fingerprint,
  budget_block_sha256: baseline.budget_block_sha256,
  change_footprint_json_sha256: baseline.change_footprint_json_sha256,
  review_input: baseline.review_input,
  change_review: {
    schema_version: 1,
    git_state_fingerprint: baseline.review_input.git_state_fingerprint,
    stages: [specification, quality],
    findings
  },
  implementation_economy: {
    footprint_status: footprint.status,
    drift_explanation: null,
    classification_assessment: {
      result: 'Pass',
      reason: 'Every implementation path matches the approved production fixture classification.',
      evidence_paths: [...reviewPaths],
      evidence_command_ids: [command.id]
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets', applicability: 'applicable', result: 'Pass',
          reason: 'The fixture behavior command covers the only applicable product surface.',
          evidence_paths: [...reviewPaths], evidence_command_ids: [command.id], not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'not_applicable', result: null,
          reason: 'This fixture has no install surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No install rules exist in the fixture.'
        },
        {
          surface: 'package', applicability: 'not_applicable', result: null,
          reason: 'This fixture has no package surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No package rules exist in the fixture.'
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'This fixture has no CI surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI configuration exists in the fixture.'
        }
      ]
    },
    reuse_assessments: [],
    structural_assessments: [],
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: 'criterion-review-evidence',
    description: 'Both review stages cover the complete implementation state.',
    requirement_refs: [requirementRef],
    task_ids: ['1.1'],
    status: 'Pass',
    evidence_command_ids: [command.id],
    blocking_untested_ids: []
  }],
  commands: evaluationCommands,
  blocking_untested: [],
  residual_risks: residualRisks
};
fs.writeFileSync(outputFile, JSON.stringify(evaluation, null, 2) + '\n');
NODE
}

reject_mode() {
    local mode=$1 label=$2
    write_evaluation "$mode"
    run_runtime_at "$repo" scripts/evaluator_check.sh --finish "$change"
    [[ "$RUN_STATUS" -ne 0 ]] || fail "$label 应被 Evaluation v2 门禁拒绝"
    assert_in_progress
}

note '仅改变 index、保持工作树和 source fingerprint 不变，也必须触发 review-input drift'
source_before=$(cd "$repo" && scripts/source_fingerprint.sh --kind source)
(
    cd "$repo"
    git reset -q HEAD -- src/staged.txt
)
source_after=$(cd "$repo" && scripts/source_fingerprint.sh --kind source)
[[ "$source_before" == "$source_after" ]] || fail 'index-only drift unexpectedly changed source fingerprint'
write_evaluation clean
run_runtime_at "$repo" scripts/evaluator_check.sh --finish "$change"
[[ "$RUN_STATUS" -ne 0 ]] || fail 'index-only drift should invalidate the frozen review input'
assert_in_progress
(
    cd "$repo"
    git add src/staged.txt
)

note '两阶段顺序、全路径覆盖和 finding 严重级别均为机器门禁'
reject_mode reversed-order '反向审查阶段顺序'
reject_mode missing-coverage '不完整审查路径覆盖'
reject_mode open-critical 'Open Critical 伪 Pass'
reject_mode open-important 'Open Important 伪 Pass'
reject_mode spec-minor '规格审查 Minor finding'
reject_mode resolved-missing-path 'Resolved finding 引用不存在的 evidence path'

note 'Resolved finding 不能用受管但未通过的命令伪装修复证据'
run_runtime_at "$repo" scripts/evaluator_check.sh --run \
    --kind static \
    --expected 'The resolution-specific check exits successfully.' \
    --observed 'The resolution-specific check exited with status 1.' \
    -- false
[[ "$RUN_STATUS" -ne 0 ]] || fail '负向 Evaluation 命令未按预期失败'
reject_mode resolved-failed-command 'Resolved finding 引用未通过的命令'

note '中止的 Evaluation attempt 也必须封存 terminal baseline envelope'
aborted_id=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" "$harness_dir/evaluation-baseline.json")
run_runtime_at "$repo" scripts/evaluator_check.sh --abort "$change" --reason 'Negative review-evidence attempts are complete; start a clean attempt.'
assert_status 0
aborted_envelope="$harness_dir/evaluations/$aborted_id.json"
assert_path_exists "$aborted_envelope"
node - "$harness_dir/evaluation-baseline.json" "$aborted_envelope" "$change" "$aborted_id" <<'NODE'
const fs=require('fs'),crypto=require('crypto');
const [baselineFile,envelopeFile,change,id]=process.argv.slice(2);
const baseline=JSON.parse(fs.readFileSync(baselineFile));
const envelope=JSON.parse(fs.readFileSync(envelopeFile));
const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(',')}]`:
  value&&typeof value==='object'?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`:
  JSON.stringify(value);
const digest=value=>'sha256:'+crypto.createHash('sha256').update(canonical(value)).digest('hex');
if (envelope.envelope_schema_version!==1 || envelope.evaluation_id!==id ||
    envelope.change_name!==change || envelope.terminal_status!=='aborted') {
  throw new Error('aborted history entry is not a terminal Evaluation envelope');
}
if (envelope.source_schema_version!==2 || envelope.evaluation!==null ||
    envelope.evaluation_sha256!==null) {
  throw new Error('aborted envelope must preserve schema v2 with an empty Evaluation payload');
}
if (envelope.baseline_sha256!==digest(baseline) ||
    JSON.stringify(envelope.baseline)!==JSON.stringify(baseline)) {
  throw new Error('aborted envelope does not bind the exact terminal baseline');
}
if (envelope.baseline.status!=='aborted' || !envelope.baseline.aborted_at || !envelope.sealed_at) {
  throw new Error('aborted envelope lacks terminal state or sealing time');
}
NODE
run_runtime_at "$repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_runtime_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior \
    --expected 'Every review-layer fixture path is present and non-empty.' \
    --observed 'Every review-layer fixture path was present and non-empty.' \
    -- bash -c 'test -s src/committed.txt && test -s src/staged.txt && test -s src/unstaged.txt && test -s src/untracked.txt'
assert_status 0

note 'Deferred Minor 必须绑定 residual risk，合法两阶段审查可完成并写入不可变历史'
write_evaluation deferred-minor
run_runtime_at "$repo" scripts/evaluator_check.sh --finish "$change"
assert_status 0
evaluation_id=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" "$harness_dir/evaluation.json")
immutable="$harness_dir/evaluations/$evaluation_id.json"
assert_path_exists "$immutable"
node - "$harness_dir/evaluation-baseline.json" "$harness_dir/evaluation.json" "$immutable" "$change" "$evaluation_id" <<'NODE'
const fs=require('fs'),crypto=require('crypto');
const [baselineFile,evaluationFile,envelopeFile,change,id]=process.argv.slice(2);
const baseline=JSON.parse(fs.readFileSync(baselineFile)),evaluation=JSON.parse(fs.readFileSync(evaluationFile));
const envelope=JSON.parse(fs.readFileSync(envelopeFile));
const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(',')}]`:
  value&&typeof value==='object'?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`:
  JSON.stringify(value);
const digest=value=>'sha256:'+crypto.createHash('sha256').update(canonical(value)).digest('hex');
if (envelope.envelope_schema_version!==1 || envelope.evaluation_id!==id ||
    envelope.change_name!==change || envelope.terminal_status!=='complete' ||
    envelope.source_schema_version!==2) {
  throw new Error('completed history entry is not a terminal Evaluation envelope');
}
if (envelope.baseline_sha256!==digest(baseline) ||
    envelope.evaluation_sha256!==digest(evaluation)) {
  throw new Error('completed envelope digest does not bind current terminal evidence');
}
if (JSON.stringify(envelope.baseline)!==JSON.stringify(baseline) ||
    JSON.stringify(envelope.evaluation)!==JSON.stringify(evaluation)) {
  throw new Error('completed envelope does not preserve baseline and Evaluation payloads');
}
if (envelope.baseline.status!=='complete' || !envelope.sealed_at) {
  throw new Error('completed envelope lacks terminal state or sealing time');
}
NODE
for evidence in "$harness_dir/evaluation-baseline.json" "$harness_dir/evaluation.json" "$immutable"; do
    if grep -Fq -- "$raw_sentinel" "$evidence"; then
        fail "review evidence persisted raw diff text: $evidence"
    fi
done

note '已完成 Evaluation 的不可变副本被改写后，direct recheck 必须拒绝'
cp -p -- "$immutable" "$tmp/immutable.saved"
printf ' \n' >> "$immutable"
run_runtime_at "$repo" scripts/evaluator_check.sh --recheck "$change"
[[ "$RUN_STATUS" -ne 0 ]] || fail 'tampered immutable Evaluation snapshot passed direct recheck'
cp -p -- "$tmp/immutable.saved" "$immutable"
run_runtime_at "$repo" scripts/evaluator_check.sh --recheck "$change"
assert_status 0

note '下一次 Evaluation 不能让历史 Deferred finding 消失，只能保留或显式关闭'
run_runtime_at "$repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_runtime_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior \
    --expected 'Every review-layer fixture path is present and non-empty.' \
    --observed 'Every review-layer fixture path was present and non-empty.' \
    -- bash -c 'test -s src/committed.txt && test -s src/staged.txt && test -s src/unstaged.txt && test -s src/untracked.txt'
assert_status 0
write_evaluation clean
run_runtime_at "$repo" scripts/evaluator_check.sh --finish "$change"
[[ "$RUN_STATUS" -ne 0 ]] || fail 'a prior Deferred finding disappeared from the next Evaluation'
assert_in_progress

write_evaluation resolved-minor
run_runtime_at "$repo" scripts/evaluator_check.sh --finish "$change"
assert_status 0

node - "$harness_dir/evaluation.json" "$harness_dir/evaluations" <<'NODE'
const fs=require('fs'),path=require('path');
const [currentFile, historyDir]=process.argv.slice(2);
const current=JSON.parse(fs.readFileSync(currentFile, 'utf8'));
const finding=current.change_review.findings.find(x=>x.id==='finding-review-followup');
if (!finding || finding.status!=='Resolved' || !finding.resolution) {
  throw new Error('the prior Deferred finding was not explicitly resolved');
}
const files=fs.readdirSync(historyDir).filter(x=>x.endsWith('.json'));
if (files.length!==3) throw new Error(`expected one aborted and two completed immutable attempts, got ${files.length}`);
let aborted=0,completed=0;
for (const file of files) {
  const data=JSON.parse(fs.readFileSync(path.join(historyDir,file), 'utf8'));
  if (data.envelope_schema_version!==1 || data.change_name!=='review-evidence' ||
      data.source_schema_version!==2 || !data.baseline ||
      !/^sha256:[0-9a-f]{64}$/.test(data.baseline_sha256)) {
    throw new Error('invalid immutable Evaluation history envelope');
  }
  if (data.terminal_status==='aborted' && data.evaluation===null && data.evaluation_sha256===null) aborted++;
  else if (data.terminal_status==='complete' && data.evaluation &&
           /^sha256:[0-9a-f]{64}$/.test(data.evaluation_sha256)) completed++;
  else throw new Error('invalid terminal payload in Evaluation history envelope');
}
if (aborted!==1 || completed!==2) throw new Error(`unexpected terminal history mix: ${aborted} aborted, ${completed} completed`);
NODE

note 'A 在未来容差内完成后，B 的新 Deferred finding 仍必须成为 C 的直接 lineage 前驱'
clock_a=$(( $(node -p 'Date.now()') + 240000 ))
run_runtime_at "$repo" env AUTOAI_TEST_NOW_MS="$clock_a" NODE_OPTIONS="--require=$fixed_clock" \
    scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_runtime_at "$repo" env AUTOAI_TEST_NOW_MS="$clock_a" NODE_OPTIONS="--require=$fixed_clock" \
    scripts/evaluator_check.sh --run \
    --kind behavior \
    --expected 'Every review-layer fixture path is present and non-empty.' \
    --observed 'Every review-layer fixture path was present and non-empty.' \
    -- bash -c 'test -s src/committed.txt && test -s src/staged.txt && test -s src/unstaged.txt && test -s src/untracked.txt'
assert_status 0
AUTOAI_TEST_NOW_MS="$clock_a" NODE_OPTIONS="--require=$fixed_clock" write_evaluation clean
run_runtime_at "$repo" env AUTOAI_TEST_NOW_MS="$clock_a" NODE_OPTIONS="--require=$fixed_clock" \
    scripts/evaluator_check.sh --finish "$change"
assert_status 0
clock_a_id=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" "$harness_dir/evaluation.json")

run_runtime_at "$repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_runtime_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior \
    --expected 'Every review-layer fixture path is present and non-empty.' \
    --observed 'Every review-layer fixture path was present and non-empty.' \
    -- bash -c 'test -s src/committed.txt && test -s src/staged.txt && test -s src/unstaged.txt && test -s src/untracked.txt'
assert_status 0
write_evaluation deferred-clock
run_runtime_at "$repo" scripts/evaluator_check.sh --finish "$change"
assert_status 0
clock_b_id=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" "$harness_dir/evaluation.json")

run_runtime_at "$repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_runtime_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior \
    --expected 'Every review-layer fixture path is present and non-empty.' \
    --observed 'Every review-layer fixture path was present and non-empty.' \
    -- bash -c 'test -s src/committed.txt && test -s src/staged.txt && test -s src/unstaged.txt && test -s src/untracked.txt'
assert_status 0
write_evaluation clean
run_runtime_at "$repo" scripts/evaluator_check.sh --finish "$change"
[[ "$RUN_STATUS" -ne 0 ]] || fail 'rollback-window predecessor finding disappeared from the next Evaluation'
assert_in_progress
write_evaluation resolved-clock
run_runtime_at "$repo" scripts/evaluator_check.sh --finish "$change"
assert_status 0
clock_c_id=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" "$harness_dir/evaluation.json")

node - "$harness_dir/evaluations" "$clock_a_id" "$clock_b_id" "$clock_c_id" <<'NODE'
const fs=require('fs'),path=require('path');
const [dir,aId,bId,cId]=process.argv.slice(2);
const load=id=>JSON.parse(fs.readFileSync(path.join(dir,id+'.json')));
const a=load(aId),b=load(bId),c=load(cId);
const aTerminal=Date.parse(a.baseline.completed_at),bStarted=Date.parse(b.baseline.started_at);
const bTerminal=Date.parse(b.baseline.completed_at),cStarted=Date.parse(c.baseline.started_at);
if (!(bStarted>aTerminal && cStarted>bTerminal)) {
  throw new Error('Evaluation attempts are not strictly monotonic across the rollback window');
}
const deferred=b.evaluation.change_review.findings.find(x=>x.id==='finding-clock-followup');
const resolved=c.evaluation.change_review.findings.find(x=>x.id==='finding-clock-followup');
if (deferred?.status!=='Deferred' || resolved?.status!=='Resolved') {
  throw new Error('rollback-window finding lineage was not retained and explicitly resolved');
}
NODE

note 'Review evidence v2 回归通过'
