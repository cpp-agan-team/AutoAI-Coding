#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT
repo="$tmp/managed surface kind matrix"
change=close-real-surface-kinds
change_dir="$repo/openspec/changes/$change"
harness_dir="$change_dir/harness"

for command_name in cmake ctest c++ git node npm npx; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "真实 surface kind 矩阵缺少依赖：$command_name"
done

init_git_repo "$repo"
mkdir -p "$repo/include/surface" "$repo/src" "$repo/cmake" \
    "$repo/tests/downstream"

cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_surface_kind_matrix LANGUAGES CXX)

add_library(surface_core STATIC
  src/core.cpp
  src/plugin.cpp
  src/config.cpp
  src/protocol.cpp)
target_compile_features(surface_core PUBLIC cxx_std_17)
target_include_directories(surface_core
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

add_executable(surface_app src/app.cpp)
target_link_libraries(surface_app PRIVATE surface_core)
EOF

cat > "$repo/include/surface/runtime.hpp" <<'EOF'
#pragma once

#include <functional>
#include <string>

namespace surface {

using Callback = std::function<std::string()>;

std::string library_marker();
void register_callback(Callback callback);
std::string dispatch_callback();
std::string read_mode(const std::string& path);
void write_message(const std::string& path, const std::string& value);
std::string read_message(const std::string& path);

}
EOF

cat > "$repo/src/core.cpp" <<'EOF'
#include "surface/runtime.hpp"

namespace surface {

std::string library_marker() {
    return "installed-surface-ok";
}

}
EOF

cat > "$repo/src/plugin.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <utility>

namespace surface {
namespace {
Callback registered_callback;
}

void register_callback(Callback callback) {
    registered_callback = std::move(callback);
}

std::string dispatch_callback() {
    return "registered-only";
}

}
EOF

cat > "$repo/src/config.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <fstream>

namespace surface {

std::string read_mode(const std::string& path) {
    std::ifstream input(path);
    std::string line;
    std::getline(input, line);
    return line.rfind("mode=", 0) == 0 ? "parsed:" + line.substr(5) : "parsed:default";
}

}
EOF

cat > "$repo/src/protocol.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <fstream>

namespace surface {

void write_message(const std::string& path, const std::string& value) {
    std::ofstream(path) << value << '\n';
}

std::string read_message(const std::string&) {
    return "write-only";
}

}
EOF

cat > "$repo/src/app.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <iostream>
#include <string>

int main(int argc, char** argv) {
    if (argc >= 2 && std::string(argv[1]) == "--callback") {
        surface::register_callback([] { return std::string("dispatched"); });
        std::cout << "callback:registered\n";
        return 0;
    }
    if (argc >= 3 && std::string(argv[1]) == "--config") {
        (void)surface::read_mode(argv[2]);
        std::cout << "mode:default\n";
        return 0;
    }
    if (argc >= 3 && std::string(argv[1]) == "--roundtrip") {
        surface::write_message(argv[2], "roundtrip");
        std::cout << "protocol:write-only\n";
        return 0;
    }
    std::cerr << "unknown-entrypoint\n";
    return 2;
}
EOF

cat > "$repo/cmake/SurfaceConfig.cmake" <<'EOF'
include("${CMAKE_CURRENT_LIST_DIR}/SurfaceTargets.cmake")
EOF

cat > "$repo/tests/integration_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
app=${1:?surface app required}
mode=${2:?probe mode required}
case "$mode" in
    callback)
        output=$($app --callback)
        if [[ "$output" != callback:dispatched ]]; then
            echo callback-not-dispatched
            exit 1
        fi
        ;;
    configuration)
        config_file=${app}.configuration
        printf 'mode=fast\n' > "$config_file"
        output=$($app --config "$config_file")
        if [[ "$output" != mode:fast ]]; then
            echo configuration-not-consumed
            exit 1
        fi
        ;;
    protocol)
        state_file=${app}.protocol
        output=$($app --roundtrip "$state_file")
        if [[ "$output" != protocol:roundtrip ]]; then
            echo protocol-not-consumed
            exit 1
        fi
        ;;
    cli)
        set +e
        output=$($app --summary 2>/dev/null)
        status=$?
        set -e
        if [[ "$status" -ne 0 || "$output" != summary:ok ]]; then
            echo cli-entrypoint-not-wired
            exit 1
        fi
        ;;
    *)
        echo unknown-probe >&2
        exit 2
        ;;
esac
echo "surface-${mode}-ok"
EOF
chmod 755 "$repo/tests/integration_probe.sh"

cat > "$repo/tests/downstream/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_surface_downstream LANGUAGES CXX)

find_package(Surface CONFIG REQUIRED)
add_executable(surface_downstream main.cpp)
target_link_libraries(surface_downstream PRIVATE Surface::surface_core)
EOF

cat > "$repo/tests/downstream/main.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <iostream>

int main() {
    std::cout << surface::library_marker() << '\n';
    return 0;
}
EOF

cat > "$repo/tests/downstream_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
main_build=${1:?main build required}
install_prefix=${2:?install prefix required}
downstream_build=${3:?downstream build required}
main_build=$(realpath -m -- "$main_build")
install_prefix=$(realpath -m -- "$install_prefix")
downstream_build=$(realpath -m -- "$downstream_build")

