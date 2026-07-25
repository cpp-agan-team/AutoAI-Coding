#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/clang ast project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

node - "$repo/scripts/integration_surface_lib.js" <<'NODE'
const normalize = require(process.argv[2]).normalizeSymbolIdentity;
const identity = normalize({
  declaration_kind: 'method', qualified_name: 'Box::pair', canonical_parameter_types: ['int', 'int'],
  canonical_return_type: 'int', template_parameter_kinds: ['type', 'type'], cv_qualifiers: [],
  ref_qualifier: 'none', declaration_path: 'include/widget.hpp'
});
if (identity.canonical_parameter_types.length !== 2 || identity.template_parameter_kinds.length !== 2) throw Error('ordered identity sequence was rejected or collapsed');
NODE

runtime_bin="$tmp/fake-clang-bin"
mkdir -p "$runtime_bin" "$repo/include" "$repo/src" "$repo/build"
tool_log="$tmp/fake-clang-invocations.log"
base_log="$tmp/base-mirror.log"

cat > "$runtime_bin/clang++" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$tool_log"
printf 'PWD=%s\n' "\$PWD" >> "$tool_log"
if [[ "\${1:-}" == --version ]]; then
  echo 'AutoAI canned clang 1.0'
  exit 0
fi
source_file=\${!#}
if [[ "\$(basename -- "\$source_file")" == autoai-clang-capability-probe.cpp ]]; then
  cat <<JSON
{"kind":"TranslationUnitDecl","inner":[{"id":"probe-fn","kind":"FunctionDecl","loc":{"file":"\$source_file"},"name":"autoai_probe","type":{"qualType":"int (int)"},"inner":[{"id":"probe-param","kind":"ParmVarDecl","name":"value","type":{"qualType":"int"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"IntegerLiteral","type":{"qualType":"int"},"value":"1"}]}]}]}]}
JSON
  exit 0
fi
root=\$(dirname -- "\$(dirname -- "\$source_file")")
if [[ "\$*" == *'-DAUTOAI_TEST_HEADER=1'* ]]; then
  header="\$root/tests/helper.hpp"
else
  header="\$root/include/widget.hpp"
fi
[[ -f "\$header" ]] || header="\$root/include/gadget.hpp"
if [[ "\$*" == *' -M '* ]]; then
  if [[ -f "\$root/dependency-symlink-case" ]]; then
    printf 'object: %q %q %q\n' "\$source_file" "\$header" "\$root/include/escape/dependency.hpp"
  else
    printf 'object: %q %q\n' "\$source_file" "\$header"
  fi
  exit 0
fi
if [[ "\$source_file" == */autoai-clang-ast-*/base/src/widget.cpp ]]; then
  printf 'BASE_ROOT=%s\n' "\$root" >> "$base_log"
  printf 'BASE_PWD=%s\n' "\$PWD" >> "$base_log"
  printf 'FILE_MODE=%s\n' "\$(stat -c %a -- "\$header")" >> "$base_log"
  printf 'DIR_MODE=%s\n' "\$(stat -c %a -- "\$root")" >> "$base_log"
fi
updated=0
grep -q updated "\$header" && updated=1
variant=0
[[ "\$*" == *'-DVARIANT=2'* ]] && variant=1
run_value=1
template_value=4
class_template_value=7
if [[ "\$updated" -eq 1 ]]; then run_value=2; template_value=5; class_template_value=8; fi
extra=''
if [[ "\$updated" -eq 1 ]]; then
  extra=",{\"id\":\"method-double\",\"kind\":\"CXXMethodDecl\",\"loc\":{\"file\":\"\$header\"},\"access\":\"public\",\"name\":\"run\",\"type\":{\"qualType\":\"int (double)\"},\"inner\":[{\"id\":\"param-double\",\"kind\":\"ParmVarDecl\",\"name\":\"value\",\"type\":{\"qualType\":\"double\"}},{\"kind\":\"CompoundStmt\",\"inner\":[{\"kind\":\"ReturnStmt\",\"inner\":[{\"kind\":\"IntegerLiteral\",\"type\":{\"qualType\":\"int\"},\"value\":\"3\"}]}]}]}"
