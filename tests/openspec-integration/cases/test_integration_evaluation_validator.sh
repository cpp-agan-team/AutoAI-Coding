#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/integration evaluation validator"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
export PATH="$runtime_bin:$REAL_TEST_PATH"
mkdir -p "$repo/src"
printf 'int api() { return 7; }\n' > "$repo/src/api.cpp"
printf 'int api(); int main() { return api() == 7 ? 0 : 1; }\n' > "$repo/src/caller.cpp"
printf 'int main() { return 0; }\n' > "$repo/src/old_consumer.cpp"
printf 'int main() { return 0; }\n' > "$repo/src/replacement_consumer.cpp"
printf '// reviewed formatting-only change\n' > "$repo/src/unplanned.cpp"
mkdir -p "$repo/include"
printf 'int accidental_public_api();\n' > "$repo/include/unplanned.hpp"
mkdir -p "$repo/tests"
printf 'int test_helper();\n' > "$repo/tests/helper.hpp"

note 'Evaluation v3 纯校验器接受摘要、ledger、candidate、surface 和命令消费完整闭合的 Pass'
(
    cd "$repo"
    node <<'NODE'
const lib = require('./scripts/integration_surface_lib.js');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const zero = 'sha256:' + '0'.repeat(64), one = 'sha256:' + '1'.repeat(64);
const surface = {
  id: 'surface-api', kind: 'internal_api', name: 'api()', consumer_kind: 'production_caller',
  consumer_paths: ['src/caller.cpp'], producer_paths: ['src/api.cpp'], compatibility: null,
  verify_kinds: ['behavior'], contract_impact: 'compatible',
  evidence_contracts: [{probe_id: 'probe-api-current', kind: 'behavior', role: 'current', argv: ['tests/api'], expected_exit_codes: [0], output_contains: 'api returned 7'}]
};
function makePlan(mode = 'reviewed_inventory') {
  const plannedSurface = structuredClone(surface);
  const block = {discovery: {mode, compile_commands_path: mode === 'clang_ast' ? 'compile_commands.json' : null}, schema_version: 1, surfaces: [plannedSurface]};
  return {block, block_sha256: one, surfaces: new Map([[plannedSurface.id, plannedSurface]])};
}
function makeReport(plan) {
  return {
    schema_version: 1, change_name: 'eval-integration', implementation_base_commit: 'a'.repeat(40),
    discovery_mode: plan.block.discovery.mode, source_fingerprint: zero, planning_block_sha256: plan.block_sha256,
    change_footprint_json_sha256: zero,
    scope_classifier_identity: {schema_version: 1, path: 'scripts/change_scope.js', sha256: zero, output_sha256: zero},
    discovery_adapter_identity: {id: 'reviewed-inventory-v1', schema_version: 1, sha256: zero},
    compile_commands_sha256: null, ast_tool_identity: null,
    planned_surface_ids: ['surface-api'], changed_production_paths: ['src/api.cpp'],
    path_candidates: [{candidate_id: 'path-candidate-api', source: 'path', path: 'src/api.cpp', old_path: null, change_status: 'modified'}],
    structural_candidates: [], ast_candidates: [],
    surface_candidate_bindings: [{surface_id: 'surface-api', candidate_bindings: [{candidate_id: 'path-candidate-api', role: 'producer', tree_side: 'both'}], producer_paths: ['src/api.cpp'], consumer_paths: ['src/caller.cpp'], old_consumer_paths: [], replacement_consumer_paths: []}],
    unmatched_candidates: [], status: 'complete'
  };
}
function makeCommand(id = 'eval-cmd-1') {
  return {id, kind: 'behavior', argv: ['tests/api'], command: 'tests/api', working_directory: '.', started_at: '2026-01-01T00:00:01Z', finished_at: '2026-01-01T00:00:02Z', expected_exit_codes: [0], exit_code: 0, expected: 'api exits successfully', observed: 'api returned 7', result: 'Pass', output_sha256: zero, surface_ids: ['surface-api'], surface_evidence_roles: [{surface_id: 'surface-api', role: 'current'}], surface_probe_bindings: [{surface_id: 'surface-api', role: 'current', probe_id: 'probe-api-current'}]};
}
function makeFixture(mode = 'reviewed_inventory') {
  const plan = makePlan(mode), report = makeReport(plan), command = makeCommand();
  const reportSha = lib.sha(lib.reportBytes(report)), discoverySha = lib.discoveryIdentity(report);
  const reviewInput = {review_paths: ['src/api.cpp', 'src/caller.cpp']};
  const baseline = {schema_version: 3, evaluation_id: 'eval-20260101T000000Z-abcdef', change_name: 'eval-integration', status: 'in_progress', started_at: '2026-01-01T00:00:00Z', source_fingerprint: zero, artifact_fingerprint: zero, base_specs_fingerprint: zero, verification_json_sha256: zero, budget_block_sha256: zero, change_footprint_json_sha256: zero, review_input: reviewInput, integration_planning_block_sha256: plan.block_sha256, integration_surface_report_sha256: reportSha, integration_discovery_identity_sha256: discoverySha};
  const integration = {
    planning_block_sha256: plan.block_sha256, report_sha256: reportSha, discovery_identity_sha256: discoverySha,
    inventory_assessment: {result: 'Pass', reason: 'The complete product diff was reviewed.', evidence_paths: ['src/api.cpp'], evidence_command_ids: []},
    candidate_assessments: [{candidate_id: 'path-candidate-api', source: 'path', disposition: 'mapped', surface_ids: ['surface-api'], surface_bindings: [{surface_id: 'surface-api', candidate_roles: ['producer'], consumer_kind: 'production_caller', consumer_paths: ['src/caller.cpp']}], reason: 'The changed implementation belongs to the approved API surface.', producer_paths: ['src/api.cpp'], implementation_consumer: null, evidence_paths: ['src/api.cpp'], evidence_command_ids: [], orphan_ids: []}],
    surface_assessments: [{surface_id: 'surface-api', result: 'Pass', reason: 'The independent command observes the production surface.', consumer_paths: ['src/caller.cpp'], old_consumer_paths: [], replacement_consumer_paths: [], kind_evidence: [{kind: 'behavior', evidence_command_ids: ['eval-cmd-1']}], role_evidence: [{role: 'current', evidence_command_ids: ['eval-cmd-1']}], evidence_command_ids: ['eval-cmd-1'], blocking_untested_ids: [], orphan_ids: []}],
    orphan_surfaces: [], result: 'Pass'
  };
  const evaluation = {schema_version: 3, evaluation_id: baseline.evaluation_id, change_name: 'eval-integration', verdict: 'Pass', evaluation_started_at: baseline.started_at, evaluated_at: '2026-01-01T00:00:03Z', openspec_version: '1.6.0', evaluator_role: 'independent', input_source_fingerprint: zero, input_artifact_fingerprint: zero, input_base_specs_fingerprint: zero, source_fingerprint: zero, artifact_fingerprint: zero, base_specs_fingerprint: zero, budget_block_sha256: zero, change_footprint_json_sha256: zero, review_input: reviewInput, change_review: {stages: [{name: 'specification_compliance', status: 'Pass'}, {name: 'code_quality', status: 'Pass'}], findings: []}, implementation_economy: {result: 'Pass'}, criteria: [{status: 'Pass'}], commands: [command], blocking_untested: [], residual_risks: [], integration_completeness: integration};
  const ledger = {schema_version: 2, evaluation_id: baseline.evaluation_id, change_name: 'eval-integration', commands: [command]};
  return {root: process.cwd(), change: 'eval-integration', plan, report, baseline, evaluation, ledger};
}
function rejects(mutate, pattern) {
  const fixture = makeFixture(); mutate(fixture);
  try { lib.validateEvaluationV3(fixture); } catch (error) { if (pattern.test(error.message)) return; throw error; }
  throw new Error('invalid Evaluation v3 fixture was accepted');
}

const valid = makeFixture(), checked = lib.validateEvaluationV3(valid);
if (checked.result !== 'Pass' || checked.surface_bound_command_ids.join(',') !== 'eval-cmd-1') throw new Error('valid Integration Evaluation did not close');

rejects(f => { f.evaluation.integration_completeness.allow_orphans = true; }, /schema mismatch|unknown field/);
rejects(f => { f.evaluation.integration_completeness.surface_assessments[0].role_evidence = []; }, /roles.*coverage|surface command union/);
rejects(f => {
  const extra = makeCommand('eval-cmd-2'); f.ledger.commands.push(extra); f.evaluation.commands.push(extra);
}, /not consumed/);
rejects(f => {
  const failed = {...makeCommand('eval-cmd-failed'), exit_code: 9, result: 'Fail', surface_ids: [], surface_evidence_roles: [], surface_probe_bindings: []};
  f.ledger.commands.push(failed); f.evaluation.commands.push(failed);
  f.evaluation.integration_completeness.candidate_assessments[0].evidence_command_ids = [failed.id];
}, /candidate assessment cannot consume a failed command/);
rejects(f => { f.ledger.commands[0].argv = ['true']; }, /approved probe contract/);
rejects(f => { f.ledger.commands[0].expected_exit_codes = [7]; f.ledger.commands[0].exit_code = 7; }, /approved probe contract/);
rejects(f => { f.ledger.commands[0].surface_probe_bindings[0].probe_id = 'probe-self-reported-pass'; }, /approved probe contract|noncanonical/);
rejects(f => { f.ledger.commands[0].surface_probe_bindings[0].self_reported_pass = true; }, /approved probe contract|noncanonical/);

const outside = fs.mkdtempSync(path.join(path.dirname(process.cwd()), 'outside-consumer-'));
fs.writeFileSync(path.join(outside, 'caller.cpp'), 'int caller() { return 0; }\n');
fs.symlinkSync(outside, 'linked-consumer', 'dir');
if (!lib.currentRegularFile(process.cwd(), 'src/caller.cpp') || lib.currentRegularFile(process.cwd(), 'linked-consumer/caller.cpp')) {
  throw new Error('ancestor symlink escaped the current regular-file policy');
}
const fakeConsumer = makeFixture();
fakeConsumer.plan.block.surfaces[0].consumer_paths = ['linked-consumer/caller.cpp'];
fakeConsumer.report.surface_candidate_bindings[0].consumer_paths = ['linked-consumer/caller.cpp'];
fakeConsumer.baseline.review_input.review_paths.push('linked-consumer/caller.cpp');
fakeConsumer.evaluation.integration_completeness.candidate_assessments[0].surface_bindings[0].consumer_paths = ['linked-consumer/caller.cpp'];
fakeConsumer.evaluation.integration_completeness.surface_assessments[0].consumer_paths = ['linked-consumer/caller.cpp'];
fakeConsumer.baseline.integration_surface_report_sha256 = lib.sha(lib.reportBytes(fakeConsumer.report));
fakeConsumer.evaluation.integration_completeness.report_sha256 = fakeConsumer.baseline.integration_surface_report_sha256;
try { lib.validateEvaluationV3(fakeConsumer); throw new Error('ancestor-symlink consumer established a valid surface'); }
catch (error) { if (!/safe current regular file/.test(error.message)) throw error; }

const plannerBlocked = makeFixture();
plannerBlocked.evaluation.integration_completeness.orphan_surfaces = [{
  id: 'orphan-planning-mismatch', type: 'planned_surface', reason_code: 'planning_mismatch', mismatch_kind: 'wrong_requirement',
  candidate_ids: [], surface_id: 'surface-api', kind: 'internal_api', name: 'api()',
  producer_paths: ['src/api.cpp'], consumer_paths: ['src/caller.cpp'], reason: 'The implementation exposes a contract outside the approved requirement.',
  finding_id: 'finding-planning-mismatch', blocking_untested_ids: [], route: 'Planner'
}];
plannerBlocked.evaluation.integration_completeness.surface_assessments[0].result = 'Blocked';
plannerBlocked.evaluation.integration_completeness.surface_assessments[0].reason = 'Planner must resolve the requirement mismatch.';
plannerBlocked.evaluation.integration_completeness.surface_assessments[0].orphan_ids = ['orphan-planning-mismatch'];
plannerBlocked.evaluation.integration_completeness.result = 'Blocked';
plannerBlocked.evaluation.verdict = 'Blocked';
plannerBlocked.evaluation.change_review.stages = [{name: 'specification_compliance', status: 'Blocked'}, {name: 'code_quality', status: 'NotRun'}];
plannerBlocked.evaluation.change_review.findings = [{id: 'finding-planning-mismatch', stage: 'specification_compliance', category: 'specification', status: 'Open', severity: 'Important', return_to: 'Planner'}];
if (lib.validateEvaluationV3(plannerBlocked).result !== 'Blocked') throw new Error('Planner-routed Blocked Integration result was rejected');
plannerBlocked.ledger.commands[0].exit_code = 9;
plannerBlocked.ledger.commands[0].result = 'Fail';
try { lib.validateEvaluationV3(plannerBlocked); throw new Error('Blocked surface hid a failed command'); }
catch (error) { if (!/cannot hide a failed command/.test(error.message)) throw error; }

const environmentBlocked = makeFixture();
environmentBlocked.ledger.commands = [];
environmentBlocked.evaluation.commands = [];
environmentBlocked.evaluation.blocking_untested = [{
  id: 'lab-unavailable',
  requirement_refs: ['capability-api:scenario-api'],
  task_ids: ['1.1'],
  reason: 'The required target environment is unavailable.',
  required_evidence: ['Re-run the approved behavior probe on the target environment.']
}];
environmentBlocked.evaluation.integration_completeness.surface_assessments[0] = {
  surface_id: 'surface-api', result: 'Blocked',
  reason: 'Only the approved provisional alternative is available.',
  consumer_paths: ['src/caller.cpp'], old_consumer_paths: [], replacement_consumer_paths: [],
  kind_evidence: [], role_evidence: [], evidence_command_ids: [],
  blocking_untested_ids: ['lab-unavailable'], orphan_ids: ['orphan-lab-unavailable']
};
environmentBlocked.evaluation.integration_completeness.orphan_surfaces = [{
  id: 'orphan-lab-unavailable', type: 'planned_surface', reason_code: 'blocked_environment',
  mismatch_kind: null, candidate_ids: [], surface_id: 'surface-api', kind: 'internal_api', name: 'api()',
  producer_paths: ['src/api.cpp'], consumer_paths: ['src/caller.cpp'],
  reason: 'The approved target environment is unavailable.',
  finding_id: null, blocking_untested_ids: ['lab-unavailable'], route: 'Environment'
}];
environmentBlocked.evaluation.integration_completeness.result = 'Blocked';
environmentBlocked.evaluation.verdict = 'Blocked';
environmentBlocked.direct_closure = {
  source_fingerprint: zero,
  planning_block_sha256: environmentBlocked.plan.block_sha256,
  verified: [],
  provisionally_blocked: [{
    surface_id: 'surface-api', task_id: '1.1', kind: 'behavior',
    role: 'current', exception_id: 'lab-unavailable'
  }]
};
if (lib.validateEvaluationV3(environmentBlocked).result !== 'Blocked') {
  throw new Error('provisional Generator closure was not preserved as a Blocked Evaluation');
}
environmentBlocked.evaluation.verdict = 'Pass';
try { lib.validateEvaluationV3(environmentBlocked); throw new Error('provisional Generator closure escaped through a Pass verdict'); }
catch (error) { if (!/top-level verdict/.test(error.message)) throw error; }

const sameHeaderExtraSurface = makeFixture();
sameHeaderExtraSurface.plan.block.surfaces[0].producer_paths = ['include/unplanned.hpp'];
sameHeaderExtraSurface.report.changed_production_paths = ['include/unplanned.hpp'];
sameHeaderExtraSurface.report.path_candidates[0].path = 'include/unplanned.hpp';
sameHeaderExtraSurface.report.surface_candidate_bindings[0].producer_paths = ['include/unplanned.hpp'];
sameHeaderExtraSurface.baseline.review_input.review_paths = ['include/unplanned.hpp', 'src/caller.cpp'];
sameHeaderExtraSurface.evaluation.review_input = sameHeaderExtraSurface.baseline.review_input;
sameHeaderExtraSurface.evaluation.integration_completeness.inventory_assessment.evidence_paths = ['include/unplanned.hpp'];
sameHeaderExtraSurface.evaluation.integration_completeness.candidate_assessments[0].producer_paths = ['include/unplanned.hpp'];
sameHeaderExtraSurface.evaluation.integration_completeness.candidate_assessments[0].evidence_paths = ['include/unplanned.hpp'];
sameHeaderExtraSurface.evaluation.integration_completeness.candidate_assessments[0].orphan_ids = ['orphan-extra-overload'];
sameHeaderExtraSurface.evaluation.integration_completeness.orphan_surfaces = [{
  id: 'orphan-extra-overload', type: 'candidate', reason_code: 'unplanned_surface', mismatch_kind: null,
  candidate_ids: ['path-candidate-api'], surface_id: null, kind: 'internal_api', name: 'accidental_public_api()',
  producer_paths: ['include/unplanned.hpp'], consumer_paths: [],
  reason: 'The complete header diff contains an additional public declaration outside the approved surface.',
  finding_id: 'finding-extra-overload', blocking_untested_ids: [], route: 'Planner'
}];
sameHeaderExtraSurface.evaluation.integration_completeness.result = 'Blocked';
sameHeaderExtraSurface.evaluation.verdict = 'Blocked';
sameHeaderExtraSurface.evaluation.change_review.stages = [
  {name: 'specification_compliance', status: 'Blocked'},
  {name: 'code_quality', status: 'NotRun'}
];
sameHeaderExtraSurface.evaluation.change_review.findings = [{
  id: 'finding-extra-overload', stage: 'specification_compliance', category: 'specification',
  status: 'Open', severity: 'Important', return_to: 'Planner'
}];
sameHeaderExtraSurface.baseline.integration_surface_report_sha256 = lib.sha(lib.reportBytes(sameHeaderExtraSurface.report));
sameHeaderExtraSurface.evaluation.integration_completeness.report_sha256 = sameHeaderExtraSurface.baseline.integration_surface_report_sha256;
if (lib.validateEvaluationV3(sameHeaderExtraSurface).result !== 'Blocked') {
  throw new Error('reviewed coarse mapped header could not record an extra unplanned surface');
}

const diagonal = makeFixture(), diagonalSurface = diagonal.plan.block.surfaces[0];
diagonalSurface.contract_impact = 'breaking';
diagonalSurface.compatibility = {
  old_consumer_paths: ['src/old_consumer.cpp'],
  replacement_consumer_paths: ['src/replacement_consumer.cpp'],
  replacement_policy: 'required',
  expected_old_result: 'The old consumer is rejected.',
  migration_path: 'Use the replacement consumer.',
  exit_condition: 'Remove the compatibility fixture after the migration window.'
};
diagonalSurface.verify_kinds = ['behavior', 'static'];
diagonalSurface.evidence_contracts = [
  {probe_id: 'probe-api-behavior-old', kind: 'behavior', role: 'old_consumer', argv: ['tests/api', 'behavior-old'], expected_exit_codes: [0], output_contains: 'behavior-old-ok'},
  {probe_id: 'probe-api-behavior-replacement', kind: 'behavior', role: 'replacement_consumer', argv: ['tests/api', 'behavior-replacement'], expected_exit_codes: [0], output_contains: 'behavior-replacement-ok'},
  {probe_id: 'probe-api-static-old', kind: 'static', role: 'old_consumer', argv: ['tests/api', 'static-old'], expected_exit_codes: [0], output_contains: 'static-old-ok'},
  {probe_id: 'probe-api-static-replacement', kind: 'static', role: 'replacement_consumer', argv: ['tests/api', 'static-replacement'], expected_exit_codes: [0], output_contains: 'static-replacement-ok'}
];
diagonal.plan.surfaces.set(diagonalSurface.id, diagonalSurface);
diagonal.report.surface_candidate_bindings[0].old_consumer_paths = ['src/old_consumer.cpp'];
diagonal.report.surface_candidate_bindings[0].replacement_consumer_paths = ['src/replacement_consumer.cpp'];
const diagonalCommand = (id, kind, role, argv, probeId) => ({
  ...makeCommand(id), kind, argv, command: argv.join(' '),
  surface_evidence_roles: [{surface_id: 'surface-api', role}],
  surface_probe_bindings: [{surface_id: 'surface-api', role, probe_id: probeId}]
});
const behaviorOld = diagonalCommand('eval-cmd-behavior-old', 'behavior', 'old_consumer', ['tests/api', 'behavior-old'], 'probe-api-behavior-old');
const staticReplacement = diagonalCommand('eval-cmd-static-replacement', 'static', 'replacement_consumer', ['tests/api', 'static-replacement'], 'probe-api-static-replacement');
diagonal.ledger.commands = [behaviorOld, staticReplacement];
diagonal.evaluation.commands = [behaviorOld, staticReplacement];
const diagonalAssessment = diagonal.evaluation.integration_completeness.surface_assessments[0];
diagonalAssessment.old_consumer_paths = ['src/old_consumer.cpp'];
diagonalAssessment.replacement_consumer_paths = ['src/replacement_consumer.cpp'];
diagonalAssessment.kind_evidence = [
  {kind: 'behavior', evidence_command_ids: ['eval-cmd-behavior-old']},
  {kind: 'static', evidence_command_ids: ['eval-cmd-static-replacement']}
];
diagonalAssessment.role_evidence = [
  {role: 'old_consumer', evidence_command_ids: ['eval-cmd-behavior-old']},
  {role: 'replacement_consumer', evidence_command_ids: ['eval-cmd-static-replacement']}
];
diagonalAssessment.evidence_command_ids = ['eval-cmd-behavior-old', 'eval-cmd-static-replacement'];
diagonal.baseline.integration_surface_report_sha256 = lib.sha(lib.reportBytes(diagonal.report));
diagonal.evaluation.integration_completeness.report_sha256 = diagonal.baseline.integration_surface_report_sha256;
try { lib.validateEvaluationV3(diagonal); throw new Error('diagonal kind/role evidence matrix was accepted'); }
catch (error) { if (!/surface probe kind\/role matrix/.test(error.message)) throw error; }

const orphaned = makeFixture('clang_ast'), identity = {declaration_kind: 'function', qualified_name: 'future_api', canonical_parameter_types: [], canonical_return_type: 'int', template_parameter_kinds: [], cv_qualifiers: [], ref_qualifier: 'none', declaration_path: 'include/api.hpp'};
orphaned.classification = {
  production: ['include/**', 'src/**'], tests: ['tests/**'], project_docs: ['README.md'],
  project_tooling: ['CMakeLists.txt', 'compile_commands.json'], examples: ['examples/**'],
  generated: [], vendor: ['vendor/**']
};
const orphanCandidateId = 'clang-ast-' + crypto.createHash('sha256')
  .update('clang-ast-v1' + 'added' + lib.canonical(null) + lib.canonical(identity))
  .digest('hex').slice(0, 16);
orphaned.report.discovery_adapter_identity = {id: 'clang-ast-v1', schema_version: 1, sha256: zero};
orphaned.report.ast_tool_identity = {resolved_path: '/usr/bin/clang++', version_sha256: zero, capability_probe_sha256: zero};
orphaned.report.compile_commands_sha256 = zero;
orphaned.report.ast_candidates = [{candidate_id: orphanCandidateId, source: 'clang_ast', base_symbol_identity: null, current_symbol_identity: identity, candidate_scope: 'public_contract', base_access: null, current_access: 'public', base_linkage: null, current_linkage: 'external', change_status: 'added', base_semantic_sha256: null, current_semantic_sha256: zero}];
orphaned.report.unmatched_candidates = [{candidate_id: orphanCandidateId, source: 'clang_ast', reason: 'No approved public surface matches this declaration.'}];
orphaned.report.status = 'orphaned';
orphaned.baseline.integration_surface_report_sha256 = lib.sha(lib.reportBytes(orphaned.report));
orphaned.baseline.integration_discovery_identity_sha256 = lib.discoveryIdentity(orphaned.report);
try { lib.validateEvaluationV3(orphaned); throw new Error('orphaned report established an Evaluation attempt'); }
catch (error) { if (!/Planner diagnostics/.test(error.message)) throw error; }

const testHeaderScope = makeFixture('clang_ast');
const testIdentity = {...identity, qualified_name: 'test_helper', declaration_path: 'tests/helper.hpp'};
const testCandidateId = 'clang-ast-' + crypto.createHash('sha256')
  .update('clang-ast-v1' + 'added' + lib.canonical(null) + lib.canonical(testIdentity))
  .digest('hex').slice(0, 16);
testHeaderScope.classification = {
  production: ['include/**', 'src/**'], tests: ['tests/**'], project_docs: ['README.md'],
  project_tooling: ['CMakeLists.txt', 'compile_commands.json'], examples: ['examples/**'],
  generated: [], vendor: ['vendor/**']
};
testHeaderScope.report.discovery_adapter_identity = {id: 'clang-ast-v1', schema_version: 1, sha256: zero};
testHeaderScope.report.ast_tool_identity = {resolved_path: '/usr/bin/clang++', version_sha256: zero, capability_probe_sha256: zero};
testHeaderScope.report.compile_commands_sha256 = zero;
testHeaderScope.report.ast_candidates = [{candidate_id: testCandidateId, source: 'clang_ast', base_symbol_identity: null, current_symbol_identity: testIdentity, candidate_scope: 'public_contract', base_access: null, current_access: 'public', base_linkage: null, current_linkage: 'external', change_status: 'added', base_semantic_sha256: null, current_semantic_sha256: zero}];
testHeaderScope.report.unmatched_candidates = [{candidate_id: testCandidateId, source: 'clang_ast', reason: 'A forged scope treats a test helper as a public contract.'}];
testHeaderScope.report.status = 'orphaned';
testHeaderScope.baseline.integration_surface_report_sha256 = lib.sha(lib.reportBytes(testHeaderScope.report));
testHeaderScope.baseline.integration_discovery_identity_sha256 = lib.discoveryIdentity(testHeaderScope.report);
try { lib.validateEvaluationV3(testHeaderScope); throw new Error('test header forged as public_contract was accepted'); }
catch (error) { if (!/AST candidate scope mismatch/.test(error.message)) throw error; }

const reviewedInventory = makeFixture();
reviewedInventory.report.changed_production_paths.push('src/unplanned.cpp');
reviewedInventory.report.path_candidates.push({candidate_id: 'path-candidate-unplanned', source: 'path', path: 'src/unplanned.cpp', old_path: null, change_status: 'added'});
reviewedInventory.report.unmatched_candidates = [{candidate_id: 'path-candidate-unplanned', source: 'path', reason: 'No approved surface maps this production path.'}];
reviewedInventory.report.status = 'review_required';
reviewedInventory.baseline.review_input.review_paths.push('src/unplanned.cpp');
reviewedInventory.evaluation.integration_completeness.inventory_assessment.evidence_paths.push('src/unplanned.cpp');
reviewedInventory.evaluation.integration_completeness.candidate_assessments.push({
  candidate_id: 'path-candidate-unplanned', source: 'path', disposition: 'non_semantic_change',
  surface_ids: [], surface_bindings: [], reason: 'The independent diff review found only a formatting comment.',
  producer_paths: ['src/unplanned.cpp'], implementation_consumer: null,
  evidence_paths: ['src/unplanned.cpp'], evidence_command_ids: [], orphan_ids: []
});
reviewedInventory.baseline.integration_surface_report_sha256 = lib.sha(lib.reportBytes(reviewedInventory.report));
reviewedInventory.evaluation.integration_completeness.report_sha256 = reviewedInventory.baseline.integration_surface_report_sha256;
if (lib.validateEvaluationV3(reviewedInventory).result !== 'Pass') throw new Error('reviewed_inventory review_required candidate could not be closed by an exact assessment');

const unverifiedRemoval = makeFixture();
unverifiedRemoval.report.changed_production_paths.push('src/removed.cpp');
unverifiedRemoval.report.path_candidates.push({candidate_id: 'path-candidate-removed', source: 'path', path: 'src/removed.cpp', old_path: null, change_status: 'deleted'});
unverifiedRemoval.report.unmatched_candidates = [{candidate_id: 'path-candidate-removed', source: 'path', reason: 'The deleted private implementation needs independent regression evidence.'}];
unverifiedRemoval.report.status = 'review_required';
unverifiedRemoval.baseline.review_input.review_paths.push('src/removed.cpp');
unverifiedRemoval.evaluation.integration_completeness.inventory_assessment.evidence_paths.push('src/removed.cpp');
unverifiedRemoval.evaluation.integration_completeness.candidate_assessments.push({
  candidate_id: 'path-candidate-removed', source: 'path', disposition: 'private_removal',
  surface_ids: [], surface_bindings: [], reason: 'The base-only helper was removed.',
  producer_paths: ['src/removed.cpp'], implementation_consumer: null,
  evidence_paths: ['src/removed.cpp'], evidence_command_ids: [], orphan_ids: []
});
unverifiedRemoval.baseline.integration_surface_report_sha256 = lib.sha(lib.reportBytes(unverifiedRemoval.report));
unverifiedRemoval.evaluation.integration_completeness.report_sha256 = unverifiedRemoval.baseline.integration_surface_report_sha256;
unverifiedRemoval.current_file = p => p !== 'src/removed.cpp' && lib.currentRegularFile(process.cwd(), p);
unverifiedRemoval.base_file = p => p === 'src/removed.cpp';
try { lib.validateEvaluationV3(unverifiedRemoval); throw new Error('private removal without independent executable evidence was accepted'); }
catch (error) { if (!/private removal needs independent executable evidence/.test(error.message)) throw error; }

const hiddenHeader = makeFixture();
hiddenHeader.report.changed_production_paths.push('include/unplanned.hpp');
hiddenHeader.report.changed_production_paths.sort();
hiddenHeader.report.path_candidates.push({candidate_id: 'path-candidate-header', source: 'path', path: 'include/unplanned.hpp', old_path: null, change_status: 'added'});
hiddenHeader.report.unmatched_candidates = [{candidate_id: 'path-candidate-header', source: 'path', reason: 'No approved surface maps this public header.'}];
hiddenHeader.report.status = 'review_required';
hiddenHeader.baseline.review_input.review_paths.push('include/unplanned.hpp');
hiddenHeader.baseline.review_input.review_paths.sort();
hiddenHeader.evaluation.integration_completeness.inventory_assessment.evidence_paths.push('include/unplanned.hpp');
hiddenHeader.evaluation.integration_completeness.inventory_assessment.evidence_paths.sort();
hiddenHeader.evaluation.integration_completeness.candidate_assessments.push({
  candidate_id: 'path-candidate-header', source: 'path', disposition: 'implementation_detail',
  surface_ids: [], surface_bindings: [], reason: 'Attempt to hide a header declaration as an implementation detail.',
  producer_paths: ['include/unplanned.hpp'],
  implementation_consumer: {consumer_kind: 'production_caller', consumer_paths: ['src/caller.cpp']},
  evidence_paths: ['include/unplanned.hpp', 'src/caller.cpp'], evidence_command_ids: [], orphan_ids: []
});
hiddenHeader.baseline.integration_surface_report_sha256 = lib.sha(lib.reportBytes(hiddenHeader.report));
hiddenHeader.evaluation.integration_completeness.report_sha256 = hiddenHeader.baseline.integration_surface_report_sha256;
try { lib.validateEvaluationV3(hiddenHeader); throw new Error('surface-bearing header was hidden as an implementation detail'); }
catch (error) { if (!/surface-bearing candidate/.test(error.message)) throw error; }
NODE
)

note 'Evaluation v3 validator 的 exact probe、review_required disposition、Environment Blocked、祖先 symlink、role 闭包和 orphaned begin 门禁通过'
