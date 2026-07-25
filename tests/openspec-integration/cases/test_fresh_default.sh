#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/fresh project with spaces"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

note 'fresh 默认模式生成 OpenSpec-aware Harness'
run_setup "$repo"
assert_status 0

while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    assert_path_exists "$repo/$relative_path"
done < "$TEST_ROOT/fixtures/default/required-paths.txt"

while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    assert_path_absent "$repo/$relative_path"
done < "$TEST_ROOT/fixtures/default/forbidden-legacy-paths.txt"

assert_file_contains "$repo/openspec/config.yaml" 'schema: spec-driven'
assert_file_contains "$repo/ai_snapshot.json" '"schema_version": 2'
assert_file_contains "$repo/ai_snapshot.json" '"workflow"'
assert_file_contains "$repo/scripts/openspec_cli.sh" '@fission-ai/openspec@1.6.0'
assert_file_contains "$repo/scripts/openspec_cli.sh" 'OPENSPEC_TELEMETRY=0'

assert_file_contains "$STUB_CALL_LOG" $'npx\ttelemetry=0'
assert_file_contains "$STUB_CALL_LOG" '@fission-ai/openspec@1.6.0'
assert_file_contains "$STUB_CALL_LOG" $'openspec\t--version'
assert_file_contains "$STUB_CALL_LOG" $'openspec\tinit\t.\t--tools\tnone\t--profile\tcore'

workflow_report=$(
    cd "$repo"
    AUTOAI_SETUP_SOURCE="$SETUP_SCRIPT" \
      AUTOAI_SETUP_TEST_ROOT="$TEST_ROOT/cases" \
      scripts/workflow_contract_check.sh --json
)
node - "$workflow_report" <<'NODE'
const report=JSON.parse(process.argv[2]);
if(report.schema_version!==2||report.status!=='pass')throw Error('workflow contract report did not pass');
if(report.setup_cli?.status!=='pass')throw Error('setup parser/help parity did not pass');
if(report.setup_cli_tests?.status!=='pass'||report.setup_cli_tests.not_enumerated.length)throw Error('setup CLI tests do not enumerate every canonical option');
NODE

target_only_report=$(cd "$repo" && scripts/workflow_contract_check.sh --json)
node - "$target_only_report" <<'NODE'
const report=JSON.parse(process.argv[2]);
if(report.status!=='pass'||report.setup_cli?.status!=='not-applicable'||report.setup_cli_tests?.status!=='not-applicable'){
  throw Error('target-only checker did not preserve non-setup gates while reporting unavailable setup sources as N/A');
}
NODE

if find "$repo/.claude" "$repo/.codex" -type f -path '*/skills/openspec-*' -print -quit 2>/dev/null | grep -q .; then
    fail '默认模式安装了方案禁止的 OpenSpec Agent skills'
fi

note '结构化 Prompt binding 漂移不能靠正文中的相同关键词蒙混过关'
node - "$repo/prompts/planner.md" <<'NODE'
const fs=require('fs'),file=process.argv[2],text=fs.readFileSync(file,'utf8');
fs.writeFileSync(file,text.replace('"role":"planner"','"role":"generator"'));
NODE
set +e
RUN_OUTPUT=$(cd "$repo" && scripts/workflow_contract_check.sh 2>&1)
RUN_STATUS=$?
set -e
assert_status 6
assert_contains "$RUN_OUTPUT" 'structured binding drift'
