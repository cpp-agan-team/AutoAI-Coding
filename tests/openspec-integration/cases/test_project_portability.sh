#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
real_node=$(command -v node)
export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path

run_setup_without_default_profile() {
    local directory=$1
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(
        cd "$directory" || exit 97
        printf '' | bash "$SETUP_SCRIPT" 2>&1
    )
    RUN_STATUS=$?
    set -e
}

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

write_archive_receipt() {
    local archive_root=$1
    local change=$2
    "$real_node" - "$archive_root" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [archiveRoot, change] = process.argv.slice(2);
const sha = value => 'sha256:' + crypto.createHash('sha256').update(value).digest('hex');
const records = [];
const base = `openspec/changes/${change}`;
const add = (file, logical) => {
  const st = fs.lstatSync(file);
  const mode = (st.mode & 0o111) ? '100755' : '100644';
  records.push(`${logical}\0${mode}\0file\0${sha(fs.readFileSync(file))}\0`);
};
for (const name of ['.openspec.yaml', 'proposal.md', 'design.md', 'tasks.md']) {
  add(path.join(archiveRoot, name), `${base}/${name}`);
}
const walk = (directory, logical) => {
  for (const name of fs.readdirSync(directory).sort((a, b) => Buffer.from(a).compare(Buffer.from(b)))) {
    const full = path.join(directory, name);
    const st = fs.lstatSync(full);
    if (st.isDirectory()) walk(full, logical + '/' + name);
    else if (st.isFile() && name.endsWith('.md')) add(full, logical + '/' + name);
  }
};
walk(path.join(archiveRoot, 'specs'), base + '/specs');
records.sort((a, b) => Buffer.from(a).compare(Buffer.from(b)));
const artifact = sha(Buffer.from(records.join('')));
const archivedAs = path.basename(archiveRoot);
const digest = 'sha256:' + '0'.repeat(64);
const receipt = {
  schema_version: 1,
  change_name: change,
  archived_as: archivedAs,
  archived_at: archivedAs.slice(0, 10) + 'T00:00:00Z',
  profile_sha256: digest,
  source_fingerprint: digest,
  artifact_fingerprint: artifact,
  base_specs_fingerprint_before: digest,
  archive_output_sha256: digest,
  main_specs_validation_sha256: digest,
  authority: 'retained-receipt-not-active-state'
};
fs.mkdirSync(path.join(archiveRoot, 'harness'), {recursive: true});
fs.writeFileSync(
  path.join(archiveRoot, 'harness', 'archive-receipt.json'),
  JSON.stringify(receipt, null, 2) + '\n'
);
NODE
}

write_profile() {
    local target=$1
    local variant=$2
    "$real_node" - "$target" "$variant" <<'NODE'
const fs = require('fs');
const [target, variant] = process.argv.slice(2);
const command = {
  id: 'portable-probe',
  module_ids: ['root'],
  capability: 'test',
  argv: ['./tools/portable-probe'],
  cwd: '.',
  timeout_seconds: 10,
  inherit_env: [],
  output_roles: ['test-result'],
  side_effects: []
};
const identityCommand = {
  id: 'portable-identity',
  module_ids: ['root'],
  capability: 'static-analysis',
  argv: ['./tools/portable-identity'],
  cwd: '.',
  timeout_seconds: 10,
  inherit_env: [],
  output_roles: ['toolchain-identity'],
  side_effects: []
};
const pathCommand = {
  id: 'portable-path',
  module_ids: ['root'],
  capability: 'static-analysis',
  argv: ['true'],
  cwd: '.',
  timeout_seconds: 10,
  inherit_env: ['PATH'],
  output_roles: ['analysis'],
  side_effects: []
};
if (variant === 'shell') {
  command.argv = ['bash', '-c', 'printf shell'];
  command.inherit_env = ['PATH'];
} else if (variant === 'secret') {
  command.argv = ['true'];
  command.inherit_env = ['PATH', 'API_TOKEN'];
} else if (variant === 'reserved') {
  command.inherit_env = ['AUTOAI_ACTIVE_CHANGE'];
} else if (variant === 'missing-path') {
  command.argv = ['true'];
} else if (variant === 'inline-runtime') {
  command.argv = ['node', '--eval', 'process.exit(0)'];
  command.inherit_env = ['PATH'];
}
const profile = {
  schema_version: 1,
  modules: [{
    id: 'root',
    root: '.',
    adapter: 'custom',
    cpp_standards: ['unknown'],
    compilers: ['unknown'],
    target_platforms: ['linux'],
    path_roles: {
      production: [],
      test: [],
      example: [],
      generated: [],
      vendor: [],
      build_metadata: []
    },
    capabilities: {
      test: ['portable-probe'],
      'static-analysis': ['portable-path']
    },
    capability_status: {
      test: {status: 'available', reason: 'reviewed test command'},
      'static-analysis': {status: 'available', reason: 'reviewed analysis command'},
      install: {status: 'not-applicable', reason: 'fixture is not installed'},
      package: {status: 'unavailable', reason: 'fixture has no package command'},
      'target-run': {status: 'needs-approval', reason: 'fixture has no approved runner'}
    },
    build_targets: [{
      id: 'portable-probe-target',
      kind: 'test-executable',
      name: 'portable-probe',
      path: 'tools/portable-probe',
      source: 'profile'
    }],
    build_graph_entries: [],
    distribution_surfaces: []
  }],
  commands: [command, identityCommand, pathCommand],
  toolchain_identity: [{
    id: 'portable-toolchain',
    module_ids: ['root'],
    command_id: 'portable-identity'
  }]
};
if (variant === 'capability-state') {
  profile.modules[0].capability_status.test = {
    status: 'not-applicable',
    reason: 'contradicts the exposed test command'
  };
}
fs.writeFileSync(target, JSON.stringify(profile, null, 2) + '\n');
NODE
}

note '只读探测返回多个候选且不会自动选择或触发 Node/npm/npx'
reset_stub_environment
repo="$tmp/mixed build repository"
init_git_repo "$repo"
printf 'cmake_minimum_required(VERSION 3.16)\n' > "$repo/CMakeLists.txt"
printf "project('portable', 'cpp')\n" > "$repo/meson.build"
before=$(fingerprint_tree "$repo")
export STUB_NODE_VERSION=v0.0.1
export STUB_NPX_MODE=fail
run_setup "$repo" --detect-project --json
assert_status 0
after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail '--detect-project 修改了目标工作树'
[[ ! -s "$STUB_CALL_LOG" ]] || fail '--detect-project 调用了 Node/npm/npx'
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const result = JSON.parse(process.argv[2]);
if (result.schema_version !== 1 ||
    result.selected !== null ||
    !Array.isArray(result.side_effects) ||
    result.side_effects.length !== 0 ||
    !Array.isArray(result.candidates)) {
  process.exit(1);
}
const adapters = new Set(result.candidates.map(candidate => candidate.adapter));
if (!adapters.has('cmake') || !adapters.has('meson') ||
    result.candidates.some(candidate => candidate.requires_human_confirmation !== true)) {
  process.exit(1);
}
NODE
assert_path_absent "$repo/.ai-harness"

note '探测聚合同一模块证据，并把子工程、package、fragment 和生成目录保留为低置信候选或提示'
reset_stub_environment
repo="$tmp/adapter detection repository"
init_git_repo "$repo"
mkdir -p \
    "$repo/cmake-child" \
    "$repo/meson-child" \
    "$repo/bazel-package" \
    "$repo/autotools-child" \
    "$repo/qmake-child" \
    "$repo/xmake-child" \
    "$repo/module-a/tools" \
    "$repo/tools/third_party/library" \
    "$repo/tools" \
    "$repo/build"
