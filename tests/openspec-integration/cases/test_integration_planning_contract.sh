#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/integration planning project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

# Keep the OpenSpec CLI offline stub while exercising the generated JavaScript
# with the system Node implementation.
runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
ln -s "$STUB_BIN/npx" "$runtime_bin/npx"
export PATH="$runtime_bin:$REAL_TEST_PATH"

change=integration-planning
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)
change_dir="$repo/openspec/changes/$change"
mkdir -p "$change_dir/specs/widget"

cat > "$change_dir/proposal.md" <<'EOF'
# Change: Connect the widget refresh surface

Add one internal product surface and connect it to the running widget daemon.
EOF

cat > "$change_dir/specs/widget/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Refresh the running widget

The daemon SHALL invoke the widget refresh surface.

#### Scenario: Daemon triggers refresh

- **WHEN** the running daemon reaches its refresh cycle
- **THEN** it invokes the widget refresh behavior

## REMOVED Requirements

### Requirement: Retired widget reset

The obsolete reset surface SHALL be retired without a replacement.
EOF

cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Connect the widget refresh surface
  - Covers: `specs/widget/spec.md` | `ADDED` | `Refresh the running widget` | `Daemon triggers refresh`
  - Verify: `behavior`, `build`

- [ ] 1.2 Verify the compatibility caller matrix
  - Covers: `specs/widget/spec.md` | `ADDED` | `Refresh the running widget` | `Daemon triggers refresh`
  - Covers: `specs/widget/spec.md` | `REMOVED` | `Retired widget reset` | `<none>`
  - Verify: `behavior`, `static`
EOF

cat > "$tmp/valid-integration.json" <<'EOF'
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
      "consumer_paths": [
        "src/widget_daemon.cpp"
      ],
      "contract_impact": "compatible",
      "entrypoint": "widget daemon refresh cycle",
      "evidence_contracts": [
        {
          "argv": ["tests/widget_refresh_probe.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "widget-refresh-ok",
          "probe_id": "probe-widget-refresh-current",
          "role": "current"
        }
      ],
      "expected_observation": "The running daemon prints widget-refresh-ok after invoking refresh.",
      "id": "surface-widget-refresh",
      "kind": "internal_api",
      "name": "widget::Service::refresh()",
      "producer_paths": [
        "include/widget/service.hpp",
        "src/widget_service.cpp"
      ],
      "requirement_refs": [
        {
          "operation": "ADDED",
          "requirement": "Refresh the running widget",
          "scenarios": [
            "Daemon triggers refresh"
          ],
          "spec_path": "specs/widget/spec.md"
        }
      ],
      "symbol_identities": null,
      "task_ids": [
        "1.1"
      ],
      "task_obligations": [
        {
          "evidence_roles": [
            "current"
          ],
          "task_id": "1.1",
          "verify_kinds": [
            "behavior"
          ]
        }
      ],
      "verify_kinds": [
        "behavior"
      ]
    }
  ]
}
EOF

cat > "$tmp/empty-integration.json" <<'EOF'
{
  "discovery": {
    "compile_commands_path": null,
    "mode": "reviewed_inventory"
  },
  "schema_version": 1,
  "surfaces": []
}
EOF

write_design() {
    local integration_json=$1
    {
        printf '%s\n\n' '# Integration planning design'
        printf '%s\n' '<!-- autoai:tdd-policy:v1 -->'
        printf '%s\n' '```json'
        printf '%s\n' '{"schema_version":1,"default":"required","exceptions":[]}'
        printf '%s\n' '```'
        printf '%s\n\n' '<!-- /autoai:tdd-policy:v1 -->'
        printf '%s\n' '<!-- autoai:integration-completeness:v1 -->'
        printf '%s\n' '```json'
        sed -n '1,$p' "$integration_json"
        printf '%s\n' '```'
        printf '%s\n' '<!-- /autoai:integration-completeness:v1 -->'
    } > "$change_dir/design.md"
}

