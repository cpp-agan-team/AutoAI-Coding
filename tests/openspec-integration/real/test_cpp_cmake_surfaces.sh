#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT

for command_name in cmake ctest c++; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "C++/CMake 真实 fixture 缺少依赖：$command_name"
done

write_micro_project() {
    local repo=$1
    mkdir -p "$repo/include/micro" "$repo/src" "$repo/tests"
    cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_micro_fixture LANGUAGES CXX)

include(CTest)
option(AUTOAI_TEST_BROAD_INSTALL "Deliberately unsafe install(DIRECTORY .) fixture" OFF)

if(AUTOAI_TEST_BROAD_INSTALL)
  # This branch is intentionally unsafe. The test proves that governance-leak
  # detection catches it; production projects must enumerate install inputs.
  install(DIRECTORY . DESTINATION share/leaky-source)
else()
  add_library(micro_component STATIC src/micro_component.cpp)
  target_compile_features(micro_component PUBLIC cxx_std_17)
  target_include_directories(micro_component
    PUBLIC
      $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
      $<INSTALL_INTERFACE:include>)

  add_executable(micro_component_test tests/micro_component_test.cpp)
  target_link_libraries(micro_component_test PRIVATE micro_component)
  add_test(NAME micro_component_test COMMAND micro_component_test)

  get_target_property(MICRO_TARGET_SOURCES micro_component SOURCES)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/micro-target-sources.txt" "${MICRO_TARGET_SOURCES}\n")

  install(TARGETS micro_component ARCHIVE DESTINATION lib)
  install(FILES include/micro/component.hpp DESTINATION include/micro)
endif()
EOF

    cat > "$repo/include/micro/component.hpp" <<'EOF'
#pragma once

namespace micro {
int doubled(int value);
}
EOF

    cat > "$repo/src/micro_component.cpp" <<'EOF'
#include "micro/component.hpp"

namespace micro {
int doubled(const int value) {
    return value * 2;
}
}
EOF

    cat > "$repo/tests/micro_component_test.cpp" <<'EOF'
#include "micro/component.hpp"

int main() {
    return micro::doubled(21) == 42 ? 0 : 1;
}
EOF
}