printf 'cmake_minimum_required(VERSION 3.16)\n' > "$repo/CMakeLists.txt"
printf 'add_library(child STATIC child.cpp)\n' > "$repo/cmake-child/CMakeLists.txt"
printf '{"version":3,"configurePresets":[]}\n' > "$repo/CMakePresets.json"
printf "project('root', 'cpp')\n" > "$repo/meson.build"
printf "subdir('nested')\n" > "$repo/meson-child/meson.build"
printf 'option("feature", type: "boolean", value: false)\n' > "$repo/meson.options"
printf 'workspace(name = "portable")\n' > "$repo/WORKSPACE"
printf 'cc_library(name = "root")\n' > "$repo/BUILD"
printf 'cc_library(name = "package")\n' > "$repo/bazel-package/BUILD.bazel"
printf 'AC_INIT([portable], [1.0])\n' > "$repo/configure.ac"
printf '#!/usr/bin/env sh\nexit 0\n' > "$repo/configure"
printf 'SUBDIRS = autotools-child\n' > "$repo/Makefile.am"
printf 'noinst_LIBRARIES = libchild.a\n' > "$repo/autotools-child/Makefile.am"
printf 'all:\n\t@true\n' > "$repo/Makefile"
printf 'TEMPLATE = app\n' > "$repo/portable.pro"
printf 'HEADERS += child.hpp\n' > "$repo/qmake-child/portable.pri"
printf 'target("root")\n' > "$repo/xmake.lua"
printf 'target("child")\n' > "$repo/xmake-child/xmake.lua"
printf 'rule all\n  command = true\nbuild all: all\n' > "$repo/build.ninja"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tools/build.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tools/third_party/library/build.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/module-a/tools/test.sh"
printf 'cmake_minimum_required(VERSION 3.16)\n' > "$repo/build/CMakeLists.txt"
printf 'name: ci\n' > "$repo/.gitlab-ci.yml"
chmod 755 \
    "$repo/tools/build.sh" \
    "$repo/tools/third_party/library/build.sh" \
    "$repo/module-a/tools/test.sh"
chmod 755 "$repo/configure"

before=$(fingerprint_tree "$repo")
run_setup "$repo" --detect-project --json
assert_status 0
after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail '聚合探测修改了目标工作树'
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const result = JSON.parse(process.argv[2]);
const key = (adapter, root) =>
  result.candidates.find(candidate => candidate.adapter === adapter && candidate.module_root === root);
const rootCmake = key('cmake', '.');
const childCmake = key('cmake', 'cmake-child');
const rootMeson = key('meson', '.');
const childMeson = key('meson', 'meson-child');
const bazel = key('bazel', '.');
const autotools = key('autotools', '.');
const qmake = key('qmake', '.');
const rootXmake = key('xmake', '.');
const childXmake = key('xmake', 'xmake-child');
const ninja = key('ninja', '.');
const rootCustom = key('custom', '.');
const moduleCustom = key('custom', 'module-a');
if (!rootCmake || rootCmake.confidence !== 'high' ||
    !childCmake || childCmake.confidence !== 'low' ||
    !rootMeson || rootMeson.confidence !== 'high' ||
    !childMeson || childMeson.confidence !== 'low' ||
    !bazel || key('bazel', 'bazel-package') ||
    !bazel.evidence.includes('WORKSPACE') || !bazel.evidence.includes('BUILD') ||
    !autotools || key('make', '.') ||
    !autotools.evidence.includes('configure.ac') ||
    !autotools.evidence.includes('configure') ||
    !autotools.evidence.includes('Makefile.am') ||
    !autotools.evidence.includes('autotools-child/Makefile.am') ||
    !qmake || key('qmake', 'qmake-child') ||
    !qmake.evidence.includes('portable.pro') ||
    !qmake.evidence.includes('qmake-child/portable.pri') ||
    !rootXmake || rootXmake.confidence !== 'high' ||
    !childXmake || childXmake.confidence !== 'low' ||
    !ninja || ninja.confidence !== 'low' ||
    !rootCustom || !rootCustom.capability_candidates.includes('build') ||
    rootCustom.evidence.includes('tools/third_party/library/build.sh') ||
    result.candidates.some(candidate =>
      candidate.adapter === 'custom' &&
      (candidate.module_root.includes('third_party') ||
       candidate.evidence.some(item => item.includes('/third_party/')))) ||
    !moduleCustom || !moduleCustom.capability_candidates.includes('test') ||
    key('cmake', 'build')) {
  process.exit(1);
}
for (const kind of [
  'bazel-package', 'autotools-fragment', 'qmake-fragment',
  'cmake-preset', 'meson-options', 'ci'
]) {
  if (!result.hints.some(hint => hint.kind === kind)) process.exit(1);
}
NODE

note '非交互初始化缺少已审核 Profile 时在目标写入前关闭'
reset_stub_environment
repo="$tmp/noninteractive missing profile"
init_git_repo "$repo"
printf 'preserve\n' > "$repo/user-owned.txt"
before=$(fingerprint_tree "$repo")
run_setup_without_default_profile "$repo"
assert_status 4
assert_contains "$RUN_OUTPUT" '非交互初始化必须提供已审核的 --project-profile'
after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail '缺少 Profile 的初始化修改了目标工作树'

note '秘密环境、隐藏 shell 工作流和隐式 PATH Profile 均 fail closed'
for variant in secret reserved shell missing-path inline-runtime capability-state; do
    reset_stub_environment
    repo="$tmp/invalid profile $variant"
    profile="$tmp/$variant-profile.json"
    init_git_repo "$repo"
    printf 'preserve\n' > "$repo/user-owned.txt"
    write_profile "$profile" "$variant"
    before=$(fingerprint_tree "$repo")
    run_setup "$repo" --project-profile "$profile"
    assert_status 4
    assert_contains "$RUN_OUTPUT" '传入的 Project Profile 无效'
    after=$(fingerprint_tree "$repo")
    [[ "$before" == "$after" ]] || fail "无效 Profile $variant 修改了目标工作树"
done

note '已审核 custom Profile 可以完成 fresh 初始化并按命令 ID 执行真实入口'
reset_stub_environment
repo="$tmp/valid custom project"
profile="$tmp/valid-custom-profile.json"
init_git_repo "$repo"
mkdir -p "$repo/tools"
printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "portable-ok\\n"\n' > "$repo/tools/portable-probe"
chmod 755 "$repo/tools/portable-probe"
printf '#!/bin/sh\nprintf "portable-toolchain-v1\\n"\n' > "$repo/tools/portable-identity"
chmod 755 "$repo/tools/portable-identity"
write_profile "$profile" valid
run_setup "$repo" --project-profile "$profile"
assert_status 0

for script in \
    scripts/project_detect.sh \
    scripts/project_profile.sh \
    scripts/project_command.sh \
    scripts/harness_doctor.sh \
    scripts/project_index.sh \
    scripts/campaign.sh \
    scripts/event_audit.sh
do
    assert_path_exists "$repo/$script"
    bash -n "$repo/$script"
done

for script in \
    scripts/project_profile_lib.js \
    scripts/project_command.js \
    scripts/harness_doctor.js \
    scripts/project_index.js \
    scripts/campaign.js \
    scripts/event_audit.js
do
    assert_path_exists "$repo/$script"
    "$real_node" --check "$repo/$script"
done