fi
if [[ "\$variant" -eq 1 ]]; then
  extra="\$extra,{\"id\":\"method-char\",\"kind\":\"CXXMethodDecl\",\"loc\":{\"file\":\"\$header\"},\"access\":\"public\",\"name\":\"run\",\"type\":{\"qualType\":\"int (char)\"},\"inner\":[{\"id\":\"param-char\",\"kind\":\"ParmVarDecl\",\"name\":\"value\",\"type\":{\"qualType\":\"char\"}},{\"kind\":\"CompoundStmt\",\"inner\":[{\"kind\":\"ReturnStmt\",\"inner\":[{\"kind\":\"IntegerLiteral\",\"type\":{\"qualType\":\"int\"},\"value\":\"6\"}]}]}]}"
fi
if [[ -f "\$root/unsupported-private-field-case" ]]; then
  extra="\$extra,{\"kind\":\"AccessSpecDecl\",\"access\":\"private\"},{\"id\":\"private-field\",\"kind\":\"FieldDecl\",\"loc\":{\"file\":\"\$header\"},\"access\":\"private\",\"name\":\"private_state\",\"type\":{\"qualType\":\"int\"}}"
fi
if [[ -f "\$root/unsupported-protected-field-case" ]]; then
  extra="\$extra,{\"kind\":\"AccessSpecDecl\",\"access\":\"protected\"},{\"id\":\"protected-field\",\"kind\":\"FieldDecl\",\"loc\":{\"file\":\"\$header\"},\"access\":\"protected\",\"name\":\"protected_state\",\"type\":{\"qualType\":\"int\"}}"
fi
if [[ "\$*" == *'-DAUTOAI_TEST_HEADER=1'* ]]; then
  extra="\$extra,{\"id\":\"test-field\",\"kind\":\"FieldDecl\",\"loc\":{\"file\":\"\$header\"},\"access\":\"public\",\"name\":\"test_state\",\"type\":{\"qualType\":\"int\"}}"
fi
cat <<JSON
{"id":"translation-unit","kind":"TranslationUnitDecl","inner":[{"id":"record","kind":"CXXRecordDecl","loc":{"file":"\$header"},"name":"Widget","tagUsed":"class","inner":[{"kind":"AccessSpecDecl","access":"public"},{"id":"ctor-decl","kind":"CXXConstructorDecl","loc":{"file":"\$header"},"access":"public","name":"Widget","type":{"qualType":"void ()"}},{"id":"dtor-decl","kind":"CXXDestructorDecl","loc":{"file":"\$header"},"access":"public","name":"~Widget","type":{"qualType":"void ()"}},{"id":"method-int","kind":"CXXMethodDecl","loc":{"file":"\$header"},"access":"public","name":"run","type":{"qualType":"int (int)"},"inner":[{"id":"param-int","kind":"ParmVarDecl","name":"value","type":{"qualType":"int"}}]},{"id":"operator-decl","kind":"CXXMethodDecl","loc":{"file":"\$header"},"access":"public","name":"operator+","type":{"qualType":"int (int) const"},"inner":[{"id":"operator-param","kind":"ParmVarDecl","name":"value","type":{"qualType":"int"}}]}\$extra]},{"id":"ctor-def","kind":"CXXConstructorDecl","loc":{"file":"\$source_file"},"previousDecl":"ctor-decl","name":"Widget","type":{"qualType":"void ()"},"inner":[{"kind":"CompoundStmt","inner":[]}]},{"id":"dtor-def","kind":"CXXDestructorDecl","loc":{"file":"\$source_file"},"parentDeclContextId":"record","previousDecl":"dtor-decl","name":"~Widget","type":{"qualType":"void ()"},"inner":[{"kind":"CompoundStmt","inner":[]}]},{"id":"method-int-def","kind":"CXXMethodDecl","loc":{"file":"\$source_file"},"parentDeclContextId":"record","previousDecl":"method-int","name":"run","type":{"qualType":"int (int)"},"inner":[{"id":"param-int-def","kind":"ParmVarDecl","name":"value","type":{"qualType":"int"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"IntegerLiteral","type":{"qualType":"int"},"value":"\$run_value"}]}]}]},{"id":"operator-def","kind":"CXXMethodDecl","loc":{"file":"\$source_file"},"previousDecl":"operator-decl","name":"operator+","type":{"qualType":"int (int) const"},"inner":[{"id":"operator-param-def","kind":"ParmVarDecl","name":"value","type":{"qualType":"int"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"IntegerLiteral","type":{"qualType":"int"},"value":"9"}]}]}]},{"id":"template","kind":"FunctionTemplateDecl","loc":{"file":"\$header"},"name":"convert","inner":[{"id":"template-param","kind":"TemplateTypeParmDecl","name":"T"},{"id":"template-function","kind":"FunctionDecl","loc":{"file":"\$header"},"name":"convert","type":{"qualType":"T (T)"},"inner":[{"id":"template-value","kind":"ParmVarDecl","name":"value","type":{"qualType":"T"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"IntegerLiteral","type":{"qualType":"int"},"value":"\$template_value"}]}]}]}]},{"id":"box-template","kind":"ClassTemplateDecl","loc":{"file":"\$header"},"name":"Box","inner":[{"id":"box-param-t","kind":"TemplateTypeParmDecl","name":"T"},{"id":"box-param-u","kind":"TemplateTypeParmDecl","name":"U"},{"id":"box-record","kind":"CXXRecordDecl","loc":{"file":"\$header"},"name":"Box","tagUsed":"class","inner":[{"kind":"AccessSpecDecl","access":"public"},{"id":"box-pair","kind":"CXXMethodDecl","loc":{"file":"\$header"},"access":"public","name":"pair","type":{"qualType":"int (int, int)"},"inner":[{"id":"box-left","kind":"ParmVarDecl","name":"left","type":{"qualType":"int"}},{"id":"box-right","kind":"ParmVarDecl","name":"right","type":{"qualType":"int"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"IntegerLiteral","type":{"qualType":"int"},"value":"\$class_template_value"}]}]}]}]}]}]}
JSON
EOF
chmod 755 "$runtime_bin/clang++"