run_plan_check() {
    local stdout_file="$tmp/plan-check.stdout"
    local stderr_file="$tmp/plan-check.stderr"
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    (
        cd "$repo"
        scripts/integration_surface_check.sh "$change" --plan-check --json
    ) >"$stdout_file" 2>"$stderr_file"
    RUN_STATUS=$?
    set -e
    RUN_OUTPUT=$(cat "$stderr_file")
}

assert_invalid_diagnostic() {
    assert_status 6
    node - "$tmp/plan-check.stdout" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const keys = Object.keys(value).sort().join(',');
if (keys !== 'change_name,reason,schema_version,status') {
  throw new Error(`diagnostic is not closed: ${keys}`);
}
if (value.schema_version !== 1 || value.change_name !== change || value.status !== 'invalid' || !value.reason) {
  throw new Error('invalid planning diagnostic contract mismatch');
}
NODE
}

note 'reviewed_inventory 的合法单 surface 规划输出 closed success JSON，且 plan-check 零写入'
write_design "$tmp/valid-integration.json"
run_plan_check
assert_status 0
node - "$tmp/plan-check.stdout" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const keys = Object.keys(value).sort().join(',');
if (keys !== 'change_name,mode,planned_surface_ids,planning_block_sha256,schema_version,status') {
  throw new Error(`success result is not closed: ${keys}`);
}
if (value.schema_version !== 1 || value.change_name !== change || value.mode !== 'plan-check' || value.status !== 'valid') {
  throw new Error('valid planning result contract mismatch');
}
if (JSON.stringify(value.planned_surface_ids) !== '["surface-widget-refresh"]') {
  throw new Error('planned surface IDs were not canonicalized');
}
if (!/^sha256:[0-9a-f]{64}$/.test(value.planning_block_sha256)) {
  throw new Error('planning block digest is not canonical sha256');
}
NODE
assert_path_absent "$change_dir/harness/integration-surface-report.json"

note '显式空 surfaces 表示已审核无产品表面，仍是合法规划'
write_design "$tmp/empty-integration.json"
run_plan_check
assert_status 0
node - "$tmp/plan-check.stdout" <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (value.status !== 'valid' || value.planned_surface_ids.length !== 0) {
  throw new Error('closed empty surface inventory was rejected');
}
NODE

note '缺失或重复 Integration Completeness 区块都 fail closed'
printf '# Design without integration inventory\n' > "$change_dir/design.md"
run_plan_check
assert_invalid_diagnostic
write_design "$tmp/valid-integration.json"
sed -n '/<!-- autoai:integration-completeness:v1 -->/,$p' "$change_dir/design.md" > "$tmp/duplicate-integration-block.md"
sed -n '1,$p' "$tmp/duplicate-integration-block.md" >> "$change_dir/design.md"
run_plan_check
assert_invalid_diagnostic