note 'Profile 模块边界、build graph、adapter export、工具链身份和 glob 契约 fail closed'
"$real_node" - "$repo/.ai-harness/project-profile.json" "$tmp" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [source, output] = process.argv.slice(2);
const original = JSON.parse(fs.readFileSync(source, 'utf8'));
const repository = path.dirname(path.dirname(source));
const write = (name, value) =>
  fs.writeFileSync(path.join(output, `profile-${name}.json`), JSON.stringify(value, null, 2) + '\n');
const digest = raw =>
  'sha256:' + crypto.createHash('sha256').update(raw).digest('hex');
const writeExport = (relative, value) => {
  const raw = JSON.stringify(value, null, 2) + '\n';
  const target = path.join(repository, relative);
  fs.mkdirSync(path.dirname(target), {recursive: true});
  fs.writeFileSync(target, raw);
  return digest(raw);
};
const exportRow = {
  entry_type: 'build-target',
  id: 'portable-probe-target',
  kind: 'test-executable',
  name: 'portable-probe',
  path: 'tools/portable-probe'
};
const exportDocument = row => ({
  schema_version: 1,
  adapter: 'custom',
  module_id: 'root',
  rows: [row]
});
const useExport = (value, artifactPath, artifactSha256) => {
  value.modules[0].build_targets[0].source = 'adapter-export';
  value.modules[0].build_targets[0].adapter_export = {
    schema_version: 1,
    adapter: 'custom',
    command_id: 'portable-identity',
    artifact_path: artifactPath,
    artifact_sha256: artifactSha256
  };
};

fs.mkdirSync(path.join(repository, 'module-extra'), {recursive: true});
fs.writeFileSync(path.join(repository, 'module-extra', '.keep'), 'profile fixture\n');

{
  const value = structuredClone(original);
  const artifactPath = 'tools/adapter-export-valid.json';
  useExport(value, artifactPath, writeExport(artifactPath, exportDocument(exportRow)));
  write('export-valid', value);
}
{
  const value = structuredClone(original);
  const artifactPath = 'tools/adapter-export-wrong-row.json';
  const wrongRow = {...exportRow, name: 'different-exported-target'};
  useExport(value, artifactPath, writeExport(artifactPath, exportDocument(wrongRow)));
  write('export-wrong-row', value);
}
{
  const value = structuredClone(original);
  const artifactPath = 'tools/adapter-export-open-document.json';
  const openDocument = {...exportDocument(exportRow), unexpected: true};
  useExport(value, artifactPath, writeExport(artifactPath, openDocument));
  write('export-open-document', value);
}
{
  const outsideDirectory = path.join(output, 'adapter-export-outside');
  const outsidePath = path.join(outsideDirectory, 'export.json');
  const raw = JSON.stringify(exportDocument(exportRow), null, 2) + '\n';
  fs.mkdirSync(outsideDirectory, {recursive: true});
  fs.writeFileSync(outsidePath, raw);
  const value = structuredClone(original);
  useExport(value, 'tools/adapter-export-link/export.json', digest(raw));
  write('export-symlink-ancestry', value);
}
{
  const value = structuredClone(original);
  const artifactPath = 'tools/adapter-export-side-effect.json';
  useExport(value, artifactPath, writeExport(artifactPath, exportDocument(exportRow)));
  value.commands.find(command => command.id === 'portable-identity').side_effects =
    ['workspace-write'];
  write('export-side-effect', value);
}
{
  const value = structuredClone(original);
  value.modules.push({
    id: 'extra',
    root: 'module-extra',
    adapter: 'custom',
    cpp_standards: ['unknown'],
    compilers: ['unknown'],
    target_platforms: ['linux'],
    path_roles: {
      production: [], test: [], example: [], generated: [],
      vendor: [], build_metadata: []
    },
    capabilities: {},
    build_targets: [],
    build_graph_entries: [],
    distribution_surfaces: []
  });
  value.commands.find(command => command.id === 'portable-probe').module_ids.push('extra');
  write('reverse-module-binding', value);
}

{
  const value = structuredClone(original);
  value.modules[0].build_graph_entries = [
    {
      id: 'cycle-a', kind: 'library', path: 'tools/portable-probe',
      source: 'profile', depends_on: ['cycle-b'], tested_by: [], consumed_by: []
    },
    {
      id: 'cycle-b', kind: 'library', path: 'tools/portable-probe',
      source: 'profile', depends_on: ['cycle-a'], tested_by: [], consumed_by: []
    }
  ];
  write('cycle', value);
}
{
  const value = {
    schema_version: 1,
    modules: [{
      id: 'tools', root: 'tools', adapter: 'custom',
      cpp_standards: ['unknown'], compilers: ['unknown'], target_platforms: ['linux'],
      path_roles: {
        production: ['tools*/**'], test: [], example: [], generated: [],
        vendor: [], build_metadata: []
      },
      capabilities: {}, build_graph_entries: [], distribution_surfaces: []
    }],
    commands: [], toolchain_identity: []
  };
  write('module-escape', value);
}
{
  const value = structuredClone(original);
  value.modules[0].build_targets[0].source = 'adapter-export';
  write('export-missing-provenance', value);
}
{
  const value = structuredClone(original);
  value.modules[0].build_targets[0].source = 'adapter-export';
  value.modules[0].build_targets[0].adapter_export = {
    schema_version: 1,
    adapter: 'custom',
    command_id: 'portable-identity',
    artifact_path: 'tools/portable-probe',
    artifact_sha256: 'sha256:' + '0'.repeat(64)
  };
  write('export-stale', value);
}
{
  const value = structuredClone(original);
  value.modules[0].cpp_standards = [];
  write('empty-standard', value);
}
{
  const value = structuredClone(original);
  value.toolchain_identity = [];
  value.commands = value.commands.filter(command => command.id !== 'portable-identity');
  write('missing-identity', value);
}
{
  const value = structuredClone(original);
  Object.defineProperty(value.commands[0], '__proto__', {
    value: {required_tools: ['autoai-prototype-injected-tool']},
    enumerable: true,
    writable: true,
    configurable: true
  });
  write('prototype-injection', value);
}
NODE

run_generated "$repo" "$real_node" scripts/project_profile_lib.js \
    --check-file "$tmp/profile-export-valid.json" --root "$repo" --json
assert_status 0
assert_contains "$RUN_OUTPUT" '"status": "pass"'

for profile_case in \
    'cycle:build graph depends_on contains a cycle' \
    'module-escape:is outside module root' \
    'export-missing-provenance:schema mismatch' \
    'export-stale:is missing, unsafe or stale' \
    'export-wrong-row:does not contain the declared row' \
    'export-open-document:schema mismatch' \
    'export-side-effect:adapter export command must be a side-effect-free static-analysis command' \
    'reverse-module-binding:is not exposed by module extra capability or an approved identity/export binding' \
    'empty-standard:must be an array' \
    'missing-identity:without a toolchain identity' \
    'prototype-injection:schema mismatch'
