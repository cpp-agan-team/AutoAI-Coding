#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/generated runtime project with spaces"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
system_node=$(command -v node)
system_node_version=$(node --version)
install_stub_path
reset_stub_environment

note 'setup 使用离线 stub，生成脚本运行时恢复系统 Node'
run_setup "$repo"
assert_status 0
export PATH=$REAL_TEST_PATH
[[ $(command -v node) == "$system_node" ]] || fail '运行生成脚本时没有恢复系统 Node'
[[ $(node --version) == "$system_node_version" ]] || fail '恢复后的 Node 版本与 setup 前不一致'

note '所有生成的 Shell 入口都能通过 bash -n'
shell_count=0
while IFS= read -r -d '' script; do
    shell_count=$((shell_count + 1))
    bash -n "$script" || fail "生成脚本语法无效：${script#"$repo"/}"
done < <(find "$repo" -path "$repo/.git" -prune -o -type f -name '*.sh' -print0)
(( shell_count > 0 )) || fail '没有发现生成的 Shell 脚本'

note '所有生成的 JavaScript 入口都能被真实 Node 完整解析'
javascript_count=0
while IFS= read -r -d '' script; do
    javascript_count=$((javascript_count + 1))
    node --check "$script" >/dev/null || fail "生成 JavaScript 语法无效：${script#"$repo"/}"
done < <(find "$repo" -path "$repo/.git" -prune -o -type f -name '*.js' -print0)
(( javascript_count > 0 )) || fail '没有发现生成的 JavaScript 脚本'

