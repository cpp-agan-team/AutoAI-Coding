#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
real_node=$(command -v node)
missing_runner=autoai-fixture-target-runner-missing-7f3d91

for command_name in cmake git g++ make node; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "多模块/交叉边界 fixture 缺少依赖：$command_name"
done
command -v "$missing_runner" >/dev/null 2>&1 && \
    fail "确定性缺失的 target runner 意外存在：$missing_runner"

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

repo="$tmp/nested multimodule cross project"
profile="$tmp/multimodule-profile.json"
init_git_repo "$repo"
mkdir -p \
    "$repo/modules/cmake-lib/src" \
    "$repo/modules/make-firmware" \
    "$repo/tools"

cat > "$repo/.gitignore" <<'EOF'
/modules/cmake-lib/out/
/modules/make-firmware/out/
EOF

cat > "$repo/modules/cmake-lib/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(autoai_nested_cmake_module LANGUAGES CXX)

add_executable(cmake_module_app src/main.cpp)
target_compile_features(cmake_module_app PRIVATE cxx_std_17)
set_target_properties(cmake_module_app PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
EOF

cat > "$repo/modules/cmake-lib/src/main.cpp" <<'EOF'
int main() {
    return 0;
}
EOF

cat > "$repo/modules/make-firmware/Makefile" <<'EOF'
CXX ?= g++
CXXFLAGS := -m32 -ffreestanding -fno-exceptions -fno-rtti

.PHONY: all
all: out/firmware.o

out/firmware.o: firmware.cpp
	mkdir -p out
	$(CXX) $(CXXFLAGS) -c firmware.cpp -o $@
EOF

cat > "$repo/modules/make-firmware/firmware.cpp" <<'EOF'
extern "C" int firmware_entry() {
    return 42;
}
EOF

cat > "$repo/tools/build-cmake-module" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
[[ "$(pwd -P)" == "$root/modules/cmake-lib" ]]
cmake -S . -B out >/dev/null
cmake --build out --parallel 2 >/dev/null
./out/bin/cmake_module_app
printf 'cmake-module-build-ok\n'
EOF

cat > "$repo/tools/build-firmware-host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
[[ "$(pwd -P)" == "$root/modules/make-firmware" ]]
make all >/dev/null
printf 'firmware-host-build-ok\n'
EOF

cat > "$repo/tools/run-firmware-target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch out/target-runner-was-invoked
exec "$missing_runner" out/firmware.o
EOF

cat > "$repo/tools/toolchain-identity" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'g++-machine='
g++ -dumpmachine
printf 'g++-version='
g++ -dumpversion
printf 'cmake-version\n'
cmake --version
printf 'make-version\n'
make --version
EOF

chmod 755 \
    "$repo/tools/build-cmake-module" \
    "$repo/tools/build-firmware-host" \
    "$repo/tools/run-firmware-target" \
    "$repo/tools/toolchain-identity"

"$real_node" - "$profile" "$missing_runner" <<'NODE'
const fs = require('fs');
const [file, missingRunner] = process.argv.slice(2);
const emptyRoles = () => ({
  production: [],
  test: [],
  example: [],
  generated: [],
  vendor: [],
  build_metadata: []
});
const cmakeRoles = emptyRoles();
cmakeRoles.production = ['modules/cmake-lib/src/**'];
cmakeRoles.generated = ['modules/cmake-lib/out/**'];
cmakeRoles.build_metadata = ['modules/cmake-lib/CMakeLists.txt'];
const firmwareRoles = emptyRoles();
firmwareRoles.production = ['modules/make-firmware/firmware.cpp'];
firmwareRoles.generated = ['modules/make-firmware/out/**'];
firmwareRoles.build_metadata = ['modules/make-firmware/Makefile'];

const profile = {
  schema_version: 1,
  modules: [
    {
      id: 'cmake-lib',
      root: 'modules/cmake-lib',
      adapter: 'cmake',
      cpp_standards: ['c++17'],
      compilers: ['g++'],
      target_platforms: ['linux-host'],
      path_roles: cmakeRoles,
      capabilities: {
        build: ['cmake-module-build']
      },
      build_targets: [{
        id: 'cmake-module-app',
        kind: 'executable',
        name: 'cmake_module_app',
        path: 'modules/cmake-lib/out/bin/cmake_module_app',
        source: 'profile'
      }],
      build_graph_entries: [{
        id: 'cmake-module-entry',
        kind: 'executable',
        path: 'modules/cmake-lib/CMakeLists.txt',
        source: 'profile'
      }],
      distribution_surfaces: []
    },
    {
      id: 'make-firmware',
      root: 'modules/make-firmware',
      adapter: 'make',
      cpp_standards: ['freestanding-c++'],
      compilers: ['g++-m32'],
      target_platforms: ['fixture-elf32'],
      path_roles: firmwareRoles,
      capabilities: {
        build: ['firmware-host-build'],
        'target-run': ['firmware-target-run']
      },
      build_targets: [{
        id: 'firmware-object',
        kind: 'target-object',
        name: 'firmware.o',
        path: 'modules/make-firmware/out/firmware.o',
        source: 'profile'
      }],
      build_graph_entries: [{
        id: 'firmware-object-entry',
        kind: 'target-object',
        path: 'modules/make-firmware/Makefile',
        source: 'profile'
      }],
      distribution_surfaces: [{
        id: 'firmware-target-artifact',
        kind: 'target-artifact',
        path: 'modules/make-firmware/out/firmware.o',
        build_entry_ids: ['firmware-object-entry'],
        consumer_entry_ids: []
      }]
    }
  ],
  commands: [
    {
      id: 'cmake-module-build',
      module_ids: ['cmake-lib'],
      capability: 'build',
      argv: ['./tools/build-cmake-module'],
      cwd: 'modules/cmake-lib',
      timeout_seconds: 60,
      inherit_env: ['PATH'],
      output_roles: ['build-result'],
      side_effects: ['workspace-write'],
      required_tools: ['cmake', 'git']
    },
    {
      id: 'firmware-host-build',
      module_ids: ['make-firmware'],
      capability: 'build',
      argv: ['./tools/build-firmware-host'],
      cwd: 'modules/make-firmware',
      timeout_seconds: 60,
      inherit_env: ['PATH'],
      output_roles: ['target-artifact'],
      side_effects: ['workspace-write'],
      required_tools: ['g++', 'git', 'make']
    },
    {
      id: 'firmware-target-run',
      module_ids: ['make-firmware'],
      capability: 'target-run',
      argv: ['./tools/run-firmware-target'],
      cwd: 'modules/make-firmware',
      timeout_seconds: 30,
      inherit_env: ['PATH'],
      output_roles: ['target-result'],
      side_effects: [],
      required_tools: [missingRunner, 'touch']
    },
    {
      id: 'fixture-toolchain-identity',
      module_ids: ['cmake-lib', 'make-firmware'],
      capability: 'static-analysis',
      argv: ['./tools/toolchain-identity'],
      cwd: '.',
      timeout_seconds: 30,
      inherit_env: ['PATH'],
      output_roles: ['toolchain-identity'],
      side_effects: [],
      required_tools: ['cmake', 'g++', 'make']
    }
  ],
  toolchain_identity: [{
    id: 'fixture-host-toolchain',
    module_ids: ['cmake-lib', 'make-firmware'],
    command_id: 'fixture-toolchain-identity'
  }]
};
fs.writeFileSync(file, JSON.stringify(profile, null, 2) + '\n');
NODE

note '嵌套 CMake/Make 模块只形成候选，探测不自动选择或写工作区'
before=$(fingerprint_tree "$repo")
run_setup "$repo" --detect-project --json
assert_status 0
after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail '多模块只读探测修改了工作区'
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const result = JSON.parse(process.argv[2]);
const candidates = new Map(result.candidates.map(item => [
  `${item.adapter}:${item.module_root}`, item
]));
for (const key of [
  'cmake:modules/cmake-lib',
  'make:modules/make-firmware'
]) {
  const candidate = candidates.get(key);
  if (!candidate || candidate.requires_human_confirmation !== true) process.exit(1);
}
if (result.selected !== null || result.side_effects.length !== 0) process.exit(1);
NODE
assert_path_absent "$repo/.ai-harness"

note '人工 Profile 保留模块 cwd/capability 边界，且允许模块显式缺少 test/install'
run_setup "$repo" --project-profile "$profile"
assert_status 0
export PATH=$REAL_TEST_PATH

run_generated "$repo" scripts/project_profile.sh --check --json
assert_status 0
"$real_node" - "$repo/.ai-harness/project-profile.json" "$RUN_OUTPUT" <<'NODE'
const fs = require('fs');
const [profileFile, output] = process.argv.slice(2);
const profile = JSON.parse(fs.readFileSync(profileFile, 'utf8'));
const checked = JSON.parse(output);
if (JSON.stringify(checked.modules) !== JSON.stringify(['cmake-lib', 'make-firmware'])) {
  throw new Error('checked module set mismatch');
}
const byId = new Map(profile.modules.map(module => [module.id, module]));
for (const id of ['cmake-lib', 'make-firmware']) {
  const capabilities = byId.get(id)?.capabilities;
  if (!capabilities || Object.hasOwn(capabilities, 'test') ||
      Object.hasOwn(capabilities, 'install')) {
    throw new Error(`${id} unexpectedly declares test/install`);
  }
}
NODE

note '受管命令在各自模块 cwd 执行，并把 module/capability/cwd 写入 envelope'
run_generated "$repo" scripts/project_command.sh cmake-module-build --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const value = JSON.parse(process.argv[2]);
if (value.status !== 'Pass' || value.exit_code !== 0 ||
    value.identity?.capability !== 'build' ||
    value.identity?.canonical_cwd !== 'modules/cmake-lib' ||
    JSON.stringify(value.identity?.module_ids) !== JSON.stringify(['cmake-lib']) ||
    !value.stdout.includes('cmake-module-build-ok')) {
  throw new Error('CMake module command envelope mismatch');
}
NODE
assert_path_exists "$repo/modules/cmake-lib/out/bin/cmake_module_app"

run_generated "$repo" scripts/project_command.sh firmware-host-build --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const value = JSON.parse(process.argv[2]);
if (value.status !== 'Pass' || value.exit_code !== 0 ||
    value.identity?.capability !== 'build' ||
    value.identity?.canonical_cwd !== 'modules/make-firmware' ||
    JSON.stringify(value.identity?.module_ids) !== JSON.stringify(['make-firmware']) ||
    !value.stdout.includes('firmware-host-build-ok')) {
  throw new Error('firmware host-build envelope mismatch');
}
NODE

"$real_node" - "$repo/modules/make-firmware/out/firmware.o" <<'NODE'
const fs = require('fs');
const value = fs.readFileSync(process.argv[2]);
if (value.length < 20 || value[0] !== 0x7f || value[1] !== 0x45 ||
    value[2] !== 0x4c || value[3] !== 0x46 || value[4] !== 1) {
  throw new Error('g++ -m32 fixture did not produce an ELF32 object');
}
NODE

note '缺失 target runner 只使 target-run unavailable；build 保持 available'
run_generated "$repo" scripts/harness_doctor.sh --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" "$missing_runner" <<'NODE'
const [raw, missingRunner] = process.argv.slice(2);
const value = JSON.parse(raw);
const required = value.checks.find(item =>
  item.id === 'profile.command.firmware-target-run.required-tools');
const moduleCapabilities = new Map((value.summary?.module_capabilities || []).map(item => [
  `${item.module_id}:${item.capability}`, item
]));
const cmakeBuild = moduleCapabilities.get('cmake-lib:build');
const firmwareBuild = moduleCapabilities.get('make-firmware:build');
const firmwareTargetRun = moduleCapabilities.get('make-firmware:target-run');
if (value.summary?.status !== 'degraded' ||
    !value.summary.available_capabilities?.includes('build') ||
    !value.summary.unavailable_capabilities?.includes('target-run') ||
    value.summary.partially_available_capabilities?.length !== 0 ||
    value.summary.available_capabilities?.includes('test') ||
    value.summary.unavailable_capabilities?.includes('test') ||
    value.summary.available_capabilities?.includes('install') ||
    value.summary.unavailable_capabilities?.includes('install') ||
    cmakeBuild?.status !== 'available' ||
    firmwareBuild?.status !== 'available' ||
    firmwareTargetRun?.status !== 'unavailable' ||
    JSON.stringify(firmwareTargetRun?.available_command_ids) !== '[]' ||
    JSON.stringify(firmwareTargetRun?.unavailable_command_ids) !==
      JSON.stringify(['firmware-target-run']) ||
    required?.status !== 'fail' || required?.severity !== 'warning' ||
    !required.message.includes(missingRunner) ||
    JSON.stringify(required.affected_capabilities) !== JSON.stringify(['target-run'])) {
  throw new Error('Doctor capability availability summary mismatch');
}
NODE

run_generated "$repo" scripts/harness_doctor.sh --strict --json
assert_status 6
assert_contains "$RUN_OUTPUT" "$missing_runner executable was not found on PATH"

assert_path_absent "$repo/modules/make-firmware/out/target-runner-was-invoked"
run_generated "$repo" scripts/project_command.sh firmware-target-run --json
assert_status 4
assert_contains "$RUN_OUTPUT" "required project tool is unavailable on the effective PATH: $missing_runner"
assert_path_absent "$repo/modules/make-firmware/out/target-runner-was-invoked"

note '同一 capability 跨模块部分可用时不得误报为全局 available'
"$real_node" - "$repo/.ai-harness/project-profile.json" "$missing_runner" <<'NODE'
const fs = require('fs');
const [file, missingRunner] = process.argv.slice(2);
const profile = JSON.parse(fs.readFileSync(file, 'utf8'));
const command = profile.commands.find(item => item.id === 'firmware-host-build');
command.required_tools.push(missingRunner);
fs.writeFileSync(file, JSON.stringify(profile, null, 2) + '\n');
NODE
run_generated "$repo" scripts/harness_doctor.sh --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const value = JSON.parse(process.argv[2]);
const moduleCapabilities = new Map((value.summary?.module_capabilities || []).map(item => [
  `${item.module_id}:${item.capability}`, item
]));
if (!value.summary?.partially_available_capabilities?.includes('build') ||
    value.summary.available_capabilities?.includes('build') ||
    value.summary.unavailable_capabilities?.includes('build') ||
    moduleCapabilities.get('cmake-lib:build')?.status !== 'available' ||
    moduleCapabilities.get('make-firmware:build')?.status !== 'unavailable') {
  throw new Error('Doctor falsely reported a partially available cross-module capability');
}
NODE

note '多模块 cwd、ELF32 host-build、target-run Blocked 和缺能力边界通过'