cat > "$repo/include/widget.hpp" <<'EOF'
#pragma once
class Widget {
public:
    Widget();
    ~Widget();
    int run(int value);
    int operator+(int value) const;
};
template <class T> T convert(T value) { return value; }
template <class T, class U> class Box {
public:
    int pair(int left, int right) { return left + right; }
};
EOF
cat > "$repo/src/widget.cpp" <<'EOF'
#include "widget.hpp"
Widget::Widget() = default;
Widget::~Widget() = default;
int Widget::run(int value) { return value + 1; }
int Widget::operator+(int value) const { return value + 9; }
int use_widget() { return Widget{}.run(1); }
EOF
mkdir -p "$repo/tests"
cat > "$repo/tests/helper.hpp" <<'EOF'
#pragma once
// test helper baseline
class Widget;
EOF

write_database() {
  local mode=${1:-normal}
  case "$mode" in
    normal)
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo","file":"src/widget.cpp","arguments":["c++","-I","include","-std=c++20","-c","src/widget.cpp","-o","build/widget.o"]}]
EOF
      ;;
    multi)
      cat > "$repo/compile_commands.json" <<EOF
[
 {"directory":"$repo","file":"src/widget.cpp","arguments":["c++","-I","include","-std=c++20","src/widget.cpp"]},
 {"directory":"$repo","file":"src/widget.cpp","arguments":["c++","-I","include","-std=c++20","-DVARIANT=2","src/widget.cpp"]}
]
EOF
      ;;
    faithful)
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo/src","file":"widget.cpp","arguments":["c++","-I","../include","-O2","-std=c++20","-c","widget.cpp","-o","../build/widget.o"]}]
EOF
      ;;
    build_cwd)
      mkdir -p "$repo/build/generated"
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo/build/generated","file":"../../src/widget.cpp","arguments":["c++","-I","../../include","-std=c++20","-c","../../src/widget.cpp","-o","widget.o"]}]
EOF
      ;;
    test_header)
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo","file":"src/widget.cpp","arguments":["c++","-I","include","-DAUTOAI_TEST_HEADER=1","-std=c++20","-c","src/widget.cpp","-o","build/widget.o"]}]
EOF
      ;;
  esac
}
write_database normal

git -C "$repo" config user.name 'AutoAI AST Test'
git -C "$repo" config user.email 'autoai-ast@example.invalid'
git -C "$repo" add -A
git -C "$repo" add -f compile_commands.json
git -C "$repo" commit -qm 'AST discovery baseline'
base=$(git -C "$repo" rev-parse HEAD)