rm -rf -- "$install_prefix" "$downstream_build"
cmake --build "$main_build" --parallel 2 >/dev/null
cmake --install "$main_build" --prefix "$install_prefix" >/dev/null
if ! cmake -S tests/downstream -B "$downstream_build" \
    -DCMAKE_PREFIX_PATH="$install_prefix" >/dev/null 2>&1; then
    echo downstream-package-missing
    exit 1
fi
cmake --build "$downstream_build" --parallel 2 >/dev/null
output=$("$downstream_build/surface_downstream")
if [[ "$output" != installed-surface-ok ]]; then
    echo downstream-runtime-mismatch
    exit 1
fi
echo downstream-install-ok
EOF
chmod 755 "$repo/tests/downstream_probe.sh"

note '用真实 npm/npx 生成 fresh v4/v3 Harness，并创建唯一 active change'
run_setup "$repo"
assert_status 0
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)

mkdir -p "$change_dir/specs/surface-completeness"
cat > "$change_dir/proposal.md" <<'EOF'
## Why

The fixture needs executable proof that every non-callable product surface is connected to its real consumer.

## What Changes

- Dispatch a registered callback through the production executable.
- Apply a parsed configuration value to observable process output.
- Consume the value written by the production protocol producer.
- Wire a real CLI option and export an installable CMake package.
- External contract impact: **compatible**.

## Capabilities

### New Capabilities

- `surface-completeness`: Closes callback, configuration, protocol, CLI, and install consumers.

### Modified Capabilities

- None.

## Impact

The existing library, executable, and target are reused; no dependency or new production target is introduced.
EOF

cat > "$change_dir/specs/surface-completeness/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Dispatch registered callback
The application SHALL dispatch the callback registered on its production path.

#### Scenario: Observe callback dispatch
- **WHEN** the callback entrypoint runs
- **THEN** it prints `callback:dispatched`

### Requirement: Apply runtime configuration
The application SHALL read the selected configuration and apply it to process behavior.

#### Scenario: Observe configured mode
- **WHEN** a configuration file selects `fast` mode
- **THEN** the process prints `mode:fast`

### Requirement: Consume protocol roundtrip
The application SHALL consume the message emitted by its production protocol writer.

#### Scenario: Observe producer consumer roundtrip
- **WHEN** the roundtrip entrypoint writes and reads a message
- **THEN** the process prints `protocol:roundtrip`

### Requirement: Expose summary CLI
The application SHALL expose the approved summary option through its real executable entrypoint.

#### Scenario: Observe summary output
- **WHEN** the executable receives `--summary`
- **THEN** it prints `summary:ok` and exits successfully

### Requirement: Export downstream CMake package
The project SHALL install an exported target that a representative downstream project can configure, build, link, and run.

#### Scenario: Consume installed target
- **WHEN** a downstream CMake project uses the install prefix
- **THEN** its executable links and prints `installed-surface-ok`
EOF

cat > "$change_dir/tasks.md" <<'EOF'
## 1. Real consumer closure

- [ ] 1 Connect callback registration to production dispatch
  - Covers: `specs/surface-completeness/spec.md` | `ADDED` | `Dispatch registered callback` | `Observe callback dispatch`
  - Verify: `behavior`
- [ ] 2 Apply parsed configuration through the real process entrypoint
  - Covers: `specs/surface-completeness/spec.md` | `ADDED` | `Apply runtime configuration` | `Observe configured mode`
  - Verify: `behavior`
- [ ] 3 Complete the protocol producer and consumer roundtrip
  - Covers: `specs/surface-completeness/spec.md` | `ADDED` | `Consume protocol roundtrip` | `Observe producer consumer roundtrip`
  - Verify: `behavior`
- [ ] 4 Wire the real summary CLI entrypoint
  - Covers: `specs/surface-completeness/spec.md` | `ADDED` | `Expose summary CLI` | `Observe summary output`
  - Verify: `behavior`
