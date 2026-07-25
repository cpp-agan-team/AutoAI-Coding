#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/evaluator lifecycle project"
init_git_repo "$repo"

fixed_clock="$tmp/fixed-clock.cjs"
cat > "$fixed_clock" <<'NODE'
const NativeDate = Date;
const fixed = Number(process.env.AUTOAI_TEST_NOW_MS);
if (!Number.isFinite(fixed)) throw new Error('AUTOAI_TEST_NOW_MS must be finite');
class FixedDate extends NativeDate {
  constructor(...args) { super(...(args.length ? args : [fixed])); }
  static now() { return fixed; }
}
global.Date = FixedDate;
NODE

export STUB_CALL_LOG="$tmp/setup-dependency-calls.log"
system_node=$(command -v node)
system_git=$(command -v git)
install_stub_path
reset_stub_environment

note '默认 Harness 由离线依赖 stub 生成，生命周期运行恢复系统真实 Node'
run_setup "$repo"
assert_status 0
export PATH=$REAL_TEST_PATH
[[ $(command -v node) == "$system_node" ]] || fail 'Evaluator 生命周期没有使用系统真实 Node'

runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
runtime_log="$tmp/runtime-npx-calls.log"
export RUNTIME_NPX_LOG=$runtime_log
: > "$runtime_log"

cat > "$runtime_bin/npx" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RUNTIME_NPX_LOG:?}"
args=("$@")
index=-1
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == openspec ]]; then
        index=$i
        break
    fi
done
(( index >= 0 )) || { echo 'runtime npx stub expected openspec' >&2; exit 64; }
command_args=("${args[@]:index + 1}")
case "${command_args[0]:-}" in
    --version|-v|version)
        printf '1.6.0\n'
        ;;
    validate)
        if [[ "${RUNTIME_POST_ARCHIVE_VALIDATE_FAIL:-0}" == 1 && ! -d openspec/changes/widget-output ]]; then
            printf '{"items":[{"id":"main-specs","valid":false,"issues":[{"level":"ERROR","message":"injected post-archive failure"}]}],"summary":{"totals":{"failed":1}}}\n'
        else
            printf '{"items":[{"id":"widget-output","valid":true,"issues":[]}],"summary":{"totals":{"failed":0}}}\n'
        fi
        ;;
    status)
        printf '{"changeName":"widget-output","schemaName":"spec-driven","isComplete":true,"artifacts":[{"id":"proposal","status":"done"},{"id":"design","status":"done"},{"id":"specs","status":"done"},{"id":"tasks","status":"done"}]}\n'
        ;;
    instructions)
        if grep -q '^- \[[xX]\] 1\.1 ' openspec/changes/widget-output/tasks.md; then
            printf '{"changeName":"widget-output","schemaName":"spec-driven","state":"all_done","progress":{"total":1,"complete":1,"remaining":0},"tasks":[{"id":"1.1","done":true}]}\n'
        else
            printf '{"changeName":"widget-output","schemaName":"spec-driven","state":"ready","progress":{"total":1,"complete":0,"remaining":1},"tasks":[{"id":"1.1","done":false}]}\n'
        fi
        ;;
    archive)
        if [[ "${RUNTIME_ARCHIVE_MODE:-}" == interrupt-prepared ]]; then
            archive_pid=$(ps -o ppid= -p "$PPID" | tr -d '[:space:]')
            archive_command=$(ps -o args= -p "$archive_pid" 2>/dev/null || true)
            [[ "$archive_pid" =~ ^[0-9]+$ && "$archive_command" == *scripts/change_archive.sh* ]] || {
                printf 'could not identify change_archive.sh parent for interruption\n' >&2
                exit 65
            }
            kill -KILL "$archive_pid"
            exit 0
        fi
        if [[ "${RUNTIME_ARCHIVE_MODE:-}" == moved-wrong-json ]]; then
            change_name=${command_args[1]:-}
            archived_as="$(date -u +%Y-%m-%d)-$change_name"
            archive_path="$(pwd -P)/openspec/changes/archive/$archived_as"
            mv "openspec/changes/$change_name" "$archive_path"
            printf '{"archive":{"change":"%s","archivedAs":"wrong-name","path":"%s","specsUpdated":true,"totals":{"added":1,"modified":0,"removed":0,"renamed":0}}}\n' "$change_name" "$archive_path"
            exit 0
        fi
        if [[ "${RUNTIME_ARCHIVE_MODE:-}" == wrong-json ]]; then
            printf '{"archive":{"change":"widget-output","archivedAs":"wrong-name","path":"/wrong/path","specsUpdated":true,"totals":{"added":1,"modified":0,"removed":0,"renamed":0}}}\n'
            exit 0
        fi
        if [[ "${RUNTIME_ARCHIVE_MODE:-}" == success || "${RUNTIME_ARCHIVE_MODE:-}" == success-source-race ]]; then
            change_name=${command_args[1]:-}
            archived_as="$(date -u +%Y-%m-%d)-$change_name"
            archive_path="$(pwd -P)/openspec/changes/archive/$archived_as"
            if [[ "${RUNTIME_ARCHIVE_MODE:-}" == success-source-race ]]; then
                printf '// source changed by the archive race regression\n' >> src/widget.cpp
            fi
            mv "openspec/changes/$change_name" "$archive_path"
            printf '{"archive":{"change":"%s","archivedAs":"%s","path":"%s","specsUpdated":true,"totals":{"added":1,"modified":0,"removed":0,"renamed":0}}}\n' "$change_name" "$archived_as" "$archive_path"
            exit 0
        fi
        printf 'archive mode was not configured\n' >&2; exit 64
        ;;
    *)
        printf 'unsupported offline OpenSpec command: %s\n' "${command_args[*]}" >&2
        exit 64
        ;;
esac
STUB
chmod 755 "$runtime_bin/npx"
export RUNTIME_REAL_GIT=$system_git
cat > "$runtime_bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${RUNTIME_PREPARED_SOURCE_RACE:-0}" == 1 && "${1:-}" == ls-files && "${2:-}" == -co &&
      -f .ai-harness/archive-transaction.json &&
      ! -e .ai-harness/logs/prepared-source-race.marker ]] &&
   grep -Fq '"status": "prepared"' .ai-harness/archive-transaction.json; then
    printf '// source changed immediately after durable archive preparation\n' >> src/widget.cpp
    : > .ai-harness/logs/prepared-source-race.marker
fi
exec "${RUNTIME_REAL_GIT:?}" "$@"
STUB
chmod 755 "$runtime_bin/git"
export PATH="$runtime_bin:$PATH"

change=widget-output
change_dir="$repo/openspec/changes/$change"
harness_dir="$change_dir/harness"
mkdir -p "$change_dir/specs/widget" "$harness_dir" "$repo/src" "$repo/tests"
printf 'schema: spec-driven\n' > "$change_dir/.openspec.yaml"

cat > "$repo/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(evaluator_lifecycle LANGUAGES CXX)
add_executable(widget src/widget.cpp)
EOF

cat > "$repo/src/widget.cpp" <<'EOF'
#include <iostream>

int main() {
    std::cout << 1 << '\n';
    return 0;
}
EOF

cat > "$repo/tests/widget_behavior.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
actual=$(./build/widget)
if [[ "$actual" != 7 ]]; then
    printf 'expected widget output 7, got %s\n' "$actual" >&2
    exit 1
fi
EOF
chmod 755 "$repo/tests/widget_behavior.sh"

cat > "$change_dir/proposal.md" <<'EOF'
# Change: Print the approved widget value

The executable must print the newly specified value while retaining a zero exit code.
EOF

cat > "$change_dir/specs/widget/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Widget exit behavior

The widget executable SHALL print the approved value and exit successfully.

#### Scenario: Returns seven

- **WHEN** the widget executable is run
- **THEN** standard output is `7` and the process exits with code 0
EOF

cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Implement the approved widget output
  - Covers: `specs/widget/spec.md` | `ADDED` | `Widget exit behavior` | `Returns seven`
  - Verify: `build`, `behavior`
EOF

cat > "$change_dir/design.md" <<'EOF'
# Design

Reuse the existing executable and change only its output value.

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "micro",
  "rationale": "One existing C++ implementation line changes; no new target, API, or dependency is needed.",
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
      "added_lines": {"expected": 2, "review_at": 5, "hard_limit": 10},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 5, "hard_limit": 10},
      "touched_files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 5, "hard_limit": 10},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "bytes": {"expected": 0, "review_at": 1024, "hard_limit": 4096}
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

<!-- autoai:tdd-policy:v1 -->
```json
{
  "schema_version": 1,
  "default": "required",
  "exceptions": []
}
```
<!-- /autoai:tdd-policy:v1 -->
EOF

cat > "$harness_dir/ai_snapshot.json" <<EOF
{
  "schema_version": 3,
  "phase": "planning",
  "planned_base_specs_fingerprint": null,
  "planned_change_fingerprint": null,
  "planned_tdd_policy_sha256": null,
  "planning_approved_at": null,
  "implementation_base_commit": null,
  "adopted_preexisting_paths": [],
  "implementation_baselined_at": null,
  "current_step": "complete planning artifacts",
  "next_step": "strict validate and obtain human review"
}
EOF

cat > "$harness_dir/verification.json" <<EOF
{
  "schema_version": 2,
  "change_name": "$change",
  "migration": null,
  "tasks": []
}
EOF
printf '# Verification — %s\n\n' "$change" > "$harness_dir/verification.md"
printf '# Evaluation history — %s\n\n' "$change" > "$harness_dir/evaluation.md"
printf '# Defect RCA — %s\n\n' "$change" > "$harness_dir/defect-rca.md"