cat > "$repo/include/widget.hpp" <<'EOF'
#pragma once
class Widget {
public:
    // updated
    Widget();
    ~Widget();
    int run(int value);
    int run(double value) { return static_cast<int>(value); }
    int operator+(int value) const;
};
template <class T> T convert(T value) { return value + T{}; }
template <class T, class U> class Box {
public:
    int pair(int left, int right) { return left + right + 1; }
};
EOF

cat > "$repo/src/widget.cpp" <<'EOF'
#include "widget.hpp"
Widget::Widget() = default;
Widget::~Widget() = default;
int Widget::run(int value) { return value + 2; }
int Widget::operator+(int value) const { return value + 9; }
int use_widget() { return Widget{}.run(1); }
EOF
cat > "$repo/tests/helper.hpp" <<'EOF'
#pragma once
// updated test helper
class Widget;
EOF

runner="$tmp/run-adapter.js"
cat > "$runner" <<'NODE'
'use strict';
const [adapterFile, root, base] = process.argv.slice(2);
const identity = (qualifiedName, parameters, templateKinds, declarationPath = 'include/widget.hpp') => ({
  declaration_kind: 'method', qualified_name: qualifiedName, canonical_parameter_types: parameters,
  canonical_return_type: 'int', template_parameter_kinds: templateKinds, cv_qualifiers: [], ref_qualifier: 'none',
  declaration_path: declarationPath
});
const oldPath = process.env.AST_OLD_PATH || null;
const currentPath = process.env.AST_CURRENT_PATH || 'include/widget.hpp';
const basePath = oldPath || currentPath, producerPaths = process.env.AST_BAD_PRODUCER ? ['src/widget.cpp'] : [...new Set([basePath, currentPath])];
const currentParameter = process.env.AST_FAKE_IDENTITY ? 'long' : 'int';
const plan = { block: { surfaces: [
  { id: 'surface-widget', kind: 'internal_api', change_kind: 'modified', producer_paths: producerPaths, symbol_identities: process.env.AST_NULL_IDENTITIES ? null : { base: [identity('Widget::run', ['int'], [], basePath)], current: [identity('Widget::run', [currentParameter], [], currentPath)] } },
  { id: 'surface-box', kind: 'internal_api', change_kind: 'modified', producer_paths: producerPaths, symbol_identities: { base: [identity('Box::pair', ['int', 'int'], ['type', 'type'], basePath)], current: [identity('Box::pair', ['int', 'int'], ['type', 'type'], currentPath)] } }
] } };
const scopeClass = currentPath.startsWith('tests/') ? 'tests' : 'production';
const scope = { logical_changes: [{ path: currentPath, old_path: oldPath, change_status: oldPath ? 'renamed' : 'modified', classifications: [scopeClass] }] };
const classification = {
  production: ['include/**', 'src/**'], tests: ['tests/**'], project_docs: ['README.md'],
  project_tooling: ['CMakeLists.txt', 'compile_commands.json'], examples: ['examples/**'],
  generated: [], vendor: ['vendor/**']
};
try {
  const value = require(adapterFile).discover({
    root, change: 'ast-test', implementationBase: base, compileCommandsPath: process.env.AST_COMPILE_DB || 'compile_commands.json', plan, scope, classification
  });
  process.stdout.write(JSON.stringify(value, null, 2) + '\n');
} catch (error) {
  process.stdout.write(JSON.stringify({ status: error.gateStatus || 'invalid', reason: error.message }) + '\n');
  process.exit(6);
}
NODE

run_adapter() {
  RUN_OUTPUT=
  RUN_STATUS=0
  set +e
  RUN_OUTPUT=$(cd "$repo" && node "$runner" "$repo/scripts/clang_ast_surface_adapter.js" "$repo" "$base" 2>&1)
  RUN_STATUS=$?
  set -e
}

assert_adapter_gate_status() {
  local expected=$1
  node - "$expected" "$RUN_OUTPUT" <<'NODE'
const [expected, raw] = process.argv.slice(2);
const value = JSON.parse(raw);
if (value.status !== expected) throw Error(`expected ${expected}, got ${value.status}`);
NODE
}