- [ ] 5 Export and exercise the installed CMake target downstream
  - Covers: `specs/surface-completeness/spec.md` | `ADDED` | `Export downstream CMake package` | `Consume installed target`
  - Verify: `build`, `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
## Context

The baseline deliberately stops at registration, parsing, serialization, and an in-tree build. The approved change must close each path through a real consumer.

## Goals / Non-Goals

**Goals:** Reuse the existing target and executable, then prove each surface with a focused runtime or downstream command.

**Non-Goals:** Add a dependency, production target, public type, or second workflow.

## Decisions

Keep reviewed inventory portable. Each surface has one task and one `current` evidence role. Runnable install output carries both build and behavior evidence; the other surfaces keep one focused behavior command.

## Risks / Trade-offs

The fixture intentionally uses one small executable for four runtime entrypoints so the matrix remains fast while preserving distinct consumer evidence.

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
  "rationale": "Five surface closures reuse one library, one executable, one existing target, and baseline consumer probes.",
  "classification": {
    "production": ["src/**", "include/**", "CMakeLists.txt", "cmake/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md"],
    "project_tooling": ["tooling/**"],
    "examples": ["examples/**"],
    "generated": [],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 32, "review_at": 60, "hard_limit": 100},
      "touched_files": {"expected": 5, "review_at": 6, "hard_limit": 8},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 4, "hard_limit": 8},
      "touched_files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 4, "hard_limit": 8},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "bytes": {"expected": 0, "review_at": 1024, "hard_limit": 4096}
    }
  },
  "structural_allowances": {
    "public_contracts": [],
    "cmake_targets": [{
      "id": "cmake-surface-install-export",
      "name": "installed Surface::surface_core export",
      "reason": "The approved build/install surface must export the existing target without adding a production target."
    }],
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
      "consumer_kind": "downstream_build",
      "consumer_paths": ["tests/downstream/CMakeLists.txt", "tests/downstream/main.cpp", "tests/downstream_probe.sh"],
      "contract_impact": "compatible",
      "entrypoint": "installed SurfaceConfig package consumed by a downstream CMake executable",
      "evidence_contracts": [
        {
          "argv": ["tests/downstream_probe.sh", "build/generator", "build/generator-install", "build/generator-downstream"],
          "expected_exit_codes": [0],
          "kind": "build",
          "output_contains": "downstream-install-ok",
          "probe_id": "probe-build-install-build",
          "role": "current"
        },
        {
          "argv": ["tests/downstream_probe.sh", "build/generator", "build/generator-install", "build/generator-downstream"],
          "expected_exit_codes": [0],
          "kind": "behavior",
          "output_contains": "downstream-install-ok",
          "probe_id": "probe-build-install-behavior",
          "role": "current"
        }
      ],
      "expected_observation": "A downstream configure, build, link, and run prints installed-surface-ok.",
      "id": "surface-build-install",
      "kind": "build_or_install",
      "name": "installed CMake target",
      "producer_paths": ["CMakeLists.txt"],
      "requirement_refs": [{
        "operation": "ADDED",
        "requirement": "Export downstream CMake package",
        "scenarios": ["Consume installed target"],
        "spec_path": "specs/surface-completeness/spec.md"
      }],
      "runnable_artifact": true,
      "symbol_identities": null,
      "task_ids": ["5"],
      "task_obligations": [{"evidence_roles": ["current"], "task_id": "5", "verify_kinds": ["build", "behavior"]}],
      "verify_kinds": ["build", "behavior"]
    },
    {
      "change_kind": "modified",
      "compatibility": null,
      "consumer_kind": "registration_dispatch",
      "consumer_paths": ["src/app.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "surface_app --callback registration and dispatch path",
      "evidence_contracts": [{
        "argv": ["bash", "-c", "cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app callback"],
        "expected_exit_codes": [0],
        "kind": "behavior",
        "output_contains": "surface-callback-ok",
        "probe_id": "probe-callback-behavior",
        "role": "current"
      }],
      "expected_observation": "The registered callback is actually dispatched and prints callback:dispatched.",
      "id": "surface-callback-dispatch",
      "kind": "callback_or_plugin",
      "name": "callback registration and dispatch",
      "producer_paths": ["src/plugin.cpp"],
      "requirement_refs": [{
        "operation": "ADDED",
        "requirement": "Dispatch registered callback",
        "scenarios": ["Observe callback dispatch"],
        "spec_path": "specs/surface-completeness/spec.md"
      }],
      "symbol_identities": null,
      "task_ids": ["1"],
      "task_obligations": [{"evidence_roles": ["current"], "task_id": "1", "verify_kinds": ["behavior"]}],
      "verify_kinds": ["behavior"]
    },
    {
      "change_kind": "modified",
      "compatibility": null,
      "consumer_kind": "real_entrypoint",
      "consumer_paths": ["tests/integration_probe.sh"],
      "contract_impact": "compatible",
      "entrypoint": "surface_app --summary",
      "evidence_contracts": [{
        "argv": ["bash", "-c", "cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app cli"],
        "expected_exit_codes": [0],
        "kind": "behavior",
        "output_contains": "surface-cli-ok",
        "probe_id": "probe-cli-behavior",
        "role": "current"
      }],
      "expected_observation": "The real executable prints summary:ok and exits successfully.",
      "id": "surface-cli-entrypoint",
      "kind": "cli",
      "name": "summary command-line entrypoint",
      "producer_paths": ["src/app.cpp"],
      "requirement_refs": [{
        "operation": "ADDED",
        "requirement": "Expose summary CLI",
        "scenarios": ["Observe summary output"],
        "spec_path": "specs/surface-completeness/spec.md"
      }],
      "symbol_identities": null,
      "task_ids": ["4"],
      "task_obligations": [{"evidence_roles": ["current"], "task_id": "4", "verify_kinds": ["behavior"]}],
      "verify_kinds": ["behavior"]
    },
    {
      "change_kind": "modified",
      "compatibility": null,
      "consumer_kind": "real_entrypoint",
      "consumer_paths": ["src/app.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "surface_app --config <file>",
      "evidence_contracts": [{
        "argv": ["bash", "-c", "cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app configuration"],
        "expected_exit_codes": [0],
        "kind": "behavior",
        "output_contains": "surface-configuration-ok",
        "probe_id": "probe-configuration-behavior",
        "role": "current"
      }],
      "expected_observation": "The real process applies mode=fast and prints mode:fast.",
      "id": "surface-configuration-runtime",
      "kind": "configuration",
      "name": "runtime mode configuration",
      "producer_paths": ["src/config.cpp"],
      "requirement_refs": [{
        "operation": "ADDED",
        "requirement": "Apply runtime configuration",
        "scenarios": ["Observe configured mode"],
        "spec_path": "specs/surface-completeness/spec.md"
      }],
      "symbol_identities": null,
      "task_ids": ["2"],
      "task_obligations": [{"evidence_roles": ["current"], "task_id": "2", "verify_kinds": ["behavior"]}],
      "verify_kinds": ["behavior"]
    },
    {
      "change_kind": "modified",
      "compatibility": null,
      "consumer_kind": "producer_consumer_pair",
      "consumer_paths": ["src/app.cpp"],
      "contract_impact": "compatible",
      "entrypoint": "surface_app --roundtrip <state-file>",
      "evidence_contracts": [{
        "argv": ["bash", "-c", "cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app protocol"],
        "expected_exit_codes": [0],
        "kind": "behavior",
        "output_contains": "surface-protocol-ok",
        "probe_id": "probe-protocol-behavior",
        "role": "current"
      }],
      "expected_observation": "The production writer and reader roundtrip prints protocol:roundtrip.",
      "id": "surface-protocol-roundtrip",
      "kind": "protocol_or_persistence",
      "name": "message persistence roundtrip",
      "producer_paths": ["src/protocol.cpp"],
      "requirement_refs": [{
        "operation": "ADDED",
        "requirement": "Consume protocol roundtrip",
        "scenarios": ["Observe producer consumer roundtrip"],
        "spec_path": "specs/surface-completeness/spec.md"
      }],
      "symbol_identities": null,
      "task_ids": ["3"],
      "task_obligations": [{"evidence_roles": ["current"], "task_id": "3", "verify_kinds": ["behavior"]}],
      "verify_kinds": ["behavior"]
    }
  ]
}
```
<!-- /autoai:integration-completeness:v1 -->
EOF