do
    profile_name=${profile_case%%:*}
    expected_message=${profile_case#*:}
    run_generated "$repo" "$real_node" scripts/project_profile_lib.js \
        --check-file "$tmp/profile-$profile_name.json" --root "$repo" --json
    assert_status 4
    assert_contains "$RUN_OUTPUT" "$expected_message"
done

ln -s "$tmp/adapter-export-outside" "$repo/tools/adapter-export-link"
run_generated "$repo" "$real_node" scripts/project_profile_lib.js \
    --check-file "$tmp/profile-export-symlink-ancestry.json" --root "$repo" --json
assert_status 4
assert_contains "$RUN_OUTPUT" 'has symbolic-link ancestry'
rm -f -- "$repo/tools/adapter-export-link"

run_generated "$repo" "$real_node" - <<'NODE'
const lib = require(process.cwd() + '/scripts/project_profile_lib.js');
const pattern = lib.globRegex('tools/**/*.js');
const embedded = lib.globRegex('foo**/bar');
const embeddedMiddle = lib.globRegex('prefix**suffix/file.cc');
if (!pattern.test('tools/a.js') ||
    !pattern.test('tools/nested/a.js') ||
    pattern.test('tools/a.cpp') ||
    embedded.test('foobar') ||
    !embedded.test('foo-suffix/bar') ||
    embedded.test('foo/nested/bar') ||
    !embeddedMiddle.test('prefix-any-suffix/file.cc') ||
    embeddedMiddle.test('prefix/any/suffix/file.cc')) {
  process.exit(1);
}
NODE
assert_status 0

for script in scripts/task_verify.sh scripts/evaluator_check.sh; do
    assert_file_contains "$repo/$script" 'Buffer.from(envelope.stdout)'
    assert_file_contains "$repo/$script" 'Buffer.from(envelope.stderr)'
done
assert_file_contains "$repo/scripts/task_verify.sh" 'timed-out, cancelled or signalled Project Command cannot close task evidence'
assert_file_contains "$repo/scripts/evaluator_check.sh" 'timed-out, cancelled or signalled Project Command cannot close Evaluation evidence'

export PATH=$REAL_TEST_PATH
before=$(fingerprint_tree "$repo")

run_generated "$repo" scripts/project_profile.sh --check --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const result = JSON.parse(process.argv[2]);
if (result.schema_version !== 1 || result.status !== 'pass' ||
    !result.modules.includes('root') ||
    result.commands.length !== 3 ||
    !result.commands.some(command => command.id === 'portable-probe') ||
    !result.commands.some(command => command.id === 'portable-identity') ||
    !result.commands.some(command => command.id === 'portable-path') ||
    result.commands.some(command => !Array.isArray(command.required_tools))) {
  process.exit(1);
}
NODE

run_generated "$repo" tools/portable-probe
assert_status 0
assert_contains "$RUN_OUTPUT" 'portable-ok'

[[ -x "$repo/scripts/source_fingerprint.sh" ]] ||
    fail '生成的 source_fingerprint.sh 不可执行'
run_generated "$repo" scripts/source_fingerprint.sh --kind source
assert_status 0

note '普通已跟踪项目 symlink 按 mode 与 link target 原子指纹，未跟踪和受管 symlink 关闭'
ln -s tools/portable-probe "$repo/portable-probe-link"
git -C "$repo" add portable-probe-link
run_generated "$repo" scripts/source_fingerprint.sh --kind source
assert_status 0
symlink_source_v1=$RUN_OUTPUT
rm -- "$repo/portable-probe-link"
ln -s tools/portable-identity "$repo/portable-probe-link"
run_generated "$repo" scripts/source_fingerprint.sh --kind source
assert_status 0
[[ "$RUN_OUTPUT" != "$symlink_source_v1" ]] ||
    fail 'tracked project symlink target change did not invalidate source fingerprint'
rm -- "$repo/portable-probe-link"
ln -s tools/portable-probe "$repo/portable-probe-link"
run_generated "$repo" scripts/source_fingerprint.sh --kind source
assert_status 0
[[ "$RUN_OUTPUT" == "$symlink_source_v1" ]] ||
    fail 'restored tracked project symlink did not restore source fingerprint'
ln -s tools/portable-probe "$repo/untracked-project-link"
run_generated "$repo" scripts/source_fingerprint.sh --kind source
assert_status 6
assert_contains "$RUN_OUTPUT" 'symbolic link blocked: untracked-project-link'
rm -- "$repo/untracked-project-link"
mv "$repo/scripts/campaign.sh" "$tmp/campaign.sh.saved"
ln -s ../tools/portable-probe "$repo/scripts/campaign.sh"
run_generated "$repo" scripts/source_fingerprint.sh --kind source
assert_status 6
assert_contains "$RUN_OUTPUT" 'symbolic link blocked: scripts/campaign.sh'
rm -- "$repo/scripts/campaign.sh"
mv "$tmp/campaign.sh.saved" "$repo/scripts/campaign.sh"

before=$(fingerprint_tree "$repo")
run_generated "$repo" scripts/project_command.sh portable-probe --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const result = JSON.parse(process.argv[2]);
if (result.schema_version !== 1 || result.status !== 'Pass' ||
    result.identity?.command_id !== 'portable-probe' ||
    !String(result.stdout).includes('portable-ok')) {
  process.exit(1);
}
NODE

after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail 'Project Profile 检查或只读 Project Command 修改了目标工作树'

run_generated "$repo" scripts/project_index.sh --refresh --json
assert_status 0
"$real_node" - "$repo/.ai-harness/derived/project-index.json" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const digest = value => /^sha256:[0-9a-f]{64}$/.test(value || '');
if (!digest(result.toolchain_identity_runtime_sha256) ||
    !digest(result.modules?.[0]?.toolchain_identity_runtime_sha256) ||
    result.modules?.[0]?.build_targets?.length !== 1 ||
    result.modules[0].build_targets[0].id !== 'portable-probe-target' ||
    result.modules[0].build_targets[0].confidence !== 'reviewed-declaration' ||
    result.modules[0].build_targets[0].inventory_status !== 'matched' ||
    !result.modules[0].build_targets[0].inventory_matches.includes('tools/portable-probe')) {
  process.exit(1);
}
NODE
run_generated "$repo" scripts/project_index.sh --check --json
assert_status 0
assert_contains "$RUN_OUTPUT" '"status": "fresh"'
index_runtime_v1=$("$real_node" -p \
    "JSON.parse(require('fs').readFileSync(process.argv[1])).toolchain_identity_runtime_sha256" \
    "$repo/.ai-harness/derived/project-index.json")
printf '#!/bin/sh\nprintf "portable-toolchain-v2\\n"\n' > "$repo/tools/portable-identity"
chmod 755 "$repo/tools/portable-identity"
run_generated "$repo" scripts/project_index.sh --refresh --json
assert_status 0
index_runtime_v2=$("$real_node" -p \
    "JSON.parse(require('fs').readFileSync(process.argv[1])).toolchain_identity_runtime_sha256" \
    "$repo/.ai-harness/derived/project-index.json")
[[ "$index_runtime_v1" != "$index_runtime_v2" ]] ||
    fail 'Project Index 未绑定实际工具链探针输出'
printf '#!/bin/sh\nprintf "portable-toolchain-v1\\n"\n' > "$repo/tools/portable-identity"
chmod 755 "$repo/tools/portable-identity"
run_generated "$repo" scripts/project_index.sh --refresh --json
assert_status 0

mkdir -p "$repo/.ai-harness/campaigns"
for change in campaign-a campaign-b campaign-c; do
    mkdir -p "$repo/openspec/changes/$change"
    printf 'schema: spec-driven\n' > "$repo/openspec/changes/$change/.openspec.yaml"
done
mkdir -p "$repo/openspec/changes/campaign-a/specs/runtime" \
    "$repo/openspec/changes/campaign-a/harness"
printf '# Proposal\n\nVerify runtime identity freshness.\n' \
    > "$repo/openspec/changes/campaign-a/proposal.md"
printf '# Tasks\n\n- [ ] 1.1 Verify runtime identity\n  - Covers: `specs/runtime/spec.md` | `ADDED` | `Runtime identity` | `Probe changes`\n  - Verify: `test`\n' \
    > "$repo/openspec/changes/campaign-a/tasks.md"
printf '# Runtime identity\n\n## ADDED Requirements\n\n### Requirement: Runtime identity\nThe command evidence SHALL bind the current toolchain.\n\n#### Scenario: Probe changes\n- **WHEN** the identity probe changes\n- **THEN** prior evidence is stale\n' \
    > "$repo/openspec/changes/campaign-a/specs/runtime/spec.md"
printf '%s\n' \
    '<!-- autoai:tdd-policy:v1 -->' \
    '```json' \
    '{"schema_version":1,"default":"required","exceptions":[]}' \
    '```' \
    '<!-- /autoai:tdd-policy:v1 -->' \
    '' \
    '<!-- autoai:integration-completeness:v1 -->' \
    '```json' \
    '{"discovery":{"compile_commands_path":null,"mode":"reviewed_inventory"},"schema_version":1,"surfaces":[]}' \
    '```' \
    '<!-- /autoai:integration-completeness:v1 -->' \
    > "$repo/openspec/changes/campaign-a/design.md"
"$real_node" - "$repo/openspec/changes/campaign-a/harness/ai_snapshot.json" <<'NODE'
const fs = require('fs');
fs.writeFileSync(process.argv[2], JSON.stringify({
  schema_version: 4,
  phase: 'implementing',
  planned_base_specs_fingerprint: null,
  planned_change_fingerprint: null,
  planned_tdd_policy_sha256: null,
  planned_integration_completeness_sha256: null,
  planning_approved_at: null,
  implementation_base_commit: null,
  adopted_preexisting_paths: [],
  implementation_baselined_at: null,
  current_step: 'runtime identity test',
  next_step: 'runtime identity test'
}, null, 2) + '\n');
NODE
"$real_node" - "$repo/ai_snapshot.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.active_change = 'campaign-a';
value.phase = 'implementing';
value.updated_at = new Date().toISOString();
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
NODE

run_generated "$repo" scripts/project_command.sh portable-probe --change campaign-a --json
assert_status 0
evidence_file="$tmp/managed-project-command.json"
printf '%s\n' "$RUN_OUTPUT" > "$evidence_file"
run_generated "$repo" "$real_node" - "$evidence_file" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const file = process.argv[2];
const raw = fs.readFileSync(file);
const envelope = JSON.parse(raw);
const outputSha = 'sha256:' + crypto.createHash('sha256').update(raw).digest('hex');
const command = {
  argv: ['scripts/project_command.sh', 'portable-probe', '--change', 'campaign-a', '--json'],
  output_sha256: outputSha,
  exit_code: 0,
  started_at: envelope.started_at,
  finished_at: envelope.finished_at
};
const policy = require(process.cwd() + '/scripts/manifest_policy.js');
policy.persistProjectCommandEvidence(process.cwd(), 'campaign-a', 'portable-probe', 0, outputSha, file);
policy.validateProjectCommandEvidence(process.cwd(), 'campaign-a', command);
NODE
assert_status 0

printf '#!/bin/sh\nprintf "portable-toolchain-v2\\n"\n' > "$repo/tools/portable-identity"
chmod 755 "$repo/tools/portable-identity"
run_generated "$repo" "$real_node" - "$evidence_file" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const raw = fs.readFileSync(process.argv[2]);
const envelope = JSON.parse(raw);
const outputSha = 'sha256:' + crypto.createHash('sha256').update(raw).digest('hex');
const command = {
  argv: ['scripts/project_command.sh', 'portable-probe', '--change', 'campaign-a', '--json'],
  output_sha256: outputSha,
  exit_code: 0,
  started_at: envelope.started_at,
  finished_at: envelope.finished_at
};
try {
  require(process.cwd() + '/scripts/manifest_policy.js')
    .validateProjectCommandEvidence(process.cwd(), 'campaign-a', command);
  process.exit(1);
} catch (error) {
  if (!String(error.message).includes('runtime environment or toolchain identity is stale')) {
    throw error;
  }
}
NODE
assert_status 0
printf '#!/bin/sh\nprintf "portable-toolchain-v1\\n"\n' > "$repo/tools/portable-identity"
chmod 755 "$repo/tools/portable-identity"

note '终止类 Project Command 侧证可审计但不能关闭 task/change'
run_generated "$repo" "$real_node" - "$evidence_file" "$tmp" <<'NODE'
const fs = require('fs');
const path = require('path');
const policy = require(process.cwd() + '/scripts/manifest_policy.js');
const [sourceFile, tempRoot] = process.argv.slice(2);
const original = JSON.parse(fs.readFileSync(sourceFile, 'utf8'));

function variant(name, status, exitCode, signal, closes) {
  const envelope = JSON.parse(JSON.stringify(original));
  envelope.status = status;
  envelope.exit_code = exitCode;
  envelope.signal = signal;
  envelope.evidence_subject_sha256 = policy.digest(Buffer.from(policy.canonical({
    identity: envelope.identity,
    status: envelope.status,
    exit_code: envelope.exit_code,
    output_sha256: envelope.output_sha256
  })));
  const raw = Buffer.from(JSON.stringify(envelope, null, 2) + '\n');
  const file = path.join(tempRoot, `project-command-${name}.json`);
  fs.writeFileSync(file, raw);
  const outputSha = policy.digest(raw);
  const command = {
    argv: ['scripts/project_command.sh', 'portable-probe', '--change', 'campaign-a', '--json'],
    output_sha256: outputSha,
    exit_code: exitCode,
    started_at: envelope.started_at,
    finished_at: envelope.finished_at
  };
  policy.persistProjectCommandEvidence(
    process.cwd(), 'campaign-a', 'portable-probe', exitCode, outputSha, file
  );
  let accepted = true;
  try {
    policy.validateProjectCommandEvidence(process.cwd(), 'campaign-a', command);
  } catch (error) {
    accepted = false;
    if (closes || !String(error.message).includes('cannot close verification')) throw error;
  }
  if (accepted !== closes) throw new Error(`closing policy mismatch for ${name}`);
}

variant('ordinary-negative', 'Fail', 7, null, true);
variant('timed-out', 'TimedOut', 124, null, false);
variant('cancelled', 'Cancelled', 130, 'SIGINT', false);
variant('signalled', 'Fail', 1, 'SIGSEGV', false);
NODE
assert_status 0

"$real_node" - "$repo/.ai-harness/campaigns/priority.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
fs.writeFileSync(file, JSON.stringify({
  schema_version: 1,
  campaign_id: 'priority',
  nodes: [
    {change_id: 'campaign-a', weight: 1},
    {change_id: 'campaign-b', weight: 100},
    {change_id: 'campaign-c', weight: 2}
  ],
  dependencies: [
    {change_id: 'campaign-a', depends_on: []},
    {change_id: 'campaign-b', depends_on: ['campaign-a']},
    {change_id: 'campaign-c', depends_on: []}
  ]
}, null, 2) + '\n');
NODE
export PATH="$STUB_BIN:$REAL_TEST_PATH"
run_generated "$repo" "$real_node" scripts/campaign.js priority --next-ready
assert_status 0
[[ "$RUN_OUTPUT" == campaign-a ]] || fail 'Campaign next-ready 未优先选择能解锁剩余关键路径的节点'

"$real_node" - "$repo/.ai-harness/campaigns/priority.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.dependencies = [
  {change_id: 'campaign-a', depends_on: []},
  {change_id: 'campaign-a', depends_on: []},
  {change_id: 'campaign-b', depends_on: ['campaign-a']}
];
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
NODE
run_generated "$repo" "$real_node" scripts/campaign.js priority --check --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'invalid campaign dependency row'
rm -- "$repo/.ai-harness/campaigns/priority.json"

