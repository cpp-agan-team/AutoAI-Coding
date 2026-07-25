#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT
repo="$tmp/managed breaking multi change"
sibling=add-greeting-locale
change=replace-render-public-contract
change_dir="$repo/openspec/changes/$change"
harness_dir="$change_dir/harness"

for command_name in cmake ctest c++ node git npm npx; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "BREAKING 受管真实生命周期缺少依赖：$command_name"
done

init_git_repo "$repo"
mkdir -p "$repo/include/greeting" "$repo/src" "$repo/tests" "$repo/consumers"

cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_managed_breaking_multichange LANGUAGES CXX)

include(CTest)

add_library(greeting_api STATIC src/greeting.cpp)
target_compile_features(greeting_api PUBLIC cxx_std_17)
target_include_directories(greeting_api
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

add_executable(greeting_cli src/greeting_cli.cpp)
target_link_libraries(greeting_cli PRIVATE greeting_api)

add_executable(greeting_api_test tests/greeting_test.cpp)
target_link_libraries(greeting_api_test PRIVATE greeting_api)
add_test(NAME greeting_api_test COMMAND greeting_api_test)

# This target models an in-repository downstream consumer that must be migrated
# together with an intentional public-contract break.
add_executable(greeting_downstream consumers/downstream.cpp)
target_link_libraries(greeting_downstream PRIVATE greeting_api)

install(TARGETS greeting_api ARCHIVE DESTINATION lib)
install(FILES include/greeting/api.hpp DESTINATION include/greeting)
EOF

cat > "$repo/include/greeting/api.hpp" <<'EOF'
#pragma once

#include <string>
#include <string_view>

namespace greeting {
std::string render(std::string_view name);
}
EOF

cat > "$repo/src/greeting.cpp" <<'EOF'
#include "greeting/api.hpp"

namespace greeting {
std::string render(const std::string_view name) {
    return "Hello, " + std::string(name);
}
}
EOF

cat > "$repo/src/greeting_cli.cpp" <<'EOF'
#include "greeting/api.hpp"

#include <iostream>

int main() {
    std::cout << greeting::render("Ada") << '\n';
    return 0;
}
EOF

cat > "$repo/tests/greeting_test.cpp" <<'EOF'
#include "greeting/api.hpp"

int main() {
    return greeting::render("Ada") == "Hello, Ada" ? 0 : 1;
}
EOF

cat > "$repo/consumers/downstream.cpp" <<'EOF'
#include "greeting/api.hpp"

#include <iostream>

int main() {
    std::cout << greeting::render("Grace") << '\n';
    return 0;
}
EOF

# Kept unchanged by the implementation: its expected compile rejection proves
# that the archived contract really is BREAKING for an unmigrated caller.
cat > "$repo/consumers/legacy_probe.cpp" <<'EOF'
#include "greeting/api.hpp"

int main() {
    return greeting::render("Legacy").empty() ? 1 : 0;
}
EOF

note '真实初始化 medium C++/CMake Harness，并建立待迁移的主规格'
run_setup "$repo"
assert_status 0
version=$(cd "$repo" && scripts/openspec_cli.sh --version)
[[ "$version" == 1.6.0 ]] || fail "BREAKING 闭环没有使用固定 OpenSpec 1.6.0：$version"

mkdir -p "$repo/openspec/specs/greeting-api"
cat > "$repo/openspec/specs/greeting-api/spec.md" <<'EOF'
# Greeting API Specification

## Purpose

Define the public rendering contract consumed by C++ callers.

## Requirements

### Requirement: Render a named greeting
The library SHALL render a greeting from a name string supplied directly by the caller.

#### Scenario: Render a named greeting
- **WHEN** a caller supplies the name `Ada`
- **THEN** the library returns `Hello, Ada`
EOF

note '同一工作树创建 sibling change，再显式切换到 BREAKING active change'
(
    cd "$repo"
    scripts/change_new.sh "$sibling" >/dev/null
    printf 'sibling-evidence-remains-isolated\n' > \
        "openspec/changes/$sibling/harness/multichange-sentinel.txt"
    scripts/change_new.sh "$change" --switch >/dev/null
)

mkdir -p "$change_dir/specs/greeting-api"
cat > "$change_dir/proposal.md" <<'EOF'
## Why

Callers now require explicit punctuation, and silently choosing punctuation inside the library is no longer acceptable.

## What Changes

- **BREAKING**: Replace `render(std::string_view)` with `render(RenderRequest)`.
- Require every source consumer to migrate to the typed request contract.
- Preserve the existing library, CLI, test, install, and downstream target topology.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `greeting-api`: Replace the public render call contract and require explicit punctuation.

## Impact

Existing source consumers do not compile until they construct `RenderRequest`; no compatibility overload is retained.
EOF

cat > "$change_dir/specs/greeting-api/spec.md" <<'EOF'
## MODIFIED Requirements

### Requirement: Render a named greeting
The library SHALL render a greeting from a `RenderRequest` containing both name and punctuation.

#### Scenario: Render a named greeting
- **WHEN** a caller supplies name `Ada` and punctuation `!`
- **THEN** the library returns `Hello, Ada!`
EOF

cat > "$change_dir/tasks.md" <<'EOF'
## 1. Public contract implementation

- [ ] 1 Replace the public render signature and migrate in-tree product targets
  - Covers: `specs/greeting-api/spec.md` | `MODIFIED` | `Render a named greeting` | `Render a named greeting`
  - Verify: `build`, `test`

## 2. Consumer migration proof

- [ ] 2 Prove legacy rejection and installed downstream migration
  - Covers: `specs/greeting-api/spec.md` | `MODIFIED` | `Render a named greeting` | `Render a named greeting`
  - Verify: `static`, `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
## Context

The repository contains a public C++ library, CLI, CTest target, install surface, and downstream executable. A separate sibling OpenSpec change remains unarchived while this change is implemented.

## Goals / Non-Goals

**Goals:** Make punctuation explicit, migrate all approved in-tree consumers, prove an old caller fails to compile, and prove an installed consumer builds and runs.

**Non-Goals:** Add a compatibility overload, new CMake target, third-party dependency, or production file.

## Decisions

Introduce one aggregate `RenderRequest` in the existing header and reuse the existing `render` implementation and all current build targets.

## Risks / Trade-offs

This is intentionally source-incompatible. The migration evidence must demonstrate both the legacy compile rejection and the successful typed replacement.

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
  "profile": "medium",
  "rationale": "The public-contract break crosses library, CLI, test, install, and downstream-consumer surfaces, but reuses the existing target graph and files.",
  "classification": {
    "production": ["include/**", "src/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md"],
    "project_tooling": ["CMakeLists.txt"],
    "examples": ["consumers/**"],
    "generated": [],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 20, "review_at": 35, "hard_limit": 60},
      "touched_files": {"expected": 3, "review_at": 5, "hard_limit": 8},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 16, "review_at": 20, "hard_limit": 30},
      "touched_files": {"expected": 2, "review_at": 3, "hard_limit": 4},
      "new_files": {"expected": 1, "review_at": 2, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 4, "review_at": 10, "hard_limit": 20},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "bytes": {"expected": 0, "review_at": 1024, "hard_limit": 4096}
    }
  },
  "structural_allowances": {
    "public_contracts": [{
      "id": "contract-render-request",
      "name": "greeting::RenderRequest and render(RenderRequest)",
      "reason": "The approved BREAKING requirement makes punctuation an explicit typed caller responsibility."
    }],
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
      "compatibility": {
        "old_consumer_paths": ["consumers/legacy_probe.cpp"],
        "replacement_consumer_paths": ["consumers/downstream.cpp"],
        "replacement_policy": "required",
        "expected_old_result": "The compiler rejects the removed render(string_view) contract.",
        "migration_path": "Construct RenderRequest with an explicit name and punctuation, then rebuild against installed artifacts.",
        "exit_condition": "Every supported downstream caller uses RenderRequest and the legacy compile-rejection probe remains green."
      },
      "consumer_kind": "representative_external",
      "consumer_paths": ["consumers/downstream.cpp"],
      "contract_impact": "breaking",
      "entrypoint": "installed greeting_api archive and public header",
      "evidence_contracts": [
        {
          "argv": ["bash", "-c", "rm -rf build/surface-behavior build/surface-behavior-install && cmake -S . -B build/surface-behavior >/dev/null && cmake --build build/surface-behavior --parallel 2 >/dev/null && cmake --install build/surface-behavior --prefix build/surface-behavior-install >/dev/null && if c++ -std=c++17 consumers/legacy_probe.cpp -Ibuild/surface-behavior-install/include build/surface-behavior-install/lib/libgreeting_api.a -o build/surface-behavior/legacy-probe >/dev/null 2>&1; then exit 1; fi && c++ -std=c++17 consumers/downstream.cpp -Ibuild/surface-behavior-install/include build/surface-behavior-install/lib/libgreeting_api.a -o build/surface-behavior/replacement && tests/expected_output.sh ./build/surface-behavior/replacement 'Hello, Grace?' installed-behavior-mismatch && echo installed-behavior-probe-ok"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "installed-behavior-probe-ok",
          "probe_id": "probe-installed-render-behavior-old",
          "role": "old_consumer"
        },
        {
          "argv": ["bash", "-c", "rm -rf build/surface-behavior build/surface-behavior-install && cmake -S . -B build/surface-behavior >/dev/null && cmake --build build/surface-behavior --parallel 2 >/dev/null && cmake --install build/surface-behavior --prefix build/surface-behavior-install >/dev/null && if c++ -std=c++17 consumers/legacy_probe.cpp -Ibuild/surface-behavior-install/include build/surface-behavior-install/lib/libgreeting_api.a -o build/surface-behavior/legacy-probe >/dev/null 2>&1; then exit 1; fi && c++ -std=c++17 consumers/downstream.cpp -Ibuild/surface-behavior-install/include build/surface-behavior-install/lib/libgreeting_api.a -o build/surface-behavior/replacement && tests/expected_output.sh ./build/surface-behavior/replacement 'Hello, Grace?' installed-behavior-mismatch && echo installed-behavior-probe-ok"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "installed-behavior-probe-ok",
          "probe_id": "probe-installed-render-behavior-replacement",
          "role": "replacement_consumer"
        },
        {
          "argv": ["bash", "-c", "rm -rf build/surface-static build/surface-static-install && cmake -S . -B build/surface-static >/dev/null && cmake --build build/surface-static --parallel 2 >/dev/null && cmake --install build/surface-static --prefix build/surface-static-install >/dev/null && if c++ -std=c++17 consumers/legacy_probe.cpp -Ibuild/surface-static-install/include build/surface-static-install/lib/libgreeting_api.a -o build/surface-static/legacy-probe >/dev/null 2>&1; then exit 1; fi && c++ -std=c++17 consumers/downstream.cpp -Ibuild/surface-static-install/include build/surface-static-install/lib/libgreeting_api.a -o build/surface-static/replacement && echo installed-static-probe-ok"],
          "expected_exit_codes": [0],
          "kind": "static",
          "output_contains": "installed-static-probe-ok",
          "probe_id": "probe-installed-render-static-old",
          "role": "old_consumer"
        },
        {
          "argv": ["bash", "-c", "rm -rf build/surface-static build/surface-static-install && cmake -S . -B build/surface-static >/dev/null && cmake --build build/surface-static --parallel 2 >/dev/null && cmake --install build/surface-static --prefix build/surface-static-install >/dev/null && if c++ -std=c++17 consumers/legacy_probe.cpp -Ibuild/surface-static-install/include build/surface-static-install/lib/libgreeting_api.a -o build/surface-static/legacy-probe >/dev/null 2>&1; then exit 1; fi && c++ -std=c++17 consumers/downstream.cpp -Ibuild/surface-static-install/include build/surface-static-install/lib/libgreeting_api.a -o build/surface-static/replacement && echo installed-static-probe-ok"],
          "expected_exit_codes": [0],
          "kind": "static",
          "output_contains": "installed-static-probe-ok",
          "probe_id": "probe-installed-render-static-replacement",
          "role": "replacement_consumer"
        }
      ],
      "expected_observation": "The old source fails to compile while the migrated installed-artifact consumer compiles, links, runs, and prints explicit punctuation.",
      "id": "surface-installed-render-api",
      "kind": "external_api",
      "name": "installed greeting render API",
      "producer_paths": ["include/greeting/api.hpp", "src/greeting.cpp"],
      "requirement_refs": [
        {
          "operation": "MODIFIED",
          "requirement": "Render a named greeting",
          "scenarios": ["Render a named greeting"],
          "spec_path": "specs/greeting-api/spec.md"
        }
      ],
      "symbol_identities": null,
      "task_ids": ["2"],
      "task_obligations": [
        {
          "evidence_roles": ["old_consumer", "replacement_consumer"],
          "task_id": "2",
          "verify_kinds": ["behavior", "static"]
        }
      ],
      "verify_kinds": ["behavior", "static"]
    },
    {
      "change_kind": "modified",
      "compatibility": null,
      "consumer_kind": "real_entrypoint",
      "consumer_paths": ["src/greeting_cli.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "greeting_cli executable",
      "evidence_contracts": [
        {
          "argv": ["bash", "-c", "rm -rf build/surface-cli && cmake -S . -B build/surface-cli >/dev/null && cmake --build build/surface-cli --parallel 2 >/dev/null && ctest --test-dir build/surface-cli --output-on-failure && tests/expected_output.sh ./build/surface-cli/greeting_cli 'Hello, Ada!' cli-punctuation-mismatch && echo greeting-cli-probe-ok"],
          "expected_exit_codes": [0],
          "kind": "test",
          "output_contains": "greeting-cli-probe-ok",
          "probe_id": "probe-greeting-cli-test-current",
          "role": "current"
        }
      ],
      "expected_observation": "The real CLI executable invokes the migrated API and prints Hello, Ada!.",
      "id": "surface-greeting-cli",
      "kind": "cli",
      "name": "greeting CLI entrypoint",
      "producer_paths": ["src/greeting_cli.cpp"],
      "requirement_refs": [
        {
          "operation": "MODIFIED",
          "requirement": "Render a named greeting",
          "scenarios": ["Render a named greeting"],
          "spec_path": "specs/greeting-api/spec.md"
        }
      ],
      "symbol_identities": null,
      "task_ids": ["1"],
      "task_obligations": [
        {
          "evidence_roles": ["current"],
          "task_id": "1",
          "verify_kinds": ["test"]
        }
      ],
      "verify_kinds": ["test"]
    }
  ]
}
```
<!-- /autoai:integration-completeness:v1 -->
EOF

note '提交主规格、双 change 规划和可构建基线，再冻结 planning/implementation base'
(
    cd "$repo"
    git config user.name 'AutoAI Breaking Lifecycle Test'
    git config user.email 'autoai-breaking-lifecycle@example.invalid'
    cmake -S . -B build/baseline >/dev/null
    cmake --build build/baseline --parallel 2 >/dev/null
    ctest --test-dir build/baseline --output-on-failure >/dev/null
    test "$(./build/baseline/greeting_cli)" = 'Hello, Ada'
    test "$(./build/baseline/greeting_downstream)" = 'Hello, Grace'
    git add -A
    git commit -qm 'approved multi-change breaking baseline'
    scripts/snapshot_update.sh --freeze-planning-baseline >/dev/null
    scripts/snapshot_update.sh --freeze-implementation-base >/dev/null
)

node - "$repo/ai_snapshot.json" "$harness_dir/ai_snapshot.json" \
    "$harness_dir/verification.json" "$(git -C "$repo" rev-parse HEAD)" "$change" <<'NODE'
const fs = require('fs');
const [rootFile, localFile, verificationFile, head, change] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(rootFile, 'utf8'));
const local = JSON.parse(fs.readFileSync(localFile, 'utf8'));
const verification = JSON.parse(fs.readFileSync(verificationFile, 'utf8'));
if (root.active_change !== change ||
    local.schema_version !== 4 ||
    !local.planned_base_specs_fingerprint?.startsWith('sha256:') ||
    !local.planned_integration_completeness_sha256?.startsWith('sha256:') ||
    local.implementation_base_commit !== head ||
    !local.implementation_baselined_at || Object.hasOwn(local, 'active_change') ||
    verification.schema_version !== 3 || verification.change_name !== change ||
    verification.migration !== null || verification.tasks.length !== 0) {
  throw new Error('multi-change planning/implementation baselines were not frozen safely');
}
NODE

