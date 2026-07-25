#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/integration surface report project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
ln -s "$STUB_BIN/npx" "$runtime_bin/npx"
export PATH="$runtime_bin:$REAL_TEST_PATH"

change=integration-report
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)
change_dir="$repo/openspec/changes/$change"
report="$change_dir/harness/integration-surface-report.json"
mkdir -p "$change_dir/specs/widget" "$repo/src" "$repo/tests"

cat > "$change_dir/proposal.md" <<'EOF'
# Change: Route widget refresh through the daemon

Modify the existing service and its production caller as one approved internal surface.
EOF

cat > "$change_dir/specs/widget/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Route widget refresh

The running widget daemon SHALL invoke the modified refresh behavior.

#### Scenario: Refresh is observable

- **WHEN** the daemon runs its refresh cycle
- **THEN** the service and caller expose the approved refreshed state
EOF

cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Implement and connect widget refresh
  - Covers: `specs/widget/spec.md` | `ADDED` | `Route widget refresh` | `Refresh is observable`
  - Verify: `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
# Integration report design

<!-- autoai:tdd-policy:v1 -->
```json
{
  "schema_version": 1,
  "default": "required",
  "exceptions": []
}
```
<!-- /autoai:tdd-policy:v1 -->

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "small",
  "rationale": "Modify two existing production files and exercise one focused behavior command.",
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
      "added_lines": {"expected": 6, "review_at": 12, "hard_limit": 24},
      "touched_files": {"expected": 3, "review_at": 4, "hard_limit": 6},
      "new_files": {"expected": 1, "review_at": 2, "hard_limit": 3}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 4, "hard_limit": 8},
      "touched_files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 2, "hard_limit": 4},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "bytes": {"expected": 0, "review_at": 1024, "hard_limit": 2048}
    }
  },
  "structural_allowances": {
    "public_contracts": [],
    "cmake_targets": [],
    "direct_dependencies": []
  },
  "reuse_decisions": [
    {
      "id": "reuse-existing-readme",
      "path": "README.md",
      "symbol": "Project documentation baseline",
      "decision": "reuse",
      "reason": "The existing project documentation remains the repository-level context and needs no implementation change."
    }
  ],
  "obsolete_items": [],
  "exceptions": []
}
```
<!-- /autoai:implementation-economy:v1 -->

<!-- autoai:integration-completeness:v1 -->
```json
{
  "discovery": {
    "compile_commands_path": null,
    "mode": "reviewed_inventory"
  },
  "schema_version": 1,
  "surfaces": [
    {
      "change_kind": "modified",
      "compatibility": null,
      "consumer_kind": "production_caller",
      "consumer_paths": ["src/widget_daemon.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "widget daemon refresh cycle",
      "evidence_contracts": [
        {
          "argv": ["tests/widget_refresh_test.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "widget-refresh-ok",
          "probe_id": "probe-widget-refresh-current",
          "role": "current"
        }
      ],
      "expected_observation": "The focused command observes both the modified service and its production caller.",
      "id": "surface-widget-refresh",
      "kind": "internal_api",
      "name": "widget refresh service",
      "producer_paths": ["src/widget_service.cpp"],
      "requirement_refs": [
        {
          "operation": "ADDED",
          "requirement": "Route widget refresh",
          "scenarios": ["Refresh is observable"],
          "spec_path": "specs/widget/spec.md"
        }
      ],
      "symbol_identities": null,
      "task_ids": ["1.1"],
      "task_obligations": [
        {
          "evidence_roles": ["current"],
          "task_id": "1.1",
          "verify_kinds": ["behavior"]
        }
      ],
      "verify_kinds": ["behavior"]
    }
  ]
}
```
<!-- /autoai:integration-completeness:v1 -->
EOF

printf 'old-service\n' > "$repo/src/widget_service.cpp"
printf 'old-daemon\n' > "$repo/src/widget_daemon.cpp"
cat > "$repo/tests/widget_refresh_test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ! grep -Fq new-service src/widget_service.cpp || ! grep -Fq new-daemon src/widget_daemon.cpp; then
    echo widget-refresh-mismatch
    exit 7
fi
[[ "${AUTOAI_TEST_SUPPRESS_PROBE_OUTPUT:-0}" != 1 ]] || exit 0
echo widget-refresh-ok
EOF
chmod 755 "$repo/tests/widget_refresh_test.sh"

git -C "$repo" config user.name 'AutoAI Integration Report Test'
git -C "$repo" config user.email 'autoai-integration-report@example.invalid'
git -C "$repo" add -A
git -C "$repo" commit -qm 'approved integration report baseline'

export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
(
    cd "$repo"
    scripts/snapshot_update.sh \
        --freeze-planning-baseline --freeze-implementation-base \
        --phase implementing --current-step implementation-base-frozen \
        --next-step implement-widget-refresh >/dev/null
)

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

