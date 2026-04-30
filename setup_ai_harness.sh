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
#   init.sh                   — 环境恢复入口
#   prompts/init.md           — 第一轮初始化 Prompt
#   prompts/resume.md         — 后续接力 Prompt
#   prompts/handoff.md        — 上下文重启交接 Prompt
#   prompts/planner.md        — 规划者 Prompt
#   prompts/generator.md      — 生成者 Prompt
#   prompts/evaluator.md      — 验收者 Prompt
#   prompts/debt-scan.md      — 技术债扫描 Prompt
#   prompts/debt-fix.md       — 小步偿还技术债 Prompt
#   scripts/context_reset_check.sh — 接力自检脚本
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
- claude-progress.txt：当前任务状态、下一步、风险
- session-state.md：当前接力轮次、上下文健康和交接摘要
- spec.md：Planner 产出的规格、验收标准和非目标
- evaluation.md：Evaluator 产出的真实验收证据
- todo.md：可接力的剩余任务
- verification.md：已跑和未跑的验证
- debt-register.md：技术债、偏离原则和偿还记录
- init.sh：新会话恢复环境和查看状态

## Read Only What You Need
- Claude Code 读 CLAUDE.md；GPT/Codex 读 AGENTS.md；细节统一从 docs/ai/ 读取
- 做架构、抽象或重构判断前读 docs/ai/golden-principles.md
- 改 C++ 代码前读 docs/ai/cpp.md；如目标目录已有局部 CLAUDE.md/AGENTS.md，也一并读取
- 改测试前读 docs/ai/testing.md；如测试目录已有局部 CLAUDE.md/AGENTS.md，也一并读取
- 改构建、命令或依赖前读 docs/ai/build.md
- 做规划、实现或验收前读 docs/ai/evaluation.md
- 长任务、新会话接力或上下文变长时读 docs/ai/workflow.md
- 做技术债巡检或修复前读 debt-register.md 和 prompts/debt-*.md