export PATH="$runtime_bin:$REAL_TEST_PATH"
note 'canned AST 全量执行 base/current dependency 与 projection，并发现 planned method、额外 overload 和 function template'
run_adapter
assert_status 0
printf '%s\n' "$RUN_OUTPUT" > "$tmp/result-one.json"
node - "$tmp/result-one.json" <<'NODE'
const fs = require('fs'), value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!value.ast_tool_identity?.resolved_path || !value.ast_tool_identity.version_sha256 || !value.ast_tool_identity.capability_probe_sha256) throw Error('tool identity incomplete');
if (value.adapter_identity?.id !== 'clang-ast-v1' || value.adapter_identity.schema_version !== 1) throw Error('adapter identity incomplete');
const candidates = value.candidates;
const methodInt = candidates.find(x => x.change_status === 'modified' && x.current_symbol_identity?.qualified_name === 'Widget::run' && x.current_symbol_identity.canonical_parameter_types[0] === 'int');
const methodDouble = candidates.find(x => x.change_status === 'added' && x.current_symbol_identity?.qualified_name === 'Widget::run' && x.current_symbol_identity.canonical_parameter_types[0] === 'double');
const template = candidates.find(x => x.change_status === 'modified' && x.current_symbol_identity?.declaration_kind === 'function_template');
const classTemplateMethod = candidates.find(x => x.change_status === 'modified' && x.current_symbol_identity?.qualified_name === 'Box::pair');
if (!methodInt || !methodDouble || !template || !classTemplateMethod) throw Error('overload/template exact candidate set missing');
if (JSON.stringify(classTemplateMethod.current_symbol_identity.canonical_parameter_types) !== JSON.stringify(['int', 'int']) || JSON.stringify(classTemplateMethod.current_symbol_identity.template_parameter_kinds) !== JSON.stringify(['type', 'type'])) throw Error('ordered repeated parameter/template kinds were collapsed');
if (!value.identity_inventory?.base?.some(x => x.qualified_name === 'Box::pair') || !value.identity_inventory?.current?.some(x => x.qualified_name === 'Box::pair')) throw Error('base/current identity inventory is incomplete');
for (const [name, kind] of [['Widget::Widget', 'constructor'], ['Widget::~Widget', 'destructor'], ['Widget::run', 'method'], ['Widget::operator+', 'operator']]) {
  if (!value.identity_inventory.base.some(x => x.qualified_name === name && x.declaration_kind === kind) || !value.identity_inventory.current.some(x => x.qualified_name === name && x.declaration_kind === kind)) throw Error('out-of-line declaration context was not normalized: ' + name);
}
if (value.identity_inventory.base.some(x => x.declaration_kind !== 'type' && ['Widget', '~Widget', 'run', 'operator+'].includes(x.qualified_name))) throw Error('out-of-line member leaked an unqualified identity');
if (methodDouble.candidate_scope !== 'public_contract' || methodDouble.base_symbol_identity !== null) throw Error('orphan overload scope/side mismatch');
if (candidates.some(x => x.change_status === 'renamed')) throw Error('AST emitted forbidden renamed candidate');
if (new Set(candidates.map(x => x.candidate_id)).size !== candidates.length) throw Error('candidate IDs collided');
NODE

note 'tests header 的外部声明只进入 reviewable，且 test-only unsupported declaration 不触发公开契约阻塞'
write_database test_header
AST_CURRENT_PATH=tests/helper.hpp run_adapter
assert_status 0
node - "$RUN_OUTPUT" <<'NODE'
const value = JSON.parse(process.argv[2]);
if (!value.candidates.length ||
    value.candidates.some(candidate => candidate.candidate_scope !== 'reviewable') ||
    !value.candidates.some(candidate => candidate.current_symbol_identity?.declaration_path === 'tests/helper.hpp')) {
  throw Error('shared production classification did not keep test-header AST candidates reviewable');
}
NODE
write_database normal