note 'RED 先证明基线行为失败，再建立最小实现和最终 surface-bound REGRESSION'
run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase red --cycle widget-refresh --kind behavior --expect-exit 7 \
    --path src/widget_service.cpp --path src/widget_daemon.cpp \
    --test-path tests/widget_refresh_test.sh --failure-class assertion \
    --expected-failure 'the baseline service and caller have not implemented the approved refresh behavior' \
    --match-output widget-refresh-mismatch \
    --observed 'the focused behavior command rejected both old production paths' -- \
    tests/widget_refresh_test.sh
assert_status 0

printf 'new-service\n' > "$repo/src/widget_service.cpp"
printf 'new-daemon\n' > "$repo/src/widget_daemon.cpp"
# This extra production path is deliberately not part of the approved surface.
# Its content is non-semantic, but only the independent Evaluator may make that
# disposition after reviewing the complete diff.  The report itself must retain
# the unmatched coarse candidate and must never invoke Clang or assume it harmless.
printf '// reviewed formatting-only production-path change\n' > "$repo/src/unplanned.cpp"

run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase green --cycle widget-refresh --kind behavior \
    --path src/widget_service.cpp --path src/widget_daemon.cpp -- \
    tests/widget_refresh_test.sh
assert_status 0

note '任意成功命令、错误退出契约和缺失可观察 marker 均不能伪造 surface closure'
false_probe_marker="$tmp/false-surface-probe-ran"
evidence_before=$(sha256sum -- "$change_dir/harness/verification.json" | awk '{print $1}')
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-refresh --kind behavior \
    --surface surface-widget-refresh \
    --path src/widget_service.cpp --path src/widget_daemon.cpp -- \
    bash -c 'touch "$1"' _ "$false_probe_marker"
assert_status 6
assert_path_absent "$false_probe_marker"
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-refresh --kind behavior --expect-exit 7 \
    --surface surface-widget-refresh \
    --path src/widget_service.cpp --path src/widget_daemon.cpp -- \
    tests/widget_refresh_test.sh
assert_status 6
run_managed_at "$repo" env AUTOAI_TEST_SUPPRESS_PROBE_OUTPUT=1 scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-refresh --kind behavior \
    --surface surface-widget-refresh \
    --path src/widget_service.cpp --path src/widget_daemon.cpp -- \
    tests/widget_refresh_test.sh
assert_status 1
[[ "$evidence_before" == "$(sha256sum -- "$change_dir/harness/verification.json" | awk '{print $1}')" ]] || \
    fail 'rejected surface probes changed verification evidence'

run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-refresh --kind behavior \
    --surface surface-widget-refresh \
    --path src/widget_service.cpp --path src/widget_daemon.cpp --path src/unplanned.cpp -- \
    tests/widget_refresh_test.sh
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh --complete 1.1
assert_status 0

export STUB_OPENSPEC_INSTRUCTIONS_MODE=success

clang_marker="$tmp/reviewed-mode-invoked-clang"
cat > "$runtime_bin/clang++" <<'EOF'
#!/usr/bin/env bash
: > "${AUTOAI_CLANG_MARKER:?}"
echo 'reviewed_inventory unexpectedly invoked clang++' >&2
exit 99
EOF
chmod 755 "$runtime_bin/clang++"
export AUTOAI_CLANG_MARKER="$clang_marker"

run_surface_json() {
    local mode=$1
    local stdout_file="$tmp/surface-${mode#--}.stdout"
    local stderr_file="$tmp/surface-${mode#--}.stderr"
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    (
        cd "$repo"
        scripts/integration_surface_check.sh "$change" "$mode" --json
    ) >"$stdout_file" 2>"$stderr_file"
    RUN_STATUS=$?
    set -e
    RUN_OUTPUT=$(cat "$stderr_file")
}

note 'reviewed refresh 生成 canonical review_required inventory，并保留未映射粗粒度候选'
run_surface_json --refresh
assert_status 0
assert_path_exists "$report"
assert_path_absent "$clang_marker"
assert_files_equal "$report" "$tmp/surface-refresh.stdout"
node - "$report" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
if (value.schema_version !== 1 || value.change_name !== change || value.discovery_mode !== 'reviewed_inventory') {
  throw new Error('reviewed report identity mismatch');
}
if (value.compile_commands_sha256 !== null || value.ast_tool_identity !== null || value.ast_candidates.length !== 0) {
  throw new Error('reviewed mode acquired an implicit AST dependency');
}
if (value.status !== 'review_required') {
  throw new Error(`unmatched reviewed candidate should require independent review, got ${value.status}`);
}
if (!value.changed_production_paths.includes('src/widget_service.cpp') ||
    !value.changed_production_paths.includes('src/widget_daemon.cpp') ||
    !value.changed_production_paths.includes('src/unplanned.cpp')) {
  throw new Error('complete production path inventory is missing');
}
const unplanned = value.path_candidates.find(x => x.path === 'src/unplanned.cpp');
if (!unplanned || !value.unmatched_candidates.some(x => x.candidate_id === unplanned.candidate_id && x.source === 'path')) {
  throw new Error('unplanned production path was not retained as an unmatched candidate');
}
const binding = value.surface_candidate_bindings.find(x => x.surface_id === 'surface-widget-refresh');
if (!binding) throw new Error('approved surface has no candidate binding');
const roles = new Set(binding.candidate_bindings.map(x => x.role));
if (!roles.has('producer') || !roles.has('consumer')) {
  throw new Error('surface did not bind both producer and production consumer candidates');
}
NODE

