#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helper.bash"

tmp=$(new_test_dir)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/superpowers governance project"
init_git_repo "$repo"

export STUB_CALL_LOG="$tmp/dependency-calls.log"
install_stub_path
reset_stub_environment

note 'fresh 默认模式生成完整 Superpowers 方法融合，不安装第二套工作流'
run_setup "$repo"
assert_status 0

note 'Planner 具备项目调查、真实方案比较、TDD 策略和自审约束'
assert_file_contains "$repo/prompts/planner.md" 'read the current main specs, relevant source and callers, tests and fixtures, CMake targets'
assert_file_contains "$repo/prompts/planner.md" 'compare two or three feasible approaches'
assert_file_contains "$repo/prompts/planner.md" 'Do not invent alternatives to meet a quota'
assert_file_contains "$repo/prompts/planner.md" 'Add exactly one closed `TDD Policy v1` block'
assert_file_contains "$repo/prompts/planner.md" 'Before review, self-check every artifact'
assert_file_contains "$repo/openspec/config.yaml" 'otherwise record why one path is sufficient'
assert_file_contains "$repo/prompts/planner.md" 'Integration Completeness v1'
assert_file_contains "$repo/prompts/planner.md" 'internal API, external API, callback/plugin, CLI, configuration, protocol/persistence and build/install surface'

note 'Generator 明确机器 TDD、RED 非 Pass、显式例外和审查反馈返工边界'
assert_file_contains "$repo/prompts/generator.md" 'RED -> GREEN -> REFACTOR -> REGRESSION'
assert_file_contains "$repo/prompts/generator.md" 'Record a focused RED with `task_verify.sh'
assert_file_contains "$repo/prompts/generator.md" 'RED is `ExpectedFailure`, never Pass'
assert_file_contains "$repo/prompts/generator.md" 'task_verify.sh --complete'
assert_file_contains "$repo/prompts/generator.md" 'silently add a TDD exception'
assert_file_contains "$repo/prompts/generator.md" 'Treat review feedback as a technical claim'
assert_file_contains "$repo/docs/ai/testing.md" '<!-- autoai:tdd-policy:v1 -->'
assert_file_contains "$repo/docs/ai/testing.md" 'stored only as `ExpectedFailure` or `InvalidRed`, never Pass'
assert_file_contains "$repo/docs/ai/testing.md" 'Unavailable hardware or external service remains `blocking_untested`'
assert_file_contains "$repo/prompts/generator.md" '--surface-role'
assert_file_contains "$repo/prompts/generator.md" 'return to Planner'

note 'RCA 强制单一假设、最小实验和三次失败升级'
assert_file_contains "$repo/docs/ai/rca.md" 'One hypothesis and one variable'
assert_file_contains "$repo/docs/ai/rca.md" 'After three unsuccessful direct fixes'
assert_file_contains "$repo/docs/ai/rca.md" 'it does not infer the quality of every debugging step from prose alone'
assert_file_contains "$repo/prompts/rca.md" 'one minimal single-variable experiment'
assert_file_contains "$repo/prompts/rca.md" 'After three unsuccessful fixes'

note 'Evaluator 在同一 attempt 中先审规格、后审质量，并保留唯一 verdict'
assert_file_contains "$repo/prompts/evaluator.md" 'First perform specification compliance'
assert_file_contains "$repo/prompts/evaluator.md" 'Second perform code quality'
spec_line=$(grep -nF 'First perform specification compliance' "$repo/prompts/evaluator.md" | cut -d: -f1)
quality_line=$(grep -nF 'Second perform code quality' "$repo/prompts/evaluator.md" | cut -d: -f1)
(( spec_line < quality_line )) || fail 'Evaluator 两阶段审查顺序错误'
assert_file_contains "$repo/prompts/evaluator.md" 'staged changes, unstaged changes and untracked paths'
assert_file_contains "$repo/prompts/evaluator.md" 'Raw diff is transient read-only input'
assert_file_contains "$repo/prompts/evaluator.md" 'add `change_review` with two ordered stages'
assert_file_contains "$repo/prompts/evaluator.md" 'Critical/Important cannot be Deferred'
assert_file_contains "$repo/prompts/evaluator.md" 'The Evaluation verdict remains the only final result'
assert_file_contains "$repo/docs/ai/evaluation.md" 'specification_compliance'
assert_file_contains "$repo/docs/ai/evaluation.md" 'Every completed v2 report is copied to immutable'
assert_file_contains "$repo/prompts/evaluator.md" 'assess every surface and every candidate exactly once'
assert_file_contains "$repo/prompts/evaluator.md" 'orphan'
assert_file_contains "$repo/docs/ai/evaluation.md" 'integration_completeness'

