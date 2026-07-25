#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

requested_clang=${AUTOAI_REAL_CLANGXX:-}
if [[ -n "$requested_clang" ]]; then
    if [[ -x "$requested_clang" ]]; then
        real_clang=$requested_clang
    elif command -v "$requested_clang" >/dev/null 2>&1; then
        real_clang=$(command -v "$requested_clang")
    else
        fail "AUTOAI_REAL_CLANGXX 不是可执行文件或可解析命令：$requested_clang"
    fi
elif command -v clang++ >/dev/null 2>&1; then
    real_clang=$(command -v clang++)
else
    note 'SKIP: 未找到真实 clang++；设置 AUTOAI_REAL_CLANGXX=/absolute/path/to/clang++ 可运行本夹具'
    exit 77
fi

real_clang=$(realpath -- "$real_clang")
[[ -x "$real_clang" ]] || fail "真实 clang++ 不可执行：$real_clang"
clang_version=$("$real_clang" --version 2>&1)
[[ "$clang_version" == *clang* || "$clang_version" == *Clang* ]] || \
    fail "AUTOAI_REAL_CLANGXX 没有报告 Clang 版本：$real_clang"

for command_name in git node npm npx; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "真实 clang_ast 生命周期缺少依赖：$command_name"
done

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT
repo="$tmp/managed real clang ast lifecycle"
change=change-engine-ast
change_dir="$repo/openspec/changes/$change"
harness_dir="$change_dir/harness"
surface_id=surface-engine-apply

# The adapter intentionally resolves the exact command name "clang++" from
# PATH.  Use a private alias so AUTOAI_REAL_CLANGXX may point at a versioned
# executable such as clang++-18 without weakening production resolution.
mkdir -p "$tmp/real-clang-bin"
ln -s "$real_clang" "$tmp/real-clang-bin/clang++"
export PATH="$tmp/real-clang-bin:$PATH"
export AUTOAI_REAL_CLANGXX="$real_clang"

init_git_repo "$repo"
mkdir -p "$repo/include" "$repo/src"

cat > "$repo/.gitignore" <<'EOF'
/build/
EOF

cat > "$repo/include/engine.hpp" <<'EOF'
#pragma once

namespace calc {

class Engine {
public:
    int apply(int value) const {
        return value + 1;
    }
};

}
EOF

cat > "$repo/src/main.cpp" <<'EOF'
#include "engine.hpp"

extern "C" int puts(const char*);

int main() {
    if (calc::Engine{}.apply(2) == 4) {
        puts("engine:v2");
    } else {
        puts("engine:v1");
    }
    return 0;
}
EOF

mkdir -p "$repo/tests"
cat > "$repo/tests/engine_behavior_test.cpp" <<'EOF'
#include "engine.hpp"

int main() {
    return calc::Engine{}.apply(2) == 4 ? 0 : 1;
}
EOF

cat > "$repo/tests/unit_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -u
mkdir -p build/ast-real
if "$AUTOAI_REAL_CLANGXX" -std=c++17 -Iinclude \
    tests/engine_behavior_test.cpp -o build/ast-real/engine-unit &&
   build/ast-real/engine-unit; then
    echo ast-unit-green
    exit 0
fi
echo ast-unit-red
exit 1
EOF
chmod 755 "$repo/tests/unit_probe.sh"

cat > "$repo/tests/production_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -u
mkdir -p build/ast-real
if ! "$AUTOAI_REAL_CLANGXX" -std=c++17 -Iinclude \
    src/main.cpp -o build/ast-real/engine-app; then
    echo ast-production-build-failed
    exit 1
fi
output=$(build/ast-real/engine-app)
if [[ "$output" != engine:v2 ]]; then
    echo "ast-production-wrong-output:$output"
    exit 1
fi
echo ast-production-ok
EOF
chmod 755 "$repo/tests/production_probe.sh"

# Keep the database itself reproducible and tracked even though the generated
# Harness ignores compile_commands.json by default.  The adapter replaces the
# recorded driver with its independently resolved real clang++.
cat > "$repo/compile_commands.json" <<EOF
[
  {
    "directory": "$repo",
    "file": "src/main.cpp",
    "arguments": ["clang++", "-I", "include", "-std=c++17", "-c", "src/main.cpp", "-o", "build/main.o"]
  },
  {
    "directory": "$repo",
    "file": "tests/engine_behavior_test.cpp",
    "arguments": ["clang++", "-I", "include", "-std=c++17", "-c", "tests/engine_behavior_test.cpp", "-o", "build/engine_behavior_test.o"]
  }
]
EOF

