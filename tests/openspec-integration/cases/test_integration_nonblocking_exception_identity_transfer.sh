#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/nonblocking exception identity transfer project"
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

change=transfer-surface-identity
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)
change_dir="$repo/openspec/changes/$change"
report="$change_dir/harness/integration-surface-report.json"
mkdir -p "$change_dir/specs/transfer" "$repo/openspec/specs/transfer" \
    "$repo/include" "$repo/src" "$repo/tests"

cat > "$repo/openspec/specs/transfer/spec.md" <<'EOF'
# Transfer Specification

## Requirements

### Requirement: Legacy operation ownership

The legacy integration surface SHALL own the stable operation.

#### Scenario: Legacy caller observes the operation

- **WHEN** the legacy caller invokes the stable operation
- **THEN** the legacy configured behavior is observable
EOF

cat > "$change_dir/proposal.md" <<'EOF'
# Change: Transfer ownership of the stable operation identity

Retire the legacy surface and expose the same stable C++ identity as a newly
approved current surface. The change is configuration-only for TDD purposes.
EOF

cat > "$change_dir/specs/transfer/spec.md" <<'EOF'
## REMOVED Requirements

### Requirement: Legacy operation ownership

The legacy integration surface SHALL no longer own the stable operation.

## ADDED Requirements

### Requirement: Current operation ownership

The current integration surface SHALL own the stable operation.

#### Scenario: Current caller observes the operation

- **WHEN** the current production caller invokes the stable operation
- **THEN** the configured current behavior is observable
EOF

cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Transfer the stable operation between approved surfaces
  - Covers: `specs/transfer/spec.md` | `REMOVED` | `Legacy operation ownership` | `<none>`
  - Covers: `specs/transfer/spec.md` | `ADDED` | `Current operation ownership` | `Current caller observes the operation`
  - Verify: `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
# Stable operation identity transfer

<!-- autoai:tdd-policy:v1 -->
```json
{
  "schema_version": 1,
  "default": "required",
  "exceptions": [
    {
      "id": "configuration-transfer",
      "category": "configuration_only",
      "task_ids": ["1.1"],
      "paths": ["include/**"],
      "reason": "The behavior implementation is unchanged; only its approved integration ownership changes.",
      "alternative_verify_kinds": ["behavior"],
      "exit_condition": "The exact production-facing probe observes the current configured ownership."
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
  "rationale": "Update one configuration marker while preserving one existing C++ operation identity.",
  "classification": {
    "production": ["include/**", "src/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md"],
    "project_tooling": ["CMakeLists.txt", "compile_commands.json"],
    "examples": ["examples/**"],
    "generated": [],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 2, "review_at": 4, "hard_limit": 8},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
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
    "compile_commands_path": "compile_commands.json",
    "mode": "clang_ast"
  },
  "schema_version": 1,
  "surfaces": [
    {
      "change_kind": "removed",
      "compatibility": {
        "old_consumer_paths": ["tests/transfer_probe.sh"],
        "replacement_consumer_paths": ["tests/transfer_probe.sh"],
        "replacement_policy": "required",
        "expected_old_result": "The legacy ownership is absent while its compatibility probe remains observable.",
        "migration_path": "Use the current operation ownership surface.",
        "exit_condition": "Remove the compatibility probe after downstream migration."
      },
      "consumer_kind": "compatibility_probe",
      "consumer_paths": ["tests/transfer_probe.sh"],
      "contract_impact": "removal",
      "entrypoint": "legacy compatibility probe",
      "evidence_contracts": [
        {
          "argv": ["tests/transfer_probe.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "transfer-surface-ok",
          "probe_id": "probe-transfer-old-consumer",
          "role": "old_consumer"
        },
        {
          "argv": ["tests/transfer_probe.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "transfer-surface-ok",
          "probe_id": "probe-transfer-replacement-consumer",
          "role": "replacement_consumer"
        },
        {
          "argv": ["tests/transfer_probe.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "transfer-surface-ok",
          "probe_id": "probe-transfer-absence",
          "role": "absence_probe"
        }
      ],
      "expected_observation": "The compatibility probe observes that legacy ownership has ended.",
      "id": "surface-transfer-legacy",
      "kind": "internal_api",
      "name": "legacy stable_operation ownership",
      "producer_paths": ["include/transfer.hpp"],
      "requirement_refs": [
        {
          "operation": "REMOVED",
          "requirement": "Legacy operation ownership",
          "scenarios": [],
          "spec_path": "specs/transfer/spec.md"
        }
      ],
      "symbol_identities": {
        "base": [
          {
            "declaration_kind": "function",
            "qualified_name": "stable_operation",
            "canonical_parameter_types": ["int"],
            "canonical_return_type": "int",
            "template_parameter_kinds": [],
            "cv_qualifiers": [],
            "ref_qualifier": "none",
            "declaration_path": "include/transfer.hpp"
          }
        ],
        "current": []
      },
      "task_ids": ["1.1"],
      "task_obligations": [
        {
          "evidence_roles": ["old_consumer", "replacement_consumer", "absence_probe"],
          "task_id": "1.1",
          "verify_kinds": ["behavior"]
        }
      ],
      "verify_kinds": ["behavior"]
    },
    {
      "change_kind": "added",
      "compatibility": null,
      "consumer_kind": "production_caller",
      "consumer_paths": ["src/current_caller.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "current production caller",
      "evidence_contracts": [
        {
          "argv": ["tests/transfer_probe.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "transfer-surface-ok",
          "probe_id": "probe-transfer-current",
          "role": "current"
        }
      ],
      "expected_observation": "The current production caller observes the configured stable operation.",
      "id": "surface-transfer-current",
      "kind": "internal_api",
      "name": "current stable_operation ownership",
      "producer_paths": ["include/transfer.hpp"],
      "requirement_refs": [
        {
          "operation": "ADDED",
          "requirement": "Current operation ownership",
          "scenarios": ["Current caller observes the operation"],
          "spec_path": "specs/transfer/spec.md"
        }
      ],
      "symbol_identities": {
        "base": [],
        "current": [
          {
            "declaration_kind": "function",
            "qualified_name": "stable_operation",
            "canonical_parameter_types": ["int"],
            "canonical_return_type": "int",
            "template_parameter_kinds": [],
            "cv_qualifiers": [],
            "ref_qualifier": "none",
            "declaration_path": "include/transfer.hpp"
          }
        ]
      },
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

cat > "$repo/include/transfer.hpp" <<'EOF'
#pragma once
// integration-owner: legacy
int stable_operation(int value);
EOF
cat > "$repo/src/current_caller.cpp" <<'EOF'
#include "transfer.hpp"
int call_stable_operation(int value) { return stable_operation(value); }
EOF
cat > "$repo/tests/transfer_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
grep -Fqx '// integration-owner: current' include/transfer.hpp
[[ "${AUTOAI_SUPPRESS_TRANSFER_MARKER:-0}" != 1 ]] || exit 0
echo transfer-surface-ok
EOF
chmod 755 "$repo/tests/transfer_probe.sh"
cat > "$repo/compile_commands.json" <<EOF
[
  {
    "directory": "$repo",
    "file": "src/current_caller.cpp",
    "arguments": ["c++", "-I", "include", "-c", "src/current_caller.cpp"]
  }
]
EOF

# This fixture isolates report ownership logic from Clang parsing.  The canned
# adapter returns one real-shaped modified candidate and a complete two-tree
# identity inventory; the generated Integration report builder remains real.
cat > "$repo/scripts/clang_ast_surface_adapter.js" <<'EOF'
#!/usr/bin/env node
'use strict';
const identity = {
  declaration_kind: 'function',
  qualified_name: 'stable_operation',
  canonical_parameter_types: ['int'],
  canonical_return_type: 'int',
  template_parameter_kinds: [],
  cv_qualifiers: [],
  ref_qualifier: 'none',
  declaration_path: 'include/transfer.hpp'
};
const digest = 'sha256:' + '0'.repeat(64);
module.exports = {
  discover() {
    return {
      candidates: [{
        candidate_id: 'ast-candidate-stable-operation',
        source: 'clang_ast',
        base_symbol_identity: identity,
        current_symbol_identity: identity,
        candidate_scope: 'public_contract',
        base_access: null,
        current_access: null,
        base_linkage: 'external',
        current_linkage: 'external',
        change_status: 'modified',
        base_semantic_sha256: digest,
        current_semantic_sha256: 'sha256:' + '1'.repeat(64)
      }],
      compile_commands_sha256: digest,
      ast_tool_identity: {
        resolved_path: '/fixture/canned-clang++',
        version_sha256: digest,
        capability_probe_sha256: digest
      },
      adapter_identity: {
        id: 'clang-ast-v1',
        schema_version: 1,
        sha256: digest
      },
      identity_inventory: {
        base: [identity],
        current: [identity]
      }
    };
  }
};
EOF
chmod 755 "$repo/scripts/clang_ast_surface_adapter.js"

git -C "$repo" config user.name 'AutoAI Identity Transfer Test'
git -C "$repo" config user.email 'autoai-identity-transfer@example.invalid'
git -C "$repo" add -A
git -C "$repo" add -f compile_commands.json
git -C "$repo" commit -qm 'approved identity transfer baseline'

export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
export STUB_OPENSPEC_TASK_TOTAL=1
(
    cd "$repo"
    scripts/snapshot_update.sh \
        --freeze-planning-baseline --freeze-implementation-base \
        --phase implementing --current-step implementation-base-frozen \
        --next-step transfer-operation-ownership >/dev/null
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

note '跨 surface 的同一 symbol identity 只要分别占用 base/current，规划必须合法'
run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --plan-check --json
assert_status 0

sed -i 's/integration-owner: legacy/integration-owner: current/' "$repo/include/transfer.hpp"
run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0

note '普通非阻塞例外必须拒绝错误 exception ID 和未分配 surface role，且零写入'
verification="$change_dir/harness/verification.json"
verification_before=$(sha256sum -- "$verification" | awk '{print $1}')
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id wrong-exception --kind behavior \
    --surface-role surface-transfer-legacy=old_consumer \
    --surface-role surface-transfer-legacy=replacement_consumer \
    --surface-role surface-transfer-legacy=absence_probe \
    --surface-role surface-transfer-current=current \
    --path include/transfer.hpp -- \
    tests/transfer_probe.sh
[[ "$RUN_STATUS" -ne 0 ]] || fail 'wrong nonblocking exception ID was accepted'
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-transfer --kind behavior \
    --surface-role surface-transfer-legacy=old_consumer \
    --surface-role surface-transfer-legacy=replacement_consumer \
    --surface-role surface-transfer-legacy=absence_probe \
    --surface-role surface-transfer-current=old_consumer \
    --path include/transfer.hpp -- \
    tests/transfer_probe.sh
[[ "$RUN_STATUS" -ne 0 ]] || fail 'unassigned nonblocking exception role was accepted'
[[ "$verification_before" == "$(sha256sum -- "$verification" | awk '{print $1}')" ]] || \
    fail 'rejected nonblocking exception evidence changed verification.json'

note '普通非阻塞 ALTERNATIVE 必须逐字匹配 probe argv/exit，并在执行前拒绝无关命令'
wrong_probe_marker="$tmp/wrong-alternative-probe-ran"
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-transfer --kind behavior \
    --surface-role surface-transfer-legacy=old_consumer \
    --surface-role surface-transfer-legacy=replacement_consumer \
    --surface-role surface-transfer-legacy=absence_probe \
    --surface-role surface-transfer-current=current \
    --path include/transfer.hpp -- \
    bash -c 'touch "$1"' _ "$wrong_probe_marker"
[[ "$RUN_STATUS" -ne 0 ]] || fail 'unrelated nonblocking ALTERNATIVE probe was accepted'
assert_path_absent "$wrong_probe_marker"
[[ "$verification_before" == "$(sha256sum -- "$verification" | awk '{print $1}')" ]] || \
    fail 'wrong ALTERNATIVE argv changed verification.json'

note 'argv/exit 正确但缺少 approved output marker 时也不能保存 surface evidence'
run_managed_at "$repo" env AUTOAI_SUPPRESS_TRANSFER_MARKER=1 \
    scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-transfer --kind behavior \
    --surface-role surface-transfer-legacy=old_consumer \
    --surface-role surface-transfer-legacy=replacement_consumer \
    --surface-role surface-transfer-legacy=absence_probe \
    --surface-role surface-transfer-current=current \
    --path include/transfer.hpp -- \
    tests/transfer_probe.sh
[[ "$RUN_STATUS" -ne 0 ]] || fail 'marker-free nonblocking ALTERNATIVE probe was accepted'
[[ "$verification_before" == "$(sha256sum -- "$verification" | awk '{print $1}')" ]] || \
    fail 'marker-free ALTERNATIVE changed verification.json'

note '精确绑定全部 obligation 的 configuration_only ALTERNATIVE 是 verified，而不是 provisional'
run_managed_at "$repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id configuration-transfer --kind behavior \
    --surface-role surface-transfer-legacy=old_consumer \
    --surface-role surface-transfer-legacy=replacement_consumer \
    --surface-role surface-transfer-legacy=absence_probe \
    --surface-role surface-transfer-current=current \
    --path include/transfer.hpp \
    --observed 'the approved configuration probe observed all legacy/current ownership roles' -- \
    tests/transfer_probe.sh
assert_status 0
node - "$repo" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, change] = process.argv.slice(2);
process.chdir(root);
const verification = JSON.parse(fs.readFileSync(
  path.join(root, 'openspec', 'changes', change, 'harness', 'verification.json'),
  'utf8'
));
const command = verification.tasks
  .find(item => item.task_id === '1.1')?.commands
  .findLast(item => item.phase === 'ALTERNATIVE');
const probeIds = command?.surface_probe_bindings
  .map(item => item.probe_id)
  .sort();
if (JSON.stringify(probeIds) !== JSON.stringify([
  'probe-transfer-absence',
  'probe-transfer-current',
  'probe-transfer-old-consumer',
  'probe-transfer-replacement-consumer'
])) {
  throw new Error(`exact nonblocking ALTERNATIVE probe bindings were not persisted: ${JSON.stringify(command)}`);
}
const closure = require(path.join(root, 'scripts', 'integration_surface_lib.js'))
  .verifyIntegrationEvidence(root, change, {taskId: '1.1'});
const expected = [
  'surface-transfer-current/behavior/current',
  'surface-transfer-legacy/behavior/absence_probe',
  'surface-transfer-legacy/behavior/old_consumer',
  'surface-transfer-legacy/behavior/replacement_consumer'
];
const actual = closure.verified
  .map(item => `${item.surface_id}/${item.kind}/${item.role}`)
  .sort();
if (closure.provisionally_blocked.length !== 0 ||
    JSON.stringify(actual) !== JSON.stringify(expected)) {
  throw new Error(`nonblocking ALTERNATIVE did not close Integration obligations: ${JSON.stringify(closure)}`);
}
NODE

run_managed_at "$repo" scripts/task_verify.sh --complete 1.1
assert_status 0

note '真实 refresh 必须把同一 modified AST candidate 按 tree_side 分别绑定 removed/base 与 added/current'
export STUB_OPENSPEC_INSTRUCTIONS_MODE=success
run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --refresh --json
assert_status 0
assert_path_exists "$report"
node - "$report" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (report.discovery_mode !== 'clang_ast' || report.status !== 'complete') {
  throw new Error(`identity-transfer report did not complete: ${report.status}`);
}
const candidate = report.ast_candidates.find(
  item => item.candidate_id === 'ast-candidate-stable-operation' &&
    item.change_status === 'modified'
);
if (!candidate) throw new Error('canned modified AST candidate is missing');
const binding = id => report.surface_candidate_bindings
  .find(item => item.surface_id === id)?.candidate_bindings
  .find(item => item.candidate_id === candidate.candidate_id && item.role === 'producer');
const legacy = binding('surface-transfer-legacy');
const current = binding('surface-transfer-current');
if (legacy?.tree_side !== 'base' || current?.tree_side !== 'current') {
  throw new Error(`modified identity transfer tree sides are wrong: ${JSON.stringify({legacy, current})}`);
}
if (report.unmatched_candidates.some(item => item.candidate_id === candidate.candidate_id)) {
  throw new Error('identity-transfer candidate remained unmatched');
}
NODE

note '非阻塞 TDD 例外和跨树 symbol identity 转移的闭环回归通过'