note '未变化的 review_required --check 逐字返回冻结 inventory，且仍不探测 clang'
run_surface_json --check
assert_status 0
assert_files_equal "$report" "$tmp/surface-check.stdout"
assert_path_absent "$clang_marker"

note '源码变化立即使旧 report 陈旧，check fail closed 且不得覆盖现场'
report_before=$(sha256sum -- "$report" | awk '{print $1}')
cp -p "$repo/src/widget_daemon.cpp" "$tmp/widget_daemon.saved"
printf 'post-report-drift\n' >> "$repo/src/widget_daemon.cpp"
run_surface_json --check
assert_status 6
node - "$tmp/surface-check.stdout" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const keys = Object.keys(value).sort().join(',');
if (keys !== 'change_name,reason,schema_version,status' || value.change_name !== change ||
    !['blocked', 'invalid'].includes(value.status) || !value.reason) {
  throw new Error('stale report did not return the closed diagnostic union');
}
NODE
[[ "$report_before" == "$(sha256sum -- "$report" | awk '{print $1}')" ]] || \
    fail 'stale check rewrote the last valid surface report'
assert_path_absent "$clang_marker"

mv "$tmp/widget_daemon.saved" "$repo/src/widget_daemon.cpp"
run_surface_json --check
assert_status 0
assert_files_equal "$report" "$tmp/surface-check.stdout"

note '陈旧 surface report 在 Evaluator begin 前拒绝，不得建立 baseline'
stale_eval_repo="$tmp/stale evaluator report project"
cp -a -- "$repo" "$stale_eval_repo"
printf 'evaluator-stale-probe\n' >> "$stale_eval_repo/src/widget_daemon.cpp"
run_managed_at "$stale_eval_repo" scripts/evaluator_check.sh --begin "$change"
assert_status 6
assert_path_absent "$stale_eval_repo/openspec/changes/$change/harness/evaluation-baseline.json"

note '保留 review_required 候选并刷新 task 证据，交由独立 Evaluator 做逐候选处置'
run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle widget-refresh --kind behavior \
    --surface surface-widget-refresh \
    --path src/widget_service.cpp --path src/widget_daemon.cpp -- \
    tests/widget_refresh_test.sh
assert_status 0
run_surface_json --refresh
assert_status 0
node - "$report" <<'NODE'
const fs = require('fs'), value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (value.status !== 'review_required' || value.unmatched_candidates.length !== 1) {
  throw new Error('reviewed inventory did not retain its one independently reviewable candidate');
}
NODE
run_managed_at "$repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
baseline="$change_dir/harness/evaluation-baseline.json"
ledger="$change_dir/harness/evaluation-command-ledger.json"
node - "$baseline" "$ledger" "$report" <<'NODE'
const fs = require('fs'), crypto = require('crypto');
const [baselineFile, ledgerFile, reportFile] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const reportSha = 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(reportFile)).digest('hex');
if (baseline.schema_version !== 3 || baseline.status !== 'in_progress' ||
    baseline.integration_planning_block_sha256 !== report.planning_block_sha256 ||
    baseline.integration_surface_report_sha256 !== reportSha ||
    !/^sha256:[0-9a-f]{64}$/.test(baseline.integration_discovery_identity_sha256)) {
  throw new Error('Evaluation v3 baseline did not bind the surface report');
}
if (ledger.schema_version !== 2 || ledger.evaluation_id !== baseline.evaluation_id ||
    ledger.change_name !== baseline.change_name || ledger.commands.length !== 0) {
  throw new Error('Evaluation v3 command ledger family mismatch');
}
NODE

note '未完成的 integrated Evaluation 不能进入 OpenSpec archive CLI'
archive_calls_before=$(grep -c 'openspec archive ' "$STUB_CALL_LOG" || true)
run_managed_at "$repo" scripts/change_archive.sh "$change"
assert_status 6
archive_calls_after=$(grep -c 'openspec archive ' "$STUB_CALL_LOG" || true)
[[ "$archive_calls_before" -eq "$archive_calls_after" ]] || \
    fail 'in-progress integrated Evaluation still invoked the archive CLI'
assert_path_exists "$change_dir"

note '补全独立 surface-bound 命令和逐 candidate/surface 评估，完成唯一 Evaluation v3 verdict'
ledger_before=$(sha256sum -- "$ledger" | awk '{print $1}')
false_eval_marker="$tmp/false-evaluator-probe-ran"
run_managed_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior --surface surface-widget-refresh -- \
    bash -c 'touch "$1"' _ "$false_eval_marker"
assert_status 6
assert_path_absent "$false_eval_marker"
run_managed_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior --expect-exit 7 --surface surface-widget-refresh -- \
    tests/widget_refresh_test.sh
assert_status 6
run_managed_at "$repo" env AUTOAI_TEST_SUPPRESS_PROBE_OUTPUT=1 scripts/evaluator_check.sh --run \
    --kind behavior --surface surface-widget-refresh -- \
    tests/widget_refresh_test.sh
