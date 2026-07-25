#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/readiness resume project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready

note '生成 Harness 并建立两个可独立浏览的 OpenSpec change'
run_setup "$repo"
assert_status 0

make_change() {
    local change=$1
    local dir="$repo/openspec/changes/$change"
    mkdir -p "$dir/specs/widget" "$dir/harness"
    printf 'schema: spec-driven\n' > "$dir/.openspec.yaml"
    cat > "$dir/proposal.md" <<EOF
# $change

Add one planned widget behavior.
EOF
    cat > "$dir/specs/widget/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Widget readiness
The widget SHALL expose the planned behavior.

#### Scenario: Ready widget
- **WHEN** the widget is used
- **THEN** the planned behavior is observable
EOF
    cat > "$dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Implement widget readiness
  - Covers: `specs/widget/spec.md` | `ADDED` | `Widget readiness` | `Ready widget`
  - Verify: `build`, `behavior`
EOF
    cat > "$dir/design.md" <<'EOF'
# Design

Reuse the existing executable and avoid new public surfaces.

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "micro",
  "rationale": "One existing implementation path is sufficient.",
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
      "added_lines": {"expected": 10, "review_at": 20, "hard_limit": 30},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 10, "review_at": 20, "hard_limit": 30},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 5, "review_at": 10, "hard_limit": 20},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "bytes": {"expected": 0, "review_at": 1024, "hard_limit": 2048}
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
    cat > "$dir/harness/ai_snapshot.json" <<'EOF'
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
    printf '{"schema_version":2,"change_name":"%s","migration":null,"tasks":[]}\n' "$change" > "$dir/harness/verification.json"
    printf '# Verification\n' > "$dir/harness/verification.md"
    printf '# Evaluation history\n' > "$dir/harness/evaluation.md"
    printf '# Defect RCA\n' > "$dir/harness/defect-rca.md"
}

make_change alpha-readiness
make_change beta-readiness
git -C "$repo" config user.name 'AutoAI Readiness Test'
git -C "$repo" config user.email 'autoai-readiness@example.invalid'
git -C "$repo" add -A
git -C "$repo" commit -qm 'baseline readiness fixtures'

