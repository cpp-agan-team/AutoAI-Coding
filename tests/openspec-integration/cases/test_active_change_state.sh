#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/active change state project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

run_managed_at() {
    local directory=$1
    shift
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$directory" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

assert_root_active() {
    local directory=$1 expected=$2
    node - "$directory/ai_snapshot.json" "$expected" <<'NODE'
const fs = require('fs');
const [file, expected] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8')).active_change;
if ((expected === '<null>' && value !== null) || (expected !== '<null>' && value !== expected)) {
  throw new Error(`expected active ${expected}, got ${value}`);
}
NODE
}

note '无 active、无 change 时 evaluate/archive/status 均拒绝，根 selector 不变'
root_before=$(sha256sum -- "$repo/ai_snapshot.json" | awk '{print $1}')
run_managed_at "$repo" scripts/change_status.sh --json
assert_status 4
run_managed_at "$repo" scripts/evaluator_check.sh --begin
assert_status 4
run_managed_at "$repo" scripts/change_archive.sh
assert_status 4
root_after=$(sha256sum -- "$repo/ai_snapshot.json" | awk '{print $1}')
[[ "$root_before" == "$root_after" ]] || fail 'no-active blocked entries mutated the root snapshot'

note 'A → B → A 显式切换不丢失任何 change-local evidence'
(
    cd "$repo"
    scripts/change_new.sh alpha-state >/dev/null
)
printf '\nALPHA EVIDENCE SENTINEL\n' >> "$repo/openspec/changes/alpha-state/harness/verification.md"
printf '\nALPHA RCA SENTINEL\n' >> "$repo/openspec/changes/alpha-state/harness/defect-rca.md"
(
    cd "$repo"
    scripts/change_new.sh beta-state --switch >/dev/null
)
printf '\nBETA EVIDENCE SENTINEL\n' >> "$repo/openspec/changes/beta-state/harness/verification.md"
printf '\nBETA RCA SENTINEL\n' >> "$repo/openspec/changes/beta-state/harness/defect-rca.md"

note '写入型 Integration refresh 只能修改唯一 active change'
nonactive_before="$tmp/nonactive-refresh.before"
fingerprint_paths "$repo" \
    openspec/changes/alpha-state/harness/ai_snapshot.json \
    openspec/changes/alpha-state/harness/verification.json \
    openspec/changes/beta-state/harness/ai_snapshot.json \
    openspec/changes/beta-state/harness/verification.json > "$nonactive_before"
run_managed_at "$repo" scripts/integration_surface_check.sh alpha-state --refresh --json
assert_status 4
assert_contains "$RUN_OUTPUT" "is not active 'beta-state'"
nonactive_after="$tmp/nonactive-refresh.after"
fingerprint_paths "$repo" \
    openspec/changes/alpha-state/harness/ai_snapshot.json \
    openspec/changes/alpha-state/harness/verification.json \
    openspec/changes/beta-state/harness/ai_snapshot.json \
    openspec/changes/beta-state/harness/verification.json > "$nonactive_after"
assert_files_equal "$nonactive_before" "$nonactive_after"

evidence_paths=(
    openspec/changes/alpha-state/harness/ai_snapshot.json
    openspec/changes/alpha-state/harness/verification.md
    openspec/changes/alpha-state/harness/defect-rca.md
    openspec/changes/beta-state/harness/ai_snapshot.json
    openspec/changes/beta-state/harness/verification.md
    openspec/changes/beta-state/harness/defect-rca.md
)
before="$tmp/change-evidence.before"
after="$tmp/change-evidence.after"
fingerprint_paths "$repo" "${evidence_paths[@]}" > "$before"
(
    cd "$repo"
    scripts/change_select.sh alpha-state >/dev/null
)
assert_root_active "$repo" alpha-state
fingerprint_paths "$repo" "${evidence_paths[@]}" > "$after"
assert_files_equal "$before" "$after"
assert_file_contains "$repo/openspec/changes/alpha-state/harness/verification.md" 'ALPHA EVIDENCE SENTINEL'
assert_file_contains "$repo/openspec/changes/beta-state/harness/verification.md" 'BETA EVIDENCE SENTINEL'
node - "$repo/openspec/changes/alpha-state/harness/ai_snapshot.json" "$repo/openspec/changes/beta-state/harness/ai_snapshot.json" <<'NODE'
const fs = require('fs');
for (const file of process.argv.slice(2)) {
  const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (Object.hasOwn(snapshot, 'active_change')) throw new Error(`local selector leaked into ${file}`);
}
NODE

note '多 change 无 active 时 resume 不猜最新，受管写入口继续 Blocked'
(
    cd "$repo"
    scripts/change_select.sh --clear >/dev/null
)
assert_root_active "$repo" '<null>'
run_managed_at "$repo" scripts/resume_from_snapshot.sh
assert_status 0
assert_contains "$RUN_OUTPUT" 'No active change'
assert_root_active "$repo" '<null>'
run_managed_at "$repo" scripts/evaluator_check.sh --begin
assert_status 4
run_managed_at "$repo" scripts/change_archive.sh
assert_status 4
assert_root_active "$repo" '<null>'

note 'active 指向不存在 change 或仅存在 archive 时 resume fail-closed 且不修补 selector'
missing_repo="$tmp/stale missing active"
archived_repo="$tmp/stale archived active"
cp -a -- "$repo" "$missing_repo"
cp -a -- "$repo" "$archived_repo"
node - "$missing_repo/ai_snapshot.json" <<'NODE'
const fs=require('fs'),f=process.argv[2],d=JSON.parse(fs.readFileSync(f));d.active_change='ghost-state';fs.writeFileSync(f,JSON.stringify(d,null,2)+'\n');
NODE
missing_before=$(sha256sum -- "$missing_repo/ai_snapshot.json" | awk '{print $1}')
run_managed_at "$missing_repo" scripts/resume_from_snapshot.sh
assert_status 4
missing_after=$(sha256sum -- "$missing_repo/ai_snapshot.json" | awk '{print $1}')
[[ "$missing_before" == "$missing_after" ]] || fail 'stale missing pointer was silently rewritten'

mkdir -p "$archived_repo/openspec/changes/archive/2026-07-14-archived-state/harness"
printf '# retained evidence\n' > "$archived_repo/openspec/changes/archive/2026-07-14-archived-state/harness/evaluation.md"
node - "$archived_repo/ai_snapshot.json" <<'NODE'
const fs=require('fs'),f=process.argv[2],d=JSON.parse(fs.readFileSync(f));d.active_change='archived-state';fs.writeFileSync(f,JSON.stringify(d,null,2)+'\n');
NODE
archived_before=$(sha256sum -- "$archived_repo/ai_snapshot.json" | awk '{print $1}')
run_managed_at "$archived_repo" scripts/resume_from_snapshot.sh
assert_status 4
archived_after=$(sha256sum -- "$archived_repo/ai_snapshot.json" | awk '{print $1}')
[[ "$archived_before" == "$archived_after" ]] || fail 'stale archived pointer was silently rewritten'

note '无 active、多 change 显式切换、证据隔离和 stale pointer 均符合状态契约'