note 'Context Slice 能读取唯一归档上游并拒绝归档身份歧义'
archive_one="$repo/openspec/changes/archive/2026-07-24-campaign-upstream"
mkdir -p "$archive_one/specs/upstream"
printf 'schema: spec-driven\n' > "$archive_one/.openspec.yaml"
printf '# Upstream proposal\n' > "$archive_one/proposal.md"
printf '# Upstream design\n' > "$archive_one/design.md"
printf '# Upstream tasks\n' > "$archive_one/tasks.md"
printf '# Upstream delta spec\n' > "$archive_one/specs/upstream/spec.md"
"$real_node" - "$repo/.ai-harness/campaigns/context.json" <<'NODE'
const fs = require('fs');
fs.writeFileSync(process.argv[2], JSON.stringify({
  schema_version: 1,
  campaign_id: 'context',
  nodes: [
    {change_id: 'campaign-upstream', weight: 1},
    {change_id: 'campaign-a', weight: 1}
  ],
  dependencies: [
    {change_id: 'campaign-upstream', depends_on: []},
    {change_id: 'campaign-a', depends_on: ['campaign-upstream']}
  ]
}, null, 2) + '\n');
NODE
run_generated "$repo" "$real_node" scripts/campaign.js context --status --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'archived Campaign receipt'
write_archive_receipt "$archive_one" campaign-upstream
run_generated "$repo" "$real_node" scripts/campaign.js context --status --json
assert_status 0
assert_contains "$RUN_OUTPUT" '"archive_receipt_sha256": "sha256:'
run_generated "$repo" "$real_node" scripts/context_slice.js campaign-a --refresh --token-budget 1000000 --json
assert_status 0
"$real_node" - "$repo/.ai-harness/derived/context/campaign-a/change.json" <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const p2 = value.tiers.find(tier => tier.tier === 'P2')?.items.map(item => item.path) || [];
const root = 'openspec/changes/archive/2026-07-24-campaign-upstream/';
for (const name of ['proposal.md', 'design.md', 'tasks.md']) {
  if (!p2.includes(root + name)) process.exit(1);
}
if (p2.some(item => item.startsWith('openspec/changes/campaign-upstream/'))) process.exit(1);
NODE
archive_two="$repo/openspec/changes/archive/2026-07-25-campaign-upstream"
mkdir -p "$archive_two"
cp -R "$archive_one/." "$archive_two/"
run_generated "$repo" "$real_node" scripts/context_slice.js campaign-a --refresh --token-budget 1000000 --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'ambiguous active/archive identity'
rm -rf -- "$archive_two"