## Default Commands
- 配置：\`cmake -B build -DCMAKE_BUILD_TYPE=Debug\`
- 编译：\`cmake --build build -j\$(nproc)\`
${TEST_COMMANDS}

## Non-Negotiables
- 不要手动编辑 build/ 目录
- 不要在代码中硬编码文件路径、IP、端口
- 不要引入新第三方依赖，除非先说明理由并获得确认
- 优先选择成熟、无聊、仓库已使用的技术；不要为炫技引入新栈
- 不要把未运行的验证说成已通过
- 生产和验收必须分离；Generator 不给自己的实现打最终分
- 不要 git push --force 到 main 分支

## Role Split
- Planner：把模糊需求写成 spec.md，不改业务代码
- Generator：按 spec.md 实现，不写最终验收结论
- Evaluator：像 QA 一样运行真实命令，把证据写入 evaluation.md

## Long-Running Work
- 每轮开始先读 claude-progress.txt、todo.md、verification.md
- 每轮只推进一个明确小步骤，完成后更新状态文件
- 出现上下文变长、开始猜测、想跳过验证或急于收尾时，立刻使用 prompts/handoff.md
- 上下文变长或任务发散时，停止扩展并写清交接

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
- claude-progress.txt：当前任务状态、下一步、风险
- session-state.md：当前接力轮次、上下文健康和交接摘要
- spec.md：Planner 产出的规格、验收标准和非目标
- evaluation.md：Evaluator 产出的真实验收证据
- todo.md：可接力的剩余任务
- verification.md：已跑和未跑的验证
- debt-register.md：技术债、偏离原则和偿还记录

## Read Only What You Need
- 工具/账号/模型配置说明：docs/ai/tooling.md
- 架构、抽象或重构判断：docs/ai/golden-principles.md
- C++ 代码：docs/ai/cpp.md
- 测试：docs/ai/testing.md
- 构建、命令或依赖：docs/ai/build.md
- 规划、实现或验收：docs/ai/evaluation.md
- 长任务、新会话接力或上下文变长：docs/ai/workflow.md

## Default Commands
- 配置：\`cmake -B build -DCMAKE_BUILD_TYPE=Debug\`
- 编译：\`cmake --build build -j\$(nproc)\`
${TEST_COMMANDS}

## Non-Negotiables
- 不要手动编辑 build/ 目录
- 不要把 API key、token 或本机认证文件写进仓库
- 不要引入新第三方依赖，除非先说明理由并获得确认
- 不要把未运行的验证说成已通过
- Generator 不给自己的实现写最终通过结论
- 不要 git push --force 到 main 分支

## Role Split
- Planner：把模糊需求写成 spec.md，不改业务代码
- Generator：按 spec.md 实现，不写最终验收结论
- Evaluator：像 QA 一样运行真实命令，把证据写入 evaluation.md

## Long-Running Work
- 每轮开始先运行 scripts/context_reset_check.sh
- 每轮只推进一个明确小步骤，完成后更新状态文件
- 上下文变长、开始猜测、想跳过验证或急于收尾时，立刻使用 prompts/handoff.md
"

safe_write "docs/ai/cpp.md" "# C++ Rules

## Hard Rules
- 优先使用智能指针和对象所有权表达，裸 new/delete 必须说明理由。
- 所有资源通过 RAII 管理，禁止手动 open/close、lock/unlock 配对散落在业务逻辑中。
- 优先复用已登记的共享工具和标准库，不要为局部需求反复手写 helper。
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
- 新 helper 只能在已有能力不适用时添加，并应放在清晰可复用的位置。
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
- 两个 Agent 都必须遵守生产和验收分离；最终完成以 evaluation.md 的独立证据为准。
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
1. Claude Code 读取 CLAUDE.md；GPT/Codex 读取 AGENTS.md。
2. 运行或阅读 scripts/context_reset_check.sh。
3. 读取 claude-progress.txt、session-state.md、todo.md、verification.md。
4. 根据任务类型读取 docs/ai/ 下最相关的一个或两个文件。
5. 用几行话确认当前目标、下一步和未验证事项。

## During Work
- 每轮只推进一个明确的小步骤。
- 模糊需求先走 Planner；实现只走 Generator；最终验收只走 Evaluator。
- 每修改 3 个文件后暂停总结：已做什么、接下来做什么、是否偏离需求。
- 不要在修 bug 时顺便重构无关代码。
- 修改范围超出计划时先报告，不要自行扩大。

## End of Each Round
- 更新 claude-progress.txt：当前状态、已完成、下一步、风险。
- 更新 session-state.md：本轮目标、上下文健康、交接摘要、下一轮第一步。
- 更新 todo.md：勾掉完成项，补充新发现但必要的后续项。
- 更新 verification.md：记录已跑验证、失败验证、未跑原因。
- 更新 evaluation.md：记录 Evaluator 的独立验收结论和真实命令证据。
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


# ============================================================================
# 2. .claude/settings.json — 权限 + Hooks
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
# 3. .cursorrules — Cursor 配置
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
# 6. .vscode/settings.json — VS Code + Copilot 配置
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
# 7. .clang-format — 被 Hook 引用，必须存在
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
# 8. 长任务接力 Harness — 状态外化到文件系统
# ============================================================================

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
- scripts/context_reset_check.sh
- scripts/ai_debt_scan.sh
- scripts/evaluator_check.sh
- cmake -B build -DCMAKE_BUILD_TYPE=Debug
- cmake --build build -j\$(nproc)
- cd build && ctest --output-on-failure

## Notes

- 如果某项验证因工具未安装无法运行，请记录具体原因，不要把它标记为通过。
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

for file in CLAUDE.md AGENTS.md spec.md evaluation.md claude-progress.txt session-state.md todo.md verification.md debt-register.md docs/ai/tooling.md docs/ai/workflow.md docs/ai/evaluation.md docs/ai/golden-principles.md; do
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
    "CLAUDE.md"
    "AGENTS.md"
    "spec.md"
    "evaluation.md"
    "claude-progress.txt"
    "session-state.md"
    "todo.md"
    "verification.md"
    "docs/ai/evaluation.md"
    "docs/ai/tooling.md"
    "docs/ai/workflow.md"
)

OPTIONAL_FILES=(
    "debt-register.md"
    "docs/ai/golden-principles.md"
    "prompts/resume.md"
    "prompts/handoff.md"
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
echo "1. Read CLAUDE.md for Claude Code or AGENTS.md for GPT/Codex"
echo "2. Read claude-progress.txt and session-state.md"
echo "3. Read todo.md and verification.md"
echo "4. Read spec.md before implementation or evaluation"
echo "5. Read only the relevant docs/ai/*.md file for the current task"
echo "6. Pick one small step, verify it, then update state files"

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
6. 如当前目录是 git 仓库，且没有敏感文件或用户未禁止提交，可创建一个初始 harness 快照 commit；否则只记录建议，不强行提交。
7. 只做初始化和必要的小修正，不扩大任务范围。
8. 结束前说明修改了哪些文件，下一轮应该从哪个 todo 开始。

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
4. 如果需求不清，写出最小合理假设，不要扩大范围。
5. 更新 todo.md：下一步应交给 Generator。
6. 不修改业务代码，不写 evaluation.md 的最终结论。

输出 spec.md 的关键摘要和 Generator 的下一步。
"

safe_write "prompts/generator.md" "# Generator Prompt

你是 Generator。你的职责是按 spec.md 小步实现，不给自己的工作打最终分。

开始时读取：

- CLAUDE.md
- AGENTS.md
- spec.md
- docs/ai/workflow.md
- 与任务相关的 docs/ai/*.md
- verification.md

请执行：

1. 确认 spec.md 的目标、非目标和验收标准。
2. 只实现一个明确小步，不扩大范围。
3. 运行与改动直接相关的自检命令。
4. 更新 verification.md：记录自检命令和结果。
5. 更新 claude-progress.txt 和 session-state.md。
6. 不写最终 Pass 结论；最终验收交给 Evaluator。

输出改动摘要、自检结果和建议 Evaluator 运行的命令。
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
5. 结论只能是 Pass、Fail 或 Blocked。
6. 如果无法触达真实世界，不要给 Pass，写 Blocked 和原因。

硬规则：

- 不修改业务代码，除非只是添加独立测试且明确记录。
- 不接受 Generator 的自我评价作为证据。
- 没有新鲜命令证据，就不能写 Pass。
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
7. 如果有技术债发现，登记到 debt-register.md，不要顺手修。
8. 最后只输出交接摘要和下一轮建议使用 prompts/resume.md。

硬规则：

- 不要宣布整体完成，除非 TODO 已完成且验证刚刚通过。
- 不要靠聊天历史保存任何关键状态。
- 不要为了收尾而删除风险、失败记录或未验证事项。
"

safe_write "prompts/resume.md" "# Resume Prompt

你是新一轮接力 Agent。你没有上一轮聊天历史，必须从文件系统恢复状态。

开始时先读取：

- CLAUDE.md
- AGENTS.md
- spec.md
- session-state.md
- claude-progress.txt
- todo.md
- verification.md
- evaluation.md
- init.sh

先运行：

- \`scripts/context_reset_check.sh\`

然后按本轮任务类型只读取最相关的细节文件：

- C++ 代码：docs/ai/cpp.md
- 测试：docs/ai/testing.md
- 构建/依赖：docs/ai/build.md
- 规划/验收：docs/ai/evaluation.md、spec.md、evaluation.md
- 长任务流程：docs/ai/workflow.md
- 架构/重构/技术债：docs/ai/golden-principles.md、debt-register.md

然后执行：

1. 用 5-10 行总结当前目标、状态、风险和下一步。
2. 从 todo.md 中选择一个最小可完成任务推进。
3. 修改必要文件，保持范围克制。
4. 运行与本轮改动相关的最小自检。
5. 更新 claude-progress.txt、session-state.md、todo.md、verification.md。
6. 最终验收必须交给 prompts/evaluator.md；只有 evaluation.md 为 Pass 且 TODO 完成时，才宣布整体完成。

遇到上下文变长、需求发散、验证缺失或工具不可用时，使用 prompts/handoff.md 停止扩大范围，把交接状态写清楚。
"


# ============================================================================
# 9. .gitignore 追加
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
# 10. 创建 Harness 目录（不创建业务代码目录）
# ============================================================================

for dir in prompts docs/ai scripts; do
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
echo "  docs/ai/*.md             — 按需读取的细节规则"
echo "  .cursorrules             — Cursor 配置"
echo "  .vscode/settings.json    — VS Code + Copilot 配置"
echo "  .vscode/extensions.json  — VS Code 推荐扩展"
echo "  .clang-format            — 代码格式化配置"
echo "  claude-progress.txt      — 长任务接力状态"
echo "  session-state.md         — 当前接力轮次状态"
echo "  spec.md                  — Planner 规格说明"
echo "  evaluation.md            — Evaluator 验收报告"
echo "  debt-register.md         — 技术债登记表"
echo "  todo.md                  — 长任务 TODO"
echo "  verification.md          — 验证记录"
echo "  init.sh                  — 环境恢复入口"
echo "  prompts/init.md          — 第一轮初始化 Prompt"
echo "  prompts/resume.md        — 后续接力 Prompt"
echo "  prompts/handoff.md       — 上下文重启交接 Prompt"
echo "  prompts/planner.md       — 规划者 Prompt"
echo "  prompts/generator.md     — 生成者 Prompt"
echo "  prompts/evaluator.md     — 验收者 Prompt"
echo "  prompts/debt-scan.md     — 技术债扫描 Prompt"
echo "  prompts/debt-fix.md      — 小步偿还技术债 Prompt"
echo "  scripts/context_reset_check.sh — 接力自检脚本"
echo "  scripts/evaluator_check.sh — 验收自检脚本"
echo "  scripts/ai_debt_scan.sh  — 本地技术债启发式扫描"
echo ""
echo "下一步："
echo "  1. 保持 CLAUDE.md 和 AGENTS.md 短小，只补充索引级项目事实"
echo "  2. 运行 ./init.sh 查看接力状态和本机工具"
echo "  3. 新会话先运行 scripts/context_reset_check.sh，再使用 prompts/resume.md"
echo "  4. 模糊需求先用 prompts/planner.md，开发用 prompts/generator.md"
echo "  5. 完成前用 prompts/evaluator.md 做独立验收"
echo "  6. 上下文变长或开始急着收尾时，使用 prompts/handoff.md"
echo "  7. 运行 cmake -B build 验证构建配置"
echo "  8. 定期用 prompts/debt-scan.md + scripts/ai_debt_scan.sh 巡检技术债"
echo "  9. 细节规则优先维护到 docs/ai/，不要把 CLAUDE.md/AGENTS.md 写成长文档"
echo ""
echo "提示：脚本不会创建 src/include/tests/libs/cmake 等业务目录；请沿用当前项目结构。"
echo "提示：测试框架选择只写入 AI 规范，不会自动安装或接入 GTest/Catch2。"
echo "提示：API key 不写入项目；GPT/Codex 认证请放在用户级配置（如 ~/.codex/auth.json）。"
echo ""
