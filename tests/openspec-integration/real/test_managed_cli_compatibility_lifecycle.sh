#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT
repo="$tmp/managed cli compatibility"

for command_name in cmake c++ git node npm npx; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "真实 compatibility 生命周期缺少依赖：$command_name"
done

init_git_repo "$repo"
mkdir -p "$repo/src" "$repo/tests"

cat > "$repo/.gitignore" <<'EOF'
/build/
EOF

cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_cli_compatibility LANGUAGES CXX)

add_executable(compat_cli src/main.cpp)
target_compile_features(compat_cli PRIVATE cxx_std_17)
EOF

cat > "$repo/src/main.cpp" <<'EOF'
#include <iostream>
#include <string_view>

int main(int argc, char** argv) {
    const std::string_view option = argc > 1 ? argv[1] : "--help";
    if (option == "--legacy") {
        std::cout << "value:42\n";
        return 0;
    }
    if (option == "--help") {
        std::cout << "--legacy\n";
        return 0;
    }
    std::cerr << "unknown option: " << option << '\n';
    return 64;
}
EOF

cat > "$repo/tests/legacy_cli_consumer.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "${1:?compat_cli required}" --legacy
EOF

cat > "$repo/tests/current_cli_consumer.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "${1:?compat_cli required}" --current
EOF
chmod 755 "$repo/tests/legacy_cli_consumer.sh" "$repo/tests/current_cli_consumer.sh"

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