(
    cd "$repo"
    scripts/change_select.sh "$change" >/dev/null
    git config user.name 'AutoAI Evaluator Test'
    git config user.email 'autoai-evaluator@example.invalid'
    git add -A
    git commit -qm 'baseline C++ project and approved OpenSpec change'
    scripts/snapshot_update.sh --freeze-planning-baseline --freeze-implementation-base >/dev/null
)

note '先记录可归因的 RED，再以最小实现完成 GREEN、回归和受控 task 勾选'
(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
    scripts/task_verify.sh 1.1 --phase red --cycle widget-output --kind behavior \
        --expect-exit 1 --path src/widget.cpp --test-path tests/widget_behavior.sh \
        --failure-class behavior --expected-failure 'The baseline prints one instead of the required seven.' \
        --match-output 'expected widget output 7' --observed 'Focused behavior test failed for the specified output mismatch.' -- \
        bash -c 'cmake -S . -B build >/dev/null && cmake --build build --clean-first >/dev/null && tests/widget_behavior.sh'
)
node - "$repo/src/widget.cpp" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const source = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, source.replace('std::cout << 1', 'std::cout << 7'));
NODE

(
    cd "$repo"
    scripts/change_footprint.sh "$change" --json >/dev/null
    scripts/task_verify.sh 1.1 --phase green --cycle widget-output --kind behavior \
        --path src/widget.cpp --observed 'The focused behavior test passed after the minimal output change.' -- \
        bash -c 'cmake -S . -B build >/dev/null && cmake --build build --clean-first >/dev/null && tests/widget_behavior.sh'
    scripts/task_verify.sh 1.1 --phase regression --cycle widget-output --kind build \
        --path src/widget.cpp --observed 'The project rebuilt successfully after GREEN.' -- \
        bash -c 'cmake -S . -B build >/dev/null && cmake --build build --clean-first >/dev/null'
    scripts/task_verify.sh 1.1 --phase regression --cycle widget-output --kind behavior \
        --path src/widget.cpp --observed 'The required runtime behavior remained green.' -- \
        bash tests/widget_behavior.sh
    scripts/task_verify.sh --complete 1.1
)

node - "$harness_dir/change-footprint.json" "$harness_dir/verification.json" <<'NODE'
const fs = require('fs');
const [footprintFile, verificationFile] = process.argv.slice(2);
const footprint = JSON.parse(fs.readFileSync(footprintFile, 'utf8'));
const verification = JSON.parse(fs.readFileSync(verificationFile, 'utf8'));
if (footprint.status !== 'within_expected') throw new Error(`unexpected footprint: ${footprint.status}`);
if (footprint.production.touched_files !== 1 || footprint.production.new_files !== 0) {
  throw new Error('production footprint did not capture exactly one existing file');
}
if (verification.tasks.length !== 1) throw new Error('expected one verified task');
if (!verification.tasks[0].commands.some(c => c.phase === 'RED' && c.result === 'ExpectedFailure')) {
  throw new Error('causal RED evidence missing');
}
const kinds = new Set(verification.tasks[0].commands.filter(c => c.phase === 'REGRESSION' && c.result === 'Pass').map(c => c.kind));
if (!kinds.has('build') || !kinds.has('behavior')) throw new Error('direct build/behavior evidence missing');
NODE

run_runtime_at() {
    local directory=$1
    shift
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$directory" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

run_runtime() {
    run_runtime_at "$repo" "$@"
}

assert_baseline_status() {
    local expected=$1
    node - "$harness_dir/evaluation-baseline.json" "$expected" <<'NODE'
const fs = require('fs');
const [file, expected] = process.argv.slice(2);
const actual = JSON.parse(fs.readFileSync(file, 'utf8')).status;
if (actual !== expected) throw new Error(`expected baseline ${expected}, got ${actual}`);
NODE
}

inject_verification_credential() {
    local directory=$1 bind_baseline=${2:-0}
    local verification_file="$directory/openspec/changes/$change/harness/verification.json"
    local baseline_file="$directory/openspec/changes/$change/harness/evaluation-baseline.json"
    node - "$verification_file" "$baseline_file" "$bind_baseline" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const [verificationFile, baselineFile, bindBaseline] = process.argv.slice(2);
const verification = JSON.parse(fs.readFileSync(verificationFile, 'utf8'));
verification.tasks[0].commands[0].argv = [
  'audit-tool', '--token', 'verification-opaque-credential-7f31'
];
fs.writeFileSync(verificationFile, JSON.stringify(verification, null, 2) + '\n');
if (bindBaseline === '1') {
  const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
  baseline.verification_json_sha256 = 'sha256:' + crypto.createHash('sha256')
    .update(fs.readFileSync(verificationFile)).digest('hex');
  fs.writeFileSync(baselineFile, JSON.stringify(baseline, null, 2) + '\n');
}
NODE
}

assert_credential_rejection() {
    local phase=$1
    assert_status 6
    if [[ "$RUN_OUTPUT" != *credential* && "$RUN_OUTPUT" != *secret* ]]; then
        fail "$phase 未给出 verification credential 拒绝原因"
    fi
}

note '已勾选 task 必须先重新打开，不能直接追加复验证据'
checked_marker="$tmp/checked-task-command-ran"
run_runtime scripts/task_verify.sh 1.1 --kind behavior --path src/widget.cpp -- \
    bash -c "touch '$checked_marker'"
assert_status 6
[[ ! -e "$checked_marker" ]] || fail 'checked task command ran before the task was reopened'

note 'tasks all_done 且尚无 Evaluation 时状态必须进入 awaiting_evaluation'
run_runtime scripts/change_status.sh "$change" --json
assert_status 0
node - "$RUN_OUTPUT" <<'NODE'
const x=JSON.parse(process.argv[2]);if(x.derived_phase!=='awaiting_evaluation')throw Error(`unexpected pre-Evaluation phase: ${x.derived_phase}`);
NODE

note 'Evaluation evidence 路径为符号链接时在建立 baseline 前拒绝'
mv "$harness_dir/evaluation.md" "$tmp/evaluation-history.saved"
ln -s "$tmp/evaluation-history.saved" "$harness_dir/evaluation.md"
run_runtime scripts/evaluator_check.sh --begin "$change"
assert_status 6
[[ ! -e "$harness_dir/evaluation-baseline.json" ]] || fail 'unsafe evidence path still created an Evaluation baseline'
rm -f "$harness_dir/evaluation.md"
mv "$tmp/evaluation-history.saved" "$harness_dir/evaluation.md"

note 'Generator command 的 finished_at 早于 started_at 时不能进入 Evaluation'
cp -p "$harness_dir/verification.json" "$tmp/verification.timestamp.saved"
node - "$harness_dir/verification.json" <<'NODE'
const fs=require('fs'),f=process.argv[2],d=JSON.parse(fs.readFileSync(f));d.tasks[0].commands[0].finished_at='2000-01-01T00:00:00Z';fs.writeFileSync(f,JSON.stringify(d,null,2)+'\n');
NODE
run_runtime scripts/evaluator_check.sh --begin "$change"
assert_status 6
assert_contains "$RUN_OUTPUT" 'Generator verification is incomplete or untraceable'
mv "$tmp/verification.timestamp.saved" "$harness_dir/verification.json"

note 'task 的历史 footprint observation 不必伪装成最终 footprint 状态'
node - "$harness_dir/verification.json" <<'NODE'
const fs=require('fs'),f=process.argv[2],d=JSON.parse(fs.readFileSync(f));d.tasks[0].footprint_observation={status:'drift_warning',drift_reason:'Historical task-time observation retained independently from the final footprint.'};fs.writeFileSync(f,JSON.stringify(d,null,2)+'\n');
NODE

note '手工注入分离式 credential argv 时 Evaluator begin 在建立 baseline 前拒绝'
credential_begin_repo="$tmp/verification credential begin project"
cp -a -- "$repo" "$credential_begin_repo"
inject_verification_credential "$credential_begin_repo"
credential_begin_root_sha=$(sha256sum -- "$credential_begin_repo/ai_snapshot.json" | awk '{print $1}')
run_runtime_at "$credential_begin_repo" scripts/evaluator_check.sh --begin "$change"
assert_credential_rejection 'Evaluator begin'
assert_path_absent "$credential_begin_repo/openspec/changes/$change/harness/evaluation-baseline.json"
[[ "$credential_begin_root_sha" == "$(sha256sum -- "$credential_begin_repo/ai_snapshot.json" | awk '{print $1}')" ]] || \
    fail 'credential begin rejection 改写了根 snapshot'

note 'Evaluator begin 冻结所有输入指纹与证据 digest'
run_runtime scripts/evaluator_check.sh --begin "$change"
assert_status 0
assert_contains "$RUN_OUTPUT" 'Evaluation started:'
assert_baseline_status in_progress

note '同一 attempt 不能重复 begin；abort 保留历史后可创建全新 attempt'
abort_repo="$tmp/abort and retry project"
cp -a -- "$repo" "$abort_repo"
abort_harness="$abort_repo/openspec/changes/$change/harness"
first_attempt=$(node -p \
    "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" \
    "$abort_harness/evaluation-baseline.json")
first_baseline_sha=$(sha256sum -- "$abort_harness/evaluation-baseline.json" | awk '{print $1}')
run_runtime_at "$abort_repo" scripts/evaluator_check.sh --begin "$change"
assert_status 6
assert_contains "$RUN_OUTPUT" 'evaluation already in progress'
[[ "$(sha256sum -- "$abort_harness/evaluation-baseline.json" | awk '{print $1}')" == "$first_baseline_sha" ]] || \
    fail '重复 begin 改写了已在进行的 Evaluation baseline'

abort_reason='Independent environment unavailable; retry after recovery.'
run_runtime_at "$abort_repo" scripts/evaluator_check.sh --abort "$change" --reason "$abort_reason"
assert_status 0
assert_contains "$RUN_OUTPUT" 'Evaluation aborted.'
node - "$abort_harness/evaluation-baseline.json" "$abort_harness/evaluation.md" \
    "$first_attempt" "$abort_reason" <<'NODE'
const fs = require('fs');
const [baselineFile, historyFile, firstAttempt, reason] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const history = fs.readFileSync(historyFile, 'utf8');
if (baseline.status !== 'aborted' || baseline.evaluation_id !== firstAttempt ||
    baseline.reason !== reason || !Number.isFinite(Date.parse(baseline.aborted_at))) {
  throw new Error('abort did not preserve a valid terminal attempt baseline');
}
if (!history.includes(`## ${firstAttempt} — Aborted`) || !history.includes(`- Reason: ${reason}`)) {
  throw new Error('aborted attempt was not retained in Evaluation history');
}
NODE

note '终态恰好位于五分钟容差边界时，+1ms 新 attempt 必须在任何 Evaluation 状态写入前拒绝'
boundary_repo="$tmp/evaluation clock boundary project"
cp -a -- "$abort_repo" "$boundary_repo"
boundary_harness="$boundary_repo/openspec/changes/$change/harness"
fixed_now=$(node -p 'Date.now()')
node - "$boundary_harness/evaluation-baseline.json" "$boundary_harness/evaluations" "$fixed_now" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const [baselineFile,historyDir,fixedRaw]=process.argv.slice(2),fixed=Number(fixedRaw);
const baseline=JSON.parse(fs.readFileSync(baselineFile)),historyFile=path.join(historyDir,baseline.evaluation_id+'.json');
const envelope=JSON.parse(fs.readFileSync(historyFile));
const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(',')}]`:
  value&&typeof value==='object'?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`:
  JSON.stringify(value);
