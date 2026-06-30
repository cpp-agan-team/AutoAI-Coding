#!/usr/bin/env bash
# ============================================================================
# setup_ai_harness.sh — C++ (CMake) 项目 AI 编程 Harness 一键初始化
#
# 用法：在项目根目录执行
#   bash setup_ai_harness.sh
#   bash setup_ai_harness.sh --force    # 备份并覆盖已生成文件
#
# 生成文件：
#   CLAUDE.md                 — Claude Code 项目级 Harness 配置
#   AGENTS.md                 — GPT/Codex 项目级 Harness 配置
#   .claude/settings.json     — Claude Code 权限 + Hooks
#   .codex/skills/full-code-review/ — Codex 全项目代码 Review Skill
#   docs/ai/*.md              — 按需读取的细节规则
#   .cursorrules              — Cursor 项目配置
#   .vscode/settings.json     — VS Code + Copilot 配置
#   .vscode/extensions.json   — VS Code 推荐扩展
#   .clang-format             — 代码格式化配置（被 Hook 引用）
#   claude-progress.txt       — 长任务接力状态
#   session-state.md          — 当前接力轮次状态
#   spec.md                   — Planner 产出的规格说明
#   evaluation.md             — Evaluator 产出的验收报告
#   debt-register.md          — 技术债登记表
#   todo.md                   — 长任务 TODO
#   verification.md           — 验证记录
#   ai_snapshot.json          — 新会话机器可读恢复快照
#   defect-rca.md             — 缺陷根因分析和规约沉淀记录
#   init.sh                   — 环境恢复入口
#   prompts/init.md           — 第一轮初始化 Prompt
#   prompts/resume.md         — 后续接力 Prompt
#   prompts/handoff.md        — 上下文重启交接 Prompt
#   prompts/planner.md        — 规划者 Prompt
#   prompts/generator.md      — 生成者 Prompt
#   prompts/evaluator.md      — 验收者 Prompt
#   prompts/rca.md            — 缺陷 RCA 和规约自愈 Prompt
#   prompts/task.md           — Task 沙盒执行 Prompt
#   prompts/debt-scan.md      — 技术债扫描 Prompt
#   prompts/debt-fix.md       — 小步偿还技术债 Prompt
#   scripts/context_reset_check.sh — 接力自检脚本
#   scripts/snapshot_update.sh — 更新 ai_snapshot.json
#   scripts/resume_from_snapshot.sh — 从快照恢复上下文
#   scripts/quick_brief_check.sh — Quick Brief 覆盖检查
#   scripts/task_new.sh       — 创建 Task 沙盒
#   scripts/rca_new.sh        — 创建缺陷 RCA 模板
#   scripts/ai_debt_scan.sh   — 本地技术债启发式扫描
#   .gitignore (追加)         — 忽略构建产物和敏感文件
#
# 特性：幂等（已存在的文件不覆盖）、纯 bash、无额外依赖
# ============================================================================

set -euo pipefail

FORCE=0
BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"

usage() {
    cat <<'EOF'
用法：
  bash setup_ai_harness.sh [--force]

选项：
  --force   备份并覆盖已存在的 harness 文件
  -h,--help 显示帮助

默认行为：已存在文件会跳过，避免覆盖人工修改。
EOF
}

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERR] 未知参数: $arg" >&2
            usage
            exit 1
            ;;
    esac
done

# --- 颜色 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
skip()  { echo -e "${YELLOW}[SKIP]${NC}  $* (已存在)"; }
err()   { echo -e "${RED}[ERR]${NC}   $*"; }

# --- 安全写入：文件已存在则跳过 ---
safe_write() {
    local filepath="$1"
    local content="$2"
    local dir
    dir=$(dirname "$filepath")
    [ -d "$dir" ] || mkdir -p "$dir"

    if [ -f "$filepath" ]; then
        if [ "$FORCE" -eq 1 ]; then
            cp "$filepath" "${filepath}.bak.${BACKUP_SUFFIX}"
            printf '%s\n' "$content" > "$filepath"
            ok "$filepath (已覆盖，备份: ${filepath}.bak.${BACKUP_SUFFIX})"
            return 0
        fi
        skip "$filepath"
        return 0
    fi
    printf '%s\n' "$content" > "$filepath"
    ok "$filepath"
    return 0
}

# --- .gitignore 追加（去重） ---
append_gitignore() {
    local pattern="$1"
    if [ -f .gitignore ] && grep -qxF "$pattern" .gitignore 2>/dev/null; then
        return
    fi
    echo "$pattern" >> .gitignore
}

# ============================================================================
# 交互式输入
# ============================================================================

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   C++ 项目 AI Harness 一键初始化                         ║${NC}"
echo -e "${GREEN}║   配置 Claude Code / GPT-Codex / Cursor / Copilot        ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# 项目名称
default_name=$(basename "$(pwd)")
read -rp "项目名称 [${default_name}]: " PROJECT_NAME
PROJECT_NAME="${PROJECT_NAME:-$default_name}"

# C++ 标准
echo ""
echo "选择 C++ 标准："
echo "  1) C++17"
echo "  2) C++20"
echo "  3) C++23"
read -rp "请选择 [1]: " cpp_choice
case "${cpp_choice:-1}" in
    1) CPP_STD="17" ;;
    2) CPP_STD="20" ;;
    3) CPP_STD="23" ;;
    *) CPP_STD="17" ;;
esac

# 测试框架
echo ""
echo "选择测试框架："
echo "  1) Google Test (GTest)"
echo "  2) Catch2"
echo "  3) 暂不配置"
read -rp "请选择 [1]: " test_choice
case "${test_choice:-1}" in
    1) TEST_FW="gtest" ; TEST_FW_NAME="Google Test" ;;
    2) TEST_FW="catch2" ; TEST_FW_NAME="Catch2" ;;
    3) TEST_FW="none"  ; TEST_FW_NAME="未配置" ;;
    *) TEST_FW="gtest" ; TEST_FW_NAME="Google Test" ;;
esac

echo ""
info "项目: ${PROJECT_NAME} | C++${CPP_STD} | 测试: ${TEST_FW_NAME}"
echo "-----------------------------------------------------------"
echo ""

# ============================================================================
# 1. CLAUDE.md — 项目级 Harness 配置（控制在 ~100 行）
# ============================================================================

# 根据测试框架生成测试命令
if [ "$TEST_FW" = "none" ]; then
    TEST_COMMANDS="- 测试框架未配置；添加测试后运行 \`cd build && ctest --output-on-failure\`"
    TEST_RULE="- 测试框架待定，添加后请更新此文件"
else
    TEST_COMMANDS="- \`cd build && ctest --output-on-failure\` — 运行测试
