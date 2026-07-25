#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/isolation pilot project"
writer="$tmp/isolation writer worktree"
contender="$tmp/isolation contender worktree"
change=isolate-widget

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

run_at() {
    local directory=$1
    shift
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$directory" && "$@" 2>&1)
    RUN_STATUS=$?
    set -e
}

assert_nonzero() {
    [[ "$RUN_STATUS" -ne 0 ]] || fail '期望命令被安全门禁拒绝，实际退出 0'
}

json_value() {
    local expression=$1
    local file=$2
    node -p "$expression" "$file"
}

worktree_paths() {
    git -C "$repo" worktree list --porcelain \
        | awk '/^worktree / { print substr($0, 10) }' \
        | LC_ALL=C sort
}

branch_names() {
    git -C "$repo" for-each-ref --format='%(refname)' refs/heads \
        | LC_ALL=C sort
}

init_git_repo "$repo"
export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment
export STUB_OPENSPEC_INSTRUCTIONS_MODE=ready

note '生成默认休眠的 Harness，并建立已批准、已冻结的 change fixture'
run_setup "$repo"
assert_status 0
git -C "$repo" config user.name 'AutoAI Isolation Test'
git -C "$repo" config user.email 'autoai-isolation@example.invalid'

(
    cd "$repo"
    scripts/change_new.sh "$change" >/dev/null
    use_modern_v2_fixture "$repo" "$change"
)

change_dir="$repo/openspec/changes/$change"
mkdir -p "$change_dir/specs/widget" "$repo/src"
cat > "$repo/src/widget.cpp" <<'EOF'
int widget_value() {
    return 1;
}
EOF
cat > "$change_dir/proposal.md" <<'EOF'
# Isolate widget implementation

Change the widget behavior in one explicitly authorized linked worktree.
EOF
cat > "$change_dir/specs/widget/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Isolated widget behavior

The widget SHALL expose the approved value after isolated implementation.

#### Scenario: Approved value is observable

- **WHEN** the widget value is queried
- **THEN** the approved value is returned
EOF
cat > "$change_dir/tasks.md" <<'EOF'
# Tasks

- [ ] 1.1 Implement the isolated widget behavior
  - Covers: `specs/widget/spec.md` | `ADDED` | `Isolated widget behavior` | `Approved value is observable`
  - Verify: `test`
EOF
cat > "$change_dir/design.md" <<'EOF'
# Design

Reuse the existing source file. The linked-worktree pilot has one Generator writer and no Git lifecycle authority.

