#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT

missing_tools=()
for command_name in bash c++ dirname git ldd make mkdir node qmake; do
    command -v "$command_name" >/dev/null 2>&1 || missing_tools+=("$command_name")
done
if (( ${#missing_tools[@]} > 0 )); then
    note "SKIP: qmake 离线 fixture 缺少项目工具：${missing_tools[*]}"
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
    result.identity?.capability !== capability ||
    result.identity?.canonical_cwd !== '.') {
  process.exit(1);
}
NODE
}

repo="$tmp/qmake native project"
profile="$tmp/qmake-profile.json"
init_git_repo "$repo"
mkdir -p "$repo/src" "$repo/tools"

cat > "$repo/.gitignore" <<'EOF'
/.fixture-out/
EOF

cat > "$repo/autoai-qmake.pro" <<'EOF'
TEMPLATE = app
TARGET = autoai_qmake_cli

CONFIG += console c++17
CONFIG -= app_bundle qt
QT -= core gui widgets

QMAKE_CXX = c++
QMAKE_LINK = c++
QMAKE_LINK_C = c++
QMAKE_LINK_SHLIB = c++

DESTDIR = bin
OBJECTS_DIR = obj
MOC_DIR = moc
RCC_DIR = rcc
UI_DIR = ui

SOURCES += src/main.cpp
EOF

cat > "$repo/src/main.cpp" <<'EOF'
#include <iostream>
#include <string_view>

int main(const int argc, char** argv) {
    if (argc != 3 ||
        std::string_view(argv[1]) != "--answer" ||
        std::string_view(argv[2]) != "42") {
        std::cerr << "usage: autoai_qmake_cli --answer 42\n";
        return 64;
    }
    std::cout << "qmake-cli-ok:42\n";
    return 0;
}
EOF

cat > "$repo/tools/qmake-configure" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/.fixture-out/qmake-build"

mkdir -p "$out"
cd "$out"
qmake "$root/autoai-qmake.pro"
EOF

cat > "$repo/tools/run-qmake-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
binary="$root/.fixture-out/qmake-build/bin/autoai_qmake_cli"

runtime_dependencies=$(ldd "$binary" 2>&1)
if [[ "$runtime_dependencies" == *libQt* ]]; then
    printf 'plain C++ qmake fixture unexpectedly links a Qt runtime\n' >&2
    printf '%s\n' "$runtime_dependencies" >&2
    exit 1
fi

output=$("$binary" --answer 42)
[[ "$output" == "qmake-cli-ok:42" ]]
printf '%s\n' "$output"
printf 'qmake-no-qt-runtime-ok\n'
EOF

cat > "$repo/tools/qmake-toolchain-identity" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

qmake -v
c++ --version
EOF

chmod 755 \
    "$repo/tools/qmake-configure" \
    "$repo/tools/qmake-toolchain-identity" \
    "$repo/tools/run-qmake-cli"

git -C "$repo" add .
git -C "$repo" \
    -c user.name=AutoAI-Test \
    -c user.email=autoai-test@example.invalid \
    commit -qm 'add native qmake fixture'

"$real_node" - "$profile" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const command = (
  id,
  capability,
  argv,
  requiredTools,
  sideEffects = ['workspace-write']
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
    adapter: 'qmake',
    cpp_standards: ['c++17'],
    compilers: ['system-c++'],
    target_platforms: ['linux-host'],
    path_roles: {
      production: ['src/**'],
      test: ['tools/run-qmake-cli'],
      example: [],
      generated: ['.fixture-out/**'],
      vendor: [],
      build_metadata: [
        'autoai-qmake.pro',
        'tools/qmake-configure',
        'tools/qmake-toolchain-identity'
      ]
    },
    capabilities: {
      configure: ['qmake-configure'],
      build: ['qmake-build'],
      test: ['qmake-cli-run']
    },
    build_targets: [{
      id: 'qmake-cli-target',
      kind: 'executable',
      name: 'autoai_qmake_cli',
      path: '.fixture-out/qmake-build/bin/autoai_qmake_cli',
      source: 'profile'
    }],
    build_graph_entries: [
      {
        id: 'qmake-project-entry',
        kind: 'qmake-application',
        path: 'autoai-qmake.pro',
        source: 'profile',
        tested_by: ['qmake-runtime-entry']
      },
      {
        id: 'qmake-runtime-entry',
        kind: 'runtime-probe',
        path: 'tools/run-qmake-cli',
        source: 'profile',
        depends_on: ['qmake-project-entry']
      }
    ],
    distribution_surfaces: [{
      id: 'qmake-cli-surface',
      kind: 'cli-executable',
      path: '.fixture-out/qmake-build/bin/autoai_qmake_cli',
      build_entry_ids: ['qmake-project-entry'],
      consumer_entry_ids: ['qmake-runtime-entry']
    }]
  }],
  commands: [
    command(
      'qmake-configure',
      'configure',
      ['./tools/qmake-configure'],
      ['bash', 'dirname', 'mkdir', 'qmake']
    ),
    command(
      'qmake-build',
      'build',
      ['make', '-C', '.fixture-out/qmake-build', '--jobs=2', 'all'],
      ['c++', 'make']
    ),
    command(
      'qmake-cli-run',
      'test',
      ['./tools/run-qmake-cli'],
      ['bash', 'dirname', 'ldd'],
      []
    ),
    command(
      'qmake-toolchain-identity',
      'static-analysis',
      ['./tools/qmake-toolchain-identity'],
      ['bash', 'c++', 'qmake'],
      []
    )
  ],
  toolchain_identity: [{
    id: 'qmake-system-cxx',
    module_ids: ['root'],
    command_id: 'qmake-toolchain-identity'
  }]
};
fs.writeFileSync(file, JSON.stringify(profile, null, 2) + '\n');
NODE

note '使用离线 OpenSpec stub 和人工审查 qmake Profile 初始化 Harness'
run_setup "$repo" --project-profile "$profile"
assert_status 0

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
  allow_side_effects: ['workspace-write'],
  output_limit_bytes: 65536
};
fs.writeFileSync(file, JSON.stringify({
  schema_version: 1,
  policy_id: 'qmake-fixture-policy',
  contexts: {local: rule, ci: rule, release: rule}
}, null, 2) + '\n');
NODE

run_generated "$repo" scripts/project_profile.sh --check --json
assert_status 0
assert_file_contains "$repo/.ai-harness/project-profile.json" '"adapter": "qmake"'

note '受管 qmake configure 和 Make build 生成真实 CLI'
assert_command_pass "$repo" qmake-configure configure
assert_path_exists "$repo/.fixture-out/qmake-build/Makefile"

assert_command_pass "$repo" qmake-build build
assert_path_exists "$repo/.fixture-out/qmake-build/bin/autoai_qmake_cli"

note '运行真实 CLI，并证明 qmake 产物不链接任何 Qt runtime'
assert_command_pass "$repo" qmake-cli-run test
assert_contains "$RUN_OUTPUT" 'qmake-cli-ok:42'
assert_contains "$RUN_OUTPUT" 'qmake-no-qt-runtime-ok'

[[ -s "$STUB_CALL_LOG" ]] || fail '初始化没有经过受控依赖替身'
assert_contains "$(<"$STUB_CALL_LOG")" 'npx'

note 'qmake plain C++ CLI configure/build/run 全链路通过'