assert_status 1
[[ "$ledger_before" == "$(sha256sum -- "$ledger" | awk '{print $1}')" ]] || \
    fail 'rejected Evaluator surface probes changed the command ledger'
run_managed_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior --surface surface-widget-refresh \
    --expected 'The production daemon invokes the approved widget refresh surface.' \
    --observed 'The focused independent command observed both the service and its production caller.' -- \
    tests/widget_refresh_test.sh
assert_status 0

node - "$baseline" "$change_dir/harness/change-footprint.json" "$ledger" "$report" \
    "$change_dir/harness/evaluation.json" "$change" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, reportFile, outputFile, change] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const footprint = JSON.parse(fs.readFileSync(footprintFile, 'utf8'));
const ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (ledger.schema_version !== 2 || ledger.commands.length !== 1 || ledger.commands[0].result !== 'Pass' ||
    JSON.stringify(ledger.commands[0].surface_probe_bindings) !==
      '[{"surface_id":"surface-widget-refresh","role":"current","probe_id":"probe-widget-refresh-current"}]') {
  throw new Error('integrated Evaluation fixture lacks its managed passing command');
}
const commands = [...ledger.commands], commandIds = commands.map(command => command.id);
const evidenceFinished = Math.max(Date.parse(baseline.started_at), ...commands.map(command => Date.parse(command.finished_at)));
const reviewedAt = new Date(evidenceFinished).toISOString();
const evaluatedAt = new Date(Math.max(Date.now(), evidenceFinished)).toISOString();
const requirementRef = {
  spec_path: 'specs/widget/spec.md', operation: 'ADDED',
  requirement: 'Route widget refresh', scenarios: ['Refresh is observable']
};
const reviewStage = (name, startedAt, completedAt, dimensions) => ({
  name, started_at: startedAt, completed_at: completedAt, status: 'Pass',
  requirement_refs: [requirementRef], task_ids: ['1.1'],
  reviewed_paths: baseline.review_input.review_paths, dimensions,
  evidence_command_ids: commandIds, finding_ids: [], blocking_untested_ids: [], not_run_reason: null
});
const surfaceId = 'surface-widget-refresh';
const reportBinding = report.surface_candidate_bindings.find(binding => binding.surface_id === surfaceId);
if (!reportBinding) throw new Error('surface report binding missing');
const typedByCandidate = new Map;
for (const binding of reportBinding.candidate_bindings) {
  const roles = typedByCandidate.get(binding.candidate_id) || [];
  roles.push(binding.role);
  typedByCandidate.set(binding.candidate_id, roles);
}
const allCandidates = [...report.path_candidates, ...report.structural_candidates, ...report.ast_candidates];
const candidateAssessments = allCandidates.map(candidate => {
  const roles = [...new Set(typedByCandidate.get(candidate.candidate_id) || [])]
    .sort((a, b) => ['producer', 'consumer'].indexOf(a) - ['producer', 'consumer'].indexOf(b));
  const logicalPaths = [...new Set([candidate.old_path, candidate.path].filter(Boolean))].sort();
  if (!roles.length) {
    if (candidate.source !== 'path' || candidate.path !== 'src/unplanned.cpp') {
      throw new Error('unexpected unbound reviewed candidate');
    }
    return {
      candidate_id: candidate.candidate_id,
      source: candidate.source,
      disposition: 'non_semantic_change',
      surface_ids: [],
      surface_bindings: [],
      reason: 'Independent diff review confirmed that the file contains only a comment and introduces no product surface.',
      producer_paths: logicalPaths,
      implementation_consumer: null,
      evidence_paths: logicalPaths,
      evidence_command_ids: [],
      orphan_ids: []
    };
  }
  const producerPaths = roles.includes('producer')
    ? logicalPaths.filter(path => reportBinding.producer_paths.includes(path)) : [];
  return {
    candidate_id: candidate.candidate_id,
    source: candidate.source,
    disposition: 'mapped',
    surface_ids: [surfaceId],
    surface_bindings: [{
      surface_id: surfaceId,
      candidate_roles: roles,
      consumer_kind: 'production_caller',
      consumer_paths: reportBinding.consumer_paths
    }],
    reason: 'The complete diff candidate is bound to the approved refresh surface.',
    producer_paths: producerPaths,
    implementation_consumer: null,
    evidence_paths: logicalPaths,
    evidence_command_ids: commandIds,
    orphan_ids: []
  };
}).sort((a, b) => a.candidate_id.localeCompare(b.candidate_id));
const evaluation = {
  schema_version: 3,
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
    stages: [
      reviewStage('specification_compliance', baseline.started_at, reviewedAt,
        ['requirements', 'scenarios', 'scope', 'contracts', 'traceability']),
      reviewStage('code_quality', reviewedAt, evaluatedAt,
        ['correctness', 'safety', 'regression_risk', 'reuse', 'complexity', 'test_quality', 'repository_impact'])
    ],
    findings: []
  },
  implementation_economy: {
    footprint_status: footprint.status,
    drift_explanation: null,
    classification_assessment: {
      result: 'Pass',
      reason: 'Both changed product paths match the approved production classification.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets', applicability: 'applicable', result: 'Pass',
          reason: 'The service and its running daemon caller pass the focused command.',
          evidence_paths: report.changed_production_paths, evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'not_applicable', result: null,
          reason: 'This internal fixture has no install surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No install rule exists in the approved project baseline.'
        },
        {
          surface: 'package', applicability: 'not_applicable', result: null,
          reason: 'This internal fixture has no package surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No package configuration exists in the approved project baseline.'
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'This internal fixture has no CI surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI configuration exists in the approved project baseline.'
        }
      ]
    },
    reuse_assessments: [{
      id: 'reuse-existing-readme',
      result: 'Pass',
      reason: 'The unchanged repository documentation remains reusable without expanding the implementation diff.',
      evidence_paths: ['README.md']
    }],
    structural_assessments: [],
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: 'criterion-widget-refresh',
    description: 'The running daemon invokes the approved refresh behavior.',
    requirement_refs: [requirementRef], task_ids: ['1.1'], status: 'Pass',
    evidence_command_ids: commandIds, blocking_untested_ids: []
  }],
  commands,
  blocking_untested: [],
  residual_risks: [],
  integration_completeness: {
    planning_block_sha256: baseline.integration_planning_block_sha256,
    report_sha256: baseline.integration_surface_report_sha256,
    discovery_identity_sha256: baseline.integration_discovery_identity_sha256,
    inventory_assessment: {
      result: 'Pass',
      reason: 'Every changed production path was independently reviewed.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    candidate_assessments: candidateAssessments,
    surface_assessments: [{
      surface_id: surfaceId,
      result: 'Pass',
      reason: 'The independent command observes the producer through its production caller.',
      consumer_paths: reportBinding.consumer_paths,
      old_consumer_paths: reportBinding.old_consumer_paths,
      replacement_consumer_paths: reportBinding.replacement_consumer_paths,
      kind_evidence: [{kind: 'behavior', evidence_command_ids: commandIds}],
      role_evidence: [{role: 'current', evidence_command_ids: commandIds}],
      evidence_command_ids: commandIds,
      blocking_untested_ids: [],
      orphan_ids: []
    }],
    orphan_surfaces: [],
    result: 'Pass'
  }
};
fs.writeFileSync(outputFile, JSON.stringify(evaluation, null, 2) + '\n');
NODE