note 'Generator 先用一个不可变黑盒测试为两个 task 记录真实 RED'
cat > "$repo/tests/expected_output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
actual=$($1)
if [[ "$actual" != "$2" ]]; then
    printf '%s\n' "$3"
    exit 1
fi
EOF
chmod +x "$repo/tests/expected_output.sh"

(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
    scripts/task_verify.sh 1 --phase red --cycle public-contract --kind test \
        --expect-exit 1 --test-path tests/expected_output.sh \
        --path tests/expected_output.sh --failure-class behavior \
        --expected-failure 'The existing CLI omits caller-provided punctuation.' \
        --match-output cli-punctuation-mismatch \
        --observed 'The baseline CLI built successfully and exposed the approved missing behavior.' -- \
        bash -c 'rm -rf build/generator && cmake -S . -B build/generator >/dev/null && cmake --build build/generator --parallel 2 >/dev/null && tests/expected_output.sh ./build/generator/greeting_cli "Hello, Ada!" cli-punctuation-mismatch'

    scripts/task_verify.sh 2 --phase red --cycle migration-proof --kind behavior \
        --expect-exit 1 --test-path tests/expected_output.sh \
        --path tests/expected_output.sh --failure-class contract \
        --expected-failure 'The installed baseline API cannot produce explicit downstream punctuation.' \
        --match-output downstream-punctuation-mismatch \
        --observed 'The baseline installed consumer built and exposed the approved migration gap.' -- \
        bash -c 'rm -rf build/generator-install && cmake --install build/generator --prefix build/generator-install >/dev/null && c++ -std=c++17 consumers/downstream.cpp -Ibuild/generator-install/include build/generator-install/lib/libgreeting_api.a -o build/generator/installed-downstream && tests/expected_output.sh ./build/generator/installed-downstream "Hello, Grace?" downstream-punctuation-mismatch'
)

