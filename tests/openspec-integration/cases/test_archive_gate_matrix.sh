#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/archive gate base"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/setup-dependency-calls.log"
install_stub_path
reset_stub_environment

note '构造一份具备真实 Generator 命令和独立 Pass 的可归档基线'
run_setup "$repo"
assert_status 0
export PATH=$REAL_TEST_PATH

runtime_bin="$tmp/runtime-bin"
runtime_log="$tmp/runtime-npx-calls.log"
mkdir -p "$runtime_bin"
: > "$runtime_log"
export ARCHIVE_GATE_RUNTIME_LOG=$runtime_log

cat > "$runtime_bin/npx" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
index=-1
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == openspec ]]; then
        index=$i
        break
    fi
done
(( index >= 0 )) || { echo 'runtime npx stub expected openspec' >&2; exit 64; }
command_args=("${args[@]:index + 1}")
case "${command_args[0]:-}" in
    --version|-v|version)
        printf '1.6.0\n'
        ;;
    validate)
        if [[ "${ARCHIVE_GATE_VALIDATE:-pass}" == fail ]]; then
            printf '{"items":[{"id":"widget-output","valid":false,"issues":[{"level":"ERROR","message":"injected strict failure"}]}],"summary":{"totals":{"failed":1}}}\n'
        else
            printf '{"items":[{"id":"widget-output","valid":true,"issues":[]}],"summary":{"totals":{"failed":0}}}\n'
        fi
        ;;
    status)
        printf '{"changeName":"widget-output","schemaName":"spec-driven","isComplete":true,"artifacts":[{"id":"proposal","status":"done"},{"id":"design","status":"done"},{"id":"specs","status":"done"},{"id":"tasks","status":"done"}]}\n'
        ;;
    instructions)
        instruction_mode=${ARCHIVE_GATE_INSTRUCTIONS:-auto}
        if [[ "$instruction_mode" == auto ]]; then
            if grep -q '^- \[[xX]\] 1\.1 ' openspec/changes/widget-output/tasks.md; then
                instruction_mode=all_done
            else
                instruction_mode=incomplete
            fi
        fi
        case "$instruction_mode" in
            incomplete)
                printf '{"changeName":"widget-output","schemaName":"spec-driven","state":"ready","progress":{"total":1,"complete":0,"remaining":1},"tasks":[{"id":"1.1","done":false}]}\n'
                ;;
            zero)
                printf '{"changeName":"widget-output","schemaName":"spec-driven","state":"all_done","progress":{"total":0,"complete":0,"remaining":0},"tasks":[]}\n'
                ;;
            all_done)
                printf '{"changeName":"widget-output","schemaName":"spec-driven","state":"all_done","progress":{"total":1,"complete":1,"remaining":0},"tasks":[{"id":"1.1","done":true}]}\n'
                ;;
            *)
                printf 'unknown instruction mode\n' >&2
                exit 64
                ;;
        esac
        ;;
    archive)
        printf 'archive-invoked\n' >> "${ARCHIVE_GATE_RUNTIME_LOG:?}"
        printf 'negative gate matrix must not reach archive\n' >&2
        exit 91
        ;;
    *)
        printf 'unsupported offline OpenSpec command: %s\n' "${command_args[*]}" >&2
        exit 64
        ;;
esac
STUB
chmod 755 "$runtime_bin/npx"
export PATH="$runtime_bin:$PATH"

change=widget-output
change_dir="$repo/openspec/changes/$change"
harness_dir="$change_dir/harness"
mkdir -p "$change_dir/specs/widget" "$harness_dir" "$repo/src" "$repo/tests"
printf 'schema: spec-driven\n' > "$change_dir/.openspec.yaml"

cat > "$repo/src/widget.sh" <<'EOF'
#!/usr/bin/env bash
printf '1\n'
EOF
chmod 755 "$repo/src/widget.sh"

cat > "$repo/tests/widget_behavior.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
actual=$(bash src/widget.sh)
if [[ "$actual" != 7 ]]; then
    printf 'expected widget output 7, got %s\n' "$actual" >&2
    exit 1
fi
EOF
chmod 755 "$repo/tests/widget_behavior.sh"

cat > "$change_dir/proposal.md" <<'EOF'
# Change: Print the approved widget value

The executable widget must print the approved value while retaining a zero exit code.
EOF

cat > "$change_dir/specs/widget/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Widget exit behavior

The widget executable SHALL print the approved value and exit successfully.