write_multi_change_project() {
    local repo=$1
    mkdir -p "$repo/include/greeting" "$repo/src" "$repo/tests"
    cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(autoai_multi_change_fixture LANGUAGES CXX)

include(CTest)

add_library(greeting_api STATIC src/greeting.cpp)
target_compile_features(greeting_api PUBLIC cxx_std_17)
target_include_directories(greeting_api
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

add_executable(greeting_api_test tests/greeting_test.cpp)
target_link_libraries(greeting_api_test PRIVATE greeting_api)
add_test(NAME greeting_api_test COMMAND greeting_api_test)

get_target_property(GREETING_TARGET_SOURCES greeting_api SOURCES)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/greeting-target-sources.txt" "${GREETING_TARGET_SOURCES}\n")

install(TARGETS greeting_api ARCHIVE DESTINATION lib)
install(FILES include/greeting/api.hpp DESTINATION include/greeting)
EOF

    cat > "$repo/include/greeting/api.hpp" <<'EOF'
#pragma once

#include <string>
#include <string_view>

namespace greeting {

struct RenderRequest {
    std::string_view name;
    std::string_view punctuation;
};

std::string_view prefix() noexcept;
std::string render(RenderRequest request);

}
EOF

    cat > "$repo/src/greeting.cpp" <<'EOF'
#include "greeting/api.hpp"

namespace greeting {

std::string_view prefix() noexcept {
    return "Hello";
}

std::string render(const RenderRequest request) {
    return std::string(prefix()) + ", " + std::string(request.name) +
           std::string(request.punctuation);
}

}
EOF

    cat > "$repo/tests/greeting_test.cpp" <<'EOF'
#include "greeting/api.hpp"

int main() {
    if (greeting::prefix() != "Hello") {
        return 1;
    }
    return greeting::render({"Ada", "!"}) == "Hello, Ada!" ? 0 : 2;
}
EOF
}

assert_strict_change_valid() {
    local repo=$1
    local change=$2
    local output=$3
    (
        cd "$repo"
        scripts/openspec_cli.sh validate "$change" --type change --strict --json > "$output"
    )
    node - "$output" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
if (data.summary?.totals?.failed !== 0 || data.items.length !== 1 ||
    data.items[0].id !== change || data.items[0].valid !== true) {
  throw new Error(`strict validation failed for ${change}`);
}
NODE
}

note 'micro fixture：真实 configure/build/test/install，显式 target 与 install 面排除治理制品'
micro_repo="$tmp/micro component"
init_git_repo "$micro_repo"
write_micro_project "$micro_repo"
run_setup "$micro_repo"
assert_status 0
(
    cd "$micro_repo"
    scripts/change_new.sh micro-component >/dev/null
    printf 'micro-evidence-only\n' > \
        openspec/changes/micro-component/harness/cmake-surface-sentinel.txt
)

micro_build="$tmp/micro-build"
micro_install="$tmp/micro-install"
run_cmake_pipeline "$micro_repo" "$micro_build" "$micro_install"

micro_sources=$(<"$micro_build/micro-target-sources.txt")
[[ "$micro_sources" == 'src/micro_component.cpp' ]] || \
    fail "micro target source 闭包异常：$micro_sources"
assert_not_contains "$micro_sources" 'openspec'
assert_not_contains "$micro_sources" 'harness'
assert_not_contains "$micro_sources" 'PROJECT_ATTRIBUTION.md'
assert_not_contains "$micro_sources" 'CLAUDE.md'

mapfile -t micro_installed < <(
    cd "$micro_install"
    find . -type f -printf '%P\n' | LC_ALL=C sort
)
[[ ${#micro_installed[@]} -eq 2 ]] || \
    fail "micro 显式安装文件数不是 2：${micro_installed[*]}"
[[ "${micro_installed[0]}" == include/micro/component.hpp ]] || \
    fail "micro 安装头文件缺失：${micro_installed[*]}"
[[ "${micro_installed[1]}" == lib/libmicro_component.a ]] || \
    fail "micro 安装静态库缺失：${micro_installed[*]}"
assert_no_governance_install_leak "$micro_install"

note '同一 micro 源树的宽泛 install(DIRECTORY .) 被治理泄漏扫描明确检出'
leaky_build="$tmp/leaky-build"
leaky_install="$tmp/leaky-install"
cmake -S "$micro_repo" -B "$leaky_build" \
    -DAUTOAI_TEST_BROAD_INSTALL=ON -DCMAKE_INSTALL_PREFIX="$leaky_install" >/dev/null
cmake --install "$leaky_build" >/dev/null

assert_path_exists "$leaky_install/share/leaky-source/CLAUDE.md"
assert_path_exists "$leaky_install/share/leaky-source/PROJECT_ATTRIBUTION.md"
assert_path_exists "$leaky_install/share/leaky-source/openspec/config.yaml"
assert_path_exists \
    "$leaky_install/share/leaky-source/openspec/changes/micro-component/harness/cmake-surface-sentinel.txt"
leak_hits=$(find "$leaky_install" \
    \( -path '*/openspec/*' -o -path '*/.ai-harness/*' -o \
       -path '*/changes/*/harness/*' -o -name PROJECT_ATTRIBUTION.md -o -name CLAUDE.md -o -name AGENTS.md \) -print)
assert_contains "$leak_hits" 'openspec/config.yaml'
assert_contains "$leak_hits" 'PROJECT_ATTRIBUTION.md'
assert_contains "$leak_hits" 'harness/cmake-surface-sentinel.txt'

note 'multi-change fixture：兼容新增与 BREAKING API 变更并存，evidence 按 change 隔离'
multi_repo="$tmp/multi change project"
init_git_repo "$multi_repo"
write_multi_change_project "$multi_repo"
run_setup "$multi_repo"
assert_status 0

mkdir -p "$multi_repo/openspec/specs/greeting-api"
cat > "$multi_repo/openspec/specs/greeting-api/spec.md" <<'EOF'
# Greeting API Specification

## Requirements

### Requirement: Render greeting by name
The library SHALL render a greeting from a string name argument.

#### Scenario: Render a named greeting
- **WHEN** a caller supplies the name `Ada`
- **THEN** the library returns `Hello, Ada`
EOF

(
    cd "$multi_repo"
    scripts/change_new.sh add-compatible-prefix >/dev/null
)
compatible_dir="$multi_repo/openspec/changes/add-compatible-prefix"
mkdir -p "$compatible_dir/specs/greeting-api"
cat > "$compatible_dir/proposal.md" <<'EOF'
## Why

Consumers need a stable greeting prefix for compatible UI composition.

## What Changes

- Add a read-only prefix query without removing or changing an existing API.
- External contract impact: **compatible**.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `greeting-api`: Add a compatible prefix query.

## Impact

The existing greeting library gains one additive public function.
EOF
cat > "$compatible_dir/design.md" <<'EOF'
## Context

The final fixture implements an additive prefix query.

## Goals / Non-Goals

**Goals:** Preserve existing behavior while exposing the prefix.

**Non-Goals:** Remove or rename an existing API.

## Decisions

Return a non-owning immutable string view backed by static storage.

## Risks / Trade-offs

The returned view must continue to reference static-lifetime storage.
EOF
cat > "$compatible_dir/specs/greeting-api/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Expose stable greeting prefix
The library SHALL expose the stable greeting prefix without changing render behavior.

#### Scenario: Read the prefix
- **WHEN** a caller queries the greeting prefix
- **THEN** the library returns `Hello`
EOF
cat > "$compatible_dir/tasks.md" <<'EOF'
## 1. Compatible API addition

- [x] 1.1 Add and test the prefix query
  - Covers: `specs/greeting-api/spec.md` | `ADDED` | `Expose stable greeting prefix` | `Read the prefix`
  - Verify: `build`, `behavior`
EOF
printf 'compatible-change-evidence\n' > \
    "$compatible_dir/harness/cmake-surface-sentinel.txt"
assert_strict_change_valid "$multi_repo" add-compatible-prefix \
    "$tmp/compatible-validation.json"

(
    cd "$multi_repo"
    scripts/change_new.sh replace-render-signature --switch >/dev/null
)
breaking_dir="$multi_repo/openspec/changes/replace-render-signature"
mkdir -p "$breaking_dir/specs/greeting-api"
cat > "$breaking_dir/proposal.md" <<'EOF'
## Why

Rendering now requires explicit punctuation and cannot be expressed by the old name-only call.

## What Changes

- **BREAKING**: Replace the name-only render signature with `RenderRequest`.
- Require consumers to provide both name and punctuation fields.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `greeting-api`: Change the render request contract.

## Impact

All source consumers of the old render signature must migrate before linking the new API.
EOF
cat > "$breaking_dir/design.md" <<'EOF'
## Context

The final fixture models an intentionally breaking public C++ API transition.

## Goals / Non-Goals

**Goals:** Make punctuation explicit in a typed request.

**Non-Goals:** Retain an overload for the old name-only signature.

## Decisions

Use one request structure so future compatible fields can be added deliberately.

## Risks / Trade-offs

Existing consumers fail to compile until migrated to `RenderRequest`.
EOF
cat > "$breaking_dir/specs/greeting-api/spec.md" <<'EOF'
## MODIFIED Requirements

### Requirement: Render greeting by name
The library SHALL render a greeting from a `RenderRequest` containing name and punctuation.

#### Scenario: Render a typed greeting request
- **WHEN** a caller supplies name `Ada` and punctuation `!`
- **THEN** the library returns `Hello, Ada!`
EOF
cat > "$breaking_dir/tasks.md" <<'EOF'
## 1. Breaking API transition

- [x] 1.1 Replace the render signature and migrate the fixture consumer
  - Covers: `specs/greeting-api/spec.md` | `MODIFIED` | `Render greeting by name` | `Render a typed greeting request`
  - Verify: `build`, `behavior`
EOF
printf 'breaking-change-evidence\n' > \
    "$breaking_dir/harness/cmake-surface-sentinel.txt"
assert_strict_change_valid "$multi_repo" replace-render-signature \
    "$tmp/breaking-validation.json"

assert_file_contains "$compatible_dir/proposal.md" 'compatible'
assert_file_contains "$breaking_dir/proposal.md" '**BREAKING**'
assert_file_contains "$compatible_dir/harness/cmake-surface-sentinel.txt" \
    'compatible-change-evidence'
assert_file_contains "$breaking_dir/harness/cmake-surface-sentinel.txt" \
    'breaking-change-evidence'
node - "$multi_repo/ai_snapshot.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (data.active_change !== 'replace-render-signature') {
  throw new Error(`unexpected active change: ${data.active_change}`);
}
NODE

multi_build="$tmp/multi-build"
multi_install="$tmp/multi-install"
run_cmake_pipeline "$multi_repo" "$multi_build" "$multi_install"

multi_sources=$(<"$multi_build/greeting-target-sources.txt")
[[ "$multi_sources" == 'src/greeting.cpp' ]] || \
    fail "multi target source 闭包异常：$multi_sources"
assert_not_contains "$multi_sources" 'openspec'
assert_not_contains "$multi_sources" 'harness'

mapfile -t multi_installed < <(
    cd "$multi_install"
    find . -type f -printf '%P\n' | LC_ALL=C sort
)
[[ ${#multi_installed[@]} -eq 2 ]] || \
    fail "multi 显式安装文件数不是 2：${multi_installed[*]}"
[[ "${multi_installed[0]}" == include/greeting/api.hpp ]] || \
    fail "multi 安装头文件缺失：${multi_installed[*]}"
[[ "${multi_installed[1]}" == lib/libgreeting_api.a ]] || \
    fail "multi 安装静态库缺失：${multi_installed[*]}"
assert_no_governance_install_leak "$multi_install"

cat > "$tmp/installed-consumer.cpp" <<'EOF'
#include "greeting/api.hpp"

int main() {
    return greeting::prefix() == "Hello" &&
                   greeting::render({"Ada", "!"}) == "Hello, Ada!"
               ? 0
               : 1;
}
EOF
c++ -std=c++17 "$tmp/installed-consumer.cpp" \
    -I"$multi_install/include" "$multi_install/lib/libgreeting_api.a" \
    -o "$tmp/installed-consumer"
"$tmp/installed-consumer"