note 'Integration Completeness 生成文档固定消费者矩阵、证据 CLI 和唯一 verdict'
assert_file_contains "$repo/docs/ai/workflow.md" 'Integration Completeness v1'
assert_file_contains "$repo/docs/ai/workflow.md" '`internal_api` | `production_caller`'
assert_file_contains "$repo/docs/ai/workflow.md" 'uses installed/exported artifacts'
assert_file_contains "$repo/docs/ai/workflow.md" 'Both registration and an actual dispatch'
assert_file_contains "$repo/docs/ai/workflow.md" 'scripts/integration_surface_check.sh'
assert_file_contains "$repo/docs/ai/workflow.md" 'task_verify.sh --upgrade-v3 <change>'
assert_file_contains "$repo/docs/ai/evaluation.md" 'top-level Evaluation verdict remains the only final verdict'

note 'Fresh Context 与 linked-worktree 试点形成安全边界，不接管 Git 生命周期'
assert_file_contains "$repo/AGENTS.md" 'In one worktree there is only one writer'
assert_file_contains "$repo/AGENTS.md" 'A read-only Subagent must not switch the active change'
assert_file_contains "$repo/docs/ai/workflow.md" 'change_status.sh --agent-context'
assert_file_contains "$repo/docs/ai/workflow.md" 'harness_lock.sh isolation-*'
assert_file_contains "$repo/CLAUDE.md" 'Never create branches/worktrees, commit, merge, push, stash, reset'
assert_path_absent "$repo/docs/superpowers"
assert_path_absent "$repo/.superpowers"
assert_path_absent "$repo/prompts/reviewer.md"

if (cd "$repo" && find .claude .codex -type f -path '*superpowers*' -print -quit 2>/dev/null) | grep -q .; then
    fail '默认模式复制或安装了 Superpowers skill/hook'
fi
assert_file_not_contains "$repo/.claude/settings.json" 'superpowers'

if find "$repo/scripts" -maxdepth 1 -type f \( -iname '*worktree*' -o -iname '*subagent*' -o -iname '*reviewer*' \) -print -quit | grep -q .; then
    fail '生成了未授权的 worktree/Subagent/Reviewer 生命周期脚本'
fi

note 'Phase 1/2 证据与唯一 verdict 已进入受管入口'
assert_file_contains "$repo/scripts/task_verify.sh" '--phase'
assert_file_contains "$repo/scripts/task_verify.sh" 'ExpectedFailure'
assert_file_contains "$repo/scripts/evaluator_check.sh" 'change_review'
assert_file_contains "$repo/scripts/evaluator_check.sh" 'evaluations'
assert_file_contains "$repo/scripts/harness_lock.sh" 'isolation-acquire'
assert_path_absent "$repo/openspec/changes/review.json"
assert_path_absent "$repo/review.md"
(cd "$repo" && node scripts/manifest_policy.js >/dev/null) || fail '融合生成物破坏 manifest policy'

note '治理文档没有引入新的 Quick Brief 告警'
quick_output=$(cd "$repo" && scripts/quick_brief_check.sh)
assert_not_contains "$quick_output" '[WARN]'