note '严格验证规划并提交基线；fresh change 必须保持 snapshot v4 / verification v3'
(
    cd "$repo"
    git config user.name 'AutoAI Real Surface Matrix Test'
    git config user.email 'autoai-real-surface-matrix@example.invalid'
    cp "$change_dir/design.md" "$tmp/valid-surface-kind-design.md"
    node - "$change_dir/design.md" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');
const startMarker = '<!-- autoai:integration-completeness:v1 -->';
const endMarker = '<!-- /autoai:integration-completeness:v1 -->';
const start = text.indexOf(startMarker), end = text.indexOf(endMarker);
if (start < 0 || end < 0 || end <= start) throw new Error('integration block missing');
const segment = text.slice(start + startMarker.length, end);
const match = segment.match(/```json\s*([\s\S]*?)\s*```/);
if (!match) throw new Error('integration JSON fence missing');
const value = JSON.parse(match[1]);
const surface = value.surfaces.find(item => item.id === 'surface-build-install');
if (!surface) throw new Error('build/install surface missing');
surface.verify_kinds = ['build'];
surface.task_obligations[0].verify_kinds = ['build'];
surface.evidence_contracts = surface.evidence_contracts.filter(item => item.kind === 'build');
const replacement = segment.replace(match[0], '```json\n' + JSON.stringify(value, null, 2) + '\n```');
fs.writeFileSync(file, text.slice(0, start + startMarker.length) + replacement + text.slice(end));
NODE
    set +e
    scripts/integration_surface_check.sh "$change" --plan-check --json >"$tmp/build-only-plan.json" 2>"$tmp/build-only-plan.err"
    build_only_status=$?
    set -e
    [[ "$build_only_status" -eq 6 ]] || fail "runnable downstream build-only surface should be rejected, got $build_only_status"
    node - "$tmp/build-only-plan.json" <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (value.status !== 'invalid' || !value.reason) {
  throw new Error('build-only planning rejection did not use the closed invalid diagnostic');
}
NODE
    mv "$tmp/valid-surface-kind-design.md" "$change_dir/design.md"
    scripts/integration_surface_check.sh "$change" --plan-check --json >/dev/null
    scripts/openspec_cli.sh validate "$change" --type change --strict --json > "$tmp/strict-plan.json"
    cmake -S . -B build/generator >/dev/null
    cmake --build build/generator --parallel 2 >/dev/null
    git add -A
    git commit -qm 'approved real surface matrix baseline'
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
  throw new Error('fresh integrated evidence family was not retained');
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

record_red() {
    local task=$1 cycle=$2 kind=$3 test_path=$4 match=$5 reason=$6
    shift 6
    run_managed_at "$repo" scripts/task_verify.sh "$task" \
        --phase red --cycle "$cycle" --kind "$kind" --expect-exit 1 \
        --test-path "$test_path" --failure-class behavior \
        --expected-failure "$reason" --match-output "$match" \
        --observed "$reason" -- "$@"
    assert_status 0
}

note 'RED/负向阶段：注册不 dispatch、解析不应用、只序列化、CLI 未接线、仅主仓 build 都不能闭合'
(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
)
record_red 1 callback-dispatch behavior tests/integration_probe.sh callback-not-dispatched \
    'Registration exists, but the production entrypoint never dispatches the callback.' \
    bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app callback'
record_red 2 configuration-runtime behavior tests/integration_probe.sh configuration-not-consumed \
    'The configuration parser runs, but the real process ignores the parsed value.' \
    bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app configuration'
record_red 3 protocol-roundtrip behavior tests/integration_probe.sh protocol-not-consumed \
    'The production path writes the message, but does not consume it again.' \
    bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app protocol'
record_red 4 cli-entrypoint behavior tests/integration_probe.sh cli-entrypoint-not-wired \
    'The approved option is absent from the real executable entrypoint.' \
    bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app cli'
record_red 5 downstream-install behavior tests/downstream/CMakeLists.txt downstream-package-missing \
    'The main repository builds, but no installed package exists for a downstream configure and link.' \
    tests/downstream_probe.sh build/generator build/generator-install build/generator-downstream

for task in 1 2 3 4 5; do
    run_managed_at "$repo" scripts/task_verify.sh --complete "$task"
    assert_status 6
done
test -x "$repo/build/generator/surface_app" || fail '负向阶段没有证明主仓 build 成功'

note 'Generator 最小实现：只连接已批准的 dispatch、真实配置、协议消费、CLI 和 install/export'
cat > "$repo/src/plugin.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <utility>

namespace surface {
namespace {
Callback registered_callback;
}

void register_callback(Callback callback) {
    registered_callback = std::move(callback);
}

std::string dispatch_callback() {
    return registered_callback ? registered_callback() : "missing-callback";
}

}
EOF

cat > "$repo/src/config.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <fstream>

namespace surface {

std::string read_mode(const std::string& path) {
    std::ifstream input(path);
    std::string line;
    std::getline(input, line);
    return line.rfind("mode=", 0) == 0 ? line.substr(5) : "default";
}

}
EOF

cat > "$repo/src/protocol.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <fstream>

namespace surface {

void write_message(const std::string& path, const std::string& value) {
    std::ofstream(path) << value << '\n';
}

std::string read_message(const std::string& path) {
    std::ifstream input(path);
    std::string value;
    std::getline(input, value);
    return value;
}

}
EOF

cat > "$repo/src/app.cpp" <<'EOF'
#include "surface/runtime.hpp"

#include <iostream>
#include <string>

int main(int argc, char** argv) {
    if (argc >= 2 && std::string(argv[1]) == "--callback") {
        surface::register_callback([] { return std::string("dispatched"); });
        std::cout << "callback:" << surface::dispatch_callback() << '\n';
        return 0;
    }
    if (argc >= 3 && std::string(argv[1]) == "--config") {
        std::cout << "mode:" << surface::read_mode(argv[2]) << '\n';
        return 0;
    }
    if (argc >= 3 && std::string(argv[1]) == "--roundtrip") {
        surface::write_message(argv[2], "roundtrip");
        std::cout << "protocol:" << surface::read_message(argv[2]) << '\n';
        return 0;
    }
    if (argc >= 2 && std::string(argv[1]) == "--summary") {
        std::cout << "summary:ok\n";
        return 0;
    }
    std::cerr << "unknown-entrypoint\n";
    return 2;
}
EOF

cat >> "$repo/CMakeLists.txt" <<'EOF'

install(TARGETS surface_core EXPORT SurfaceTargets
  ARCHIVE DESTINATION lib
  INCLUDES DESTINATION include)
install(DIRECTORY include/ DESTINATION include)
install(EXPORT SurfaceTargets
  FILE SurfaceTargets.cmake
  NAMESPACE Surface::
  DESTINATION lib/cmake/Surface)
install(FILES cmake/SurfaceConfig.cmake DESTINATION lib/cmake/Surface)
EOF

(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
)

record_green_and_regression() {
    local task=$1 cycle=$2 kind=$3 surface=$4
    shift 4
    run_managed_at "$repo" scripts/task_verify.sh "$task" \
        --phase green --cycle "$cycle" --kind "$kind" "$@"
    assert_status 0
    run_managed_at "$repo" scripts/task_verify.sh "$task" \
        --phase regression --cycle "$cycle" --kind "$kind" \
        --surface "$surface" "$@"
    assert_status 0
    run_managed_at "$repo" scripts/task_verify.sh --complete "$task"
    assert_status 0
}

record_green_and_regression 1 callback-dispatch behavior surface-callback-dispatch \
    --path src/plugin.cpp --path src/app.cpp \
    --observed 'The production entrypoint dispatches the registered callback.' -- \
    bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app callback'
record_green_and_regression 2 configuration-runtime behavior surface-configuration-runtime \
    --path src/config.cpp --path src/app.cpp \
    --observed 'The real process reads and applies mode=fast.' -- \
    bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app configuration'
record_green_and_regression 3 protocol-roundtrip behavior surface-protocol-roundtrip \
    --path src/protocol.cpp --path src/app.cpp \
    --observed 'The production producer and consumer roundtrip the persisted message.' -- \
    bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app protocol'
record_green_and_regression 4 cli-entrypoint behavior surface-cli-entrypoint \
    --path src/app.cpp \
    --observed 'The real executable accepts --summary and prints the approved output.' -- \
    bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app cli'
run_managed_at "$repo" scripts/task_verify.sh 5 \
    --phase green --cycle downstream-install --kind behavior \
    --path CMakeLists.txt \
    --observed 'The same downstream consumer now configures, links, and runs from the install tree.' -- \
    tests/downstream_probe.sh build/generator build/generator-install build/generator-downstream
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 5 \
    --phase regression --cycle downstream-install --kind behavior \
    --surface surface-build-install \
    --path CMakeLists.txt \
    --observed 'The representative downstream runtime remains observable after installation.' -- \
    tests/downstream_probe.sh build/generator build/generator-install build/generator-downstream
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh 5 \
    --phase regression --cycle downstream-install --kind build \
    --surface surface-build-install --path CMakeLists.txt \
    --observed 'The installed export configures, builds, links, and runs in a downstream project.' -- \
    tests/downstream_probe.sh build/generator build/generator-install build/generator-downstream
assert_status 0
run_managed_at "$repo" scripts/task_verify.sh --complete 5
assert_status 0

note '完整 Generator evidence 生成无孤儿的 reviewed-inventory surface report'
run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --refresh --json
assert_status 0
report="$harness_dir/integration-surface-report.json"
node - "$report" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2]));
const expected = [
  'surface-build-install', 'surface-callback-dispatch', 'surface-cli-entrypoint',
  'surface-configuration-runtime', 'surface-protocol-roundtrip'
];
if (report.status !== 'complete' || report.discovery_mode !== 'reviewed_inventory' ||
    JSON.stringify(report.planned_surface_ids) !== JSON.stringify(expected) ||
    report.unmatched_candidates.length !== 0 || report.changed_production_paths.length !== 5) {
  throw new Error(`real surface report did not close: ${JSON.stringify(report)}`);
}
for (const surfaceId of expected) {
  const binding = report.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
  if (!binding?.candidate_bindings.some(item => item.role === 'producer')) {
    throw new Error(`missing changed producer binding: ${surfaceId}`);
  }
}
NODE

