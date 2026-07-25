#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT

for command_name in git node; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "真实离线工程形态 fixture 缺少依赖：$command_name"
done
missing_build_tools=()
for command_name in cmake ctest c++; do
    command -v "$command_name" >/dev/null 2>&1 || \
        missing_build_tools+=("$command_name")
done
if (( ${#missing_build_tools[@]} > 0 )); then
    note "SKIP: 真实离线工程形态 fixture 缺少项目工具：${missing_build_tools[*]}"
    exit 77
fi

real_node=$(command -v node)
export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

run_generated() {
    local directory=$1
    shift
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(
        cd "$directory" || exit 97
        "$@" 2>&1
    )
    RUN_STATUS=$?
    set -e
}

assert_command_pass() {
    local directory=$1
    local command_id=$2
    local capability=$3
    run_generated "$directory" scripts/project_command.sh "$command_id" --json
    assert_status 0
    "$real_node" - "$RUN_OUTPUT" "$command_id" "$capability" <<'NODE' || \
        fail "Project Command envelope 不符合预期：$command_id"
const [raw, commandId, capability] = process.argv.slice(2);
const result = JSON.parse(raw);
if (result.schema_version !== 1 ||
    result.status !== 'Pass' ||
    result.exit_code !== 0 ||
    result.signal !== null ||
    result.identity?.command_id !== commandId ||
    result.identity?.capability !== capability) {
  process.exit(1);
}
NODE
}

repo="$tmp/real shapes project"
profile="$tmp/real-shapes-profile.json"
init_git_repo "$repo"
mkdir -p \
    "$repo/include/shape" \
    "$repo/src" \
    "$repo/tools" \
    "$repo/cmake" \
    "$repo/consumers/header-only" \
    "$repo/consumers/shared-sdk"

cat > "$repo/.gitignore" <<'EOF'
/.fixture-out/
EOF

cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_real_shapes LANGUAGES CXX)

include(CTest)

add_library(shape_headers INTERFACE)
target_compile_features(shape_headers INTERFACE cxx_std_17)
target_include_directories(shape_headers
  INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

add_library(shape_sdk SHARED src/sdk.cpp)
target_compile_features(shape_sdk PUBLIC cxx_std_17)
target_include_directories(shape_sdk
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

add_library(shape_plugin MODULE src/plugin.cpp)
target_compile_features(shape_plugin PRIVATE cxx_std_17)
set_target_properties(shape_plugin PROPERTIES PREFIX "")

add_executable(shape_plugin_host tools/plugin_host.cpp)
target_compile_features(shape_plugin_host PRIVATE cxx_std_17)
target_link_libraries(shape_plugin_host PRIVATE ${CMAKE_DL_LIBS})

add_test(
  NAME shape_plugin_dispatch
  COMMAND shape_plugin_host $<TARGET_FILE:shape_plugin>)
add_test(
  NAME shape_plugin_missing
  COMMAND shape_plugin_host
          ${CMAKE_CURRENT_BINARY_DIR}/missing-shape-plugin.so)
set_tests_properties(shape_plugin_missing PROPERTIES
  WILL_FAIL TRUE)

install(
  TARGETS shape_headers shape_sdk
  EXPORT ShapeTargets
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
install(
  TARGETS shape_plugin
  LIBRARY DESTINATION lib/shape)
install(
  FILES
    include/shape/header_only.hpp
    include/shape/sdk.hpp
  DESTINATION include/shape)
install(
  EXPORT ShapeTargets
  FILE ShapeTargets.cmake
  NAMESPACE Shape::
  DESTINATION lib/cmake/Shape)
install(
  FILES cmake/ShapeConfig.cmake
  DESTINATION lib/cmake/Shape)
EOF

cat > "$repo/include/shape/header_only.hpp" <<'EOF'
#pragma once

namespace shape {
constexpr int header_only_answer() noexcept {
    return 42;
}
}
EOF

cat > "$repo/include/shape/sdk.hpp" <<'EOF'
#pragma once

namespace shape {
int sdk_answer() noexcept;
}
EOF

cat > "$repo/src/sdk.cpp" <<'EOF'
#include "shape/sdk.hpp"

namespace shape {
int sdk_answer() noexcept {
    return 84;
}
}
EOF

cat > "$repo/src/plugin.cpp" <<'EOF'
extern "C" int shape_plugin_dispatch(const int value) {
    return value + 1;
}
EOF

cat > "$repo/tools/plugin_host.cpp" <<'EOF'
#include <dlfcn.h>

#include <iostream>

int main(const int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: shape_plugin_host <plugin>\n";
        return 64;
    }

    void* handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        std::cerr << "plugin-load-failed: " << dlerror() << '\n';
        return 3;
    }

    dlerror();
    void* raw_symbol = dlsym(handle, "shape_plugin_dispatch");
    const char* symbol_error = dlerror();
    if (symbol_error != nullptr) {
        std::cerr << "plugin-symbol-failed: " << symbol_error << '\n';
        dlclose(handle);
        return 4;
    }

    using Dispatch = int (*)(int);
    const auto dispatch = reinterpret_cast<Dispatch>(raw_symbol);
    const int actual = dispatch(41);
    dlclose(handle);
    if (actual != 42) {
        std::cerr << "plugin-result-failed: " << actual << '\n';
        return 5;
    }
    std::cout << "plugin-dispatch-ok:42\n";
    return 0;
}
EOF

cat > "$repo/cmake/ShapeConfig.cmake" <<'EOF'
include("${CMAKE_CURRENT_LIST_DIR}/ShapeTargets.cmake")
EOF

cat > "$repo/consumers/header-only/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(shape_header_consumer LANGUAGES CXX)
find_package(Shape CONFIG REQUIRED)
add_executable(shape_header_consumer main.cpp)
target_link_libraries(shape_header_consumer PRIVATE Shape::shape_headers)
EOF

cat > "$repo/consumers/header-only/main.cpp" <<'EOF'
#include <shape/header_only.hpp>

#include <iostream>

int main() {
    static_assert(shape::header_only_answer() == 42);
    std::cout << "header-only-consumer-ok\n";
    return 0;
}
EOF

cat > "$repo/consumers/shared-sdk/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(shape_sdk_consumer LANGUAGES CXX)
find_package(Shape CONFIG REQUIRED)
add_executable(shape_sdk_consumer main.cpp)
target_link_libraries(shape_sdk_consumer PRIVATE Shape::shape_sdk)
EOF

cat > "$repo/consumers/shared-sdk/main.cpp" <<'EOF'
#include <shape/sdk.hpp>

#include <iostream>

int main() {
    if (shape::sdk_answer() != 84) {
        return 1;
    }
    std::cout << "shared-sdk-consumer-ok\n";
    return 0;
}
EOF

cat > "$repo/tools/verify-installed-shapes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/.fixture-out"
prefix="$out/install"
header_build="$out/header-consumer-build"
sdk_build="$out/sdk-consumer-build"

rm -rf -- "$header_build" "$sdk_build"

cmake \
    -S "$root/consumers/header-only" \
    -B "$header_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$prefix" >/dev/null
cmake --build "$header_build" --parallel 2 >/dev/null
"$header_build/shape_header_consumer"

cmake \
    -S "$root/consumers/shared-sdk" \
    -B "$sdk_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$prefix" >/dev/null
cmake --build "$sdk_build" --parallel 2 >/dev/null
"$sdk_build/shape_sdk_consumer"

"$out/build/shape_plugin_host" \
    "$prefix/lib/shape/shape_plugin.so"

missing_plugin="$out/definitely-missing-plugin.so"
rm -f -- "$missing_plugin"
set +e
missing_output=$(
    "$out/build/shape_plugin_host" "$missing_plugin" 2>&1
)
missing_status=$?
set -e
if [[ "$missing_status" -ne 3 ||
      "$missing_output" != *plugin-load-failed:* ]]; then
    printf 'missing plugin negative path was not rejected correctly\n' >&2
    exit 1
fi
printf 'plugin-negative-ok\n'
printf 'all-shapes-ok\n'
EOF
chmod 755 "$repo/tools/verify-installed-shapes"

git -C "$repo" add .
git -C "$repo" \
    -c user.name=AutoAI-Test \
    -c user.email=autoai-test@example.invalid \
    commit -qm 'add real offline shape fixture'

"$real_node" - "$profile" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const command = (
  id,
  capability,
  argv,
  sideEffects = ['workspace-write'],
  requiredTools = []
) => ({
  id,
  module_ids: ['root'],
  capability,
  argv,
  cwd: '.',
  timeout_seconds: 120,
  inherit_env: ['PATH'],
  required_tools: requiredTools,
  output_roles: [capability + '-result'],
  side_effects: sideEffects
});
const profile = {
  schema_version: 1,
  modules: [{
    id: 'root',
    root: '.',
    adapter: 'cmake',
    cpp_standards: ['17'],
    compilers: ['system-c++'],
    target_platforms: ['linux'],
    path_roles: {
      production: ['include/**', 'src/**'],
      test: ['consumers/**'],
      example: [],
      generated: ['.fixture-out/**'],
      vendor: [],
      build_metadata: ['CMakeLists.txt', 'cmake/**', 'tools/**']
    },
    capabilities: {
      configure: ['shape-configure'],
      build: ['shape-build'],
      test: ['shape-test'],
      install: ['shape-install'],
      consumer: ['shape-consumers']
    },
    build_targets: [
      {id: 'target-shape-headers', kind: 'header-only-library', name: 'shape_headers', path: 'include/shape/header_only.hpp', source: 'profile'},
      {id: 'target-shape-sdk', kind: 'shared-library', name: 'shape_sdk', path: '.fixture-out/build/libshape_sdk.so', source: 'profile'},
      {id: 'target-shape-plugin', kind: 'module-plugin', name: 'shape_plugin', path: '.fixture-out/build/shape_plugin.so', source: 'profile'}
    ],
    build_graph_entries: [
      {id: 'shape-headers', kind: 'header-only-library', path: 'include/shape/header_only.hpp', source: 'profile', consumed_by: ['header-consumer']},
      {id: 'shape-sdk', kind: 'shared-library', path: 'src/sdk.cpp', source: 'profile', consumed_by: ['sdk-consumer']},
      {id: 'shape-plugin', kind: 'module-plugin', path: 'src/plugin.cpp', source: 'profile', consumed_by: ['plugin-host']},
      {id: 'header-consumer', kind: 'downstream-consumer', path: 'consumers/header-only/main.cpp', source: 'profile', depends_on: ['shape-headers']},
      {id: 'sdk-consumer', kind: 'downstream-consumer', path: 'consumers/shared-sdk/main.cpp', source: 'profile', depends_on: ['shape-sdk']},
      {id: 'plugin-host', kind: 'runtime-host', path: 'tools/plugin_host.cpp', source: 'profile', depends_on: ['shape-plugin']}
    ],
    distribution_surfaces: [
      {id: 'surface-shape-headers', kind: 'header-only-sdk', path: 'include/shape/header_only.hpp', build_entry_ids: ['shape-headers'], consumer_entry_ids: ['header-consumer']},
      {id: 'surface-shape-sdk', kind: 'shared-sdk', path: 'include/shape/sdk.hpp', build_entry_ids: ['shape-sdk'], consumer_entry_ids: ['sdk-consumer']},
      {id: 'surface-shape-plugin', kind: 'module-plugin', path: '.fixture-out/install/lib/shape/shape_plugin.so', build_entry_ids: ['shape-plugin'], consumer_entry_ids: ['plugin-host']}
    ]
  }],
  commands: [
    command('shape-configure', 'configure', [
      'cmake', '-S', '.', '-B', '.fixture-out/build',
      '-DCMAKE_BUILD_TYPE=Release',
      '-DCMAKE_INSTALL_PREFIX=.fixture-out/install'
    ]),
    command('shape-build', 'build', [
      'cmake', '--build', '.fixture-out/build', '--parallel', '2'
    ]),
    command('shape-test', 'test', [
      'ctest', '--test-dir', '.fixture-out/build', '--output-on-failure'
    ]),
    command('shape-install', 'install', [
      'cmake', '--install', '.fixture-out/build'
    ], ['workspace-write', 'install']),
    command('shape-consumers', 'consumer', [
      './tools/verify-installed-shapes'
    ], ['workspace-write'], ['cmake', 'dirname', 'rm']),
    command('system-cxx-identity', 'static-analysis', [
      'c++', '--version'
    ], [])
  ],
  toolchain_identity: [{
    id: 'system-cxx',
    module_ids: ['root'],
    command_id: 'system-cxx-identity'
  }]
};
fs.writeFileSync(file, JSON.stringify(profile, null, 2) + '\n');
NODE

note '使用 OpenSpec stub 初始化 CMake Profile，初始化过程不访问 registry'
run_setup "$repo" --project-profile "$profile"
assert_status 0
assert_path_absent "$repo/.vscode"
assert_path_absent "$repo/.clang-format"

export PATH=$REAL_TEST_PATH
"$real_node" - "$repo/.ai-harness/organization-policy.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const rule = {
  allow_command_ids: ['*'],
  deny_command_ids: [],
  allow_capabilities: ['*'],
  max_timeout_seconds: 180,
  inherit_env: ['PATH'],
  allow_side_effects: ['workspace-write', 'install'],
  output_limit_bytes: 65536
};
fs.writeFileSync(file, JSON.stringify({
  schema_version: 1,
  policy_id: 'real-shapes-policy',
  contexts: {local: rule, ci: rule, release: rule}
}, null, 2) + '\n');
NODE

note '受管 Project Commands 完成 configure、build、CTest 和安装'
assert_command_pass "$repo" shape-configure configure
assert_command_pass "$repo" shape-build build
assert_command_pass "$repo" shape-test test
assert_command_pass "$repo" shape-install install

assert_path_exists "$repo/.fixture-out/install/include/shape/header_only.hpp"
assert_path_exists "$repo/.fixture-out/install/include/shape/sdk.hpp"
assert_path_exists "$repo/.fixture-out/install/lib/libshape_sdk.so"
assert_path_exists "$repo/.fixture-out/install/lib/shape/shape_plugin.so"
assert_path_exists "$repo/.fixture-out/install/lib/cmake/Shape/ShapeConfig.cmake"

note '安装面驱动两个独立下游 consumer，并对 MODULE 插件做真实正负 dispatch'
assert_command_pass "$repo" shape-consumers consumer
assert_contains "$RUN_OUTPUT" 'header-only-consumer-ok'
assert_contains "$RUN_OUTPUT" 'shared-sdk-consumer-ok'
assert_contains "$RUN_OUTPUT" 'plugin-dispatch-ok:42'
assert_contains "$RUN_OUTPUT" 'plugin-negative-ok'
assert_contains "$RUN_OUTPUT" 'all-shapes-ok'

install_hits=$(find "$repo/.fixture-out/install" \
    \( -path '*/openspec/*' -o -path '*/.ai-harness/*' -o \
       -name PROJECT_ATTRIBUTION.md -o -name CLAUDE.md -o -name AGENTS.md \) \
    -print)
[[ -z "$install_hits" ]] || fail "安装面泄漏 Harness 治理制品：$install_hits"

run_generated "$repo" scripts/project_index.sh --refresh --json
assert_status 0
"$real_node" - "$repo/.ai-harness/derived/project-index.json" <<'NODE' || \
    fail 'Project Index 未保留三类 build target 和 distribution surface'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const root = result.modules?.find(module => module.id === 'root');
const targetKinds = new Set((root?.build_targets || []).map(item => item.kind));
const surfaceKinds = new Set((root?.distribution_surfaces || []).map(item => item.kind));
if (result.schema_version !== 1 ||
    root?.adapter !== 'cmake' ||
    !targetKinds.has('header-only-library') ||
    !targetKinds.has('shared-library') ||
    !targetKinds.has('module-plugin') ||
    !surfaceKinds.has('header-only-sdk') ||
    !surfaceKinds.has('shared-sdk') ||
    !surfaceKinds.has('module-plugin')) {
  process.exit(1);
}
NODE

[[ -s "$STUB_CALL_LOG" ]] || fail '初始化没有经过受控依赖替身'
assert_contains "$(<"$STUB_CALL_LOG")" 'npx'

note '纯 header-only、安装后 SHARED SDK、MODULE dispatch 与缺插件负例均通过'
