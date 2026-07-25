#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/footprint contract project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

note '生成 Harness 和一个带二进制例外的 footprint change'
run_setup "$repo"
assert_status 0
(
    cd "$repo"
    scripts/change_new.sh footprint-contract >/dev/null
)
export PATH=$REAL_TEST_PATH

change=footprint-contract
change_dir="$repo/openspec/changes/$change"
snapshot="$change_dir/harness/ai_snapshot.json"
report="$change_dir/harness/change-footprint.json"

cat > "$change_dir/design.md" <<'EOF'
# Footprint design

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "micro",
  "rationale": "Exercise binary accounting and conservative vendor dependency detection.",
  "classification": {
    "production": ["src/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md"],
    "project_tooling": ["CMakeLists.txt"],
    "examples": ["examples/**"],
    "generated": [],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 0, "review_at": 0, "hard_limit": 0},
      "touched_files": {"expected": 0, "review_at": 0, "hard_limit": 0},
      "new_files": {"expected": 0, "review_at": 0, "hard_limit": 0}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 0, "hard_limit": 0},
      "touched_files": {"expected": 0, "review_at": 0, "hard_limit": 0},
      "new_files": {"expected": 0, "review_at": 0, "hard_limit": 0}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 0, "hard_limit": 0},
      "new_files": {"expected": 0, "review_at": 0, "hard_limit": 0}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 0, "hard_limit": 0},
      "bytes": {"expected": 0, "review_at": 0, "hard_limit": 0}
    }
  },
  "structural_allowances": {
    "public_contracts": [],
    "cmake_targets": [],
    "direct_dependencies": [
      {"id": "dep-vendor-fixture", "name": "vendor/blob.hpp", "reason": "The fixture deliberately changes one vendored binary input."}
    ]
  },
  "reuse_decisions": [],
  "obsolete_items": [],
  "exceptions": []
}
```
<!-- /autoai:implementation-economy:v1 -->
EOF

note 'artifact fingerprint 整棵跳过 harness evidence，不被其中的链接或运行文件污染'
ln -s missing-evidence-target "$change_dir/harness/ignored-runtime-link"
if ! (cd "$repo" && scripts/source_fingerprint.sh --kind artifact --change "$change" >/dev/null); then
    fail 'artifact fingerprint descended into harness runtime evidence'
fi
rm -f "$change_dir/harness/ignored-runtime-link"

git -C "$repo" config user.name 'AutoAI Footprint Test'
git -C "$repo" config user.email 'autoai-footprint@example.invalid'
git -C "$repo" add -A
git -C "$repo" commit -qm 'approved footprint baseline'
base=$(git -C "$repo" rev-parse HEAD)
node - "$snapshot" "$base" <<'NODE'
const fs=require('fs'),[file,base]=process.argv.slice(2),d=JSON.parse(fs.readFileSync(file));
d.implementation_base_commit=base;
d.implementation_baselined_at='2026-07-14T00:00:00Z';
fs.writeFileSync(file,JSON.stringify(d,null,2)+'\n');
NODE

mkdir -p "$repo/vendor"
printf '\0\1\2\3' > "$repo/vendor/blob.hpp"

run_footprint() {
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && scripts/change_footprint.sh "$change" --json 2>&1)
    RUN_STATUS=$?
    set -e
}

note '未批准的二进制使 footprint invalid，但仍报告文件数、字节数和路径'
run_footprint
assert_status 6
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
if(d.status!=='invalid'||d.binary?.files!==1||d.binary.bytes!==4||JSON.stringify(d.binary.paths)!=='["vendor/blob.hpp"]')throw Error('binary footprint contract mismatch');
const c=d.structural_candidates.find(x=>x.path==='vendor/blob.hpp');
if(!c||c.kind!=='direct-dependency-candidate'||c.allowance_kind!=='direct_dependencies')throw Error('vendor header was not classified as a dependency candidate');
NODE

node - "$change_dir/design.md" <<'NODE'
const fs=require('fs'),file=process.argv[2],text=fs.readFileSync(file,'utf8');
const replacement='"exceptions": [{"id":"binary-vendor-fixture","metric":"binary","paths":["vendor/**"],"reason":"Line accounting does not apply to the binary fixture.","requirement_refs":["specs/fixture/spec.md | ADDED | Binary fixture"],"task_ids":["1.1"],"verification":"Compare the exact fixture bytes."}]';
if(!text.includes('"exceptions": []'))throw Error('exception placeholder missing');
fs.writeFileSync(file,text.replace('"exceptions": []',replacement));
NODE

note '显式例外保留二进制报告，并让纯 vendor 变化回到可验收状态'
run_footprint
assert_status 0
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
if(d.status!=='within_expected'||d.binary?.files!==1||d.binary.bytes!==4)throw Error('approved binary footprint mismatch');
NODE

note '空文本文件计为 0 新增行；无 NUL 的非法 UTF-8 仍按二进制处理'
mkdir -p "$repo/src"
: > "$repo/src/empty.cpp"
run_footprint
assert_status 6
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
if(d.production.added_lines!==0)throw Error('empty untracked file was incorrectly counted as one line');
NODE
rm -f "$repo/src/empty.cpp"
printf '\377' > "$repo/vendor/nonutf8.bin"
run_footprint
assert_status 0
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
if(d.binary.files!==2||d.binary.bytes!==5||!d.binary.paths.includes('vendor/nonutf8.bin'))throw Error('invalid UTF-8 file was not treated as binary');
NODE
rm -f "$repo/vendor/nonutf8.bin"

bad_utf8_path=$'vendor/path-\377.bin'
printf 'x\n' > "$repo/$bad_utf8_path"
run_footprint
assert_status 6
assert_contains "$RUN_OUTPUT" 'Git untracked path data is not valid UTF-8'
rm -f "$repo/$bad_utf8_path"

note 'Implementation Economy 预算文档不是合法 UTF-8 时必须硬失败'
cp -p "$change_dir/design.md" "$tmp/design.saved"
printf '\377' >> "$change_dir/design.md"
run_footprint
assert_status 6
assert_contains "$RUN_OUTPUT" 'design.md is not valid UTF-8'
mv "$tmp/design.saved" "$change_dir/design.md"
run_footprint
assert_status 0

note '.gitignore 与保留目录中的团队文档都不能借 manifest 逃逸 scope 分类'
cp -p "$repo/.gitignore" "$tmp/gitignore.saved"
printf 'project-specific-ignore\n' >> "$repo/.gitignore"
run_footprint
assert_status 6
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
if(!d.unclassified_paths.includes('.gitignore'))throw Error('.gitignore was hidden from footprint scope');
NODE
mv "$tmp/gitignore.saved" "$repo/.gitignore"

printf '# Team-owned AI integration notes\n' > "$repo/docs/ai/team-guide.md"
run_footprint
assert_status 6
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
if(!d.unclassified_paths.includes('docs/ai/team-guide.md'))throw Error('team documentation was hidden by a managed prefix');
NODE

note '二进制计量、vendor candidate 与 manifest scope 边界均通过'