note '计划 symbol 必须真实存在于相应树且 declaration_path 必须属于 producer_paths'
before=$(wc -l < "$tool_log")
AST_NULL_IDENTITIES=1 run_adapter
assert_status 6
assert_adapter_gate_status invalid
assert_contains "$RUN_OUTPUT" 'clang_ast_cpp_api_requires_symbol_identities'
after=$(wc -l < "$tool_log")
[[ "$before" -eq "$after" ]] || fail 'null C++ identities invoked clang before plan rejection'
AST_FAKE_IDENTITY=1 run_adapter
assert_status 6
assert_contains "$RUN_OUTPUT" 'planned_symbol_identity_missing_from_current'
AST_BAD_PRODUCER=1 run_adapter
assert_status 6
assert_contains "$RUN_OUTPUT" 'planned_symbol_declaration_is_not_a_producer'

assert_file_contains "$base_log" 'FILE_MODE=400'
assert_file_contains "$base_log" 'DIR_MODE=500'
base_mirror=$(awk -F= '/^BASE_ROOT=/{print substr($0,index($0,"=")+1); exit}' "$base_log")
[[ -n "$base_mirror" && ! -e "$base_mirror" ]] || fail 'private base mirror was not cleaned after discovery'

note '相同输入的 tool identity、adapter identity、candidate ID 与 canonical output 稳定'
run_adapter
assert_status 0
printf '%s\n' "$RUN_OUTPUT" > "$tmp/result-two.json"
assert_files_equal "$tmp/result-one.json" "$tmp/result-two.json"

note 'compile database 的 directory 与 AST 相关优化 flag 被原样映射到 base/current'
write_database faithful
run_adapter
assert_status 0
assert_file_contains "$tool_log" "PWD=$repo/src"
assert_file_contains "$tool_log" '-O2'
note '未跟踪 CMake build working directory 只在私有 base mirror 中安全重建'
write_database build_cwd
run_adapter
assert_status 0
assert_file_contains "$tool_log" "PWD=$repo/build/generated"
assert_file_contains "$base_log" '/base/build/generated'
write_database normal

note '声明路径 rename 明确拆成 base deleted 与 current added，不做模糊 rename'
git -C "$repo" mv include/widget.hpp include/gadget.hpp
AST_OLD_PATH=include/widget.hpp AST_CURRENT_PATH=include/gadget.hpp run_adapter
assert_status 0
printf '%s\n' "$RUN_OUTPUT" > "$tmp/result-rename.json"
node - "$tmp/result-rename.json" <<'NODE'
const fs = require('fs'), value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!value.candidates.some(x => x.change_status === 'deleted' && x.base_symbol_identity?.declaration_path === 'include/widget.hpp')) throw Error('rename lost base deleted identity');
if (!value.candidates.some(x => x.change_status === 'added' && x.current_symbol_identity?.declaration_path === 'include/gadget.hpp')) throw Error('rename lost current added identity');
if (value.candidates.some(x => x.change_status === 'renamed')) throw Error('rename was fuzzily collapsed');
NODE
git -C "$repo" mv include/gadget.hpp include/widget.hpp

note '共享 scope 对 header 重命名到普通源路径仍保留 base-side public-contract candidate'
git -C "$repo" mv include/widget.hpp src/widget_contract.txt
node - "$repo/scripts/change_scope.js" "$repo" "$base" <<'NODE'
const [scopeFile, root, base] = process.argv.slice(2);
const classification = {
  production: ['include/**', 'src/**', 'CMakeLists.txt', 'cmake/**'],
  tests: ['tests/**'],
  project_docs: ['docs/**'],
  project_tooling: ['tools/**'],
  examples: ['examples/**'],
  generated: [],
  vendor: ['vendor/**']
};
const scope = require(scopeFile).collectScope(root, base, classification);
const oldHeader = scope.structural_candidates.find(candidate =>
  candidate.path === 'include/widget.hpp' &&
  candidate.change_status === 'deleted' &&
  candidate.kind === 'public-contract-candidate'
);
if (!oldHeader) throw Error('cross-category rename lost the base-side public contract candidate');
if (scope.structural_candidates.some(candidate =>
  candidate.path === 'src/widget_contract.txt' &&
  candidate.kind === 'public-contract-candidate'
)) throw Error('ordinary current path inherited the old header category');
NODE
git -C "$repo" mv src/widget_contract.txt include/widget.hpp

note '同一 header 在多配置下 presence 不一致时 fail closed'
write_database multi
run_adapter
assert_status 6
assert_contains "$RUN_OUTPUT" 'ast_multi_configuration_inconsistency'

