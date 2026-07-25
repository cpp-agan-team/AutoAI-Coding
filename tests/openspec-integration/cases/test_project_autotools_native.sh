#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT

missing_tools=()
for command_name in \
    aclocal ar autoconf autoheader automake autoreconf awk bash c++ dirname \
    git grep install m4 make mkdir node ranlib sed; do
    command -v "$command_name" >/dev/null 2>&1 || missing_tools+=("$command_name")
done
if (( ${#missing_tools[@]} > 0 )); then
    note "SKIP: Autotools 离线 fixture 缺少项目工具：${missing_tools[*]}"
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

repo="$tmp/autotools-native-project"
profile="$tmp/autotools-profile.json"
init_git_repo "$repo"
mkdir -p \
    "$repo/consumers" \
    "$repo/include/autoai" \
    "$repo/src" \
    "$repo/tests" \
    "$repo/tools"

cat > "$repo/.gitignore" <<'EOF'
/.fixture-out/
/Makefile.in
/aclocal.m4
/autom4te.cache/
/compile
/config.h.in
/configure
/depcomp
/install-sh
/missing
/test-driver
EOF

cat > "$repo/configure.ac" <<'EOF'
AC_INIT([autoai-autotools-fixture], [1.0.0])
AM_INIT_AUTOMAKE([foreign subdir-objects])
AC_CONFIG_SRCDIR([src/math.cpp])
AC_CONFIG_HEADERS([config.h])
AC_PROG_CXX
AC_PROG_RANLIB
AC_CONFIG_FILES([Makefile])
AC_OUTPUT
EOF

cat > "$repo/Makefile.am" <<'EOF'
AUTOMAKE_OPTIONS = subdir-objects
AM_CPPFLAGS = -I$(top_srcdir)/include

lib_LIBRARIES = libautoai_math.a
libautoai_math_a_SOURCES = \
	include/autoai/math.hpp \
	src/math.cpp

autoaiincludedir = $(includedir)/autoai
autoaiinclude_HEADERS = include/autoai/math.hpp

check_PROGRAMS = autotools_selftest
autotools_selftest_SOURCES = tests/selftest.cpp
autotools_selftest_LDADD = libautoai_math.a
TESTS = autotools_selftest
EOF

cat > "$repo/include/autoai/math.hpp" <<'EOF'
#pragma once

namespace autoai {
int add(int lhs, int rhs) noexcept;
}
EOF

cat > "$repo/src/math.cpp" <<'EOF'
#include "autoai/math.hpp"

namespace autoai {
int add(const int lhs, const int rhs) noexcept {
    return lhs + rhs;
}
}
EOF

cat > "$repo/tests/selftest.cpp" <<'EOF'
#include "autoai/math.hpp"

int main() {
    return autoai::add(20, 22) == 42 ? 0 : 1;
}
EOF

cat > "$repo/consumers/main.cpp" <<'EOF'
#include <autoai/math.hpp>

#include <iostream>

int main() {
    const int answer = autoai::add(19, 23);
    if (answer != 42) {
        return 1;
    }
    std::cout << "autotools-consumer-ok:" << answer << '\n';
    return 0;
}
EOF

cat > "$repo/tools/autotools-configure" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/.fixture-out/autotools-build"
prefix="$root/.fixture-out/autotools-install"

cd "$root"
autoreconf --force --install
mkdir -p "$out"
cd "$out"
"$root/configure" \
    --prefix="$prefix" \
    CXX=c++ \
    CXXFLAGS='-std=c++17 -O2'
EOF

cat > "$repo/tools/verify-autotools-consumer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
prefix="$root/.fixture-out/autotools-install"
out="$root/.fixture-out/autotools-consumer"
binary="$out/autotools_consumer"

mkdir -p "$out"
c++ \
    -std=c++17 \
    -I"$prefix/include" \
    "$root/consumers/main.cpp" \
    "$prefix/lib/libautoai_math.a" \
    -o "$binary"
"$binary"
EOF

chmod 755 \
    "$repo/tools/autotools-configure" \
    "$repo/tools/verify-autotools-consumer"

git -C "$repo" add .
git -C "$repo" \
    -c user.name=AutoAI-Test \
    -c user.email=autoai-test@example.invalid \
    commit -qm 'add native autotools fixture'

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
  timeout_seconds: 180,
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
    adapter: 'autotools',
    cpp_standards: ['c++17'],
    compilers: ['system-c++'],
    target_platforms: ['linux-host'],
    path_roles: {
      production: ['include/**', 'src/**'],
      test: ['tests/**', 'consumers/**'],
      example: [],
      generated: ['.fixture-out/**'],
      vendor: [],
      build_metadata: ['configure.ac', 'Makefile.am', 'tools/**']
    },
    capabilities: {
      configure: ['autotools-configure'],
      build: ['autotools-build'],
      test: ['autotools-check'],
      install: ['autotools-install'],
      consumer: ['autotools-consumer']
    },
    build_targets: [{
      id: 'autotools-static-library',
      kind: 'static-library',
      name: 'autoai_math',
      path: '.fixture-out/autotools-build/libautoai_math.a',
      source: 'profile'
    }],
    build_graph_entries: [
      {
        id: 'autotools-library-entry',
        kind: 'static-library',
        path: 'Makefile.am',
        source: 'profile',
        tested_by: ['autotools-selftest-entry'],
        consumed_by: ['autotools-consumer-entry']
      },
      {
        id: 'autotools-selftest-entry',
        kind: 'test-executable',
        path: 'tests/selftest.cpp',
        source: 'profile',
        depends_on: ['autotools-library-entry']
      },
      {
        id: 'autotools-consumer-entry',
        kind: 'downstream-consumer',
        path: 'consumers/main.cpp',
        source: 'profile',
        depends_on: ['autotools-library-entry']
      }
    ],
    distribution_surfaces: [{
      id: 'autotools-installed-sdk',
      kind: 'installed-static-sdk',
      path: 'include/autoai/math.hpp',
      build_entry_ids: ['autotools-library-entry'],
      consumer_entry_ids: ['autotools-consumer-entry']
    }]
  }],
  commands: [
    command(
      'autotools-configure',
      'configure',
      ['./tools/autotools-configure'],
      [
        'aclocal', 'autoconf', 'autoheader', 'automake', 'autoreconf',
        'awk', 'bash', 'c++', 'dirname', 'grep', 'install', 'm4',
        'mkdir', 'sed'
      ]
    ),
    command(
      'autotools-build',
      'build',
      ['make', '-C', '.fixture-out/autotools-build', '--jobs=2', 'all'],
      ['c++', 'make']
    ),
    command(
      'autotools-check',
      'test',
      ['make', '-C', '.fixture-out/autotools-build', '--jobs=2', 'check'],
      ['c++', 'make']
    ),
    command(
      'autotools-install',
      'install',
      ['make', '-C', '.fixture-out/autotools-build', 'install'],
      ['install', 'make'],
      ['workspace-write', 'install']
    ),
    command(
      'autotools-consumer',
      'consumer',
      ['./tools/verify-autotools-consumer'],
      ['bash', 'c++', 'dirname', 'mkdir']
    ),
    command(
      'autotools-toolchain-identity',
      'static-analysis',
      ['c++', '--version'],
      ['c++'],
      []
    )
  ],
  toolchain_identity: [{
    id: 'autotools-system-cxx',
    module_ids: ['root'],
    command_id: 'autotools-toolchain-identity'
  }]
};
fs.writeFileSync(file, JSON.stringify(profile, null, 2) + '\n');
NODE