note '独立 Evaluator 对每个 surface 运行真实消费者命令，并精确绑定 surface/current role'
(
    cd "$repo"
    scripts/evaluator_check.sh --begin "$change" >/dev/null
    scripts/evaluator_check.sh --run --kind behavior --surface surface-callback-dispatch \
        --expected 'A freshly built real executable dispatches its registered callback.' \
        --observed 'The independent callback command printed callback:dispatched.' -- \
        bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app callback'
    scripts/evaluator_check.sh --run --kind behavior --surface surface-configuration-runtime \
        --expected 'A real process reads mode=fast and changes observable output.' \
        --observed 'The independent configuration command printed mode:fast.' -- \
        bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app configuration'
    scripts/evaluator_check.sh --run --kind behavior --surface surface-protocol-roundtrip \
        --expected 'The production writer and reader complete one real persistence roundtrip.' \
        --observed 'The independent protocol command printed protocol:roundtrip.' -- \
        bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app protocol'
    scripts/evaluator_check.sh --run --kind behavior --surface surface-cli-entrypoint \
        --expected 'The real executable accepts --summary and exits successfully.' \
        --observed 'The independent CLI command printed summary:ok.' -- \
        bash -c 'cmake --build build/generator --parallel 2 >/dev/null && tests/integration_probe.sh build/generator/surface_app cli'
    scripts/evaluator_check.sh --run --kind build --surface surface-build-install \
        --expected 'An installed package configures, builds, links, and runs downstream.' \
        --observed 'The independent downstream command printed downstream-install-ok.' -- \
        tests/downstream_probe.sh build/generator build/generator-install build/generator-downstream
    scripts/evaluator_check.sh --run --kind behavior --surface surface-build-install \
        --expected 'The executable built from the installed package runs and prints installed-surface-ok.' \
        --observed 'The independent downstream runtime completed and the probe printed downstream-install-ok.' -- \
        tests/downstream_probe.sh build/generator build/generator-install build/generator-downstream
)