- \`cd build && ctest -R <name> --output-on-failure\` — 运行指定测试"
    if [ "$TEST_FW" = "gtest" ]; then
        TEST_RULE="- 使用 Google Test，测试文件命名 *_test.cpp
- 每个 TEST/TEST_F 只测一个行为，名字用 MethodName_Scenario_Expected"
    else
        TEST_RULE="- 使用 Catch2，测试文件命名 *_test.cpp
- TEST_CASE 名用自然语言描述行为，SECTION 分正常/异常"
    fi
fi

# 根据 C++ 标准生成错误处理建议，避免在 C++17/20 中误用 std::expected。
if [ "$CPP_STD" = "23" ]; then
    ERROR_RULE="- 错误处理：库代码可使用 std::expected 或异常，应用代码用错误码/异常按场景选择"
    SRC_RECOVERABLE_RULE="- 运行时可恢复错误：优先返回 std::optional 或 std::expected"
else
    ERROR_RULE="- 错误处理：库代码用异常或 std::optional；不要使用 std::expected，除非项目显式引入兼容实现"
    SRC_RECOVERABLE_RULE="- 运行时可恢复错误：返回 std::optional，或在引入兼容库后使用 expected 类型"
fi

safe_write "CLAUDE.md" "# ${PROJECT_NAME} — AI Harness Index

本文件是短索引，不是规则大全。先读这里，再按任务需要读取 docs/ai/ 下的细节文件。

## Project Facts
- 语言：C++${CPP_STD}
- 构建：CMake 3.20+
- 编译器：GCC 12+ / Clang 15+ 均需兼容
- 测试：${TEST_FW_NAME}
- 格式化：clang-format，由 Claude hook 或编辑器触发

## Project Structure
- 保持现有项目结构，不为了 harness 新建业务目录
- build/：构建产物，禁止手动编辑
- docs/ai/：按需读取的详细 AI 规则
- AGENTS.md：GPT/Codex 项目入口，和本文件共享同一套规则源

## State Files
- ai_snapshot.json：机器可读恢复快照，优先用于新会话秒级恢复
- claude-progress.txt：当前任务状态、下一步、风险
- session-state.md：当前接力轮次、上下文健康和交接摘要
- spec.md：Planner 产出的规格、验收标准和非目标
- evaluation.md：Evaluator 产出的真实验收证据
- todo.md：可接力的剩余任务
- verification.md：已跑和未跑的验证
- debt-register.md：技术债、偏离原则和偿还记录
- defect-rca.md：缺陷 RCA、复盘结论和新规约沉淀
- init.sh：新会话恢复环境和查看状态

## Read Only What You Need
- Claude Code 读 CLAUDE.md；GPT/Codex 读 AGENTS.md；细节统一从 docs/ai/ 读取
- 新会话或接力时先读 ai_snapshot.json，再按快照声明的 must_read 文件恢复
- 阅读长文档时先看文件头部 Quick Brief；需要细节时再读正文
- 做架构、抽象或重构判断前读 docs/ai/golden-principles.md
- 改 C++ 代码前读 docs/ai/cpp.md；如目标目录已有局部 CLAUDE.md/AGENTS.md，也一并读取
- 改测试前读 docs/ai/testing.md；如测试目录已有局部 CLAUDE.md/AGENTS.md，也一并读取
- 改构建、命令或依赖前读 docs/ai/build.md
- 做规划、实现或验收前读 docs/ai/evaluation.md
- 长任务、新会话接力或上下文变长时读 docs/ai/workflow.md
- 拆分复杂任务前读 docs/ai/task-sandbox.md
- 修复缺陷或重复失败后读 docs/ai/rca.md，并更新 docs/ai/check-rules.md
- 为长文件补充摘要前读 docs/ai/quick-brief.md
- 做技术债巡检或修复前读 debt-register.md 和 prompts/debt-*.md

## Default Commands
- 配置：\`cmake -B build -DCMAKE_BUILD_TYPE=Debug\`
- 编译：\`cmake --build build -j\$(nproc)\`
${TEST_COMMANDS}

## Reuse Before New Code
- 开发前先用 \`rg\`、目录浏览和已有测试查找同类实现、公共 helper、工具脚本、CMake target 和 fixture
- 优先复用、扩展或轻量抽取现有逻辑；只有现有逻辑不满足 spec 且复用会扩大风险时，才新增实现
- 新增公共 helper 后必须登记到本文件 Shared Utilities 或对应 docs/ai/，避免下一轮重复造轮子

## Non-Negotiables
- 不要手动编辑 build/ 目录
- 不要在代码中硬编码文件路径、IP、端口
- 不要引入新第三方依赖，除非先说明理由并获得确认
- 优先选择成熟、无聊、仓库已使用的技术；不要为炫技引入新栈
- 不要重复造轮子：先查找已有逻辑、共享工具和测试辅助，能复用就复用
- 不要把未运行的验证说成已通过
- 生产和验收必须分离；Generator 不给自己的实现打最终分
- 不要 git push --force 到 main 分支

## Role Split
- Planner：把模糊需求写成 spec.md，不改业务代码
- Generator：按 spec.md 实现，不写最终验收结论
- Evaluator：像 QA 一样运行真实命令，把证据写入 evaluation.md

## Long-Running Work
- 每轮开始先读 ai_snapshot.json、claude-progress.txt、todo.md、verification.md
- 按 spec.md、todo.md 或当前 Task 的有序开发队列连续推进；完成一项并验证后，自动领取下一项
- 每个子项仍保持小而可验证，完成后及时记录验证和状态，避免攒到最后回忆
- 长任务优先拆入 tasks/TASK-*/，每个 Task 独立维护 task.md、ai_snapshot.json、verification.md、defect-rca.md
- 只有遇到阻塞、验收失败、需求不清、范围扩大、上下文变浑浊或需要人类决策时，才使用 prompts/handoff.md
- 结束前运行 scripts/snapshot_update.sh 更新 ai_snapshot.json，保证下一轮可直接恢复

## Shared Utilities
> 新增公共工具函数后在这里登记名称和位置，避免重复实现。"

safe_write "AGENTS.md" "# ${PROJECT_NAME} — GPT/Codex Harness Index

本文件是 GPT/Codex 的短索引。不要把细节规则堆在这里；需要细节时按任务读取 docs/ai/。

## Project Facts
- 语言：C++${CPP_STD}
- 构建：CMake 3.20+
- 编译器：GCC 12+ / Clang 15+ 均需兼容
- 测试：${TEST_FW_NAME}
- Claude Code 入口：CLAUDE.md
- GPT/Codex 入口：AGENTS.md

## State Files
- ai_snapshot.json：机器可读恢复快照，优先用于新会话秒级恢复
- claude-progress.txt：当前任务状态、下一步、风险
- session-state.md：当前接力轮次、上下文健康和交接摘要
- spec.md：Planner 产出的规格、验收标准和非目标
- evaluation.md：Evaluator 产出的真实验收证据
- todo.md：可接力的剩余任务
- verification.md：已跑和未跑的验证
- debt-register.md：技术债、偏离原则和偿还记录
- defect-rca.md：缺陷 RCA、复盘结论和新规约沉淀

## Read Only What You Need
- 新会话或接力：ai_snapshot.json，然后按快照声明的 must_read 文件恢复
- 工具/账号/模型配置说明：docs/ai/tooling.md
- 项目完成后的全代码 Review：使用 Codex Skill \`\$full-code-review\`
- 架构、抽象或重构判断：docs/ai/golden-principles.md
- C++ 代码：docs/ai/cpp.md
- 测试：docs/ai/testing.md
- 构建、命令或依赖：docs/ai/build.md
- 规划、实现或验收：docs/ai/evaluation.md
- 长任务、新会话接力或上下文变长：docs/ai/workflow.md
- 复杂需求拆分：docs/ai/task-sandbox.md
- 缺陷复盘和规约自愈：docs/ai/rca.md、docs/ai/check-rules.md
- 长文档摘要和分层阅读：docs/ai/quick-brief.md

## Default Commands
- 配置：\`cmake -B build -DCMAKE_BUILD_TYPE=Debug\`
- 编译：\`cmake --build build -j\$(nproc)\`
${TEST_COMMANDS}

## Reuse Before New Code
- 开发前先用 \`rg\`、目录浏览和已有测试查找同类实现、公共 helper、工具脚本、CMake target 和 fixture
- 优先复用、扩展或轻量抽取现有逻辑；只有现有逻辑不满足 spec 且复用会扩大风险时，才新增实现
- 新增公共 helper 后必须登记到相关 docs/ai/ 或共享工具清单，避免后续 GPT/Codex 轮次重复实现

## Non-Negotiables
- 不要手动编辑 build/ 目录
- 不要把 API key、token 或本机认证文件写进仓库
- 不要引入新第三方依赖，除非先说明理由并获得确认
- 不要重复造轮子：先查找已有逻辑、共享工具和测试辅助，能复用就复用
- 不要把未运行的验证说成已通过
- Generator 不给自己的实现写最终通过结论
- 不要 git push --force 到 main 分支

## Role Split
- Planner：把模糊需求写成 spec.md，不改业务代码
- Generator：按 spec.md 实现，不写最终验收结论
- Evaluator：像 QA 一样运行真实命令，把证据写入 evaluation.md

## Long-Running Work
- 每轮开始先运行 scripts/resume_from_snapshot.sh 或 scripts/context_reset_check.sh
- 按 spec.md、todo.md 或当前 Task 的有序开发队列连续推进；完成一项并验证后，自动领取下一项
- 每个子项仍保持小而可验证，完成后及时记录验证和状态，避免攒到最后回忆
- 长任务优先拆入 tasks/TASK-*/，每个 Task 独立维护 task.md、ai_snapshot.json、verification.md、defect-rca.md
- 只有遇到阻塞、验收失败、需求不清、范围扩大、上下文变浑浊或需要人类决策时，才使用 prompts/handoff.md
- 结束前运行 scripts/snapshot_update.sh 更新 ai_snapshot.json，保证下一轮可直接恢复

## Shared Utilities
> 新增公共工具函数后在这里登记名称和位置，避免重复实现。
"

safe_write "docs/ai/cpp.md" "# C++ Rules

## Hard Rules
- 优先使用智能指针和对象所有权表达，裸 new/delete 必须说明理由。
- 所有资源通过 RAII 管理，禁止手动 open/close、lock/unlock 配对散落在业务逻辑中。
- 新增功能前先搜索已有模块、公共 helper、测试 fixture 和标准库能力，优先复用，不要为局部需求反复手写 helper。
- 不修改的参数用 const&，不修改成员的方法标记 const。
- 零容忍未定义行为：不越界访问、不解引用空指针、不使用悬挂引用。
- 头文件统一使用 #pragma once。
- 单参数构造函数标记 explicit。
- 有虚函数的基类必须声明 virtual ~ClassName() = default。

## Style
- 函数建议不超过 40 行，超过时优先拆分清晰的私有函数。
- 优先用标准库算法和容器，不为简单遍历引入复杂抽象。
- 命名：类型 PascalCase，函数/变量 snake_case，常量 kPascalCase，宏 UPPER_CASE。
- include 顺序：对应头文件、项目头文件、第三方、标准库。

## Error Handling
${ERROR_RULE}
- 构造函数中的错误：抛异常，保证对象不会半初始化。
${SRC_RECOVERABLE_RULE}
- 不可恢复错误：抛 std::runtime_error 派生异常。

## Concurrency
- 共享可变状态必须用 mutex 保护，并注释锁保护的状态范围。
- 优先使用 std::lock_guard 或 std::scoped_lock。
"

safe_write "docs/ai/golden-principles.md" "# Golden Principles

这些原则用于防止 Agent 复制坏模式。发现代码与原则冲突时，先登记到 debt-register.md；能在小范围内安全修复时，再用 prompts/debt-fix.md 处理。

## Prefer Boring Technology
- 优先使用仓库已有技术、标准库、CMake 和成熟工具链。
- 不为小问题引入新框架、新构建系统或新代码生成器。
- 新依赖必须说明用途、替代方案、维护成本、许可证和构建影响。

## Reuse Before Creating
- 优先使用共享工具包、已有模块和标准库能力。
- 实现前至少检查同目录、src/include/tests、已有脚本、CMake target 和测试辅助中是否已有相似逻辑。
- 优先调用、扩展、参数化或轻量抽取现有逻辑；不要平行新增相同职责的类、函数或脚本。
- 新 helper 只能在已有能力不适用时添加，并应放在清晰可复用的位置。
- 新增实现时，在变更摘要中说明为什么不能复用已有逻辑。
- 发现重复 helper 时，登记技术债；修复时一次只合并一小类重复。

## Validate Boundaries
- 不要猜数据格式、文件布局、协议字段或外部输入范围。
- 能用类型、解析器、schema、SDK 或边界检查表达约束时，不要靠字符串拼接和隐式假设。
- 错误路径必须可观测：返回错误、抛异常或记录上下文，不要静默吞掉。

## Keep Changes Small
- 一次 PR 只偿还一个明确债务点。
- 不把风格重排、重命名和行为修复混在一起。
- 未跑验证必须写入 verification.md，不得声称完成。

## Improve The Pattern
- 如果仓库里已有坏模式，不要继续模仿；先在 debt-register.md 记录。
- 修改局部代码时，顺手让附近代码向黄金原则靠近，但不要扩大到无关模块。
"

safe_write "docs/ai/testing.md" "# Testing Rules

## Framework
- 当前选择：${TEST_FW_NAME}

## Commands
${TEST_COMMANDS}

## Rules
${TEST_RULE}
- 覆盖正常路径、边界条件、异常/错误路径。
- 每个测试只验证一个行为。
- 测试之间必须独立，不依赖执行顺序。
- 不要在测试中使用 sleep；用条件变量、虚拟时钟或可控同步点。
- 不要 mock 能直接测试的纯逻辑。
"

safe_write "docs/ai/evaluation.md" "# Evaluation Rules

## Principle
生产和验收必须分离。实现者容易偏乐观，因此最终验收必须由 Evaluator 按真实命令和可观察证据完成。

## Roles
- Planner：把模糊需求整理成 spec.md，写清目标、非目标、验收标准、风险和测试计划；不改业务代码。
- Generator：按 spec.md 实现，记录改动和自检结果；不写最终通过结论。
- Evaluator：像 QA 一样从干净状态阅读 spec.md 和 diff，运行真实命令，把证据写入 evaluation.md。

## Evaluator Must Touch Reality
- 必须运行能证明行为的命令：构建、测试、脚本、可执行程序或最小复现。
- 不能只阅读代码后说看起来没问题。
- 如果命令无法运行，必须记录阻塞原因、缺失工具和剩余风险。
- 验收结论只能是 Pass、Fail 或 Blocked。

## Evidence Standard
- 每个通过项都要对应命令或文件证据。
- 每个失败项都要给出复现步骤。
- 未验证项必须留在 evaluation.md 和 verification.md。
"

safe_write "docs/ai/tooling.md" "# AI Tooling

## Project Rule Entrypoints
- Claude Code：读取 CLAUDE.md，并使用 .claude/settings.json 的权限和 hooks。
- GPT/Codex：读取 AGENTS.md，并复用 docs/ai/、prompts/、spec.md、evaluation.md 等同一套 harness 文件。
- Codex Skill：脚本会生成 .codex/skills/full-code-review，用于项目完成后的全仓库代码 review。
- Cursor：读取 .cursorrules；详细规则仍以 docs/ai/ 为准。
- GitHub Copilot：由 .vscode/settings.json 启用，项目规范仍以 CLAUDE.md / AGENTS.md / docs/ai/ 为准。

## Model And Credential Policy
- 不要把 API key、token、cookie 或本机 auth 文件提交到项目仓库。
- GPT/Codex 的模型和 provider 通常在用户级配置中，例如 ~/.codex/config.toml。
- GPT/Codex 的 API key 通常在用户级认证文件中，例如 ~/.codex/auth.json。
- Claude Code 的认证通常由 Claude CLI 或应用自己的登录态管理，不应写入本项目。
- 如果团队需要示例配置，只提交不含密钥的 example 文件，并在文档里说明本机配置位置。

## Shared Harness
- 两个 Agent 都使用同一套状态文件：claude-progress.txt、session-state.md、todo.md、verification.md。
- 两个 Agent 都使用同一套 Planner / Generator / Evaluator 流程：spec.md、evaluation.md、prompts/*.md。
- 两个 Agent 在开发前都必须先查找已有实现、公共 helper、测试 fixture、脚本和 CMake 逻辑；能复用就复用。
- 两个 Agent 都必须遵守生产和验收分离；最终完成以 evaluation.md 的独立证据为准。
- 项目完成后需要额外做一次全仓库 review 时，让 Codex 使用 \`\$full-code-review\`，重点检查真实 bug、风险和有效优化点，不要把输出变成重复补测试清单。
"

safe_write "docs/ai/build.md" "# Build Rules

## Baseline
- CMake 版本：3.20+
- C++ 标准：C++${CPP_STD}
- 编译器：GCC 12+ / Clang 15+

## Commands
- Debug 配置：\`cmake -B build -DCMAKE_BUILD_TYPE=Debug\`
- Debug 编译：\`cmake --build build -j\$(nproc)\`
- Release 配置：\`cmake -B build -DCMAKE_BUILD_TYPE=Release\`

## Dependency Policy
- 不要在未说明理由时新增第三方依赖。
- 新增依赖必须写清用途、替代方案、构建影响和许可证风险。
- 优先选择成熟、无聊、团队熟悉、Agent 容易稳定使用的技术。
- 测试框架选择只写入规范，不代表 CMake 已完成依赖接入。

## Build Directory
- build/ 是生成目录，禁止手动编辑。
- 修改源码、CMake 或配置后重新运行构建命令验证。
"

safe_write "docs/ai/workflow.md" "# Agent Workflow Rules

## Principle
规则文件宁缺毋滥。CLAUDE.md 和 AGENTS.md 只做短索引，细节文件只在相关任务中读取。

重启胜过修补。上下文开始变浑浊时，不要靠更长总结硬撑；把状态写回文件系统，然后用干净上下文接力。

## Start of Each Round
1. 优先运行 scripts/resume_from_snapshot.sh；如果快照缺失，再运行 scripts/context_reset_check.sh。
2. Claude Code 读取 CLAUDE.md；GPT/Codex 读取 AGENTS.md。
3. 读取 ai_snapshot.json、claude-progress.txt、session-state.md、todo.md、verification.md。
4. 根据任务类型读取 docs/ai/ 下最相关的一个或两个文件。
5. 读取长文件时先看 Quick Brief；只有需要细节时再读正文。
6. 用几行话确认当前目标、下一步和未验证事项。

## During Work
- 按开发文档中的有序队列连续推进：取下一项、实现、验证、记录，然后继续下一项。
- 每个子项仍必须小而可验证；不要把多个无关目标揉成一次大改。
- 模糊需求先走 Planner；实现只走 Generator；最终验收只走 Evaluator。
- 写新函数、脚本、CMake 逻辑或测试 fixture 前，先查找并复用已有同类实现；找不到或不适用时再新增。
- 复杂需求先拆成 tasks/TASK-*/ 子任务，每个 Task 有自己的 task.md、ai_snapshot.json、verification.md 和 defect-rca.md。
- 每完成 3 个子项或修改 3 个文件后做一次检查点记录：已做什么、验证什么、接下来继续哪一项；不需要等待人类确认，除非触发停止条件。
- 不要在修 bug 时顺便重构无关代码。
- 修改范围超出计划时先报告，不要自行扩大。
- 同一问题连续失败两次、Evaluator 判 Fail、或人类指出缺陷时，进入 RCA 流程并更新 docs/ai/check-rules.md。

## Continue Until
- spec.md、todo.md 或当前 Task 中没有下一个可执行项。
- 验证失败、工具不可用或无法触达真实环境。
- 需求、接口、验收标准不清，需要人类确认。
- 下一项会明显扩大范围、跨越非目标、或引入新依赖。
- 上下文变浑浊，开始猜测、重复读错状态或想跳过验证。

## End of Each Round
- 更新 claude-progress.txt：当前状态、已完成、下一步、风险。
- 更新 session-state.md：本轮目标、上下文健康、交接摘要、下一轮第一步。
- 更新 todo.md：勾掉完成项，补充新发现但必要的后续项。
- 更新 verification.md：记录已跑验证、失败验证、未跑原因。
- 更新 evaluation.md：记录 Evaluator 的独立验收结论和真实命令证据。
- 运行 scripts/snapshot_update.sh，把下一轮最小读取集合写入 ai_snapshot.json。
- 未完成验证时不要宣布任务完成。

## Context Reset
- 新会话使用 prompts/resume.md 接力。
- 不依赖聊天历史保存状态；跨轮事实必须落到文件系统。
- 出现以下信号时使用 prompts/handoff.md 停止并交接：上下文接近上限、开始忘记约束、方案突然变粗、想跳过验证、文件改动超过计划、连续失败两次。
- 交接后下一轮从 scripts/context_reset_check.sh 和 prompts/resume.md 开始。

## Technical Debt Cadence
- 定期使用 prompts/debt-scan.md 做小范围巡检。
- 债务先登记到 debt-register.md，再用 prompts/debt-fix.md 一次修一个点。
- 适合后台 Agent 的任务应当 boring、小、可验证，方便人类快速 review。
"

safe_write "docs/ai/quick-brief.md" "# Quick Brief And Layered Reading

## Goal
降低长上下文噪声。Agent 续做时先读短摘要，再按需读取正文，避免每轮重复吞入整篇长文档。

## File Layers
- Frozen：稳定协议，例如 CLAUDE.md、AGENTS.md、docs/ai/*.md。初始化或规则相关任务才读。
- Active：当前阶段指南，例如 spec.md、task.md、evaluation.md。进入阶段时读一次。
- Hot：快照和状态，例如 ai_snapshot.json、session-state.md、todo.md、verification.md。每轮都读。

## Quick Brief Format
超过 80 行、且会被 Agent 多次读取的 Markdown 文件，建议在文件头部放 15 行以内的 YAML 摘要：

\`\`\`yaml
quick_brief:
  purpose: 这个文件解决什么问题
  current_state: 当前状态
  must_read:
    - 真正需要继续读的章节或文件
  next_step: 下一步
  last_verified: 最近一次验证命令或日期
\`\`\`

## Reading Rule
1. 先读 ai_snapshot.json。
2. 对长 Markdown 先读 Quick Brief。
3. 只有 Quick Brief 指向的章节、当前任务相关章节、或验证需要时，才读正文。
4. 如果正文状态改变，更新 Quick Brief；不要让摘要和正文互相矛盾。

## Check
运行 scripts/quick_brief_check.sh 查看哪些长 Markdown 缺少 Quick Brief。该脚本只提示，不替代人工判断。
"

safe_write "docs/ai/rca.md" "# Defect RCA And Rule Self-Healing

## Goal
修 Bug 不只改代码，还要沉淀防护规则，减少下一轮 Agent 重复犯错。

## When To Use
- Evaluator 给出 Fail。
- 人类指出明显缺陷或遗漏。
- 同一问题连续失败两次。
- 修复暴露出缺失的测试、规约或检查项。

## RCA Steps
1. 记录缺陷现象：输入、命令、错误输出、影响范围。
2. 追溯根因：是需求理解、上下文缺失、测试不足、边界遗漏、还是工具使用问题。
3. 修复代码或文档，只处理和缺陷直接相关的范围。
4. 增加回归验证：测试、脚本、最小复现或手工检查步骤。
5. 更新 defect-rca.md 或 tasks/TASK-*/defect-rca.md。
6. 把可复用的防护规则写入 docs/ai/check-rules.md。
7. 更新 ai_snapshot.json，让下一轮能看到这条新规则。

## Rule Quality
- 规则必须具体、可执行、可检查。
- 不写空泛结论，例如“以后更小心”。
- 优先写触发条件和检查动作，例如“修改解析逻辑后必须运行 X 命令”。
- 如果只是一次性事故，不要污染全局规约；只记录在当前 Task RCA。
"

safe_write "docs/ai/check-rules.md" "# Learned Check Rules

这个文件记录从缺陷 RCA 中沉淀出来的可复用防护规则。它不是编码风格大全，只收录真实踩坑后的检查项。

## Active Rules

| ID | Trigger | Check | Source |
| --- | --- | --- | --- |
| CR-0001 | 初始化 harness 后 | 运行 scripts/context_reset_check.sh 和 scripts/quick_brief_check.sh，确认恢复入口可用 | setup_ai_harness.sh |

## How To Add A Rule
1. 先在 defect-rca.md 记录缺陷和根因。
2. 只把可复用、可检查的规则提升到这里。
3. 每条规则必须有 Trigger、Check 和 Source。
4. 新规则加入后，更新 ai_snapshot.json 的 must_read 或 risks。
"

safe_write "docs/ai/task-sandbox.md" "# Task Sandbox

## Goal
把复杂需求拆成可独立接力、独立验证、独立复盘的小任务，避免一个 spec.md 装下所有上下文。

## When To Create A Task
- 需求横跨多个模块、多个接口或多天开发。
- 需要并行或分波次推进。
- 当前任务包含明显不同的设计、实现、验收阶段。
- 一个会话无法稳定承载全部上下文。

## Directory Shape
\`\`\`text
tasks/TASK-YYYYMMDDHHMMSS-name/
  task.md
  ai_snapshot.json
  verification.md
  defect-rca.md
\`\`\`

## Task Rules
- 每个 Task 只承载一个可验收目标。
- task.md 写 Goals、Non-Goals、Acceptance Criteria、Plan、Files、Risks。
- Task 内的 ai_snapshot.json 只保存该 Task 的最小恢复集。
- verification.md 只记录该 Task 的真实命令证据。
- defect-rca.md 只记录该 Task 内发生的缺陷复盘。
- Task 完成后，把关键结论同步回根目录 evaluation.md、verification.md 和 ai_snapshot.json。

## Commands
- 新建任务：scripts/task_new.sh short-name
- 续做任务：先读根 ai_snapshot.json，再读对应 Task 的 ai_snapshot.json 和 task.md。
"

# ============================================================================
# 2. Codex Skill — 项目完成后的全代码 Review
# ============================================================================

safe_write ".codex/skills/full-code-review/SKILL.md" '---
name: full-code-review
description: Whole-project code review for a completed or nearly completed software project. Use when the user asks Codex to deeply read the entire repository after development, perform a full-code/full-repo review, check for bugs, regressions, security issues, architectural risks, or meaningful optimization opportunities, especially when they explicitly do not want piecemeal review or repeated generic test suggestions.
---

# Full Code Review

## Purpose

Perform a full-repository review after project development. Prioritize real defects, behavioral risks, security/data-integrity issues, maintainability problems, and worthwhile optimizations. Do not turn the review into a repeated request to add tests.

## Operating Rules

- Review the whole first-party project, not only the latest diff, unless the user explicitly narrows scope.
- Do not ask the user to approve each review slice. Build a repo map, inspect systematically, and continue until the full pass is complete or a hard blocker prevents progress.
- Do not edit code during the review unless the user explicitly asks for fixes. The output is findings and recommendations.
- Respect dirty worktrees. Treat existing local changes as user work; do not revert or overwrite them.
- Use source evidence. A finding should cite file and line references whenever possible and explain the failure mode.
- Avoid generic test advice. Mention tests only when tied to a concrete defect/regression path, or once in a short residual-risk note.
- If the repository is too large to inspect every generated or vendored file, explicitly exclude generated/vendor/build artifacts and list any first-party areas that could not be reviewed.

## Review Workflow

1. Establish the repo root and state.
   - Run `git rev-parse --show-toplevel` when available.
   - Run `git status --short` to notice user changes.
   - Build the inventory with `git ls-files`; fall back to `rg --files`.

2. Create a project map before judging code.
   - Read `README`, package manifests, dependency files, build configs, framework configs, CI/deploy files, environment examples, schema/migration files, and main entry points.
   - If `.zread/wiki/current` exists, read the relevant generated pages for orientation, but verify important claims against source.
   - Classify files into app source, API/backend, frontend/UI, data/schema, scripts/jobs, infrastructure/config, tests, docs, generated/vendor/build artifacts.

3. Inspect all first-party implementation areas systematically.
   - Walk directory by directory rather than sampling only suspicious files.
   - Trace important user flows end to end: input validation, auth/permission checks, persistence, background jobs, external calls, error handling, retries, cancellation, and UI state transitions.
   - Check shared contracts: API schemas, database models, environment variables, serialization formats, route names, feature flags, and build/runtime assumptions.
   - Use targeted searches to find risk patterns: `TODO`, `FIXME`, `HACK`, `XXX`, `debugger`, `console.log`, broad catches, ignored lint/type errors, unsafe casts, unchecked `any`, raw SQL, shell execution, eval-like behavior, secrets, auth bypasses, hard-coded URLs, and duplicated business rules.

4. Run low-risk verification commands when discoverable.
   - Prefer existing scripts from package manifests, Makefiles, task runners, or CI configs.
   - Run static checks, type checks, linters, builds, or focused smoke commands when practical.
   - Do not make test coverage the center of the review. Use command results to support or disprove concrete concerns.

5. Triage findings.
   - Lead with high-confidence issues that can cause wrong behavior, data loss, security exposure, production failures, or broken user workflows.
   - Include optimization opportunities only when they are meaningful: clear performance wins, simpler architecture, reduced duplication, less fragile state handling, or easier operational debugging.
   - Do not report style preferences as findings unless they create real maintenance risk.

## Output Format

Start with findings, ordered by severity. Use this structure:

```text
Findings
- High/Medium/Low: <short title> - <file:line>
  Impact: <what can go wrong>
  Evidence: <why the code behaves that way>
  Recommendation: <specific fix direction>