printf '\nTampered after archive.\n' >> "$archive_one/proposal.md"
run_generated "$repo" "$real_node" scripts/campaign.js context --status --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'retained artifact identity mismatch'
printf '# Upstream proposal\n' > "$archive_one/proposal.md"
write_archive_receipt "$archive_one" campaign-upstream

export PATH=$REAL_TEST_PATH

"$real_node" - "$repo/.ai-harness/organization-policy.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const rule = {
  allow_command_ids: ['*'],
  deny_command_ids: [],
  allow_capabilities: ['*'],
  max_timeout_seconds: 30,
  inherit_env: [],
  allow_side_effects: ['*'],
  output_limit_bytes: 65536
};
fs.writeFileSync(file, JSON.stringify({
  schema_version: 1,
  policy_id: 'portable-policy',
  contexts: {local: rule, ci: rule, release: rule}
}, null, 2) + '\n');
NODE
run_generated "$repo" scripts/harness_doctor.sh --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const result = JSON.parse(process.argv[2]);
const check = result.checks?.find(item => item.id === 'profile.command.portable-path.local-policy');
if (result.summary?.status !== 'degraded' || check?.status !== 'fail' ||
    !result.summary.unavailable_capabilities?.includes('static-analysis') ||
    !result.summary.available_capabilities?.includes('test') ||
    !result.summary.not_applicable_capabilities?.includes('install') ||
    !result.summary.unavailable_capabilities?.includes('package') ||
    !result.summary.needs_approval_capabilities?.includes('target-run') ||
    !result.summary.absent_capabilities?.includes('configure')) {
  process.exit(1);
}
NODE
run_generated "$repo" scripts/project_command.sh portable-path --json
assert_status 4
assert_contains "$RUN_OUTPUT" 'PATH command or required_tools need PATH in the effective environment allowlist'

before=$(fingerprint_tree "$repo")

run_generated "$repo" scripts/project_command.sh missing-command --json
assert_status 4
assert_contains "$RUN_OUTPUT" 'unknown Project Profile command'

run_generated "$repo" scripts/harness_doctor.sh --unsupported
assert_status 2
assert_contains "$RUN_OUTPUT" 'usage: harness_doctor.sh'

run_generated "$repo" scripts/campaign.sh portability --check --json
assert_status 6
assert_contains "$RUN_OUTPUT" '[ERR]'

run_generated "$repo" scripts/event_audit.sh portability --check --json
assert_status 6
assert_contains "$RUN_OUTPUT" '[ERR]'

after=$(fingerprint_tree "$repo")
[[ "$before" == "$after" ]] || fail '生成脚本的只读检查修改了目标工作树'

note '仓内 wrapper 的 required_tools 由 Doctor 和命令执行器共同 fail closed'
"$real_node" - \
    "$repo/.ai-harness/project-profile.json" \
    "$repo/.ai-harness/organization-policy.json" <<'NODE'
const fs = require('fs');
const [profileFile, policyFile] = process.argv.slice(2);
const profile = JSON.parse(fs.readFileSync(profileFile, 'utf8'));
const command = profile.commands.find(item => item.id === 'portable-probe');
command.inherit_env = ['PATH'];
command.required_tools = ['autoai-definitely-missing-tool'];
fs.writeFileSync(profileFile, JSON.stringify(profile, null, 2) + '\n');
const policy = JSON.parse(fs.readFileSync(policyFile, 'utf8'));
policy.contexts.local.inherit_env = ['PATH'];
fs.writeFileSync(policyFile, JSON.stringify(policy, null, 2) + '\n');
NODE
run_generated "$repo" scripts/harness_doctor.sh --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const result = JSON.parse(process.argv[2]);
const check = result.checks?.find(
  item => item.id === 'profile.command.portable-probe.required-tools'
);
if (result.summary?.status !== 'degraded' ||
    check?.status !== 'fail' ||
    !result.summary.unavailable_capabilities?.includes('test')) {
  process.exit(1);
}
NODE
run_generated "$repo" scripts/harness_doctor.sh --json --strict
assert_status 6
run_generated "$repo" scripts/project_command.sh portable-probe --json
assert_status 4
assert_contains "$RUN_OUTPUT" \
    'required project tool is unavailable on the effective PATH: autoai-definitely-missing-tool'

note 'Project Index 按最深模块根归属文件，不把嵌套模块文件重复计入根模块'
"$real_node" - "$repo/.ai-harness/project-profile.json" "$repo" <<'NODE'
const fs = require('fs');
const path = require('path');
const [profileFile, root] = process.argv.slice(2);
fs.writeFileSync(path.join(root, 'root-owned.cc'), 'int root_owned = 1;\n');
fs.writeFileSync(path.join(root, 'module-extra', 'nested-owned.cc'), 'int nested_owned = 1;\n');
const module = (id, moduleRoot, production) => ({
  id,
  root: moduleRoot,
  adapter: 'custom',
  cpp_standards: ['unknown'],
  compilers: ['unknown'],
  target_platforms: ['linux'],
  path_roles: {
    production,
    test: [],
    example: [],
    generated: [],
    vendor: [],
    build_metadata: []
  },
  capabilities: {},
  build_targets: [],
  build_graph_entries: [],
  distribution_surfaces: []
});
fs.writeFileSync(profileFile, JSON.stringify({
  schema_version: 1,
  modules: [
    module('root', '.', ['**/*.cc']),
    module('nested', 'module-extra', ['module-extra/**/*.cc'])
  ],
  commands: [],
  toolchain_identity: []
}, null, 2) + '\n');
NODE
run_generated "$repo" scripts/project_index.sh --refresh --json
assert_status 0
"$real_node" - "$repo/.ai-harness/derived/project-index.json" <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const modules = new Map(value.modules.map(module => [module.id, module]));
const root = modules.get('root')?.path_roles?.production || [];
const nested = modules.get('nested')?.path_roles?.production || [];
if (value.file_ownership?.rule !== 'deepest-module-root' ||
    value.file_ownership.ambiguous.length !== 0 ||
    !root.includes('root-owned.cc') ||
    root.includes('module-extra/nested-owned.cc') ||
    !nested.includes('module-extra/nested-owned.cc')) {
  process.exit(1);
}
NODE