baseline="$harness_dir/evaluation-baseline.json"
ledger="$harness_dir/evaluation-command-ledger.json"
evaluation="$harness_dir/evaluation.json"

node - "$baseline" "$harness_dir/change-footprint.json" "$ledger" "$report" \
    "$evaluation" "$change" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, reportFile, outputFile, change] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const footprint = JSON.parse(fs.readFileSync(footprintFile));
const ledger = JSON.parse(fs.readFileSync(ledgerFile));
const report = JSON.parse(fs.readFileSync(reportFile));
const commands = [...ledger.commands];
if (baseline.schema_version !== 3 || ledger.schema_version !== 2 || commands.length !== 6 ||
    commands.some(command => command.result !== 'Pass' || command.surface_ids.length !== 1 ||
      command.surface_evidence_roles.length !== 1 || command.surface_evidence_roles[0].role !== 'current')) {
  throw new Error('independent integrated ledger is incomplete');
}

const surfaceMeta = new Map([
  ['surface-build-install', {
    task: '5', kinds: ['build', 'behavior'], requirement: 'Export downstream CMake package',
    scenario: 'Consume installed target'
  }],
  ['surface-callback-dispatch', {
    task: '1', kinds: ['behavior'], requirement: 'Dispatch registered callback',
    scenario: 'Observe callback dispatch'
  }],
  ['surface-cli-entrypoint', {
    task: '4', kinds: ['behavior'], requirement: 'Expose summary CLI',
    scenario: 'Observe summary output'
  }],
  ['surface-configuration-runtime', {
    task: '2', kinds: ['behavior'], requirement: 'Apply runtime configuration',
    scenario: 'Observe configured mode'
  }],
  ['surface-protocol-roundtrip', {
    task: '3', kinds: ['behavior'], requirement: 'Consume protocol roundtrip',
    scenario: 'Observe producer consumer roundtrip'
  }]
]);
const commandsBySurface = new Map();
for (const command of commands) {
  const surfaceId = command.surface_ids[0];
  const rows = commandsBySurface.get(surfaceId) || [];
  rows.push(command);
  commandsBySurface.set(surfaceId, rows);
}
for (const surfaceId of surfaceMeta.keys()) {
  const expectedKinds = surfaceMeta.get(surfaceId).kinds;
  const actualKinds = (commandsBySurface.get(surfaceId) || []).map(command => command.kind).sort();
  if (JSON.stringify(actualKinds) !== JSON.stringify([...expectedKinds].sort())) {
    throw new Error(`surface independent command kinds mismatch: ${surfaceId}`);
  }
}
const refFor = surfaceId => {
  const meta = surfaceMeta.get(surfaceId);
  return {
    spec_path: 'specs/surface-completeness/spec.md', operation: 'ADDED',
    requirement: meta.requirement, scenarios: [meta.scenario]
  };
};
const allRefs = [...surfaceMeta.keys()].map(refFor);
const allTaskIds = ['1', '2', '3', '4', '5'];
const allCommandIds = commands.map(command => command.id);
const evidenceFinished = Math.max(Date.parse(baseline.started_at), ...commands.map(command => Date.parse(command.finished_at)));
const reviewedAt = new Date(evidenceFinished).toISOString();
const evaluatedAt = new Date(Math.max(Date.now(), evidenceFinished)).toISOString();
const reviewStage = (name, startedAt, completedAt, dimensions) => ({
  name, started_at: startedAt, completed_at: completedAt, status: 'Pass',
  requirement_refs: allRefs, task_ids: allTaskIds,
  reviewed_paths: baseline.review_input.review_paths, dimensions,
  evidence_command_ids: allCommandIds, finding_ids: [], blocking_untested_ids: [],
  not_run_reason: null
});

