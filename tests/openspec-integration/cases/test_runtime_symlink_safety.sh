#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
base="$tmp/runtime symlink base"
init_git_repo "$base"

export STUB_CALL_LOG="$tmp/setup-dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$base"
assert_status 0
export PATH=$REAL_TEST_PATH

prepare_change_repo() {
    local destination=$1 change=${2:-security-probe}
    cp -a -- "$base" "$destination"
    mkdir -p "$destination/openspec/changes/$change/harness"
    printf '# Defect RCA — %s\n\n' "$change" > "$destination/openspec/changes/$change/harness/defect-rca.md"
    node - "$destination/ai_snapshot.json" "$change" <<'NODE'
const fs = require('fs');
const [file, change] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
snapshot.active_change = change;
snapshot.phase = 'planning';
snapshot.current_step = 'security-boundary-probe';
snapshot.next_step = 'reject unsafe runtime paths';
fs.writeFileSync(file, JSON.stringify(snapshot, null, 2) + '\n');
NODE
}

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

directory_signature() {
    local directory=$1
    printf '%s\t%s\t%s\t%s\n' \
        "$(stat -c '%a' -- "$directory")" \
        "$(stat -c '%y' -- "$directory")" \
        "$(stat -c '%z' -- "$directory")" \
        "$(fingerprint_tree "$directory")"
}

file_signature() {
    local file=$1
    printf '%s\t%s\t%s\n' \
        "$(stat -c '%a' -- "$file")" \
        "$(stat -c '%s' -- "$file")" \
        "$(sha256sum -- "$file" | awk '{print $1}')"
}

failures=0

note '.ai-harness/locks 为符号链接时，受管命令不能在仓库外创建再删除锁'
lock_repo="$tmp/runtime lock symlink"
prepare_change_repo "$lock_repo"
lock_victim="$tmp/external lock victim"
mkdir -p "$lock_victim"
printf 'LOCK VICTIM SENTINEL\n' > "$lock_victim/sentinel.txt"
chmod 750 "$lock_victim"
chmod 640 "$lock_victim/sentinel.txt"
touch -t 200001010101 "$lock_victim"
rm -rf -- "$lock_repo/.ai-harness/locks"
ln -s "$lock_victim" "$lock_repo/.ai-harness/locks"
before=$(directory_signature "$lock_victim")
run_runtime_at "$lock_repo" scripts/change_select.sh missing-change
after=$(directory_signature "$lock_victim")
if [[ "$RUN_STATUS" -ne 4 ]]; then
    printf '[ASSERT] unsafe runtime lock path 应 rc=4，实际 rc=%s\n' "$RUN_STATUS" >&2
    failures=$((failures + 1))
fi
if [[ "$before" != "$after" ]]; then
    printf '[ASSERT] .ai-harness/locks symlink 导致了仓库外创建/删除写入\n' >&2
    failures=$((failures + 1))
fi

note '.ai-harness/logs 为符号链接时，archive 必须在创建日志前拒绝'
log_repo="$tmp/runtime log symlink"
prepare_change_repo "$log_repo"
log_victim="$tmp/external log victim"
mkdir -p "$log_victim"
printf 'LOG VICTIM SENTINEL\n' > "$log_victim/sentinel.txt"
chmod 750 "$log_victim"
chmod 600 "$log_victim/sentinel.txt"
touch -t 200001010101 "$log_victim"
rm -rf -- "$log_repo/.ai-harness/logs"
ln -s "$log_victim" "$log_repo/.ai-harness/logs"
runtime_bin="$tmp/runtime-bin"
mkdir -p "$runtime_bin"
cat > "$runtime_bin/npx" <<'EOF'
#!/usr/bin/env bash
exit 64
EOF
chmod 755 "$runtime_bin/npx"
before=$(directory_signature "$log_victim")
run_runtime_at "$log_repo" env PATH="$runtime_bin:$PATH" scripts/change_archive.sh security-probe
after=$(directory_signature "$log_victim")
if [[ "$RUN_STATUS" -ne 4 ]]; then
    printf '[ASSERT] unsafe runtime log path 应 rc=4，实际 rc=%s\n' "$RUN_STATUS" >&2
    failures=$((failures + 1))
fi
if [[ "$before" != "$after" ]]; then
    printf '[ASSERT] .ai-harness/logs symlink 导致了仓库外日志写入\n' >&2
    failures=$((failures + 1))
fi

note 'change-local defect-rca.md 为符号链接时，RCA 入口不能追加仓库外文件'
rca_repo="$tmp/runtime rca symlink"
prepare_change_repo "$rca_repo"
rca_victim="$tmp/external rca victim.md"
printf 'RCA VICTIM MUST STAY BYTE IDENTICAL\n' > "$rca_victim"
chmod 640 "$rca_victim"
rm -f -- "$rca_repo/openspec/changes/security-probe/harness/defect-rca.md"
ln -s "$rca_victim" "$rca_repo/openspec/changes/security-probe/harness/defect-rca.md"
before=$(file_signature "$rca_victim")
run_runtime_at "$rca_repo" scripts/rca_new.sh security-probe
after=$(file_signature "$rca_victim")
if [[ "$RUN_STATUS" -ne 4 ]]; then
    printf '[ASSERT] unsafe change-local RCA path 应 rc=4，实际 rc=%s\n' "$RUN_STATUS" >&2
    failures=$((failures + 1))
fi
if [[ "$before" != "$after" ]]; then
    printf '[ASSERT] defect-rca.md symlink 导致了仓库外追加写入\n' >&2
    failures=$((failures + 1))
fi

(( failures == 0 )) || fail "runtime symlink regression failed ($failures assertions)"
note 'lock、log 与 change-local RCA 路径均 fail-closed，仓库外 victim 未变化'