baseline.aborted_at=new Date(fixed+300000).toISOString();
envelope.baseline=baseline;
envelope.baseline_sha256='sha256:'+crypto.createHash('sha256').update(canonical(baseline)).digest('hex');
envelope.sealed_at=baseline.aborted_at;
fs.writeFileSync(baselineFile,JSON.stringify(baseline,null,2)+'\n');
fs.writeFileSync(historyFile,JSON.stringify(envelope,null,2)+'\n');
NODE
boundary_state_before=$(sha256sum -- \
    "$boundary_harness/evaluation-baseline.json" \
    "$boundary_harness/evaluation-command-ledger.json" \
    "$boundary_harness/evaluation.md" \
    "$boundary_harness/evaluations"/*.json \
    "$boundary_repo/ai_snapshot.json")
run_runtime_at "$boundary_repo" env \
    AUTOAI_TEST_NOW_MS="$fixed_now" NODE_OPTIONS="--require=$fixed_clock" \
    scripts/evaluator_check.sh --begin "$change"
assert_status 6
assert_contains "$RUN_OUTPUT" 'clock tolerance'
boundary_state_after=$(sha256sum -- \
    "$boundary_harness/evaluation-baseline.json" \
    "$boundary_harness/evaluation-command-ledger.json" \
    "$boundary_harness/evaluation.md" \
    "$boundary_harness/evaluations"/*.json \
    "$boundary_repo/ai_snapshot.json")
[[ "$boundary_state_before" == "$boundary_state_after" ]] || \
    fail 'clock-boundary rejection modified Evaluation state'

note '只有 terminal history 残留而 direct predecessor baseline 缺失时 begin 必须 fail closed'
orphan_history_repo="$tmp/orphan evaluation history project"
cp -a -- "$abort_repo" "$orphan_history_repo"
orphan_harness="$orphan_history_repo/openspec/changes/$change/harness"
rm -f -- "$orphan_harness/evaluation-baseline.json" "$orphan_harness/evaluation-command-ledger.json" "$orphan_harness/evaluation.json"
orphan_history_before=$(sha256sum -- "$orphan_harness/evaluation.md" "$orphan_harness/evaluations"/*.json "$orphan_history_repo/ai_snapshot.json")
run_runtime_at "$orphan_history_repo" scripts/evaluator_check.sh --begin "$change"
assert_status 6
assert_contains "$RUN_OUTPUT" 'without a direct predecessor baseline'
assert_path_absent "$orphan_harness/evaluation-baseline.json"
assert_path_absent "$orphan_harness/evaluation-command-ledger.json"
orphan_history_after=$(sha256sum -- "$orphan_harness/evaluation.md" "$orphan_harness/evaluations"/*.json "$orphan_history_repo/ai_snapshot.json")
[[ "$orphan_history_before" == "$orphan_history_after" ]] || \
    fail 'orphan-history rejection modified retained Evaluation state'

note 'current terminal baseline 不是全历史最新终态时 begin 必须拒绝，不能从旧前驱分叉'
nonlatest_repo="$tmp/nonlatest evaluation predecessor project"
cp -a -- "$abort_repo" "$nonlatest_repo"
nonlatest_harness="$nonlatest_repo/openspec/changes/$change/harness"
node - "$nonlatest_harness/evaluation-baseline.json" "$nonlatest_harness/evaluations" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const [baselineFile,historyDir]=process.argv.slice(2),current=JSON.parse(fs.readFileSync(baselineFile));
const source=JSON.parse(fs.readFileSync(path.join(historyDir,current.evaluation_id+'.json')));
const id='eval-20990101T000000Z-acde12',terminal=new Date(Date.now()+120000).toISOString();
source.evaluation_id=id;
source.sealed_at=terminal;
source.baseline={...source.baseline,evaluation_id:id,aborted_at:terminal};
const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(',')}]`:
  value&&typeof value==='object'?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`:
  JSON.stringify(value);
source.baseline_sha256='sha256:'+crypto.createHash('sha256').update(canonical(source.baseline)).digest('hex');
fs.writeFileSync(path.join(historyDir,id+'.json'),JSON.stringify(source,null,2)+'\n',{mode:0o644,flag:'wx'});
NODE
nonlatest_before=$(sha256sum -- \
    "$nonlatest_harness/evaluation-baseline.json" \
    "$nonlatest_harness/evaluation-command-ledger.json" \
    "$nonlatest_harness/evaluation.md" \
    "$nonlatest_harness/evaluations"/*.json \
    "$nonlatest_repo/ai_snapshot.json")
run_runtime_at "$nonlatest_repo" scripts/evaluator_check.sh --begin "$change"
assert_status 6
assert_contains "$RUN_OUTPUT" 'unique latest terminal predecessor'
nonlatest_after=$(sha256sum -- \
    "$nonlatest_harness/evaluation-baseline.json" \
    "$nonlatest_harness/evaluation-command-ledger.json" \
    "$nonlatest_harness/evaluation.md" \
    "$nonlatest_harness/evaluations"/*.json \
    "$nonlatest_repo/ai_snapshot.json")
[[ "$nonlatest_before" == "$nonlatest_after" ]] || \
    fail 'nonlatest-predecessor rejection modified Evaluation state'

note '两个不同 terminal envelope 具有相同终态时间时 begin 必须拒绝歧义前驱'
tied_history_repo="$tmp/tied evaluation predecessor project"
cp -a -- "$abort_repo" "$tied_history_repo"
tied_harness="$tied_history_repo/openspec/changes/$change/harness"
node - "$tied_harness/evaluation-baseline.json" "$tied_harness/evaluations" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const [baselineFile,historyDir]=process.argv.slice(2),current=JSON.parse(fs.readFileSync(baselineFile));
const currentFile=path.join(historyDir,current.evaluation_id+'.json'),source=JSON.parse(fs.readFileSync(currentFile));
const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(',')}]`:
  value&&typeof value==='object'?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`:
  JSON.stringify(value);
const originalTerminal=source.sealed_at,later=new Date(Date.now()+120000).toISOString();
current.aborted_at=later;
source.sealed_at=later;
source.baseline=current;
source.baseline_sha256='sha256:'+crypto.createHash('sha256').update(canonical(current)).digest('hex');
fs.writeFileSync(baselineFile,JSON.stringify(current,null,2)+'\n');
fs.writeFileSync(currentFile,JSON.stringify(source,null,2)+'\n');
for (const id of ['eval-20990101T000000Z-beef12','eval-20990101T000000Z-cafe12']) {
  const tied=structuredClone(source);
  tied.evaluation_id=id;
  tied.sealed_at=originalTerminal;
  tied.baseline={...tied.baseline,evaluation_id:id,aborted_at:originalTerminal};
  tied.baseline_sha256='sha256:'+crypto.createHash('sha256').update(canonical(tied.baseline)).digest('hex');
  fs.writeFileSync(path.join(historyDir,id+'.json'),JSON.stringify(tied,null,2)+'\n',{mode:0o644,flag:'wx'});
}
NODE
tied_before=$(sha256sum -- \
    "$tied_harness/evaluation-baseline.json" \
    "$tied_harness/evaluation-command-ledger.json" \
    "$tied_harness/evaluation.md" \
    "$tied_harness/evaluations"/*.json \
    "$tied_history_repo/ai_snapshot.json")
run_runtime_at "$tied_history_repo" scripts/evaluator_check.sh --begin "$change"
assert_status 6
assert_contains "$RUN_OUTPUT" 'terminal'
tied_after=$(sha256sum -- \
    "$tied_harness/evaluation-baseline.json" \
    "$tied_harness/evaluation-command-ledger.json" \
    "$tied_harness/evaluation.md" \
    "$tied_harness/evaluations"/*.json \
    "$tied_history_repo/ai_snapshot.json")
[[ "$tied_before" == "$tied_after" ]] || \
    fail 'tied-predecessor rejection modified Evaluation state'

run_runtime_at "$abort_repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
assert_contains "$RUN_OUTPUT" 'Evaluation started:'
node - "$abort_harness/evaluation-baseline.json" "$abort_harness/evaluation.md" \
    "$abort_harness/evaluations/$first_attempt.json" "$first_attempt" "$abort_reason" <<'NODE'
const fs = require('fs');
const [baselineFile, historyFile, envelopeFile, firstAttempt, reason] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const history = fs.readFileSync(historyFile, 'utf8');
const predecessor = JSON.parse(fs.readFileSync(envelopeFile, 'utf8')).baseline;
if (baseline.status !== 'in_progress' || baseline.evaluation_id === firstAttempt) {
  throw new Error('begin after abort did not create a distinct in-progress attempt');
}
if (Date.parse(baseline.started_at) <= Date.parse(predecessor.aborted_at)) {
  throw new Error('begin after abort did not advance strictly beyond its terminal predecessor');
}
if (!history.includes(`## ${firstAttempt} — Aborted`) || !history.includes(`- Reason: ${reason}`)) {
  throw new Error('new attempt discarded the prior aborted-attempt history');
}
NODE

note 'Evaluation baseline 是 closed schema，未知字段不能穿过 finish/recheck'
cp -p "$harness_dir/evaluation-baseline.json" "$tmp/evaluation-baseline.closed.saved"
node - "$harness_dir/evaluation-baseline.json" <<'NODE'
const fs=require('fs'),f=process.argv[2],d=JSON.parse(fs.readFileSync(f));d.unexpected='forbidden';fs.writeFileSync(f,JSON.stringify(d,null,2)+'\n');
NODE
run_runtime scripts/evaluator_check.sh --finish "$change"
assert_status 6
assert_contains "$RUN_OUTPUT" 'baseline closed schema is invalid'
mv "$tmp/evaluation-baseline.closed.saved" "$harness_dir/evaluation-baseline.json"

write_evaluation() {
    local mode=$1
    node - "$harness_dir/evaluation-baseline.json" "$harness_dir/change-footprint.json" \
        "$harness_dir/evaluation-command-ledger.json" "$harness_dir/evaluation.json" \
        "$change" "$mode" <<'NODE'
const fs = require('fs');
const [baselineFile, footprintFile, ledgerFile, outputFile, change, mode] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const footprint = JSON.parse(fs.readFileSync(footprintFile, 'utf8'));
const ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
const requirementRef = {
  spec_path: 'specs/widget/spec.md',
  operation: 'ADDED',
  requirement: 'Widget exit behavior',
  scenarios: ['Returns seven']
};
if (ledger.schema_version!==1 || ledger.evaluation_id!==baseline.evaluation_id ||
    ledger.change_name!==change || !Array.isArray(ledger.commands) || !ledger.commands.length) {
  throw new Error('managed Evaluation command ledger does not match the active attempt');
}
const commands = [...ledger.commands];
const evidenceFinished = Math.max(Date.parse(baseline.started_at), ...commands.map(item=>Date.parse(item.finished_at)));
const reportObservedAt = Date.now();
if (!Number.isFinite(evidenceFinished) || evidenceFinished>reportObservedAt+1000) {
  throw new Error(`managed command timestamps extend beyond report creation tolerance: evidence=${evidenceFinished}, report=${reportObservedAt}, delta_ms=${evidenceFinished-reportObservedAt}`);
}
const evaluated = new Date(Math.max(reportObservedAt, evidenceFinished)).toISOString();
const reviewBoundary = new Date(evidenceFinished).toISOString();
const evidenceIds = commands
  .filter(command => !(mode==='orphan-command' && command.kind==='static'))
  .map(command => command.id);
const reviewStage = (name, stageStarted, stageFinished, dimensions) => ({
  name,
  started_at: stageStarted,
  completed_at: stageFinished,
  status: 'Pass',
  requirement_refs: [requirementRef],
  task_ids: ['1.1'],
  reviewed_paths: baseline.review_input.review_paths,
  dimensions,
  evidence_command_ids: evidenceIds,
  finding_ids: [],
  blocking_untested_ids: [],
  not_run_reason: null
});
const evaluation = {
  schema_version: 2,
  evaluation_id: baseline.evaluation_id,
  change_name: change,
  verdict: 'Pass',
  evaluation_started_at: baseline.started_at,
  evaluated_at: evaluated,
  openspec_version: '1.6.0',
  evaluator_role: 'independent',
  input_source_fingerprint: baseline.source_fingerprint,
  input_artifact_fingerprint: baseline.artifact_fingerprint,
  input_base_specs_fingerprint: baseline.base_specs_fingerprint,
  source_fingerprint: baseline.source_fingerprint,
  artifact_fingerprint: baseline.artifact_fingerprint,
  base_specs_fingerprint: baseline.base_specs_fingerprint,
  budget_block_sha256: baseline.budget_block_sha256,
  change_footprint_json_sha256: baseline.change_footprint_json_sha256,
  review_input: baseline.review_input,
  change_review: {
    schema_version: 1,
    git_state_fingerprint: baseline.review_input.git_state_fingerprint,
    stages: [
      reviewStage('specification_compliance', baseline.started_at, reviewBoundary,
        ['requirements', 'scenarios', 'scope', 'contracts', 'traceability']),
      reviewStage('code_quality', reviewBoundary, evaluated,
        ['correctness', 'safety', 'regression_risk', 'reuse', 'complexity', 'test_quality', 'repository_impact'])
    ],
    findings: []
  },
  implementation_economy: {
    footprint_status: footprint.status,
    drift_explanation: null,
    classification_assessment: {
      result: mode === 'fake-aggregate' ? 'Fail' : 'Pass',
      reason: 'The single production path matches the approved classification.',
      evidence_paths: mode === 'fake-classification-gap' ? [] : ['src/widget.cpp'],
      evidence_command_ids: evidenceIds
    },
    repository_impact_assessment: {
      result: 'Pass',
      surfaces: [
        {
          surface: 'product_targets', applicability: 'applicable', result: 'Pass',
          reason: 'The existing widget target builds and executes.',
          evidence_paths: ['src/widget.cpp'], evidence_command_ids: evidenceIds,
          not_applicable_reason: null
        },
        {
          surface: 'install', applicability: 'not_applicable', result: null,
          reason: 'The fixture has no install surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No install rule exists in the baseline project.'
        },
        {
          surface: 'package', applicability: 'not_applicable', result: null,
          reason: 'The fixture has no package surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No package configuration exists in the baseline project.'
        },
        {
          surface: 'ci', applicability: 'not_applicable', result: null,
          reason: 'The fixture has no CI surface.', evidence_paths: [], evidence_command_ids: [],
          not_applicable_reason: 'No CI configuration exists in the baseline project.'
        }
      ]
    },
    reuse_assessments: [],
    structural_assessments: [],
    obsolete_item_assessments: [],
    exception_assessments: [],
    result: 'Pass'
  },
  criteria: [{
    id: 'criterion-widget-output',
    description: 'The existing widget target builds and prints seven. Opaque evaluation narrative: eval-private-47f66c23.',
    requirement_refs: [requirementRef],
    task_ids: ['1.1'],
    status: 'Pass',
    evidence_command_ids: mode === 'dangling-criterion' ? ['missing-command'] : evidenceIds,
    blocking_untested_ids: []
  }],
  commands,
  blocking_untested: [],
  residual_risks: []
};
fs.writeFileSync(outputFile, JSON.stringify(evaluation, null, 2) + '\n');
NODE
}

assert_finish_rejected() {
    local label=$1
    run_runtime scripts/evaluator_check.sh --finish "$change"
    [[ "$RUN_STATUS" -ne 0 ]] || fail "$label 应被 Evaluator 拒绝"
    assert_baseline_status in_progress
}

note '只记录一条受管 static 命令，用于验证缺少可执行证据的真实门禁'
run_runtime scripts/evaluator_check.sh --run \
    --kind static \
    --expected 'The repository diff is whitespace-clean.' \
    --observed 'git diff --check exited successfully.' \
    -- git diff --check
assert_status 0

note '伪 Pass：只有静态检查，缺少 executable evidence，不能完成 Evaluation'
write_evaluation static-only
assert_finish_rejected 'static-only Pass'

note '中止 static-only attempt，在新 attempt 中记录受管 build 和 behavior 命令'
run_runtime scripts/evaluator_check.sh --abort "$change" \
    --reason 'Static-only negative probe completed; start the executable-evidence attempt.'
assert_status 0
run_runtime scripts/evaluator_check.sh --begin "$change"
assert_status 0
run_runtime scripts/evaluator_check.sh --run \
    --kind build \
    --expected 'CMake build exits with code 0.' \
    --observed 'CMake build exited with code 0.' \
    -- cmake --build build
assert_status 0
run_runtime scripts/evaluator_check.sh --run \
    --kind behavior \
    --expected 'The widget prints seven and exits with code 0.' \
    --observed 'The widget printed seven and exited with code 0.' \
    -- bash -c 'test "$(./build/widget)" = 7'
assert_status 0

note '伪 Pass：criterion 引用不存在的命令，不能完成 Evaluation'
write_evaluation dangling-criterion
assert_finish_rejected 'dangling criterion Pass'

run_runtime scripts/evaluator_check.sh --run \
    --kind static \
    --expected 'The repository diff is whitespace-clean.' \
    --observed 'git diff --check exited successfully.' \
    -- git diff --check
assert_status 0

note '伪 Pass：未被任何 criterion 或 economy assessment 引用的孤儿命令不能混入报告'
write_evaluation orphan-command
assert_finish_rejected 'orphan Evaluation command'

note '伪 Pass：子评估为 Fail 却聚合成 Pass，不能完成 Evaluation'
write_evaluation fake-aggregate
assert_finish_rejected 'fake aggregate Pass'

note '伪 Pass：classification assessment 漏掉实施路径时不能完成 Evaluation'
write_evaluation fake-classification-gap
assert_finish_rejected 'classification path gap'

note 'begin 后源代码或 verification 变化会让旧 attempt 失效，恢复字节后才能继续'
cp "$repo/src/widget.cpp" "$tmp/widget.cpp.saved"
printf '// stale attempt probe\n' >> "$repo/src/widget.cpp"
write_evaluation valid
assert_finish_rejected 'source fingerprint drift'
mv "$tmp/widget.cpp.saved" "$repo/src/widget.cpp"

cp "$harness_dir/verification.json" "$tmp/verification.json.saved"
printf ' ' >> "$harness_dir/verification.json"
write_evaluation valid
assert_finish_rejected 'verification digest drift'
mv "$tmp/verification.json.saved" "$harness_dir/verification.json"

note '独立重复执行真实 build/behavior 后，closed 合法 Pass 完成并绑定 digest'
(
    cd "$repo"
    cmake --build build >/dev/null
    [[ $(./build/widget) == 7 ]]
)
write_evaluation valid
credential_finish_repo="$tmp/verification credential finish project"
cp -a -- "$repo" "$credential_finish_repo"
inject_verification_credential "$credential_finish_repo" 1
credential_finish_history_sha=$(sha256sum -- "$credential_finish_repo/openspec/changes/$change/harness/evaluation.md" | awk '{print $1}')
run_runtime_at "$credential_finish_repo" scripts/evaluator_check.sh --finish "$change"
assert_credential_rejection 'Evaluator finish'
node - "$credential_finish_repo/openspec/changes/$change/harness/evaluation-baseline.json" <<'NODE'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2]));if(d.status!=='in_progress')throw Error('credential-rejected finish completed the Evaluation baseline');
NODE
[[ "$credential_finish_history_sha" == "$(sha256sum -- "$credential_finish_repo/openspec/changes/$change/harness/evaluation.md" | awk '{print $1}')" ]] || \
    fail 'credential finish rejection 追加了 Evaluation history'

fail_repo="$tmp/valid Fail evaluation project"
blocked_repo="$tmp/valid Blocked evaluation project"
cp -a -- "$repo" "$fail_repo"
cp -a -- "$repo" "$blocked_repo"

node - "$fail_repo/openspec/changes/$change/harness/evaluation.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const evaluation = JSON.parse(fs.readFileSync(file, 'utf8'));
evaluation.verdict = 'Fail';
evaluation.criteria[0].status = 'Fail';
fs.writeFileSync(file, JSON.stringify(evaluation, null, 2) + '\n');
NODE

node - "$blocked_repo/openspec/changes/$change/harness/evaluation.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const evaluation = JSON.parse(fs.readFileSync(file, 'utf8'));
const requirementRefs = evaluation.criteria[0].requirement_refs;
evaluation.verdict = 'Blocked';
evaluation.criteria[0].status = 'Blocked';
evaluation.criteria[0].blocking_untested_ids = ['blocked-widget-runtime'];
evaluation.blocking_untested = [{
  id: 'blocked-widget-runtime',
  requirement_refs: requirementRefs,
  task_ids: ['1.1'],
  reason: 'The independent runtime environment became unavailable before the final acceptance observation.',
  required_evidence: ['Repeat the executable behavior check in the independent runtime environment.']
}];
fs.writeFileSync(file, JSON.stringify(evaluation, null, 2) + '\n');
NODE

secret_repo="$tmp/evaluator free-text secret project"
cp -a -- "$repo" "$secret_repo"
node - "$secret_repo/openspec/changes/$change/harness/evaluation.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const evaluation = JSON.parse(fs.readFileSync(file, 'utf8'));
evaluation.criteria[0].description = 'Authorization: Bearer evaluator-free-text-0f5cc8';
evaluation.implementation_economy.repository_impact_assessment.surfaces[0].reason =
  'X-API-Key: evaluator-free-text-117c48';
evaluation.residual_risks = [{
  id: 'risk-free-text-secret',
  impact: 'Cookie: session=evaluator-free-text-49c1ab',
  rationale: 'This deliberately probes recursive secret detection outside command fields.'
}];
fs.writeFileSync(file, JSON.stringify(evaluation, null, 2) + '\n');
NODE
run_runtime scripts/evaluator_check.sh --finish "$change"
assert_status 0
assert_contains "$RUN_OUTPUT" 'Evaluation completed: Pass'
assert_baseline_status complete

node - "$harness_dir/evaluation-baseline.json" "$harness_dir/evaluation.json" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const [baselineFile, evaluationFile] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile, 'utf8'));
const digest = 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(evaluationFile)).digest('hex');
if (baseline.evaluation_json_sha256 !== digest) throw new Error('completed baseline is not bound to evaluation.json');
if (evaluation.verdict !== 'Pass' || evaluation.implementation_economy.result !== 'Pass') {
  throw new Error('valid Evaluation did not preserve Pass aggregates');
}
NODE

note '已 complete 的 Pass 也不能在 verification argv 含分离 credential 时通过 recheck/archive'
credential_recheck_repo="$tmp/verification credential recheck project"
credential_archive_repo="$tmp/verification credential archive project"
cp -a -- "$repo" "$credential_recheck_repo"
cp -a -- "$repo" "$credential_archive_repo"
inject_verification_credential "$credential_recheck_repo" 1
inject_verification_credential "$credential_archive_repo" 1
credential_recheck_root_sha=$(sha256sum -- "$credential_recheck_repo/ai_snapshot.json" | awk '{print $1}')
credential_recheck_baseline_sha=$(sha256sum -- "$credential_recheck_repo/openspec/changes/$change/harness/evaluation-baseline.json" | awk '{print $1}')
run_runtime_at "$credential_recheck_repo" scripts/evaluator_check.sh --recheck "$change"
assert_credential_rejection 'Evaluator complete recheck'
[[ "$credential_recheck_root_sha" == "$(sha256sum -- "$credential_recheck_repo/ai_snapshot.json" | awk '{print $1}')" ]] || \
    fail 'credential recheck rejection 改写了根 snapshot'
[[ "$credential_recheck_baseline_sha" == "$(sha256sum -- "$credential_recheck_repo/openspec/changes/$change/harness/evaluation-baseline.json" | awk '{print $1}')" ]] || \
    fail 'credential recheck rejection 改写了 complete baseline'

stable_files=(
    "$harness_dir/evaluation-baseline.json"
    "$harness_dir/evaluation.json"
    "$harness_dir/evaluation.md"
    "$repo/ai_snapshot.json"
)
before="$tmp/completed-files.before"
after="$tmp/completed-files.after"
for file in "${stable_files[@]}"; do
    printf '%s\t%s\t%s\n' "${file#"$repo/"}" "$(sha256sum -- "$file" | awk '{print $1}')" "$(stat -c '%y' -- "$file")"
done > "$before"
sleep 1
run_runtime scripts/evaluator_check.sh --finish "$change"
assert_status 0
assert_contains "$RUN_OUTPUT" 'Completed Evaluation remains valid.'
for file in "${stable_files[@]}"; do
    printf '%s\t%s\t%s\n' "${file#"$repo/"}" "$(sha256sum -- "$file" | awk '{print $1}')" "$(stat -c '%y' -- "$file")"
done > "$after"
assert_files_equal "$before" "$after"

legacy_complete_repo="$tmp/live legacy v1 complete project"
cp -a -- "$repo" "$legacy_complete_repo"
legacy_harness="$legacy_complete_repo/openspec/changes/$change/harness"
node - "$legacy_harness/ai_snapshot.json" "$legacy_harness/verification.json" \
    "$legacy_harness/evaluation-baseline.json" "$legacy_harness/evaluation.json" \
    "$legacy_harness/evaluation-command-ledger.json" "$legacy_harness/evaluations" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const [snapshotFile,verificationFile,baselineFile,evaluationFile,ledgerFile,evaluationsDir]=process.argv.slice(2);
const snapshot=JSON.parse(fs.readFileSync(snapshotFile)),verification=JSON.parse(fs.readFileSync(verificationFile)),baseline=JSON.parse(fs.readFileSync(baselineFile)),evaluation=JSON.parse(fs.readFileSync(evaluationFile));
const legacyGeneratorCommand=command=>({
  id:command.id,kind:command.kind,argv:command.argv,working_directory:command.working_directory,
  started_at:command.started_at,finished_at:command.finished_at,
  expected_exit_codes:command.expected_exit_codes,exit_code:command.exit_code,result:command.result
});
const legacyEvaluationCommand=command=>({
  id:command.id,kind:command.kind,command:command.command,working_directory:command.working_directory,
  started_at:command.started_at,finished_at:command.finished_at,
  expected_exit_codes:command.expected_exit_codes,exit_code:command.exit_code,
  expected:command.expected,observed:command.observed,result:command.result
});
const legacySnapshot={
  schema_version:2,phase:snapshot.phase,planned_base_specs_fingerprint:snapshot.planned_base_specs_fingerprint,
  implementation_base_commit:snapshot.implementation_base_commit,
  adopted_preexisting_paths:snapshot.adopted_preexisting_paths,
  implementation_baselined_at:snapshot.implementation_baselined_at,
  current_step:snapshot.current_step,next_step:snapshot.next_step
};
const legacyVerification={schema_version:1,change_name:verification.change_name,tasks:verification.tasks.map(task=>({
  task_id:task.task_id,requirement_refs:task.requirement_refs,changed_paths:task.changed_paths,
  footprint_observation:task.footprint_observation,
  commands:task.commands.filter(command=>command.phase==='REGRESSION'&&command.result==='Pass').map(legacyGeneratorCommand)
}))};
const legacyEvaluation={...evaluation,schema_version:1,commands:evaluation.commands.map(legacyEvaluationCommand)};
delete legacyEvaluation.review_input;delete legacyEvaluation.change_review;
const write=(file,value)=>fs.writeFileSync(file,JSON.stringify(value,null,2)+'\n'),digest=file=>'sha256:'+crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
write(snapshotFile,legacySnapshot);write(verificationFile,legacyVerification);write(evaluationFile,legacyEvaluation);
const legacyBaseline={...baseline,schema_version:1};delete legacyBaseline.review_input;
legacyBaseline.verification_json_sha256=digest(verificationFile);legacyBaseline.evaluation_json_sha256=digest(evaluationFile);
write(baselineFile,legacyBaseline);
fs.rmSync(ledgerFile);fs.rmSync(evaluationsDir,{recursive:true});
NODE

partial_repo="$tmp/partial-move archive project"
post_strict_repo="$tmp/post-strict archive project"
symlink_repo="$tmp/dangling-target archive project"
wrong_json_repo="$tmp/wrong-json archive project"
success_repo="$tmp/success archive project"
source_race_repo="$tmp/source-race archive project"
prepared_race_repo="$tmp/prepared-source-race archive project"
prepared_interrupt_repo="$tmp/prepared-interrupt archive project"
tasks_incomplete_repo="$tmp/tasks-incomplete archive project"
stale_repo="$tmp/stale-pass archive project"
cp -a -- "$repo" "$partial_repo"
cp -a -- "$repo" "$post_strict_repo"
cp -a -- "$repo" "$symlink_repo"
cp -a -- "$repo" "$wrong_json_repo"
cp -a -- "$repo" "$success_repo"
cp -a -- "$repo" "$source_race_repo"
cp -a -- "$repo" "$prepared_race_repo"
cp -a -- "$repo" "$prepared_interrupt_repo"
cp -a -- "$repo" "$tasks_incomplete_repo"
cp -a -- "$repo" "$stale_repo"
sed -i 's/^- \[x\] 1\.1 /- [ ] 1.1 /' "$tasks_incomplete_repo/openspec/changes/$change/tasks.md"
printf '// stale archived Pass probe\n' >> "$stale_repo/src/widget.cpp"

run_archive_at() {
    local directory=$1 mode=$2 post_fail=${3:-0} prepared_race=${4:-0}
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$directory" && RUNTIME_ARCHIVE_MODE="$mode" \
        RUNTIME_POST_ARCHIVE_VALIDATE_FAIL="$post_fail" \
        RUNTIME_PREPARED_SOURCE_RACE="$prepared_race" \
        scripts/change_archive.sh "$change" 2>&1)
    RUN_STATUS=$?
    set -e
}

note 'live schema v1 complete Evaluation 可按原证据只读 recheck 并归档，不隐式生成 ledger/envelope'
legacy_files=(
    "$legacy_harness/ai_snapshot.json"
    "$legacy_harness/verification.json"
    "$legacy_harness/evaluation-baseline.json"
    "$legacy_harness/evaluation.json"
    "$legacy_harness/evaluation.md"
)
legacy_before="$tmp/legacy-v1.before"
for file in "${legacy_files[@]}"; do printf '%s\t%s\t%s\n' "${file#"$legacy_complete_repo/"}" "$(sha256sum -- "$file" | awk '{print $1}')" "$(stat -c '%y' -- "$file")"; done > "$legacy_before"
run_runtime_at "$legacy_complete_repo" scripts/evaluator_check.sh --recheck "$change"
assert_status 0
assert_contains "$RUN_OUTPUT" 'Completed legacy Evaluation v1 remains valid.'
assert_path_absent "$legacy_harness/evaluation-command-ledger.json"
assert_path_absent "$legacy_harness/evaluations"
legacy_after="$tmp/legacy-v1.after"
for file in "${legacy_files[@]}"; do printf '%s\t%s\t%s\n' "${file#"$legacy_complete_repo/"}" "$(sha256sum -- "$file" | awk '{print $1}')" "$(stat -c '%y' -- "$file")"; done > "$legacy_after"
assert_files_equal "$legacy_before" "$legacy_after"
run_archive_at "$legacy_complete_repo" success
assert_status 0
legacy_archive="$legacy_complete_repo/openspec/changes/archive/$(date -u +%Y-%m-%d)-$change"
assert_path_exists "$legacy_archive/harness/evaluation.json"
assert_path_absent "$legacy_archive/harness/evaluation-command-ledger.json"
assert_path_absent "$legacy_archive/harness/evaluations"
node - "$legacy_before" "$legacy_archive" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');const [manifest,archive]=process.argv.slice(2);
for(const line of fs.readFileSync(manifest,'utf8').trim().split('\n')){const [relative,expected]=line.split('\t'),file=path.join(archive,relative.replace(/^openspec\/changes\/[^/]+\//,'')),actual=crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');if(actual!==expected)throw Error('legacy archive rewrote '+relative)}
NODE

assert_pre_cli_archive_rejection() {
    local directory=$1 root_sha=$2 calls_before=$3 label=$4 calls_after
    assert_status 6
    calls_after=$(grep -c 'openspec archive ' "$runtime_log" || true)
    [[ "$calls_after" -eq "$calls_before" ]] || fail "$label 被拒绝后仍调用了 OpenSpec archive CLI"
    [[ "$root_sha" == "$(sha256sum -- "$directory/ai_snapshot.json" | awk '{print $1}')" ]] || \
        fail "$label 在 archive CLI 前拒绝时改写了根 snapshot"
    assert_path_exists "$directory/openspec/changes/$change"
    node - "$directory/ai_snapshot.json" "$change" "$label" <<'NODE'
const fs=require('fs'),[file,change,label]=process.argv.slice(2),d=JSON.parse(fs.readFileSync(file));
if(d.active_change!==change||Object.hasOwn(d,'archive_failure'))throw Error(label+' changed active selector or created archive_failure before the archive CLI');
NODE
}

credential_archive_root_sha=$(sha256sum -- "$credential_archive_repo/ai_snapshot.json" | awk '{print $1}')
archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
run_archive_at "$credential_archive_repo" success
assert_pre_cli_archive_rejection "$credential_archive_repo" "$credential_archive_root_sha" "$archive_calls_before" 'verification credential'
assert_path_absent "$credential_archive_repo/openspec/changes/archive/$(date -u +%Y-%m-%d)-$change"

for pre_cli_case in tasks-incomplete stale-pass; do
    if [[ "$pre_cli_case" == tasks-incomplete ]]; then
        pre_cli_repo=$tasks_incomplete_repo
    else
        pre_cli_repo=$stale_repo
    fi
    pre_cli_root_sha=$(sha256sum -- "$pre_cli_repo/ai_snapshot.json" | awk '{print $1}')
    archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
    run_archive_at "$pre_cli_repo" success
    assert_pre_cli_archive_rejection "$pre_cli_repo" "$pre_cli_root_sha" "$archive_calls_before" "$pre_cli_case"
done

note '结构合法的 Fail/Blocked 可完成 Evaluation，但都不能进入 OpenSpec archive CLI'
for verdict_case in Fail Blocked; do
    if [[ "$verdict_case" == Fail ]]; then
        verdict_repo=$fail_repo
    else
        verdict_repo=$blocked_repo
    fi
    run_runtime_at "$verdict_repo" scripts/evaluator_check.sh --finish "$change"
    assert_status 0
    assert_contains "$RUN_OUTPUT" "Evaluation completed: $verdict_case"
    node - "$verdict_repo/openspec/changes/$change/harness/evaluation-baseline.json" \
        "$verdict_repo/openspec/changes/$change/harness/evaluation.json" "$verdict_case" <<'NODE'
const fs = require('fs');
const [baselineFile, evaluationFile, expected] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const evaluation = JSON.parse(fs.readFileSync(evaluationFile, 'utf8'));
if (baseline.status !== 'complete' || evaluation.verdict !== expected) {
  throw new Error(`${expected} Evaluation did not complete as a structurally valid terminal report`);
}
NODE

    verdict_root_sha=$(sha256sum -- "$verdict_repo/ai_snapshot.json" | awk '{print $1}')
    archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
    run_archive_at "$verdict_repo" success
    assert_pre_cli_archive_rejection "$verdict_repo" "$verdict_root_sha" "$archive_calls_before" "$verdict_case Evaluation"
    assert_contains "$RUN_OUTPUT" 'Evaluation is not a digest-bound Pass'
done

assert_archive_recovery_state() {
    local directory=$1 expected_message=$2
    node - "$directory/ai_snapshot.json" "$change" "$expected_message" "$directory" <<'NODE'
const fs = require('fs');
const path = require('path');
const [file, change, message, root] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
const failure = snapshot.archive_failure;
if (snapshot.active_change !== null || snapshot.phase !== 'archive_failed' ||
    failure?.change !== change || failure?.message !== message ||
    failure?.active_cleared !== true ||
    failure?.actual_locations?.source_change?.kind !== 'missing' ||
    failure?.actual_locations?.utc_archive?.kind !== 'directory') {
  throw new Error('partial archive failure state did not compare-and-clear the active pointer');
}
const log = path.join(root, failure.log_path);
const text = fs.readFileSync(log, 'utf8');
for (const marker of [
  '[openspec-preflight]', '[pre-archive.fingerprints]', '[pre-archive.evidence]',
  '[archive-cli]', 'rc=0', 'stdout:', 'stderr:',
  '[recovery.actual-locations]', '[recovery.strict-validation.main-specs]',
  '[post-failure.git-status]', '[post-failure.git-name-status]',
  '[post-failure.git-diff-sha256]'
]) if (!text.includes(marker)) throw new Error('archive recovery log missing '+marker);
NODE
}

note 'CLI 已移动 change 但返回错误 JSON 时，不回滚/重试并 compare-and-clear active'
archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
run_archive_at "$partial_repo" moved-wrong-json
[[ "$RUN_STATUS" -ne 0 ]] || fail '部分移动+错误 JSON 应失败'
archive_calls_after=$(grep -c 'openspec archive ' "$runtime_log" || true)
[[ $((archive_calls_after-archive_calls_before)) -eq 1 ]] || fail '部分移动失败触发了 archive 自动重试'
assert_contains "$RUN_OUTPUT" 'archive JSON contract mismatch'
partial_target=$(find "$partial_repo/openspec/changes/archive" -mindepth 1 -maxdepth 1 -type d -name "*-$change" -print -quit)
[[ -n "$partial_target" ]] || fail '部分移动现场没有保留 archive 目录'
assert_path_absent "$partial_repo/openspec/changes/$change"
assert_archive_recovery_state "$partial_repo" 'archive JSON contract mismatch'

note 'CLI 已移动 change 但主 specs 后置 strict 失败时保留现场并清空 stale active'
archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
run_archive_at "$post_strict_repo" success 1
[[ "$RUN_STATUS" -ne 0 ]] || fail '后置 strict failure 应失败'
archive_calls_after=$(grep -c 'openspec archive ' "$runtime_log" || true)
[[ $((archive_calls_after-archive_calls_before)) -eq 1 ]] || fail '后置 strict failure 触发了 archive 自动重试'
assert_contains "$RUN_OUTPUT" 'main spec validation JSON has errors'
post_target=$(find "$post_strict_repo/openspec/changes/archive" -mindepth 1 -maxdepth 1 -type d -name "*-$change" -print -quit)
[[ -n "$post_target" ]] || fail '后置 strict failure 没有保留 archive 目录'
assert_path_absent "$post_strict_repo/openspec/changes/$change"
assert_archive_recovery_state "$post_strict_repo" 'main spec validation JSON has errors'

note 'durable prepare 与 archive CLI 之间的源码竞态进入恢复状态，不能伪装成普通 preflight rejection'
archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
run_archive_at "$prepared_race_repo" success 0 1
[[ "$RUN_STATUS" -ne 0 ]] || fail 'durable prepare 后的 source race 应失败'
archive_calls_after=$(grep -c 'openspec archive ' "$runtime_log" || true)
[[ "$archive_calls_after" -eq "$archive_calls_before" ]] || fail 'prepare 后 source race 不应进入 OpenSpec archive CLI'
assert_contains "$RUN_OUTPUT" 'source changed after archive transaction preparation'
assert_not_contains "$RUN_OUTPUT" 'Archive was not invoked'
assert_path_exists "$prepared_race_repo/openspec/changes/$change"
assert_path_absent "$prepared_race_repo/openspec/changes/archive/$(date -u +%Y-%m-%d)-$change"
prepared_race_current=$(cd "$prepared_race_repo" && scripts/source_fingerprint.sh --kind source)
node - "$prepared_race_repo/ai_snapshot.json" \
    "$prepared_race_repo/.ai-harness/archive-transaction.json" "$change" "$prepared_race_current" <<'NODE'
const fs = require('fs');
const [snapshotFile, transactionFile, change, current] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
const transaction = JSON.parse(fs.readFileSync(transactionFile, 'utf8'));
if (snapshot.active_change !== change || snapshot.phase !== 'archive_failed' ||
    snapshot.archive_failure?.change !== change ||
    snapshot.archive_failure?.message !== 'source changed after archive transaction preparation' ||
    snapshot.archive_failure?.active_cleared !== false ||
    snapshot.archive_failure?.actual_locations?.source_change?.kind !== 'directory' ||
    snapshot.archive_failure?.actual_locations?.utc_archive?.kind !== 'missing' ||
    transaction.change_name !== change || transaction.status !== 'prepared' ||
    transaction.fingerprints?.source_fingerprint === current) {
  throw new Error('prepare-to-CLI source race did not retain a recoverable source state');
}
NODE

note '归档 CLI 运行期间产品源码漂移时 fail closed，并保留 prepared transaction 供人工恢复'
archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
run_archive_at "$source_race_repo" success-source-race
[[ "$RUN_STATUS" -ne 0 ]] || fail 'archive 运行期间的 source race 应失败'
archive_calls_after=$(grep -c 'openspec archive ' "$runtime_log" || true)
[[ $((archive_calls_after-archive_calls_before)) -eq 1 ]] || fail 'source race 触发了 archive 自动重试'
assert_contains "$RUN_OUTPUT" 'product source changed while OpenSpec archive was running'
assert_contains "$(tail -n 1 "$source_race_repo/src/widget.cpp")" 'source changed by the archive race regression'
assert_path_absent "$source_race_repo/openspec/changes/$change"
assert_archive_recovery_state "$source_race_repo" 'product source changed while OpenSpec archive was running'
source_race_current=$(cd "$source_race_repo" && scripts/source_fingerprint.sh --kind source)
node - "$source_race_repo/.ai-harness/archive-transaction.json" "$change" "$source_race_current" <<'NODE'
const fs = require('fs');
const [file, change, current] = process.argv.slice(2);
const transaction = JSON.parse(fs.readFileSync(file, 'utf8'));
if (transaction.change_name !== change || transaction.status !== 'prepared' ||
    transaction.completed_at !== null ||
    transaction.fingerprints?.source_fingerprint === current) {
  throw new Error('source race did not retain a stale prepared transaction for recovery');
}
NODE

note 'prepared journal 后进程硬中断可只读识别，并按 source-retained 路径显式恢复'
prepared_root_sha=$(sha256sum -- "$prepared_interrupt_repo/ai_snapshot.json" | awk '{print $1}')
archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
run_archive_at "$prepared_interrupt_repo" interrupt-prepared
[[ "$RUN_STATUS" -ne 0 ]] || fail 'prepared transaction 中断应使 archive 命令失败'
archive_calls_after=$(grep -c 'openspec archive ' "$runtime_log" || true)
[[ $((archive_calls_after-archive_calls_before)) -eq 1 ]] || fail 'prepared transaction 中断没有准确进入一次 archive CLI'
assert_path_exists "$prepared_interrupt_repo/openspec/changes/$change"
prepared_current_source=$(cd "$prepared_interrupt_repo" && scripts/source_fingerprint.sh --kind source)
node - "$prepared_interrupt_repo/.ai-harness/archive-transaction.json" "$prepared_interrupt_repo/ai_snapshot.json" \
    "$change" "$prepared_current_source" "$prepared_root_sha" "$prepared_interrupt_repo" <<'NODE'
const fs = require('fs');
const path = require('path');
const [transactionFile, snapshotFile, change, currentSource, rootSha, root] = process.argv.slice(2);
const transaction = JSON.parse(fs.readFileSync(transactionFile, 'utf8'));
const digest = value => typeof value === 'string' && /^sha256:[0-9a-f]{64}$/.test(value);
if (transaction.schema_version !== 1 ||
    !/^archive-txn-[0-9a-f]{24}$/.test(transaction.transaction_id) ||
    transaction.change_name !== change || transaction.status !== 'prepared' ||
    !Number.isFinite(Date.parse(transaction.prepared_at)) || transaction.completed_at !== null ||
    transaction.target_path !== `openspec/changes/archive/${new Date().toISOString().slice(0, 10)}-${change}` ||
    !/^\.ai-harness\/logs\/archive-[A-Za-z0-9_.-]+\.log$/.test(transaction.log_path) ||
    !fs.statSync(path.join(root, transaction.log_path)).isFile() ||
    transaction.root_snapshot_sha256 !== 'sha256:' + rootSha ||
    transaction.fingerprints?.source_fingerprint !== currentSource ||
    !digest(transaction.fingerprints?.artifact_fingerprint) ||
    !digest(transaction.fingerprints?.base_specs_fingerprint) || !digest(transaction.evidence_sha256)) {
  throw new Error('interrupted archive did not leave the exact durable prepared journal');
}
const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
if (snapshot.active_change !== change || Object.hasOwn(snapshot, 'archive_failure')) {
  throw new Error('hard interruption unexpectedly rewrote the root recovery state');
}
NODE
assert_path_exists "$prepared_interrupt_repo/.ai-harness/locks/managed-operation.lock"
run_runtime_at "$prepared_interrupt_repo" scripts/harness_lock.sh cleanup-stale
assert_status 0
assert_contains "$RUN_OUTPUT" 'Removed verified stale lock.'
prepared_transaction_sha=$(sha256sum -- "$prepared_interrupt_repo/.ai-harness/archive-transaction.json" | awk '{print $1}')
run_runtime_at "$prepared_interrupt_repo" scripts/archive_recover.sh --status
assert_status 0
node - "$RUN_OUTPUT" "$change" <<'NODE'
const [raw, change] = process.argv.slice(2);
const status = JSON.parse(raw);
if (status.unresolved !== true || status.change_name !== change ||
    status.current_state !== 'source-retained' || status.transaction_interrupted !== true ||
    !/^archive-txn-[0-9a-f]{24}$/.test(status.transaction_id) || status.eligible !== true ||
    status.issues.length !== 0) {
  throw new Error('prepared-only recovery status did not identify an eligible source-retained interruption');
}
NODE
[[ "$prepared_root_sha" == "$(sha256sum -- "$prepared_interrupt_repo/ai_snapshot.json" | awk '{print $1}')" ]] || \
    fail 'archive_recover --status 改写了 root snapshot'
[[ "$prepared_transaction_sha" == "$(sha256sum -- "$prepared_interrupt_repo/.ai-harness/archive-transaction.json" | awk '{print $1}')" ]] || \
    fail 'archive_recover --status 改写了 prepared transaction'
run_runtime_at "$prepared_interrupt_repo" scripts/archive_recover.sh --acknowledge "$change" \
    --reason 'Reviewed the interrupted prepared transaction and retained source change.'
assert_status 0
node - "$prepared_interrupt_repo/ai_snapshot.json" \
    "$prepared_interrupt_repo/.ai-harness/archive-transaction.json" "$change" <<'NODE'
const fs = require('fs');
const [snapshotFile, transactionFile, change] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
const transaction = JSON.parse(fs.readFileSync(transactionFile, 'utf8'));
if (snapshot.active_change !== change || snapshot.phase !== 'archive_recovery_acknowledged' ||
    snapshot.last_archive_recovery_acknowledgment?.recovered_state !== 'source-retained' ||
    Object.hasOwn(snapshot, 'archive_failure') || transaction.change_name !== change ||
    transaction.status !== 'acknowledged' || !Number.isFinite(Date.parse(transaction.completed_at))) {
  throw new Error('prepared-only source-retained recovery was not durably acknowledged');
}
NODE

note 'UTC archive target 是 dangling symlink 时在 CLI 前失败并保留 active change'
symlink_target="$symlink_repo/openspec/changes/archive/$(date -u +%Y-%m-%d)-$change"
ln -s missing-archive-target "$symlink_target"
symlink_root_sha=$(sha256sum -- "$symlink_repo/ai_snapshot.json" | awk '{print $1}')
archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
run_archive_at "$symlink_repo" success
assert_pre_cli_archive_rejection "$symlink_repo" "$symlink_root_sha" "$archive_calls_before" 'dangling archive target'
assert_contains "$RUN_OUTPUT" 'dangling symlink'
[[ -L "$symlink_target" ]] || fail 'dangling archive target 现场未保留'

note 'archive 命令即使退出 0，错误的顶层 archive JSON 也不能被接受'
run_archive_at "$wrong_json_repo" wrong-json
[[ "$RUN_STATUS" -ne 0 ]] || fail '错误 archive JSON 不应通过归档门禁'
assert_contains "$RUN_OUTPUT" 'archive JSON contract mismatch'
assert_path_exists "$wrong_json_repo/openspec/changes/$change"
node - "$wrong_json_repo/ai_snapshot.json" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
if (snapshot.active_change !== change || snapshot.phase !== 'archive_failed') {
  throw new Error('archive JSON contract failure did not preserve the active change for recovery');
}
NODE
run_runtime_at "$wrong_json_repo" scripts/change_status.sh "$change" --json
assert_status 0
node - "$RUN_OUTPUT" <<'NODE'
const x=JSON.parse(process.argv[2]);if(x.derived_phase!=='archive_failed'||!x.archive_failure)throw Error('dynamic status lost the archive recovery state');
NODE

note '现代 source-retained 恢复不得改写旧终态，并且 acknowledgment 后必须能开始全新 Evaluation'
wrong_json_harness="$wrong_json_repo/openspec/changes/$change/harness"
old_recovery_evaluation_id=$(node -p \
    "JSON.parse(require('fs').readFileSync(process.argv[1])).evaluation_id" \
    "$wrong_json_harness/evaluation-baseline.json")
old_recovery_envelope="$wrong_json_harness/evaluations/$old_recovery_evaluation_id.json"
old_recovery_envelope_sha=$(sha256sum -- "$old_recovery_envelope" | awk '{print $1}')
run_runtime_at "$wrong_json_repo" scripts/archive_recover.sh --acknowledge "$change" \
    --reason 'Reviewed the retained change and immutable Evaluation evidence.'
assert_status 0
node - "$wrong_json_repo/ai_snapshot.json" "$wrong_json_harness/evaluation-baseline.json" \
    "$wrong_json_harness/evaluations" "$change" "$old_recovery_evaluation_id" <<'NODE'
const fs = require('fs');
const path = require('path');
const [snapshotFile, baselineFile, historyDir, change, oldId] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
if (snapshot.active_change !== change || snapshot.phase !== 'archive_recovery_acknowledged' ||
    snapshot.last_archive_recovery_acknowledgment?.recovered_state !== 'source-retained') {
  throw new Error('source-retained acknowledgment did not preserve the active recovery contract');
}
if (baseline.evaluation_id === oldId && baseline.status !== 'complete') {
  throw new Error('source-retained recovery rewrote an immutable completed attempt in place');
}
if (baseline.evaluation_id !== oldId) {
  const recoveryEnvelope = path.join(historyDir, baseline.evaluation_id + '.json');
  if (baseline.status !== 'aborted' || !fs.existsSync(recoveryEnvelope)) {
    throw new Error('replacement recovery attempt is not an independently sealed aborted attempt');
  }
  const envelope = JSON.parse(fs.readFileSync(recoveryEnvelope, 'utf8'));
  if (envelope.evaluation_id !== baseline.evaluation_id || envelope.terminal_status !== 'aborted' ||
      envelope.evaluation !== null || envelope.evaluation_sha256 !== null ||
      JSON.stringify(envelope.baseline) !== JSON.stringify(baseline)) {
    throw new Error('replacement recovery attempt envelope does not match its baseline');
  }
}
NODE
[[ "$old_recovery_envelope_sha" == "$(sha256sum -- "$old_recovery_envelope" | awk '{print $1}')" ]] || \
    fail 'source-retained acknowledgment 改写了旧 complete terminal envelope'

recovery_archive_root_sha=$(sha256sum -- "$wrong_json_repo/ai_snapshot.json" | awk '{print $1}')
archive_calls_before=$(grep -c 'openspec archive ' "$runtime_log" || true)
run_archive_at "$wrong_json_repo" success
assert_pre_cli_archive_rejection "$wrong_json_repo" "$recovery_archive_root_sha" "$archive_calls_before" \
    'source-retained recovery acknowledgment'
assert_contains "$RUN_OUTPUT" 'fresh independent Evaluation required after source-retained archive recovery'

run_runtime_at "$wrong_json_repo" scripts/evaluator_check.sh --begin "$change"
assert_status 0
node - "$wrong_json_harness/evaluation-baseline.json" "$old_recovery_evaluation_id" <<'NODE'
const fs = require('fs');
const [file, oldId] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(file, 'utf8'));
if (baseline.status !== 'in_progress' || baseline.evaluation_id === oldId) {
  throw new Error('source-retained recovery did not begin a fresh independent Evaluation attempt');
}
NODE
[[ "$old_recovery_envelope_sha" == "$(sha256sum -- "$old_recovery_envelope" | awk '{print $1}')" ]] || \
    fail 'fresh recovery Evaluation 改写了旧 complete terminal envelope'

note '真实字段形状、绝对 path 与 UTC archivedAs 全部匹配时才完成归档'
run_archive_at "$success_repo" success
assert_status 0
archived_as="$(date -u +%Y-%m-%d)-$change"
archived_dir="$success_repo/openspec/changes/archive/$archived_as"
assert_path_absent "$success_repo/openspec/changes/$change"
assert_path_exists "$archived_dir/harness/evaluation.json"
node - "$success_repo/ai_snapshot.json" "$change" "$archived_as" <<'NODE'
const fs = require('fs');
const [file, change, archivedAs] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
if (snapshot.active_change !== null || snapshot.phase !== 'idle' ||
    snapshot.last_archived_change?.change_name !== change ||
    snapshot.last_archived_change?.archived_as !== archivedAs ||
    Object.hasOwn(snapshot, 'archive_failure')) {
  throw new Error('valid archive contract did not clear active/recovery state');
}
NODE
success_current_source=$(cd "$success_repo" && scripts/source_fingerprint.sh --kind source)
node - "$success_repo/.ai-harness/archive-transaction.json" "$change" "$archived_as" \
    "$success_current_source" <<'NODE'
const fs = require('fs');
const [file, change, archivedAs, currentSource] = process.argv.slice(2);
const transaction = JSON.parse(fs.readFileSync(file, 'utf8'));
if (transaction.schema_version !== 1 || transaction.change_name !== change ||
    transaction.status !== 'committed' || !Number.isFinite(Date.parse(transaction.completed_at)) ||
    transaction.target_path !== `openspec/changes/archive/${archivedAs}` ||
    transaction.fingerprints?.source_fingerprint !== currentSource) {
  throw new Error('successful archive did not commit a source-stable transaction journal');
}
NODE

security_failures=0
latest_archive_log=$(find "$success_repo/.ai-harness/logs" -maxdepth 1 -type f -name "archive-$change-*.log" \
    -printf '%T@\t%p\n' | LC_ALL=C sort -n | tail -n 1 | cut -f2-)
if [[ -z "$latest_archive_log" || ! -f "$latest_archive_log" ]]; then
    printf '[ASSERT] successful archive did not retain a metadata audit log\n' >&2
    security_failures=$((security_failures + 1))
else
    if grep -Fq -- 'std::cout << 7' "$latest_archive_log"; then
        printf '[ASSERT] archive log leaked tracked source diff content\n' >&2
        security_failures=$((security_failures + 1))
    fi
    if grep -Fq -- 'eval-private-47f66c23' "$latest_archive_log"; then
        printf '[ASSERT] archive log embedded the full Evaluation free-text report\n' >&2
        security_failures=$((security_failures + 1))
    fi
    if ! grep -Fq -- 'evaluation_json_sha256' "$latest_archive_log"; then
        printf '[ASSERT] redacted archive log lost the Evaluation digest needed for audit correlation\n' >&2
        security_failures=$((security_failures + 1))
    fi
fi

run_runtime_at "$secret_repo" scripts/evaluator_check.sh --finish "$change"
if [[ "$RUN_STATUS" -eq 0 ]]; then
    printf '[ASSERT] Evaluator accepted HTTP credentials hidden in arbitrary free-text fields\n' >&2
    security_failures=$((security_failures + 1))
fi
secret_baseline_status=$(node -p \
    "JSON.parse(require('fs').readFileSync(process.argv[1])).status" \
    "$secret_repo/openspec/changes/$change/harness/evaluation-baseline.json")
if [[ "$secret_baseline_status" != in_progress ]]; then
    printf '[ASSERT] rejected free-text secret attempt did not preserve an in-progress Evaluation baseline\n' >&2
    security_failures=$((security_failures + 1))
fi

(( security_failures == 0 )) || fail "Evaluator/archive security regression failed ($security_failures assertions)"

note 'Evaluator 生命周期：begin、负向门禁、fresh Pass、digest 绑定、只读重验与 archive JSON 正反门禁均通过'