const typedByCandidate = new Map();
for (const surfaceBinding of report.surface_candidate_bindings) {
  for (const candidateBinding of surfaceBinding.candidate_bindings) {
    const entries = typedByCandidate.get(candidateBinding.candidate_id) || [];
    entries.push({surface: surfaceBinding, role: candidateBinding.role});
    typedByCandidate.set(candidateBinding.candidate_id, entries);
  }
}
const allCandidates = [...report.path_candidates, ...report.structural_candidates, ...report.ast_candidates];
const candidateAssessments = allCandidates.map(candidate => {
  const typed = typedByCandidate.get(candidate.candidate_id) || [];
  if (!typed.length) throw new Error(`complete report has unbound candidate: ${candidate.candidate_id}`);
  const bySurface = new Map();
  for (const item of typed) {
    const roles = bySurface.get(item.surface.surface_id) || [];
    roles.push(item.role);
    bySurface.set(item.surface.surface_id, roles);
  }
  const surfaceIds = [...bySurface.keys()].sort();
  const logicalPaths = [...new Set([candidate.old_path, candidate.path].filter(Boolean))].sort();
  const producerPaths = logicalPaths.filter(candidatePath => typed.some(item =>
    item.role === 'producer' && item.surface.producer_paths.includes(candidatePath)));
  const evidenceCommandIds = [...new Set(surfaceIds.flatMap(surfaceId =>
    (commandsBySurface.get(surfaceId) || []).map(command => command.id)))].sort();
  return {
    candidate_id: candidate.candidate_id,
    source: candidate.source,
    disposition: 'mapped',
    surface_ids: surfaceIds,
    surface_bindings: surfaceIds.map(surfaceId => {
      const surface = report.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
      const roles = [...new Set(bySurface.get(surfaceId))]
        .sort((a, b) => ['producer', 'consumer'].indexOf(a) - ['producer', 'consumer'].indexOf(b));
      const plannedConsumerKind = {
        'surface-build-install': 'downstream_build',
        'surface-callback-dispatch': 'registration_dispatch',
        'surface-cli-entrypoint': 'real_entrypoint',
        'surface-configuration-runtime': 'real_entrypoint',
        'surface-protocol-roundtrip': 'producer_consumer_pair'
      }[surfaceId];
      return {
        surface_id: surfaceId,
        candidate_roles: roles,
        consumer_kind: plannedConsumerKind,
        consumer_paths: surface.consumer_paths
      };
    }),
    reason: 'The complete diff candidate is mapped to every approved surface it produces or consumes.',
    producer_paths: producerPaths,
    implementation_consumer: null,
    evidence_paths: logicalPaths,
    evidence_command_ids: evidenceCommandIds,
    orphan_ids: []
  };
}).sort((a, b) => a.candidate_id.localeCompare(b.candidate_id));