```

Then include:

- `Optimization Opportunities`: only concrete, worthwhile improvements.
- `Coverage`: directories or subsystems reviewed, commands run, and any exclusions.
- `Residual Risk`: short note for areas that could not be verified. Mention test gaps here only once, and only if relevant.

If no high-confidence problems are found, say so clearly and still include coverage and residual risk.'

safe_write ".codex/skills/full-code-review/agents/openai.yaml" 'interface:
  display_name: "Full Code Review"
  short_description: "全项目深度代码审查，聚焦真实 bug、风险与有效优化点"
  default_prompt: "Use $full-code-review to review the entire project after development and report bugs, risks, and meaningful optimization opportunities."'


# ============================================================================
# 3. .claude/settings.json — 权限 + Hooks
# ============================================================================

safe_write ".claude/settings.json" '{
  "permissions": {
    "allow": [
      "Read",
      "Edit",
      "Write",
      "Bash(cmake *)",
      "Bash(make *)",
      "Bash(ninja *)",
      "Bash(g++ *)",
      "Bash(clang++ *)",
      "Bash(c++ *)",
      "Bash(gcc *)",
      "Bash(clang *)",
      "Bash(gdb *)",
      "Bash(lldb *)",
      "Bash(ctest *)",
      "Bash(cpack *)",
      "Bash(clang-format *)",
      "Bash(clang-tidy *)",
      "Bash(git status*)",
      "Bash(git diff*)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git log*)",
      "Bash(git branch*)",
      "Bash(git checkout *)",
      "Bash(git switch *)",
      "Bash(git stash*)",
      "Bash(ls *)",
      "Bash(cat *)",
      "Bash(grep *)",
      "Bash(find *)",
      "Bash(wc *)",
      "Bash(head *)",
      "Bash(tail *)",
      "Bash(bash scripts/context_reset_check.sh *)",
      "Bash(./scripts/context_reset_check.sh *)",
      "Bash(bash scripts/resume_from_snapshot.sh *)",
      "Bash(./scripts/resume_from_snapshot.sh *)",
      "Bash(bash scripts/snapshot_update.sh *)",
      "Bash(./scripts/snapshot_update.sh *)",
      "Bash(bash scripts/quick_brief_check.sh *)",
      "Bash(./scripts/quick_brief_check.sh *)",
      "Bash(bash scripts/task_new.sh *)",
      "Bash(./scripts/task_new.sh *)",
      "Bash(bash scripts/rca_new.sh *)",
      "Bash(./scripts/rca_new.sh *)",
      "Bash(bash scripts/ai_debt_scan.sh *)",
      "Bash(./scripts/ai_debt_scan.sh *)",
      "Bash(bash scripts/evaluator_check.sh *)",
      "Bash(./scripts/evaluator_check.sh *)"
    ],
    "deny": [
      "Bash(rm -rf *)",
      "Bash(git push --force *)",
      "Bash(git push -f *)",
      "Bash(git reset --hard *)",
      "Bash(sudo *)"
    ]
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "if printf \"%s\\n\" \"$CLAUDE_FILE_PATH\" | grep -qE \"\\.(cpp|cc|cxx|h|hpp|hxx)$\"; then if command -v clang-format >/dev/null 2>&1; then clang-format -i \"$CLAUDE_FILE_PATH\" || echo \"WARN: clang-format failed for $CLAUDE_FILE_PATH\" >&2; else echo \"WARN: clang-format not found\" >&2; fi; fi"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "if printf \"%s\\n\" \"$CLAUDE_FILE_PATH\" | grep -qE \"(^|/)build/\"; then echo \"BLOCK: 不要直接编辑 build/ 目录，请修改源码后重新构建\" >&2; exit 1; fi"
          }
        ]
      }
    ]
  }
}'


# ============================================================================
# 4. .cursorrules — Cursor 配置
# ============================================================================

safe_write ".cursorrules" "你是一位资深 C++ 工程师，精通现代 C++${CPP_STD} 和 CMake。

项目：${PROJECT_NAME}
构建系统：CMake 3.20+
C++ 标准：C++${CPP_STD}
测试框架：${TEST_FW_NAME}

## 核心规则
- 优先使用智能指针，避免裸 new/delete
- RAII 管理所有资源
- const 正确性：不修改的参数用 const&，不修改的方法标 const
- 头文件使用 #pragma once
- 函数不超过 40 行
- 命名：类型 PascalCase，函数/变量 snake_case，常量 kPascalCase
- 优先使用成熟、无聊、仓库已有的技术和模式

## 构建命令
- 配置：cmake -B build -DCMAKE_BUILD_TYPE=Debug
- 编译：cmake --build build -j\$(nproc)
- 测试：cd build && ctest --output-on-failure

## 禁止
- C 风格内存管理（malloc/free）除非 C 互操作
- 未定义行为（越界访问、空指针解引用、悬挂引用）
- 手动 lock/unlock，使用 lock_guard/scoped_lock
- 不说明理由就引入新第三方依赖
- 复制明显坏模式；发现坏模式先登记到 debt-register.md"


# ============================================================================
# 5. .vscode/settings.json — VS Code + Copilot 配置
# ============================================================================

safe_write ".vscode/settings.json" '{
  "editor.formatOnSave": true,
  "editor.defaultFormatter": "xaver.clang-format",
  "C_Cpp.default.cppStandard": "c++'"${CPP_STD}"'",
  "C_Cpp.default.configurationProvider": "ms-vscode.cmake-tools",
  "cmake.buildDirectory": "${workspaceFolder}/build",
  "cmake.configureOnOpen": true,
  "files.associations": {
    "*.h": "cpp",
    "*.hpp": "cpp"
  },
  "github.copilot.enable": {
    "*": true,
    "markdown": true,
    "cmake": true,
    "plaintext": false
  },
  "[cpp]": {
    "editor.defaultFormatter": "xaver.clang-format",
    "editor.formatOnSave": true
  }
}'

safe_write ".vscode/extensions.json" '{
  "recommendations": [
    "xaver.clang-format",
    "ms-vscode.cmake-tools",
    "ms-vscode.cpptools",
    "github.copilot",
    "github.copilot-chat"
  ]
}'


# ============================================================================
# 6. .clang-format — 被 Hook 引用，必须存在
# ============================================================================

safe_write ".clang-format" "---
Language: Cpp
BasedOnStyle: Google
IndentWidth: 4
ColumnLimit: 100
AccessModifierOffset: -4
AlignAfterOpenBracket: Align
AllowShortFunctionsOnASingleLine: Inline
AllowShortIfStatementsOnASingleLine: Never
AllowShortLoopsOnASingleLine: false
BreakBeforeBraces: Attach
IncludeBlocks: Regroup
IncludeCategories:
  - Regex: '^\".*\"'
    Priority: 1
  - Regex: '^<.*>'
    Priority: 2
PointerAlignment: Left
SortIncludes: CaseInsensitive
SpaceAfterCStyleCast: false
Standard: c++${CPP_STD}
..."


# ============================================================================
# 7. 长任务接力 Harness — 状态外化到文件系统
# ============================================================================

safe_write "ai_snapshot.json" "{
  \"schema_version\": 1,
  \"project\": \"${PROJECT_NAME}\",
  \"updated_by\": \"setup_ai_harness.sh\",
  \"updated_at\": \"initialization\",
  \"current_task\": \"harness-initialization\",
  \"current_step\": \"initialized\",
  \"next_step\": \"Run scripts/resume_from_snapshot.sh, then continue the ordered queue from todo.md or the active Task.\",
  \"must_read\": [
    \"CLAUDE.md\",
    \"AGENTS.md\",
    \"claude-progress.txt\",
    \"session-state.md\",
    \"todo.md\",
    \"verification.md\"
  ],
  \"active_files\": [],
  \"decisions\": [
    \"Use short CLAUDE.md and AGENTS.md indexes; keep details in docs/ai/.\",
    \"Use Planner / Generator / Evaluator role split.\",
    \"Use Task sandbox for large multi-step work.\"
  ],
  \"risks\": [
    \"Project-specific build commands and tests still need confirmation.\"
  ],
  \"verification\": {
    \"passed\": [
      \"setup_ai_harness.sh generated initial harness files\"
    ],
    \"not_run\": [
      \"scripts/context_reset_check.sh\",
      \"scripts/quick_brief_check.sh\",
      \"cmake -B build -DCMAKE_BUILD_TYPE=Debug\"
    ]
  }
}"

safe_write "claude-progress.txt" "# Claude Progress

## Mission
为 ${PROJECT_NAME} 维护可接力、可验证、少漂移的 C++${CPP_STD}/CMake 开发状态。

## Current State
- AI 编程规范和编辑器配置已由 setup_ai_harness.sh 初始化。
- Harness 不创建业务代码目录；项目结构以现有仓库为准。
- CLAUDE.md 是短索引；细节规则在 docs/ai/ 下按需读取。
- AGENTS.md 是 GPT/Codex 短索引；与 Claude 共用 docs/ai/、prompts/ 和状态文件。
- session-state.md 用于记录当前接力轮次和交接摘要。
- spec.md 与 evaluation.md 用于分离规划、实现和验收。
- Golden Principles 已写入 docs/ai/golden-principles.md，用于防止坏模式扩散。
- 测试框架选择：${TEST_FW_NAME}。
- 真实 CMake target、测试依赖和项目特有约束仍需要按项目实际情况补充。

## Completed
- 生成 Claude Code / Cursor / VS Code / clang-format 基础配置。
- 生成 GPT/Codex 的 AGENTS.md 项目入口。
- 生成 docs/ai/ 下的按需细节规则。
- 生成 Planner / Generator / Evaluator 角色分离模板。
- 生成技术债登记表、扫描脚本和债务修复 prompt。
- 生成 Context Reset 自检脚本、会话状态文件和交接 prompt。
- 建立长任务接力所需的状态文件模板。

## Next Step
模糊需求先用 prompts/planner.md 写 spec.md；实现用 prompts/generator.md；最终验收用 prompts/evaluator.md。

## Open Risks
- 本脚本只生成 AI harness，不会自动安装编译器、CMake、clang-format 或测试框架。
- 选择 ${TEST_FW_NAME} 只会写入规范，不代表 CMake 已完成测试依赖集成。
- 已存在文件会被跳过；如果需要迁移旧配置，请手动比对后更新。
- 早期坏模式可能被 Agent 继续模仿；需要定期运行技术债扫描并小步修复。
- 如果上下文开始变长或任务发散，应先使用 prompts/handoff.md 交接，不要急着收尾。
- 自评容易偏乐观；最终完成状态必须以 evaluation.md 的独立验收结论为准。

## Verification
- 尚未在本项目业务代码上运行构建或测试。
- 尚未运行 scripts/context_reset_check.sh。
- 尚未运行 scripts/ai_debt_scan.sh。
- 尚未运行 scripts/evaluator_check.sh。
"

safe_write "spec.md" "# Spec

Planner 负责维护本文件。Generator 按本文件实现；Evaluator 按本文件验收。

## Problem
- 待补充：用户要解决的问题是什么。

## Goals
- 待补充：本轮必须完成的可观察结果。

## Non-Goals
- 待补充：本轮明确不做什么，防止范围扩张。

## Acceptance Criteria
- [ ] 待补充：可测试、可观察、可判定的验收标准。

## Test Plan
- 待补充：Evaluator 应运行的真实命令或最小复现步骤。

## Risks
- 待补充：不确定点、外部依赖、可能失败的验证。
"

safe_write "evaluation.md" "# Evaluation Report

Evaluator 负责维护本文件。不要由 Generator 给自己的实现写最终通过结论。

## Verdict
- Status: Blocked
- Reason: 尚未执行独立验收。

## Spec Under Test
- spec.md

## Evidence

| Check | Command / Evidence | Result | Notes |
| --- | --- | --- | --- |
| Harness self-check | scripts/evaluator_check.sh | Not Run | 待执行 |

## Failures
- 暂无；尚未验收。

## Untested
- 构建
- 测试
- 行为验收

## Follow-Up
- 使用 prompts/evaluator.md 执行独立验收。
"

safe_write "session-state.md" "# Session State

## Current Round
- Round: 0
- Started By: setup_ai_harness.sh
- Context Health: fresh
- Mode: initialization

## This Round Goal
建立可重启、可接力、状态外化的 AI harness。

## Last Handoff Summary
- 尚无上一轮交接。

## Next Round First Step
运行 scripts/context_reset_check.sh，然后按 prompts/resume.md 恢复状态。

## Reset Triggers
出现任一信号就停止扩展，使用 prompts/handoff.md 写交接：
- 上下文变长，开始丢细节或重复读错状态
- 开始想跳过验证、简化方案或急着宣布完成
- 文件改动超过原计划
- 同一问题连续失败两次
- 发现旧计划和新状态冲突

## Files To Update Before Handoff
- claude-progress.txt
- session-state.md
- spec.md
- evaluation.md
- todo.md
- verification.md
"

safe_write "debt-register.md" "# Technical Debt Register

用这个文件记录偏离 Golden Principles 的小债务。债务不是集中大扫除，而是让后台 Agent 每次偿还一点。

## Golden Principles
- 详细原则见 docs/ai/golden-principles.md。
- 扫描入口见 prompts/debt-scan.md。
- 修复入口见 prompts/debt-fix.md。

## Open Debt

| ID | Area | Principle | Symptom | Evidence | Suggested Small Fix | Status |
| --- | --- | --- | --- | --- | --- | --- |
| TD-0001 | harness | Prefer Boring Technology | 初始项目尚未扫描业务代码 | scripts/ai_debt_scan.sh 未运行 | 运行扫描并登记真实问题 | open |

## Paid Down

| ID | Date | Fix | Verification |
| --- | --- | --- | --- |
"

safe_write "todo.md" "# TODO

- [ ] 补充 CLAUDE.md 中的项目特有信息、公共工具列表和真实构建命令
- [ ] 确认或创建根目录 CMakeLists.txt
- [ ] 用 prompts/planner.md 补充 spec.md 的验收标准
- [ ] 按 ${TEST_FW_NAME} 实际接入测试依赖，或把测试框架标记为待定
- [ ] 用 prompts/evaluator.md 生成独立 evaluation.md 结论
- [ ] 运行 scripts/resume_from_snapshot.sh，确认 ai_snapshot.json 可用于恢复
- [ ] 运行 scripts/quick_brief_check.sh，确认长文档摘要覆盖情况
- [ ] 大需求开始前用 scripts/task_new.sh 创建 Task 沙盒
- [ ] 运行 scripts/ai_debt_scan.sh 并把真实问题登记到 debt-register.md
- [ ] 运行 cmake -B build -DCMAKE_BUILD_TYPE=Debug
- [ ] 运行 cmake --build build -j\$(nproc)
- [ ] 有测试后运行 cd build && ctest --output-on-failure
"

safe_write "verification.md" "# Verification Log

## Passed

- setup_ai_harness.sh 已生成基础 harness 文件。

## Not Yet Run

- bash -n setup_ai_harness.sh
- jq empty .claude/settings.json .vscode/settings.json
- scripts/resume_from_snapshot.sh
- scripts/context_reset_check.sh
- scripts/quick_brief_check.sh
- scripts/ai_debt_scan.sh
- scripts/evaluator_check.sh
- cmake -B build -DCMAKE_BUILD_TYPE=Debug
- cmake --build build -j\$(nproc)
- cd build && ctest --output-on-failure

## Notes

- 如果某项验证因工具未安装无法运行，请记录具体原因，不要把它标记为通过。
"

safe_write "defect-rca.md" "# Defect RCA Log

本文件记录跨任务的缺陷 RCA。Task 内部缺陷优先写入 tasks/TASK-*/defect-rca.md；可复用规则再提升到 docs/ai/check-rules.md。

## RCA Entries

### RCA-0001 — Harness initialized
- Symptom: 尚无缺陷。
- Root Cause: N/A。
- Fix: 初始化 RCA 落点。
- Regression Check: 待首次真实缺陷后补充。
- Promoted Rule: N/A。
"

safe_write "tasks/_template/task.md" "# Task Template

## Goals
- 待补充。

## Non-Goals
- 待补充。

## Acceptance Criteria
- [ ] 待补充可观察、可验证、可判定的验收标准。

## Plan
1. 读取根目录 ai_snapshot.json。
2. 读取本 Task 的 ai_snapshot.json、task.md 和 verification.md。
3. 从 Acceptance Criteria 或 Plan 中领取下一个可执行子项。
4. 实现、运行最小验证、更新本 Task 状态。
5. 如果验证通过且仍有可执行子项，继续领取下一项。
6. 只有遇到阻塞、失败、需求不清、范围扩大或上下文变浑浊时才交接。

## Files
- 待补充。

## Risks
- 待补充。
"

safe_write "tasks/_template/ai_snapshot.json" "{
  \"schema_version\": 1,
  \"task\": \"TASK-template\",
  \"updated_by\": \"setup_ai_harness.sh\",
  \"current_step\": \"template\",
  \"next_step\": \"Copy this directory or run scripts/task_new.sh short-name.\",
  \"must_read\": [
    \"ai_snapshot.json\",
    \"task.md\",
    \"verification.md\"
  ],
  \"active_files\": [],
  \"decisions\": [],
  \"risks\": []
}"

safe_write "tasks/_template/verification.md" "# Verification

## Passed

## Failed

## Not Yet Run
- 待补充。
"

safe_write "tasks/_template/defect-rca.md" "# Defect RCA

本文件只记录当前 Task 内发生的缺陷复盘。可复用规则再提升到 docs/ai/check-rules.md。

## Entries
"

safe_write "init.sh" "#!/usr/bin/env bash
set -euo pipefail

echo \"Project root: \$(pwd)\"
echo \"\"

check_tool() {
    local tool=\"\$1\"
    if command -v \"\$tool\" >/dev/null 2>&1; then
        printf '[OK] %s: ' \"\$tool\"
        \"\$tool\" --version 2>/dev/null | head -n 1 || echo \"installed\"
    else
        printf '[MISS] %s not found\\n' \"\$tool\"
    fi
}

check_tool cmake
check_tool clang-format
check_tool git

echo \"\"
if [ -x scripts/context_reset_check.sh ]; then
    scripts/context_reset_check.sh
    echo \"\"
fi

if [ -x scripts/resume_from_snapshot.sh ]; then
    scripts/resume_from_snapshot.sh
    echo \"\"
fi

for file in ai_snapshot.json CLAUDE.md AGENTS.md .codex/skills/full-code-review/SKILL.md .codex/skills/full-code-review/agents/openai.yaml spec.md evaluation.md claude-progress.txt session-state.md todo.md verification.md debt-register.md defect-rca.md docs/ai/tooling.md docs/ai/workflow.md docs/ai/evaluation.md docs/ai/golden-principles.md docs/ai/quick-brief.md docs/ai/task-sandbox.md docs/ai/rca.md docs/ai/check-rules.md; do
    if [ -f \"\$file\" ]; then
        echo \"===== \$file =====\"
        sed -n '1,220p' \"\$file\"
        echo \"\"
    fi
done
"
chmod +x init.sh

safe_write "scripts/context_reset_check.sh" '#!/usr/bin/env bash
set -euo pipefail

REQUIRED_FILES=(
    "ai_snapshot.json"
    "CLAUDE.md"
    "AGENTS.md"
    ".codex/skills/full-code-review/SKILL.md"
    ".codex/skills/full-code-review/agents/openai.yaml"
    "spec.md"
    "evaluation.md"
    "claude-progress.txt"
    "session-state.md"
    "todo.md"
    "verification.md"
    "docs/ai/evaluation.md"
    "docs/ai/tooling.md"
    "docs/ai/workflow.md"
    "docs/ai/quick-brief.md"
    "docs/ai/task-sandbox.md"
    "docs/ai/rca.md"
    "docs/ai/check-rules.md"
)

OPTIONAL_FILES=(
    "defect-rca.md"
    "debt-register.md"
    "docs/ai/golden-principles.md"
    "prompts/resume.md"
    "prompts/handoff.md"
    "prompts/rca.md"
    "prompts/task.md"
)

echo "# Context Reset Check"
echo ""

missing=0
echo "## Required Files"
for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "- [OK] $file"
    else
        echo "- [MISS] $file"
        missing=1
    fi
done

echo ""
echo "## Optional Harness Files"
for file in "${OPTIONAL_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "- [OK] $file"
    else
        echo "- [WARN] $file"
    fi
done

echo ""
echo "## Resume Order"
echo "1. Read ai_snapshot.json first"
echo "2. Read CLAUDE.md for Claude Code or AGENTS.md for GPT/Codex"
echo "3. Read claude-progress.txt and session-state.md"
echo "4. Read todo.md and verification.md"
echo "5. Read spec.md before implementation or evaluation"
echo "6. Read only the relevant docs/ai/*.md file for the current task"
echo "7. Continue the ordered task queue: implement one small verifiable item, verify it, record it, then continue the next item until a stop condition is hit"

echo ""
echo "## Reset Triggers"
echo "- Context feels crowded or contradictory"
echo "- You are tempted to skip verification"
echo "- You are about to declare completion without fresh checks"
echo "- The task has expanded beyond the current plan"
echo "- The same approach failed twice"

if [ "$missing" -ne 0 ]; then
    echo ""
    echo "Missing required state files. Re-run setup_ai_harness.sh or restore the files before continuing."
    exit 1
fi
'
chmod +x scripts/context_reset_check.sh

safe_write "scripts/snapshot_update.sh" '#!/usr/bin/env bash
set -euo pipefail

TASK="${1:-current-work}"
STEP="${2:-in-progress}"
NEXT="${3:-Read ai_snapshot.json, then continue one small verified step.}"
UPDATED_AT=$(date -Iseconds 2>/dev/null || date)
PROJECT=$(basename "$(pwd)")

json_escape() {
    printf "%s" "$1" | sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g"
}

GIT_BRANCH="not-a-git-repo"
GIT_SUMMARY=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    GIT_SUMMARY=$(git status --short 2>/dev/null | head -n 20 | tr "\n" ";")
fi

cat > ai_snapshot.json <<EOF_SNAPSHOT
{
  "schema_version": 1,
  "project": "$(json_escape "$PROJECT")",
  "updated_by": "scripts/snapshot_update.sh",
  "updated_at": "$(json_escape "$UPDATED_AT")",
  "current_task": "$(json_escape "$TASK")",
  "current_step": "$(json_escape "$STEP")",
  "next_step": "$(json_escape "$NEXT")",
  "must_read": [
    "CLAUDE.md",
    "AGENTS.md",
    "claude-progress.txt",
    "session-state.md",
    "todo.md",
    "verification.md"
  ],
  "active_files": [],
  "decisions": [],
  "risks": [],
  "git": {
    "branch": "$(json_escape "$GIT_BRANCH")",
    "status_short": "$(json_escape "$GIT_SUMMARY")"
  },
  "verification": {
    "passed": [],
    "not_run": []
  }
}
EOF_SNAPSHOT

echo "[OK] ai_snapshot.json updated"
'
chmod +x scripts/snapshot_update.sh

safe_write "scripts/resume_from_snapshot.sh" '#!/usr/bin/env bash
set -euo pipefail

echo "# Resume From Snapshot"
echo ""

if [ -f ai_snapshot.json ]; then
    echo "## ai_snapshot.json"
    sed -n "1,220p" ai_snapshot.json
else
    echo "[WARN] ai_snapshot.json not found. Run scripts/context_reset_check.sh and rebuild state from files."
fi

echo ""
echo "## Minimum Read Order"
echo "1. CLAUDE.md or AGENTS.md"
echo "2. claude-progress.txt"
echo "3. session-state.md"
echo "4. todo.md"
echo "5. verification.md"
echo "6. spec.md when implementing or evaluating"
echo "7. Only the relevant docs/ai/*.md file for the current task"

if [ -d tasks ]; then
    echo ""
    echo "## Task Snapshots"
    find tasks -maxdepth 2 -name ai_snapshot.json -print 2>/dev/null | sort | head -n 20
fi
'
chmod +x scripts/resume_from_snapshot.sh

safe_write "scripts/quick_brief_check.sh" '#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
THRESHOLD="${QUICK_BRIEF_MIN_LINES:-80}"
missing=0

echo "# Quick Brief Check"
echo ""
echo "- Root: $ROOT"
echo "- Line threshold: $THRESHOLD"
echo ""

while IFS= read -r file; do
    lines=$(wc -l < "$file" | tr -d " ")
    if [ "$lines" -le "$THRESHOLD" ]; then
        continue
    fi
    if head -n 20 "$file" | grep -Eq "(^|[[:space:]])quick_brief:"; then
        echo "- [OK] $file ($lines lines)"
    else
        echo "- [WARN] $file ($lines lines) missing quick_brief in first 20 lines"
        missing=1
    fi
done < <(find "$ROOT" \
    \( -path "*/.git" -o -path "*/build" -o -path "*/.cache" -o -path "*/node_modules" \) -prune \
    -o -type f -name "*.md" -print)

echo ""
if [ "$missing" -eq 0 ]; then
    echo "All long Markdown files have Quick Brief headers or are below threshold."
else
    echo "Warnings are advisory. Add Quick Brief only to files that Agents repeatedly read."
fi
'
chmod +x scripts/quick_brief_check.sh

safe_write "scripts/task_new.sh" '#!/usr/bin/env bash
set -euo pipefail

RAW_NAME="${1:-manual-task}"
SLUG=$(printf "%s" "$RAW_NAME" | tr "[:upper:]" "[:lower:]" | sed "s/[^a-z0-9._-]/-/g; s/-\\+/-/g; s/^-//; s/-$//")
if [ -z "$SLUG" ]; then
    SLUG="manual-task"
fi

STAMP=$(date +%Y%m%d%H%M%S)
DIR="tasks/TASK-${STAMP}-${SLUG}"
mkdir -p "$DIR"

cat > "$DIR/task.md" <<EOF_TASK
# TASK-${STAMP}-${SLUG}

## Goals
- 待补充。

## Non-Goals
- 待补充。

## Acceptance Criteria
- [ ] 待补充可观察、可验证、可判定的验收标准。

## Plan
1. 阅读根目录 ai_snapshot.json 和本 Task ai_snapshot.json。
2. 从 Acceptance Criteria 或 Plan 中领取下一个可执行子项。
3. 修改必要文件并运行最小验证。
4. 更新本 Task 的 verification.md 和 ai_snapshot.json。
5. 如果验证通过且仍有可执行子项，继续领取下一项。
6. 只有遇到阻塞、失败、需求不清、范围扩大或上下文变浑浊时才交接。

## Files
- 待补充。

## Risks
- 待补充。
EOF_TASK

cat > "$DIR/ai_snapshot.json" <<EOF_SNAPSHOT
{
  "schema_version": 1,
  "task": "TASK-${STAMP}-${SLUG}",
  "updated_by": "scripts/task_new.sh",
  "current_step": "created",
  "next_step": "Fill task.md Goals and Acceptance Criteria.",
  "must_read": [
    "ai_snapshot.json",
    "$DIR/task.md",
    "$DIR/verification.md"
  ],
  "active_files": [],
  "decisions": [],
  "risks": []
}
EOF_SNAPSHOT

cat > "$DIR/verification.md" <<EOF_VERIFY
# Verification

## Passed

## Failed

## Not Yet Run
- 待补充。
EOF_VERIFY

cat > "$DIR/defect-rca.md" <<EOF_RCA
# Defect RCA

本文件只记录 TASK-${STAMP}-${SLUG} 内发生的缺陷复盘。可复用规则再提升到 docs/ai/check-rules.md。

## Entries
EOF_RCA

echo "[OK] created $DIR"
'
chmod +x scripts/task_new.sh

safe_write "scripts/rca_new.sh" '#!/usr/bin/env bash
set -euo pipefail

ID="${1:-RCA-$(date +%Y%m%d%H%M%S)}"
DIR="${2:-rca}"
mkdir -p "$DIR"
FILE="$DIR/${ID}.md"

if [ -f "$FILE" ]; then
    echo "[SKIP] $FILE already exists"
    exit 0
fi

cat > "$FILE" <<EOF_RCA
# $ID

## Symptom
- 现象：
- 影响范围：
- 复现命令或输入：

## Root Cause
- 根因：
- 为什么现有规约或测试没有挡住：

## Fix
- 修复摘要：
- 修改文件：

## Regression Check
- [ ] 测试、脚本或最小复现：

## Promoted Rule
- 是否需要写入 docs/ai/check-rules.md：
- Trigger：
- Check：
EOF_RCA

echo "[OK] created $FILE"
'
chmod +x scripts/rca_new.sh

safe_write "scripts/evaluator_check.sh" '#!/usr/bin/env bash
set -euo pipefail

echo "# Evaluator Check"
echo ""

required=(
    "spec.md"
    "evaluation.md"
    "verification.md"
)

missing=0
for file in "${required[@]}"; do
    if [ -f "$file" ]; then
        echo "- [OK] $file"
    else
        echo "- [MISS] $file"
        missing=1
    fi
done

echo ""
echo "## Suggested Real-World Checks"
if [ -f CMakeLists.txt ]; then
    echo "- cmake -B build -DCMAKE_BUILD_TYPE=Debug"
    echo "- cmake --build build -j\$(nproc)"
    echo "- cd build && ctest --output-on-failure"
else
    echo "- No CMakeLists.txt found; record build evaluation as Blocked until build config exists."
fi

if [ -x scripts/context_reset_check.sh ]; then
    echo "- scripts/context_reset_check.sh"
fi

if [ -x scripts/ai_debt_scan.sh ]; then
    echo "- scripts/ai_debt_scan.sh"
fi

echo ""
echo "## Verdict Rule"
echo "Use Pass only when acceptance criteria in spec.md have fresh command evidence. Otherwise use Fail or Blocked."

if [ "$missing" -ne 0 ]; then
    exit 1
fi
'
chmod +x scripts/evaluator_check.sh

safe_write "scripts/ai_debt_scan.sh" '#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
TARGETS=()

for dir in "$ROOT/src" "$ROOT/include" "$ROOT/tests"; do
    if [ -d "$dir" ]; then
        TARGETS+=("$dir")
    fi
done

echo "# AI Debt Scan"
echo ""
echo "- Root: $ROOT"
echo "- Date: $(date -Iseconds 2>/dev/null || date)"
echo ""

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "No src/include/tests directories found. Pass a project root or extend TARGETS for this repository layout."
    exit 0
fi

run_check() {
    local title="$1"
    local pattern="$2"
    echo "## $title"
    echo ""
    local result
    result=$(grep -RInE \
        --exclude-dir=.git \
        --exclude-dir=build \
        --exclude-dir=libs \
        --include="*.c" \
        --include="*.cc" \
        --include="*.cpp" \
        --include="*.cxx" \
        --include="*.h" \
        --include="*.hpp" \
        --include="*.hxx" \
        "$pattern" "${TARGETS[@]}" 2>/dev/null || true)
    if [ -n "$result" ]; then
        printf "%s\n" "$result"
    else
        echo "No obvious hits."
    fi
    echo ""
}

run_check "C-style memory or raw ownership" "\b(malloc|free|new|delete)\b"
run_check "Manual lock/unlock" "\.(lock|unlock)[[:space:]]*\("
run_check "Sleep in code or tests" "\b(sleep|usleep|std::this_thread::sleep_for)\b"
run_check "Hardcoded host/IP hints" "(localhost|127\.0\.0\.1|[0-9]{1,3}(\.[0-9]{1,3}){3})"
run_check "TODO/FIXME/HACK markers" "\b(TODO|FIXME|HACK|XXX)\b"

echo "## Next Step"
echo ""
echo "Review hits against docs/ai/golden-principles.md. Register real issues in debt-register.md; do not treat every hit as a bug."
'
chmod +x scripts/ai_debt_scan.sh

safe_write "prompts/init.md" "# First-Round Initialization Prompt

你是本项目第一轮初始化 Agent。目标是建立可接力的 long-running agent harness，而不是一次性把所有功能做完。

请执行：

1. 阅读 CLAUDE.md、AGENTS.md、docs/ai/tooling.md、docs/ai/workflow.md、setup_ai_harness.sh、项目目录和现有配置。
2. 运行或阅读 init.sh 与 scripts/context_reset_check.sh，确认环境和状态文件。
3. 创建或更新 claude-progress.txt、session-state.md、todo.md、verification.md。
4. 在 claude-progress.txt 中记录 Mission、Current State、Completed、Next Step、Open Risks、Verification。
5. 在 session-state.md 中记录本轮目标、上下文健康、交接摘要和下一轮第一步。
6. 运行 scripts/snapshot_update.sh，生成机器可读 ai_snapshot.json。
7. 如当前目录是 git 仓库，且没有敏感文件或用户未禁止提交，可创建一个初始 harness 快照 commit；否则只记录建议，不强行提交。
8. 只做初始化和必要的小修正，不扩大任务范围。
9. 结束前说明修改了哪些文件，下一轮应该从哪个 todo 开始。

硬规则：

- 不要依赖聊天历史保存状态。
- CLAUDE.md 和 AGENTS.md 只保留短索引；细节规则按需放到 docs/ai/。
- 初始状态必须落到文件系统；需要 git 快照时只提交 harness 相关文件。
- 未运行的验证必须写入 verification.md 的 Not Yet Run。
- 不要把未完成任务说成完成。
"

safe_write "prompts/planner.md" "# Planner Prompt

你是 Planner。你的职责是把模糊需求转成可执行规格，不实现代码，不做最终验收。

开始时读取：

- CLAUDE.md
- AGENTS.md
- docs/ai/evaluation.md
- docs/ai/workflow.md
- claude-progress.txt
- todo.md

请执行：

1. 把用户需求整理到 spec.md。
2. 写清 Goals、Non-Goals、Acceptance Criteria、Test Plan、Risks。
3. 验收标准必须可观察、可测试、可判定。
4. 如果需求超过一个会话或一个模块，使用 scripts/task_new.sh 拆出 tasks/TASK-*/，并在 spec.md 中列出 Task 顺序。
5. 如果需求不清，写出最小合理假设，不要扩大范围。
6. 更新 todo.md：下一步应交给 Generator。
7. 运行 scripts/snapshot_update.sh，写清下一轮最小读取集合。
8. 不修改业务代码，不写 evaluation.md 的最终结论。

输出 spec.md 的关键摘要和 Generator 的下一步。
"

safe_write "prompts/generator.md" "# Generator Prompt

你是 Generator。你的职责是按 spec.md 或当前 Task 的开发队列连续实现，不给自己的工作打最终分。

开始时读取：

- CLAUDE.md
- AGENTS.md
- spec.md
- docs/ai/workflow.md
- 与任务相关的 docs/ai/*.md
- verification.md

请执行：

1. 确认 spec.md 的目标、非目标和验收标准。
2. 用 \`rg\`、目录浏览和已有测试查找同类实现、公共 helper、脚本、CMake target 和 fixture。
3. 优先复用、扩展或轻量抽取现有逻辑；只有不适用时才新增，并说明原因。
4. 从 spec.md、todo.md 或当前 Task 的 Plan/Acceptance Criteria 中领取下一个可执行子项。
5. 实现该子项，运行与改动直接相关的自检命令。
6. 更新 verification.md：记录自检命令和结果；如当前工作属于 tasks/TASK-*，同步更新该 Task 的 verification.md 和 ai_snapshot.json。
7. 如果验证通过且仍有下一个明确可执行子项，继续执行第 4 步，不要因为完成一个子项就停下。
8. 每完成 3 个子项或修改 3 个文件，更新 claude-progress.txt 和 session-state.md 做检查点记录。
9. 遇到停止条件时，运行 scripts/snapshot_update.sh，写清下一轮最小读取集合。
10. 不写最终 Pass 结论；最终验收交给 Evaluator。

停止条件：

- 没有下一个明确可执行子项。
- 验证失败、工具不可用或无法触达真实环境。
- 需求、接口或验收标准不清。
- 下一项会扩大范围、跨越 Non-Goals 或引入新依赖。
- 上下文变浑浊，开始猜测或想跳过验证。

输出复用检查结果、连续完成的子项列表、自检结果、停止原因和建议 Evaluator 运行的命令。
"

safe_write "prompts/evaluator.md" "# Evaluator Prompt

你是 Evaluator。你的职责是像 QA 一样验收，不实现功能，不替 Generator 找借口。

开始时读取：

- CLAUDE.md
- AGENTS.md
- spec.md
- evaluation.md
- verification.md
- docs/ai/evaluation.md
- docs/ai/testing.md

先运行：

- \`scripts/evaluator_check.sh\`

请执行：

1. 根据 spec.md 的 Acceptance Criteria 制定验收步骤。
2. 运行真实命令：构建、测试、脚本、可执行程序或最小复现。
3. 把命令、结果、失败原因和未验证项写入 evaluation.md。
4. 同步更新 verification.md。
5. 如果结论是 Fail，使用 prompts/rca.md 记录缺陷根因；可复用规则提升到 docs/ai/check-rules.md。
6. 运行 scripts/snapshot_update.sh，写清下一轮最小读取集合。
7. 结论只能是 Pass、Fail 或 Blocked。
8. 如果无法触达真实世界，不要给 Pass，写 Blocked 和原因。

硬规则：

- 不修改业务代码，除非只是添加独立测试且明确记录。
- 不接受 Generator 的自我评价作为证据。
- 没有新鲜命令证据，就不能写 Pass。
"

safe_write "prompts/task.md" "# Task Sandbox Prompt

你正在处理一个 tasks/TASK-* 子任务。目标是让复杂需求在小沙盒内连续推进、验证和接力。

开始时读取：

- 根目录 ai_snapshot.json
- CLAUDE.md
- AGENTS.md
- docs/ai/task-sandbox.md
- 当前 tasks/TASK-*/task.md
- 当前 tasks/TASK-*/ai_snapshot.json
- 当前 tasks/TASK-*/verification.md

请执行：

1. 用 5 行以内确认本 Task 的目标、非目标和验收标准。
2. 从 task.md 的 Plan 或 Acceptance Criteria 中领取下一个可执行子项。
3. 修改前先查找已有实现、公共 helper、测试 fixture、脚本和 CMake 规则。
4. 实现该子项，运行和本步骤直接相关的验证。
5. 更新当前 Task 的 verification.md 和 ai_snapshot.json。
6. 如果验证通过且仍有下一个明确可执行子项，继续执行第 2 步。
7. 每完成 3 个子项或修改 3 个文件，更新根目录 claude-progress.txt、todo.md、verification.md 和 ai_snapshot.json 做检查点记录。
8. Task 完成后，把结论同步到根目录 evaluation.md 或 verification.md。

硬规则：

- 不把多个无关 Task 混在一个目录里。
- 不在 Task 内宣布全局完成；全局完成必须由 Evaluator 根据根目录 evaluation.md 判定。
- 发生缺陷或连续失败时，使用 prompts/rca.md。
- 遇到阻塞、失败、需求不清、范围扩大或上下文变浑浊时，停止连续推进并写清交接。
"

safe_write "prompts/rca.md" "# RCA Prompt

你正在处理缺陷 RCA。目标不是写漂亮复盘，而是把可复用防护规则沉淀进仓库。

开始时读取：

- docs/ai/rca.md
- docs/ai/check-rules.md
- defect-rca.md
- 当前 Task 的 defect-rca.md，如果存在
- evaluation.md
- verification.md

请执行：

1. 记录缺陷现象：输入、命令、错误输出、影响范围。
2. 写出根因：需求理解、上下文缺失、测试不足、边界遗漏、工具使用错误或其他。
3. 修复只覆盖直接相关范围，不顺手重构。
4. 添加或记录回归验证。
5. 更新 defect-rca.md 或当前 Task 的 defect-rca.md。
6. 如果规则可复用，更新 docs/ai/check-rules.md，写清 Trigger、Check、Source。
7. 更新 verification.md 和 ai_snapshot.json。

硬规则：

- 不接受“以后注意”这类空泛规则。
- 不把一次性事故提升成全局规则。
- 没有回归验证或未说明阻塞原因，RCA 不能关闭。
"

safe_write "prompts/debt-scan.md" "# Technical Debt Scan Prompt

你是后台技术债扫描 Agent。目标不是大改代码，而是对照 Golden Principles 找出小、具体、可偿还的偏离。

开始时读取：

- CLAUDE.md
- AGENTS.md
- docs/ai/golden-principles.md
- docs/ai/workflow.md
- debt-register.md
- verification.md

请执行：

1. 运行 \`scripts/ai_debt_scan.sh\`，如果脚本不可用则说明原因。
2. 结合扫描结果和 Golden Principles，筛选真实问题，忽略误报。
3. 每个问题必须足够小，最好能在 1 个 PR 内、少量文件内修复。
4. 更新 debt-register.md：新增 ID、区域、违反原则、证据和建议的小修复。
5. 不做大规模重构，不直接修复多个无关问题。
6. 更新 verification.md，记录扫描是否运行。

输出只总结新增或更新的债务项，以及下一轮最适合修复的一个 ID。
"

safe_write "prompts/debt-fix.md" "# Technical Debt Fix Prompt

你是技术债偿还 Agent。目标是一次只修一个 boring、低风险、可验证的小问题。

开始时读取：

- CLAUDE.md
- AGENTS.md
- docs/ai/golden-principles.md
- docs/ai/cpp.md 或相关任务细节文件
- debt-register.md
- verification.md

请执行：

1. 从 debt-register.md 选择一个 open 的最小债务项。
2. 说明它违反了哪条 Golden Principle。
3. 只修改必要文件，不顺手重构无关代码。
4. 运行最小相关验证。
5. 更新 debt-register.md：把该项标记为 paid 或记录阻塞原因。
6. 更新 verification.md 和 claude-progress.txt。

硬规则：

- 不把风格重排和行为修复混在一起。
- 不引入新依赖来偿还小债。
- 验证未跑或失败时，不得标记为 paid。
"

safe_write "prompts/handoff.md" "# Handoff Prompt

你当前应该停止扩展任务，把状态沉到文件系统，然后让下一轮干净上下文接手。

触发交接的典型信号：

- 上下文太长，开始丢细节或重复确认同一事实。
- 你想跳过验证、简化方案或急着宣布完成。
- 当前改动范围超过原计划。
- 同一问题连续失败两次。
- 旧计划和当前文件状态出现冲突。

请执行：

1. 停止新增功能和大范围修改。
2. 读取并更新 claude-progress.txt。
3. 更新 session-state.md：Context Health、This Round Goal、Last Handoff Summary、Next Round First Step。
4. 更新 spec.md 或 evaluation.md：写清当前规格或验收状态。
5. 更新 todo.md：保留一个明确的下一步，不要塞满愿望清单。
6. 更新 verification.md：写清已跑、失败、未跑和未跑原因。
7. 运行 scripts/snapshot_update.sh，更新 ai_snapshot.json 的 current_task、current_step、next_step 和 must_read。
8. 如果当前工作属于 tasks/TASK-*，同步更新该 Task 的 ai_snapshot.json。
9. 如果有技术债发现，登记到 debt-register.md，不要顺手修。
10. 最后只输出交接摘要和下一轮建议使用 prompts/resume.md。

硬规则：

- 不要宣布整体完成，除非 TODO 已完成且验证刚刚通过。
- 不要靠聊天历史保存任何关键状态。
- 不要为了收尾而删除风险、失败记录或未验证事项。
"

safe_write "prompts/resume.md" "# Resume Prompt

你是新一轮接力 Agent。你没有上一轮聊天历史，必须从文件系统恢复状态。

开始时先运行：

- \`scripts/resume_from_snapshot.sh\`

然后读取：

- ai_snapshot.json
- CLAUDE.md
- AGENTS.md
- spec.md
- session-state.md
- claude-progress.txt
- todo.md
- verification.md
- evaluation.md
- init.sh

然后按本轮任务类型只读取最相关的细节文件：

- C++ 代码：docs/ai/cpp.md
- 测试：docs/ai/testing.md
- 构建/依赖：docs/ai/build.md
- 规划/验收：docs/ai/evaluation.md、spec.md、evaluation.md
- 长任务流程：docs/ai/workflow.md
- 架构/重构/技术债：docs/ai/golden-principles.md、debt-register.md
- 复杂任务：docs/ai/task-sandbox.md、当前 tasks/TASK-*/task.md
- 缺陷复盘：docs/ai/rca.md、docs/ai/check-rules.md
- 长文件降噪：docs/ai/quick-brief.md

然后执行：

1. 用 5-10 行总结当前目标、状态、风险和下一步。
2. 从 ai_snapshot.json、todo.md、spec.md 或当前 Task 中找到下一个可执行子项。
3. 开发前查找并复用已有同类逻辑、公共 helper、测试 fixture、脚本和 CMake 规则。
4. 实现该子项，运行与改动相关的最小自检。
5. 更新 claude-progress.txt、session-state.md、todo.md、verification.md。
6. 如果验证通过且仍有下一个明确可执行子项，继续执行第 2 步。
7. 每完成 3 个子项或修改 3 个文件，运行 scripts/snapshot_update.sh 更新 ai_snapshot.json。
8. 最终验收必须交给 prompts/evaluator.md；只有 evaluation.md 为 Pass 且 TODO 完成时，才宣布整体完成。

遇到上下文变长、需求发散、验证失败、需求不清、工具不可用或下一项会扩大范围时，使用 prompts/handoff.md 停止扩大范围，把交接状态写清楚。
"


# ============================================================================
# 8. .gitignore 追加
# ============================================================================

info "更新 .gitignore ..."
touch .gitignore
for pattern in \
    "build/" \
    ".env" \
    ".env.*" \
    "*.o" \
    "*.obj" \
    "*.a" \
    "*.so" \
    "*.dylib" \
    "*.exe" \
    ".cache/" \
    "*.log" \
    "compile_commands.json" \
    ".claude/settings.local.json" \
    ".vscode/*.log" \
    "CMakeUserPresets.json"; do
    append_gitignore "$pattern"
done
ok ".gitignore (已追加必要条目)"


# ============================================================================
# 9. 创建 Harness 目录（不创建业务代码目录）
# ============================================================================

for dir in prompts docs/ai scripts tasks rca; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        ok "创建目录 $dir/"
    fi
done


# ============================================================================
# 完成
# ============================================================================

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  AI Harness 初始化完成！${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  项目：${PROJECT_NAME}"
echo "  标准：C++${CPP_STD}"
echo "  测试：${TEST_FW_NAME}"
echo ""
echo "已生成的 AI 配置文件："
echo "  CLAUDE.md                — Claude Code 项目级规范"
echo "  AGENTS.md                — GPT/Codex 项目级规范"
echo "  .claude/settings.json    — Claude Code 权限 + Hooks"
echo "  .codex/skills/full-code-review/ — Codex 全项目代码 Review Skill"
echo "  docs/ai/*.md             — 按需读取的细节规则"
echo "  .cursorrules             — Cursor 配置"
echo "  .vscode/settings.json    — VS Code + Copilot 配置"
echo "  .vscode/extensions.json  — VS Code 推荐扩展"
echo "  .clang-format            — 代码格式化配置"
echo "  claude-progress.txt      — 长任务接力状态"
echo "  session-state.md         — 当前接力轮次状态"
echo "  ai_snapshot.json         — 机器可读恢复快照"
echo "  spec.md                  — Planner 规格说明"
echo "  evaluation.md            — Evaluator 验收报告"
echo "  debt-register.md         — 技术债登记表"
echo "  defect-rca.md            — 缺陷 RCA 和规约沉淀记录"
echo "  todo.md                  — 长任务 TODO"
echo "  verification.md          — 验证记录"
echo "  tasks/_template/         — Task 沙盒模板"
echo "  init.sh                  — 环境恢复入口"
echo "  prompts/init.md          — 第一轮初始化 Prompt"
echo "  prompts/resume.md        — 后续接力 Prompt"
echo "  prompts/handoff.md       — 上下文重启交接 Prompt"
echo "  prompts/planner.md       — 规划者 Prompt"
echo "  prompts/generator.md     — 生成者 Prompt"
echo "  prompts/evaluator.md     — 验收者 Prompt"
echo "  prompts/task.md          — Task 沙盒 Prompt"
echo "  prompts/rca.md           — 缺陷 RCA Prompt"
echo "  prompts/debt-scan.md     — 技术债扫描 Prompt"
echo "  prompts/debt-fix.md      — 小步偿还技术债 Prompt"
echo "  scripts/context_reset_check.sh — 接力自检脚本"
echo "  scripts/evaluator_check.sh — 验收自检脚本"
echo "  scripts/resume_from_snapshot.sh — 快照恢复脚本"
echo "  scripts/snapshot_update.sh — 快照更新脚本"
echo "  scripts/quick_brief_check.sh — Quick Brief 检查脚本"
echo "  scripts/task_new.sh      — 创建 Task 沙盒"
echo "  scripts/rca_new.sh       — 创建 RCA 模板"
echo "  scripts/ai_debt_scan.sh  — 本地技术债启发式扫描"
echo ""
echo "下一步："
echo "  1. 保持 CLAUDE.md 和 AGENTS.md 短小，只补充索引级项目事实"
echo "  2. 运行 ./init.sh 查看接力状态和本机工具"
echo "  3. 新会话先运行 scripts/resume_from_snapshot.sh，再使用 prompts/resume.md"
echo "  4. 模糊需求先用 prompts/planner.md，开发用 prompts/generator.md"
echo "  5. 大需求先用 scripts/task_new.sh short-name 拆成 Task 沙盒"
echo "  6. 完成前用 prompts/evaluator.md 做独立验收"
echo "  7. 缺陷或连续失败时使用 prompts/rca.md，并把可复用规则写入 docs/ai/check-rules.md"
echo "  8. 每轮结束运行 scripts/snapshot_update.sh 更新 ai_snapshot.json"
echo "  9. 运行 scripts/quick_brief_check.sh 检查长文档摘要覆盖"
echo "  10. 运行 cmake -B build 验证构建配置"
echo "  11. 定期用 prompts/debt-scan.md + scripts/ai_debt_scan.sh 巡检技术债"
echo "  12. 项目开发完成后，让 Codex 使用 \$full-code-review 做全仓库代码 review"
echo "  13. 细节规则优先维护到 docs/ai/，不要把 CLAUDE.md/AGENTS.md 写成长文档"
echo ""
echo "提示：脚本不会创建 src/include/tests/libs/cmake 等业务目录；请沿用当前项目结构。"
echo "提示：测试框架选择只写入 AI 规范，不会自动安装或接入 GTest/Catch2。"
echo "提示：API key 不写入项目；GPT/Codex 认证请放在用户级配置（如 ~/.codex/auth.json）。"
echo ""
