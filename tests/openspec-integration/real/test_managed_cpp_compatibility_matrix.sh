#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT
repo="$tmp/managed cpp compatibility matrix"

for command_name in cmake c++ git node npm npx; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "真实 C++ compatibility 矩阵缺少依赖：$command_name"
done

init_git_repo "$repo"
mkdir -p "$repo/include/compat" "$repo/src" "$repo/cmake" "$repo/tests/cmake-consumer"

cat > "$repo/.gitignore" <<'EOF'
/build/
EOF

cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_cpp_compatibility LANGUAGES CXX)

include(GNUInstallDirs)

add_library(compat_core STATIC src/internal.cpp src/external.cpp)
set_target_properties(compat_core PROPERTIES EXPORT_NAME core)
target_compile_features(compat_core PUBLIC cxx_std_17)
target_include_directories(compat_core
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")

add_library(compat_legacy INTERFACE)
set_target_properties(compat_legacy PROPERTIES EXPORT_NAME legacy)
target_link_libraries(compat_legacy INTERFACE compat_core)

add_executable(compat_app src/app.cpp)
target_include_directories(compat_app PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(compat_app PRIVATE compat_core)

install(TARGETS compat_core compat_legacy EXPORT CompatTargets
  ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  INCLUDES DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(DIRECTORY include/ DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(EXPORT CompatTargets FILE CompatTargets.cmake NAMESPACE Compat::
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Compat")
configure_file(cmake/CompatConfig.cmake.in CompatConfig.cmake @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/CompatConfig.cmake"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Compat")
EOF

cat > "$repo/cmake/CompatConfig.cmake.in" <<'EOF'
include("${CMAKE_CURRENT_LIST_DIR}/CompatTargets.cmake")
EOF

cat > "$repo/include/compat/api.hpp" <<'EOF'
#pragma once

namespace compat {

int legacy_external();

}
EOF

cat > "$repo/src/internal.hpp" <<'EOF'
#pragma once

namespace compat {

int legacy_internal();

}
EOF

cat > "$repo/src/internal.cpp" <<'EOF'
#include "internal.hpp"

namespace compat {

int legacy_internal() {
    return 42;
}

}
EOF

cat > "$repo/src/external.cpp" <<'EOF'
#include "compat/api.hpp"

namespace compat {

int legacy_external() {
    return 42;
}

}
EOF

cat > "$repo/src/app.cpp" <<'EOF'
#include "internal.hpp"

#include <iostream>
#include <string_view>

int main(int argc, char** argv) {
    const std::string_view option = argc > 1 ? argv[1] : "--help";
    if (option == "--legacy-internal") {
        std::cout << "internal:" << compat::legacy_internal() << '\n';
        return 0;
    }
    if (option == "--help") {
        std::cout << "--legacy-internal\n";
        return 0;
    }
    std::cerr << "unknown option: " << option << '\n';
    return 64;
}
EOF

cat > "$repo/tests/legacy_external.cpp" <<'EOF'
#include "compat/api.hpp"
#include <iostream>

int main() {
    std::cout << "external:" << compat::legacy_external() << '\n';
}
EOF

cat > "$repo/tests/current_external.cpp" <<'EOF'
#include "compat/api.hpp"
#include <iostream>

int main() {
    std::cout << "external:" << compat::current_external() << '\n';
}
EOF

cat > "$repo/tests/cmake-consumer/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_compat_consumer LANGUAGES CXX)

find_package(Compat CONFIG REQUIRED)
if(NOT DEFINED COMPAT_TARGET)
  message(FATAL_ERROR "COMPAT_TARGET is required")
endif()
add_executable(compat_consumer main.cpp)
target_link_libraries(compat_consumer PRIVATE "${COMPAT_TARGET}")
EOF

cat > "$repo/tests/cmake-consumer/main.cpp" <<'EOF'
#include "compat/api.hpp"
#include <iostream>

int main() {
    std::cout << "cmake:" << compat::current_external() << '\n';
}
EOF

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

write_probe() {
    local mode=$1
    cat > "$repo/tests/compatibility_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -u

mode=${1:?deprecation or removal required}
[[ "$mode" == deprecation || "$mode" == removal ]] || exit 2
fail() {
    echo "$mode-probe-red"
    exit 1
}

root=$(pwd)/build/compatibility-"$mode"
build=$root/project
prefix=$root/install
rm -rf -- "$root"
cmake -S . -B "$build" -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 || fail
cmake --build "$build" --parallel 2 >/dev/null 2>&1 || fail
cmake --install "$build" --prefix "$prefix" >/dev/null 2>&1 || fail
app=$build/compat_app
lib=$prefix/lib/libcompat_core.a
include=$prefix/include

if [[ "$mode" == deprecation ]]; then
    internal_stderr=$root/internal-legacy.stderr
    internal_output=$("$app" --legacy-internal 2>"$internal_stderr") || fail
    [[ "$internal_output" == internal:42 ]] || fail
    grep -Fxq 'DEPRECATED: legacy_internal; use current_internal' "$internal_stderr" || fail
    [[ "$("$app" --current-internal 2>/dev/null)" == internal:42 ]] || fail

    c++ -std=c++17 -Wall tests/legacy_external.cpp -I"$include" "$lib" \
        -o "$root/legacy-external" 2>"$root/legacy-external.stderr" || fail
    grep -Fq 'legacy_external is deprecated; use current_external' \
        "$root/legacy-external.stderr" || fail
    [[ "$("$root/legacy-external")" == external:42 ]] || fail
    c++ -std=c++17 tests/current_external.cpp -I"$include" "$lib" \
        -o "$root/current-external" >/dev/null 2>&1 || fail
    [[ "$("$root/current-external")" == external:42 ]] || fail

    cmake -S tests/cmake-consumer -B "$root/legacy-cmake" \
        -DCMAKE_PREFIX_PATH="$prefix" -DCOMPAT_TARGET=Compat::legacy \
        >"$root/legacy-cmake.stdout" 2>"$root/legacy-cmake.stderr" || fail
    grep -Fq 'Compat::legacy is deprecated; use Compat::current' \
        "$root/legacy-cmake.stderr" || fail
    cmake --build "$root/legacy-cmake" --parallel 2 >/dev/null 2>&1 || fail
    [[ "$("$root/legacy-cmake/compat_consumer")" == cmake:42 ]] || fail
else
    set +e
    "$app" --legacy-internal >"$root/internal-legacy.stdout" 2>"$root/internal-legacy.stderr"
    internal_status=$?
    set -e
    [[ "$internal_status" -eq 64 && ! -s "$root/internal-legacy.stdout" ]] || fail
    grep -Fxq 'unknown option: --legacy-internal' "$root/internal-legacy.stderr" || fail
    help_output=$("$app" --help 2>/dev/null) || fail
    [[ "$help_output" == *--current-internal* && "$help_output" != *--legacy-internal* ]] || fail
    [[ "$("$app" --current-internal 2>/dev/null)" == internal:42 ]] || fail

    set +e
    c++ -std=c++17 tests/legacy_external.cpp -I"$include" "$lib" \
        -o "$root/legacy-external" >"$root/legacy-external.stdout" \
        2>"$root/legacy-external.stderr"
    external_status=$?
    set -e
    [[ "$external_status" -ne 0 ]] || fail
    grep -Fq 'legacy_external' "$root/legacy-external.stderr" || fail
    c++ -std=c++17 tests/current_external.cpp -I"$include" "$lib" \
        -o "$root/current-external" >/dev/null 2>&1 || fail
    [[ "$("$root/current-external")" == external:42 ]] || fail

    set +e
    cmake -S tests/cmake-consumer -B "$root/legacy-cmake" \
        -DCMAKE_PREFIX_PATH="$prefix" -DCOMPAT_TARGET=Compat::legacy \
        >"$root/legacy-cmake.stdout" 2>"$root/legacy-cmake.stderr"
    cmake_status=$?
    set -e
    [[ "$cmake_status" -ne 0 ]] || fail
    grep -Fq 'Compat::legacy' "$root/legacy-cmake.stderr" || fail
fi

cmake -S tests/cmake-consumer -B "$root/current-cmake" \
    -DCMAKE_PREFIX_PATH="$prefix" -DCOMPAT_TARGET=Compat::current \
    >/dev/null 2>&1 || fail
cmake --build "$root/current-cmake" --parallel 2 >/dev/null 2>&1 || fail
[[ "$("$root/current-cmake/compat_consumer")" == cmake:42 ]] || fail

echo "$mode-internal-old-consumer-ok"
echo "$mode-internal-replacement-consumer-ok"
echo "$mode-external-old-consumer-ok"
echo "$mode-external-replacement-consumer-ok"
echo "$mode-install-old-consumer-ok"
echo "$mode-install-replacement-consumer-ok"
if [[ "$mode" == removal ]]; then
    echo removal-internal-absence-probe-ok
    echo removal-external-absence-probe-ok
    echo removal-install-absence-probe-ok
fi
EOF
    chmod 755 "$repo/tests/compatibility_probe.sh"
}

write_implementation() {
    local mode=$1
    if [[ "$mode" == deprecation ]]; then
        cat > "$repo/include/compat/api.hpp" <<'EOF'
#pragma once

namespace compat {

[[deprecated("legacy_external is deprecated; use current_external")]]
int legacy_external();
int current_external();

}
EOF
        cat > "$repo/src/internal.hpp" <<'EOF'
#pragma once

namespace compat {

[[deprecated("legacy_internal is deprecated; use current_internal")]]
int legacy_internal();
int current_internal();

}
EOF
        cat > "$repo/src/internal.cpp" <<'EOF'
#include "internal.hpp"

namespace compat {

int legacy_internal() {
    return 42;
}

int current_internal() {
    return 42;
}

}
EOF
        cat > "$repo/src/external.cpp" <<'EOF'
#include "compat/api.hpp"

namespace compat {

int legacy_external() {
    return 42;
}

int current_external() {
    return 42;
}

}
EOF
        cat > "$repo/src/app.cpp" <<'EOF'
#include "internal.hpp"

#include <iostream>
#include <string_view>

int main(int argc, char** argv) {
    const std::string_view option = argc > 1 ? argv[1] : "--help";
    if (option == "--legacy-internal") {
        std::cerr << "DEPRECATED: legacy_internal; use current_internal\n";
        std::cout << "internal:" << compat::legacy_internal() << '\n';
        return 0;
    }
    if (option == "--current-internal") {
        std::cout << "internal:" << compat::current_internal() << '\n';
        return 0;
    }
    if (option == "--help") {
        std::cout << "--legacy-internal (deprecated)\n--current-internal\n";
        return 0;
    }
    std::cerr << "unknown option: " << option << '\n';
    return 64;
}
EOF
        cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_cpp_compatibility LANGUAGES CXX)

include(GNUInstallDirs)

add_library(compat_core STATIC src/internal.cpp src/external.cpp)
set_target_properties(compat_core PROPERTIES EXPORT_NAME core)
target_compile_features(compat_core PUBLIC cxx_std_17)
target_include_directories(compat_core
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")

add_library(compat_legacy INTERFACE)
set_target_properties(compat_legacy PROPERTIES EXPORT_NAME legacy)
target_link_libraries(compat_legacy INTERFACE compat_core)
add_library(compat_current INTERFACE)
set_target_properties(compat_current PROPERTIES EXPORT_NAME current)
target_link_libraries(compat_current INTERFACE compat_core)

add_executable(compat_app src/app.cpp)
target_include_directories(compat_app PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(compat_app PRIVATE compat_core)

install(TARGETS compat_core compat_legacy compat_current EXPORT CompatTargets
  ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  INCLUDES DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(DIRECTORY include/ DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(EXPORT CompatTargets FILE CompatTargets.cmake NAMESPACE Compat::
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Compat")
configure_file(cmake/CompatConfig.cmake.in CompatConfig.cmake @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/CompatConfig.cmake"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Compat")
EOF
        cat > "$repo/cmake/CompatConfig.cmake.in" <<'EOF'
include("${CMAKE_CURRENT_LIST_DIR}/CompatTargets.cmake")
if(TARGET Compat::legacy)
  set_property(TARGET Compat::legacy PROPERTY
    DEPRECATION "Compat::legacy is deprecated; use Compat::current")
endif()
EOF
    else
        cat > "$repo/include/compat/api.hpp" <<'EOF'
#pragma once

namespace compat {

int current_external();

}
EOF
        cat > "$repo/src/internal.hpp" <<'EOF'
#pragma once

namespace compat {

int current_internal();

}
EOF
        cat > "$repo/src/internal.cpp" <<'EOF'
#include "internal.hpp"

namespace compat {

int current_internal() {
    return 42;
}

}
EOF
        cat > "$repo/src/external.cpp" <<'EOF'
#include "compat/api.hpp"

namespace compat {

int current_external() {
    return 42;
}

}
EOF
        cat > "$repo/src/app.cpp" <<'EOF'
#include "internal.hpp"

#include <iostream>
#include <string_view>

int main(int argc, char** argv) {
    const std::string_view option = argc > 1 ? argv[1] : "--help";
    if (option == "--current-internal") {
        std::cout << "internal:" << compat::current_internal() << '\n';
        return 0;
    }
    if (option == "--help") {
        std::cout << "--current-internal\n";
        return 0;
    }
    std::cerr << "unknown option: " << option << '\n';
    return 64;
}
EOF
        cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_cpp_compatibility LANGUAGES CXX)

include(GNUInstallDirs)

add_library(compat_core STATIC src/internal.cpp src/external.cpp)
set_target_properties(compat_core PROPERTIES EXPORT_NAME core)
target_compile_features(compat_core PUBLIC cxx_std_17)
target_include_directories(compat_core
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")

add_library(compat_current INTERFACE)
set_target_properties(compat_current PROPERTIES EXPORT_NAME current)
target_link_libraries(compat_current INTERFACE compat_core)

add_executable(compat_app src/app.cpp)
target_include_directories(compat_app PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(compat_app PRIVATE compat_core)

install(TARGETS compat_core compat_current EXPORT CompatTargets
  ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  INCLUDES DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(DIRECTORY include/ DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(EXPORT CompatTargets FILE CompatTargets.cmake NAMESPACE Compat::
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Compat")
configure_file(cmake/CompatConfig.cmake.in CompatConfig.cmake @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/CompatConfig.cmake"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Compat")
EOF
        cat > "$repo/cmake/CompatConfig.cmake.in" <<'EOF'
include("${CMAKE_CURRENT_LIST_DIR}/CompatTargets.cmake")
EOF
    fi
}

write_change_plan() {
    local change=$1 mode=$2
    local change_dir="$repo/openspec/changes/$change"
    mkdir -p "$change_dir/specs/cpp-compatibility"
    node - "$change_dir" "$mode" <<'NODE'
const fs = require('fs');
const path = require('path');
const [changeDir, mode] = process.argv.slice(2);
const deprecated = mode === 'deprecation';
if (!deprecated && mode !== 'removal') throw new Error('unknown compatibility mode');

const operation = deprecated ? 'ADDED' : 'MODIFIED';
const changeKind = deprecated ? 'deprecated' : 'removed';
const impact = deprecated ? 'deprecation' : 'removal';
const roles = deprecated
  ? ['old_consumer', 'replacement_consumer']
  : ['old_consumer', 'replacement_consumer', 'absence_probe'];
const requirement = 'Migrate C++ and CMake compatibility surfaces';
const scenario = 'Compatibility migration state is observable';
const probeArgv = ['tests/compatibility_probe.sh', mode];
const roleLabel = role => role.replaceAll('_', '-');

const budget = {
  schema_version: 1,
  profile: 'medium',
  rationale: 'Modify three existing compatibility surfaces and reuse one exact real-consumer probe without adding a production target or dependency.',
  classification: {
    production: ['src/**', 'include/**', 'CMakeLists.txt', 'cmake/**'],
    tests: ['tests/**'],
    project_docs: ['README.md'],
    project_tooling: ['tooling/**'],
    examples: ['examples/**'],
    generated: [],
    vendor: ['vendor/**']
  },
  thresholds: {
    production: {
      added_lines: {expected: 180, review_at: 280, hard_limit: 480},
      touched_files: {expected: 7, review_at: 9, hard_limit: 12},
      new_files: {expected: 0, review_at: 1, hard_limit: 2}
    },
    tests: {
      added_lines: {expected: 0, review_at: 8, hard_limit: 20},
      touched_files: {expected: 0, review_at: 1, hard_limit: 2},
      new_files: {expected: 0, review_at: 1, hard_limit: 2}
    },
    project_support: {
      added_lines: {expected: 0, review_at: 8, hard_limit: 20},
      new_files: {expected: 0, review_at: 1, hard_limit: 2}
    },
    generated: {
      files: {expected: 0, review_at: 1, hard_limit: 2},
      bytes: {expected: 0, review_at: 1024, hard_limit: 4096}
    }
  },
  structural_allowances: {
    public_contracts: [{
      id: 'cpp-compatibility-contracts',
      name: 'internal and installed C++ compatibility declarations',
      reason: 'The approved lifecycle explicitly deprecates or removes legacy declarations while retaining their replacements.'
    }],
    cmake_targets: [{
      id: 'cmake-compatibility-export',
      name: 'installed legacy and replacement CMake targets',
      reason: 'The approved lifecycle explicitly deprecates or removes the legacy exported target while retaining Compat::current.'
    }],
    direct_dependencies: []
  },
  reuse_decisions: [],
  obsolete_items: [],
  exceptions: []
};

const requirementRef = {
  operation,
  requirement,
  scenarios: [scenario],
  spec_path: 'specs/cpp-compatibility/spec.md'
};
const pathsFor = kind => {
  if (!deprecated) {
    return {
      consumer: ['tests/compatibility_probe.sh'],
      old: ['tests/compatibility_probe.sh'],
      replacement: ['tests/compatibility_probe.sh']
    };
  }
  if (kind === 'internal') {
    return {consumer: ['src/app.cpp'], old: ['src/app.cpp'], replacement: ['src/app.cpp']};
  }
  if (kind === 'external') {
    return {
      consumer: ['tests/current_external.cpp'],
      old: ['tests/legacy_external.cpp'],
      replacement: ['tests/current_external.cpp']
    };
  }
  return {
    consumer: ['tests/cmake-consumer/CMakeLists.txt'],
    old: ['tests/cmake-consumer/CMakeLists.txt'],
    replacement: ['tests/cmake-consumer/CMakeLists.txt']
  };
};
const surface = ({id, short, kind, consumerKind, producerPaths, verifyKinds}) => {
  const paths = pathsFor(short);
  return {
    change_kind: changeKind,
    compatibility: {
      old_consumer_paths: paths.old,
      replacement_consumer_paths: paths.replacement,
      replacement_policy: 'required',
      expected_old_result: deprecated
        ? `The ${short} legacy consumer remains successful and emits an observable deprecation signal.`
        : `The ${short} legacy consumer or entrypoint is rejected while the replacement remains available.`,
      migration_path: `Move the ${short} consumer from the legacy surface to its current replacement.`,
      exit_condition: deprecated
        ? `Remove the ${short} legacy surface only in a separately approved removal change.`
        : `Keep the ${short} absence and replacement probes green.`
    },
    consumer_kind: deprecated ? consumerKind : 'compatibility_probe',
    consumer_paths: paths.consumer,
    contract_impact: impact,
    entrypoint: `${short} compatibility consumer probe`,
    evidence_contracts: verifyKinds.flatMap(kindName => roles.map(role => ({
      argv: probeArgv,
      expected_exit_codes: [0],
      kind: kindName,
      output_contains: `${mode}-${short}-${roleLabel(role)}-ok`,
      probe_id: `probe-${mode}-${short}-${kindName}-${roleLabel(role)}`,
      role
    }))),
    expected_observation: deprecated
      ? `Legacy and replacement ${short} consumers both succeed and the legacy path is visibly deprecated.`
      : `The legacy ${short} surface is absent while the replacement consumer succeeds.`,
    id,
    kind,
    name: `${mode} ${short} compatibility surface`,
    producer_paths: producerPaths,
    requirement_refs: [requirementRef],
    ...(kind === 'build_or_install' ? {runnable_artifact: true} : {}),
    symbol_identities: null,
    task_ids: ['1'],
    task_obligations: [{evidence_roles: roles, task_id: '1', verify_kinds: verifyKinds}],
    verify_kinds: verifyKinds
  };
};
const surfaces = [
  surface({
    id: 'surface-internal-compatibility',
    short: 'internal',
    kind: 'internal_api',
    consumerKind: 'production_caller',
    producerPaths: ['src/internal.hpp', 'src/internal.cpp', 'src/app.cpp'],
    verifyKinds: ['behavior']
  }),
  surface({
    id: 'surface-external-compatibility',
    short: 'external',
    kind: 'external_api',
    consumerKind: 'representative_external',
    producerPaths: ['include/compat/api.hpp', 'src/external.cpp'],
    verifyKinds: ['behavior']
  }),
  surface({
    id: 'surface-install-compatibility',
    short: 'install',
    kind: 'build_or_install',
    consumerKind: 'downstream_build',
    producerPaths: ['CMakeLists.txt', 'cmake/CompatConfig.cmake.in'],
    verifyKinds: ['build', 'behavior']
  })
];

const proposal = `## Why

The internal API, installed C++ SDK, and exported CMake target need one explicit ${mode} phase with executable migration evidence.

## What Changes

- ${deprecated ? 'Keep every legacy consumer successful with an observable deprecation signal.' : 'Remove every approved legacy surface and prove its absence.'}
- Keep every replacement consumer successful.
- Exercise real C++ compilation, linking, execution, installation, export, and downstream CMake consumption.
- External contract impact: **${impact}**.

## Capabilities

### New Capabilities

${deprecated ? '- `cpp-compatibility`: Defines the migration window for all three compatibility surfaces.' : '- None.'}

### Modified Capabilities

${deprecated ? '- None.' : '- `cpp-compatibility`: Ends the migration window while retaining all replacement surfaces.'}

## Impact

Existing targets and dependencies are reused; no production target or third-party dependency is added.
`;
const requirementBody = deprecated
  ? `The product SHALL keep the legacy internal API, installed C++ API, and exported CMake target usable with observable deprecation signals, and SHALL provide successful replacement consumers for all three.`
  : `The product SHALL reject or omit the legacy internal API, installed C++ API, and exported CMake target, and SHALL keep successful replacement consumers for all three.`;
const spec = `## ${operation} Requirements

### Requirement: ${requirement}
${requirementBody}

#### Scenario: ${scenario}
- **WHEN** the exact internal, external, and installed downstream probes run against clean artifacts
- **THEN** every old, replacement, and required absence role has the approved ${mode} result
`;
const tasks = `## 1. C++ compatibility lifecycle

- [ ] 1 Implement and verify the approved ${mode} phase
  - Covers: \`specs/cpp-compatibility/spec.md\` | \`${operation}\` | \`${requirement}\` | \`${scenario}\`
  - Verify: \`behavior\`, \`build\`
`;
const integration = {
  discovery: {compile_commands_path: null, mode: 'reviewed_inventory'},
  schema_version: 1,
  surfaces
};
const design = `## Context

This change exercises the ${mode} phase against a real C++ library, production executable, installed SDK consumer, and downstream CMake project.

## Goals / Non-Goals

**Goals:** Close every compatibility role through exact clean-build probes and independent Evaluation.

**Non-Goals:** Add targets or dependencies, infer migration, or accept grep/build-only evidence for runtime behavior.

## Decisions

Use one exact probe argv per phase. A behavior command closes internal and external roles; a build command closes the installed CMake roles after configure, build, link, and execution.

## Risks / Trade-offs

Reviewed inventory requires the independent reviewer to inspect the complete diff in addition to the exact consumer evidence.

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
fs.writeFileSync(path.join(changeDir, 'specs/cpp-compatibility/spec.md'), spec);
NODE
}

write_pass_evaluation() {
    local change=$1 mode=$2
    local harness_dir="$repo/openspec/changes/$change/harness"
    (
        cd "$repo"
        node - "$harness_dir/evaluation-baseline.json" "$harness_dir/change-footprint.json" \
            "$harness_dir/evaluation-command-ledger.json" "$harness_dir/integration-surface-report.json" \
            "$harness_dir/evaluation.json" "$change" "$mode" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, reportFile, outputFile, change, mode] =
  process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile));
const footprint = JSON.parse(fs.readFileSync(footprintFile));
const ledger = JSON.parse(fs.readFileSync(ledgerFile));
const report = JSON.parse(fs.readFileSync(reportFile));
const lib = require(process.cwd() + '/scripts/integration_surface_lib.js');
const plan = lib.parsePlan(process.cwd(), change);
const economy = lib.parseEconomy(
  fs.readFileSync(`openspec/changes/${change}/design.md`, 'utf8'));
const commands = [...ledger.commands];
if (baseline.schema_version !== 3 || ledger.schema_version !== 2 ||
    commands.length !== 2 || commands.some(command => command.result !== 'Pass') ||
    commands.map(command => command.kind).sort().join(',') !== 'behavior,build') {
  throw new Error(`${mode} independent ledger must contain exact behavior and build probes`);
}
if (!['within_expected', 'drift_warning'].includes(footprint.status) ||
    report.status !== 'complete' || report.unmatched_candidates.length !== 0) {
  throw new Error(`${mode} footprint or surface report is not closed`);
}

const commandIds = commands.map(command => command.id);
const commandFor = (surfaceId, kind = null, role = null) => commands.filter(command =>
  (!kind || command.kind === kind) &&
  command.surface_probe_bindings.some(binding =>
    binding.surface_id === surfaceId && (!role || binding.role === role)));
for (const surface of plan.block.surfaces) {
  for (const kind of surface.verify_kinds) {
    for (const role of lib.requiredRoles(surface)) {
      const matches = commandFor(surface.id, kind, role);
      if (matches.length !== 1) {
        throw new Error(`missing exact evaluator pair: ${surface.id}/${kind}/${role}`);
      }
    }
  }
}

const requirementRef = {
  spec_path: 'specs/cpp-compatibility/spec.md',
  operation: mode === 'deprecation' ? 'ADDED' : 'MODIFIED',
  requirement: 'Migrate C++ and CMake compatibility surfaces',
  scenarios: ['Compatibility migration state is observable']
};
const evidenceFinished = Math.max(
  Date.parse(baseline.started_at),
  ...commands.map(command => Date.parse(command.finished_at)));
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

const typedByCandidate = new Map();
for (const surfaceBinding of report.surface_candidate_bindings) {
  for (const candidateBinding of surfaceBinding.candidate_bindings) {
    const values = typedByCandidate.get(candidateBinding.candidate_id) || [];
    values.push({surface: surfaceBinding, role: candidateBinding.role});
    typedByCandidate.set(candidateBinding.candidate_id, values);
  }
}
const allCandidates = [
  ...report.path_candidates,
  ...report.structural_candidates,
  ...report.ast_candidates
];
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
    commandFor(surfaceId).map(command => command.id)))].sort();
  return {
    candidate_id: candidate.candidate_id,
    source: candidate.source,
    disposition: 'mapped',
    surface_ids: surfaceIds,
    surface_bindings: surfaceIds.map(surfaceId => {
      const binding = report.surface_candidate_bindings.find(item => item.surface_id === surfaceId);
      const surface = plan.surfaces.get(surfaceId);
      return {
        surface_id: surfaceId,
        candidate_roles: [...new Set(bySurface.get(surfaceId))]
          .sort((a, b) => ['producer', 'consumer'].indexOf(a) -
            ['producer', 'consumer'].indexOf(b)),
        consumer_kind: surface.consumer_kind,
        consumer_paths: binding.consumer_paths
      };
    }),
    reason: `The reviewed ${mode} diff candidate maps to every planned surface it produces or consumes.`,
    producer_paths: producerPaths,
    implementation_consumer: null,
    evidence_paths: logicalPaths,
    evidence_command_ids: evidenceCommandIds,
    orphan_ids: []
  };
}).sort((a, b) => a.candidate_id.localeCompare(b.candidate_id));

const surfaceAssessments = plan.block.surfaces.map(surface => {
  const binding = report.surface_candidate_bindings.find(item => item.surface_id === surface.id);
  const surfaceCommands = commandFor(surface.id);
  const surfaceCommandIds = surfaceCommands.map(command => command.id);
  return {
    surface_id: surface.id,
    result: 'Pass',
    reason: `Independent exact probes close every required ${mode} compatibility pair.`,
    consumer_paths: binding.consumer_paths,
    old_consumer_paths: binding.old_consumer_paths,
    replacement_consumer_paths: binding.replacement_consumer_paths,
    kind_evidence: surface.verify_kinds.map(kind => ({
      kind,
      evidence_command_ids: commandFor(surface.id, kind).map(command => command.id)
    })),
    role_evidence: lib.requiredRoles(surface).map(role => ({
      role,
      evidence_command_ids: commandFor(surface.id, null, role).map(command => command.id)
    })),
    evidence_command_ids: surfaceCommandIds,
    blocking_untested_ids: [],
    orphan_ids: []
  };
});

const allowanceKinds = new Map();
for (const [kind, allowances] of Object.entries(economy.structural_allowances)) {
  for (const allowance of allowances) allowanceKinds.set(allowance.id, kind);
}
const structuralAssessments = [...allowanceKinds].map(([allowanceId, kind]) => {
  const candidates = footprint.structural_candidates.filter(
    candidate => candidate.allowance_kind === kind);
  return {
    allowance_id: allowanceId,
    candidate_ids: candidates.map(candidate => candidate.candidate_id).sort(),
    result: 'Pass',
    reason: `The approved ${kind} compatibility change is exercised by real consumers.`,
    evidence_paths: candidates.length
      ? [...new Set(candidates.flatMap(candidate =>
          [candidate.old_path, candidate.path].filter(Boolean)))].sort()
      : report.changed_production_paths,
    evidence_command_ids: commandIds
  };
});

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
        ['correctness', 'safety', 'regression_risk', 'reuse', 'complexity',
          'test_quality', 'repository_impact'])
    ],
    findings: []
  },
  implementation_economy: {
    footprint_status: footprint.status,
    drift_explanation: footprint.status === 'within_expected' ? null :
      'The reviewed change stays below every hard limit and is fully explained by the three approved compatibility surfaces.',
    classification_assessment: {
      result: 'Pass',
      reason: 'Every changed product path is classified and mapped to an approved compatibility surface.',
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets',
          applicability: 'applicable',
          result: 'Pass',
          reason: 'The existing library and executable pass the exact compatibility probe.',
          evidence_paths: report.changed_production_paths,
          evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        {
          surface: 'install',
          applicability: 'applicable',
          result: 'Pass',
          reason: 'Installed headers and archives are compiled, linked, and executed by real consumers.',
          evidence_paths: ['CMakeLists.txt', 'include/compat/api.hpp',
            'tests/current_external.cpp'],
          evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        {
          surface: 'package',
          applicability: 'applicable',
          result: 'Pass',
          reason: 'The installed CMake config and exported targets are consumed downstream.',
          evidence_paths: ['CMakeLists.txt', 'cmake/CompatConfig.cmake.in',
            'tests/cmake-consumer/CMakeLists.txt'],
          evidence_command_ids: commandIds,
          not_applicable_reason: null
        },
        {
          surface: 'ci',
          applicability: 'not_applicable',
          result: null,
          reason: 'This disposable real fixture has no CI configuration.',
          evidence_paths: [],
          evidence_command_ids: [],
          not_applicable_reason: 'No CI surface exists in the approved implementation base.'
        }
      ]
    },
    reuse_assessments: [],
    structural_assessments: structuralAssessments,
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: `criterion-${mode}-cpp-compatibility`,
    description: `All three real compatibility surfaces satisfy the approved ${mode} phase.`,
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
      reason: `The complete ${mode} product diff and every real consumer were independently reviewed.`,
      evidence_paths: report.changed_production_paths,
      evidence_command_ids: commandIds
    },
    candidate_assessments: candidateAssessments,
    surface_assessments: surfaceAssessments,
    orphan_surfaces: [],
    result: 'Pass'
  }
};
fs.writeFileSync(outputFile, JSON.stringify(evaluation, null, 2) + '\n');
NODE
    )
}

prepare_change() {
    local change=$1 mode=$2
    (
        cd "$repo"
        scripts/change_new.sh "$change" >/dev/null
    )
    write_probe "$mode"
    write_change_plan "$change" "$mode"
    (
        cd "$repo"
        scripts/integration_surface_check.sh "$change" --plan-check --json \
            >"$tmp/$mode-plan.json"
        scripts/openspec_cli.sh validate "$change" --type change --strict --json \
            >"$tmp/$mode-strict-plan.json"
        git add -A
        git commit -qm "approved $mode C++ compatibility baseline"
        scripts/snapshot_update.sh --freeze-planning-baseline >/dev/null
        scripts/snapshot_update.sh --freeze-implementation-base >/dev/null
    )
}

run_compatibility_change() {
    local change=$1 mode=$2
    local change_dir="$repo/openspec/changes/$change"
    local harness_dir="$change_dir/harness"
    local probe=tests/compatibility_probe.sh
    local roles
    if [[ "$mode" == deprecation ]]; then
        roles=(old_consumer replacement_consumer)
    else
        roles=(old_consumer replacement_consumer absence_probe)
    fi
    local behavior_args=() build_args=() role
    for role in "${roles[@]}"; do
        behavior_args+=(
            --surface-role "surface-internal-compatibility=$role"
            --surface-role "surface-external-compatibility=$role"
            --surface-role "surface-install-compatibility=$role"
        )
        build_args+=(--surface-role "surface-install-compatibility=$role")
    done
    local changed_paths=(
        CMakeLists.txt
        cmake/CompatConfig.cmake.in
        include/compat/api.hpp
        src/app.cpp
        src/external.cpp
        src/internal.cpp
        src/internal.hpp
        "$probe"
    )
    local path_args=() changed
    for changed in "${changed_paths[@]}"; do
        path_args+=(--path "$changed")
    done

    note "$mode：用真实旧基线记录可执行 behavior RED"
    run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
    assert_status 0
    run_managed_at "$repo" scripts/task_verify.sh 1 \
        --phase red --cycle "cpp-$mode" --kind behavior --expect-exit 1 \
        --path "$probe" --test-path "$probe" --failure-class behavior \
        --expected-failure "the baseline does not yet satisfy the approved $mode compatibility state" \
        --match-output "$mode-probe-red" \
        --observed "the real baseline exposed the planned $mode compatibility gap" -- \
        "$probe" "$mode"
    assert_status 0

    note "$mode：最小修改 internal/external/install 三类 production surface"
    write_implementation "$mode"
    run_managed_at "$repo" scripts/change_footprint.sh "$change" --json
    assert_status 0
    run_managed_at "$repo" scripts/task_verify.sh 1 \
        --phase green --cycle "cpp-$mode" --kind behavior \
        "${path_args[@]}" -- "$probe" "$mode"
    assert_status 0

    run_managed_at "$repo" scripts/task_verify.sh 1 \
        --phase regression --cycle "cpp-$mode" --kind behavior \
        "${behavior_args[@]}" "${path_args[@]}" \
        --observed "real internal and installed SDK consumers closed every behavior role" -- \
        "$probe" "$mode"
    assert_status 0
    run_managed_at "$repo" scripts/task_verify.sh 1 \
        --phase regression --cycle "cpp-$mode" --kind build \
        "${build_args[@]}" "${path_args[@]}" \
        --observed "real installed CMake consumers closed every build role" -- \
        "$probe" "$mode"
    assert_status 0
    for role in "${roles[@]}"; do
        assert_contains "$RUN_OUTPUT" "$mode-install-${role//_/-}-ok"
    done
    run_managed_at "$repo" scripts/task_verify.sh --complete 1
    assert_status 0

    node - "$harness_dir/verification.json" "$mode" <<'NODE'
const fs = require('fs');
const [file, mode] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file));
const task = value.tasks.find(item => item.task_id === '1');
const regressions = task?.commands.filter(item => item.phase === 'REGRESSION') || [];
const expectedBindings = mode === 'deprecation' ? 8 : 12;
if (value.schema_version !== 3 || !task || task.commands.length !== 4 ||
    regressions.length !== 2 ||
    regressions.reduce((sum, command) => sum + command.surface_probe_bindings.length, 0) !==
      expectedBindings ||
    regressions.some(command =>
      command.argv.join('\0') !== `tests/compatibility_probe.sh\0${mode}`)) {
  throw new Error(`${mode} Generator exact compatibility bindings are incomplete`);
}
NODE

    note "$mode：刷新完整 diff inventory，并要求所有 producer candidate 映射"
    run_managed_at "$repo" scripts/integration_surface_check.sh "$change" --refresh --json
    assert_status 0
    node - "$harness_dir/integration-surface-report.json" "$mode" <<'NODE'
const fs = require('fs');
const [file, mode] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(file));
if (report.schema_version !== 1 || report.status !== 'complete' ||
    report.unmatched_candidates.length !== 0 ||
    report.surface_candidate_bindings.length !== 3 ||
    report.surface_candidate_bindings.some(binding =>
      !binding.candidate_bindings.some(candidate => candidate.role === 'producer'))) {
  throw new Error(`${mode} compatibility report is not closed`);
}
NODE

    note "$mode：独立 Evaluator 重跑真实 behavior 与 downstream build probes"
    run_managed_at "$repo" scripts/evaluator_check.sh --begin "$change"
    assert_status 0
    run_managed_at "$repo" scripts/evaluator_check.sh --run \
        --kind behavior "${behavior_args[@]}" \
        --expected "Every real internal and external compatibility role has the approved result." \
        --observed "The exact clean-build probe observed all internal and external role markers." -- \
        "$probe" "$mode"
    assert_status 0
    run_managed_at "$repo" scripts/evaluator_check.sh --run \
        --kind build "${build_args[@]}" \
        --expected "Every installed CMake compatibility role configures, builds, links, and runs as approved." \
        --observed "The exact downstream probe observed all installed target role markers." -- \
        "$probe" "$mode"
    assert_status 0

    write_pass_evaluation "$change" "$mode"
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
        "$change" "$archived_as" "$mode" <<'NODE'
const fs = require('fs');
const [rootFile, evaluationFile, change, archivedAs, mode] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(rootFile));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile));
if (root.active_change !== null ||
    root.last_archived_change?.change_name !== change ||
    root.last_archived_change?.archived_as !== archivedAs ||
    evaluation.verdict !== 'Pass' ||
    evaluation.integration_completeness?.surface_assessments.length !== 3 ||
    evaluation.integration_completeness?.surface_assessments.some(
      assessment => assessment.result !== 'Pass')) {
  throw new Error(`${mode} archived compatibility evidence is incomplete`);
}
NODE
}

note '生成真实 Harness，并验证 old-only C++/CMake 基线'
run_setup "$repo"
assert_status 0
git -C "$repo" config user.name 'AutoAI Real C++ Compatibility Test'
git -C "$repo" config user.email 'autoai-real-cpp-compatibility@example.invalid'
cmake -S "$repo" -B "$repo/build/initial" >/dev/null
cmake --build "$repo/build/initial" --parallel 2 >/dev/null
test "$("$repo/build/initial/compat_app" --legacy-internal)" = internal:42

deprecation_change=deprecate-cpp-compat-surfaces
prepare_change "$deprecation_change" deprecation
run_compatibility_change "$deprecation_change" deprecation
assert_path_exists "$repo/openspec/specs/cpp-compatibility/spec.md"

note '提交已归档 deprecation 结果，形成 removal 的独立实现基线'
git -C "$repo" add -A
git -C "$repo" commit -qm 'archived C++ compatibility deprecation baseline'

removal_change=remove-cpp-compat-surfaces
prepare_change "$removal_change" removal
run_compatibility_change "$removal_change" removal

node - "$repo/openspec/specs/cpp-compatibility/spec.md" <<'NODE'
const fs = require('fs');
const text = fs.readFileSync(process.argv[2], 'utf8');
if (!text.includes('reject or omit the legacy internal API') ||
    !text.includes('installed C++ API') ||
    !text.includes('exported CMake target') ||
    !text.includes('keep successful replacement consumers')) {
  throw new Error('archived main spec does not retain the complete removal contract');
}
NODE

note '真实 internal/external/CMake deprecation → removal、exact probes、Evaluation 与双 archive 生命周期通过'
