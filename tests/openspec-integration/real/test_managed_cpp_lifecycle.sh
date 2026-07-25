#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT
repo="$tmp/managed C++ lifecycle"
change=add-managed-widget-value
change_dir="$repo/openspec/changes/$change"
harness_dir="$change_dir/harness"

for command_name in cmake ctest c++ node git npm npx; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "受管真实生命周期缺少依赖：$command_name"
done

init_git_repo "$repo"
mkdir -p "$repo/include/widget" "$repo/src" "$repo/tests"

cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_managed_lifecycle LANGUAGES CXX)

include(CTest)

add_library(widget_core STATIC src/widget.cpp)
target_compile_features(widget_core PUBLIC cxx_std_17)
target_include_directories(widget_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")

add_executable(widget_cli src/widget_cli.cpp)
target_link_libraries(widget_cli PRIVATE widget_core)

add_executable(widget_behavior_test tests/widget_test.cpp)
target_link_libraries(widget_behavior_test PRIVATE widget_core)
add_test(NAME widget_behavior_test COMMAND widget_behavior_test)
EOF

cat > "$repo/include/widget/value.hpp" <<'EOF'
#pragma once

namespace widget {
int approved_value() noexcept;
}
EOF

cat > "$repo/src/widget.cpp" <<'EOF'
#include "widget/value.hpp"

namespace widget {
int approved_value() noexcept {
    return 1;
}
}
EOF

cat > "$repo/src/widget_cli.cpp" <<'EOF'
#include "widget/value.hpp"

#include <iostream>

int main() {
    std::cout << widget::approved_value() << '\n';
    return 0;
}
EOF

cat > "$repo/tests/widget_test.cpp" <<'EOF'
#include "widget/value.hpp"

int main() {
    return widget::approved_value() == 1 ? 0 : 1;
}
EOF

cat > "$repo/tests/widget_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
rm -rf build/managed-probe
cmake -S . -B build/managed-probe >/dev/null
cmake --build build/managed-probe --parallel 2 >/dev/null
ctest --test-dir build/managed-probe --output-on-failure >/dev/null
actual=$(./build/managed-probe/widget_cli)
if [[ "$actual" != 7 ]]; then
    echo "expected widget value 7, got $actual"
    exit 1
fi
echo widget-value-ok
EOF
chmod 755 "$repo/tests/widget_probe.sh"

note '真实 npm/npx 初始化 Harness，并通过受管 wrapper 创建 active change'
run_setup "$repo"
assert_status 0
version=$(cd "$repo" && scripts/openspec_cli.sh --version)
[[ "$version" == 1.6.0 ]] || fail "受管闭环没有使用固定 OpenSpec 1.6.0：$version"
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)

mkdir -p "$change_dir/specs/managed-widget"
cat > "$change_dir/proposal.md" <<'EOF'
## Why

Consumers need one additional approved value while the existing C++ function signature remains stable.

## What Changes

- Change the disposable fixture value from `1` to `7`.
- Keep the public C++ function signature and build target topology unchanged.
- External contract impact: **compatible**.

## Capabilities

### New Capabilities

- `managed-widget`: Defines the newly approved observable value.

### Modified Capabilities

- None.

## Impact

Only one existing implementation and its focused behavior test change.
EOF

cat > "$change_dir/specs/managed-widget/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Emit approved managed value
The widget fixture SHALL expose the approved managed value without changing its public function signature.

#### Scenario: Print seven
- **WHEN** a consumer executes the widget CLI
- **THEN** standard output is `7` and the process exits successfully
EOF

cat > "$change_dir/tasks.md" <<'EOF'
## 1. Compatible implementation

