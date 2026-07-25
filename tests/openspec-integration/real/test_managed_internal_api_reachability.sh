#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT
repo="$tmp/managed internal api reachability"
change=connect-internal-value
change_dir="$repo/openspec/changes/$change"
harness_dir="$change_dir/harness"
surface_id=surface-internal-value

for command_name in cmake c++ git node npm npx; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "真实 internal_api 生命周期缺少依赖：$command_name"
done

init_git_repo "$repo"
mkdir -p "$repo/src"

cat > "$repo/.gitignore" <<'EOF'
/build/
EOF

cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_internal_api_reachability LANGUAGES CXX)

add_library(component_core STATIC src/core.cpp)
target_compile_features(component_core PUBLIC cxx_std_17)
target_include_directories(component_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")

add_executable(component_app src/app.cpp)
target_link_libraries(component_app PRIVATE component_core)
EOF

cat > "$repo/src/core.cpp" <<'EOF'
namespace component {

int baseline_value() {
    return 7;
}

}
EOF

cat > "$repo/src/app.cpp" <<'EOF'
#include <iostream>

int main() {
    std::cout << "entry:baseline\n";
    return 0;
}
EOF

note '用真实 npm/npx 生成 fresh v4/v3 Harness，并创建 internal_api change'
run_setup "$repo"
assert_status 0
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)

mkdir -p "$change_dir/specs/internal-value"
cat > "$change_dir/proposal.md" <<'EOF'
## Why

The component needs one internal value operation that is observable through the existing production executable, not merely callable from a unit test.

## What Changes

- Add the internal value operation to the existing core library.
- Connect the existing production executable to that operation.
- Prove the connection through a focused process-level probe.
- External contract impact: **compatible**.

## Capabilities

### New Capabilities

- `internal-value`: Exposes the internal operation through the existing production entrypoint.

### Modified Capabilities

- None.

## Impact

The existing library and executable are reused. No production target or third-party dependency is added.
EOF

cat > "$change_dir/specs/internal-value/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Expose internal value through production
The production executable SHALL obtain the approved value through the new internal operation.

#### Scenario: Observe the connected internal value
- **WHEN** the production executable runs
- **THEN** it prints `entry:42`
EOF

cat > "$change_dir/tasks.md" <<'EOF'
## 1. Internal production connection