note 'Generator 实施最小 BREAKING GREEN，并迁移所有批准的 in-tree consumers'
cat > "$repo/include/greeting/api.hpp" <<'EOF'
#pragma once

#include <string>
#include <string_view>

namespace greeting {

struct RenderRequest {
    std::string_view name;
    std::string_view punctuation;
};

std::string render(RenderRequest request);

}
EOF

cat > "$repo/src/greeting.cpp" <<'EOF'
#include "greeting/api.hpp"

namespace greeting {
std::string render(const RenderRequest request) {
    return "Hello, " + std::string(request.name) + std::string(request.punctuation);
}
}
EOF

sed -i 's/render("Ada")/render({"Ada", "!"})/' "$repo/src/greeting_cli.cpp"
sed -i 's/render("Ada") == "Hello, Ada"/render({"Ada", "!"}) == "Hello, Ada!"/' \
    "$repo/tests/greeting_test.cpp"
sed -i 's/render("Grace")/render({"Grace", "?"})/' "$repo/consumers/downstream.cpp"

(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null

    scripts/task_verify.sh 1 --phase green --cycle public-contract --kind test \
        --path include/greeting/api.hpp --path src/greeting.cpp \
        --path src/greeting_cli.cpp --path tests/greeting_test.cpp \
        --path tests/expected_output.sh -- \
        bash -c 'rm -rf build/generator && cmake -S . -B build/generator >/dev/null && cmake --build build/generator --parallel 2 >/dev/null && tests/expected_output.sh ./build/generator/greeting_cli "Hello, Ada!" cli-punctuation-mismatch'
    scripts/task_verify.sh 2 --phase green --cycle migration-proof --kind behavior \
        --path consumers/downstream.cpp --path tests/expected_output.sh -- \
        bash -c 'rm -rf build/generator-install && cmake --install build/generator --prefix build/generator-install >/dev/null && c++ -std=c++17 consumers/downstream.cpp -Ibuild/generator-install/include build/generator-install/lib/libgreeting_api.a -o build/generator/installed-downstream && tests/expected_output.sh ./build/generator/installed-downstream "Hello, Grace?" downstream-punctuation-mismatch'

    scripts/task_verify.sh 1 --phase regression --cycle public-contract --kind build \
        --path include/greeting/api.hpp --path src/greeting.cpp \
        --path src/greeting_cli.cpp --path tests/greeting_test.cpp \
        --path tests/expected_output.sh -- \
        bash -c 'rm -rf build/generator-regression && cmake -S . -B build/generator-regression >/dev/null && cmake --build build/generator-regression --parallel 2 >/dev/null'
    scripts/task_verify.sh 1 --phase regression --cycle public-contract --kind test \
        --surface surface-greeting-cli \
        --path include/greeting/api.hpp --path src/greeting.cpp \
        --path src/greeting_cli.cpp --path tests/greeting_test.cpp \
        --path tests/expected_output.sh -- \
        bash -c "rm -rf build/surface-cli && cmake -S . -B build/surface-cli >/dev/null && cmake --build build/surface-cli --parallel 2 >/dev/null && ctest --test-dir build/surface-cli --output-on-failure && tests/expected_output.sh ./build/surface-cli/greeting_cli 'Hello, Ada!' cli-punctuation-mismatch && echo greeting-cli-probe-ok"

    scripts/task_verify.sh 2 --phase regression --cycle migration-proof --kind static \
        --surface-role surface-installed-render-api=old_consumer \
        --surface-role surface-installed-render-api=replacement_consumer \
        --path consumers/downstream.cpp --path tests/expected_output.sh -- \
        bash -c 'rm -rf build/surface-static build/surface-static-install && cmake -S . -B build/surface-static >/dev/null && cmake --build build/surface-static --parallel 2 >/dev/null && cmake --install build/surface-static --prefix build/surface-static-install >/dev/null && if c++ -std=c++17 consumers/legacy_probe.cpp -Ibuild/surface-static-install/include build/surface-static-install/lib/libgreeting_api.a -o build/surface-static/legacy-probe >/dev/null 2>&1; then exit 1; fi && c++ -std=c++17 consumers/downstream.cpp -Ibuild/surface-static-install/include build/surface-static-install/lib/libgreeting_api.a -o build/surface-static/replacement && echo installed-static-probe-ok'
    scripts/task_verify.sh 2 --phase regression --cycle migration-proof --kind behavior \
        --surface-role surface-installed-render-api=old_consumer \
        --surface-role surface-installed-render-api=replacement_consumer \
        --path consumers/downstream.cpp --path tests/expected_output.sh -- \
        bash -c "rm -rf build/surface-behavior build/surface-behavior-install && cmake -S . -B build/surface-behavior >/dev/null && cmake --build build/surface-behavior --parallel 2 >/dev/null && cmake --install build/surface-behavior --prefix build/surface-behavior-install >/dev/null && if c++ -std=c++17 consumers/legacy_probe.cpp -Ibuild/surface-behavior-install/include build/surface-behavior-install/lib/libgreeting_api.a -o build/surface-behavior/legacy-probe >/dev/null 2>&1; then exit 1; fi && c++ -std=c++17 consumers/downstream.cpp -Ibuild/surface-behavior-install/include build/surface-behavior-install/lib/libgreeting_api.a -o build/surface-behavior/replacement && tests/expected_output.sh ./build/surface-behavior/replacement 'Hello, Grace?' installed-behavior-mismatch && echo installed-behavior-probe-ok"

    scripts/task_verify.sh --complete 1
    scripts/task_verify.sh --complete 2
)