# OpenSpec 1.6.0 exposes leaf task ids as ordinal strings ("1", "2", ...).
- [ ] 1 Implement and verify the approved widget value
  - Covers: `specs/managed-widget/spec.md` | `ADDED` | `Emit approved managed value` | `Print seven`
  - Verify: `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
## Context

The fixture already exposes the required function and executable. The implementation should reuse both.

## Goals / Non-Goals

**Goals:** Change the observable value and update the existing focused test.

**Non-Goals:** Add targets, public types, dependencies, or production files.

## Decisions

Edit the existing return expression and existing test expectation only.

## Risks / Trade-offs

The behavior contract changes, but the public C++ API shape and build graph remain stable.

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
  "profile": "micro",
  "rationale": "The compatible fixture change reuses one function, one CLI, and one focused test.",
  "classification": {
    "production": ["src/**", "include/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md"],
    "project_tooling": ["CMakeLists.txt"],
    "examples": ["examples/**"],
    "generated": [],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 2, "review_at": 6, "hard_limit": 12},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 2, "review_at": 6, "hard_limit": 12},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 3, "hard_limit": 6},
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
      "consumer_kind": "real_entrypoint",
      "consumer_paths": ["src/widget_cli.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "build/managed-probe/widget_cli",
      "evidence_contracts": [
        {
          "argv": ["tests/widget_probe.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "widget-value-ok",
          "probe_id": "probe-managed-widget-cli-current",
          "role": "current"
        }
      ],
      "expected_observation": "A clean build passes CTest and the real widget CLI prints 7.",
      "id": "surface-managed-widget-cli",
      "kind": "cli",
      "name": "managed widget CLI value",
      "producer_paths": ["src/widget.cpp"],
      "requirement_refs": [
        {
          "operation": "ADDED",
          "requirement": "Emit approved managed value",
          "scenarios": ["Print seven"],
          "spec_path": "specs/managed-widget/spec.md"
        }
      ],
      "symbol_identities": null,
      "task_ids": ["1"],
      "task_obligations": [
        {
          "evidence_roles": ["current"],
          "task_id": "1",
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

note '提交已审核规划与初始可构建项目，再分别冻结 planning 与 implementation base'
(
    cd "$repo"
    git config user.name 'AutoAI Real Lifecycle Test'
    git config user.email 'autoai-real-lifecycle@example.invalid'
    cmake -S . -B build/baseline >/dev/null
    cmake --build build/baseline --parallel 2 >/dev/null
    ctest --test-dir build/baseline --output-on-failure >/dev/null
    test "$(./build/baseline/widget_cli)" = 1
    scripts/integration_surface_check.sh "$change" --plan-check --json >/dev/null
    scripts/openspec_cli.sh validate "$change" --type change --strict --json >/dev/null
    git add -A
    git commit -qm 'approved managed lifecycle baseline'
    scripts/snapshot_update.sh --freeze-planning-baseline >/dev/null
    scripts/snapshot_update.sh --freeze-implementation-base >/dev/null
)

node - "$harness_dir/ai_snapshot.json" "$(git -C "$repo" rev-parse HEAD)" <<'NODE'
const fs = require('fs');
const [file, head] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
if (snapshot.schema_version !== 4 ||
    !snapshot.planned_base_specs_fingerprint?.startsWith('sha256:') ||
    !snapshot.planned_integration_completeness_sha256?.startsWith('sha256:') ||
    snapshot.implementation_base_commit !== head ||
    !snapshot.implementation_baselined_at) {
  throw new Error('planning/implementation baselines were not frozen');
}
NODE

note 'Generator 先用真实 clean build/CTest/CLI probe 建立 RED'
(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
    scripts/task_verify.sh 1 \
        --phase red --cycle managed-widget --kind behavior --expect-exit 1 \
        --path src/widget.cpp --path tests/widget_test.cpp \
        --test-path tests/widget_probe.sh \
        --failure-class behavior \
        --expected-failure 'the baseline CLI still prints 1 instead of the approved value 7' \
        --match-output 'expected widget value 7, got 1' \
        --observed 'the immutable production-entry probe reproduced the approved behavior gap' -- \
        tests/widget_probe.sh
)

note 'Generator 只修改既有实现和测试，再以同一 probe 完成 GREEN 与 surface-bound REGRESSION'
sed -i 's/return 1;/return 7;/' "$repo/src/widget.cpp"
sed -i 's/approved_value() == 1/approved_value() == 7/' "$repo/tests/widget_test.cpp"
(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
    scripts/task_verify.sh 1 \
        --phase green --cycle managed-widget --kind behavior \
        --path src/widget.cpp --path tests/widget_test.cpp -- \
        tests/widget_probe.sh
    scripts/task_verify.sh 1 \
        --phase regression --cycle managed-widget --kind behavior \
        --surface surface-managed-widget-cli \
        --path src/widget.cpp --path tests/widget_test.cpp \
        --observed 'the independently runnable production CLI probe printed the approved value after clean build and CTest' -- \
        tests/widget_probe.sh
    scripts/task_verify.sh --complete 1 >/dev/null
    scripts/integration_surface_check.sh "$change" --refresh --json >/dev/null
)

node - "$harness_dir/change-footprint.json" "$harness_dir/verification.json" \
    "$harness_dir/integration-surface-report.json" <<'NODE'
const fs = require('fs');
const [footprintFile, verificationFile, reportFile] = process.argv.slice(2);
const footprint = JSON.parse(fs.readFileSync(footprintFile, 'utf8'));
const verification = JSON.parse(fs.readFileSync(verificationFile, 'utf8'));
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (footprint.status !== 'within_expected' || footprint.production.touched_files !== 1 ||
    footprint.tests.touched_files !== 1 || footprint.production.new_files !== 0) {
  throw new Error(`unexpected managed footprint: ${JSON.stringify(footprint)}`);
}
const task = verification.tasks.find(item => item.task_id === '1');
const regression = task?.commands.find(item => item.phase === 'REGRESSION');
if (verification.schema_version !== 3 || !task || task.commands.length !== 3 ||
    JSON.stringify(regression?.surface_probe_bindings) !== JSON.stringify([{
      surface_id: 'surface-managed-widget-cli',
      role: 'current',
      probe_id: 'probe-managed-widget-cli-current'
    }])) {
  throw new Error('Generator RED/GREEN/exact REGRESSION evidence is incomplete');
}
if (report.schema_version !== 1 || report.status !== 'complete' ||
    report.unmatched_candidates.length !== 0 ||
    report.surface_candidate_bindings.length !== 1 ||
    !report.surface_candidate_bindings[0].candidate_bindings.some(
      item => item.role === 'producer')) {
  throw new Error(`managed widget report is not closed: ${JSON.stringify(report)}`);
}
NODE

note '独立 Evaluator 冻结输入，并通过受管 ledger 真实重跑同一 exact production probe'
(
    cd "$repo"
    scripts/evaluator_check.sh --begin "$change" >/dev/null
    scripts/evaluator_check.sh --run \
        --kind behavior --surface surface-managed-widget-cli \
        --expected 'A clean build passes CTest and the real widget CLI prints 7.' \
        --observed 'The independent exact probe printed widget-value-ok.' -- \
        tests/widget_probe.sh
)

node - "$harness_dir/evaluation-baseline.json" "$harness_dir/change-footprint.json" \
    "$harness_dir/evaluation-command-ledger.json" \
    "$harness_dir/integration-surface-report.json" \
    "$harness_dir/evaluation.json" "$change" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, reportFile, outputFile, change] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const footprint = JSON.parse(fs.readFileSync(footprintFile));
const ledger = JSON.parse(fs.readFileSync(ledgerFile));
const report = JSON.parse(fs.readFileSync(reportFile));
const commands = [...ledger.commands];
const surfaceId = 'surface-managed-widget-cli';
if (baseline.schema_version !== 3 || ledger.schema_version !== 2 ||
    commands.length !== 1 || commands[0].kind !== 'behavior' ||
    commands[0].result !== 'Pass' ||
    commands[0].argv.join('\0') !== 'tests/widget_probe.sh' ||
    JSON.stringify(commands[0].surface_probe_bindings) !== JSON.stringify([{
      surface_id: surfaceId,
      role: 'current',
      probe_id: 'probe-managed-widget-cli-current'
    }])) {
  throw new Error('independent exact widget probe ledger is incomplete');
}
const implementationPaths = ['src/widget.cpp', 'tests/widget_test.cpp'];
const commandIds = commands.map(command => command.id);
const requirementRef = {
  spec_path: 'specs/managed-widget/spec.md',
  operation: 'ADDED',
  requirement: 'Emit approved managed value',
  scenarios: ['Print seven']
};
const evidenceFinished = Math.max(
  Date.parse(baseline.started_at), ...commands.map(command => Date.parse(command.finished_at)));
const reviewedAt = new Date(evidenceFinished).toISOString();
const evaluatedAt = new Date(Math.max(Date.now(), evidenceFinished)).toISOString();
const reviewStage = (name, startedAt, completedAt, dimensions) => ({
  name,
  started_at: startedAt,
  completed_at: completedAt,
  status: 'Pass',
  requirement_refs: [requirementRef],
  task_ids: ['1'],
  reviewed_paths: baseline.review_input.review_paths,
  dimensions,
  evidence_command_ids: commandIds,
  finding_ids: [],
  blocking_untested_ids: [],
  not_run_reason: null
});
const reportBinding = report.surface_candidate_bindings.find(
  item => item.surface_id === surfaceId);
if (!reportBinding) throw new Error('managed widget report binding is missing');
const typedByCandidate = new Map();
for (const binding of reportBinding.candidate_bindings) {
  const roles = typedByCandidate.get(binding.candidate_id) || [];
  roles.push(binding.role);
  typedByCandidate.set(binding.candidate_id, roles);
}
const allCandidates = [
  ...report.path_candidates,
  ...report.structural_candidates,
  ...report.ast_candidates
];
const candidateAssessments = allCandidates.map(candidate => {
  const roles = [...new Set(typedByCandidate.get(candidate.candidate_id) || [])]
    .sort((a, b) => ['producer', 'consumer'].indexOf(a) - ['producer', 'consumer'].indexOf(b));
  if (!roles.length) throw new Error(`complete report left ${candidate.candidate_id} unbound`);
  const logicalPaths = candidate.source === 'clang_ast'
    ? [...new Set([
        candidate.base_symbol_identity?.declaration_path,
        candidate.current_symbol_identity?.declaration_path
      ].filter(Boolean))].sort()
    : [...new Set([candidate.old_path, candidate.path].filter(Boolean))].sort();
  return {
    candidate_id: candidate.candidate_id,
    source: candidate.source,
    disposition: 'mapped',
    surface_ids: [surfaceId],
    surface_bindings: [{
      surface_id: surfaceId,
      candidate_roles: roles,
      consumer_kind: 'real_entrypoint',
      consumer_paths: reportBinding.consumer_paths
    }],
    reason: 'The changed implementation candidate belongs to the approved CLI behavior surface and is exercised through its real executable.',
    producer_paths: roles.includes('producer')
      ? logicalPaths.filter(item => reportBinding.producer_paths.includes(item))
      : [],
    implementation_consumer: null,
    evidence_paths: logicalPaths,
    evidence_command_ids: commandIds,
    orphan_ids: []
  };
}).sort((a, b) => a.candidate_id.localeCompare(b.candidate_id));
if (report.status !== 'complete' || report.unmatched_candidates.length ||
    footprint.structural_candidates.length || report.structural_candidates.length) {
  throw new Error('managed widget inventory unexpectedly contains an orphan or structural candidate');
}
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
      reason: 'The only changed source and test paths match the approved classifications.',
      evidence_paths: implementationPaths,
      evidence_command_ids: commandIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets', applicability: 'applicable', result: 'Pass',
          reason: 'The existing library, CLI, and test targets are rebuilt and the real executable prints the approved value.',
          evidence_paths: implementationPaths, evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'not_applicable', result: null,
          reason: 'The disposable fixture has no install rules.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No install surface exists in the approved baseline.'
        },
        {
          surface: 'package', applicability: 'not_applicable', result: null,
          reason: 'The disposable fixture has no package surface.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No package configuration exists in the approved baseline.'
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'The disposable fixture has no CI surface.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI configuration exists in the approved baseline.'
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
    id: 'criterion-managed-widget',
    description: 'The existing widget target builds, passes CTest, and prints seven.',
    requirement_refs: [requirementRef],
    task_ids: ['1'],
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
      reason: 'Every changed production candidate is mapped to the approved widget CLI surface.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    candidate_assessments: candidateAssessments,
    surface_assessments: [{
      surface_id: surfaceId,
      result: 'Pass',
      reason: 'The independent exact probe performs a clean build, runs CTest, invokes the real CLI, and observes 7.',
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

(
    cd "$repo"
    scripts/evaluator_check.sh --finish "$change" >/dev/null
)

node - "$harness_dir/evaluation-baseline.json" "$harness_dir/evaluation.json" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const [baselineFile, evaluationFile] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile, 'utf8'));
const digest = 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(evaluationFile)).digest('hex');
if (baseline.status !== 'complete' || baseline.evaluation_json_sha256 !== digest ||
    evaluation.verdict !== 'Pass' || evaluation.implementation_economy.result !== 'Pass' ||
    evaluation.integration_completeness?.result !== 'Pass' ||
    evaluation.integration_completeness?.orphan_surfaces?.length !== 0) {
  throw new Error('independent closed Pass Evaluation was not completed and digest-bound');
}
NODE

note '唯一受管 archive wrapper 通过全部门禁后调用真实 OpenSpec 1.6.0 archive'
(
    cd "$repo"
    scripts/change_archive.sh "$change" >/dev/null
)

archived_as="$(date -u +%Y-%m-%d)-$change"
archived_dir="$repo/openspec/changes/archive/$archived_as"
assert_path_absent "$change_dir"
assert_path_exists "$archived_dir/harness/evaluation.json"
assert_path_exists "$archived_dir/harness/verification.json"
assert_path_exists "$archived_dir/harness/change-footprint.json"
assert_path_exists "$archived_dir/harness/integration-surface-report.json"
assert_path_exists "$repo/openspec/specs/managed-widget/spec.md"
assert_file_contains "$repo/openspec/specs/managed-widget/spec.md" 'Requirement: Emit approved managed value'
assert_file_contains "$repo/openspec/specs/managed-widget/spec.md" 'Scenario: Print seven'

node - "$repo/ai_snapshot.json" "$change" "$archived_as" <<'NODE'
const fs = require('fs');
const [file, change, archivedAs] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
if (snapshot.active_change !== null || snapshot.phase !== 'idle' ||
    snapshot.last_archived_change?.change_name !== change ||
    snapshot.last_archived_change?.archived_as !== archivedAs ||
    Object.hasOwn(snapshot, 'archive_failure')) {
  throw new Error('managed archive did not clear active state and record the archive identity');
}
NODE

post_validation="$tmp/post-archive-validation.json"
(
    cd "$repo"
    scripts/openspec_cli.sh validate --all --strict --json --no-interactive > "$post_validation"
)
node - "$post_validation" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (data.summary?.totals?.failed !== 0 || data.items.length < 1 ||
    data.items.some(item => item.valid !== true)) {
  throw new Error('post-managed-archive main specs did not pass real strict validation');
}
NODE

note '真实 OpenSpec 1.6.0 + CMake/C++ 受管 planning → Generator → Evaluator → archive 闭环通过'
