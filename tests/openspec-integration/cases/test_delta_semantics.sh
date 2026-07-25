#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/delta contract project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/setup-dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

# Runtime commands use the system Node implementation but retain the offline
# OpenSpec 1.6.0 contract stub.
runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
ln -s "$STUB_BIN/npx" "$runtime_bin/npx"
export PATH="$runtime_bin:$REAL_TEST_PATH"

change=delta-contract
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)
change_dir="$repo/openspec/changes/$change"

note 'change_new accepts the real 1.6.0 JSON shape and preserves .openspec.yaml'
assert_path_exists "$change_dir/.openspec.yaml"

run_change_new() {
    local id=$1
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && scripts/change_new.sh "$id" --switch 2>&1)
    RUN_STATUS=$?
    set -e
}

note 'change_new rejects an exit-0 response whose absolute path contract is false'
export STUB_OPENSPEC_NEW_MODE=wrong-json
run_change_new wrong-new-json
[[ "$RUN_STATUS" -ne 0 ]] || fail 'wrong new-change JSON 应失败'
assert_contains "$RUN_OUTPUT" 'new-change JSON or filesystem contract mismatch'

note 'change_new rejects an initial change directory containing anything beyond .openspec.yaml'
export STUB_OPENSPEC_NEW_MODE=extra-entry
run_change_new polluted-new-change
[[ "$RUN_STATUS" -ne 0 ]] || fail 'polluted initial change directory 应失败'
assert_contains "$RUN_OUTPUT" 'new-change JSON or filesystem contract mismatch'
export STUB_OPENSPEC_NEW_MODE=success

node - "$repo/ai_snapshot.json" "$change" <<'NODE'
const fs = require('fs');
const [file, expected] = process.argv.slice(2);
if (JSON.parse(fs.readFileSync(file, 'utf8')).active_change !== expected) {
  throw new Error('rejected new-change contract changed the active selector');
}
NODE

mkdir -p "$repo/openspec/specs/widget" "$change_dir/specs/widget"
cat > "$repo/openspec/specs/widget/spec.md" <<'EOF'
# Widget capability

### Requirement: Modify Me

Existing behavior.

### Requirement: Remove Plain

Existing behavior.

### Requirement: Remove Bullet

Existing behavior.

### Requirement: Old Name

Existing behavior.
EOF

write_valid_delta() {
    cat > "$change_dir/specs/widget/spec.md" <<'EOF'
## added requirements

### requirement: Added Name

#### scenario: Added works

- **WHEN** the feature is used
- **THEN** it works

```markdown
## MODIFIED Requirements
### Requirement: Missing In Fence
#### Scenario: Must Be Ignored
```

## MoDiFiEd ReQuIrEmEnTs

### ReQuIrEmEnT: Modify Me

#### ScEnArIo: Modified works

- **WHEN** the feature is used
- **THEN** it uses the new behavior

## removed requirements

### requirement: Remove Plain

- `### Requirement: Remove Bullet`

## renamed requirements

- FROM: `### Requirement: Old Name`
- TO: `### Requirement: New Name`
EOF
}

write_valid_tasks() {
    cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [x] 1.1 Add the new requirement
  - Covers: `specs/widget/spec.md` | `ADDED` | `Added Name` | `Added works`
  - Verify: `static`
- [x] 1.2 Modify the existing requirement
  - Covers: `specs/widget/spec.md` | `MODIFIED` | `Modify Me` | `Modified works`
  - Verify: `static`
- [x] 1.3 Remove the ordinary-header requirement
  - Covers: `specs/widget/spec.md` | `REMOVED` | `Remove Plain` | `<none>`
  - Verify: `static`
- [x] 1.4 Remove the bullet-header requirement
  - Covers: `specs/widget/spec.md` | `REMOVED` | `Remove Bullet` | `<none>`
  - Verify: `static`
- [x] 1.5 Rename the existing requirement
  - Covers: `specs/widget/spec.md` | `RENAMED` | `Old Name -> New Name` | `<none>`
  - Verify: `static`
- [x] 1.6 Add a support verification for the same scenario
  - Covers: `specs/widget/spec.md` | `ADDED` | `Added Name` | `Added works`
  - Verify: `static`
EOF
}