mutate_valid_block() {
    local expression=$1 output=$2
    node - "$tmp/valid-integration.json" "$output" "$expression" <<'NODE'
const fs = require('fs');
const [source, output, expression] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(source, 'utf8'));
const clangIdentity = {
  declaration_kind: 'method', qualified_name: 'widget::Service::refresh', canonical_parameter_types: [],
  canonical_return_type: 'void', template_parameter_kinds: [], cv_qualifiers: [], ref_qualifier: 'none',
  declaration_path: 'include/widget/service.hpp'
};
switch (expression) {
  case 'unknown-field': value.allow_unplanned = true; break;
  case 'invalid-kind': value.surfaces[0].kind = 'future_api'; break;
  case 'invalid-role': value.surfaces[0].task_obligations[0].evidence_roles = ['future']; break;
  case 'multiline-name': value.surfaces[0].name = 'widget refresh\nshadow surface'; break;
  case 'secret-observation': value.surfaces[0].expected_observation = 'Authorization: Bearer test-secret'; break;
  case 'missing-probe': delete value.surfaces[0].evidence_contracts; break;
  case 'probe-extra-field': value.surfaces[0].evidence_contracts[0].self_reported_pass = true; break;
  case 'duplicate-probe-pair':
    value.surfaces[0].evidence_contracts.push({...value.surfaces[0].evidence_contracts[0], probe_id: 'probe-widget-refresh-shadow'});
    break;
  case 'invalid-probe-exit': value.surfaces[0].evidence_contracts[0].expected_exit_codes = [-1]; break;
  case 'empty-probe-marker': value.surfaces[0].evidence_contracts[0].output_contains = ''; break;
  case 'credential-probe-argv': value.surfaces[0].evidence_contracts[0].argv = ['tests/widget_refresh_probe.sh', '--token', 'example']; break;
  case 'split-obligation-cartesian': {
    const surface = value.surfaces[0];
    surface.contract_impact = 'breaking';
    surface.compatibility = {
      old_consumer_paths: ['tests/widget_old.cpp'],
      replacement_consumer_paths: ['tests/widget_new.cpp'],
      replacement_policy: 'required',
      expected_old_result: 'The old caller remains observable.',
      migration_path: 'Move callers to the replacement.',
      exit_condition: 'Remove the old caller after migration.'
    };
    surface.task_ids = ['1.1', '1.2'];
    surface.verify_kinds = ['behavior', 'static'];
    surface.task_obligations = [
      {task_id: '1.1', verify_kinds: ['behavior'], evidence_roles: ['old_consumer']},
      {task_id: '1.2', verify_kinds: ['static'], evidence_roles: ['replacement_consumer']}
    ];
    break;
  }
  case 'build-only-surface': {
    const surface = value.surfaces[0];
    surface.kind = 'build_or_install';
    surface.consumer_kind = 'downstream_build';
    surface.runnable_artifact = false;
    surface.verify_kinds = ['build'];
    surface.task_obligations[0].verify_kinds = ['build'];
    surface.evidence_contracts[0].kind = 'build';
    break;
  }
  case 'runnable-build-only-surface': {
    const surface = value.surfaces[0];
    surface.kind = 'build_or_install';
    surface.consumer_kind = 'downstream_build';
    surface.runnable_artifact = true;
    surface.verify_kinds = ['build'];
    surface.task_obligations[0].verify_kinds = ['build'];
    surface.evidence_contracts[0].kind = 'build';
    break;
  }
  case 'build-missing-runnable-field': {
    const surface = value.surfaces[0];
    surface.kind = 'build_or_install';
    surface.consumer_kind = 'downstream_build';
    surface.verify_kinds = ['build'];
    surface.task_obligations[0].verify_kinds = ['build'];
    surface.evidence_contracts[0].kind = 'build';
    break;
  }
  case 'invalid-requirement': value.surfaces[0].requirement_refs[0].requirement = 'Missing requirement'; break;
  case 'invalid-task':
    value.surfaces[0].task_ids = ['9.9'];
    value.surfaces[0].task_obligations[0].task_id = '9.9';
    break;
  case 'approved-no-replacement-removal':
  case 'unapproved-no-replacement-removal': {
    const surface = value.surfaces[0];
    surface.change_kind = 'removed';
    surface.contract_impact = 'removal';
    surface.consumer_kind = 'compatibility_probe';
    surface.compatibility = {
      old_consumer_paths: ['tests/widget_old.cpp'],
      replacement_consumer_paths: [],
      replacement_policy: expression === 'approved-no-replacement-removal'
        ? 'requirement_approved_none'
        : 'required',
      expected_old_result: 'The retired reset caller is rejected with the approved diagnostic.',
      migration_path: 'No replacement exists because the REMOVED requirement explicitly retires this behavior.',
      exit_condition: 'The obsolete reset surface is absent from production and exported artifacts.'
    };
    surface.requirement_refs = [{
      operation: 'REMOVED',
      requirement: 'Retired widget reset',
      scenarios: [],
      spec_path: 'specs/widget/spec.md'
    }];
    surface.task_ids = ['1.2'];
    surface.task_obligations = [{
      task_id: '1.2',
      verify_kinds: ['behavior'],
      evidence_roles: ['old_consumer', 'absence_probe']
    }];
    surface.verify_kinds = ['behavior'];
    surface.evidence_contracts = [
      {
        argv: ['tests/widget_old_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-old-rejected', probe_id: 'probe-widget-no-replacement-old', role: 'old_consumer'
      },
      {
        argv: ['tests/widget_absence_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-reset-absent', probe_id: 'probe-widget-no-replacement-absence', role: 'absence_probe'
      }
    ];
    break;
  }
  case 'approved-none-on-added-requirement': {
    const surface = value.surfaces[0];
    surface.change_kind = 'removed';
    surface.contract_impact = 'removal';
    surface.consumer_kind = 'compatibility_probe';
    surface.compatibility = {
      old_consumer_paths: ['tests/widget_old.cpp'],
      replacement_consumer_paths: [],
      replacement_policy: 'requirement_approved_none',
      expected_old_result: 'The old caller is rejected.',
      migration_path: 'No replacement is claimed without a REMOVED requirement.',
      exit_condition: 'The old caller remains absent.'
    };
    surface.task_obligations[0].evidence_roles = ['old_consumer', 'absence_probe'];
    surface.evidence_contracts = [
      {
        argv: ['tests/widget_old_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-old-rejected', probe_id: 'probe-widget-invalid-none-old', role: 'old_consumer'
      },
      {
        argv: ['tests/widget_absence_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-reset-absent', probe_id: 'probe-widget-invalid-none-absence', role: 'absence_probe'
      }
    ];
    break;
  }
  case 'clang-null-internal':
    value.discovery = {compile_commands_path: 'compile_commands.json', mode: 'clang_ast'};
    break;
  case 'clang-null-external':
    value.discovery = {compile_commands_path: 'compile_commands.json', mode: 'clang_ast'};
    value.surfaces[0].kind = 'external_api';
    value.surfaces[0].consumer_kind = 'representative_external';
    break;
  case 'clang-non-json':
    value.discovery = {compile_commands_path: 'build/compile_commands.txt', mode: 'clang_ast'};
    value.surfaces[0].symbol_identities = {base: [], current: [clangIdentity]};
    break;
  case 'clang-valid-internal':
    value.discovery = {compile_commands_path: 'compile_commands.json', mode: 'clang_ast'};
    value.surfaces[0].symbol_identities = {base: [], current: [clangIdentity]};
    break;
  case 'clang-duplicate-current-identity': {
    value.discovery = {compile_commands_path: 'compile_commands.json', mode: 'clang_ast'};
    const first = value.surfaces[0];
    first.symbol_identities = {base: [], current: [clangIdentity]};
    const second = JSON.parse(JSON.stringify(first));
    second.id = 'surface-widget-refresh-shadow';
    second.evidence_contracts[0].probe_id = 'probe-widget-refresh-shadow-current';
    value.surfaces.push(second);
    break;
  }
  case 'clang-cross-side-identity-transfer': {
    value.discovery = {compile_commands_path: 'compile_commands.json', mode: 'clang_ast'};
    const removed = value.surfaces[0];
    removed.change_kind = 'removed';
    removed.contract_impact = 'removal';
    removed.consumer_kind = 'compatibility_probe';
    removed.compatibility = {
      old_consumer_paths: ['tests/widget_old.cpp'],
      replacement_consumer_paths: ['src/widget_daemon.cpp'],
      replacement_policy: 'required',
      expected_old_result: 'The old identity is absent.',
      migration_path: 'Use the replacement surface.',
      exit_condition: 'The old identity no longer appears in the installed contract.'
    };
    removed.symbol_identities = {base: [clangIdentity], current: []};
    removed.task_obligations[0].evidence_roles = ['old_consumer', 'replacement_consumer', 'absence_probe'];
    removed.evidence_contracts = [
      {
        argv: ['tests/widget_old_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-old-observed', probe_id: 'probe-widget-old-consumer', role: 'old_consumer'
      },
      {
        argv: ['tests/widget_refresh_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-refresh-ok', probe_id: 'probe-widget-replacement-consumer', role: 'replacement_consumer'
      },
      {
        argv: ['tests/widget_absence_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-old-absent', probe_id: 'probe-widget-absence', role: 'absence_probe'
      }
    ];
    const added = JSON.parse(JSON.stringify(value.surfaces[0]));
    added.id = 'surface-widget-refresh-replacement';
    added.name = 'widget::Service::refreshReplacement()';
    added.change_kind = 'added';
    added.contract_impact = 'compatible';
    added.consumer_kind = 'production_caller';
    added.compatibility = null;
    added.symbol_identities = {base: [], current: [clangIdentity]};
    added.task_obligations[0].evidence_roles = ['current'];
    added.evidence_contracts = [{
      argv: ['tests/widget_refresh_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
      output_contains: 'widget-refresh-ok', probe_id: 'probe-widget-replacement-current', role: 'current'
    }];
    value.surfaces.push(added);
    break;
  }
  case 'clang-added-identity-owned-by-modified-base': {
    value.discovery = {compile_commands_path: 'compile_commands.json', mode: 'clang_ast'};
    const modified = value.surfaces[0];
    const replacementIdentity = {...clangIdentity, qualified_name: 'widget::Service::refreshReplacement'};
    modified.change_kind = 'modified';
    modified.symbol_identities = {base: [clangIdentity], current: [replacementIdentity]};
    const added = JSON.parse(JSON.stringify(modified));
    added.id = 'surface-widget-refresh-invalid-added-owner';
    added.change_kind = 'added';
    added.symbol_identities = {base: [], current: [clangIdentity]};
    added.evidence_contracts[0].probe_id = 'probe-widget-invalid-added-owner-current';
    value.surfaces.push(added);
    break;
  }
  case 'clang-removed-identity-owned-by-modified-current': {
    value.discovery = {compile_commands_path: 'compile_commands.json', mode: 'clang_ast'};
    const modified = value.surfaces[0];
    const predecessorIdentity = {...clangIdentity, qualified_name: 'widget::Service::refreshPredecessor'};
    modified.change_kind = 'modified';
    modified.symbol_identities = {base: [predecessorIdentity], current: [clangIdentity]};
    const removed = JSON.parse(JSON.stringify(modified));
    removed.id = 'surface-widget-refresh-invalid-removed-owner';
    removed.change_kind = 'removed';
    removed.contract_impact = 'removal';
    removed.consumer_kind = 'compatibility_probe';
    removed.compatibility = {
      old_consumer_paths: ['tests/widget_old.cpp'],
      replacement_consumer_paths: ['src/widget_daemon.cpp'],
      replacement_policy: 'required',
      expected_old_result: 'The old identity is absent.',
      migration_path: 'Use the surviving modified surface.',
      exit_condition: 'The old ownership is retired.'
    };
    removed.symbol_identities = {base: [clangIdentity], current: []};
    removed.task_obligations[0].evidence_roles = ['old_consumer', 'replacement_consumer', 'absence_probe'];
    removed.evidence_contracts = [
      {
        argv: ['tests/widget_old_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-old-observed', probe_id: 'probe-widget-invalid-removed-old', role: 'old_consumer'
      },
      {
        argv: ['tests/widget_refresh_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-refresh-ok', probe_id: 'probe-widget-invalid-removed-replacement', role: 'replacement_consumer'
      },
      {
        argv: ['tests/widget_absence_probe.sh'], expected_exit_codes: [0], kind: 'behavior',
        output_contains: 'widget-old-absent', probe_id: 'probe-widget-invalid-removed-absence', role: 'absence_probe'
      }
    ];
    value.surfaces.push(removed);
    break;
  }
  case 'clang-dynamic-null':
    value.discovery = {compile_commands_path: 'compile_commands.json', mode: 'clang_ast'};
    value.surfaces[0].kind = 'configuration';
    value.surfaces[0].consumer_kind = 'real_entrypoint';
    break;
  default: throw new Error(`unknown fixture mutation: ${expression}`);
}
fs.writeFileSync(output, JSON.stringify(value, null, 2) + '\n');
NODE
}

note 'closed schema 拒绝未知字段、非法 kind/evidence role，以及多行或 secret-like 展示文本'
for mutation in unknown-field invalid-kind invalid-role multiline-name secret-observation; do
    mutate_valid_block "$mutation" "$tmp/$mutation.json"
    write_design "$tmp/$mutation.json"
    run_plan_check
    assert_invalid_diagnostic
done

note 'task obligation 必须覆盖 kind×role 笛卡尔积'
for mutation in split-obligation-cartesian; do
    mutate_valid_block "$mutation" "$tmp/$mutation.json"
    write_design "$tmp/$mutation.json"
    run_plan_check
    assert_invalid_diagnostic
done

note '没有可运行产物的纯 build/install 表面可由下游 build probe 闭合'
mutate_valid_block build-only-surface "$tmp/build-only-surface.json"
write_design "$tmp/build-only-surface.json"
run_plan_check
assert_status 0
mutate_valid_block runnable-build-only-surface "$tmp/runnable-build-only-surface.json"
write_design "$tmp/runnable-build-only-surface.json"
run_plan_check
assert_invalid_diagnostic
mutate_valid_block build-missing-runnable-field "$tmp/build-missing-runnable-field.json"
write_design "$tmp/build-missing-runnable-field.json"
run_plan_check
assert_invalid_diagnostic

note 'evidence contract 必须闭集、完整、唯一且不含自报 Pass、非法 exit、空 marker 或凭据 argv'
for mutation in missing-probe probe-extra-field duplicate-probe-pair invalid-probe-exit empty-probe-marker credential-probe-argv; do
    mutate_valid_block "$mutation" "$tmp/$mutation.json"
    write_design "$tmp/$mutation.json"
    run_plan_check
    assert_invalid_diagnostic
done

note 'surface requirement/task 必须精确命中 delta、叶子 task 与 Covers 交叉边'
for mutation in invalid-requirement invalid-task; do
    mutate_valid_block "$mutation" "$tmp/$mutation.json"
    write_design "$tmp/$mutation.json"
    run_plan_check
    assert_invalid_diagnostic
done

note '无替代 removal 必须由机器可读策略绑定纯 REMOVED requirement，不能靠空数组自我批准'
mutate_valid_block approved-no-replacement-removal "$tmp/approved-no-replacement-removal.json"
write_design "$tmp/approved-no-replacement-removal.json"
run_plan_check
assert_status 0
for mutation in unapproved-no-replacement-removal approved-none-on-added-requirement; do
    mutate_valid_block "$mutation" "$tmp/$mutation.json"
    write_design "$tmp/$mutation.json"
    run_plan_check
    assert_invalid_diagnostic
done

note 'clang_ast 规划只接受 .json compile database，且 C++ internal/external API 不能绕过 symbol identity'
for mutation in clang-null-internal clang-null-external clang-non-json; do
    mutate_valid_block "$mutation" "$tmp/$mutation.json"
    write_design "$tmp/$mutation.json"
    run_plan_check
    assert_invalid_diagnostic
done

note 'clang_ast 的配置或动态入口仍可显式使用 null symbol identity'
mutate_valid_block clang-dynamic-null "$tmp/clang-dynamic-null.json"
write_design "$tmp/clang-dynamic-null.json"
run_plan_check
assert_status 0

note 'clang_ast 的 internal API 提供精确 current symbol identity 后规划合法'
mutate_valid_block clang-valid-internal "$tmp/clang-valid-internal.json"
write_design "$tmp/clang-valid-internal.json"
run_plan_check
assert_status 0

note 'symbol identity 同侧跨 surface 重复必须拒绝，base 到 current 的显式身份迁移允许'
mutate_valid_block clang-duplicate-current-identity "$tmp/clang-duplicate-current-identity.json"
write_design "$tmp/clang-duplicate-current-identity.json"
run_plan_check
assert_invalid_diagnostic
for mutation in clang-added-identity-owned-by-modified-base clang-removed-identity-owned-by-modified-current; do
    mutate_valid_block "$mutation" "$tmp/$mutation.json"
    write_design "$tmp/$mutation.json"
    run_plan_check
    assert_invalid_diagnostic
done
mutate_valid_block clang-cross-side-identity-transfer "$tmp/clang-cross-side-identity-transfer.json"
write_design "$tmp/clang-cross-side-identity-transfer.json"
run_plan_check
assert_status 0

note 'Integration Completeness 唯一区块、空清单与引用闭包规划契约均通过'