write_change_plan() {
    local change=$1 mode=$2
    local change_dir="$repo/openspec/changes/$change"
    mkdir -p "$change_dir/specs/cli-compatibility"
    node - "$change_dir" "$mode" <<'NODE'
const fs = require('fs');
const path = require('path');
const [changeDir, mode] = process.argv.slice(2);
const deprecated = mode === 'deprecation';
if (!deprecated && mode !== 'removal') throw new Error('unknown compatibility mode');

const operation = deprecated ? 'ADDED' : 'MODIFIED';
// Keep the scenario identity stable across the ADDED -> MODIFIED lifecycle.
// OpenSpec strict validation treats replacing a scenario name as an implicit
// deletion, which is not a valid MODIFIED delta.
const scenario = 'Legacy migration state is observable';
const roles = deprecated
  ? ['old_consumer', 'replacement_consumer']
  : ['old_consumer', 'replacement_consumer', 'absence_probe'];
const surfaceId = deprecated ? 'surface-deprecated-legacy-cli' : 'surface-removed-legacy-cli';
const probe = deprecated ? 'tests/deprecation_probe.sh' : 'tests/removal_probe.sh';
const requirement = 'Legacy CLI migration window';
const roleLabel = role => role.replaceAll('_', '-');

const proposal = deprecated ? `## Why

The legacy CLI must remain usable for one explicit migration window while directing callers to its replacement.

## What Changes

- Keep \`--legacy\` working and emit an observable deprecation signal.
- Add the replacement \`--current\` entrypoint.
- Verify both consumers through one exact runtime probe.
- External contract impact: **deprecation**.

## Capabilities

### New Capabilities

- \`cli-compatibility\`: Defines the observable legacy migration window.

### Modified Capabilities

- None.

## Impact

The existing executable is reused; no target or dependency is added.
` : `## Why

The approved migration window has ended, so the legacy CLI must be unreachable while the replacement remains available.

## What Changes

- Remove the \`--legacy\` entrypoint.
- Preserve \`--current\` as the supported replacement.
- Prove the approved legacy failure, help-surface absence, and replacement success.
- External contract impact: **removal**.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- \`cli-compatibility\`: Ends the legacy migration window and retains the replacement.

## Impact

The existing executable is reused; no target or dependency is added.
`;

const requirementBody = deprecated
  ? `The CLI SHALL keep \`--legacy\` successful with a visible deprecation signal and SHALL provide the successful \`--current\` replacement.

#### Scenario: ${scenario}
- **WHEN** old and replacement consumers invoke a freshly built CLI
- **THEN** the old consumer succeeds and emits \`DEPRECATED: --legacy; use --current\`, while the replacement prints \`value:42\``
  : `The CLI SHALL reject \`--legacy\` with exit code 64, omit it from runtime help, and SHALL keep \`--current\` successful.

#### Scenario: ${scenario}
- **WHEN** old, absence, and replacement probes invoke a freshly built CLI
- **THEN** the old consumer is rejected, help cannot reach the old entrypoint, and the replacement prints \`value:42\``;
const spec = `## ${operation} Requirements

### Requirement: ${requirement}
${requirementBody}
`;
const tasks = `## 1. CLI compatibility lifecycle

- [ ] 1 ${deprecated ? 'Deprecate the legacy CLI and connect its replacement' : 'Remove the legacy CLI and preserve its replacement'}
  - Covers: \`specs/cli-compatibility/spec.md\` | \`${operation}\` | \`${requirement}\` | \`${scenario}\`
  - Verify: \`behavior\`
`;

const budget = {
  schema_version: 1,
  profile: 'small',
  rationale: 'Modify one existing CLI source and add one focused compatibility probe without adding a target or dependency.',
  classification: {
    production: ['src/**'], tests: ['tests/**'], project_docs: ['README.md'],
    project_tooling: ['CMakeLists.txt'], examples: ['examples/**'], generated: [], vendor: ['vendor/**']
  },
  thresholds: {
    production: {
      added_lines: {expected: 28, review_at: 45, hard_limit: 70},
      touched_files: {expected: 1, review_at: 2, hard_limit: 3},
      new_files: {expected: 0, review_at: 1, hard_limit: 2}
    },
    tests: {
      added_lines: {expected: 55, review_at: 80, hard_limit: 120},
      touched_files: {expected: 1, review_at: 2, hard_limit: 3},
      new_files: {expected: 1, review_at: 2, hard_limit: 3}
    },
    project_support: {
      added_lines: {expected: 0, review_at: 4, hard_limit: 8},
      new_files: {expected: 0, review_at: 1, hard_limit: 2}
    },
    generated: {
      files: {expected: 0, review_at: 1, hard_limit: 2},
      bytes: {expected: 0, review_at: 1024, hard_limit: 4096}
    }
  },
  structural_allowances: {public_contracts: [], cmake_targets: [], direct_dependencies: []},
  reuse_decisions: [], obsolete_items: [], exceptions: []
};

const requirementRef = {
  operation, requirement, scenarios: [scenario], spec_path: 'specs/cli-compatibility/spec.md'
};
const surface = {
  change_kind: deprecated ? 'deprecated' : 'removed',
  compatibility: {
    old_consumer_paths: ['tests/legacy_cli_consumer.sh'],
    replacement_consumer_paths: ['tests/current_cli_consumer.sh'],
    replacement_policy: 'required',
    expected_old_result: deprecated
      ? 'The old consumer exits successfully and emits the approved deprecation signal.'
      : 'The old consumer exits 64 with the approved unknown-option diagnostic.',
    migration_path: 'Replace --legacy with --current while preserving the same value result.',
    exit_condition: deprecated
      ? 'Remove --legacy only in a separately approved removal change.'
      : 'Keep the absence probe and replacement runtime probe green.'
  },
  consumer_kind: deprecated ? 'real_entrypoint' : 'compatibility_probe',
  consumer_paths: [deprecated ? 'src/main.cpp' : 'tests/legacy_cli_consumer.sh'],
  contract_impact: deprecated ? 'deprecation' : 'removal',
  entrypoint: deprecated ? 'compat_cli legacy and current process entrypoints' : 'compat_cli runtime compatibility probe',
  evidence_contracts: roles.map(role => ({
    argv: [probe],
    expected_exit_codes: [0],
    kind: 'behavior',
    output_contains: `${mode}-${roleLabel(role)}-ok`,
    probe_id: `probe-${mode}-behavior-${roleLabel(role)}`,
    role
  })),
  expected_observation: deprecated
    ? 'The old CLI succeeds with a visible warning and the replacement succeeds with the same value.'
    : 'The old CLI fails exactly as approved, runtime help omits it, and the replacement succeeds.',
  id: surfaceId,
  kind: 'cli',
  name: deprecated ? 'deprecated legacy CLI entrypoint' : 'removed legacy CLI entrypoint',
  producer_paths: ['src/main.cpp'],
  requirement_refs: [requirementRef],
  symbol_identities: null,
  task_ids: ['1'],
  task_obligations: [{evidence_roles: roles, task_id: '1', verify_kinds: ['behavior']}],
  verify_kinds: ['behavior']
};
const integration = {
  discovery: {compile_commands_path: null, mode: 'reviewed_inventory'},
  schema_version: 1,
  surfaces: [surface]
};
const design = `## Context

This change exercises one explicit ${mode} phase against a real C++ CLI and real consumer processes.

## Goals / Non-Goals

**Goals:** Prove every required compatibility role through exact runtime evidence.

**Non-Goals:** Add targets, dependencies, implicit migration, or a second verdict.

## Decisions

Use one combined clean-build probe whose role-specific markers cannot pass unless every planned consumer condition is observed.

## Risks / Trade-offs

The compatibility probe is intentionally strict about exit codes, stderr, help output, and replacement behavior.

<!-- autoai:tdd-policy:v1 -->
\`\`\`json
${JSON.stringify({schema_version: 1, default: 'required', exceptions: []}, null, 2)}
\`\`\`
<!-- /autoai:tdd-policy:v1 -->

<!-- autoai:implementation-economy:v1 -->
\`\`\`json
${JSON.stringify(budget, null, 2)}
\`\`\`
<!-- /autoai:implementation-economy:v1 -->

<!-- autoai:integration-completeness:v1 -->
\`\`\`json
${JSON.stringify(integration, null, 2)}
\`\`\`
<!-- /autoai:integration-completeness:v1 -->
`;

fs.writeFileSync(path.join(changeDir, 'proposal.md'), proposal);
fs.writeFileSync(path.join(changeDir, 'design.md'), design);
fs.writeFileSync(path.join(changeDir, 'tasks.md'), tasks);
fs.writeFileSync(path.join(changeDir, 'specs/cli-compatibility/spec.md'), spec);
NODE
}

