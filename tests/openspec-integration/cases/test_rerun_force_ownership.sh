#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/ownership project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

note '先生成 fresh OpenSpec-aware Harness'
run_setup "$repo"
assert_status 0

mkdir -p "$repo/openspec/specs/team-capability"
mkdir -p "$repo/openspec/changes/team-change/harness"
mkdir -p "$repo/openspec/changes/team-change/specs/team-capability"
printf '\n# TEAM CONFIG SENTINEL\n' >> "$repo/openspec/config.yaml"
printf '# team canonical spec\n' > "$repo/openspec/specs/team-capability/spec.md"
printf 'schema: spec-driven\n' > "$repo/openspec/changes/team-change/.openspec.yaml"
printf '# team proposal\n' > "$repo/openspec/changes/team-change/proposal.md"
printf '# team design\n' > "$repo/openspec/changes/team-change/design.md"
printf '# team tasks\n- [ ] keep\n' > "$repo/openspec/changes/team-change/tasks.md"
printf '# team delta spec\n' > "$repo/openspec/changes/team-change/specs/team-capability/spec.md"
printf '{"verdict":"Blocked","sentinel":"keep"}\n' > "$repo/openspec/changes/team-change/harness/evaluation.json"
printf '# verification sentinel\n' > "$repo/openspec/changes/team-change/harness/verification.md"
printf '{"schema_version":2,"change_name":"team-change","current_phase":"planning","next_step":"keep","must_read":["openspec/changes/team-change/tasks.md"],"sentinel":"keep"}\n' > "$repo/openspec/changes/team-change/harness/ai_snapshot.json"
printf '{"schema_version":2,"workflow":"openspec","active_change":"team-change","phase":"planning","current_step":"keep","next_step":"keep","must_read":["openspec/changes/team-change/tasks.md"],"updated_at":"2026-07-14T00:00:00Z","sentinel":"keep"}\n' > "$repo/ai_snapshot.json"
printf '\nTEAM RUNTIME SENTINEL\n' >> "$repo/claude-progress.txt"
printf '\nTEAM RCA SENTINEL\n' >> "$repo/defect-rca.md"
printf '\nTEAM TEMPLATE SENTINEL\n' >> "$repo/CLAUDE.md"

protected_paths=(
    openspec/config.yaml
    openspec/specs/team-capability/spec.md
    openspec/changes/team-change/.openspec.yaml
    openspec/changes/team-change/proposal.md
    openspec/changes/team-change/design.md
    openspec/changes/team-change/tasks.md
    openspec/changes/team-change/specs/team-capability/spec.md
    openspec/changes/team-change/harness/evaluation.json
    openspec/changes/team-change/harness/verification.md
    openspec/changes/team-change/harness/ai_snapshot.json
    ai_snapshot.json
    claude-progress.txt
    defect-rca.md
)

before="$tmp/protected-before.txt"
after="$tmp/protected-after.txt"
fingerprint_paths "$repo" "${protected_paths[@]}" > "$before"

note '普通重跑只检查项目 list 兼容性，不因未完成 change 的 strict validation 阻塞'
export STUB_OPENSPEC_VALIDATE_MODE=error
run_setup "$repo"
assert_status 0
fingerprint_paths "$repo" "${protected_paths[@]}" > "$after"
assert_files_equal "$before" "$after"
assert_file_contains "$repo/CLAUDE.md" 'TEAM TEMPLATE SENTINEL'

init_count=$(grep -Fc $'openspec\tinit\t.\t--tools\tnone\t--profile\tcore' "$STUB_CALL_LOG" || true)
[[ "$init_count" -eq 1 ]] || fail "已有 OpenSpec 项目重复执行 init，次数=$init_count"

note '--force 仅备份更新 AutoAI 模板，不覆盖状态、evidence 或 Team/OpenSpec 制品'
run_setup "$repo" --force
assert_status 0
fingerprint_paths "$repo" "${protected_paths[@]}" > "$after"
assert_files_equal "$before" "$after"
assert_file_not_contains "$repo/CLAUDE.md" 'TEAM TEMPLATE SENTINEL'

backup_count=0
while IFS= read -r backup; do
    backup_count=$((backup_count + 1))
    assert_file_contains "$backup" 'TEAM TEMPLATE SENTINEL'
done < <(find "$repo" -maxdepth 1 -type f -name 'CLAUDE.md.bak.*' -print)
[[ "$backup_count" -eq 1 ]] || fail "期望恰好一个 CLAUDE.md 备份，实际为 $backup_count"

init_count=$(grep -Fc $'openspec\tinit\t.\t--tools\tnone\t--profile\tcore' "$STUB_CALL_LOG" || true)
[[ "$init_count" -eq 1 ]] || fail "--force 对已有 OpenSpec 项目重复执行 init，次数=$init_count"
validate_count=$(grep -c $'openspec\tvalidate\t--all\t--strict' "$STUB_CALL_LOG" || true)
[[ "$validate_count" -eq 1 ]] || fail "已有项目重跑不应 strict validate 所有在途 change，次数=$validate_count"
