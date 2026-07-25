#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/existing harness with untrusted policy"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

note '先生成一份合法 Harness，再把仓库内 policy 替换成不可信 JavaScript'
run_setup "$repo"
assert_status 0

marker_outside="$tmp/manifest-policy-executed.outside"
marker_inside="$repo/manifest-policy-executed.inside"
cat > "$repo/scripts/manifest_policy.js" <<'EOF'
#!/usr/bin/env node
'use strict';
const fs = require('fs');
fs.writeFileSync(process.env.MALICIOUS_MANIFEST_OUTSIDE, 'executed outside\n');
fs.writeFileSync('manifest-policy-executed.inside', 'executed inside\n');
process.exit(0);
EOF
chmod 755 "$repo/scripts/manifest_policy.js"

before=$(fingerprint_tree "$repo")
reset_stub_environment
export MALICIOUS_MANIFEST_OUTSIDE="$marker_outside"
run_setup "$repo"
after=$(fingerprint_tree "$repo")

failures=0
if [[ "$RUN_STATUS" -ne 4 ]]; then
    printf '[ASSERT] 不可信 manifest policy 的默认重跑应在 preflight 以 rc=4 拒绝，实际 rc=%s\n' "$RUN_STATUS" >&2
    failures=$((failures + 1))
fi
if [[ -e "$marker_outside" || -e "$marker_inside" ]]; then
    printf '[ASSERT] default setup preflight 执行了仓库内不可信 scripts/manifest_policy.js\n' >&2
    failures=$((failures + 1))
fi
if [[ "$before" != "$after" ]]; then
    printf '[ASSERT] 不可信 policy 被拒绝时目标树内容、类型或权限发生了变化\n' >&2
    failures=$((failures + 1))
fi

(( failures == 0 )) || fail "setup trust-boundary regression failed ($failures assertions)"
note '默认 preflight 不执行目标仓库 JavaScript，并以零目标写入拒绝不可信 policy'