run_managed_at "$repo" scripts/evaluator_check.sh --finish "$change"
assert_status 0
node - "$baseline" "$change_dir/harness/evaluation.json" <<'NODE'
const fs = require('fs'), crypto = require('crypto');
const [baselineFile, evaluationFile] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
const digest = 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(evaluationFile)).digest('hex');
if (baseline.schema_version !== 3 || baseline.status !== 'complete' ||
    baseline.evaluation_json_sha256 !== digest || evaluation.schema_version !== 3 ||
    evaluation.verdict !== 'Pass' || evaluation.integration_completeness.result !== 'Pass') {
  throw new Error('integrated Evaluation was not sealed as a digest-bound Pass');
}
NODE

note 'archive 已移动但返回契约损坏时保留现场，并对归档 v3 证据做深恢复校验'
run_managed_at "$repo" env STUB_OPENSPEC_ARCHIVE_MODE=moved-wrong-json scripts/change_archive.sh "$change"
assert_status 6
archived_as="$(date -u +%Y-%m-%d)-$change"
archived_dir="$repo/openspec/changes/archive/$archived_as"
assert_path_absent "$change_dir"
assert_path_exists "$archived_dir/harness/integration-surface-report.json"
assert_path_exists "$archived_dir/harness/evaluation.json"
assert_path_exists "$archived_dir/harness/evaluations"
run_managed_at "$repo" scripts/archive_recover.sh --status
assert_status 0
printf '%s\n' "$RUN_OUTPUT" > "$tmp/archive-status-valid.json"
node - "$tmp/archive-status-valid.json" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2), value = JSON.parse(fs.readFileSync(file));
if (!value.unresolved || value.change_name !== change || value.current_state !== 'archived' ||
    value.eligible !== true || value.archive_candidates.length !== 1) {
  throw new Error('valid archived Integration v3 evidence was not recovery-eligible');
}
NODE

evaluation_id=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" "$archived_dir/harness/evaluation.json")
envelope="$archived_dir/harness/evaluations/$evaluation_id.json"
transaction="$repo/.ai-harness/archive-transaction.json"
cp -p -- "$archived_dir/harness/verification.json" "$tmp/verification.valid.json"
cp -p -- "$archived_dir/harness/evaluation-baseline.json" "$tmp/baseline.valid.json"
cp -p -- "$archived_dir/harness/evaluation.json" "$tmp/evaluation.valid.json"
cp -p -- "$archived_dir/harness/evaluation-command-ledger.json" "$tmp/ledger.valid.json"
cp -p -- "$archived_dir/harness/integration-surface-report.json" "$tmp/report.valid.json"
cp -p -- "$envelope" "$tmp/envelope.valid.json"
cp -p -- "$transaction" "$tmp/transaction.valid.json"