#### Scenario: Returns seven

- **WHEN** the widget executable is run
- **THEN** standard output is `7` and the process exits with code 0
EOF

cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Implement the approved widget output
  - Covers: `specs/widget/spec.md` | `ADDED` | `Widget exit behavior` | `Returns seven`
  - Verify: `build`, `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
# Design

Reuse the existing executable script and change only its output value.

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "micro",
  "rationale": "One existing implementation line changes; no new API, target, or dependency is needed.",
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
      "added_lines": {"expected": 2, "review_at": 5, "hard_limit": 10},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 5, "hard_limit": 10},
      "touched_files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 5, "hard_limit": 10},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 1, "hard_limit": 2},
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

<!-- autoai:tdd-policy:v1 -->
```json
{
  "schema_version": 1,
  "default": "required",
  "exceptions": []
}
```
<!-- /autoai:tdd-policy:v1 -->
EOF

cat > "$harness_dir/ai_snapshot.json" <<'EOF'
{
  "schema_version": 3,
  "phase": "planning",
  "planned_base_specs_fingerprint": null,
  "planned_change_fingerprint": null,
  "planned_tdd_policy_sha256": null,
  "planning_approved_at": null,
  "implementation_base_commit": null,
  "adopted_preexisting_paths": [],
  "implementation_baselined_at": null,
  "current_step": "complete planning artifacts",
  "next_step": "strict validate and obtain human review"
}
EOF

cat > "$harness_dir/verification.json" <<EOF
{
  "schema_version": 2,
  "change_name": "$change",
  "migration": null,
  "tasks": []
}
EOF
printf '# Verification — %s\n\n' "$change" > "$harness_dir/verification.md"
printf '# Evaluation history — %s\n\n' "$change" > "$harness_dir/evaluation.md"
printf '# Defect RCA — %s\n\n' "$change" > "$harness_dir/defect-rca.md"

(
    cd "$repo"
    scripts/change_select.sh "$change" >/dev/null
    git config user.name 'AutoAI Archive Gate Test'
    git config user.email 'autoai-archive-gate@example.invalid'
    git add -A
    git commit -qm 'baseline archive gate fixture'
    scripts/snapshot_update.sh --freeze-planning-baseline --freeze-implementation-base >/dev/null
)

(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
    scripts/task_verify.sh 1.1 --phase red --cycle widget-output --kind behavior \
        --expect-exit 1 --path src/widget.sh --test-path tests/widget_behavior.sh \
        --failure-class behavior --expected-failure 'The baseline script prints one instead of the required seven.' \
        --match-output 'expected widget output 7' --observed 'Focused behavior test failed for the specified output mismatch.' -- \
        bash tests/widget_behavior.sh >/dev/null
)
sed -i "s/printf '1/printf '7/" "$repo/src/widget.sh"
(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
    scripts/task_verify.sh 1.1 --phase green --cycle widget-output --kind behavior \
        --path src/widget.sh --observed 'The focused behavior test passed after the minimal script change.' -- \
        bash tests/widget_behavior.sh >/dev/null
    scripts/task_verify.sh 1.1 --phase regression --cycle widget-output --kind build \
        --path src/widget.sh --observed 'The changed script retained valid shell syntax.' -- \
        bash -n src/widget.sh >/dev/null
    scripts/task_verify.sh 1.1 --phase regression --cycle widget-output --kind behavior \
        --path src/widget.sh --observed 'The required output behavior remained green.' -- \
        bash tests/widget_behavior.sh >/dev/null
    scripts/task_verify.sh --complete 1.1 >/dev/null
    scripts/evaluator_check.sh --begin "$change" >/dev/null
    scripts/evaluator_check.sh --run \
        --kind build \
        --expected 'The executable script has valid shell syntax.' \
        --observed 'Shell syntax validation exited with code 0.' -- \
        bash -n src/widget.sh >/dev/null
    scripts/evaluator_check.sh --run \
        --kind behavior \
        --expected 'The widget prints seven and exits with code 0.' \
        --observed 'The widget printed seven and exited with code 0.' -- \
        bash -c 'test "$(bash src/widget.sh)" = 7' >/dev/null
)

node - "$harness_dir/evaluation-baseline.json" "$harness_dir/change-footprint.json" \
    "$harness_dir/evaluation-command-ledger.json" "$harness_dir/evaluation.json" \
    "$change" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, outputFile, change] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const footprint = JSON.parse(fs.readFileSync(footprintFile, 'utf8'));
const ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
const requirementRef = {
  spec_path: 'specs/widget/spec.md', operation: 'ADDED',
  requirement: 'Widget exit behavior', scenarios: ['Returns seven']
};
if (ledger.schema_version!==1 || ledger.evaluation_id!==baseline.evaluation_id ||
    ledger.change_name!==change || !Array.isArray(ledger.commands) || ledger.commands.length!==2 ||
    ledger.commands.some(command=>command.result!=='Pass')) {
  throw new Error('archive fixture lacks its two managed passing Evaluation commands');
}
const commands = [...ledger.commands];
const evidenceFinished = Math.max(Date.parse(baseline.started_at), ...commands.map(command=>Date.parse(command.finished_at)));
const reportObservedAt = Date.now();
if (!Number.isFinite(evidenceFinished) || evidenceFinished>reportObservedAt+1000) {
  throw new Error('managed Evaluation commands extend beyond report creation tolerance');
}
const reviewedAt = new Date(evidenceFinished).toISOString();
const evaluated = new Date(Math.max(reportObservedAt,evidenceFinished)).toISOString();
const ids = commands.map(command => command.id);
const reviewStage = (name, stageStarted, stageFinished, dimensions) => ({
  name,
  started_at: stageStarted,
  completed_at: stageFinished,
  status: 'Pass',
  requirement_refs: [requirementRef],
  task_ids: ['1.1'],
  reviewed_paths: baseline.review_input.review_paths,
  dimensions,
  evidence_command_ids: ids,
  finding_ids: [],
  blocking_untested_ids: [],
  not_run_reason: null
});
const evaluation = {
  schema_version: 2,
  evaluation_id: baseline.evaluation_id,
  change_name: change,
  verdict: 'Pass',
  evaluation_started_at: baseline.started_at,
  evaluated_at: evaluated,
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
    stages: [
      reviewStage('specification_compliance', baseline.started_at, reviewedAt,
        ['requirements', 'scenarios', 'scope', 'contracts', 'traceability']),
      reviewStage('code_quality', reviewedAt, evaluated,
        ['correctness', 'safety', 'regression_risk', 'reuse', 'complexity', 'test_quality', 'repository_impact'])
    ],
    findings: []
  },
  implementation_economy: {
    footprint_status: footprint.status,
    drift_explanation: null,
    classification_assessment: {
      result: 'Pass', reason: 'The sole implementation path matches the approved production classification.',
      evidence_paths: ['src/widget.sh'], evidence_command_ids: ids
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets', applicability: 'applicable', result: 'Pass',
          reason: 'The existing executable script passes syntax and behavior checks.',
          evidence_paths: ['src/widget.sh'], evidence_command_ids: ids, not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'not_applicable', result: null,
          reason: 'The fixture has no install surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No install rule exists in the baseline project.'
        },
        {
          surface: 'package', applicability: 'not_applicable', result: null,
          reason: 'The fixture has no package surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No package configuration exists in the baseline project.'
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'The fixture has no CI surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI configuration exists in the baseline project.'
        }
      ]
    },
    reuse_assessments: [], structural_assessments: [], obsolete_item_assessments: [], exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: 'criterion-widget-output',
    description: 'The existing widget executable prints seven and exits successfully.',
    requirement_refs: [requirementRef], task_ids: ['1.1'], status: 'Pass',
    evidence_command_ids: ids, blocking_untested_ids: []
  }],
  commands,
  blocking_untested: [],
  residual_risks: []
};
fs.writeFileSync(outputFile, JSON.stringify(evaluation, null, 2) + '\n');
NODE

(
    cd "$repo"
    scripts/evaluator_check.sh --finish "$change" >/dev/null
)
node - "$harness_dir/evaluation-baseline.json" "$harness_dir/evaluation.json" <<'NODE' || \
    fail '归档门禁矩阵没有建立 digest-bound Pass 基线'
const fs=require('fs'),crypto=require('crypto');
const [baselineFile,evaluationFile]=process.argv.slice(2);
const baseline=JSON.parse(fs.readFileSync(baselineFile));
const evaluation=JSON.parse(fs.readFileSync(evaluationFile));
const digest='sha256:'+crypto.createHash('sha256').update(fs.readFileSync(evaluationFile)).digest('hex');
if(baseline.status!=='complete'||baseline.evaluation_json_sha256!==digest||evaluation.verdict!=='Pass')process.exit(1);
NODE

run_archive_case() {
    local directory=$1 instruction_mode=$2 validate_mode=$3
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(
        cd "$directory" &&
        ARCHIVE_GATE_INSTRUCTIONS="$instruction_mode" \
        ARCHIVE_GATE_VALIDATE="$validate_mode" \
        scripts/change_archive.sh "$change" 2>&1
    )
    RUN_STATUS=$?
    set -e
}

assert_rejected_without_global_poison() {
    local directory=$1 before_file=$2 before_sha=$3 before_active=$4 before_phase=$5 before_calls=$6 label=$7
    local after_calls
    assert_status 6
    after_calls=$(grep -c '^archive-invoked$' "$runtime_log" || true)
    [[ "$after_calls" -eq "$before_calls" ]] || fail "$label 被拒绝后仍调用了 archive CLI"
    cmp -s -- "$before_file" "$directory/ai_snapshot.json" || fail "$label 改写了根 snapshot 字节"
    [[ "$before_sha" == "$(sha256sum -- "$directory/ai_snapshot.json" | awk '{print $1}')" ]] || \
        fail "$label 改写了根 snapshot hash"
    node - "$directory/ai_snapshot.json" "$before_active" "$before_phase" "$label" <<'NODE' || \
        fail "$label 改写 active/phase 或遗留 archive_failure"
const fs=require('fs');
const [file,active,phase,label]=process.argv.slice(2),snapshot=JSON.parse(fs.readFileSync(file));
if(snapshot.active_change!==active||snapshot.phase!==phase||Object.hasOwn(snapshot,'archive_failure')){
  throw new Error(label+' poisoned the root workflow state');
}
NODE
    assert_path_exists "$directory/openspec/changes/$change"
    assert_path_absent "$directory/openspec/changes/archive/$(date -u +%Y-%m-%d)-$change"

    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$directory" && scripts/snapshot_update.sh \
        --current-step "repair rejected archive gate: $label" \
        --next-step 'rerun independent checks and archive gates' 2>&1)
    RUN_STATUS=$?
    set -e
    assert_status 0
}

note '独立负向矩阵：每个 pre-CLI gate 拒绝都保持根状态可继续返工'
for gate in incomplete zero no-evaluation stale-pass no-real-command future-tdd strict-fail; do
    case_repo="$tmp/gate-$gate"
    cp -a -- "$repo" "$case_repo"
    instruction_mode=all_done
    validate_mode=pass
    expected_message=
    case "$gate" in
        incomplete)
            instruction_mode=incomplete
            expected_message='tasks incomplete or instructions JSON contract mismatch'
            ;;
        zero)
            instruction_mode=zero
            expected_message='tasks incomplete or instructions JSON contract mismatch'
            ;;
        no-evaluation)
            rm -f -- "$case_repo/openspec/changes/$change/harness/evaluation-baseline.json" \
                "$case_repo/openspec/changes/$change/harness/evaluation.json"
            expected_message='complete Evaluation missing'
            ;;
        stale-pass)
            printf '# stale Pass probe\n' >> "$case_repo/src/widget.sh"
            expected_message='footprint stale or blocked'
            ;;
        no-real-command)
            node - "$case_repo/openspec/changes/$change/harness/evaluation-baseline.json" \
                "$case_repo/openspec/changes/$change/harness/evaluation.json" <<'NODE'
const fs=require('fs'),crypto=require('crypto');
const [baselineFile,evaluationFile]=process.argv.slice(2);
const evaluation=JSON.parse(fs.readFileSync(evaluationFile));
for(const command of evaluation.commands)command.kind='static';
fs.writeFileSync(evaluationFile,JSON.stringify(evaluation,null,2)+'\n');
const baseline=JSON.parse(fs.readFileSync(baselineFile));
baseline.evaluation_json_sha256='sha256:'+crypto.createHash('sha256').update(fs.readFileSync(evaluationFile)).digest('hex');
fs.writeFileSync(baselineFile,JSON.stringify(baseline,null,2)+'\n');
NODE
            expected_message='complete Evaluation recheck failed'
            ;;
        future-tdd)
            future_harness="$case_repo/openspec/changes/$change/harness"
            future_eval_id=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" \
                "$future_harness/evaluation-baseline.json")
            cp -p -- "$future_harness/verification.json" "$tmp/future-tdd-verification.saved"
            cp -p -- "$future_harness/evaluation-baseline.json" "$tmp/future-tdd-baseline.saved"
            cp -p -- "$future_harness/evaluations/$future_eval_id.json" "$tmp/future-tdd-envelope.saved"
            node - "$future_harness/verification.json" "$future_harness/evaluation-baseline.json" \
                "$future_harness/evaluations/$future_eval_id.json" <<'NODE'
const fs=require('fs'),crypto=require('crypto');
const [verificationFile,baselineFile,envelopeFile]=process.argv.slice(2);
const verification=JSON.parse(fs.readFileSync(verificationFile));
const task=verification.tasks.at(-1),command=task?.commands.at(-1);
if (!command || command.phase!=='REGRESSION') throw new Error('fixture lacks a final REGRESSION command');
const future=new Date(Date.now()+360000).toISOString();
command.started_at=future;
command.finished_at=future;
fs.writeFileSync(verificationFile,JSON.stringify(verification,null,2)+'\n');
const baseline=JSON.parse(fs.readFileSync(baselineFile));
baseline.verification_json_sha256='sha256:'+crypto.createHash('sha256').update(fs.readFileSync(verificationFile)).digest('hex');
fs.writeFileSync(baselineFile,JSON.stringify(baseline,null,2)+'\n');
const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(',')}]`:
  value&&typeof value==='object'?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`:
  JSON.stringify(value);
const envelope=JSON.parse(fs.readFileSync(envelopeFile));
envelope.baseline=baseline;
envelope.baseline_sha256='sha256:'+crypto.createHash('sha256').update(canonical(baseline)).digest('hex');
fs.writeFileSync(envelopeFile,JSON.stringify(envelope,null,2)+'\n');
NODE
            expected_message='complete Evaluation recheck failed'
            ;;
        strict-fail)
            validate_mode=fail
            expected_message='strict validation JSON has errors'
            ;;
    esac

    before_file="$tmp/$gate-root-before.json"
    cp -p -- "$case_repo/ai_snapshot.json" "$before_file"
    before_sha=$(sha256sum -- "$case_repo/ai_snapshot.json" | awk '{print $1}')
    before_active=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).active_change" "$case_repo/ai_snapshot.json")
    before_phase=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).phase" "$case_repo/ai_snapshot.json")
    before_calls=$(grep -c '^archive-invoked$' "$runtime_log" || true)

    if [[ "$gate" == future-tdd ]]; then
        RUN_OUTPUT=
        RUN_STATUS=0
        set +e
        RUN_OUTPUT=$(cd "$case_repo" && node -e \
            "require('./scripts/manifest_policy.js').verifyTddEvidence(process.cwd(),'$change',{requireDone:true})" 2>&1)
        RUN_STATUS=$?
        set -e
        [[ "$RUN_STATUS" -ne 0 ]] || fail 'direct TDD verification accepted a final command beyond five minutes'
        assert_contains "$RUN_OUTPUT" 'future evidence timestamp'

        RUN_OUTPUT=
        RUN_STATUS=0
        set +e
        RUN_OUTPUT=$(cd "$case_repo" && scripts/evaluator_check.sh --recheck "$change" 2>&1)
        RUN_STATUS=$?
        set -e
        assert_status 6
        assert_contains "$RUN_OUTPUT" 'future evidence timestamp'
    fi

    run_archive_case "$case_repo" "$instruction_mode" "$validate_mode"
    assert_contains "$RUN_OUTPUT" "$expected_message"
    if [[ "$gate" == future-tdd ]]; then
        cp -p -- "$tmp/future-tdd-verification.saved" "$case_repo/openspec/changes/$change/harness/verification.json"
        cp -p -- "$tmp/future-tdd-baseline.saved" "$case_repo/openspec/changes/$change/harness/evaluation-baseline.json"
        cp -p -- "$tmp/future-tdd-envelope.saved" \
            "$case_repo/openspec/changes/$change/harness/evaluations/$future_eval_id.json"
    fi
    assert_rejected_without_global_poison \
        "$case_repo" "$before_file" "$before_sha" "$before_active" "$before_phase" "$before_calls" "$gate"
done

[[ "$(grep -c '^archive-invoked$' "$runtime_log" || true)" -eq 0 ]] || \
    fail '归档负向矩阵触发了 OpenSpec archive CLI'
note 'incomplete/0 task/no Evaluation/stale Pass/no real command/future TDD/strict fail 均被只读门禁拒绝且可继续返工'
