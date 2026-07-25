#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/documentation only project"
change=documentation-only
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

run_managed_at "$repo" scripts/change_new.sh "$change"
assert_status 0

node - "$repo" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, change] = process.argv.slice(2);
const changeRoot = path.join(root, 'openspec', 'changes', change);
const write = (relative, content, mode = 0o644) => {
  const file = path.join(root, relative);
  fs.mkdirSync(path.dirname(file), {recursive: true});
  fs.writeFileSync(file, content, {mode});
};
const policy = {
  schema_version: 1,
  default: 'required',
  exceptions: [{
    id: 'documentation-proof',
    category: 'documentation_only',
    task_ids: ['1.1'],
    paths: ['docs/operator-guide.md'],
    reason: 'This task changes only a user-facing Markdown guide and creates no executable product surface.',
    alternative_verify_kinds: ['test'],
    exit_condition: 'Remove this exception if the task adds runtime behavior, configuration, build logic, or a product interface.'
  }]
};
const economy = {
  schema_version: 1,
  profile: 'small',
  rationale: 'Add one short operator guide and verify its required instructions with one existing executable check.',
  classification: {
    production: ['src/**'],
    tests: ['tests/**'],
    project_docs: ['docs/**'],
    project_tooling: ['CMakeLists.txt', 'cmake/**'],
    examples: ['examples/**'],
    generated: [],
    vendor: ['vendor/**']
  },
  thresholds: {
    production: {
      added_lines: {expected: 0, review_at: 1, hard_limit: 2},
      touched_files: {expected: 0, review_at: 1, hard_limit: 2},
      new_files: {expected: 0, review_at: 1, hard_limit: 2}
    },
    tests: {
      added_lines: {expected: 0, review_at: 1, hard_limit: 2},
      touched_files: {expected: 0, review_at: 1, hard_limit: 2},
      new_files: {expected: 0, review_at: 1, hard_limit: 2}
    },
    project_support: {
      added_lines: {expected: 8, review_at: 12, hard_limit: 20},
      new_files: {expected: 1, review_at: 2, hard_limit: 3}
    },
    generated: {
      files: {expected: 0, review_at: 1, hard_limit: 2},
      bytes: {expected: 0, review_at: 1024, hard_limit: 2048}
    }
  },
  structural_allowances: {
    public_contracts: [],
    cmake_targets: [],
    direct_dependencies: []
  },
  reuse_decisions: [],
  obsolete_items: [],
  exceptions: []
};
const integration = {
  discovery: {
    compile_commands_path: null,
    mode: 'reviewed_inventory'
  },
  schema_version: 1,
  surfaces: []
};
fs.mkdirSync(path.join(changeRoot, 'specs', 'operator-guide'), {recursive: true});
fs.writeFileSync(path.join(changeRoot, 'proposal.md'), `# Change: Add an operator quick-start guide

Document the existing refresh command without changing any runtime surface.
`);
fs.writeFileSync(path.join(changeRoot, 'specs', 'operator-guide', 'spec.md'), `## ADDED Requirements

### Requirement: Operator refresh guidance

The project SHALL document the existing refresh command and its successful output.

#### Scenario: Operator follows the guide

- **WHEN** an operator reads the quick-start guide
- **THEN** the command and expected success marker are both present
`);
fs.writeFileSync(path.join(changeRoot, 'tasks.md'), `# Tasks

- [ ] 1.1 Add and verify the operator quick-start guide
  - Covers: \`specs/operator-guide/spec.md\` | \`ADDED\` | \`Operator refresh guidance\` | \`Operator follows the guide\`
  - Verify: \`test\`
`);
fs.writeFileSync(path.join(changeRoot, 'design.md'), `# Documentation-only design

The change intentionally declares no product surface. The executable document check is an approved TDD exception, not a substitute product consumer.

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

<!-- autoai:integration-completeness:v1 -->
\`\`\`json
${JSON.stringify(integration, null, 2)}
\`\`\`
<!-- /autoai:integration-completeness:v1 -->
`);
write('tests/verify_operator_guide.sh', `#!/usr/bin/env bash
set -euo pipefail
grep -Fqx '# Operator Quick Start' docs/operator-guide.md
grep -Fq 'widgetctl refresh' docs/operator-guide.md
grep -Fq 'refresh-complete' docs/operator-guide.md
printf '%s\\n' 'operator-guide-ok'
`, 0o755);
NODE

git -C "$repo" config user.name 'AutoAI Documentation Lifecycle Test'
git -C "$repo" config user.email 'autoai-doc-lifecycle@example.invalid'
git -C "$repo" add -A
git -C "$repo" commit -qm 'approve documentation-only change'

