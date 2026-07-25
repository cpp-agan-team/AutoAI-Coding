#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/provisional recovery project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

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

change=hardware-recovery
run_managed_at "$repo" scripts/change_new.sh "$change"
assert_status 0
change_dir="$repo/openspec/changes/$change"
mkdir -p "$change_dir/specs/device" "$repo/src"

cat > "$change_dir/proposal.md" <<'EOF'
# Change: Exercise a device surface after the lab recovers

Implement the approved device path while the physical lab is initially unavailable.
EOF

cat > "$change_dir/specs/device/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Device operation is reachable

The production daemon SHALL invoke the device operation.

#### Scenario: Live lab observation

- **WHEN** the recovered lab runs the daemon probe
- **THEN** the producer is observed through its production caller
EOF

cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Implement and connect the device operation
  - Covers: `specs/device/spec.md` | `ADDED` | `Device operation is reachable` | `Live lab observation`
  - Verify: `behavior`, `static`
EOF

cat > "$change_dir/design.md" <<'EOF'
# Device recovery design

<!-- autoai:tdd-policy:v1 -->
```json
{
  "schema_version": 1,
  "default": "required",
  "exceptions": [
    {
      "id": "lab-unavailable",
      "category": "unavailable_hardware",
      "task_ids": ["1.1"],
      "paths": ["src/**"],
      "reason": "The physical lab is unavailable during the initial implementation window.",
      "alternative_verify_kinds": ["behavior", "static"],
      "exit_condition": "Run the live production path when the lab becomes available."
    }
  ]
}
```
<!-- /autoai:tdd-policy:v1 -->

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "small",
  "rationale": "Modify one device producer and one existing production caller.",
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
      "added_lines": {"expected": 4, "review_at": 8, "hard_limit": 16},
      "touched_files": {"expected": 2, "review_at": 3, "hard_limit": 4},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 2, "hard_limit": 4},
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
  "structural_allowances": {"public_contracts": [], "cmake_targets": [], "direct_dependencies": []},
  "reuse_decisions": [],
  "obsolete_items": [],
  "exceptions": []
}
```
<!-- /autoai:implementation-economy:v1 -->

<!-- autoai:integration-completeness:v1 -->
```json
{
  "discovery": {"compile_commands_path": null, "mode": "reviewed_inventory"},
  "schema_version": 1,
  "surfaces": [
    {
      "change_kind": "modified",
      "compatibility": {
        "old_consumer_paths": ["src/device_legacy.cpp"],
        "replacement_consumer_paths": ["src/device_daemon.cpp"],
        "replacement_policy": "required",
        "expected_old_result": "The legacy consumer remains explicitly covered during the recovery window.",
        "migration_path": "Move callers from the legacy probe to the connected daemon.",
        "exit_condition": "Remove the legacy consumer after the approved compatibility window."
      },
      "consumer_kind": "production_caller",
      "consumer_paths": ["src/device_daemon.cpp"],
      "contract_impact": "breaking",
      "entrypoint": "device daemon live probe",
      "evidence_contracts": [
        {
          "argv": ["bash", "-c", "grep -qx \"device-service=implemented\" src/device_service.cpp && grep -qx \"device-daemon=connected\" src/device_daemon.cpp && printf \"device-behavior-ok\\n\""],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "device-behavior-ok",
          "probe_id": "probe-device-behavior-old",
          "role": "old_consumer"
        },
        {
          "argv": ["bash", "-c", "grep -qx \"device-service=implemented\" src/device_service.cpp && grep -qx \"device-daemon=connected\" src/device_daemon.cpp && printf \"device-behavior-ok\\n\""],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "device-behavior-ok",
          "probe_id": "probe-device-behavior-replacement",
          "role": "replacement_consumer"
        },
        {
          "argv": ["bash", "-c", "test -s src/device_service.cpp && test -s src/device_daemon.cpp && printf \"device-static-ok\\n\""],
          "expected_exit_codes": [0],
          "kind": "static",
          "output_contains": "device-static-ok",
          "probe_id": "probe-device-static-old",
          "role": "old_consumer"
        },
        {
          "argv": ["bash", "-c", "test -s src/device_service.cpp && test -s src/device_daemon.cpp && printf \"device-static-ok\\n\""],
          "expected_exit_codes": [0],
          "kind": "static",
          "output_contains": "device-static-ok",
          "probe_id": "probe-device-static-replacement",
          "role": "replacement_consumer"
        }
      ],
      "expected_observation": "The live command observes the device producer through the daemon caller.",
      "id": "surface-device-operation",
      "kind": "internal_api",
      "name": "device operation",
      "producer_paths": ["src/device_service.cpp"],
      "requirement_refs": [
        {
          "operation": "ADDED",
          "requirement": "Device operation is reachable",
          "scenarios": ["Live lab observation"],
          "spec_path": "specs/device/spec.md"
        }
      ],
      "symbol_identities": null,
      "task_ids": ["1.1"],
      "task_obligations": [
        {
          "evidence_roles": ["old_consumer", "replacement_consumer"],
          "task_id": "1.1",
          "verify_kinds": ["behavior", "static"]
        }
      ],
      "verify_kinds": ["behavior", "static"]
    }
  ]
}
```
<!-- /autoai:integration-completeness:v1 -->
EOF

printf 'device-service=baseline\n' > "$repo/src/device_service.cpp"
printf 'device-daemon=baseline\n' > "$repo/src/device_daemon.cpp"
printf 'device-legacy=compatibility-probe\n' > "$repo/src/device_legacy.cpp"
git -C "$repo" config user.name 'AutoAI Provisional Recovery Test'
git -C "$repo" config user.email 'autoai-provisional-recovery@example.invalid'
git -C "$repo" add -A
git -C "$repo" commit -qm 'approved hardware recovery baseline'

export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
export STUB_OPENSPEC_TASK_TOTAL=1
run_managed_at "$repo" scripts/snapshot_update.sh \
    --freeze-planning-baseline --freeze-implementation-base \
    --phase implementing --current-step implementation-base-frozen \
    --next-step implement-device-operation
assert_status 0

printf 'device-service=implemented\n' > "$repo/src/device_service.cpp"
printf 'device-daemon=connected\n' > "$repo/src/device_daemon.cpp"
run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0

note '环境不可用时 ALTERNATIVE 可以完成 task，但 Integration closure 必须保持 provisional/Blocked'
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id lab-unavailable --kind behavior \
    --surface-role surface-device-operation=old_consumer \
    --surface-role surface-device-operation=replacement_consumer \
    --path src/device_service.cpp --path src/device_daemon.cpp \
    --observed 'the implementation is inspectable but the physical lab is unavailable' -- \
    bash -c 'test -f src/device_service.cpp && test -f src/device_daemon.cpp'
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id lab-unavailable --kind static \
    --surface-role surface-device-operation=old_consumer \
    --surface-role surface-device-operation=replacement_consumer \
    --path src/device_service.cpp --path src/device_daemon.cpp \
    --observed 'static inspection remains only an alternative while the lab is unavailable' -- \
    bash -c 'test -s src/device_service.cpp && test -s src/device_daemon.cpp'
assert_status 0

incomplete_repo="$tmp/incomplete recovery project"
cp -a -- "$repo" "$incomplete_repo"
incomplete_marker="$tmp/incomplete-command-ran"
run_managed_at "$incomplete_repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle lab-recovered --kind behavior \
    --surface-role surface-device-operation=old_consumer \
    --surface-role surface-device-operation=replacement_consumer \
    --path src/device_service.cpp --path src/device_daemon.cpp -- \
    bash -c 'touch "$1"' _ "$incomplete_marker"
assert_status 6
assert_path_absent "$incomplete_marker"

run_managed_at "$repo" scripts/task_verify.sh --complete 1.1
assert_status 0
node - "$repo" "$change" <<'NODE'
const path = require('path');
const [root, change] = process.argv.slice(2);
process.chdir(root);
const manifest = require(path.join(root, 'scripts', 'manifest_policy.js'));
const integration = require(path.join(root, 'scripts', 'integration_surface_lib.js'));
const tdd = manifest.verifyTddEvidence(root, change, {taskId: '1.1'});
const closure = integration.verifyIntegrationEvidence(root, change, {taskId: '1.1'});
if (JSON.stringify(tdd.blocking_exception_task_ids) !== JSON.stringify(['1.1'])) {
  throw new Error('unavailable-hardware task was not retained as blocking');
}
if (closure.verified.length !== 0 || closure.provisionally_blocked.length !== 4 ||
    closure.provisionally_blocked.some(item => item.exception_id !== 'lab-unavailable')) {
  throw new Error('provisional surface closure did not remain Blocked');
}
NODE

note '恢复命令必须一次绑定该 Verify kind 的全部 surface role，且不得携带 exception_id'
verification="$change_dir/harness/verification.json"
evidence_before=$(sha256sum -- "$verification" | awk '{print $1}')
missing_role_marker="$tmp/missing-role-command-ran"
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle lab-recovered --kind behavior \
    --surface-role surface-device-operation=old_consumer \
    --path src/device_service.cpp --path src/device_daemon.cpp -- \
    bash -c 'touch "$1"' _ "$missing_role_marker"
assert_status 6
assert_path_absent "$missing_role_marker"
[[ "$evidence_before" == "$(sha256sum -- "$verification" | awk '{print $1}')" ]] || \
    fail 'missing-role recovery changed verification evidence'

run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle lab-recovered --exception-id lab-unavailable --kind behavior \
    --surface-role surface-device-operation=old_consumer \
    --surface-role surface-device-operation=replacement_consumer \
    --path src/device_service.cpp --path src/device_daemon.cpp -- \
    bash -c 'exit 0'
assert_status 2

note '环境恢复后的 partial recovery 仍保持整个 task provisional，不能逐 pair 提前解封'
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle lab-recovered --kind behavior \
    --surface-role surface-device-operation=old_consumer \
    --surface-role surface-device-operation=replacement_consumer \
    --path src/device_service.cpp --path src/device_daemon.cpp \
    --observed 'the recovered physical lab exercised the connected production path' -- \
    bash -c 'grep -qx "device-service=implemented" src/device_service.cpp && grep -qx "device-daemon=connected" src/device_daemon.cpp && printf "device-behavior-ok\n"'
assert_status 0

node - "$repo" "$change" <<'NODE'
const path = require('path');
const [root, change] = process.argv.slice(2);
process.chdir(root);
const manifest = require(path.join(root, 'scripts', 'manifest_policy.js'));
const integration = require(path.join(root, 'scripts', 'integration_surface_lib.js'));
const tdd = manifest.verifyTddEvidence(root, change, {taskId: '1.1'});
const closure = integration.verifyIntegrationEvidence(root, change, {taskId: '1.1'});
if (JSON.stringify(tdd.blocking_exception_task_ids) !== JSON.stringify(['1.1']) ||
    closure.verified.length !== 0 || closure.provisionally_blocked.length !== 4) {
  throw new Error('a partial recovery cycle released only part of a blocked task');
}
NODE

note '同一 recovery cycle 覆盖全部 Verify kinds 后，无需伪造 RED/GREEN 即可解除 blocker'
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase regression --cycle lab-recovered --kind static \
    --surface-role surface-device-operation=old_consumer \
    --surface-role surface-device-operation=replacement_consumer \
    --path src/device_service.cpp --path src/device_daemon.cpp \
    --observed 'the recovered environment completed the remaining static obligation' -- \
    bash -c 'test -s src/device_service.cpp && test -s src/device_daemon.cpp && printf "device-static-ok\n"'
assert_status 0

node - "$repo" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, change] = process.argv.slice(2);
process.chdir(root);
const manifest = require(path.join(root, 'scripts', 'manifest_policy.js'));
const integration = require(path.join(root, 'scripts', 'integration_surface_lib.js'));
const tdd = manifest.verifyTddEvidence(root, change, {taskId: '1.1'});
const closure = integration.verifyIntegrationEvidence(root, change, {taskId: '1.1'});
if (tdd.blocking_exception_task_ids.length !== 0 || closure.provisionally_blocked.length !== 0 ||
    closure.verified.length !== 4 || closure.verified.some(item => item.surface_id !== 'surface-device-operation')) {
  throw new Error('fresh recovery REGRESSION did not produce a non-blocking surface closure');
}
const task = JSON.parse(fs.readFileSync(path.join(root, 'openspec/changes', change, 'harness', 'verification.json')))
  .tasks.find(item => item.task_id === '1.1');
if (task.commands.length !== 4 || task.commands.slice(0, 2).some(command => command.phase !== 'ALTERNATIVE') ||
    task.commands.slice(2).some(command => command.phase !== 'REGRESSION' || command.exception_id !== null) ||
    task.commands.some(command => command.phase === 'RED' || command.phase === 'GREEN')) {
  throw new Error('environment recovery did not preserve the intended append-only phase history');
}
NODE

note '恢复证据仍受 source freshness 约束，源码漂移会重新阻止闭环'
cp -p "$repo/src/device_daemon.cpp" "$tmp/device_daemon.saved"
printf 'post-recovery-drift\n' >> "$repo/src/device_daemon.cpp"
node - "$repo" "$change" <<'NODE'
const path = require('path');
const [root, change] = process.argv.slice(2);
process.chdir(root);
let rejected = false;
try { require(path.join(root, 'scripts', 'manifest_policy.js')).verifyTddEvidence(root, change, {taskId: '1.1'}); }
catch { rejected = true; }
if (!rejected) throw new Error('stale recovery evidence remained current after source drift');
NODE
mv "$tmp/device_daemon.saved" "$repo/src/device_daemon.cpp"

node - "$repo" "$change" <<'NODE'
const path = require('path');
const [root, change] = process.argv.slice(2);
process.chdir(root);
const closure = require(path.join(root, 'scripts', 'integration_surface_lib.js'))
  .verifyIntegrationEvidence(root, change, {taskId: '1.1'});
if (closure.provisionally_blocked.length || closure.verified.length !== 4) {
  throw new Error('restored source did not restore the recovered closure');
}
NODE

note '缺失当前 task obligation 返回 blocked/stale_task_obligations，且 refresh 零写入'
stale_task_repo="$tmp/stale task obligation project"
cp -a -- "$repo" "$stale_task_repo"
stale_verification="$stale_task_repo/openspec/changes/$change/harness/verification.json"
node - "$stale_verification" <<'NODE'
const fs = require('fs'), file = process.argv[2], value = JSON.parse(fs.readFileSync(file));
const task = value.tasks.find(item => item.task_id === '1.1');
const command = task.commands.findLast(item => item.phase === 'REGRESSION' && item.kind === 'static');
if (!command) throw new Error('stale-obligation fixture has no static recovery command');
command.surface_evidence_roles = command.surface_evidence_roles.filter(
  item => item.role === 'old_consumer'
);
command.surface_probe_bindings = command.surface_probe_bindings.filter(
  item => item.role === 'old_consumer'
);
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
NODE
stale_verification_before=$(sha256sum -- "$stale_verification" | awk '{print $1}')
run_managed_at "$stale_task_repo" env STUB_OPENSPEC_INSTRUCTIONS_MODE=success \
    scripts/integration_surface_check.sh "$change" --refresh --json
assert_status 6
printf '%s\n' "$RUN_OUTPUT" > "$tmp/stale-task-obligation.json"
node - "$tmp/stale-task-obligation.json" "$change" <<'NODE'
const fs = require('fs'), [file, change] = process.argv.slice(2), value = JSON.parse(fs.readFileSync(file));
if (Object.keys(value).sort().join(',') !== 'change_name,reason,schema_version,status' ||
    value.schema_version !== 1 || value.change_name !== change ||
    value.status !== 'blocked' || value.reason !== 'stale_task_obligations') {
  throw new Error('stale task obligation did not use the closed blocked diagnostic: ' + JSON.stringify(value));
}
NODE
[[ "$stale_verification_before" == "$(sha256sum -- "$stale_verification" | awk '{print $1}')" ]] || \
    fail 'stale obligation refresh rewrote verification evidence'
assert_path_absent "$stale_task_repo/openspec/changes/$change/harness/integration-surface-report.json"

note 'hardware/external-service provisional evidence、显式恢复及 fail-closed 负例均通过'