write_probe() {
    local mode=$1
    if [[ "$mode" == deprecation ]]; then
        cat > "$repo/tests/deprecation_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -u
fail() { echo deprecation-probe-red; exit 1; }
rm -rf -- build/deprecation-probe
cmake -S . -B build/deprecation-probe >/dev/null 2>&1 || fail
cmake --build build/deprecation-probe --target compat_cli --parallel 2 >/dev/null 2>&1 || fail
binary=build/deprecation-probe/compat_cli
legacy_stderr=build/deprecation-probe/legacy.stderr
legacy_output=$(tests/legacy_cli_consumer.sh "$binary" 2>"$legacy_stderr") || fail
[[ "$legacy_output" == value:42 ]] || fail
grep -Fxq 'DEPRECATED: --legacy; use --current' "$legacy_stderr" || fail
current_output=$(tests/current_cli_consumer.sh "$binary" 2>/dev/null) || fail
[[ "$current_output" == value:42 ]] || fail
echo deprecation-old-consumer-ok
echo deprecation-replacement-consumer-ok
EOF
        chmod 755 "$repo/tests/deprecation_probe.sh"
    else
        cat > "$repo/tests/removal_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -u
fail() { echo removal-probe-red; exit 1; }
rm -rf -- build/removal-probe
cmake -S . -B build/removal-probe >/dev/null 2>&1 || fail
cmake --build build/removal-probe --target compat_cli --parallel 2 >/dev/null 2>&1 || fail
binary=build/removal-probe/compat_cli
legacy_stdout=build/removal-probe/legacy.stdout
legacy_stderr=build/removal-probe/legacy.stderr
set +e
tests/legacy_cli_consumer.sh "$binary" >"$legacy_stdout" 2>"$legacy_stderr"
legacy_status=$?
set -e
[[ "$legacy_status" -eq 64 && ! -s "$legacy_stdout" ]] || fail
grep -Fxq 'unknown option: --legacy' "$legacy_stderr" || fail
help_output=$($binary --help 2>/dev/null) || fail
[[ "$help_output" == *--current* && "$help_output" != *--legacy* ]] || fail
current_output=$(tests/current_cli_consumer.sh "$binary" 2>/dev/null) || fail
[[ "$current_output" == value:42 ]] || fail
echo removal-old-consumer-ok
echo removal-replacement-consumer-ok
echo removal-absence-probe-ok
EOF
        chmod 755 "$repo/tests/removal_probe.sh"
    fi
}