note 'Task Context Slice 按 OpenSpec surface 和 build graph 一跳裁剪项目文件'
printf 'int context_caller() { return nested_owned; }\n' \
    > "$repo/module-extra/caller.cc"
printf 'int graph_neighbor = 1;\n' \
    > "$repo/module-extra/graph-neighbor.cc"
printf 'int graph_two_hop = 1;\n' \
    > "$repo/module-extra/graph-two-hop.cc"
printf 'reviewed build metadata\n' > "$repo/module-extra/BUILD.meta"
mkdir -p "$repo/openspec/specs/runtime"
printf '# Runtime identity main spec\n' \
    > "$repo/openspec/specs/runtime/spec.md"
"$real_node" - \
    "$repo/.ai-harness/project-profile.json" \
    "$repo/openspec/changes/campaign-a/design.md" <<'NODE'
const fs = require('fs');
const [profileFile, designFile] = process.argv.slice(2);
const profile = JSON.parse(fs.readFileSync(profileFile, 'utf8'));
const root = profile.modules.find(module => module.id === 'root');
const nested = profile.modules.find(module => module.id === 'nested');
root.build_graph_entries = [{
  id: 'root-unrelated',
  kind: 'library',
  path: 'root-owned.cc',
  source: 'profile',
  depends_on: [],
  tested_by: [],
  consumed_by: []
}];
nested.path_roles.build_metadata = ['module-extra/BUILD.meta'];
nested.build_graph_entries = [
  {
    id: 'nested-api',
    kind: 'library',
    path: 'module-extra/nested-owned.cc',
    source: 'profile',
    depends_on: [],
    tested_by: [],
    consumed_by: ['nested-neighbor']
  },
  {
    id: 'nested-neighbor',
    kind: 'consumer',
    path: 'module-extra/graph-neighbor.cc',
    source: 'profile',
    depends_on: [],
    tested_by: [],
    consumed_by: ['nested-two-hop']
  },
  {
    id: 'nested-two-hop',
    kind: 'consumer',
    path: 'module-extra/graph-two-hop.cc',
    source: 'profile',
    depends_on: [],
    tested_by: [],
    consumed_by: []
  }
];
nested.distribution_surfaces = [{
  id: 'nested-runtime-surface',
  kind: 'internal-library',
  path: 'module-extra/nested-owned.cc',
  build_entry_ids: ['nested-api'],
  consumer_entry_ids: []
}];
fs.writeFileSync(profileFile, JSON.stringify(profile, null, 2) + '\n');

const surface = {
  change_kind: 'added',
  compatibility: null,
  consumer_kind: 'production_caller',
  consumer_paths: ['module-extra/caller.cc'],
  contract_impact: 'compatible',
  entrypoint: 'nested_owned',
  evidence_contracts: [{
    argv: ['./tools/portable-probe'],
    expected_exit_codes: [0],
    kind: 'test',
    output_contains: 'portable-ok',
    probe_id: 'probe-runtime-current',
    role: 'current'
  }],
  expected_observation: 'The production caller observes the nested runtime identity value.',
  id: 'surface-runtime-identity',
  kind: 'internal_api',
  name: 'Nested runtime identity',
  producer_paths: ['module-extra/nested-owned.cc'],
  requirement_refs: [{
    spec_path: 'specs/runtime/spec.md',
    operation: 'ADDED',
    requirement: 'Runtime identity',
    scenarios: ['Probe changes']
  }],
  symbol_identities: null,
  task_ids: ['1.1'],
  task_obligations: [{
    task_id: '1.1',
    verify_kinds: ['test'],
    evidence_roles: ['current']
  }],
  verify_kinds: ['test']
};
fs.writeFileSync(designFile, [
  '<!-- autoai:tdd-policy:v1 -->',
  '```json',
  '{"schema_version":1,"default":"required","exceptions":[]}',
  '```',
  '<!-- /autoai:tdd-policy:v1 -->',
  '',
  '<!-- autoai:integration-completeness:v1 -->',
  '```json',
  JSON.stringify({
    discovery: {compile_commands_path: null, mode: 'reviewed_inventory'},
    schema_version: 1,
    surfaces: [surface]
  }),
  '```',
  '<!-- /autoai:integration-completeness:v1 -->',
  ''
].join('\n'));
NODE
run_generated "$repo" scripts/project_profile.sh --check --json
assert_status 0
run_generated "$repo" scripts/project_index.sh --refresh --json
assert_status 0
run_generated "$repo" scripts/context_slice.sh campaign-a \
    --task 1.1 --refresh --token-budget 1000000 --json
assert_status 0
assert_contains "$RUN_OUTPUT" '"selection_mode": "task-scoped"'
"$real_node" - \
    "$repo/.ai-harness/derived/context/campaign-a/1.1.json" <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const p1 = value.tiers.find(tier => tier.tier === 'P1')?.items
  .map(item => item.path) || [];
const selection = value.selection;
if (selection?.mode !== 'task-scoped' ||
    selection.task?.id !== '1.1' ||
    !selection.selected_surface_ids.includes('surface-runtime-identity') ||
    selection.direct_module_ids.join(',') !== 'nested' ||
    selection.direct_build_graph_entry_ids.join(',') !== 'nested-api' ||
    selection.one_hop_build_graph_entry_ids.join(',') !== 'nested-neighbor' ||
    !selection.risk_signals.some(item => item.code === 'build-graph-one-hop') ||
    !p1.includes('module-extra/nested-owned.cc') ||
    !p1.includes('module-extra/caller.cc') ||
    !p1.includes('module-extra/graph-neighbor.cc') ||
    !p1.includes('module-extra/BUILD.meta') ||
    p1.includes('module-extra/graph-two-hop.cc') ||
    p1.includes('root-owned.cc')) {
  process.exit(1);
}
NODE
run_generated "$repo" scripts/context_slice.sh campaign-a \
    --task 9.9 --refresh --token-budget 1000000 --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'OpenSpec task does not exist'

note 'Context Slice 把 Git submodule 当作原子 gitlink，不递归读取内部文件'
suborigin="$tmp/context-submodule-origin"
init_git_repo "$suborigin"
printf 'int must_not_be_read_from_parent = 1;\n' > "$suborigin/internal.cc"
git -C "$suborigin" add internal.cc
git -C "$suborigin" \
    -c user.name=autoai-test \
    -c user.email=autoai-test@example.invalid \
    commit -qm 'initial context submodule'
git -c protocol.file.allow=always -C "$repo" \
    submodule add -q "$suborigin" deps/context-module