self_consistent_archive_tamper() {
    local mode=$1
    node - "$mode" "$archived_dir" "$envelope" "$transaction" <<'NODE'
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const [mode, changeDir, envelopeFile, transactionFile] = process.argv.slice(2);
const harness = path.join(changeDir, 'harness');
const files = {
  verification: path.join(harness, 'verification.json'),
  baseline: path.join(harness, 'evaluation-baseline.json'),
  evaluation: path.join(harness, 'evaluation.json'),
  ledger: path.join(harness, 'evaluation-command-ledger.json'),
  footprint: path.join(harness, 'change-footprint.json'),
  report: path.join(harness, 'integration-surface-report.json')
};
const canonical = value => Array.isArray(value)
  ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object'
    ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const bytes = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
const digestBytes = value => 'sha256:' + crypto.createHash('sha256').update(value).digest('hex');
const fileDigest = file => digestBytes(fs.readFileSync(file));
const payloadDigest = value => digestBytes(Buffer.from(canonical(value)));
const write = (file, value) => fs.writeFileSync(file, bytes(value));
const baseline = JSON.parse(fs.readFileSync(files.baseline));
const evaluation = JSON.parse(fs.readFileSync(files.evaluation));
const verification = JSON.parse(fs.readFileSync(files.verification));
const ledger = JSON.parse(fs.readFileSync(files.ledger));
const report = JSON.parse(fs.readFileSync(files.report));
if (mode === 'candidate-misbinding') {
  const candidate = report.path_candidates.find(item => item.path === 'src/unplanned.cpp');
  const binding = report.surface_candidate_bindings.find(item => item.surface_id === 'surface-widget-refresh');
  const assessment = evaluation.integration_completeness.candidate_assessments.find(item => item.candidate_id === candidate?.candidate_id);
  if (!candidate || !binding || !assessment || assessment.disposition !== 'non_semantic_change') {
    throw new Error('candidate-misbinding fixture source is incomplete');
  }
  binding.candidate_bindings.push({candidate_id: candidate.candidate_id, role: 'producer', tree_side: 'current'});
  binding.candidate_bindings.sort((a, b) =>
    (a.candidate_id + a.role + a.tree_side).localeCompare(b.candidate_id + b.role + b.tree_side));
  report.unmatched_candidates = report.unmatched_candidates.filter(item => item.candidate_id !== candidate.candidate_id);
  report.status = 'complete';
  Object.assign(assessment, {
    disposition: 'mapped',
    surface_ids: ['surface-widget-refresh'],
    surface_bindings: [{
      surface_id: 'surface-widget-refresh',
      candidate_roles: ['producer'],
      consumer_kind: 'production_caller',
      consumer_paths: binding.consumer_paths
    }],
    reason: 'Self-consistent tamper falsely binds an unrelated changed path to the approved surface.',
    producer_paths: [],
    implementation_consumer: null,
    evidence_paths: ['src/unplanned.cpp'],
    evidence_command_ids: evaluation.commands.map(command => command.id),
    orphan_ids: []
  });
  write(files.report, report);
  const reportSha = fileDigest(files.report);
  baseline.integration_surface_report_sha256 = reportSha;
  evaluation.integration_completeness.report_sha256 = reportSha;
} else if (mode === 'criterion-evidence') {
  evaluation.criteria[0].evidence_command_ids = [];
} else if (mode === 'verification-changed-path') {
  const before = verification.tasks[0].changed_paths.length;
  verification.tasks[0].changed_paths = verification.tasks[0].changed_paths.filter(item => item !== 'src/unplanned.cpp');
  if (verification.tasks[0].changed_paths.length === before) {
    throw new Error('verification changed-path fixture source is incomplete');
  }
} else if (mode === 'command-content') {
  evaluation.commands[0].command = '';
  ledger.commands[0].command = '';
} else if (mode === 'review-dimensions') {
  evaluation.change_review.stages[0].dimensions = evaluation.change_review.stages[0].dimensions.slice(1);
} else if (mode === 'economy-paths') {
  evaluation.implementation_economy.classification_assessment.evidence_paths =
    evaluation.implementation_economy.classification_assessment.evidence_paths.slice(0, -1);
} else if (mode === 'prior-finding-continuity') {
  const previousId = 'eval-20000101T000000Z-aaaaaa';
  const previousStarted = '2000-01-01T00:00:00.000Z';
  const previousCompleted = '2000-01-01T00:00:02.000Z';
  const previousEvaluation = structuredClone(evaluation);
  previousEvaluation.evaluation_id = previousId;
  previousEvaluation.evaluation_started_at = previousStarted;
  previousEvaluation.evaluated_at = '2000-01-01T00:00:01.000Z';
  previousEvaluation.change_review.findings.push({
    id: 'finding-prior-open',
    stage: 'specification_compliance',
    category: 'specification',
    severity: 'Critical',
    status: 'Open',
    summary: 'A prior unresolved finding must not disappear from retained Evaluation history.',
    requirement_refs: previousEvaluation.criteria[0].requirement_refs,
    task_ids: previousEvaluation.criteria[0].task_ids,
    evidence_paths: previousEvaluation.review_input.review_paths.slice(0, 1),
    evidence_command_ids: previousEvaluation.commands.slice(0, 1).map(command => command.id),
    return_to: 'Planner',
    resolution: null,
    tracking: null
  });
  const previousBaseline = structuredClone(baseline);
  previousBaseline.evaluation_id = previousId;
  previousBaseline.started_at = previousStarted;
  previousBaseline.completed_at = previousCompleted;
  previousBaseline.evaluation_json_sha256 = digestBytes(bytes(previousEvaluation));
  const previousEnvelope = {
    envelope_schema_version: 1,
    evaluation_id: previousId,
    change_name: evaluation.change_name,
    terminal_status: 'complete',
    source_schema_version: 3,
    sealed_at: previousCompleted,
    baseline_sha256: payloadDigest(previousBaseline),
    evaluation_sha256: payloadDigest(previousEvaluation),
    baseline: previousBaseline,
    evaluation: previousEvaluation
  };
  write(path.join(harness, 'evaluations', previousId + '.json'), previousEnvelope);
} else {
  throw new Error('unknown self-consistent tamper mode');
}
write(files.verification, verification);
write(files.ledger, ledger);
write(files.evaluation, evaluation);
baseline.verification_json_sha256 = fileDigest(files.verification);
baseline.evaluation_json_sha256 = fileDigest(files.evaluation);
write(files.baseline, baseline);
const envelope = JSON.parse(fs.readFileSync(envelopeFile));
envelope.baseline = baseline;
envelope.evaluation = evaluation;
envelope.baseline_sha256 = payloadDigest(baseline);
envelope.evaluation_sha256 = payloadDigest(evaluation);
write(envelopeFile, envelope);

const footprint = JSON.parse(fs.readFileSync(files.footprint));
const transaction = JSON.parse(fs.readFileSync(transactionFile));
const counts = {};
for (const group of ['production', 'tests', 'project_support', 'generated']) {
  const value = footprint[group];
  if (value && typeof value === 'object') {
    counts[group] = Object.fromEntries(Object.entries(value).filter(([, number]) => Number.isFinite(number)));
  }
}
const summary = {
  fingerprints: transaction.fingerprints,
  budget_block_sha256: footprint.budget_block_sha256,
  verification_json_sha256: fileDigest(files.verification),
  change_footprint_json_sha256: fileDigest(files.footprint),
  evaluation_baseline_json_sha256: fileDigest(files.baseline),
  evaluation_json_sha256: fileDigest(files.evaluation),
  integration_surface_report_sha256: fileDigest(files.report),
  footprint: {status: footprint.status, counts},
  evaluation: {
    evaluation_id: evaluation.evaluation_id,
    verdict: evaluation.verdict,
    evaluated_at: evaluation.evaluated_at,
    baseline_status: baseline.status
  }
};
transaction.evidence_sha256 = digestBytes(bytes(summary));
write(transactionFile, transaction);
NODE
}