note 'Generator 完成后刷新 reviewed inventory，确认公开 API 与 CLI 均无孤儿候选'
(
    cd "$repo"
    scripts/integration_surface_check.sh "$change" --refresh --json >/dev/null
)

node - "$harness_dir/integration-surface-report.json" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(file, 'utf8'));
if (report.schema_version !== 1 || report.change_name !== change ||
    report.discovery_mode !== 'reviewed_inventory' || report.status !== 'complete' ||
    report.unmatched_candidates.length !== 0 ||
    report.planned_surface_ids.join(',') !== 'surface-greeting-cli,surface-installed-render-api') {
  throw new Error(`BREAKING Integration surface report is not closed: ${JSON.stringify(report)}`);
}
const installed = report.surface_candidate_bindings.find(
  item => item.surface_id === 'surface-installed-render-api');
const cli = report.surface_candidate_bindings.find(item => item.surface_id === 'surface-greeting-cli');
if (!installed || !cli || installed.old_consumer_paths.join(',') !== 'consumers/legacy_probe.cpp' ||
    installed.replacement_consumer_paths.join(',') !== 'consumers/downstream.cpp' ||
    installed.consumer_paths.join(',') !== 'consumers/downstream.cpp' ||
    !installed.candidate_bindings.some(item => item.role === 'producer') ||
    !cli.candidate_bindings.some(item => item.role === 'producer') ||
    !cli.candidate_bindings.some(item => item.role === 'consumer')) {
  throw new Error('BREAKING external API / CLI candidate bindings are incomplete');
}
NODE

