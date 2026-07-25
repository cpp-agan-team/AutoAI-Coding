#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/budget contract edge project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0
(
    cd "$repo"
    scripts/change_new.sh budget-edges >/dev/null
)
export PATH=$REAL_TEST_PATH

change=budget-edges
change_dir="$repo/openspec/changes/$change"
design="$change_dir/design.md"
snapshot="$change_dir/harness/ai_snapshot.json"
report="$change_dir/harness/change-footprint.json"

mkdir -p "$repo/tools"
printf '# Fixture project\n' > "$repo/README.md"
printf 'generator input\n' > "$repo/tools/gen.js"

cat > "$design" <<'EOF'
# Budget contract edge fixture

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "micro",
  "rationale": "Exercise canonical parsing, classification closure and severity aggregation.",
  "classification": {
    "production": ["src/**", "include/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md"],
    "project_tooling": ["CMakeLists.txt", "tools/**"],
    "examples": ["examples/**"],
    "generated": [
      {"output": "gen/**", "inputs": ["tools/gen.js"], "argv": ["node", "tools/gen.js"]}
    ],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 0, "review_at": 2, "hard_limit": 3},
      "touched_files": {"expected": 0, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 2, "hard_limit": 3}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 2, "hard_limit": 4},
      "touched_files": {"expected": 0, "review_at": 1, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 3}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "new_files": {"expected": 0, "review_at": 2, "hard_limit": 3}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 2, "hard_limit": 3},
      "bytes": {"expected": 0, "review_at": 10, "hard_limit": 20}
    }
  },
  "structural_allowances": {
    "public_contracts": [],
    "cmake_targets": [],
    "direct_dependencies": []
  },
  "reuse_decisions": [],
  "obsolete_items": [],
  "exceptions": []
}
```
<!-- /autoai:implementation-economy:v1 -->
EOF

git -C "$repo" config user.name 'AutoAI Budget Edge Test'
git -C "$repo" config user.email 'autoai-budget-edge@example.invalid'
git -C "$repo" add -A
git -C "$repo" commit -qm 'approved budget edge baseline'
base=$(git -C "$repo" rev-parse HEAD)
node - "$snapshot" "$base" <<'NODE'
const fs=require('fs'),[file,base]=process.argv.slice(2),d=JSON.parse(fs.readFileSync(file));d.implementation_base_commit=base;d.implementation_baselined_at='2026-07-14T00:00:00Z';fs.writeFileSync(file,JSON.stringify(d,null,2)+'\n');
NODE
cp -p -- "$design" "$tmp/design.valid.md"

run_footprint() {
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && scripts/change_footprint.sh "$change" --json 2>&1)
    RUN_STATUS=$?
    set -e
}

budget_digest() {
    node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).budget_block_sha256" "$report"
}

note '合法空 footprint 建立 canonical budget digest 与逐字节稳定报告'
run_footprint
assert_status 0
canonical_digest=$(budget_digest)
cp -p -- "$report" "$tmp/report.canonical.json"

note '对象 key-order 与空白变化保持等价 canonical digest 和相同 footprint JSON'
node - "$design" <<'NODE'
const fs=require('fs'),file=process.argv[2],text=fs.readFileSync(file,'utf8');
const re=/<!-- autoai:implementation-economy:v1 -->\s*```json\s*\n([\s\S]*?)\n```\s*<!-- \/autoai:implementation-economy:v1 -->/;
const match=text.match(re);if(!match)throw Error('budget block missing');
const reverse=v=>Array.isArray(v)?v.map(reverse):v&&typeof v==='object'?Object.fromEntries(Object.entries(v).reverse().map(([k,x])=>[k,reverse(x)])):v;
const body=JSON.stringify(reverse(JSON.parse(match[1])),null,'\t');
fs.writeFileSync(file,text.replace(re,`<!-- autoai:implementation-economy:v1 -->\n\n\`\`\`json\n${body}\n\`\`\`\n<!-- /autoai:implementation-economy:v1 -->`));
NODE
run_footprint
assert_status 0
[[ "$(budget_digest)" == "$canonical_digest" ]] || fail 'key-order/whitespace changed canonical budget digest'
assert_files_equal "$tmp/report.canonical.json" "$report"

note '数组顺序仍是语义数据，变化必须改变 budget digest'
node - "$design" <<'NODE'
const fs=require('fs'),file=process.argv[2],text=fs.readFileSync(file,'utf8');
const re=/<!-- autoai:implementation-economy:v1 -->\s*```json\s*\n([\s\S]*?)\n```\s*<!-- \/autoai:implementation-economy:v1 -->/;
const m=text.match(re),d=JSON.parse(m[1]);d.classification.production.reverse();
fs.writeFileSync(file,text.replace(re,`<!-- autoai:implementation-economy:v1 -->\n\`\`\`json\n${JSON.stringify(d,null,2)}\n\`\`\`\n<!-- /autoai:implementation-economy:v1 -->`));
NODE
run_footprint
assert_status 0
[[ "$(budget_digest)" != "$canonical_digest" ]] || fail 'classification array order was erased from canonical budget digest'
cp -p -- "$tmp/design.valid.md" "$design"