note '使用离线 OpenSpec stub 和人工审查 Autotools Profile 初始化 Harness'
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
  max_timeout_seconds: 240,
  inherit_env: ['PATH'],
  allow_side_effects: ['workspace-write', 'install'],
  output_limit_bytes: 65536
};
fs.writeFileSync(file, JSON.stringify({
  schema_version: 1,
  policy_id: 'autotools-fixture-policy',
  contexts: {local: rule, ci: rule, release: rule}
}, null, 2) + '\n');
NODE

run_generated "$repo" scripts/project_profile.sh --check --json
assert_status 0
assert_file_contains "$repo/.ai-harness/project-profile.json" '"adapter": "autotools"'

note '受管命令真实执行 autoreconf、configure、build、check 与 install'
assert_command_pass "$repo" autotools-configure configure
assert_path_exists "$repo/configure"
assert_path_exists "$repo/.fixture-out/autotools-build/Makefile"

assert_command_pass "$repo" autotools-build build
assert_path_exists "$repo/.fixture-out/autotools-build/libautoai_math.a"

assert_command_pass "$repo" autotools-check test
assert_contains "$RUN_OUTPUT" 'PASS: autotools_selftest'

assert_command_pass "$repo" autotools-install install
assert_path_exists "$repo/.fixture-out/autotools-install/include/autoai/math.hpp"
assert_path_exists "$repo/.fixture-out/autotools-install/lib/libautoai_math.a"

note '下游 consumer 只使用安装后的头文件和静态库完成编译、链接和运行'
assert_command_pass "$repo" autotools-consumer consumer
assert_contains "$RUN_OUTPUT" 'autotools-consumer-ok:42'

[[ -s "$STUB_CALL_LOG" ]] || fail '初始化没有经过受控依赖替身'
assert_contains "$(<"$STUB_CALL_LOG")" 'npx'

note 'Autotools 原生全链路与安装后 consumer 均通过'