node - "$harness_dir/change-footprint.json" "$harness_dir/verification.json" <<'NODE'
const fs = require('fs');
const [footprintFile, verificationFile] = process.argv.slice(2);
const footprint = JSON.parse(fs.readFileSync(footprintFile, 'utf8'));
const verification = JSON.parse(fs.readFileSync(verificationFile, 'utf8'));
if (footprint.status !== 'within_expected' || footprint.production.touched_files !== 3 ||
    footprint.tests.touched_files !== 2 || footprint.project_support.touched_files !== 1 ||
    footprint.production.new_files !== 0 || footprint.tests.new_files !== 1 ||
    footprint.structural_candidates.length !== 1 ||
    footprint.structural_candidates[0].allowance_kind !== 'public_contracts') {
  throw new Error(`unexpected medium BREAKING footprint: ${JSON.stringify(footprint)}`);
}
if (verification.tasks.length !== 2) throw new Error('expected two Generator task records');
if (verification.schema_version !== 3 || verification.migration !== null) {
  throw new Error('Generator did not preserve the fresh verification v3 family');
}
const kinds = new Set(verification.tasks.flatMap(task =>
  task.commands.filter(command => command.result === 'Pass').map(command => command.kind)));
for (const kind of ['build', 'test', 'static', 'behavior']) {
  if (!kinds.has(kind)) throw new Error(`missing Generator ${kind} evidence`);
}
const task1 = verification.tasks.find(task => task.task_id === '1');
const task2 = verification.tasks.find(task => task.task_id === '2');
if (!task1 || !task2 || task1.surface_ids.join(',') !== 'surface-greeting-cli' ||
    task2.surface_ids.join(',') !== 'surface-installed-render-api') {
  throw new Error('Generator task-to-surface mapping drifted');
}
const cliRegression = task1.commands.find(command =>
  command.phase === 'REGRESSION' && command.kind === 'test');
if (!cliRegression || cliRegression.surface_ids.join(',') !== 'surface-greeting-cli' ||
    JSON.stringify(cliRegression.surface_evidence_roles) !==
      JSON.stringify([{surface_id: 'surface-greeting-cli', role: 'current'}]) ||
    JSON.stringify(cliRegression.surface_probe_bindings) !== JSON.stringify([{
      surface_id: 'surface-greeting-cli', role: 'current',
      probe_id: 'probe-greeting-cli-test-current'
    }])) {
  throw new Error('CLI current-role evidence is missing');
}
for (const kind of ['behavior', 'static']) {
  const command = task2.commands.find(item => item.phase === 'REGRESSION' && item.kind === kind);
  if (!command || command.surface_ids.join(',') !== 'surface-installed-render-api' ||
      command.surface_evidence_roles.map(item => item.role).join(',') !==
        'old_consumer,replacement_consumer' ||
      command.surface_probe_bindings.map(item => item.probe_id).join(',') !==
        `probe-installed-render-${kind}-old,probe-installed-render-${kind}-replacement`) {
    throw new Error(`external API ${kind} evidence does not close both breaking roles`);
  }
}
NODE