note '重复 JSON key 在 footprint 写入前硬失败，不能采用最后一个值'
node - "$design" <<'NODE'
const fs=require('fs'),file=process.argv[2],text=fs.readFileSync(file,'utf8'),needle='  "schema_version": 1,';
if(!text.includes(needle))throw Error('schema key missing');fs.writeFileSync(file,text.replace(needle,needle+'\n  "schema_version": 1,'));
NODE
report_before=$(sha256sum -- "$report" | awk '{print $1}')
run_footprint
assert_status 6
assert_contains "$RUN_OUTPUT" 'duplicate JSON key'
[[ "$report_before" == "$(sha256sum -- "$report" | awk '{print $1}')" ]] || fail 'duplicate-key failure replaced the last valid footprint'
cp -p -- "$tmp/design.valid.md" "$design"

note 'generated 可重复命令中的 Bearer/API credential 在 budget 解析阶段拒绝'
node - "$design" <<'NODE'
const fs=require('fs'),file=process.argv[2],text=fs.readFileSync(file,'utf8');
const re=/<!-- autoai:implementation-economy:v1 -->\s*```json\s*\n([\s\S]*?)\n```\s*<!-- \/autoai:implementation-economy:v1 -->/;
const m=text.match(re),d=JSON.parse(m[1]);d.classification.generated[0].argv.push('Authorization: Bearer generated-budget-credential');
fs.writeFileSync(file,text.replace(re,`<!-- autoai:implementation-economy:v1 -->\n\`\`\`json\n${JSON.stringify(d,null,2)}\n\`\`\`\n<!-- /autoai:implementation-economy:v1 -->`));
NODE
run_footprint
assert_status 6
assert_contains "$RUN_OUTPUT" 'secret-free argv'
cp -p -- "$tmp/design.valid.md" "$design"

note 'generated argv 的凭据 option/value 分离写法同样必须拒绝'
security_failures=0
node - "$design" <<'NODE'
const fs=require('fs'),file=process.argv[2],text=fs.readFileSync(file,'utf8');
const re=/<!-- autoai:implementation-economy:v1 -->\s*```json\s*\n([\s\S]*?)\n```\s*<!-- \/autoai:implementation-economy:v1 -->/;
const m=text.match(re),d=JSON.parse(m[1]);d.classification.generated[0].argv.push('--token','generated-budget-literal-value');
fs.writeFileSync(file,text.replace(re,`<!-- autoai:implementation-economy:v1 -->\n\`\`\`json\n${JSON.stringify(d,null,2)}\n\`\`\`\n<!-- /autoai:implementation-economy:v1 -->`));
NODE
run_footprint
if [[ "$RUN_STATUS" -eq 0 ]]; then
    printf '[ASSERT] generated argv accepted a credential option followed by a literal value\n' >&2
    security_failures=$((security_failures + 1))
else
    assert_status 6
    assert_contains "$RUN_OUTPUT" 'secret-free argv'
fi
cp -p -- "$tmp/design.valid.md" "$design"

note '一个实施路径同时命中 production/tests 时 footprint 必须 invalid 并列出 overlap'
node - "$design" <<'NODE'
const fs=require('fs'),file=process.argv[2],text=fs.readFileSync(file,'utf8');
const re=/<!-- autoai:implementation-economy:v1 -->\s*```json\s*\n([\s\S]*?)\n```\s*<!-- \/autoai:implementation-economy:v1 -->/;
const m=text.match(re),d=JSON.parse(m[1]);d.classification.tests.push('src/**');
fs.writeFileSync(file,text.replace(re,`<!-- autoai:implementation-economy:v1 -->\n\`\`\`json\n${JSON.stringify(d,null,2)}\n\`\`\`\n<!-- /autoai:implementation-economy:v1 -->`));
NODE
mkdir -p "$repo/src"
printf 'int overlap_probe;\n' > "$repo/src/overlap.cpp"
run_footprint
assert_status 6
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
const hit=d.classification_overlaps.find(x=>x.path==='src/overlap.cpp');
if(d.status!=='invalid'||!hit||JSON.stringify(hit.classes)!=='["production","tests"]')throw Error('classification overlap was not closed as invalid');
NODE
rm -f -- "$repo/src/overlap.cpp"
cp -p -- "$tmp/design.valid.md" "$design"

note 'production drift、tests review、project-support hard 与 generated drift 按最高严重度聚合'
mkdir -p "$repo/src" "$repo/tests" "$repo/gen"
printf 'int production_probe;\n' > "$repo/src/production.cpp"
printf 'test line 1\ntest line 2\n' > "$repo/tests/budget_test.cpp"
printf 'data' > "$repo/gen/output.txt"
printf 'support line 1\nsupport line 2\nsupport line 3\n' >> "$repo/README.md"
run_footprint
assert_status 6
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));
if(d.status!=='hard_exceeded'||d.production.added_lines!==1||d.tests.added_lines!==2||d.project_support.added_lines!==3||d.generated.files!==1||d.generated.bytes!==4)throw Error('highest-severity footprint aggregation mismatch');
NODE

printf '# Fixture project\n' > "$repo/README.md"
run_footprint
assert_status 6
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));if(d.status!=='review_required')throw Error(`expected review_required, got ${d.status}`);
NODE

rm -f -- "$repo/tests/budget_test.cpp"
run_footprint
assert_status 0
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));if(d.status!=='drift_warning')throw Error(`expected drift_warning, got ${d.status}`);
NODE

rm -f -- "$repo/src/production.cpp" "$repo/gen/output.txt"
run_footprint
assert_status 0
node - "$report" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));if(d.status!=='within_expected')throw Error(`expected within_expected, got ${d.status}`);
NODE

(( security_failures == 0 )) || fail "budget generated-argv credential regression failed ($security_failures assertions)"
note 'budget duplicate-key/canonicalization/overlap/generated-secret 与四类最高严重度聚合均通过'
