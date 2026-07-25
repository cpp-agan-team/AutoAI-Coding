#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
base="$tmp/task secret argv base"
init_git_repo "$base"

export STUB_CALL_LOG="$tmp/setup-dependency-calls.log"
install_stub_path
reset_stub_environment
run_setup "$base"
assert_status 0
export PATH=$REAL_TEST_PATH

recorder="$tmp/record-command-execution.sh"
cat > "$recorder" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "$1"
EOF
chmod 755 "$recorder"

run_task_probe() {
    local label=$1 secret_arg=$2 marker repo
    marker="$tmp/command-ran-$label"
    repo="$tmp/task secret argv $label"
    cp -a -- "$base" "$repo"
    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(cd "$repo" && scripts/task_verify.sh 1.1 --kind behavior -- \
        "$recorder" "$marker" --header "$secret_arg" 2>&1)
    RUN_STATUS=$?
    set -e
    if [[ "$RUN_STATUS" -ne 2 ]]; then
        printf '[ASSERT] %s argv 应在任何 lock/command 前以 rc=2 拒绝，实际 rc=%s\n' "$label" "$RUN_STATUS" >&2
        return 1
    fi
    if [[ "$RUN_OUTPUT" != *'credential-bearing argv'* && "$RUN_OUTPUT" != *'possible secret in argv'* ]]; then
        printf '[ASSERT] %s argv 未给出明确的 secret 拒绝原因\n' "$label" >&2
        return 1
    fi
    if [[ -e "$marker" ]]; then
        printf '[ASSERT] %s argv 被拒绝前仍执行了命令\n' "$label" >&2
        return 1
    fi
}

failures=0
note 'Generator task evidence 禁止 Authorization Bearer、X-API-Key 与 Cookie 出现在 argv'
run_task_probe authorization-bearer 'Authorization: Bearer task-secret-7ec0b9' || failures=$((failures + 1))
run_task_probe x-api-key 'X-API-Key: task-secret-6a146c' || failures=$((failures + 1))
run_task_probe cookie 'Cookie: session=task-secret-2935df' || failures=$((failures + 1))

(( failures == 0 )) || fail "task secret argv regression failed ($failures assertions)"
note '三类 HTTP 凭据都在命令执行和 evidence 写入前 fail-closed'