restore_archive_evidence() {
    cp -p -- "$tmp/verification.valid.json" "$archived_dir/harness/verification.json"
    cp -p -- "$tmp/baseline.valid.json" "$archived_dir/harness/evaluation-baseline.json"
    cp -p -- "$tmp/evaluation.valid.json" "$archived_dir/harness/evaluation.json"
    cp -p -- "$tmp/ledger.valid.json" "$archived_dir/harness/evaluation-command-ledger.json"
    cp -p -- "$tmp/report.valid.json" "$archived_dir/harness/integration-surface-report.json"
    cp -p -- "$tmp/envelope.valid.json" "$envelope"
    cp -p -- "$tmp/transaction.valid.json" "$transaction"
    rm -f -- "$archived_dir/harness/evaluations/eval-20000101T000000Z-aaaaaa.json"
}

note '自洽错绑 candidate 并重封所有摘要、envelope 与 transaction 后仍必须拒绝'
self_consistent_archive_tamper candidate-misbinding
run_managed_at "$repo" scripts/archive_recover.sh --status
assert_status 0
printf '%s\n' "$RUN_OUTPUT" > "$tmp/archive-status-candidate-misbound.json"
node - "$tmp/archive-status-candidate-misbound.json" <<'NODE'
const fs = require('fs'), value = JSON.parse(fs.readFileSync(process.argv[2]));
if (value.eligible !== false ||
    !value.issues.some(issue => issue.includes('missing complete digest-bound retained evidence'))) {
  throw new Error('self-consistent candidate misbinding remained recovery-eligible');
}
NODE
restore_archive_evidence

note '移除 criterion 的独立命令并重封所有摘要后仍必须拒绝'
self_consistent_archive_tamper criterion-evidence
run_managed_at "$repo" scripts/archive_recover.sh --status
assert_status 0
printf '%s\n' "$RUN_OUTPUT" > "$tmp/archive-status-criterion-tampered.json"
node - "$tmp/archive-status-criterion-tampered.json" <<'NODE'
const fs = require('fs'), value = JSON.parse(fs.readFileSync(process.argv[2]));
if (value.eligible !== false ||
    !value.issues.some(issue => issue.includes('missing complete digest-bound retained evidence'))) {
  throw new Error('self-consistent criterion evidence tamper remained recovery-eligible');
}
NODE
restore_archive_evidence