- [ ] 1 Implement the internal value and connect its production caller
  - Covers: `specs/internal-value/spec.md` | `ADDED` | `Expose internal value through production` | `Observe the connected internal value`
  - Verify: `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
## Context

The baseline has an existing core library and executable. A direct unit test can prove the new function body, but only the executable can prove that the product actually consumes it.

## Goals / Non-Goals

**Goals:** Add one internal operation, reuse the existing targets, and close it through a real production caller and observable process result.

**Non-Goals:** Add a public SDK, a production target, a dependency, or accept a direct unit-test invocation as integration evidence.

## Decisions

Use reviewed inventory and one exact process-level evidence contract. The unit probe is intentionally distinct from the approved production probe.

## Risks / Trade-offs

The internal declaration is kept in a source-local header. Its structural allowance is explicit because every new C++ declaration still requires scope review even when it is not installed.

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
  "rationale": "Reuse the existing library and executable; add one source-local declaration, one focused unit test, and two small probes.",
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
      "added_lines": {"expected": 40, "review_at": 60, "hard_limit": 100},
      "touched_files": {"expected": 3, "review_at": 5, "hard_limit": 7},
      "new_files": {"expected": 1, "review_at": 2, "hard_limit": 3}
    },
    "tests": {
      "added_lines": {"expected": 80, "review_at": 120, "hard_limit": 180},
      "touched_files": {"expected": 3, "review_at": 5, "hard_limit": 7},
      "new_files": {"expected": 3, "review_at": 5, "hard_limit": 7}
    },
    "project_support": {
      "added_lines": {"expected": 16, "review_at": 24, "hard_limit": 40},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "bytes": {"expected": 0, "review_at": 1024, "hard_limit": 4096}
    }
  },
  "structural_allowances": {
    "public_contracts": [
      {
        "id": "internal-value-declaration",
        "name": "source-local internal value declaration",
        "reason": "The approved internal operation needs one declaration shared by its implementation, unit test, and production caller; it is not installed or exported."
      }
    ],
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
      "change_kind": "added",
      "compatibility": null,
      "consumer_kind": "production_caller",
      "consumer_paths": ["src/app.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "component_app process entrypoint",
      "evidence_contracts": [
        {
          "argv": ["tests/production_entry_probe.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "production-interface-ok",
          "probe_id": "probe-internal-value-production",
          "role": "current"
        }
      ],
      "expected_observation": "A clean build of the existing executable runs and prints entry:42 through the internal operation.",
      "id": "surface-internal-value",
      "kind": "internal_api",
      "name": "internal approved value operation",
      "producer_paths": ["src/core.cpp", "src/internal_value_internal.hpp"],
      "requirement_refs": [
        {
          "operation": "ADDED",
          "requirement": "Expose internal value through production",
          "scenarios": ["Observe the connected internal value"],
          "spec_path": "specs/internal-value/spec.md"
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

note '严格验证规划并冻结真实 C++ 基线'
(
    cd "$repo"
    git config user.name 'AutoAI Real Internal API Test'
    git config user.email 'autoai-real-internal-api@example.invalid'
    scripts/integration_surface_check.sh "$change" --plan-check --json >/dev/null
    scripts/openspec_cli.sh validate "$change" --type change --strict --json > "$tmp/strict-plan.json"
    cmake -S . -B build/baseline >/dev/null
    cmake --build build/baseline --parallel 2 >/dev/null
    test "$(build/baseline/component_app)" = entry:baseline
    git add -A
    git commit -qm 'approved internal api baseline'
    scripts/snapshot_update.sh --freeze-planning-baseline >/dev/null
    scripts/snapshot_update.sh --freeze-implementation-base >/dev/null
)

node - "$harness_dir/ai_snapshot.json" "$harness_dir/verification.json" <<'NODE'
const fs = require('fs');
const [snapshotFile, verificationFile] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile));
const verification = JSON.parse(fs.readFileSync(verificationFile));
if (snapshot.schema_version !== 4 || verification.schema_version !== 3 ||
    !snapshot.planned_integration_completeness_sha256?.startsWith('sha256:') ||
    verification.tasks.length !== 0) {
  throw new Error('fresh integrated evidence family mismatch');
}
NODE

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

note '先只增加直调 internal API 的单元测试，并记录真实 RED'
mkdir -p "$repo/tests"
cat >> "$repo/CMakeLists.txt" <<'EOF'

enable_testing()
add_executable(internal_value_test tests/internal_value_test.cpp)
target_link_libraries(internal_value_test PRIVATE component_core)
add_test(NAME internal_value_test COMMAND internal_value_test)
EOF

cat > "$repo/tests/internal_value_test.cpp" <<'EOF'
#include "internal_value_internal.hpp"

int main() {
    return component::internal::approved_value() == 42 ? 0 : 1;
}
EOF

cat > "$repo/tests/unit_interface_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ -n "${AUTOAI_UNIT_PROBE_MARKER:-}" ]]; then
    : > "$AUTOAI_UNIT_PROBE_MARKER"
fi
if cmake -S . -B build/unit-probe >/dev/null 2>&1 &&
   cmake --build build/unit-probe --target internal_value_test --parallel 2 >/dev/null 2>&1 &&
   build/unit-probe/internal_value_test; then
    echo internal-unit-ok
    exit 0
fi
echo internal-unit-red
exit 1
EOF
chmod 755 "$repo/tests/unit_interface_probe.sh"

cat > "$repo/tests/production_entry_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -u
rm -rf -- build/production-probe
if ! cmake -S . -B build/production-probe >/dev/null 2>&1 ||
   ! cmake --build build/production-probe --target component_app --parallel 2 >/dev/null 2>&1; then
    echo production-build-failed
    exit 1
fi
output=$(build/production-probe/component_app)
if [[ "$output" != entry:42 ]]; then
    echo production-interface-not-connected
    exit 1
fi
echo production-interface-ok
EOF
chmod 755 "$repo/tests/production_entry_probe.sh"

run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase red --cycle internal-value --kind behavior --expect-exit 1 \
    --path CMakeLists.txt \
    --path tests/internal_value_test.cpp \
    --path tests/production_entry_probe.sh \
    --path tests/unit_interface_probe.sh \
    --test-path tests/unit_interface_probe.sh --failure-class contract \
    --expected-failure 'the focused unit consumer cannot compile before the approved internal operation exists' \
    --match-output internal-unit-red \
    --observed 'the real C++ compiler rejected the missing internal declaration' -- \
    tests/unit_interface_probe.sh
assert_status 0

note '实现函数后单元测试 GREEN，但暂不修改 production caller'
cat > "$repo/src/internal_value_internal.hpp" <<'EOF'
#pragma once

namespace component::internal {

int approved_value();

}
EOF

cat > "$repo/src/core.cpp" <<'EOF'
#include "internal_value_internal.hpp"

namespace component {

int baseline_value() {
    return 7;
}

namespace internal {

int approved_value() {
    return 42;
}

}
}
EOF

run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase green --cycle internal-value --kind behavior \
    --path CMakeLists.txt \
    --path src/core.cpp \
    --path src/internal_value_internal.hpp \
    --path tests/internal_value_test.cpp \
    --path tests/production_entry_probe.sh \
    --path tests/unit_interface_probe.sh -- \
    tests/unit_interface_probe.sh
assert_status 0

note '只有单元测试调用时：错误 probe 在执行前拒绝，批准的 production probe 真实运行但无法闭合'
verification="$harness_dir/verification.json"
evidence_after_green=$(sha256sum -- "$verification" | awk '{print $1}')
unit_execution_marker="$tmp/unit-probe-must-not-run"
run_managed_at "$repo" env AUTOAI_UNIT_PROBE_MARKER="$unit_execution_marker" \
    scripts/task_verify.sh 1 \
    --phase regression --cycle internal-value --kind behavior \
    --surface "$surface_id" \
    --path src/core.cpp --path src/internal_value_internal.hpp -- \
    tests/unit_interface_probe.sh
assert_status 6
assert_path_absent "$unit_execution_marker"
[[ "$evidence_after_green" == "$(sha256sum -- "$verification" | awk '{print $1}')" ]] || \
    fail 'unapproved unit probe mutated Generator evidence'

run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase regression --cycle internal-value --kind behavior \
    --surface "$surface_id" \
    --path src/core.cpp --path src/internal_value_internal.hpp -- \
    tests/production_entry_probe.sh
assert_status 1
assert_contains "$RUN_OUTPUT" production-interface-not-connected
[[ "$evidence_after_green" == "$(sha256sum -- "$verification" | awk '{print $1}')" ]] || \
    fail 'failed production probe mutated Generator evidence'

run_managed_at "$repo" scripts/task_verify.sh --complete 1
assert_status 6
assert_file_contains "$change_dir/tasks.md" '- [ ] 1 Implement the internal value and connect its production caller'

note '接入现有 production caller 后，Generator 只能用规划中的 exact probe 完成闭环'
cat > "$repo/src/app.cpp" <<'EOF'
#include "internal_value_internal.hpp"

#include <iostream>

int main() {
    std::cout << "entry:" << component::internal::approved_value() << '\n';
    return 0;
}
EOF

run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase regression --cycle internal-value --kind behavior \
    --surface "$surface_id" \
    --path CMakeLists.txt \
    --path src/app.cpp \
    --path src/core.cpp \
    --path src/internal_value_internal.hpp \
    --path tests/internal_value_test.cpp \
    --path tests/production_entry_probe.sh \
    --path tests/unit_interface_probe.sh \
    --observed 'the approved process probe observed the production caller reaching the internal operation' -- \
    tests/production_entry_probe.sh
assert_status 0
assert_contains "$RUN_OUTPUT" production-interface-ok

run_managed_at "$repo" scripts/task_verify.sh --complete 1
assert_status 0
assert_file_contains "$change_dir/tasks.md" '- [x] 1 Implement the internal value and connect its production caller'

node - "$verification" "$surface_id" <<'NODE'
const fs = require('fs');
const [file, surfaceId] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file));
const task = value.tasks.find(item => item.task_id === '1');
if (value.schema_version !== 3 || !task || task.surface_ids.join(',') !== surfaceId ||
    task.commands.length !== 3) {
  throw new Error('Generator evidence retained rejected unit-only attempts');
}
const regression = task.commands.find(item => item.phase === 'REGRESSION');
if (!regression || regression.argv.join('\0') !== 'tests/production_entry_probe.sh' ||
    JSON.stringify(regression.surface_probe_bindings) !==
      JSON.stringify([{surface_id: surfaceId, role: 'current', probe_id: 'probe-internal-value-production'}])) {
  throw new Error('Generator exact production probe binding is missing');
}
NODE

note '刷新 reviewed inventory，确认 producer、production caller 和声明候选全部映射且无孤儿项'
report="$harness_dir/integration-surface-report.json"
run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --refresh --json
assert_status 0
assert_path_exists "$report"
node - "$report" "$surface_id" <<'NODE'
const fs = require('fs');
const [file, surfaceId] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(file));
const expectedPaths = ['src/app.cpp', 'src/core.cpp', 'src/internal_value_internal.hpp'];
if (report.schema_version !== 1 || report.discovery_mode !== 'reviewed_inventory' ||
    report.status !== 'complete' || report.unmatched_candidates.length !== 0 ||
    JSON.stringify(report.changed_production_paths) !== JSON.stringify(expectedPaths) ||
    report.structural_candidates.length !== 1) {
  throw new Error(`internal API inventory did not close: ${JSON.stringify(report)}`);
}
const binding = report.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
const roles = new Set(binding?.candidate_bindings.map(item => item.role));
if (!binding || !roles.has('producer') || !roles.has('consumer') ||
    binding.consumer_paths.join(',') !== 'src/app.cpp') {
  throw new Error('internal API producer/production-caller binding is incomplete');
}
NODE

note '独立 Evaluator 重新 clean build 并运行同一批准 probe'
run_managed_at "$repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_managed_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior --surface "$surface_id" \
    --expected 'A clean build of the existing executable reaches the approved internal operation.' \
    --observed 'The independently rebuilt executable printed entry:42 and the planned success marker.' -- \
    tests/production_entry_probe.sh
assert_status 0
assert_contains "$RUN_OUTPUT" production-interface-ok

baseline="$harness_dir/evaluation-baseline.json"
ledger="$harness_dir/evaluation-command-ledger.json"
evaluation="$harness_dir/evaluation.json"

node - "$baseline" "$harness_dir/change-footprint.json" "$ledger" "$report" \
    "$evaluation" "$change" "$surface_id" "$repo" <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const [baselineFile, footprintFile, ledgerFile, reportFile, outputFile, change, surfaceId, repoRoot] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const footprint = JSON.parse(fs.readFileSync(footprintFile));
const ledger = JSON.parse(fs.readFileSync(ledgerFile));
const report = JSON.parse(fs.readFileSync(reportFile));
const commands = [...ledger.commands];
if (baseline.schema_version !== 3 || ledger.schema_version !== 2 || commands.length !== 1 ||
    commands[0].result !== 'Pass' || commands[0].argv.join('\0') !== 'tests/production_entry_probe.sh' ||
    JSON.stringify(commands[0].surface_probe_bindings) !==
      JSON.stringify([{surface_id: surfaceId, role: 'current', probe_id: 'probe-internal-value-production'}])) {
  throw new Error('independent exact production probe ledger is incomplete');
}
if (footprint.status !== 'within_expected') {
  throw new Error(`unexpected implementation economy status: ${footprint.status}`);
}

const policy = require(repoRoot + '/scripts/manifest_policy.js').loadManifest(repoRoot);
const base = baseline.review_input.implementation_base_commit;
const changed = cp.execFileSync('git', ['diff', '--name-only', '-z', base, '--'], {cwd: repoRoot})
  .toString('utf8').split('\0');
const untracked = cp.execFileSync('git', ['ls-files', '--others', '--exclude-standard', '-z'], {cwd: repoRoot})
  .toString('utf8').split('\0');
const implementationPaths = [...new Set([...changed, ...untracked].filter(Boolean))]
  .filter(item => !policy.isManaged(item)).sort();
const expectedImplementationPaths = [
  'CMakeLists.txt',
  'src/app.cpp',
  'src/core.cpp',
  'src/internal_value_internal.hpp',
  'tests/internal_value_test.cpp',
  'tests/production_entry_probe.sh',
  'tests/unit_interface_probe.sh'
];
if (JSON.stringify(implementationPaths) !== JSON.stringify(expectedImplementationPaths)) {
  throw new Error(`unexpected implementation path inventory: ${JSON.stringify(implementationPaths)}`);
}

const commandIds = commands.map(command => command.id);
const evidenceFinished = Math.max(
  Date.parse(baseline.started_at), ...commands.map(command => Date.parse(command.finished_at)));
const reviewedAt = new Date(evidenceFinished).toISOString();
const evaluatedAt = new Date(Math.max(Date.now(), evidenceFinished)).toISOString();
const requirementRef = {
  spec_path: 'specs/internal-value/spec.md',
  operation: 'ADDED',
  requirement: 'Expose internal value through production',
  scenarios: ['Observe the connected internal value']
};
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

const reportBinding = report.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
if (!reportBinding) throw new Error('surface report binding missing');
const typedByCandidate = new Map();
for (const binding of reportBinding.candidate_bindings) {
  const roles = typedByCandidate.get(binding.candidate_id) || [];
  roles.push(binding.role);
  typedByCandidate.set(binding.candidate_id, roles);
}
const allCandidates = [...report.path_candidates, ...report.structural_candidates, ...report.ast_candidates];
const candidateAssessments = allCandidates.map(candidate => {
  const roles = [...new Set(typedByCandidate.get(candidate.candidate_id) || [])]
    .sort((a, b) => ['producer', 'consumer'].indexOf(a) - ['producer', 'consumer'].indexOf(b));
  if (!roles.length) throw new Error(`complete report left ${candidate.candidate_id} unbound`);
  const logicalPaths = [...new Set([candidate.old_path, candidate.path].filter(Boolean))].sort();
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
    reason: 'The candidate is mapped to the approved internal producer or its real production caller.',
    producer_paths: roles.includes('producer')
      ? logicalPaths.filter(item => reportBinding.producer_paths.includes(item)) : [],
    implementation_consumer: null,
    evidence_paths: logicalPaths,
    evidence_command_ids: commandIds,
    orphan_ids: []
  };
}).sort((a, b) => a.candidate_id.localeCompare(b.candidate_id));

const structuralIds = footprint.structural_candidates.map(item => item.candidate_id);
if (structuralIds.length !== 1 || report.structural_candidates.length !== 1) {
  throw new Error('expected exactly one approved source-local declaration candidate');
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
      reason: 'Every changed implementation path is covered by one approved production, test, or tooling classification.',
      evidence_paths: implementationPaths,
      evidence_command_ids: commandIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets',
          applicability: 'applicable',
          result: 'Pass',
          reason: 'The existing library and executable are rebuilt and the production entrypoint observes the internal value.',
          evidence_paths: report.changed_production_paths,
          evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'not_applicable', result: null,
          reason: 'The approved operation is internal and has no install surface.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'The implementation base defines no install rule.'
        },
        {
          surface: 'package', applicability: 'not_applicable', result: null,
          reason: 'The approved operation is not a package contract.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'The implementation base defines no package export.'
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'This disposable lifecycle fixture has no CI configuration.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI file exists in the approved implementation base.'
        }
      ]
    },
    reuse_assessments: [],
    structural_assessments: [{
      allowance_id: 'internal-value-declaration',
      candidate_ids: structuralIds,
      result: 'Pass',
      reason: 'The sole declaration candidate is source-local, planned, and exercised through its production caller.',
      evidence_paths: ['src/internal_value_internal.hpp', 'src/app.cpp'],
      evidence_command_ids: commandIds
    }],
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: 'criterion-production-internal-value',
    description: 'The existing production executable obtains and prints the approved internal value.',
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
      reason: 'Every changed production candidate was reviewed and mapped to the internal operation or its production caller.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    candidate_assessments: candidateAssessments,
    surface_assessments: [{
      surface_id: surfaceId,
      result: 'Pass',
      reason: 'The independent exact probe observes the internal producer only through the existing production executable.',
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

node - "$baseline" "$evaluation" "$surface_id" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const [baselineFile, evaluationFile, surfaceId] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
const digest = 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(evaluationFile)).digest('hex');
if (baseline.status !== 'complete' || baseline.evaluation_json_sha256 !== digest ||
    evaluation.verdict !== 'Pass' || evaluation.integration_completeness.orphan_surfaces.length !== 0 ||
    evaluation.integration_completeness.surface_assessments[0].surface_id !== surfaceId ||
    evaluation.integration_completeness.surface_assessments[0].result !== 'Pass') {
  throw new Error('sealed internal API Evaluation is incomplete');
}
NODE

note '唯一 Evaluation Pass 通过 archive，完整 surface 证据随 change 保留'
run_managed_at "$repo" scripts/change_archive.sh "$change"
assert_status 0
archived_as="$(date -u +%Y-%m-%d)-$change"
archived_dir="$repo/openspec/changes/archive/$archived_as"
assert_path_absent "$change_dir"
assert_path_exists "$archived_dir/harness/integration-surface-report.json"
assert_path_exists "$archived_dir/harness/evaluation.json"
assert_path_exists "$repo/openspec/specs/internal-value/spec.md"

node - "$repo/ai_snapshot.json" "$archived_dir/harness/evaluation.json" \
    "$change" "$archived_as" <<'NODE'
const fs = require('fs');
const [rootFile, evaluationFile, change, archivedAs] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(rootFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
if (root.active_change !== null || root.last_archived_change?.change_name !== change ||
    root.last_archived_change?.archived_as !== archivedAs || evaluation.verdict !== 'Pass' ||
    evaluation.integration_completeness?.result !== 'Pass' ||
    evaluation.integration_completeness?.orphan_surfaces?.length !== 0) {
  throw new Error('archived internal API closure state mismatch');
}
NODE

note '真实 C++ internal_api 从 unit-only 拒绝、production caller 接入、独立 Evaluation 到 archive 的生命周期通过'