<!-- autoai:implementation-economy:v1 -->
```json
{
  "schema_version": 1,
  "profile": "micro",
  "rationale": "One existing implementation file is sufficient; no public API, target, or dependency is added.",
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
      "added_lines": {"expected": 4, "review_at": 8, "hard_limit": 12},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "tests": {
      "added_lines": {"expected": 4, "review_at": 8, "hard_limit": 12},
      "touched_files": {"expected": 1, "review_at": 2, "hard_limit": 3},
      "new_files": {"expected": 0, "review_at": 1, "hard_limit": 2}
    },
    "project_support": {
      "added_lines": {"expected": 0, "review_at": 2, "hard_limit": 4},
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

# Fixture 用户动作：建立初始提交，随后通过受管命令记录人工批准的 planning/base。
git -C "$repo" add -A
git -C "$repo" commit -qm 'user: establish approved isolation fixture'
run_at "$repo" scripts/snapshot_update.sh \
    --freeze-planning-baseline --freeze-implementation-base \
    --phase implementing --current-step implementation-base-frozen \
    --next-step enter-authorized-isolation
assert_status 0
git -C "$repo" add -A
git -C "$repo" commit -qm 'user: persist approved planning and implementation baseline'

# Fixture 用户动作：Harness 不得执行这些 worktree/branch 创建命令。
git -C "$repo" worktree add -q -b isolation-writer "$writer" HEAD
git -C "$repo" worktree add -q -b isolation-contender "$contender" HEAD

common_git_dir=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
namespace="$common_git_dir/autoai-harness/isolation-v1"
lease_file="$namespace/leases/$change.json"
local_token_file="$writer/.ai-harness/locks/isolation-writer.json"

note 'status 在 primary/linked worktree 都是零写读取；primary acquire 明确拒绝且不创建 fallback'
assert_path_absent "$namespace"
writer_before=$(fingerprint_tree "$writer")
run_at "$writer" scripts/harness_lock.sh isolation-status "$change"
assert_status 0
status_json="$tmp/writer-status.json"
printf '%s\n' "$RUN_OUTPUT" > "$status_json"
[[ "$writer_before" == "$(fingerprint_tree "$writer")" ]] || fail 'isolation-status 修改了 linked worktree'
assert_path_absent "$namespace"
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).worktree_kind' "$status_json") == linked ]] || \
    fail 'linked worktree 身份未被识别'
challenge=$(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).confirmation_challenge' "$status_json")

run_at "$repo" scripts/harness_lock.sh isolation-status "$change"
assert_status 0
primary_status="$tmp/primary-status.json"
printf '%s\n' "$RUN_OUTPUT" > "$primary_status"
primary_challenge=$(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).confirmation_challenge' "$primary_status")
repo_id=$(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).repo_id' "$primary_status")
run_at "$repo" scripts/harness_lock.sh isolation-acquire "$change" \
    --reason 'primary must stay coordinator-only' --confirm "$primary_challenge"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'requires an existing Git linked worktree'
assert_path_absent "$namespace"

note '错误 challenge 和含凭据 reason 在任何 shared state 写入前失败，且不回显秘密'
run_at "$writer" scripts/harness_lock.sh isolation-acquire "$change" \
    --reason 'explicit linked writer authorization' --confirm wrong-challenge
assert_nonzero
assert_contains "$RUN_OUTPUT" 'confirmation challenge mismatch'
assert_path_absent "$namespace"

reason_secret='token=do-not-persist-this-value'
run_at "$writer" scripts/harness_lock.sh isolation-acquire "$change" \
    --reason "$reason_secret" --confirm "$challenge"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'isolation reason invalid'
assert_not_contains "$RUN_OUTPUT" 'do-not-persist-this-value'
assert_path_absent "$namespace"

note '不安全的既有 common state 父目录必须在创建 namespace 前拒绝'
mkdir -p "$common_git_dir/autoai-harness"
chmod 0777 "$common_git_dir/autoai-harness"
run_at "$writer" scripts/harness_lock.sh isolation-acquire "$change" \
    --reason 'must reject unsafe common state parent before writing' --confirm "$challenge"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'isolation state owner/mode mismatch: parent'
assert_path_absent "$namespace"
assert_path_absent "$local_token_file"
chmod 0700 "$common_git_dir/autoai-harness"

note '合法显式授权创建 common lease 与本地 token；common state 只保存 token hash'
run_at "$writer" scripts/harness_lock.sh isolation-acquire "$change" \
    --reason 'user approved one isolated Generator writer' --confirm "$challenge"
assert_status 0
lease_id=$RUN_OUTPUT
[[ "$lease_id" =~ ^lease-[0-9a-f]{24}$ ]] || fail 'acquire 未返回合法 lease ID'
assert_path_exists "$lease_file"
assert_path_exists "$local_token_file"
[[ $(stat -c '%a' -- "$lease_file") == 600 ]] || fail 'common lease 权限不是 0600'
[[ $(stat -c '%a' -- "$local_token_file") == 600 ]] || fail 'local token 权限不是 0600'
node - "$lease_file" "$local_token_file" "$writer" "$lease_id" <<'NODE'
const fs=require('fs'),crypto=require('crypto');
const [leaseFile,localFile,writer,id]=process.argv.slice(2);
const lease=JSON.parse(fs.readFileSync(leaseFile)),local=JSON.parse(fs.readFileSync(localFile));
const digest=v=>'sha256:'+crypto.createHash('sha256').update(v).digest('hex');
if(lease.lease_id!==id||local.lease_id!==id||lease.change_name!==local.change_name)throw Error('lease/local identity mismatch');
if(lease.worktree_root!==fs.realpathSync(writer)||lease.token_sha256!==digest(local.token))throw Error('token hash or worktree binding mismatch');
if(fs.readFileSync(leaseFile,'utf8').includes(local.token))throw Error('raw owner token leaked into common lease');
NODE

note '失败 baseline 被记录为 blocked，不能 activate；显式 release 后才能重新授权'
run_at "$writer" scripts/harness_lock.sh isolation-baseline "$change" \
    --kind test -- bash -c 'exit 9'
assert_status 6
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).state' "$lease_file") == blocked ]] || \
    fail '失败 baseline 没有阻塞 lease'
run_at "$writer" scripts/harness_lock.sh isolation-activate "$change" --confirm "$lease_id"
assert_nonzero
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).state' "$lease_file") == blocked ]] || \
    fail '失败 activate 改写了 blocked lease'
run_at "$writer" scripts/harness_lock.sh isolation-release "$change" \
    --reason 'discard failed baseline authorization' --confirm "$lease_id"
assert_status 0
assert_path_absent "$lease_file"
assert_path_absent "$local_token_file"

note '重新授权后 credential-bearing argv 在执行前拒绝，成功 executable baseline 才允许 activate'
run_at "$writer" scripts/harness_lock.sh isolation-status "$change"
assert_status 0
status_json="$tmp/writer-status-second.json"
printf '%s\n' "$RUN_OUTPUT" > "$status_json"
challenge=$(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).confirmation_challenge' "$status_json")
run_at "$writer" scripts/harness_lock.sh isolation-acquire "$change" \
    --reason 'user re-approved writer after failed baseline' --confirm "$challenge"
assert_status 0
lease_id=$RUN_OUTPUT

note 'common state 的私有权限、atomic-temp 恢复和 marker identity 都必须 fail closed'
lease_sha_before=$(sha256sum -- "$lease_file" | awk '{print $1}')
chmod 0644 "$lease_file"
run_at "$writer" scripts/harness_lock.sh isolation-status "$change"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'isolation state owner/mode mismatch'
[[ "$lease_sha_before" == "$(sha256sum -- "$lease_file" | awk '{print $1}')" ]] || \
    fail 'mode 门禁失败时改写了 common lease'
chmod 0600 "$lease_file"

token_sha_before=$(sha256sum -- "$local_token_file" | awk '{print $1}')
chmod 0644 "$local_token_file"
run_at "$writer" scripts/harness_lock.sh isolation-status "$change"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'isolation state owner/mode mismatch: local writer token'
[[ "$token_sha_before" == "$(sha256sum -- "$local_token_file" | awk '{print $1}')" ]] || \
    fail 'mode 门禁失败时改写了 local writer token'
chmod 0600 "$local_token_file"

( exit 0 ) &
dead_pid=$!
wait "$dead_pid"
atomic_temp="$namespace/leases/.isolation-$change.json-$dead_pid-1700000000000-abcdef"
printf '{' > "$atomic_temp"
chmod 0600 "$atomic_temp"
run_at "$writer" scripts/harness_lock.sh isolation-recover "$change" \
    --reason 'recover interrupted atomic baseline write' --confirm "$lease_id"
assert_status 0
assert_contains "$RUN_OUTPUT" 'Recovered 1 interrupted atomic write(s)'
assert_path_absent "$atomic_temp"
assert_path_exists "$lease_file"
assert_path_exists "$local_token_file"
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).baselines.length' "$lease_file") == 0 ]] || \
    fail 'atomic-temp recovery 改写了 live lease'

marker_file="$namespace/enabling-$change.json"
worktree_id=$(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).worktree_id' "$lease_file")
guard_sha=$(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).guard_sha256' "$lease_file")
write_test_marker() {
    local schema=$1 guard=$2
    node - "$marker_file" "$change" "$worktree_id" "$guard" "$dead_pid" "$schema" <<'NODE'
const fs=require('fs');
const [file,change,worktreeId,guard,pid,schema]=process.argv.slice(2);
const marker={
  schema_version:Number(schema),
  change_name:change,
  worktree_id:worktreeId,
  started_at:new Date().toISOString(),
  guard_sha256:guard,
  pid:Number(pid),
  operation_id:'isolation-op-'+'a'.repeat(24)
};
fs.writeFileSync(file,JSON.stringify(marker,null,2)+'\n',{mode:0o600});
NODE
}

write_test_marker 2 "$guard_sha"
run_at "$writer" scripts/harness_lock.sh isolation-recover "$change" \
    --reason 'must reject malformed marker schema' --confirm "$lease_id"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'interrupted owner marker identity mismatch'
assert_path_exists "$marker_file"

invalid_guard="sha256:$(printf '0%.0s' {1..64})"
write_test_marker 1 "$invalid_guard"
run_at "$writer" scripts/harness_lock.sh isolation-recover "$change" \
    --reason 'must reject mismatched marker guard' --confirm "$lease_id"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'interrupted owner marker identity mismatch'
assert_path_exists "$marker_file"
rm -f -- "$marker_file"
assert_path_exists "$lease_file"
assert_path_exists "$local_token_file"

note 'curl user credential argv 在执行和持久化前被拒绝'
curl_secret='curl-user:do-not-persist-curl-secret'
run_at "$writer" scripts/harness_lock.sh isolation-baseline "$change" \
    --kind test -- curl -u "$curl_secret" https://example.invalid/
assert_status 2
assert_contains "$RUN_OUTPUT" 'credential-bearing baseline argv is forbidden'
assert_not_contains "$RUN_OUTPUT" 'do-not-persist-curl-secret'
run_at "$writer" scripts/harness_lock.sh isolation-baseline "$change" \
    --kind test -- curl "--user=$curl_secret" https://example.invalid/
assert_status 2
assert_contains "$RUN_OUTPUT" 'credential-bearing baseline argv is forbidden'
assert_not_contains "$RUN_OUTPUT" 'do-not-persist-curl-secret'
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).baselines.length' "$lease_file") == 0 ]] || \
    fail '被拒绝的 curl credential argv 仍写入了 baseline'

run_at "$writer" scripts/harness_lock.sh isolation-baseline "$change" \
    --kind test -- bash --token=do-not-run-this-secret
assert_status 2
assert_contains "$RUN_OUTPUT" 'credential-bearing baseline argv is forbidden'
assert_not_contains "$RUN_OUTPUT" 'do-not-run-this-secret'
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).baselines.length' "$lease_file") == 0 ]] || \
    fail '被拒绝的 secret argv 仍写入了 baseline'

note '远未来 live lease 必须 fail closed；五分钟内回拨则把 baseline 单调钳制到 acquired_at'
cp -p -- "$lease_file" "$tmp/lease-before-clock-tests.json"
node - "$lease_file" <<'NODE'
const fs=require('fs'),file=process.argv[2],lease=JSON.parse(fs.readFileSync(file));
lease.acquired_at=new Date(Date.now()+360000).toISOString();
fs.writeFileSync(file,JSON.stringify(lease,null,2)+'\n');
NODE
future_lease_sha=$(sha256sum -- "$lease_file" | awk '{print $1}')
run_at "$writer" scripts/harness_lock.sh isolation-status "$change"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'isolation lease identity mismatch'
[[ "$future_lease_sha" == "$(sha256sum -- "$lease_file" | awk '{print $1}')" ]] || \
    fail 'future-time rejection modified the live lease'
cp -p -- "$tmp/lease-before-clock-tests.json" "$lease_file"

rollback_floor=$(( $(node -p 'Date.now()') + 240000 ))
node - "$lease_file" "$rollback_floor" <<'NODE'
const fs=require('fs'),[file,floorRaw]=process.argv.slice(2),lease=JSON.parse(fs.readFileSync(file));
lease.acquired_at=new Date(Number(floorRaw)).toISOString();
fs.writeFileSync(file,JSON.stringify(lease,null,2)+'\n');
NODE
run_at "$writer" scripts/harness_lock.sh isolation-baseline "$change" \
    --kind test -- bash -c 'exit 0'
assert_status 0
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).baselines[0].result' "$lease_file") == Pass ]] || \
    fail '成功 baseline 没有形成 Pass 记录'
node - "$lease_file" <<'NODE'
const fs=require('fs'),lease=JSON.parse(fs.readFileSync(process.argv[2])),record=lease.baselines[0];
if (Date.parse(record.started_at)<Date.parse(lease.acquired_at) ||
    Date.parse(record.finished_at)<Date.parse(record.started_at)) {
  throw new Error('rollback-window baseline was not normalized monotonically');
}
NODE

note 'activate 的 predecessor+1ms 超出五分钟边界时必须拒绝且不能写坏 pending lease'
activation_now=$(node -p 'Date.now()')
node - "$lease_file" "$activation_now" <<'NODE'
const fs=require('fs'),[file,nowRaw]=process.argv.slice(2),lease=JSON.parse(fs.readFileSync(file)),edge=Number(nowRaw)+300000;
lease.acquired_at=new Date(edge).toISOString();
lease.baselines[0].started_at=new Date(edge).toISOString();
lease.baselines[0].finished_at=new Date(edge).toISOString();
fs.writeFileSync(file,JSON.stringify(lease,null,2)+'\n');
NODE
activation_edge_sha=$(sha256sum -- "$lease_file" | awk '{print $1}')
run_at "$writer" env AUTOAI_TEST_NOW_MS="$activation_now" NODE_OPTIONS="--require=$fixed_clock" \
    scripts/harness_lock.sh isolation-activate "$change" --confirm "$lease_id"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'timestamp exceeds clock tolerance'
[[ "$activation_edge_sha" == "$(sha256sum -- "$lease_file" | awk '{print $1}')" ]] || \
    fail 'activation clock-boundary rejection modified the pending lease'

activation_floor=$(( $(node -p 'Date.now()') + 240000 ))
node - "$lease_file" "$activation_floor" <<'NODE'
const fs=require('fs'),[file,floorRaw]=process.argv.slice(2),lease=JSON.parse(fs.readFileSync(file)),floor=Number(floorRaw);
lease.acquired_at=new Date(floor).toISOString();
lease.baselines[0].started_at=new Date(floor).toISOString();
lease.baselines[0].finished_at=new Date(floor).toISOString();
fs.writeFileSync(file,JSON.stringify(lease,null,2)+'\n');
NODE
run_at "$writer" scripts/harness_lock.sh isolation-activate "$change" --confirm "$lease_id"
assert_status 0
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).state' "$lease_file") == active ]] || \
    fail '成功 baseline 后 lease 未激活'
node - "$lease_file" <<'NODE'
const fs=require('fs'),lease=JSON.parse(fs.readFileSync(process.argv[2]));
if (Date.parse(lease.activated_at)<=Date.parse(lease.baselines.at(-1).finished_at)) {
  throw new Error('activation did not advance beyond the final baseline');
}
NODE

note '第二 worktree 可以只读 status，但同 change 的受管写入口因无 token/lease 而拒绝'
contender_rca="$contender/openspec/changes/$change/harness/defect-rca.md"
contender_rca_before=$(sha256sum -- "$contender_rca" | awk '{print $1}')
run_at "$contender" scripts/harness_lock.sh isolation-status "$change"
assert_status 0
contender_status="$tmp/contender-status.json"
printf '%s\n' "$RUN_OUTPUT" > "$contender_status"
[[ $(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).change_lease.lease_id' "$contender_status") == "$lease_id" ]] || \
    fail '只读 contender 未看到 shared lease'
run_at "$contender" scripts/change_status.sh "$change" --json
assert_status 0
run_at "$contender" scripts/rca_new.sh "$change"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'isolation authority rejected rca'
[[ "$contender_rca_before" == "$(sha256sum -- "$contender_rca" | awk '{print $1}')" ]] || \
    fail '无 writer lease 的 contender 改写了 change evidence'

note 'common lease symlink 攻击使受管写入 fail closed，恢复测试夹具后 owner 仍可继续'
mv -- "$lease_file" "$lease_file.saved"
ln -s -- "$(basename "$lease_file.saved")" "$lease_file"
run_at "$writer" scripts/rca_new.sh "$change"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'isolation authority rejected rca'
unlink -- "$lease_file"
mv -- "$lease_file.saved" "$lease_file"

note 'dirty linked worktree 不能 release；只有用户显式提交后才释放 Harness lease'
node - "$writer/src/widget.cpp" <<'NODE'
const fs=require('fs'),file=process.argv[2];
fs.writeFileSync(file,fs.readFileSync(file,'utf8').replace('return 1','return 2'));
NODE
run_at "$writer" scripts/harness_lock.sh isolation-release "$change" \
    --reason 'finish isolated writer session' --confirm "$lease_id"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'worktree must be clean'
assert_path_exists "$lease_file"
assert_path_exists "$local_token_file"

# Fixture 用户动作：Harness 不得执行 add/commit；用户确认实现后自行提交。
git -C "$writer" add src/widget.cpp
git -C "$writer" commit -qm 'user: commit isolated widget implementation'
writer_commit=$(git -C "$writer" rev-parse --verify HEAD)
run_at "$writer" scripts/harness_lock.sh isolation-release "$change" \
    --reason 'user confirmed isolated implementation is committed' --confirm "$lease_id"
assert_status 0
released_history=$RUN_OUTPUT
assert_path_absent "$lease_file"
assert_path_absent "$local_token_file"
node - "$released_history" <<'NODE'
const fs=require('fs'),lease=JSON.parse(fs.readFileSync(process.argv[2]));
if (lease.state!=='released' || Date.parse(lease.released_at)<=Date.parse(lease.activated_at)) {
  throw new Error('release did not retain a strictly monotonic terminal time');
}
NODE

note 'acquire 必须检查全部 released writer HEAD，不能按回拨后的 released_at 只挑一个'
git -C "$contender" merge -q --ff-only isolation-writer
base_commit=$(git -C "$repo" rev-parse --verify HEAD)
tree_id=$(git -C "$repo" rev-parse --verify HEAD^{tree})
side_commit=$(printf 'clock-skew side writer\n' | git -C "$repo" commit-tree "$tree_id" -p "$base_commit")
fabricated_history="$namespace/history/20000101T000005Z-lease-bbbbbbbbbbbbbbbbbbbbbbbb.json"
node - "$released_history" "$fabricated_history" "$side_commit" <<'NODE'
const fs=require('fs');
const [source,target,side]=process.argv.slice(2),lease=JSON.parse(fs.readFileSync(source));
lease.lease_id='lease-'+'b'.repeat(24);
lease.acquired_at='2000-01-01T00:00:00.000Z';
for (let i=0;i<lease.baselines.length;i++) {
  lease.baselines[i].id='baseline-'+String(i+1).padStart(12,'0');
  lease.baselines[i].started_at=`2000-01-01T00:00:0${i+1}.000Z`;
  lease.baselines[i].finished_at=`2000-01-01T00:00:0${i+2}.000Z`;
}
lease.activated_at='2000-01-01T00:00:04.000Z';
lease.released_at='2000-01-01T00:00:05.000Z';
lease.final_head=side;
fs.writeFileSync(target,JSON.stringify(lease,null,2)+'\n',{mode:0o600,flag:'wx'});
NODE
run_at "$contender" scripts/harness_lock.sh isolation-status "$change"
assert_status 0
contender_clock_status="$tmp/contender-clock-status.json"
printf '%s\n' "$RUN_OUTPUT" > "$contender_clock_status"
contender_challenge=$(json_value 'JSON.parse(require("fs").readFileSync(process.argv[1])).confirmation_challenge' "$contender_clock_status")
run_at "$contender" scripts/harness_lock.sh isolation-acquire "$change" \
    --reason 'must integrate every released writer regardless of wall clock' --confirm "$contender_challenge"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'previous writer HEAD is not an ancestor'
assert_path_absent "$lease_file"
assert_path_absent "$contender/.ai-harness/locks/isolation-writer.json"
rm -f -- "$fabricated_history"

note '未集成 writer HEAD 时 primary disable 拒绝；用户显式合并后只关闭 guard，不清理 Git'
worktrees_before=$(worktree_paths)
branches_before=$(branch_names)
run_at "$repo" scripts/harness_lock.sh isolation-disable \
    --reason 'attempt before user integration' --confirm "$repo_id"
assert_nonzero
assert_contains "$RUN_OUTPUT" 'released writer HEAD is not integrated'
assert_path_exists "$namespace/enabled.json"

# Fixture 用户动作：Harness 不得执行 merge；用户按项目 Git 流程显式集成 writer 分支。
git -C "$repo" merge -q --ff-only isolation-writer
[[ $(git -C "$repo" rev-parse --verify HEAD) == "$writer_commit" ]] || fail '用户 fast-forward 未集成 writer HEAD'
run_at "$repo" scripts/harness_lock.sh isolation-disable \
    --reason 'user integrated every released writer head' --confirm "$repo_id"
assert_status 0
assert_path_absent "$namespace/enabled.json"

[[ "$worktrees_before" == "$(worktree_paths)" ]] || fail 'Harness 创建、删除或清理了 Git worktree'
[[ "$branches_before" == "$(branch_names)" ]] || fail 'Harness 创建、删除或改名了 Git branch'
assert_path_exists "$writer"
assert_path_exists "$contender"
if rg -n -- 'git["'\'' ,]+worktree["'\'' ,]+(add|remove|prune)|git["'\'' ,]+branch["'\'' ,]+-[dD]' \
    "$repo/scripts/harness_lock.sh" >/dev/null; then
    fail '生成的 isolation pilot 含自动 worktree/branch 生命周期命令'
fi

note 'common isolation namespace 被 symlink 替换时，连只读 status 也必须 fail closed'
unsafe_repo="$tmp/isolation symlink-state project"
init_git_repo "$unsafe_repo"
reset_stub_environment
run_setup "$unsafe_repo"
assert_status 0
unsafe_common=$(git -C "$unsafe_repo" rev-parse --path-format=absolute --git-common-dir)
mkdir -p "$unsafe_common/autoai-harness" "$tmp/symlink-state-target"
chmod 0700 "$unsafe_common/autoai-harness"
ln -s -- "$tmp/symlink-state-target" "$unsafe_common/autoai-harness/isolation-v1"
run_at "$unsafe_repo" scripts/harness_lock.sh isolation-status
assert_nonzero
assert_contains "$RUN_OUTPUT" 'unsafe isolation path'

note '隔离试点的授权、单写者、基线、释放、集成和 symlink/secret 安全边界均通过'