note '用真实 npm/npx 生成 Harness，并创建显式 clang_ast change'
run_setup "$repo"
assert_status 0
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)

mkdir -p "$change_dir/specs/engine-apply"
cat > "$change_dir/proposal.md" <<'EOF'
## Why

The existing engine operation needs a revised result while preserving its exact C++ signature and production call path.

## What Changes

- Change the implementation of `calc::Engine::apply(int) const`.
- Prove the behavior through both a focused RED/GREEN test and the existing production executable.
- Use real Clang AST discovery to bind the exact method identity and reject unplanned declarations.
- External contract impact: **compatible**.

## Capabilities

### New Capabilities

- `engine-apply-v2`: Observes the revised engine result through the existing production entrypoint.

### Modified Capabilities

- None.

## Impact

No new target, dependency, or public signature is approved.
EOF

cat > "$change_dir/specs/engine-apply/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Observe revised engine result
The existing production executable SHALL observe the revised result through `calc::Engine::apply(int) const`.

#### Scenario: Production process reaches the revised method
- **WHEN** the production probe compiles and runs the existing executable
- **THEN** the process prints `engine:v2` and the probe prints `ast-production-ok`
EOF

cat > "$change_dir/tasks.md" <<'EOF'
## 1. Engine behavior

- [ ] 1 Revise the existing method and preserve its production connection
  - Covers: `specs/engine-apply/spec.md` | `ADDED` | `Observe revised engine result` | `Production process reaches the revised method`
  - Verify: `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
## Context

The engine method already has a production caller. The change keeps the exact signature and uses an explicit Clang AST inventory so an overload or template added in the same header cannot hide behind a path-only review.

## Goals / Non-Goals

**Goals:** Preserve the exact method identity, execute RED → GREEN → REGRESSION, and prove the unchanged production caller reaches the revised implementation.

**Non-Goals:** Add an overload, template, target, dependency, or accept a test-only caller as product integration.

## Decisions

Use the tracked `compile_commands.json`, one exact method identity on both tree sides, and one process-level evidence contract.

## Risks / Trade-offs

Selecting `clang_ast` makes a compatible real `clang++` a fail-closed dependency for this change.

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
  "rationale": "Reuse one existing method and executable; add only focused test probes.",
  "classification": {
    "production": ["include/**", "src/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md"],
    "project_tooling": ["compile_commands.json"],
    "examples": ["examples/**"],
    "generated": [],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 12, "review_at": 30, "hard_limit": 60},
      "touched_files": {"expected": 2, "review_at": 3, "hard_limit": 4},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 50, "review_at": 80, "hard_limit": 120},
      "touched_files": {"expected": 3, "review_at": 4, "hard_limit": 6},
      "new_files": {"expected": 3, "review_at": 4, "hard_limit": 6}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 4, "hard_limit": 12},
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
        "id": "engine-header-review",
        "name": "existing engine declaration review",
        "reason": "The existing public declaration file changes only in commentary; real AST must prove the method identity itself remains exact."
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
    "compile_commands_path": "compile_commands.json",
    "mode": "clang_ast"
  },
  "schema_version": 1,
  "surfaces": [
    {
      "change_kind": "modified",
      "compatibility": null,
      "consumer_kind": "production_caller",
      "consumer_paths": ["src/main.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "engine_app process entrypoint",
      "evidence_contracts": [
        {
          "argv": ["tests/production_probe.sh"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "ast-production-ok",
          "probe_id": "probe-engine-production",
          "role": "current"
        }
      ],
      "expected_observation": "The independently compiled production executable prints engine:v2 and the probe emits ast-production-ok.",
      "id": "surface-engine-apply",
      "kind": "internal_api",
      "name": "calc::Engine::apply(int) const",
      "producer_paths": ["include/engine.hpp"],
      "requirement_refs": [
        {
          "operation": "ADDED",
          "requirement": "Observe revised engine result",
          "scenarios": ["Production process reaches the revised method"],
          "spec_path": "specs/engine-apply/spec.md"
        }
      ],
      "symbol_identities": {
        "base": [
          {
            "canonical_parameter_types": ["int"],
            "canonical_return_type": "int",
            "cv_qualifiers": ["const"],
            "declaration_kind": "method",
            "declaration_path": "include/engine.hpp",
            "qualified_name": "calc::Engine::apply",
            "ref_qualifier": "none",
            "template_parameter_kinds": []
          }
        ],
        "current": [
          {
            "canonical_parameter_types": ["int"],
            "canonical_return_type": "int",
            "cv_qualifiers": ["const"],
            "declaration_kind": "method",
            "declaration_path": "include/engine.hpp",
            "qualified_name": "calc::Engine::apply",
            "ref_qualifier": "none",
            "template_parameter_kinds": []
          }
        ]
      },
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

note '规划检查不执行 Clang；冻结后由真实 AST 同时读取 base/current 树'
(
    cd "$repo"
    git config user.name 'AutoAI Real Clang AST Test'
    git config user.email 'autoai-real-clang-ast@example.invalid'
    scripts/integration_surface_check.sh "$change" --plan-check --json > "$tmp/plan-check.json"
    scripts/openspec_cli.sh validate "$change" --type change --strict --json > "$tmp/strict-plan.json"
    "$AUTOAI_REAL_CLANGXX" -std=c++17 -Iinclude src/main.cpp -o "$tmp/baseline-engine-app"
    test "$("$tmp/baseline-engine-app")" = engine:v1
    git add -A
    git add -f compile_commands.json
    git commit -qm 'approved real clang AST baseline'
    scripts/snapshot_update.sh --freeze-planning-baseline >/dev/null
    scripts/snapshot_update.sh --freeze-implementation-base >/dev/null
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

note '真实编译器先建立 RED'
run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase red --cycle engine-ast --kind behavior --expect-exit 1 \
    --test-path tests/engine_behavior_test.cpp --failure-class contract \
    --expected-failure 'the baseline method still returns value plus one' \
    --match-output ast-unit-red \
    --observed 'the real Clang-built focused test rejected the baseline result' -- \
    tests/unit_probe.sh
assert_status 0
assert_contains "$RUN_OUTPUT" ast-unit-red

note '最小实现进入 GREEN，并用现有 production caller 完成 REGRESSION'
cat > "$repo/include/engine.hpp" <<'EOF'
#pragma once

namespace calc {

class Engine {
public:
    int apply(int value) const {
        // The approved signature remains exact across the implementation change.
        return value + 2;
    }
};

}
EOF

run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase green --cycle engine-ast --kind behavior \
    --path include/engine.hpp -- \
    tests/unit_probe.sh
assert_status 0
assert_contains "$RUN_OUTPUT" ast-unit-green

run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase regression --cycle engine-ast --kind behavior \
    --surface "$surface_id" \
    --path include/engine.hpp \
    --observed 'the real Clang-built production executable reached the revised exact method' -- \
    tests/production_probe.sh
assert_status 0
assert_contains "$RUN_OUTPUT" ast-production-ok

run_managed_at "$repo" scripts/task_verify.sh --complete 1
assert_status 0

note '同一头文件临时加入未规划 overload 和 function template，真实 AST 必须逐符号阻断'
cat > "$repo/include/engine.hpp" <<'EOF'
#pragma once

namespace calc {

class Engine {
public:
    int apply(int value) const {
        // The approved signature remains exact across the implementation change.
        return value + 2;
    }
    int apply(double value) const { return value > 0.0 ? 9 : 0; }
};

template <class T>
T echo(T value) {
    return value;
}

}
EOF

run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase regression --cycle engine-ast --kind behavior \
    --surface "$surface_id" \
    --path include/engine.hpp -- \
    tests/production_probe.sh
assert_status 0

report="$harness_dir/integration-surface-report.json"
run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --refresh --json
assert_status 6
assert_path_exists "$report"
assert_contains "$RUN_OUTPUT" '"status": "orphaned"'

node - "$report" "$real_clang" "$surface_id" <<'NODE'
const fs = require('fs');
const [file, expectedClang, surfaceId] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
if (value.discovery_mode !== 'clang_ast' || value.status !== 'orphaned' ||
    value.discovery_adapter_identity?.id !== 'clang-ast-v1' ||
    value.discovery_adapter_identity?.schema_version !== 1 ||
    !value.discovery_adapter_identity?.sha256?.startsWith('sha256:') ||
    !value.compile_commands_sha256?.startsWith('sha256:') ||
    value.ast_tool_identity?.resolved_path !== expectedClang ||
    !value.ast_tool_identity?.version_sha256?.startsWith('sha256:') ||
    !value.ast_tool_identity?.capability_probe_sha256?.startsWith('sha256:')) {
  throw new Error(`real Clang/tool identity is incomplete: ${JSON.stringify(value)}`);
}
const planned = value.ast_candidates.find(candidate =>
  candidate.change_status === 'modified' &&
  candidate.current_symbol_identity?.qualified_name === 'calc::Engine::apply' &&
  candidate.current_symbol_identity?.canonical_parameter_types?.join(',') === 'int'
);
const overload = value.ast_candidates.find(candidate =>
  candidate.change_status === 'added' &&
  candidate.current_symbol_identity?.qualified_name === 'calc::Engine::apply' &&
  candidate.current_symbol_identity?.canonical_parameter_types?.join(',') === 'double'
);
const template = value.ast_candidates.find(candidate =>
  candidate.change_status === 'added' &&
  candidate.current_symbol_identity?.qualified_name === 'calc::echo' &&
  candidate.current_symbol_identity?.declaration_kind === 'function_template' &&
  candidate.current_symbol_identity?.template_parameter_kinds?.join(',') === 'type'
);
if (!planned || !overload || !template) {
  throw new Error(`real overload/template candidate identities are incomplete: ${JSON.stringify(value.ast_candidates)}`);
}
for (const candidate of [planned, overload, template]) {
  if (!/^clang-ast-[0-9a-f]{16}$/.test(candidate.candidate_id)) {
    throw new Error(`unstable AST candidate ID: ${candidate.candidate_id}`);
  }
}
if (new Set(value.ast_candidates.map(candidate => candidate.candidate_id)).size !== value.ast_candidates.length ||
    overload.candidate_scope !== 'public_contract' || template.candidate_scope !== 'public_contract') {
  throw new Error('real AST candidate IDs collided or public scope was lost');
}
const unmatched = new Set(value.unmatched_candidates.map(candidate => candidate.candidate_id));
if (!unmatched.has(overload.candidate_id) || !unmatched.has(template.candidate_id)) {
  throw new Error('unplanned overload/template did not become blocking unmatched candidates');
}
const binding = value.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
if (!binding?.candidate_bindings.some(item =>
  item.candidate_id === planned.candidate_id && item.role === 'producer' && item.tree_side === 'both')) {
  throw new Error('planned exact method candidate was not bound across both tree sides');
}
NODE

run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --check --json
assert_status 6
assert_contains "$RUN_OUTPUT" '"status": "orphaned"'

note '移除未规划表面后刷新并复检，真实 AST 输出必须确定且无孤儿项'
cat > "$repo/include/engine.hpp" <<'EOF'
#pragma once

namespace calc {

class Engine {
public:
    int apply(int value) const {
        // The approved signature remains exact across the implementation change.
        return value + 2;
    }
};

}
EOF

run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 1 \
    --phase regression --cycle engine-ast --kind behavior \
    --surface "$surface_id" \
    --path include/engine.hpp -- \
    tests/production_probe.sh
assert_status 0

run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --refresh --json
assert_status 0
assert_contains "$RUN_OUTPUT" '"status": "complete"'
report_sha=$(sha256sum -- "$report" | awk '{print $1}')

node - "$report" "$real_clang" "$surface_id" <<'NODE'
const fs = require('fs');
const [file, expectedClang, surfaceId] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const planned = value.ast_candidates.filter(candidate =>
  candidate.current_symbol_identity?.qualified_name === 'calc::Engine::apply'
);
if (value.status !== 'complete' || value.unmatched_candidates.length !== 0 ||
    value.ast_tool_identity?.resolved_path !== expectedClang || planned.length !== 1 ||
    planned[0].change_status !== 'modified' ||
    planned[0].current_symbol_identity?.canonical_parameter_types?.join(',') !== 'int') {
  throw new Error(`real Clang final closure mismatch: ${JSON.stringify(value)}`);
}
const binding = value.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
if (!binding?.candidate_bindings.some(item => item.candidate_id === planned[0].candidate_id)) {
  throw new Error('final exact method candidate is not bound');
}
NODE

run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --check --json
assert_status 0
assert_contains "$RUN_OUTPUT" '"status": "complete"'
[[ "$report_sha" == "$(sha256sum -- "$report" | awk '{print $1}')" ]] || \
    fail 'read-only AST check rewrote the persisted report'

note '从 PATH 移除 clang++ 时，生成的真实 adapter 必须 Blocked 且不能回退 reviewed_inventory'
node_bin=$(command -v node)
mkdir -p "$tmp/no-clang-bin"
missing_output=
missing_status=0
set +e
missing_output=$(PATH="$tmp/no-clang-bin" "$node_bin" - \
    "$repo/scripts/clang_ast_surface_adapter.js" "$repo" \
    "$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).implementation_base_commit" "$harness_dir/ai_snapshot.json")" 2>&1 <<'NODE'
const [adapterFile, root, base] = process.argv.slice(2);
const identity = {
  canonical_parameter_types: ['int'],
  canonical_return_type: 'int',
  cv_qualifiers: ['const'],
  declaration_kind: 'method',
  declaration_path: 'include/engine.hpp',
  qualified_name: 'calc::Engine::apply',
  ref_qualifier: 'none',
  template_parameter_kinds: []
};
const plan = {
  block: {
    surfaces: [{
      id: 'surface-engine-apply',
      kind: 'internal_api',
      change_kind: 'modified',
      producer_paths: ['include/engine.hpp'],
      symbol_identities: {base: [identity], current: [identity]}
    }]
  }
};
const scope = {
  logical_changes: [
    {path: 'include/engine.hpp', old_path: null, change_status: 'modified', classifications: ['production']}
  ]
};
const classification = {
  production: ['include/**', 'src/**'], tests: ['tests/**'], project_docs: ['README.md'],
  project_tooling: ['CMakeLists.txt', 'compile_commands.json'], examples: ['examples/**'],
  generated: [], vendor: ['vendor/**']
};
try {
  require(adapterFile).discover({
    root,
    change: 'change-engine-ast',
    implementationBase: base,
    compileCommandsPath: 'compile_commands.json',
    plan,
    scope,
    classification
  });
  throw new Error('missing clang unexpectedly succeeded');
} catch (error) {
  if (error.gateStatus !== 'blocked' || error.message !== 'clang++_not_found') {
    throw error;
  }
  process.stdout.write(JSON.stringify({status: error.gateStatus, reason: error.message}) + '\n');
  process.exit(6);
}
NODE
)
missing_status=$?
set -e
[[ "$missing_status" -eq 6 ]] || fail "缺少 clang++ 的 adapter 退出码错误：$missing_status"
assert_contains "$missing_output" '"status":"blocked"'
assert_contains "$missing_output" '"reason":"clang++_not_found"'
[[ "$report_sha" == "$(sha256sum -- "$report" | awk '{print $1}')" ]] || \
    fail 'missing-tool probe rewrote the successful AST report'

note '独立 Evaluator 用真实 Clang 重新构建生产入口，并绑定同一 exact probe'
run_managed_at "$repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_managed_at "$repo" scripts/evaluator_check.sh --run \
    --kind behavior --surface "$surface_id" \
    --expected 'A clean real-Clang build reaches the planned exact method through the existing production process.' \
    --observed 'The independently rebuilt process printed engine:v2 and the planned success marker.' -- \
    tests/production_probe.sh
assert_status 0
assert_contains "$RUN_OUTPUT" ast-production-ok

baseline="$harness_dir/evaluation-baseline.json"
ledger="$harness_dir/evaluation-command-ledger.json"
evaluation="$harness_dir/evaluation.json"

node - "$baseline" "$harness_dir/change-footprint.json" "$ledger" "$report" \
    "$evaluation" "$change" "$surface_id" "$repo" "$real_clang" <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const [
  baselineFile, footprintFile, ledgerFile, reportFile, outputFile,
  change, surfaceId, repoRoot, expectedClang
] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const footprint = JSON.parse(fs.readFileSync(footprintFile));
const ledger = JSON.parse(fs.readFileSync(ledgerFile));
const report = JSON.parse(fs.readFileSync(reportFile));
const commands = [...ledger.commands];
if (baseline.schema_version !== 3 || ledger.schema_version !== 2 || commands.length !== 1 ||
    commands[0].result !== 'Pass' ||
    commands[0].argv.join('\0') !== 'tests/production_probe.sh' ||
    JSON.stringify(commands[0].surface_probe_bindings) !== JSON.stringify([{
      surface_id: surfaceId,
      role: 'current',
      probe_id: 'probe-engine-production'
    }])) {
  throw new Error('independent exact real-Clang probe ledger is incomplete');
}
if (report.discovery_mode !== 'clang_ast' || report.status !== 'complete' ||
    report.ast_tool_identity?.resolved_path !== expectedClang ||
    report.unmatched_candidates.length !== 0 || footprint.status !== 'within_expected') {
  throw new Error('real-Clang inventory or Implementation Economy baseline is not complete');
}

const policy = require(repoRoot + '/scripts/manifest_policy.js').loadManifest(repoRoot);
const base = baseline.review_input.implementation_base_commit;
const changed = cp.execFileSync('git', ['diff', '--name-only', '-z', base, '--'], {cwd: repoRoot})
  .toString('utf8').split('\0');
const untracked = cp.execFileSync(
  'git', ['ls-files', '--others', '--exclude-standard', '-z'], {cwd: repoRoot}
).toString('utf8').split('\0');
const implementationPaths = [...new Set([...changed, ...untracked].filter(Boolean))]
  .filter(item => !policy.isManaged(item)).sort();
const expectedImplementationPaths = ['include/engine.hpp'];
if (JSON.stringify(implementationPaths) !== JSON.stringify(expectedImplementationPaths)) {
  throw new Error(`unexpected real-Clang implementation inventory: ${JSON.stringify(implementationPaths)}`);
}

const commandIds = commands.map(command => command.id);
const evidenceFinished = Math.max(
  Date.parse(baseline.started_at), ...commands.map(command => Date.parse(command.finished_at)));
const reviewedAt = new Date(evidenceFinished).toISOString();
const evaluatedAt = new Date(Math.max(Date.now(), evidenceFinished)).toISOString();
const requirementRef = {
  spec_path: 'specs/engine-apply/spec.md',
  operation: 'ADDED',
  requirement: 'Observe revised engine result',
  scenarios: ['Production process reaches the revised method']
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
if (!reportBinding) throw new Error('real-Clang surface report binding missing');
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
const candidatePaths = candidate => {
  if (candidate.source === 'clang_ast') {
    return [...new Set([
      candidate.base_symbol_identity?.declaration_path,
      candidate.current_symbol_identity?.declaration_path
    ].filter(Boolean))].sort();
  }
  return [...new Set([candidate.old_path, candidate.path].filter(Boolean))].sort();
};
const candidateAssessments = allCandidates.map(candidate => {
  const roles = [...new Set(typedByCandidate.get(candidate.candidate_id) || [])]
    .sort((a, b) => ['producer', 'consumer'].indexOf(a) - ['producer', 'consumer'].indexOf(b));
  if (!roles.length) throw new Error(`complete AST report left ${candidate.candidate_id} unbound`);
  const logicalPaths = candidatePaths(candidate);
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
    reason: 'The candidate is mapped to the approved exact method or its reviewed producer path.',
    producer_paths: roles.includes('producer')
      ? logicalPaths.filter(item => reportBinding.producer_paths.includes(item)) : [],
    implementation_consumer: null,
    evidence_paths: logicalPaths,
    evidence_command_ids: commandIds,
    orphan_ids: []
  };
}).sort((a, b) => a.candidate_id.localeCompare(b.candidate_id));

const structuralIds = footprint.structural_candidates.map(item => item.candidate_id);
if (structuralIds.length !== 1 || report.structural_candidates.length !== 1 ||
    report.ast_candidates.length !== 1 ||
    report.ast_candidates[0].current_symbol_identity?.qualified_name !== 'calc::Engine::apply') {
  throw new Error('expected one approved header candidate and one exact real AST method candidate');
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
      reason: 'The implementation path has one approved production classification.',
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
          reason: 'The existing production program is rebuilt by real Clang and observes the revised method.',
          evidence_paths: report.changed_production_paths,
          evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        {
          surface: 'install',
          applicability: 'not_applicable',
          result: null,
          reason: 'This internal method change has no install surface.',
          evidence_paths: [],
          evidence_command_ids: [],
          not_applicable_reason: 'The approved implementation base defines no install rule.'
        },
        {
          surface: 'package',
          applicability: 'not_applicable',
          result: null,
          reason: 'This internal method change is not a package export.',
          evidence_paths: [],
          evidence_command_ids: [],
          not_applicable_reason: 'The approved implementation base defines no package export.'
        },
        {
          surface: 'ci',
          applicability: 'not_applicable',
          result: null,
          reason: 'The disposable real-Clang lifecycle repository has no CI configuration.',
          evidence_paths: [],
          evidence_command_ids: [],
          not_applicable_reason: 'No CI file exists in the approved implementation base.'
        }
      ]
    },
    reuse_assessments: [],
    structural_assessments: [{
      allowance_id: 'engine-header-review',
      candidate_ids: structuralIds,
      result: 'Pass',
      reason: 'The existing header is explicitly reviewed and the real AST proves its exact method identity.',
      evidence_paths: ['include/engine.hpp'],
      evidence_command_ids: commandIds
    }],
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: 'criterion-real-clang-engine',
    description: 'The real-Clang-built production process observes the revised exact engine method.',
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
      reason: 'Every changed production and real AST candidate is mapped; no overload or template remains.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    candidate_assessments: candidateAssessments,
    surface_assessments: [{
      surface_id: surfaceId,
      result: 'Pass',
      reason: 'The independent exact process probe closes the current role through the production caller.',
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

node - "$baseline" "$evaluation" "$surface_id" "$real_clang" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const [baselineFile, evaluationFile, surfaceId, expectedClang] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
const digest = 'sha256:' + crypto.createHash('sha256')
  .update(fs.readFileSync(evaluationFile)).digest('hex');
if (baseline.status !== 'complete' || baseline.evaluation_json_sha256 !== digest ||
    evaluation.verdict !== 'Pass' ||
    evaluation.integration_completeness?.surface_assessments?.[0]?.surface_id !== surfaceId ||
    evaluation.integration_completeness?.result !== 'Pass' ||
    evaluation.integration_completeness?.orphan_surfaces?.length !== 0) {
  throw new Error('sealed real-Clang AST Evaluation is incomplete');
}
if (evaluation.commands.length !== 1 ||
    evaluation.commands[0].surface_probe_bindings?.[0]?.probe_id !== 'probe-engine-production') {
  throw new Error(`sealed real-Clang command contract mismatch for ${expectedClang}`);
}
NODE

note 'Pass verdict 通过 archive；主 specs 与完整 AST/evidence 随 change 持久化'
run_managed_at "$repo" scripts/change_archive.sh "$change"
assert_status 0
archived_as=$(node -p \
    "JSON.parse(require('fs').readFileSync(process.argv[1])).last_archived_change.archived_as" \
    "$repo/ai_snapshot.json")
archived_dir="$repo/openspec/changes/archive/$archived_as"
assert_path_absent "$change_dir"
assert_path_exists "$archived_dir/harness/integration-surface-report.json"
assert_path_exists "$archived_dir/harness/evaluation.json"
assert_path_exists "$archived_dir/harness/verification.json"
assert_path_exists "$repo/openspec/specs/engine-apply/spec.md"
assert_file_contains "$repo/openspec/specs/engine-apply/spec.md" \
    '### Requirement: Observe revised engine result'

node - "$repo/ai_snapshot.json" "$archived_dir/harness/integration-surface-report.json" \
    "$archived_dir/harness/evaluation.json" "$change" "$archived_as" \
    "$real_clang" "$surface_id" <<'NODE'
const fs = require('fs');
const [
  rootFile, reportFile, evaluationFile, change, archivedAs, expectedClang, surfaceId
] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(rootFile));
const report = JSON.parse(fs.readFileSync(reportFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
const ast = report.ast_candidates;
if (root.active_change !== null ||
    root.last_archived_change?.change_name !== change ||
    root.last_archived_change?.archived_as !== archivedAs ||
    report.discovery_mode !== 'clang_ast' || report.status !== 'complete' ||
    report.ast_tool_identity?.resolved_path !== expectedClang ||
    ast.length !== 1 ||
    ast[0].current_symbol_identity?.qualified_name !== 'calc::Engine::apply' ||
    ast[0].current_symbol_identity?.canonical_parameter_types?.join(',') !== 'int' ||
    evaluation.verdict !== 'Pass' ||
    evaluation.integration_completeness?.result !== 'Pass' ||
    evaluation.integration_completeness?.surface_assessments?.[0]?.surface_id !== surfaceId ||
    evaluation.integration_completeness?.orphan_surfaces?.length !== 0) {
  throw new Error('archived real-Clang AST closure state mismatch');
}
NODE

clang_version_first_line=${clang_version%%$'\n'*}
note "真实 Clang AST 从 TDD、孤儿阻断、独立 Evaluation 到 archive 的生命周期通过：$clang_version_first_line"