export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
note '空 surface 规划契约冻结 planning 与 implementation base，并通过 readiness'
run_managed_at "$repo" scripts/snapshot_update.sh \
    --freeze-planning-baseline --freeze-implementation-base \
    --phase implementing --current-step implementation-base-frozen \
    --next-step write-operator-guide
assert_status 0
run_managed_at "$repo" scripts/evaluator_check.sh --plan "$change"
assert_status 0

mkdir -p "$repo/docs"
printf '%s\n' \
    '# Operator Quick Start' \
    '' \
    'Run `widgetctl refresh` from the project root.' \
    '' \
    'A successful refresh prints `refresh-complete`.' \
    > "$repo/docs/operator-guide.md"

note 'documentation_only 例外用真实 test 命令形成 Generator 证据并完成 task'
run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id documentation-proof --kind test \
    --path docs/operator-guide.md \
    --observed 'The executable check found the documented command and success marker.' -- \
    tests/verify_operator_guide.sh
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh --complete 1.1
assert_status 0

export STUB_OPENSPEC_INSTRUCTIONS_MODE=success
report="$repo/openspec/changes/$change/harness/integration-surface-report.json"
note 'all-done 后 surface inventory 必须是 complete 且四类候选均为空'
run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --refresh --json
assert_status 0
node - "$report" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(file));
if (report.change_name !== change || report.status !== 'complete' ||
    report.discovery_mode !== 'reviewed_inventory' ||
    report.planned_surface_ids.length !== 0 ||
    report.changed_production_paths.length !== 0 ||
    report.path_candidates.length !== 0 ||
    report.structural_candidates.length !== 0 ||
    report.ast_candidates.length !== 0 ||
    report.surface_candidate_bindings.length !== 0 ||
    report.unmatched_candidates.length !== 0) {
  throw new Error('documentation-only surface inventory is not a canonical empty closure');
}
NODE

note 'Evaluator 独立执行文档验证，并生成无 candidate/surface 的 Evaluation v3 Pass'
run_managed_at "$repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_managed_at "$repo" scripts/evaluator_check.sh --run \
    --kind test \
    --expected 'The published guide contains the existing command and success marker.' \
    --observed 'The independent executable document check passed.' -- \
    tests/verify_operator_guide.sh
assert_status 0

change_dir="$repo/openspec/changes/$change"
baseline="$change_dir/harness/evaluation-baseline.json"
ledger="$change_dir/harness/evaluation-command-ledger.json"
evaluation="$change_dir/harness/evaluation.json"
node - "$baseline" "$change_dir/harness/change-footprint.json" "$ledger" "$report" \
    "$evaluation" "$change" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, reportFile, outputFile, change] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const footprint = JSON.parse(fs.readFileSync(footprintFile));
const ledger = JSON.parse(fs.readFileSync(ledgerFile));
const report = JSON.parse(fs.readFileSync(reportFile));
if (ledger.schema_version !== 2 || ledger.commands.length !== 1 ||
    ledger.commands[0].kind !== 'test' || ledger.commands[0].result !== 'Pass' ||
    ledger.commands[0].surface_ids.length !== 0 ||
    ledger.commands[0].surface_evidence_roles.length !== 0 ||
    ledger.commands[0].surface_probe_bindings.length !== 0) {
  throw new Error('independent documentation command is not an unbound executable Pass');
}
const commands = [...ledger.commands];
const commandIds = commands.map(command => command.id);
const evidenceFinished = Math.max(
  Date.parse(baseline.started_at),
  ...commands.map(command => Date.parse(command.finished_at))
);
const reviewedAt = new Date(evidenceFinished).toISOString();
const evaluatedAt = new Date(Math.max(Date.now(), evidenceFinished)).toISOString();
const requirementRef = {
  spec_path: 'specs/operator-guide/spec.md',
  operation: 'ADDED',
  requirement: 'Operator refresh guidance',
  scenarios: ['Operator follows the guide']
};
const reviewStage = (name, startedAt, completedAt, dimensions) => ({
  name,
  started_at: startedAt,
  completed_at: completedAt,
  status: 'Pass',
  requirement_refs: [requirementRef],
  task_ids: ['1.1'],
  reviewed_paths: baseline.review_input.review_paths,
  dimensions,
  evidence_command_ids: commandIds,
  finding_ids: [],
  blocking_untested_ids: [],
  not_run_reason: null
});
const notApplicable = (surface, reason) => ({
  surface,
  applicability: 'not_applicable',
  result: null,
  reason,
  evidence_paths: [],
  evidence_command_ids: [],
  not_applicable_reason: reason
});
const documentPath = 'docs/operator-guide.md';
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
      reviewStage(
        'specification_compliance',
        baseline.started_at,
        reviewedAt,
        ['requirements', 'scenarios', 'scope', 'contracts', 'traceability']
      ),
      reviewStage(
        'code_quality',
        reviewedAt,
        evaluatedAt,
        ['correctness', 'safety', 'regression_risk', 'reuse', 'complexity', 'test_quality', 'repository_impact']
      )
    ],
    findings: []
  },
  implementation_economy: {
    footprint_status: footprint.status,
    drift_explanation: null,
    classification_assessment: {
      result: 'Pass',
      reason: 'The only implementation path is classified as project documentation.',
      evidence_paths: [documentPath],
      evidence_command_ids: commandIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets',
          applicability: 'applicable',
          result: 'Pass',
          reason: 'The user-facing documentation artifact passes its executable content check.',
          evidence_paths: [documentPath],
          evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        notApplicable('install', 'The change has no install rule or installed binary impact.'),
        notApplicable('package', 'The change has no packaging impact.'),
        notApplicable('ci', 'The fixture has no CI configuration change.')
      ]
    },
    reuse_assessments: [],
    structural_assessments: [],
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: 'criterion-operator-guide',
    description: 'The operator guide documents the existing refresh command and successful output.',
    requirement_refs: [requirementRef],
    task_ids: ['1.1'],
    status: 'Pass',
    evidence_command_ids: commandIds,
    blocking_untested_ids: []
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
      reason: 'The complete diff contains no production path and therefore no product-surface candidate.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    candidate_assessments: [],
    surface_assessments: [],
    orphan_surfaces: [],
    result: 'Pass'
  }
};
fs.writeFileSync(outputFile, JSON.stringify(evaluation, null, 2) + '\n');
NODE