note 'compile database command、response file、plugin 和越界 output 在执行 Clang 前被拒绝'
security_cases=(malformed command response plugin outside c_language)
for security_case in "${security_cases[@]}"; do
  before=$(wc -l < "$tool_log")
  case "$security_case" in
    malformed)
      printf '%s\n' '[{"directory":' > "$repo/compile_commands.json"
      ;;
    command)
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo","file":"src/widget.cpp","command":"c++ -Iinclude src/widget.cpp"}]
EOF
      ;;
    response)
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo","file":"src/widget.cpp","arguments":["c++","@args.rsp","src/widget.cpp"]}]
EOF
      ;;
    plugin)
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo","file":"src/widget.cpp","arguments":["c++","-Xclang","-load","src/widget.cpp"]}]
EOF
      ;;
    outside)
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo","file":"src/widget.cpp","output":"/tmp/escape.o","arguments":["c++","src/widget.cpp"]}]
EOF
      ;;
    c_language)
      cat > "$repo/compile_commands.json" <<EOF
[{"directory":"$repo","file":"src/widget.c","arguments":["cc","-I","include","src/widget.c"]}]
EOF
      ;;
  esac
  run_adapter
  assert_status 6
  assert_adapter_gate_status invalid
  after=$(wc -l < "$tool_log")
  [[ "$before" -eq "$after" ]] || fail "unsafe $security_case entry invoked clang"
done

note 'adapter 自身也拒绝非 .json compile database 路径，且在调用 Clang 前 Invalid'
write_database normal
cp "$repo/compile_commands.json" "$repo/compile_commands.txt"
before=$(wc -l < "$tool_log")
AST_COMPILE_DB=compile_commands.txt run_adapter
assert_status 6
assert_adapter_gate_status invalid
assert_contains "$RUN_OUTPUT" 'compile_commands_path_must_be_json'
after=$(wc -l < "$tool_log")
[[ "$before" -eq "$after" ]] || fail 'non-json compile database path invoked clang'
rm -f "$repo/compile_commands.txt"

note 'compile database 与依赖路径的任一祖先 symlink 都不能越过仓库边界'
write_database normal
mkdir -p "$repo/safe-db" "$tmp/outside-dependency"
cp "$repo/compile_commands.json" "$repo/safe-db/compile_commands.json"
ln -s safe-db "$repo/db-link"
before=$(wc -l < "$tool_log")
AST_COMPILE_DB=db-link/compile_commands.json run_adapter
assert_status 6
assert_adapter_gate_status invalid
assert_contains "$RUN_OUTPUT" 'compile_commands_path_uses_symlink'
after=$(wc -l < "$tool_log")
[[ "$before" -eq "$after" ]] || fail 'compile database ancestor symlink invoked clang'
touch "$tmp/outside-dependency/dependency.hpp" "$repo/dependency-symlink-case"
ln -s "$tmp/outside-dependency" "$repo/include/escape"
run_adapter
assert_status 6
assert_adapter_gate_status invalid
assert_contains "$RUN_OUTPUT" 'dependency_path_uses_symlink'
rm -f "$repo/dependency-symlink-case" "$repo/include/escape" "$repo/db-link"

note '公开 record 的 private/protected FieldDecl 也会改变 ABI，未投影时必须 fail closed'
for access in private protected; do
  touch "$repo/unsupported-${access}-field-case"
  run_adapter
  assert_status 6
  assert_adapter_gate_status blocked
  assert_contains "$RUN_OUTPUT" 'unsupported_public_contract_declaration_FieldDecl'
  rm -f "$repo/unsupported-${access}-field-case"
done

note '显式 clang_ast 模式缺少 clang++ 时 Blocked，绝不自动回退 reviewed_inventory'
write_database normal
mkdir -p "$tmp/no-clang"
PATH="$tmp/no-clang:/usr/local/bin:/usr/bin:/bin"
if command -v clang++ >/dev/null 2>&1; then fail 'test environment unexpectedly exposes clang++ in missing-tool path'; fi
run_adapter
assert_status 6
assert_adapter_gate_status blocked
assert_contains "$RUN_OUTPUT" 'clang++_not_found'

note '可选 AST adapter 的离线安全、身份、差集、cohort、rename 和缺工具语义通过；未声称真实 Clang 兼容性'
