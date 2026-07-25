#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/integration upgrade source"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$repo"
assert_status 0

change=upgrade-integration
(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
)
use_modern_v2_fixture "$repo" "$change"

change_dir="$repo/openspec/changes/$change"
mkdir -p "$change_dir/specs/upgrade"
cat > "$change_dir/proposal.md" <<'EOF'
# Change: Upgrade an empty evidence family

Exercise the explicit v3 integration-evidence migration before implementation starts.
EOF
cat > "$change_dir/specs/upgrade/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Evidence family upgrade

The Harness SHALL upgrade only a pristine v3/v2 evidence family.

#### Scenario: Empty evidence upgrades atomically

- **WHEN** an approved change has no task or Evaluation evidence
- **THEN** its local snapshot and verification document move to v4/v3 together
EOF
cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Upgrade the empty evidence family
  - Covers: `specs/upgrade/spec.md` | `ADDED` | `Evidence family upgrade` | `Empty evidence upgrades atomically`
  - Verify: `static`
EOF
cat > "$change_dir/design.md" <<'EOF'
# Design

This fixture has no product surface; it tests only the explicit evidence-family migration.

<!-- autoai:tdd-policy:v1 -->
```json
{
  "schema_version": 1,
  "default": "required",
  "exceptions": [
    {
      "id": "upgrade-proof",
      "category": "configuration_only",
      "task_ids": ["1.1"],
      "paths": ["lifecycle-marker.txt"],
      "reason": "The lifecycle fixture records a repository-document marker without adding runtime behavior.",
      "alternative_verify_kinds": ["static"],
      "exit_condition": "Remove this exception if the marker becomes executable behavior."
    }
  ]
}
```
<!-- /autoai:tdd-policy:v1 -->

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "micro",
  "rationale": "No product files are changed by this migration fixture.",
  "classification": {
    "production": ["src/**"],
    "tests": ["tests/**"],
    "project_docs": ["README.md", "lifecycle-marker.txt"],
    "project_tooling": ["CMakeLists.txt"],
    "examples": ["examples/**"],
    "generated": [],
    "vendor": ["vendor/**"]
  },
  "thresholds": {
    "production": {
      "added_lines": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "touched_files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "touched_files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 2, "review_at": 3, "hard_limit": 4},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "generated": {
      "files": {"expected": 0, "review_at": 1, "hard_limit": 2},
      "bytes": {"expected": 0, "review_at": 1, "hard_limit": 2}
    }
  },
  "structural_allowances": {"public_contracts": [], "cmake_targets": [], "direct_dependencies": []},
  "reuse_decisions": [],
  "obsolete_items": [],
  "exceptions": []
}
```
<!-- /autoai:implementation-economy:v1 -->

<!-- autoai:integration-completeness:v1 -->
```json
{
  "discovery": {"compile_commands_path": null, "mode": "reviewed_inventory"},
  "schema_version": 1,
  "surfaces": []
}
```
<!-- /autoai:integration-completeness:v1 -->
EOF
printf 'baseline lifecycle marker\n' > "$repo/lifecycle-marker.txt"

git -C "$repo" config user.name 'AutoAI Integration Upgrade Test'
git -C "$repo" config user.email 'autoai-integration-upgrade@example.invalid'
git -C "$repo" add -A
git -C "$repo" commit -qm 'approved empty evidence upgrade fixture'
node - "$change_dir/harness/ai_snapshot.json" "$(git -C "$repo" rev-parse HEAD)" <<'NODE'
const fs = require('fs');
const [file, head] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.implementation_base_commit = head;
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
NODE

# Generated runtime scripts need the real Node interpreter while the OpenSpec
# wrapper remains pinned to the offline npx fixture.
runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
ln -s "$STUB_BIN/npx" "$runtime_bin/npx"
export PATH="$runtime_bin:$REAL_TEST_PATH"

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

copy_fixture() {
    local destination=$1
    cp -a -- "$repo" "$destination"
}

assert_upgrade_source_unchanged() {
    local directory=$1 snapshot_sha=$2 verification_sha=$3
    local harness="$directory/openspec/changes/$change/harness"
    [[ "$snapshot_sha" == "$(sha256sum -- "$harness/ai_snapshot.json" | awk '{print $1}')" ]] || \
        fail 'rejected upgrade rewrote the local snapshot'
    [[ "$verification_sha" == "$(sha256sum -- "$harness/verification.json" | awk '{print $1}')" ]] || \
        fail 'rejected upgrade rewrote verification evidence'
    assert_path_absent "$harness/integration-upgrade-v3.json"
}

note 'pristine v3/v2 evidence upgrades to v4/v3 with a closed committed journal'
success_repo="$tmp/upgrade success"
copy_fixture "$success_repo"
run_managed_at "$success_repo" scripts/change_footprint.sh "$change" --json
assert_status 0
preupgrade_footprint_sha=$(sha256sum -- "$success_repo/openspec/changes/$change/harness/change-footprint.json" | awk '{print $1}')
run_managed_at "$success_repo" scripts/task_verify.sh --upgrade-v3 "$change"
assert_status 0
success_harness="$success_repo/openspec/changes/$change/harness"
[[ "$preupgrade_footprint_sha" == "$(sha256sum -- "$success_harness/change-footprint.json" | awk '{print $1}')" ]] || \
    fail 'v3 upgrade rewrote an existing valid footprint'
node - "$success_harness/ai_snapshot.json" "$success_harness/verification.json" \
    "$success_harness/integration-upgrade-v3.json" "$change" <<'NODE'
const fs = require('fs');
const [snapshotFile, verificationFile, journalFile, change] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
const verification = JSON.parse(fs.readFileSync(verificationFile, 'utf8'));
const journal = JSON.parse(fs.readFileSync(journalFile, 'utf8'));
if (snapshot.schema_version !== 4 || snapshot.planned_integration_completeness_sha256 !== null ||
    snapshot.phase !== 'planning' || verification.schema_version !== 3 ||
    verification.change_name !== change || verification.tasks.length !== 0) {
  throw new Error('upgrade target family mismatch');
}
if (journal.schema_version !== 1 || journal.change_name !== change || journal.status !== 'committed' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(journal.prepared_at) ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(journal.committed_at) ||
    journal.source_snapshot.schema_version !== 3 || journal.source_verification.schema_version !== 2) {
  throw new Error('closed upgrade journal mismatch');
}
NODE

note 'committed upgrade is idempotent and preserves all three artifact bytes'
success_snapshot_sha=$(sha256sum -- "$success_harness/ai_snapshot.json" | awk '{print $1}')
success_verification_sha=$(sha256sum -- "$success_harness/verification.json" | awk '{print $1}')
success_journal_sha=$(sha256sum -- "$success_harness/integration-upgrade-v3.json" | awk '{print $1}')
run_managed_at "$success_repo" scripts/task_verify.sh --upgrade-v3 "$change"
assert_status 0
[[ "$success_snapshot_sha" == "$(sha256sum -- "$success_harness/ai_snapshot.json" | awk '{print $1}')" &&
   "$success_verification_sha" == "$(sha256sum -- "$success_harness/verification.json" | awk '{print $1}')" &&
   "$success_journal_sha" == "$(sha256sum -- "$success_harness/integration-upgrade-v3.json" | awk '{print $1}')" ]] || \
    fail 'idempotent v3 upgrade changed committed evidence'

note 'prepared half-state blocks unrelated commands and is resumed from the journal'
node - "$success_harness/integration-upgrade-v3.json" "$success_harness/ai_snapshot.json" <<'NODE'
const fs = require('fs');
const [journalFile, snapshotFile] = process.argv.slice(2);
const journal = JSON.parse(fs.readFileSync(journalFile, 'utf8'));
journal.status = 'prepared';
journal.committed_at = null;
fs.writeFileSync(journalFile, JSON.stringify(journal, null, 2) + '\n');
fs.writeFileSync(snapshotFile, JSON.stringify(journal.source_snapshot, null, 2) + '\n');
NODE
run_managed_at "$success_repo" scripts/change_status.sh "$change" --json
assert_status 6
assert_contains "$RUN_OUTPUT" 'only task_verify.sh --upgrade-v3 may resume'
run_managed_at "$success_repo" scripts/task_verify.sh --upgrade-v3 "$change"
assert_status 0
node - "$success_harness/ai_snapshot.json" "$success_harness/verification.json" \
    "$success_harness/integration-upgrade-v3.json" <<'NODE'
const fs = require('fs');
const [snapshotFile, verificationFile, journalFile] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile));
const verification = JSON.parse(fs.readFileSync(verificationFile));
const journal = JSON.parse(fs.readFileSync(journalFile));
if (snapshot.schema_version !== 4 || verification.schema_version !== 3 || journal.status !== 'committed') {
  throw new Error('prepared mixed state was not recovered');
}
NODE

note 'committed target is re-approved without moving the implementation base, then accepts task evidence and later managed commands'
implementation_before=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).implementation_base_commit" "$success_harness/ai_snapshot.json")
baselined_before=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1])).implementation_baselined_at" "$success_harness/ai_snapshot.json")
journal_before=$(sha256sum -- "$success_harness/integration-upgrade-v3.json" | awk '{print $1}')
export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready
run_managed_at "$success_repo" scripts/snapshot_update.sh --refresh-planning-baseline
assert_status 0
[[ "$preupgrade_footprint_sha" == "$(sha256sum -- "$success_harness/change-footprint.json" | awk '{print $1}')" ]] || \
    fail 'post-upgrade reapproval rewrote an existing valid footprint'
node - "$success_harness/ai_snapshot.json" "$implementation_before" "$baselined_before" <<'NODE'
const fs = require('fs');
const [file, implementationBefore, baselinedBefore] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file));
const digest = value => typeof value === 'string' && /^sha256:[0-9a-f]{64}$/.test(value);
if (snapshot.schema_version !== 4 || snapshot.phase !== 'implementing' ||
    snapshot.implementation_base_commit !== implementationBefore ||
    String(snapshot.implementation_baselined_at) !== baselinedBefore ||
    !digest(snapshot.planned_base_specs_fingerprint) ||
    !digest(snapshot.planned_change_fingerprint) ||
    !digest(snapshot.planned_tdd_policy_sha256) ||
    !digest(snapshot.planned_integration_completeness_sha256) ||
    !Number.isFinite(Date.parse(snapshot.planning_approved_at))) {
  throw new Error('post-upgrade planning approval moved the implementation base or omitted a digest');
}
NODE
[[ "$journal_before" == "$(sha256sum -- "$success_harness/integration-upgrade-v3.json" | awk '{print $1}')" ]] || \
    fail 'post-upgrade approval rewrote the immutable migration journal'

printf 'post-upgrade lifecycle marker\n' >> "$success_repo/lifecycle-marker.txt"
run_managed_at "$success_repo" scripts/change_footprint.sh "$change" --json
assert_status 0
run_managed_at "$success_repo" scripts/task_verify.sh 1.1 \
    --phase alternative --exception-id upgrade-proof --kind static \
    --path lifecycle-marker.txt --observed 'the repository-document marker is present' -- \
    bash -c 'test -s lifecycle-marker.txt'
assert_status 0
run_managed_at "$success_repo" scripts/task_verify.sh --complete 1.1
assert_status 0
export STUB_OPENSPEC_INSTRUCTIONS_MODE=success
run_managed_at "$success_repo" scripts/change_status.sh "$change" --json
assert_status 0
run_managed_at "$success_repo" scripts/task_verify.sh --upgrade-v3 "$change"
assert_status 0
[[ "$journal_before" == "$(sha256sum -- "$success_harness/integration-upgrade-v3.json" | awk '{print $1}')" ]] || \
    fail 'evolved committed upgrade rewrote the immutable journal'

note 'task evidence, checked tasks and Evaluation artifacts each reject without upgrade writes'
for mode in task-evidence checked-task evaluation-artifact; do
    reject_repo="$tmp/reject $mode"
    copy_fixture "$reject_repo"
    reject_harness="$reject_repo/openspec/changes/$change/harness"
    case "$mode" in
        task-evidence)
            node - "$reject_harness/verification.json" <<'NODE'
const fs = require('fs'), file = process.argv[2], value = JSON.parse(fs.readFileSync(file));
value.tasks.push({task_id:'1.1',requirement_refs:[],changed_paths:[],footprint_observation:{},commands:[]});
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
NODE
            ;;
        checked-task)
            sed -i 's/^- \[ \] 1\.1 /- [x] 1.1 /' "$reject_repo/openspec/changes/$change/tasks.md"
            ;;
        evaluation-artifact)
            printf '{}\n' > "$reject_harness/evaluation.json"
            ;;
    esac
    before_snapshot=$(sha256sum -- "$reject_harness/ai_snapshot.json" | awk '{print $1}')
    before_verification=$(sha256sum -- "$reject_harness/verification.json" | awk '{print $1}')
    run_managed_at "$reject_repo" scripts/task_verify.sh --upgrade-v3 "$change"
    assert_status 6
    assert_upgrade_source_unchanged "$reject_repo" "$before_snapshot" "$before_verification"
done

note 'fake and non-ancestor implementation bases fail before a journal or target write'
for mode in fake non-ancestor; do
    reject_repo="$tmp/reject $mode implementation base"
    copy_fixture "$reject_repo"
    reject_harness="$reject_repo/openspec/changes/$change/harness"
    if [[ "$mode" == fake ]]; then
        rejected_base=ffffffffffffffffffffffffffffffffffffffff
    else
        rejected_base=$(git -C "$reject_repo" commit-tree "$(git -C "$reject_repo" rev-parse 'HEAD^{tree}')" -m 'unrelated implementation base')
    fi
    node - "$reject_harness/ai_snapshot.json" "$rejected_base" <<'NODE'
const fs = require('fs');
const [file, base] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file));
snapshot.implementation_base_commit = base;
fs.writeFileSync(file, JSON.stringify(snapshot, null, 2) + '\n');
NODE
    before_snapshot=$(sha256sum -- "$reject_harness/ai_snapshot.json" | awk '{print $1}')
    before_verification=$(sha256sum -- "$reject_harness/verification.json" | awk '{print $1}')
    run_managed_at "$reject_repo" scripts/task_verify.sh --upgrade-v3 "$change"
    assert_status 6
    assert_upgrade_source_unchanged "$reject_repo" "$before_snapshot" "$before_verification"
done

note 'invalid Integration planning fails before a journal or target family is written'
invalid_repo="$tmp/reject invalid plan"
copy_fixture "$invalid_repo"
invalid_harness="$invalid_repo/openspec/changes/$change/harness"
sed -i '/<!-- autoai:integration-completeness:v1 -->/,/<!-- \/autoai:integration-completeness:v1 -->/d' \
    "$invalid_repo/openspec/changes/$change/design.md"
invalid_snapshot_sha=$(sha256sum -- "$invalid_harness/ai_snapshot.json" | awk '{print $1}')
invalid_verification_sha=$(sha256sum -- "$invalid_harness/verification.json" | awk '{print $1}')
run_managed_at "$invalid_repo" scripts/task_verify.sh --upgrade-v3 "$change"
assert_status 6
assert_upgrade_source_unchanged "$invalid_repo" "$invalid_snapshot_sha" "$invalid_verification_sha"

note 'v3 upgrade 原子 journal、恢复、幂等与拒绝条件均通过'