run_managed() {
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

local_value() {
    local change=$1 expression=$2
    node -p "$expression" "$repo/openspec/changes/$change/harness/ai_snapshot.json"
}

note 'unborn HEAD 允许 setup 和规划，但冻结 implementation base 在业务写入前拒绝'
main_repo=$repo
repo="$tmp/unborn readiness project"
init_git_repo "$repo"
reset_stub_environment
export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
run_setup "$repo"
assert_status 0
make_change unborn-readiness
(cd "$repo" && scripts/change_select.sh unborn-readiness >/dev/null)
unborn_root_before=$(sha256sum -- "$repo/ai_snapshot.json" | awk '{print $1}')
unborn_local_before=$(sha256sum -- "$repo/openspec/changes/unborn-readiness/harness/ai_snapshot.json" | awk '{print $1}')
run_managed scripts/snapshot_update.sh --freeze-planning-baseline --freeze-implementation-base --phase implementing
assert_status 4
assert_contains "$RUN_OUTPUT" 'HEAD commit'
[[ "$unborn_root_before" == "$(sha256sum -- "$repo/ai_snapshot.json" | awk '{print $1}')" ]] || \
    fail 'unborn readiness 失败后改写了根 snapshot'
[[ "$unborn_local_before" == "$(sha256sum -- "$repo/openspec/changes/unborn-readiness/harness/ai_snapshot.json" | awk '{print $1}')" ]] || \
    fail 'unborn readiness 失败后写入了 planning/implementation baseline'
if git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    fail 'unborn fixture 意外拥有 HEAD commit'
fi
repo=$main_repo
reset_stub_environment
export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready

note 'CLI 退出 0 但 status JSON 不符合 1.6.0 contract 时不得写入任何 baseline'
(cd "$repo" && scripts/change_select.sh beta-readiness >/dev/null)
export STUB_OPENSPEC_STATUS_MODE=malformed
run_managed scripts/snapshot_update.sh --freeze-planning-baseline --freeze-implementation-base --phase implementing
assert_status 6
[[ $(local_value beta-readiness "JSON.parse(require('fs').readFileSync(process.argv[1])).planned_base_specs_fingerprint") == null ]] || fail '失败的 readiness 写入了 planned baseline'
[[ $(local_value beta-readiness "JSON.parse(require('fs').readFileSync(process.argv[1])).implementation_base_commit") == null ]] || fail '失败的 readiness 写入了 implementation base'

note '任务引用未闭合或 Economy schema 非法时同样必须在编码前阻断'
export STUB_OPENSPEC_STATUS_MODE=success
sed -i 's/Widget readiness` | `Ready widget/Unknown requirement` | `Ready widget/' "$repo/openspec/changes/beta-readiness/tasks.md"
run_managed scripts/snapshot_update.sh --freeze-planning-baseline --freeze-implementation-base --phase implementing
assert_status 6
sed -i 's/Unknown requirement` | `Ready widget/Widget readiness` | `Ready widget/' "$repo/openspec/changes/beta-readiness/tasks.md"
sed -i '/"exceptions": \[\]/a\  ,"unknown_budget_field": true' "$repo/openspec/changes/beta-readiness/design.md"
run_managed scripts/snapshot_update.sh --freeze-planning-baseline --freeze-implementation-base --phase implementing
assert_status 6
sed -i '/unknown_budget_field/d' "$repo/openspec/changes/beta-readiness/design.md"

note '合法 readiness 冻结 base，并把根 cursor 原子同步到 change-local snapshot'
run_managed scripts/snapshot_update.sh --freeze-planning-baseline --freeze-implementation-base --phase implementing --current-step implementation-base-frozen --next-step implement-first-task
assert_status 0
frozen_implementation_base=$(local_value beta-readiness "JSON.parse(require('fs').readFileSync(process.argv[1])).implementation_base_commit")
node - "$repo/ai_snapshot.json" "$repo/openspec/changes/beta-readiness/harness/ai_snapshot.json" <<'NODE'
const fs=require('fs'),[rootFile,localFile]=process.argv.slice(2),root=JSON.parse(fs.readFileSync(rootFile)),local=JSON.parse(fs.readFileSync(localFile));
if(root.phase!=='implementing'||local.phase!=='implementing'||root.current_step!=='implementation-base-frozen'||local.current_step!==root.current_step||root.next_step!=='implement-first-task'||local.next_step!==root.next_step)throw Error('root/local recovery cursor mismatch');
if('active_change'in local||typeof local.implementation_base_commit!=='string'||!local.planned_base_specs_fingerprint)throw Error('local snapshot selector/base contract mismatch');
NODE

note 'Generator 实现即使提交到 HEAD，footprint 仍相对冻结 implementation base 计算完整 scope'
committed_scope_repo="$tmp/committed generator scope project"
cp -a -- "$repo" "$committed_scope_repo"
mkdir -p "$committed_scope_repo/src"
printf 'int committed_widget_scope = 1;\n' > "$committed_scope_repo/src/widget.cpp"
git -C "$committed_scope_repo" add src/widget.cpp
git -C "$committed_scope_repo" commit -qm 'generator commits approved implementation'
RUN_OUTPUT=
RUN_STATUS=0
set +e
RUN_OUTPUT=$(cd "$committed_scope_repo" && scripts/change_footprint.sh beta-readiness --json 2>&1)
RUN_STATUS=$?
set -e
assert_status 6
node - "$committed_scope_repo/openspec/changes/beta-readiness/harness/change-footprint.json" \
    "$frozen_implementation_base" <<'NODE'
const fs=require('fs');const [file,base]=process.argv.slice(2),x=JSON.parse(fs.readFileSync(file));
if(x.implementation_base_commit!==base||x.status!=='review_required'||x.production.touched_files!==1||x.production.new_files!==1||x.production.added_lines!==1)throw Error('committed implementation disappeared from frozen-base footprint');
NODE
if git -C "$committed_scope_repo" diff --quiet "$frozen_implementation_base" HEAD -- src/widget.cpp; then
    fail 'fixture did not create a committed change relative to implementation base'
fi

note 'change_status 可只读浏览非 active change，不会偷偷切换 selector'
run_managed scripts/change_status.sh alpha-readiness --json
assert_status 0
node - "$repo/ai_snapshot.json" "$RUN_OUTPUT" <<'NODE'
const fs=require('fs'),root=JSON.parse(fs.readFileSync(process.argv[2])),x=JSON.parse(process.argv[3]);if(root.active_change!=='beta-readiness'||x.change_name!=='alpha-readiness'||x.active!==false)throw Error('non-active status browsing mutated or misreported selector');
NODE

note '缓存的 complete/Pass 不能伪造 accepted；实时 recheck 失败必须派生 evaluation_stale'
cat > "$repo/openspec/changes/beta-readiness/harness/evaluation-baseline.json" <<'EOF'
{"schema_version":1,"status":"complete","evaluation_id":"fake","evaluation_json_sha256":"sha256:fake"}
EOF
cat > "$repo/openspec/changes/beta-readiness/harness/evaluation.json" <<'EOF'
{"evaluation_id":"fake","verdict":"Pass","evaluated_at":"2026-01-01T00:00:00Z"}
EOF
export STUB_OPENSPEC_INSTRUCTIONS_MODE=success
run_managed scripts/change_status.sh beta-readiness --json
assert_status 0
node - "$RUN_OUTPUT" <<'NODE'
const x=JSON.parse(process.argv[2]);if(x.derived_phase!=='evaluation_stale'||x.evaluation?.fresh!==false)throw Error('cached Pass was incorrectly accepted');
NODE
export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
run_managed scripts/change_status.sh beta-readiness --json
assert_status 0
node - "$RUN_OUTPUT" <<'NODE'
const x=JSON.parse(process.argv[2]);if(x.derived_phase!=='implementing'||x.evaluation?.fresh!==false)throw Error('reopened tasks did not resume Generator after stale Evaluation');
NODE

note '无效 implementation base 与主 specs 漂移会被动态恢复分别识别'
node - "$repo/openspec/changes/beta-readiness/harness/ai_snapshot.json" <<'NODE'
const fs=require('fs'),f=process.argv[2],x=JSON.parse(fs.readFileSync(f));x.implementation_base_commit='0000000000000000000000000000000000000000';fs.writeFileSync(f,JSON.stringify(x,null,2)+'\n');
NODE
rm -f "$repo/openspec/changes/beta-readiness/harness/evaluation-baseline.json" "$repo/openspec/changes/beta-readiness/harness/evaluation.json"
run_managed scripts/resume_from_snapshot.sh
assert_status 6
assert_contains "$RUN_OUTPUT" 'implementation_base_invalid'

node - "$repo/openspec/changes/beta-readiness/harness/ai_snapshot.json" "$frozen_implementation_base" <<'NODE'
const fs=require('fs'),[f,base]=process.argv.slice(2),x=JSON.parse(fs.readFileSync(f));x.implementation_base_commit=base;fs.writeFileSync(f,JSON.stringify(x,null,2)+'\n');
NODE
mkdir -p "$repo/openspec/specs/external"
printf '### Requirement: External drift\n' > "$repo/openspec/specs/external/spec.md"
run_managed scripts/resume_from_snapshot.sh
assert_status 6
assert_contains "$RUN_OUTPUT" 'plan_revision_required'

note '受控重规划先拒绝进行中的 Evaluation，再只刷新 planned base 而保持 implementation base 不变'
cat > "$repo/openspec/changes/beta-readiness/harness/evaluation-baseline.json" <<'EOF'
{"schema_version":1,"evaluation_id":"in-progress-replan","change_name":"beta-readiness","status":"in_progress"}
EOF
run_managed scripts/snapshot_update.sh --refresh-planning-baseline
assert_status 6
[[ $(local_value beta-readiness "JSON.parse(require('fs').readFileSync(process.argv[1])).implementation_base_commit") == "$frozen_implementation_base" ]] || fail 'failed refresh moved implementation base'
rm -f "$repo/openspec/changes/beta-readiness/harness/evaluation-baseline.json"
run_managed scripts/snapshot_update.sh --refresh-planning-baseline
assert_status 0
node - "$repo/openspec/changes/beta-readiness/harness/ai_snapshot.json" "$frozen_implementation_base" <<'NODE'
const fs=require('fs'),[file,base]=process.argv.slice(2),x=JSON.parse(fs.readFileSync(file));if(x.implementation_base_commit!==base||x.phase!=='implementing'||!x.planned_base_specs_fingerprint)throw Error('controlled planning refresh contract mismatch');
NODE
run_managed scripts/change_status.sh beta-readiness --json
assert_status 0
node - "$RUN_OUTPUT" <<'NODE'
const x=JSON.parse(process.argv[2]);if(x.derived_phase!=='implementing'||!x.planned_base.fresh)throw Error('replanned change did not resume implementation');
NODE

note '编码前就绪、非 active 状态浏览、动态 Pass 重验与受控重规划恢复均通过'