run_managed_at "$repo" scripts/evaluator_check.sh --finish "$change"
assert_status 0

note '合法 archive 保留空 surface report、文档例外证据、Evaluation v3 与不可变 envelope'
run_managed_at "$repo" scripts/change_archive.sh "$change"
assert_status 0
archived_as="$(date -u +%Y-%m-%d)-$change"
archived_dir="$repo/openspec/changes/archive/$archived_as"
assert_path_absent "$change_dir"
assert_path_exists "$archived_dir/harness/verification.json"
assert_path_exists "$archived_dir/harness/integration-surface-report.json"
assert_path_exists "$archived_dir/harness/evaluation.json"
assert_path_exists "$archived_dir/harness/evaluations"
node - "$repo/ai_snapshot.json" "$archived_dir" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const [rootSnapshotFile, archiveRoot, change] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(rootSnapshotFile));
const verification = JSON.parse(fs.readFileSync(path.join(archiveRoot, 'harness', 'verification.json')));
const report = JSON.parse(fs.readFileSync(path.join(archiveRoot, 'harness', 'integration-surface-report.json')));
const evaluation = JSON.parse(fs.readFileSync(path.join(archiveRoot, 'harness', 'evaluation.json')));
const baseline = JSON.parse(fs.readFileSync(path.join(archiveRoot, 'harness', 'evaluation-baseline.json')));
const envelope = JSON.parse(fs.readFileSync(path.join(
  archiveRoot, 'harness', 'evaluations', baseline.evaluation_id + '.json'
)));
const task = verification.tasks.find(item => item.task_id === '1.1');
if (root.active_change !== null || root.phase !== 'idle' ||
    verification.schema_version !== 3 || task?.surface_ids.length !== 0 ||
    !task?.commands.some(command =>
      command.phase === 'ALTERNATIVE' &&
      command.exception_id === 'documentation-proof' &&
      command.kind === 'test' &&
      command.result === 'Pass' &&
      command.surface_ids.length === 0
    ) ||
    report.status !== 'complete' ||
    report.planned_surface_ids.length !== 0 ||
    report.changed_production_paths.length !== 0 ||
    report.path_candidates.length !== 0 ||
    report.structural_candidates.length !== 0 ||
    report.ast_candidates.length !== 0 ||
    evaluation.schema_version !== 3 ||
    evaluation.verdict !== 'Pass' ||
    evaluation.integration_completeness.result !== 'Pass' ||
    evaluation.integration_completeness.candidate_assessments.length !== 0 ||
    evaluation.integration_completeness.surface_assessments.length !== 0 ||
    evaluation.integration_completeness.orphan_surfaces.length !== 0 ||
    baseline.status !== 'complete' ||
    envelope.terminal_status !== 'complete' ||
    envelope.evaluation_id !== baseline.evaluation_id ||
    envelope.change_name !== change) {
  throw new Error('archived documentation-only lifecycle evidence is incomplete');
}
NODE

note '纯文档 change 的 surfaces: [] 全生命周期与归档证据保留通过'