assert_deep_archive_tamper_rejected() {
    local mode=$1 description=$2
    local status_file="$tmp/archive-status-${mode}.json"
    note "$description"
    self_consistent_archive_tamper "$mode"
    run_managed_at "$repo" scripts/archive_recover.sh --status
    assert_status 0
    printf '%s\n' "$RUN_OUTPUT" > "$status_file"
    node - "$status_file" "$mode" <<'NODE'
const fs = require('fs');
const [file, mode] = process.argv.slice(2), value = JSON.parse(fs.readFileSync(file));
if (value.eligible !== false ||
    !value.issues.some(issue => issue.includes('missing complete digest-bound retained evidence'))) {
  throw new Error('self-consistent ' + mode + ' tamper remained recovery-eligible');
}
NODE
    restore_archive_evidence
}

assert_deep_archive_tamper_rejected verification-changed-path \
  '从 verification 隐去真实实现路径并重封所有摘要后仍必须拒绝'
assert_deep_archive_tamper_rejected command-content \
  '清空独立命令语义并同步 ledger、envelope 与 transaction 后仍必须拒绝'
assert_deep_archive_tamper_rejected review-dimensions \
  '削减规格审查维度并重封所有摘要后仍必须拒绝'
assert_deep_archive_tamper_rejected economy-paths \
  '削减 Implementation Economy 分类覆盖并重封所有摘要后仍必须拒绝'
assert_deep_archive_tamper_rejected prior-finding-continuity \
  '历史 Open finding 从当前审查消失时，即使历史 envelope 合法也必须拒绝'

note '自洽改写摘要也不能隐藏缺失的 Generator REGRESSION/surface obligation'
node - "$archived_dir/harness/verification.json" "$archived_dir/harness/evaluation-baseline.json" "$envelope" <<'NODE'
const fs = require('fs'), crypto = require('crypto');
const [verificationFile, baselineFile, envelopeFile] = process.argv.slice(2);
const canonical = value => Array.isArray(value)
  ? '[' + value.map(canonical).join(',') + ']'
  : value && typeof value === 'object'
    ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
    : JSON.stringify(value);
const fileDigest = file => 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const payloadDigest = value => 'sha256:' + crypto.createHash('sha256').update(canonical(value)).digest('hex');
const write = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
const verification = JSON.parse(fs.readFileSync(verificationFile));
verification.tasks[0].commands = verification.tasks[0].commands.filter(command => command.phase !== 'REGRESSION');
write(verificationFile, verification);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
baseline.verification_json_sha256 = fileDigest(verificationFile);
write(baselineFile, baseline);
const envelope = JSON.parse(fs.readFileSync(envelopeFile));
envelope.baseline = baseline;
envelope.baseline_sha256 = payloadDigest(baseline);
write(envelopeFile, envelope);
NODE
run_managed_at "$repo" scripts/archive_recover.sh --status
assert_status 0
printf '%s\n' "$RUN_OUTPUT" > "$tmp/archive-status-tampered.json"
node - "$tmp/archive-status-tampered.json" <<'NODE'
const fs = require('fs'), value = JSON.parse(fs.readFileSync(process.argv[2]));
if (value.eligible !== false ||
    !value.issues.some(issue => issue.includes('missing complete digest-bound retained evidence'))) {
  throw new Error('self-consistent archived verification tamper remained recovery-eligible');
}
NODE
restore_archive_evidence

note '恢复原始证据后可显式 acknowledge，且 reviewed review_required 证据完整保留'
run_managed_at "$repo" scripts/archive_recover.sh --status
assert_status 0
printf '%s\n' "$RUN_OUTPUT" > "$tmp/archive-status-restored.json"
node - "$tmp/archive-status-restored.json" <<'NODE'
const fs = require('fs'), value = JSON.parse(fs.readFileSync(process.argv[2]));
if (value.eligible !== true || value.current_state !== 'archived') {
  throw new Error('restored archive did not regain recovery eligibility');
}
NODE
run_managed_at "$repo" scripts/archive_recover.sh --acknowledge "$change" --reason \
    'Reviewed the retained Integration v3 evidence and accepted the unambiguous archived state.'
assert_status 0
node - "$repo/ai_snapshot.json" "$archived_dir/harness/evaluation.json" "$change" <<'NODE'
const fs = require('fs');
const [rootFile, evaluationFile, change] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(rootFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
if (root.active_change !== null || root.archive_failure !== undefined ||
    root.phase !== 'idle' ||
    root.last_archive_recovery_acknowledgment?.change_name !== change ||
    root.last_archive_recovery_acknowledgment?.recovered_state !== 'archived' ||
    evaluation.verdict !== 'Pass' || evaluation.integration_completeness?.result !== 'Pass') {
  throw new Error('integrated archive recovery acknowledgment mismatch');
}
NODE

note 'reviewed inventory 候选处置、exact probe、transaction 锚定、深恢复语义篡改拒绝和显式 acknowledgment 均通过'