note '独立 Evaluator 冻结输入，并真实重跑 clean build/CTest、旧调用拒绝与安装后迁移'
(
    cd "$repo"
    scripts/evaluator_check.sh --begin "$change" >/dev/null
    scripts/evaluator_check.sh --run --kind build \
        --expected 'A clean CMake configure and build succeeds for every in-tree product target.' \
        --observed 'The independent clean configure and full build completed successfully.' -- \
        bash -c 'rm -rf build/evaluator build/evaluator-install && cmake -S . -B build/evaluator >/dev/null && cmake --build build/evaluator --parallel 2 >/dev/null'
    scripts/evaluator_check.sh --run --kind test \
        --surface surface-greeting-cli \
        --expected 'CTest and both migrated product executables expose the typed punctuation behavior.' \
        --observed 'CTest passed and the CLI plus in-tree downstream executable produced explicit punctuation.' -- \
        bash -c "rm -rf build/surface-cli && cmake -S . -B build/surface-cli >/dev/null && cmake --build build/surface-cli --parallel 2 >/dev/null && ctest --test-dir build/surface-cli --output-on-failure && tests/expected_output.sh ./build/surface-cli/greeting_cli 'Hello, Ada!' cli-punctuation-mismatch && echo greeting-cli-probe-ok"
    scripts/evaluator_check.sh --run --kind static \
        --surface-role surface-installed-render-api=old_consumer \
        --surface-role surface-installed-render-api=replacement_consumer \
        --expected 'The real compiler rejects the legacy caller and compiles/links the replacement against installed artifacts.' \
        --observed 'The independent compiler rejected the old signature and accepted the installed-artifact replacement source.' -- \
        bash -c 'rm -rf build/surface-static build/surface-static-install && cmake -S . -B build/surface-static >/dev/null && cmake --build build/surface-static --parallel 2 >/dev/null && cmake --install build/surface-static --prefix build/surface-static-install >/dev/null && if c++ -std=c++17 consumers/legacy_probe.cpp -Ibuild/surface-static-install/include build/surface-static-install/lib/libgreeting_api.a -o build/surface-static/legacy-probe >/dev/null 2>&1; then exit 1; fi && c++ -std=c++17 consumers/downstream.cpp -Ibuild/surface-static-install/include build/surface-static-install/lib/libgreeting_api.a -o build/surface-static/replacement && echo installed-static-probe-ok'
    scripts/evaluator_check.sh --run --kind behavior \
        --surface-role surface-installed-render-api=old_consumer \
        --surface-role surface-installed-render-api=replacement_consumer \
        --expected 'The old installed consumer remains rejected while the migrated consumer runs and prints Hello, Grace?.' \
        --observed 'The independent installed-artifact probe rejected the old source, then compiled, linked, ran, and observed the replacement.' -- \
        bash -c "rm -rf build/surface-behavior build/surface-behavior-install && cmake -S . -B build/surface-behavior >/dev/null && cmake --build build/surface-behavior --parallel 2 >/dev/null && cmake --install build/surface-behavior --prefix build/surface-behavior-install >/dev/null && if c++ -std=c++17 consumers/legacy_probe.cpp -Ibuild/surface-behavior-install/include build/surface-behavior-install/lib/libgreeting_api.a -o build/surface-behavior/legacy-probe >/dev/null 2>&1; then exit 1; fi && c++ -std=c++17 consumers/downstream.cpp -Ibuild/surface-behavior-install/include build/surface-behavior-install/lib/libgreeting_api.a -o build/surface-behavior/replacement && tests/expected_output.sh ./build/surface-behavior/replacement 'Hello, Grace?' installed-behavior-mismatch && echo installed-behavior-probe-ok"
)

node - "$harness_dir/evaluation-baseline.json" "$harness_dir/change-footprint.json" \
    "$harness_dir/evaluation-command-ledger.json" \
    "$harness_dir/integration-surface-report.json" "$harness_dir/evaluation.json" \
    "$change" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, reportFile, outputFile, change] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const footprint = JSON.parse(fs.readFileSync(footprintFile, 'utf8'));
const ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
if (baseline.schema_version !== 3 || ledger.schema_version !== 2 ||
    ledger.evaluation_id !== baseline.evaluation_id || ledger.change_name !== change ||
    !Array.isArray(ledger.commands) || ledger.commands.length !== 4 ||
    ledger.commands.some(command => command.result !== 'Pass') || report.status !== 'complete') {
  throw new Error('managed integrated Evaluation inputs are incomplete');
}
const commands = [...ledger.commands];
const evidenceFinished = Math.max(
  Date.parse(baseline.started_at), ...commands.map(command => Date.parse(command.finished_at)));
const observedAt = Date.now();
if (!Number.isFinite(evidenceFinished) || evidenceFinished > observedAt + 300000) {
  throw new Error('managed Evaluation timestamps exceed the accepted clock tolerance');
}
const reviewBoundary = new Date(evidenceFinished).toISOString();
const evaluated = new Date(Math.max(observedAt, evidenceFinished)).toISOString();
const paths = [
  'consumers/downstream.cpp', 'include/greeting/api.hpp',
  'src/greeting.cpp', 'src/greeting_cli.cpp',
  'tests/expected_output.sh', 'tests/greeting_test.cpp'
];
const commandIds = commands.map(command => command.id);
const commandIdsFor = (...kinds) => commands
  .filter(command => kinds.includes(command.kind)).map(command => command.id);
const commandIdsForSurface = surfaceId => commands
  .filter(command => command.surface_ids.includes(surfaceId)).map(command => command.id);
const requirementRef = {
  spec_path: 'specs/greeting-api/spec.md', operation: 'MODIFIED',
  requirement: 'Render a named greeting', scenarios: ['Render a named greeting']
};
const reviewStage = (name, startedAt, completedAt, dimensions) => ({
  name, started_at: startedAt, completed_at: completedAt, status: 'Pass',
  requirement_refs: [requirementRef], task_ids: ['1', '2'],
  reviewed_paths: baseline.review_input.review_paths, dimensions,
  evidence_command_ids: commandIds, finding_ids: [], blocking_untested_ids: [],
  not_run_reason: null
});
const structuralCandidates = footprint.structural_candidates.map(item => item.candidate_id);
if (structuralCandidates.length !== 1) throw new Error('expected one public-contract candidate');