const surfaceAssessments = [...surfaceMeta.keys()].map(surfaceId => {
  const meta = surfaceMeta.get(surfaceId);
  const surfaceCommands = commandsBySurface.get(surfaceId) || [];
  const commandIds = surfaceCommands.map(command => command.id);
  const binding = report.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
  return {
    surface_id: surfaceId,
    result: 'Pass',
    reason: 'The independent command reaches the approved real consumer and observes the planned result.',
    consumer_paths: binding.consumer_paths,
    old_consumer_paths: binding.old_consumer_paths,
    replacement_consumer_paths: binding.replacement_consumer_paths,
    kind_evidence: meta.kinds.map(kind => ({
      kind,
      evidence_command_ids: surfaceCommands.filter(command => command.kind === kind).map(command => command.id)
    })),
    role_evidence: [{role: 'current', evidence_command_ids: commandIds}],
    evidence_command_ids: commandIds,
    blocking_untested_ids: [],
    orphan_ids: []
  };
});
const criteria = [...surfaceMeta.keys()].map(surfaceId => {
  const meta = surfaceMeta.get(surfaceId);
  return {
    id: 'criterion-' + surfaceId.slice('surface-'.length),
    description: `The ${surfaceId} consumer produces its approved observable result.`,
    requirement_refs: [refFor(surfaceId)], task_ids: [meta.task], status: 'Pass',
    evidence_command_ids: (commandsBySurface.get(surfaceId) || []).map(command => command.id), blocking_untested_ids: []
  };
}).sort((a, b) => a.id.localeCompare(b.id));

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
    drift_explanation: footprint.status === 'within_expected' ? null :
      'The reviewed fixture remains below every hard limit and the five planned closures explain the reviewed variance.',
    classification_assessment: {
      result: 'Pass',
      reason: 'Every changed product path belongs to one closed production classification.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: allCommandIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets', applicability: 'applicable', result: 'Pass',
          reason: 'The existing library and executable pass all focused real-consumer commands.',
          evidence_paths: report.changed_production_paths, evidence_command_ids: allCommandIds,
          not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'applicable', result: 'Pass',
          reason: 'The representative installed consumer configures, builds, links, and runs.',
          evidence_paths: ['CMakeLists.txt', 'tests/downstream/CMakeLists.txt', 'tests/downstream/main.cpp'],
          evidence_command_ids: (commandsBySurface.get('surface-build-install') || []).map(command => command.id),
          not_applicable_reason: null
        },
        {
          surface: 'package', applicability: 'applicable', result: 'Pass',
          reason: 'The installed package config and exported target are consumed downstream.',
          evidence_paths: ['CMakeLists.txt', 'cmake/SurfaceConfig.cmake', 'tests/downstream/CMakeLists.txt'],
          evidence_command_ids: (commandsBySurface.get('surface-build-install') || []).map(command => command.id),
          not_applicable_reason: null
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'This disposable real fixture has no CI configuration.',
          evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI file exists in the approved implementation base.'
        }
      ]
    },
    reuse_assessments: [],
    structural_assessments: [{
      allowance_id: 'cmake-surface-install-export',
      candidate_ids: report.structural_candidates.map(candidate => candidate.candidate_id),
      result: 'Pass',
      reason: 'The only CMake structural candidate is the approved install/export of the existing target.',
      evidence_paths: ['CMakeLists.txt', 'tests/downstream/CMakeLists.txt', 'tests/downstream/main.cpp'],
      evidence_command_ids: (commandsBySurface.get('surface-build-install') || []).map(command => command.id)
    }],
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria,
  commands,
  blocking_untested: [],
  residual_risks: [],
  integration_completeness: {
    planning_block_sha256: baseline.integration_planning_block_sha256,
    report_sha256: baseline.integration_surface_report_sha256,
    discovery_identity_sha256: baseline.integration_discovery_identity_sha256,
    inventory_assessment: {
      result: 'Pass',
      reason: 'All production candidates and all five surface kinds were independently reviewed.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: allCommandIds
    },
    candidate_assessments: candidateAssessments,
    surface_assessments: surfaceAssessments,
    orphan_surfaces: [],
    result: 'Pass'
  }
};
fs.writeFileSync(outputFile, JSON.stringify(evaluation, null, 2) + '\n');
NODE

run_managed_at "$repo" scripts/evaluator_check.sh --finish "$change"
assert_status 0

note '唯一 Evaluation3 Pass 通过 archive；报告和五类 surface assessment 随 change 保留'
run_managed_at "$repo" scripts/change_archive.sh "$change"
assert_status 0
archived_as="$(date -u +%Y-%m-%d)-$change"
archived_dir="$repo/openspec/changes/archive/$archived_as"
assert_path_absent "$change_dir"
assert_path_exists "$archived_dir/harness/integration-surface-report.json"
assert_path_exists "$archived_dir/harness/evaluation.json"
assert_path_exists "$repo/openspec/specs/surface-completeness/spec.md"
node - "$repo/ai_snapshot.json" "$archived_dir/harness/integration-surface-report.json" \
    "$archived_dir/harness/evaluation.json" "$change" "$archived_as" <<'NODE'
const fs = require('fs');
const [rootFile, reportFile, evaluationFile, change, archivedAs] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(rootFile));
const report = JSON.parse(fs.readFileSync(reportFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
if (root.active_change !== null || root.last_archived_change?.change_name !== change ||
    root.last_archived_change?.archived_as !== archivedAs || report.status !== 'complete' ||
    evaluation.schema_version !== 3 || evaluation.verdict !== 'Pass' ||
    evaluation.integration_completeness?.surface_assessments?.length !== 5 ||
    evaluation.integration_completeness.surface_assessments.some(item => item.result !== 'Pass')) {
  throw new Error('archived real surface-kind evidence is incomplete');
}
NODE

note 'callback/config/protocol/CLI/install 五类真实消费者从负向门禁到 archive 的 fresh v4/v3 生命周期通过'