"$real_node" - "$repo/.ai-harness/project-profile.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const profile = JSON.parse(fs.readFileSync(file, 'utf8'));
const rootModule = profile.modules.find(module => module.id === 'root');
rootModule.path_roles.production.push('portable-probe-link');
rootModule.distribution_surfaces.push({
  id: 'portable-project-symlink',
  kind: 'project-symlink',
  path: 'portable-probe-link',
  build_entry_ids: [],
  consumer_entry_ids: []
});
profile.modules.push({
  id: 'gitlink-module',
  root: 'deps/context-module',
  adapter: 'custom',
  cpp_standards: ['unknown'],
  compilers: ['unknown'],
  target_platforms: ['linux'],
  path_roles: {
    production: ['deps/context-module'],
    test: [],
    example: [],
    generated: [],
    vendor: [],
    build_metadata: []
  },
  capabilities: {},
  build_targets: [],
  build_graph_entries: [],
  distribution_surfaces: [{
    id: 'gitlink-source',
    kind: 'gitlink',
    path: 'deps/context-module',
    build_entry_ids: [],
    consumer_entry_ids: []
  }]
});
fs.writeFileSync(file, JSON.stringify(profile, null, 2) + '\n');
NODE
run_generated "$repo" scripts/project_profile.sh --check --json
assert_status 0
run_generated "$repo" scripts/project_index.sh --refresh --json
assert_status 0
run_generated "$repo" scripts/context_slice.sh campaign-a \
    --refresh --token-budget 1000000 --json
assert_status 0
"$real_node" - "$repo/.ai-harness/derived/context/campaign-a/change.json" <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const rows = value.tiers.flatMap(tier =>
  tier.items.map(item => ({...item, tier: tier.tier})));
const exact = rows.filter(item => item.path === 'deps/context-module');
if (!exact.some(item => item.tier === 'P1') ||
    !exact.some(item => item.tier === 'P2') ||
    exact.some(item => item.bytes !== 0 ||
      !/^sha256:[0-9a-f]{64}$/.test(item.sha256)) ||
    rows.some(item => item.path.startsWith('deps/context-module/'))) {
  process.exit(1);
}
const symlinks = rows.filter(item => item.path === 'portable-probe-link');
if (!symlinks.some(item => item.tier === 'P1') ||
    !symlinks.some(item => item.tier === 'P2') ||
    symlinks.some(item => item.bytes !== Buffer.byteLength('tools/portable-probe') ||
      !/^sha256:[0-9a-f]{64}$/.test(item.sha256))) {
  process.exit(1);
}
NODE
run_generated "$repo" scripts/context_slice.sh campaign-a \
    --check --token-budget 1000000 --json
assert_status 0
rm -- "$repo/portable-probe-link"
ln -s tools/portable-identity "$repo/portable-probe-link"
run_generated "$repo" scripts/context_slice.sh campaign-a \
    --check --token-budget 1000000 --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'stale'
rm -- "$repo/portable-probe-link"
ln -s tools/portable-probe "$repo/portable-probe-link"

note 'Doctor 与执行器按 command cwd 解释相对和空 PATH segment'
mkdir -p "$repo/module-path/tools"
printf '#!/bin/sh\nprintf "relative-path-ok\\n"\n' \
    > "$repo/module-path/tools/relative-probe"
chmod 755 "$repo/module-path/tools/relative-probe"
"$real_node" - "$repo/.ai-harness/project-profile.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const profile = JSON.parse(fs.readFileSync(file, 'utf8'));
profile.modules.push({
  id: 'relative-path-module',
  root: 'module-path',
  adapter: 'custom',
  cpp_standards: ['unknown'],
  compilers: ['unknown'],
  target_platforms: ['linux'],
  path_roles: {
    production: [],
    test: [],
    example: [],
    generated: [],
    vendor: [],
    build_metadata: []
  },
  capabilities: {'static-analysis': ['relative-path-probe']},
  build_targets: [],
  build_graph_entries: [],
  distribution_surfaces: []
});
profile.commands.push({
  id: 'relative-path-probe',
  module_ids: ['relative-path-module'],
  capability: 'static-analysis',
  argv: ['relative-probe'],
  cwd: 'module-path',
  timeout_seconds: 10,
  inherit_env: ['PATH'],
  output_roles: ['analysis'],
  side_effects: []
});
fs.writeFileSync(file, JSON.stringify(profile, null, 2) + '\n');
NODE
export PATH="tools::$REAL_TEST_PATH"
run_generated "$repo" scripts/harness_doctor.sh --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const value = JSON.parse(process.argv[2]);
const executable = value.checks.find(
  item => item.id === 'profile.command.relative-path-probe.executable');
const row = value.summary?.module_capabilities?.find(
  item => item.module_id === 'relative-path-module' &&
    item.capability === 'static-analysis');
if (executable?.status !== 'pass' ||
    row?.status !== 'available' ||
    !row.available_command_ids.includes('relative-path-probe')) {
  process.exit(1);
}
NODE
run_generated "$repo" scripts/project_command.sh relative-path-probe --json
assert_status 0
assert_contains "$RUN_OUTPUT" 'relative-path-ok'

note 'Doctor 把同模块强制工具链探针纳入 capability runtime-ready'
"$real_node" - "$repo/.ai-harness/project-profile.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const profile = JSON.parse(fs.readFileSync(file, 'utf8'));
profile.commands.push({
  id: 'relative-toolchain-identity',
  module_ids: ['relative-path-module'],
  capability: 'static-analysis',
  argv: ['true'],
  cwd: 'module-path',
  timeout_seconds: 10,
  inherit_env: ['PATH'],
  required_tools: ['autoai-missing-relative-toolchain'],
  output_roles: ['toolchain-identity'],
  side_effects: []
});
profile.toolchain_identity.push({
  id: 'relative-toolchain',
  module_ids: ['relative-path-module'],
  command_id: 'relative-toolchain-identity'
});
fs.writeFileSync(file, JSON.stringify(profile, null, 2) + '\n');
NODE
run_generated "$repo" scripts/harness_doctor.sh --json
assert_status 0
"$real_node" - "$RUN_OUTPUT" <<'NODE'
const value = JSON.parse(process.argv[2]);
const own = value.checks.find(
  item => item.id === 'profile.command.relative-path-probe.executable');
const dependency = value.checks.find(
  item => item.id === 'profile.command.relative-path-probe.toolchain-identities');
const row = value.summary?.module_capabilities?.find(
  item => item.module_id === 'relative-path-module' &&
    item.capability === 'static-analysis');
if (own?.status !== 'pass' ||
    dependency?.status !== 'fail' ||
    row?.status !== 'unavailable' ||
    !row.unavailable_command_ids.includes('relative-path-probe')) {
  process.exit(1);
}
NODE
run_generated "$repo" scripts/project_command.sh relative-path-probe --json
assert_status 4
assert_contains "$RUN_OUTPUT" \
    'required project tool is unavailable on the effective PATH: autoai-missing-relative-toolchain'
export PATH=$REAL_TEST_PATH

note 'Profile 与 Index 拒绝 .ai-harness 符号链接祖先且不向链接目标写派生状态'
outside_harness="$tmp/outside-harness-state"
rm -rf -- "$repo/.ai-harness/derived"
mv -- "$repo/.ai-harness" "$outside_harness"
ln -s "$outside_harness" "$repo/.ai-harness"
run_generated "$repo" scripts/project_profile.sh --check --json
assert_status 4
assert_contains "$RUN_OUTPUT" 'has symbolic-link ancestry'
run_generated "$repo" scripts/project_index.sh --refresh --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'has symbolic-link ancestry'
assert_path_absent "$outside_harness/derived/project-index.json"

note '通用项目探测、Profile 边界和最小运行入口通过'