write_cli_implementation() {
    local mode=$1
    if [[ "$mode" == deprecation ]]; then
        cat > "$repo/src/main.cpp" <<'EOF'
#include <iostream>
#include <string_view>

int main(int argc, char** argv) {
    const std::string_view option = argc > 1 ? argv[1] : "--help";
    if (option == "--legacy") {
        std::cerr << "DEPRECATED: --legacy; use --current\n";
        std::cout << "value:42\n";
        return 0;
    }
    if (option == "--current") {
        std::cout << "value:42\n";
        return 0;
    }
    if (option == "--help") {
        std::cout << "--legacy (deprecated)\n--current\n";
        return 0;
    }
    std::cerr << "unknown option: " << option << '\n';
    return 64;
}
EOF
    else
        cat > "$repo/src/main.cpp" <<'EOF'
#include <iostream>
#include <string_view>

int main(int argc, char** argv) {
    const std::string_view option = argc > 1 ? argv[1] : "--help";
    if (option == "--current") {
        std::cout << "value:42\n";
        return 0;
    }
    if (option == "--help") {
        std::cout << "--current\n";
        return 0;
    }
    std::cerr << "unknown option: " << option << '\n';
    return 64;
}
EOF
    fi
}

write_pass_evaluation() {
    local change=$1 mode=$2 surface_id=$3 probe=$4 roles_csv=$5 operation=$6 scenario=$7 consumer_kind=$8
    local harness_dir="$repo/openspec/changes/$change/harness"
    (
        cd "$repo"
        node - "$harness_dir/evaluation-baseline.json" "$harness_dir/change-footprint.json" \
            "$harness_dir/evaluation-command-ledger.json" "$harness_dir/integration-surface-report.json" \
            "$harness_dir/evaluation.json" "$change" "$mode" "$surface_id" "$probe" \
            "$roles_csv" "$operation" "$scenario" "$consumer_kind" <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const [baselineFile, footprintFile, ledgerFile, reportFile, outputFile, change, mode,
  surfaceId, probe, rolesCsv, operation, scenario, consumerKind] = process.argv.slice(2);
const roles = rolesCsv.split(',');
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const footprint = JSON.parse(fs.readFileSync(footprintFile));
const ledger = JSON.parse(fs.readFileSync(ledgerFile));
const report = JSON.parse(fs.readFileSync(reportFile));
const commands = [...ledger.commands];
if (baseline.schema_version !== 3 || ledger.schema_version !== 2 || commands.length !== 1 ||
    commands[0].result !== 'Pass' || commands[0].argv.join('\0') !== probe ||
    commands[0].surface_probe_bindings.map(item => item.role).join(',') !== rolesCsv) {
  throw new Error(`${mode} independent exact probe ledger is incomplete`);
}
if (footprint.status !== 'within_expected' || footprint.structural_candidates.length !== 0) {
  throw new Error(`${mode} implementation economy is not within its closed budget`);
}

const policy = require(process.cwd() + '/scripts/manifest_policy.js').loadManifest();
const base = baseline.review_input.implementation_base_commit;
const changed = cp.execFileSync('git', ['diff', '--name-only', '-z', base, '--'])
  .toString('utf8').split('\0');
const untracked = cp.execFileSync('git', ['ls-files', '--others', '--exclude-standard', '-z'])
  .toString('utf8').split('\0');
const implementationPaths = [...new Set([...changed, ...untracked].filter(Boolean))]
  .filter(item => !policy.isManaged(item)).sort();
if (JSON.stringify(implementationPaths) !== JSON.stringify(['src/main.cpp', probe])) {
  throw new Error(`${mode} implementation path inventory drifted: ${JSON.stringify(implementationPaths)}`);
}

const commandIds = commands.map(command => command.id);
const finished = Math.max(Date.parse(baseline.started_at), ...commands.map(command => Date.parse(command.finished_at)));
const reviewedAt = new Date(finished).toISOString();
const evaluatedAt = new Date(Math.max(Date.now(), finished)).toISOString();
const requirementRef = {
  spec_path: 'specs/cli-compatibility/spec.md', operation,
  requirement: 'Legacy CLI migration window', scenarios: [scenario]
};
const reviewStage = (name, startedAt, completedAt, dimensions) => ({
  name, started_at: startedAt, completed_at: completedAt, status: 'Pass',
  requirement_refs: [requirementRef], task_ids: ['1'],
  reviewed_paths: baseline.review_input.review_paths, dimensions,
  evidence_command_ids: commandIds, finding_ids: [], blocking_untested_ids: [],
  not_run_reason: null
});
const reportBinding = report.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
if (!reportBinding) throw new Error(`${mode} surface report binding missing`);
const typed = new Map();
for (const item of reportBinding.candidate_bindings) {
  const values = typed.get(item.candidate_id) || [];
  values.push(item.role);
  typed.set(item.candidate_id, values);
}
const allCandidates = [...report.path_candidates, ...report.structural_candidates, ...report.ast_candidates];
const candidateAssessments = allCandidates.map(candidate => {
  const candidateRoles = [...new Set(typed.get(candidate.candidate_id) || [])]
    .sort((a, b) => ['producer', 'consumer'].indexOf(a) - ['producer', 'consumer'].indexOf(b));
  if (!candidateRoles.length) throw new Error(`${mode} report has an unbound candidate`);
  const paths = [...new Set([candidate.old_path, candidate.path].filter(Boolean))].sort();
  return {
    candidate_id: candidate.candidate_id,
    source: candidate.source,
    disposition: 'mapped',
    surface_ids: [surfaceId],
    surface_bindings: [{
      surface_id: surfaceId,
      candidate_roles: candidateRoles,
      consumer_kind: consumerKind,
      consumer_paths: reportBinding.consumer_paths
    }],
    reason: `The changed CLI candidate is mapped to the approved ${mode} surface.`,
    producer_paths: candidateRoles.includes('producer')
      ? paths.filter(item => reportBinding.producer_paths.includes(item)) : [],
    implementation_consumer: null,
    evidence_paths: paths,
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
      reason: 'The CLI source and focused compatibility probe match their approved classifications.',
      evidence_paths: implementationPaths,
      evidence_command_ids: commandIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets', applicability: 'applicable', result: 'Pass',
          reason: `The existing CLI target passes the complete ${mode} compatibility probe.`,
          evidence_paths: report.changed_production_paths, evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'not_applicable', result: null,
          reason: 'This CLI fixture has no install surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'The approved implementation base defines no install rule.'
        },
        {
          surface: 'package', applicability: 'not_applicable', result: null,
          reason: 'This CLI fixture has no package surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'The approved implementation base defines no package export.'
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'This disposable fixture has no CI configuration.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI file exists in the approved implementation base.'
        }
      ]
    },
    reuse_assessments: [], structural_assessments: [], obsolete_item_assessments: [],
    exception_assessments: [], result: 'Pass'
  },
  criteria: [{
    id: `criterion-${mode}-compatibility`,
    description: `The real CLI satisfies every approved ${mode} compatibility role.`,
    requirement_refs: [requirementRef], task_ids: ['1'], status: 'Pass',
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
      reason: `The complete CLI diff was independently reviewed for ${mode}.`,
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    candidate_assessments: candidateAssessments,
    surface_assessments: [{
      surface_id: surfaceId,
      result: 'Pass',
      reason: `The exact runtime probe closes every required ${mode} compatibility role.`,
      consumer_paths: reportBinding.consumer_paths,
      old_consumer_paths: reportBinding.old_consumer_paths,
      replacement_consumer_paths: reportBinding.replacement_consumer_paths,
      kind_evidence: [{kind: 'behavior', evidence_command_ids: commandIds}],
      role_evidence: roles.map(role => ({role, evidence_command_ids: commandIds})),
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
    )
}

run_compatibility_change() {
    local change=$1 mode=$2
    local surface_id probe roles_csv operation scenario consumer_kind
    if [[ "$mode" == deprecation ]]; then
        surface_id=surface-deprecated-legacy-cli
        probe=tests/deprecation_probe.sh
        roles_csv=old_consumer,replacement_consumer
        operation=ADDED
        scenario='Legacy migration state is observable'
        consumer_kind=real_entrypoint
    else
        surface_id=surface-removed-legacy-cli
        probe=tests/removal_probe.sh
        roles_csv=old_consumer,replacement_consumer,absence_probe
        operation=MODIFIED
        scenario='Legacy migration state is observable'
        consumer_kind=compatibility_probe
    fi
    local change_dir="$repo/openspec/changes/$change"
    local harness_dir="$change_dir/harness"
    local role_args=()
    local role
    IFS=, read -r -a role_values <<< "$roles_csv"
    for role in "${role_values[@]}"; do
        role_args+=(--surface-role "$surface_id=$role")
    done

    write_probe "$mode"
    run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
    assert_status 0
    run_managed_at "$repo" scripts/task_verify.sh 1 \
        --phase red --cycle "cli-$mode" --kind behavior --expect-exit 1 \
        --path "$probe" --test-path "$probe" --failure-class behavior \
        --expected-failure "the baseline CLI does not yet satisfy the approved $mode behavior" \
        --match-output "$mode-probe-red" \
        --observed "the real baseline process exposed the planned $mode gap" -- \
        "$probe"
    assert_status 0

    write_cli_implementation "$mode"
    run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
    assert_status 0
    run_managed_at "$repo" scripts/task_verify.sh 1 \
        --phase green --cycle "cli-$mode" --kind behavior \
        --path src/main.cpp --path "$probe" -- "$probe"
    assert_status 0
    run_managed_at "$repo" scripts/task_verify.sh 1 \
        --phase regression --cycle "cli-$mode" --kind behavior \
        "${role_args[@]}" --path src/main.cpp --path "$probe" \
        --observed "the exact runtime probe closed every planned $mode compatibility role" -- \
        "$probe"
    assert_status 0
    for role in "${role_values[@]}"; do
        assert_contains "$RUN_OUTPUT" "$mode-${role//_/-}-ok"
    done
    run_managed_at "$repo" scripts/task_verify.sh --complete 1
    assert_status 0

    node - "$harness_dir/verification.json" "$surface_id" "$roles_csv" "$probe" <<'NODE'
const fs = require('fs');
const [file, surfaceId, rolesCsv, probe] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file));
const task = value.tasks.find(item => item.task_id === '1');
const regression = task?.commands.find(item => item.phase === 'REGRESSION');
if (value.schema_version !== 3 || !task || task.commands.length !== 3 ||
    regression?.argv.join('\0') !== probe ||
    regression?.surface_probe_bindings.map(item => item.role).join(',') !== rolesCsv ||
    regression?.surface_probe_bindings.some(item => item.surface_id !== surfaceId)) {
  throw new Error('Generator compatibility probe bindings are incomplete');
}
NODE

    run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --refresh --json
    assert_status 0
    local report="$harness_dir/integration-surface-report.json"
    node - "$report" "$surface_id" <<'NODE'
const fs = require('fs');
const [file, surfaceId] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(file));
const binding = report.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
if (report.schema_version !== 1 || report.status !== 'complete' ||
    report.unmatched_candidates.length !== 0 ||
    report.changed_production_paths.join(',') !== 'src/main.cpp' ||
    !binding?.candidate_bindings.some(item => item.role === 'producer')) {
  throw new Error('compatibility surface report is not closed');
}
NODE

    run_managed_at "$repo" scripts/evaluator_check.sh --begin "$change"
    assert_status 0
    run_managed_at "$repo" scripts/evaluator_check.sh --run \
        --kind behavior "${role_args[@]}" \
        --expected "A clean real CLI run satisfies every planned $mode compatibility role." \
        --observed "The independent exact probe observed all role-specific $mode markers." -- \
        "$probe"
    assert_status 0
    for role in "${role_values[@]}"; do
        assert_contains "$RUN_OUTPUT" "$mode-${role//_/-}-ok"
    done

    write_pass_evaluation "$change" "$mode" "$surface_id" "$probe" "$roles_csv" \
        "$operation" "$scenario" "$consumer_kind"
    run_managed_at "$repo" scripts/evaluator_check.sh --finish "$change"
    assert_status 0
    run_managed_at "$repo" scripts/change_archive.sh "$change"
    assert_status 0

    local archived_as="$(date -u +%Y-%m-%d)-$change"
    local archived_dir="$repo/openspec/changes/archive/$archived_as"
    assert_path_absent "$change_dir"
    assert_path_exists "$archived_dir/harness/integration-surface-report.json"
    assert_path_exists "$archived_dir/harness/evaluation.json"
    node - "$repo/ai_snapshot.json" "$archived_dir/harness/evaluation.json" \
        "$change" "$archived_as" "$roles_csv" <<'NODE'
const fs = require('fs');
const [rootFile, evaluationFile, change, archivedAs, rolesCsv] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(rootFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
const roles = evaluation.integration_completeness.surface_assessments[0].role_evidence
  .map(item => item.role).join(',');
if (root.active_change !== null || root.last_archived_change?.change_name !== change ||
    root.last_archived_change?.archived_as !== archivedAs || evaluation.verdict !== 'Pass' ||
    evaluation.integration_completeness?.result !== 'Pass' || roles !== rolesCsv) {
  throw new Error('archived compatibility state is incomplete');
}
NODE
}

prepare_change() {
    local change=$1 mode=$2
    (
        cd "$repo"
        scripts/change_new.sh "$change" >/dev/null
    )
    write_change_plan "$change" "$mode"
    (
        cd "$repo"
        scripts/integration_surface_check.sh "$change" --plan-check --json >/dev/null
        scripts/openspec_cli.sh validate "$change" --type change --strict --json > "$tmp/$mode-strict-plan.json"
        git add -A
        git commit -qm "approved $mode compatibility baseline"
        scripts/snapshot_update.sh --freeze-planning-baseline >/dev/null
        scripts/snapshot_update.sh --freeze-implementation-base >/dev/null
    )
}

note '生成真实 Harness，并验证初始 legacy CLI 基线'
run_setup "$repo"
assert_status 0
git -C "$repo" config user.name 'AutoAI Real Compatibility Test'
git -C "$repo" config user.email 'autoai-real-compatibility@example.invalid'
cmake -S "$repo" -B "$repo/build/initial" >/dev/null
cmake --build "$repo/build/initial" --parallel 2 >/dev/null
test "$("$repo/tests/legacy_cli_consumer.sh" "$repo/build/initial/compat_cli")" = value:42

deprecation_change=deprecate-legacy-cli
note '第一阶段：旧消费者继续成功并发出弃用信号，replacement 同时成功'
prepare_change "$deprecation_change" deprecation
run_compatibility_change "$deprecation_change" deprecation
assert_path_exists "$repo/openspec/specs/cli-compatibility/spec.md"

note '把已归档 deprecation 状态提交为 removal 的独立实现基线'
git -C "$repo" add -A
git -C "$repo" commit -qm 'archived deprecation compatibility baseline'

removal_change=remove-legacy-cli
note '第二阶段：旧消费者按批准方式失败，absence probe 与 replacement 同时闭合'
prepare_change "$removal_change" removal
run_compatibility_change "$removal_change" removal

node - "$repo/openspec/specs/cli-compatibility/spec.md" <<'NODE'
const fs = require('fs');
const text = fs.readFileSync(process.argv[2], 'utf8');
if (!text.includes('reject `--legacy` with exit code 64') ||
    !text.includes('omit it from runtime help') || !text.includes('keep `--current` successful')) {
  throw new Error('archived main spec does not retain the approved removal contract');
}
NODE

note '真实 CLI deprecation → removal 的多角色 exact-probe、独立 Evaluation 和双 archive 生命周期通过'