const reportBindings = new Map(report.surface_candidate_bindings.map(binding => [binding.surface_id, binding]));
const typedByCandidate = new Map;
for (const binding of report.surface_candidate_bindings) {
  for (const candidateBinding of binding.candidate_bindings) {
    const rows = typedByCandidate.get(candidateBinding.candidate_id) || [];
    rows.push({surface_id: binding.surface_id, role: candidateBinding.role});
    typedByCandidate.set(candidateBinding.candidate_id, rows);
  }
}
const allCandidates = [...report.path_candidates, ...report.structural_candidates, ...report.ast_candidates];
const candidateAssessments = allCandidates.map(candidate => {
  const typed = typedByCandidate.get(candidate.candidate_id) || [];
  if (!typed.length) throw new Error(`complete report left ${candidate.candidate_id} unbound`);
  const surfaceIds = [...new Set(typed.map(item => item.surface_id))].sort();
  const logicalPaths = [...new Set([candidate.old_path, candidate.path]
    .filter(Boolean))].sort();
  const bindings = surfaceIds.map(surfaceId => {
    const reportBinding = reportBindings.get(surfaceId);
    const roles = [...new Set(typed.filter(item => item.surface_id === surfaceId)
      .map(item => item.role))]
      .sort((a, b) => ['producer', 'consumer'].indexOf(a) - ['producer', 'consumer'].indexOf(b));
    return {
      surface_id: surfaceId,
      candidate_roles: roles,
      consumer_kind: surfaceId === 'surface-installed-render-api'
        ? 'representative_external' : 'real_entrypoint',
      consumer_paths: reportBinding.consumer_paths
    };
  });
  const producerPaths = logicalPaths.filter(candidatePath => bindings.some(binding =>
    binding.candidate_roles.includes('producer') &&
    reportBindings.get(binding.surface_id).producer_paths.includes(candidatePath)));
  const evidenceIds = [...new Set(surfaceIds.flatMap(commandIdsForSurface))];
  if (!evidenceIds.length) throw new Error(`candidate ${candidate.candidate_id} has no independent surface command`);
  return {
    candidate_id: candidate.candidate_id,
    source: candidate.source,
    disposition: 'mapped',
    surface_ids: surfaceIds,
    surface_bindings: bindings,
    reason: 'The complete diff candidate is mapped to an approved public API or CLI surface and independently exercised.',
    producer_paths: producerPaths,
    implementation_consumer: null,
    evidence_paths: logicalPaths,
    evidence_command_ids: evidenceIds,
    orphan_ids: []
  };
}).sort((a, b) => a.candidate_id.localeCompare(b.candidate_id));

const externalCommands = commandIdsForSurface('surface-installed-render-api');
const cliCommands = commandIdsForSurface('surface-greeting-cli');
const externalBinding = reportBindings.get('surface-installed-render-api');
const cliBinding = reportBindings.get('surface-greeting-cli');
if (externalCommands.length !== 2 || cliCommands.length !== 1 || !externalBinding || !cliBinding) {
  throw new Error('independent command-to-surface coverage is not exact');
}
const cliProbeCommand = commands.find(command => command.id === cliCommands[0]);
if (JSON.stringify(cliProbeCommand?.surface_probe_bindings) !== JSON.stringify([{
  surface_id: 'surface-greeting-cli', role: 'current',
  probe_id: 'probe-greeting-cli-test-current'
}])) {
  throw new Error('independent CLI command is not bound to the approved probe');
}
for (const command of commands.filter(item =>
  item.surface_ids.includes('surface-installed-render-api'))) {
  const expectedProbeIds = [
    `probe-installed-render-${command.kind}-old`,
    `probe-installed-render-${command.kind}-replacement`
  ];
  if (command.surface_probe_bindings.map(item => item.probe_id).join(',') !==
      expectedProbeIds.join(',')) {
    throw new Error(`independent ${command.kind} command probe binding drifted`);
  }
}
const evaluation = {
  schema_version: 3,
  evaluation_id: baseline.evaluation_id,
  change_name: change,
  verdict: 'Pass',
  evaluation_started_at: baseline.started_at,
  evaluated_at: evaluated,
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
      reviewStage('specification_compliance', baseline.started_at, reviewBoundary,
        ['requirements', 'scenarios', 'scope', 'contracts', 'traceability']),
      reviewStage('code_quality', reviewBoundary, evaluated,
        ['correctness', 'safety', 'regression_risk', 'reuse', 'complexity', 'test_quality', 'repository_impact'])
    ],
    findings: []
  },
  implementation_economy: {
    footprint_status: footprint.status,
    drift_explanation: null,
    classification_assessment: {
      result: 'Pass',
      reason: 'Every implementation path is classified by the approved medium profile and is covered by independent build, runtime, or downstream evidence.',
      evidence_paths: paths,
      evidence_command_ids: commandIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets', applicability: 'applicable', result: 'Pass',
          reason: 'The existing library, CLI, CTest, and downstream targets configure, build, and run.',
          evidence_paths: paths, evidence_command_ids: commandIdsFor('build', 'test'),
          not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'applicable', result: 'Pass',
          reason: 'Installed headers and archive reject the old source and compile, link, and run the migrated representative consumer.',
          evidence_paths: ['consumers/downstream.cpp', 'include/greeting/api.hpp',
            'src/greeting.cpp'],
          evidence_command_ids: externalCommands, not_applicable_reason: null
        },
        {
          surface: 'package', applicability: 'not_applicable', result: null,
          reason: 'This fixture intentionally defines no package-generation surface.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CPack or other package configuration exists in the approved baseline.'
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'This disposable fixture has no repository CI configuration.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI surface exists in the approved baseline.'
        }
      ]
    },
    reuse_assessments: [],
    structural_assessments: [{
      allowance_id: 'contract-render-request',
      candidate_ids: structuralCandidates,
      result: 'Pass',
      reason: 'The only structural candidate is the approved replacement public header contract.',
      evidence_paths: ['include/greeting/api.hpp', 'consumers/downstream.cpp'],
      evidence_command_ids: externalCommands
    }],
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: 'criterion-breaking-render-migration',
    description: 'The typed contract and CLI run, the old signature is rejected, and the installed downstream replacement succeeds.',
    requirement_refs: [requirementRef],
    task_ids: ['1', '2'],
    status: 'Pass',
    evidence_command_ids: commandIds,
    blocking_untested_ids: []
  }],
  commands,
  blocking_untested: [],
  residual_risks: [{
    id: 'risk-external-consumer-migration',
    impact: 'External callers not represented in this disposable repository must update source before adopting the archive.',
    rationale: 'The contract is intentionally BREAKING; compile rejection and one installed representative consumer prove the migration shape but cannot enumerate external repositories.'
  }],
  integration_completeness: {
    planning_block_sha256: baseline.integration_planning_block_sha256,
    report_sha256: baseline.integration_surface_report_sha256,
    discovery_identity_sha256: baseline.integration_discovery_identity_sha256,
    inventory_assessment: {
      result: 'Pass',
      reason: 'Every changed production candidate is mapped and all public consumers were independently reviewed.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: [...new Set([...cliCommands, ...externalCommands])]
    },
    candidate_assessments: candidateAssessments,
    surface_assessments: [
      {
        surface_id: 'surface-greeting-cli',
        result: 'Pass',
        reason: 'The independent CTest/CLI command executes the migrated real entrypoint.',
        consumer_paths: cliBinding.consumer_paths,
        old_consumer_paths: cliBinding.old_consumer_paths,
        replacement_consumer_paths: cliBinding.replacement_consumer_paths,
        kind_evidence: [{kind: 'test', evidence_command_ids: cliCommands}],
        role_evidence: [{role: 'current', evidence_command_ids: cliCommands}],
        evidence_command_ids: cliCommands,
        blocking_untested_ids: [],
        orphan_ids: []
      },
      {
        surface_id: 'surface-installed-render-api',
        result: 'Pass',
        reason: 'Independent installed-artifact probes reject the legacy caller and accept the representative replacement.',
        consumer_paths: externalBinding.consumer_paths,
        old_consumer_paths: externalBinding.old_consumer_paths,
        replacement_consumer_paths: externalBinding.replacement_consumer_paths,
        kind_evidence: [
          {kind: 'behavior', evidence_command_ids: commandIdsFor('behavior')},
          {kind: 'static', evidence_command_ids: commandIdsFor('static')}
        ],
        role_evidence: [
          {role: 'old_consumer', evidence_command_ids: externalCommands},
          {role: 'replacement_consumer', evidence_command_ids: externalCommands}
        ],
        evidence_command_ids: externalCommands,
        blocking_untested_ids: [],
        orphan_ids: []
      }
    ],
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

node - "$harness_dir/evaluation-baseline.json" "$harness_dir/evaluation.json" \
    "$harness_dir/evaluation-command-ledger.json" \
    "$harness_dir/integration-surface-report.json" "$harness_dir/evaluations" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const [baselineFile, evaluationFile, ledgerFile, reportFile, evaluationsDir] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile, 'utf8'));
const ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const envelope = JSON.parse(fs.readFileSync(path.join(evaluationsDir, `${evaluation.evaluation_id}.json`), 'utf8'));
const digest = 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(evaluationFile)).digest('hex');
if (baseline.schema_version !== 3 || baseline.status !== 'complete' ||
    baseline.evaluation_json_sha256 !== digest || evaluation.schema_version !== 3 ||
    evaluation.verdict !== 'Pass' || evaluation.implementation_economy.result !== 'Pass' ||
    evaluation.integration_completeness?.result !== 'Pass' ||
    evaluation.integration_completeness?.orphan_surfaces?.length !== 0 ||
    evaluation.change_review?.stages?.map(stage => stage.name).join(',') !==
      'specification_compliance,code_quality' ||
    evaluation.change_review.stages.some(stage => stage.status !== 'Pass') ||
    evaluation.residual_risks.length !== 1 || ledger.schema_version !== 2 ||
    ledger.commands.length !== 4 || report.status !== 'complete' ||
    JSON.stringify(ledger.commands) !== JSON.stringify(evaluation.commands) ||
    envelope.terminal_status !== 'complete' || envelope.source_schema_version !== 3 ||
    envelope.evaluation_id !== evaluation.evaluation_id || envelope.evaluation?.verdict !== 'Pass') {
  throw new Error('independent BREAKING Pass Evaluation was not completed and digest-bound');
}
NODE

note '受管 archive wrapper 在 sibling change 存在时通过硬门禁并调用真实 OpenSpec archive'
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
assert_path_exists "$repo/openspec/changes/$sibling"
assert_file_contains "$repo/openspec/changes/$sibling/harness/multichange-sentinel.txt" \
    'sibling-evidence-remains-isolated'
assert_path_absent "$repo/openspec/changes/$sibling/harness/evaluation.json"
assert_file_contains "$repo/openspec/specs/greeting-api/spec.md" \
    'Requirement: Render a named greeting'
assert_file_contains "$repo/openspec/specs/greeting-api/spec.md" 'Scenario: Render a named greeting'
assert_file_contains "$repo/openspec/specs/greeting-api/spec.md" '`RenderRequest`'
assert_file_not_contains "$repo/openspec/specs/greeting-api/spec.md" \
    'name string supplied directly by the caller'

node - "$repo/ai_snapshot.json" "$change" "$archived_as" <<'NODE'
const fs = require('fs');
const [file, change, archivedAs] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
if (snapshot.active_change !== null || snapshot.phase !== 'idle' ||
    snapshot.last_archived_change?.change_name !== change ||
    snapshot.last_archived_change?.archived_as !== archivedAs ||
    Object.hasOwn(snapshot, 'archive_failure')) {
  throw new Error('BREAKING multi-change archive did not clear active state and record identity');
}
NODE

post_validation="$tmp/post-breaking-archive-validation.json"
(
    cd "$repo"
    scripts/openspec_cli.sh validate --specs --strict --json --no-interactive > "$post_validation"
)
node - "$post_validation" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (data.summary?.totals?.failed !== 0 || data.items.length < 1 ||
    data.items.some(item => item.valid !== true)) {
  throw new Error('post-BREAKING-archive main specs did not pass real strict validation');
}
NODE

note '真实 OpenSpec 1.6.0 + medium C++/CMake multi-change BREAKING 受管闭环通过'