run_evaluator_begin() {
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && scripts/evaluator_check.sh --begin "$change" 2>&1)
    RUN_STATUS=$?
    set -e
}

write_valid_delta
write_valid_tasks
cat > "$change_dir/design.md" <<'EOF'
# Design fixture

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
export STUB_OPENSPEC_TASK_TOTAL=6
note 'validate JSON 必须使用 items[].valid、summary.totals.failed 且不能含 ERROR issue'
export STUB_OPENSPEC_VALIDATE_MODE=error
run_evaluator_begin
[[ "$RUN_STATUS" -ne 0 ]] || fail 'valid=false/ERROR validate JSON 应失败'
assert_contains "$RUN_OUTPUT" 'strict validation has errors'
export STUB_OPENSPEC_VALIDATE_MODE=success

note 'instructions apply 必须使用 progress.complete 和 tasks[].done 的 1.6.0 contract'
export STUB_OPENSPEC_INSTRUCTIONS_MODE=legacy-shape
run_evaluator_begin
[[ "$RUN_STATUS" -ne 0 ]] || fail 'legacy instructions JSON shape 应失败'
assert_contains "$RUN_OUTPUT" 'tasks must be non-empty and all_done'
export STUB_OPENSPEC_INSTRUCTIONS_MODE=inconsistent
run_evaluator_begin
[[ "$RUN_STATUS" -ne 0 ]] || fail 'done=false instructions JSON 应失败'
assert_contains "$RUN_OUTPUT" 'tasks must be non-empty and all_done'
export STUB_OPENSPEC_INSTRUCTIONS_MODE=success

note 'instructions progress.total 必须与 tasks.md 叶子任务数一致'
export STUB_OPENSPEC_TASK_TOTAL=5
run_evaluator_begin
[[ "$RUN_STATUS" -ne 0 ]] || fail 'instructions/task count mismatch 应失败'
assert_contains "$RUN_OUTPUT" 'tasks.md leaf count differs from instructions progress.total'
export STUB_OPENSPEC_TASK_TOTAL=6

note '官方 rename pair、两种 REMOVED header、大小写变化、重复 support 覆盖与 fenced-code 排除均通过 delta 层'
run_evaluator_begin
[[ "$RUN_STATUS" -ne 0 ]] || fail '初始空 verification 不应完成 Evaluation begin'
assert_not_contains "$RUN_OUTPUT" 'delta spec syntax or main-spec application semantics failed'
assert_contains "$RUN_OUTPUT" 'Generator verification is incomplete or untraceable'

note 'ADDED 名称与主 spec 冲突时，在 Generator evidence 前被拒绝'
write_valid_delta
sed -i 's/Added Name/Modify Me/' "$change_dir/specs/widget/spec.md"
run_evaluator_begin
[[ "$RUN_STATUS" -ne 0 ]] || fail 'ADDED/main-spec collision 应失败'
assert_contains "$RUN_OUTPUT" 'delta spec syntax or main-spec application semantics failed'
assert_contains "$RUN_OUTPUT" 'delta destination collides with main spec'

note 'MODIFIED 来源不在主 spec 时被拒绝'
write_valid_delta
sed -i 's/Modify Me/Missing Source/' "$change_dir/specs/widget/spec.md"
run_evaluator_begin
[[ "$RUN_STATUS" -ne 0 ]] || fail 'MODIFIED missing source 应失败'
assert_contains "$RUN_OUTPUT" 'delta source missing from main spec'

note '不存在的 capability 只能包含 ADDED，不能以 MODIFIED 隐式创建'
write_valid_delta
mkdir -p "$change_dir/specs/new-capability"
cat > "$change_dir/specs/new-capability/spec.md" <<'EOF'
## MODIFIED Requirements

### Requirement: Cannot Exist

#### Scenario: Invalid source

- **WHEN** used
- **THEN** fail closed
EOF
run_evaluator_begin
[[ "$RUN_STATUS" -ne 0 ]] || fail 'new capability MODIFIED 应失败'
assert_contains "$RUN_OUTPUT" 'new capability may only contain ADDED requirements'

note 'OpenSpec 1.6.0 delta 语法与主 specs 应用语义门禁通过'