note '所有生成 JSON 和 YAML 都能被真实解析器读取'
mapfile -d '' -t json_files < <(
    find "$repo" -path "$repo/.git" -prune -o -type f -name '*.json' -print0
)
(( ${#json_files[@]} > 0 )) || fail '没有发现生成的 JSON 文件'
node - "${json_files[@]}" <<'NODE'
const fs = require('fs');
for (const file of process.argv.slice(2)) {
  try {
    JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    console.error(`invalid JSON: ${file}: ${error.message}`);
    process.exitCode = 1;
  }
}
NODE

mapfile -d '' -t yaml_files < <(
    find "$repo" -path "$repo/.git" -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print0
)
(( ${#yaml_files[@]} > 0 )) || fail '没有发现生成的 YAML 文件'
if python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "${yaml_files[@]}" <<'PY'
import pathlib
import sys
import yaml

for name in sys.argv[1:]:
    with pathlib.Path(name).open(encoding="utf-8") as stream:
        yaml.safe_load(stream)
PY
elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'ARGV.each { |file| YAML.safe_load_file(file, aliases: false) }' -- "${yaml_files[@]}"
else
    fail '测试环境缺少可用的 YAML 解析器（PyYAML 或 Ruby Psych）'
fi

note 'manifest 必须与固定所有权策略完全一致，不能把业务路径伪装成 Harness'
(cd "$repo" && node scripts/manifest_policy.js >/dev/null) || fail 'fresh manifest policy 校验失败'
node - "$repo" <<'NODE'
const path=require('path');
const root=process.argv[2];
const policy=require(path.join(root,'scripts/manifest_policy.js')).loadManifest(root);
for(const managed of ['docs/ai/openspec.md','prompts/planner.md','scripts/change_status.sh']){
  if(!policy.isManaged(managed))throw Error(`generated template is not managed: ${managed}`);
}
for(const projectOwned of ['docs/ai/team-guide.md','prompts/team-workflow.md','.gitignore']){
  if(policy.isManaged(projectOwned))throw Error(`project path was hidden by Harness ownership: ${projectOwned}`);
}
NODE
cp -p "$repo/.ai-harness/manifest.json" "$tmp/manifest.original.json"
node - "$repo/.ai-harness/manifest.json" <<'NODE'
const fs=require('fs'),file=process.argv[2],d=JSON.parse(fs.readFileSync(file,'utf8'));
d.managed_paths.push({path:'src/',ownership:'team-prefix',template_version:null});
fs.writeFileSync(file,JSON.stringify(d,null,2)+'\n');
NODE
if (cd "$repo" && node scripts/manifest_policy.js >/dev/null 2>&1); then
    fail '被篡改的 manifest 获得了业务路径排除权限'
fi
cp -p "$tmp/manifest.original.json" "$repo/.ai-harness/manifest.json"
(cd "$repo" && node scripts/manifest_policy.js >/dev/null) || fail 'manifest 恢复后策略仍失败'

note 'Agent 权限只放行只读 OpenSpec 命令，不能通配授权直接 archive'
node - "$repo/.claude/settings.json" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2])),allow=d?.permissions?.allow||[],deny=d?.permissions?.deny||[];
if(allow.includes('Bash(scripts/openspec_cli.sh:*)'))throw Error('wildcard openspec_cli permission is forbidden');
for(const rule of ['Bash(scripts/openspec_cli.sh status:*)','Bash(scripts/openspec_cli.sh instructions:*)','Bash(scripts/openspec_cli.sh validate:*)'])if(!allow.includes(rule))throw Error('missing read-only allow: '+rule);
if(!deny.includes('Bash(scripts/openspec_cli.sh archive:*)'))throw Error('managed archive deny is missing');
NODE

note '默认指导面不再把 legacy 根规格、状态或 tasks/ 当事实源'
mapfile -d '' -t guidance_files < <(
    find "$repo" -path "$repo/.git" -prune -o -path "$repo/openspec" -prune -o \
        -type f \( -name '*.md' -o -name '*.json' -o -name '*.yaml' -o \
        -name '*.yml' -o -name '*.txt' -o -name '.cursorrules' \) -print0
)
node - "${guidance_files[@]}" <<'NODE'
const fs = require('fs');
const forbidden = /(^|[^A-Za-z0-9_.\/-])(spec\.md|todo\.md|evaluation\.md|verification\.md|tasks\/)/gm;
const hits = [];
for (const file of process.argv.slice(2)) {
  const text = fs.readFileSync(file, 'utf8');
  for (const match of text.matchAll(forbidden)) {
    const line = text.slice(0, match.index).split('\n').length;
    hits.push(`${file}:${line}:${match[2]}`);
  }
}
if (hits.length) {
  console.error(`legacy root references found:\n${hits.join('\n')}`);
  process.exit(1);
}
NODE

note 'source fingerprint 稳定，并对内容和可执行位变化敏感'
mkdir -p "$repo/src"
printf 'int runtime_probe() { return 7; }\n' > "$repo/src/runtime_probe.cpp"
chmod 644 "$repo/src/runtime_probe.cpp"
fingerprint_1=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
fingerprint_2=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_1" == "$fingerprint_2" ]] || fail '未修改工作区时 source fingerprint 不稳定'
node -e '
const data = JSON.parse(process.argv[1]);
if (!/^sha256:[0-9a-f]{64}$/.test(data.source_fingerprint || "")) process.exit(1);
' "$fingerprint_1" || fail 'source fingerprint JSON 契约无效'

chmod 755 "$repo/src/runtime_probe.cpp"
fingerprint_executable=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_executable" != "$fingerprint_1" ]] || fail '可执行位变化没有改变 source fingerprint'
chmod 644 "$repo/src/runtime_probe.cpp"
fingerprint_restored=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_restored" == "$fingerprint_1" ]] || fail '恢复可执行位后 source fingerprint 未恢复'

printf '// content change\n' >> "$repo/src/runtime_probe.cpp"
fingerprint_content=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_content" != "$fingerprint_1" ]] || fail '内容变化没有改变 source fingerprint'

note '通用模式不猜测构建目录；被 Git 跟踪的 build/cache/dependency 路径仍属于源码状态'
mkdir -p "$repo/build" "$repo/.cache" "$repo/node_modules"
printf 'tracked build\n' > "$repo/build/tracked.txt"
printf 'tracked cache\n' > "$repo/.cache/tracked.txt"
printf 'tracked dependency\n' > "$repo/node_modules/tracked.txt"
git -C "$repo" add -f -- build/tracked.txt .cache/tracked.txt node_modules/tracked.txt
fingerprint_tracked_metadata=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_tracked_metadata" != "$fingerprint_content" ]] || fail '通用指纹错误地排除了被跟踪的假定构建路径'
printf 'tracked mutation\n' >> "$repo/build/tracked.txt"
fingerprint_tracked_mutation=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_tracked_mutation" != "$fingerprint_tracked_metadata" ]] || fail '被跟踪的 build/ 变化没有改变 source fingerprint'

note '只有 Project Profile 明确声明且未跟踪的 generated 路径可从源码指纹排除'
node - "$repo/.ai-harness/project-profile.json" <<'NODE'
const fs=require('fs'),file=process.argv[2],d=JSON.parse(fs.readFileSync(file,'utf8'));
d.modules[0].path_roles.generated=['scratch-generated/**'];
fs.writeFileSync(file,JSON.stringify(d,null,2)+'\n');
NODE
profile_fingerprint=$(cd "$repo" && scripts/source_fingerprint.sh --kind profile)
[[ "$profile_fingerprint" == sha256:* ]] || fail 'Profile 指纹契约无效'
fingerprint_before_generated=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
mkdir -p "$repo/scratch-generated"
printf 'profile-declared generated output\n' > "$repo/scratch-generated/output.cpp"
fingerprint_with_generated=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_with_generated" == "$fingerprint_before_generated" ]] || fail 'Profile 声明的未跟踪 generated 输出进入了 source fingerprint'
git -C "$repo" add -f -- scratch-generated/output.cpp
fingerprint_tracked_generated=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_tracked_generated" != "$fingerprint_before_generated" ]] || fail '被 Git 跟踪的 generated 输出被错误排除'

note 'OpenSpec 标准 artifacts 与 archive 不进入 source fingerprint 或 Quick Brief 扫描'
mkdir -p \
    "$repo/openspec/specs/runtime-probe" \
    "$repo/openspec/changes/runtime-probe/specs/runtime-probe" \
    "$repo/openspec/changes/archive/2026-07-14-runtime-probe" \
    "$repo/.ai-harness/migrations/runtime-probe"
for file in \
    "$repo/openspec/specs/runtime-probe/spec.md" \
    "$repo/openspec/changes/runtime-probe/proposal.md" \
    "$repo/openspec/changes/runtime-probe/specs/runtime-probe/spec.md" \
    "$repo/openspec/changes/archive/2026-07-14-runtime-probe/proposal.md" \
    "$repo/.ai-harness/migrations/runtime-probe/legacy.md"; do
    for line in $(seq 1 12); do
        printf 'sentinel line %s without a Quick Brief\n' "$line" >> "$file"
    done
done

fingerprint_with_openspec=$(cd "$repo" && scripts/source_fingerprint.sh --kind source --json)
[[ "$fingerprint_with_openspec" == "$fingerprint_tracked_generated" ]] || \
    fail 'OpenSpec artifact 或 migration runtime 意外进入 source fingerprint'

included_doc="$repo/docs/ai/runtime-quick-brief-probe.md"
for line in $(seq 1 12); do
    printf 'included guidance line %s without a Quick Brief\n' "$line" >> "$included_doc"
done
quick_output=$(cd "$repo" && QUICK_BRIEF_MIN_LINES=5 scripts/quick_brief_check.sh)
assert_contains "$quick_output" './docs/ai/runtime-quick-brief-probe.md'
assert_contains "$quick_output" 'OpenSpec artifacts, archive and migration backups are excluded.'
for excluded in \
    './openspec/specs/runtime-probe/spec.md' \
    './openspec/changes/runtime-probe/proposal.md' \
    './openspec/changes/runtime-probe/specs/runtime-probe/spec.md' \
    './openspec/changes/archive/2026-07-14-runtime-probe/proposal.md' \
    './.ai-harness/migrations/runtime-probe/legacy.md'; do
    assert_not_contains "$quick_output" "$excluded"
done
