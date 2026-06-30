# AI Harness 使用说明

这份文档说明如何使用 `setup_ai_harness.sh` 给一个 C++/CMake 项目初始化 AI 协作 Harness。它适合同时使用 Claude Code、GPT/Codex、Cursor 和 GitHub Copilot 的项目。

这个脚本只生成 AI 协作规则、状态文件、Prompt 和辅助脚本，不创建业务代码目录，也不改变你的项目代码结构。

## 适用场景

- 想让 Claude Code 和 GPT/Codex 在同一个项目里遵守同一套规则。
- 想让长任务可以跨多轮 Agent 接力，不依赖聊天历史。
- 想把需求规划、代码生成、独立验收分开。
- 想约束 Claude Code 和 GPT/Codex 在开发前先查找并复用已有逻辑，避免重复造轮子。
- 想让新会话通过 `ai_snapshot.json` 快速恢复任务现场。
- 想把复杂需求拆成独立 Task 沙盒，逐个推进和验收。
- 想把缺陷复盘沉淀成可复用检查规约，减少重复犯错。
- 想让 AI 定期扫描技术债，而不是等代码腐烂后集中重构。
- 想在项目开发完成后，让 Claude 或 Codex 做一次全仓库代码 review，集中找真实 bug、风险和有效优化点。
- 想把项目规则写进仓库，但不把 API key 写进仓库。

## 快速开始

把脚本放到项目根目录，然后执行：

```bash
bash setup_ai_harness.sh
```

如果项目里已经生成过旧版 Harness 文件，想更新到最新模板：

```bash
bash setup_ai_harness.sh --force
```

`--force` 会先备份已有文件，再覆盖。例如：

```text
CLAUDE.md.bak.20260430135000
AGENTS.md.bak.20260430135000
```

查看帮助：

```bash
bash setup_ai_harness.sh --help
```

## 运行时会问什么

脚本会交互式询问三项信息：

1. 项目名称：默认使用当前目录名。
2. C++ 标准：C++17、C++20 或 C++23。
3. 测试框架：Google Test、Catch2 或暂不配置。

注意：测试框架选择只会写入 AI 规则，不会自动安装或接入 GTest/Catch2。

## 生成哪些文件

核心入口文件：

```text
CLAUDE.md      Claude Code 项目入口
AGENTS.md      GPT/Codex 项目入口
```

规则文件：

```text
docs/ai/cpp.md
docs/ai/testing.md
docs/ai/build.md
docs/ai/evaluation.md
docs/ai/workflow.md
docs/ai/golden-principles.md
docs/ai/tooling.md
docs/ai/quick-brief.md
docs/ai/task-sandbox.md
docs/ai/rca.md
docs/ai/check-rules.md
```

全代码 Review 入口：

```text
.claude/skills/full-code-review/SKILL.md
.codex/skills/full-code-review/SKILL.md
.codex/skills/full-code-review/agents/openai.yaml
prompts/full-code-review.md
```

状态文件：

```text
ai_snapshot.json
claude-progress.txt
session-state.md
spec.md
evaluation.md
todo.md
verification.md
debt-register.md
defect-rca.md
tasks/_template/
```

Prompt 文件：

```text
prompts/init.md
prompts/resume.md
prompts/handoff.md
prompts/planner.md
prompts/generator.md
prompts/evaluator.md
prompts/full-code-review.md
prompts/task.md
prompts/rca.md
prompts/debt-scan.md
prompts/debt-fix.md
```

辅助脚本：

```text
init.sh
scripts/context_reset_check.sh
scripts/resume_from_snapshot.sh
scripts/snapshot_update.sh
scripts/quick_brief_check.sh
scripts/task_new.sh
scripts/rca_new.sh
scripts/evaluator_check.sh
scripts/ai_debt_scan.sh
```

编辑器和工具配置：

```text
.claude/settings.json
.cursorrules
.vscode/settings.json
.vscode/extensions.json
.clang-format
.gitignore
```

## 不会做什么

脚本不会创建这些业务目录：

```text
src/
include/
tests/
libs/
cmake/
```

不同项目的代码结构不同，Harness 不应该替项目预设目录。请沿用你当前项目自己的结构。

脚本也不会：

- 安装 CMake、编译器、clang-format、GTest 或 Catch2。
- 生成业务代码。
- 修改已有源码。
- 自动配置真实第三方依赖。
- 把 API key 写进项目。

## Claude 和 GPT/Codex 怎么用

Claude Code 使用：

```text
CLAUDE.md
```

GPT/Codex 使用：

```text
AGENTS.md
```

两个入口都只是短索引。真正的细节规则统一放在：

```text
docs/ai/
```

不要把 `CLAUDE.md` 或 `AGENTS.md` 写成长文档。它们只负责告诉 Agent：当前任务应该读哪些文件。

脚本还会生成全代码 Review 入口：

```text
.claude/skills/full-code-review/SKILL.md
.codex/skills/full-code-review/
prompts/full-code-review.md
```

开发完成后需要做全项目检查时，可以让 Claude 使用：

```text
/full-code-review
```

也可以让 Claude 或其他 Agent 读取通用 Prompt：

```text
prompts/full-code-review.md
```

Codex 可以使用：

```text
Use $full-code-review to review the entire project after development and report bugs, risks, and meaningful optimization opportunities.
```

这套 review 入口要求 Agent 先建立全仓库地图，再系统阅读一方代码，输出真实 bug、风险和优化点；不会把结果变成重复的“补测试”清单。

## 避免重复造轮子

脚本会在 `CLAUDE.md` 和 `AGENTS.md` 中写入同一套复用约束：开发前先用 `rg`、目录浏览和已有测试查找同类实现、公共 helper、工具脚本、CMake target 和 fixture。

Generator 和 Resume prompt 也会要求 Agent 优先复用、扩展或轻量抽取现有逻辑；只有现有逻辑不满足规格且复用会扩大风险时，才新增实现。新增公共 helper 后，需要登记到入口文件的 `Shared Utilities` 或相关 `docs/ai/` 文档中。

## 五个工程化优化

### 快照恢复

`ai_snapshot.json` 是给 Agent 读取的最小恢复包，记录当前任务、当前步骤、下一步、必读文件、风险和验证状态。新会话先运行：

```bash
scripts/resume_from_snapshot.sh
```

每轮结束前运行：

```bash
scripts/snapshot_update.sh "当前任务" "当前步骤" "下一步"
```

### Quick Brief 分层阅读

`docs/ai/quick-brief.md` 约定长 Markdown 文件在头部维护 15 行以内的摘要。Agent 续做时先读摘要，必要时再读正文，减少上下文噪声。

检查长文档摘要覆盖：

```bash
scripts/quick_brief_check.sh
```

### Task 沙盒

复杂需求不要全塞进一个 `spec.md`。先创建独立任务目录：

```bash
scripts/task_new.sh short-name
```

生成结构：

```text
tasks/TASK-YYYYMMDDHHMMSS-short-name/
  task.md
  ai_snapshot.json
  verification.md
  defect-rca.md
```

每个 Task 独立记录目标、验收标准、快照、验证和缺陷复盘；完成后再同步关键结论到根目录状态文件。

### RCA 规约自愈

当 Evaluator 失败、人类指出缺陷或同一问题连续失败时，使用：

```text
prompts/rca.md
```

也可以创建独立 RCA 模板：

```bash
scripts/rca_new.sh
```

RCA 的可复用结论写入 `docs/ai/check-rules.md`，让后续 Agent 在开发前能看到真实踩坑沉淀出的检查规则。

### 全代码 Review 入口

开发完成并通过常规实现/验收流程后，使用 `.claude/skills/full-code-review/SKILL.md`、`.codex/skills/full-code-review/` 或 `prompts/full-code-review.md` 触发全仓库 review。

Claude Code 推荐：

```text
/full-code-review
```

Codex 推荐：

```text
用 full-code-review 帮我做全项目代码 review，重点找 bug、风险和有效优化点，不要重复泛泛建议补测试。
```

它适合做“完成后的完整检查”，不适合每改一点就问一次局部 review。

## 推荐日常流程

如果需求还不清楚，先让 Agent 使用：

```text
prompts/planner.md
```

Planner 只负责把需求整理到：

```text
spec.md
```

实现时使用：

```text
prompts/generator.md
```

Generator 按 `spec.md`、`todo.md` 或当前 Task 的开发队列连续实现。它完成一个小项并验证后，应继续领取下一个明确可执行的小项；只有遇到阻塞、失败、需求不清、范围扩大或上下文变浑浊时才交接。Generator 不能写最终通过结论。

验收时使用：

```text
prompts/evaluator.md
```

Evaluator 必须运行真实命令，把证据写进：

```text
evaluation.md
verification.md
```

最终是否完成，以 `evaluation.md` 的独立验收结论为准，不以实现 Agent 的自我评价为准。

## 长任务接力

每次新开一个 Agent 会话，先运行：

```bash
./scripts/context_reset_check.sh
```

然后让 Agent 使用：

```text
prompts/resume.md
```

如果 Agent 跑久了，出现下面情况：

- 上下文很长，开始忘记细节。
- 开始猜测项目状态。
- 想跳过验证。
- 急着宣布完成。
- 改动范围超过原计划。
- 同一个问题连续失败两次。

就让它使用：

```text
prompts/handoff.md
```

这个 Prompt 会要求 Agent 停止扩展任务，把状态写回文件系统，然后让下一轮干净上下文接手。

正常开发不要每做完一个小项就使用 `prompts/handoff.md`。只有没有下一个明确可执行项、验证失败、需求需要确认、范围要扩大、上下文不健康或工具不可用时，才交接。

## Plan 文档怎么放

开发过程中可以让 AI 生成计划文档，建议统一放在：

```text
docs/ai/plans/
```

命名建议：

```text
docs/ai/plans/2026-04-30-add-login-flow.md
docs/ai/plans/2026-04-30-refactor-storage-layer.md
docs/ai/plans/2026-04-30-fix-build-errors.md
```

可以这样要求 Agent：

```text
请阅读 AGENTS.md、spec.md 和 docs/ai/workflow.md，
为这个任务生成实施计划，
保存到 docs/ai/plans/2026-04-30-xxx.md。
不要修改代码。
```

如果使用 Claude Code，把 `AGENTS.md` 换成 `CLAUDE.md`。

计划文档不是最终事实来源。真正的当前状态仍然应该同步到：

```text
claude-progress.txt
session-state.md
todo.md
verification.md
evaluation.md
```

## 技术债怎么处理

扫描技术债：

```bash
./scripts/ai_debt_scan.sh
```

然后让 Agent 使用：

```text
prompts/debt-scan.md
```

真实债务记录到：

```text
debt-register.md
```

修复技术债时使用：

```text
prompts/debt-fix.md
```

原则是一次只修一个小债，不做大范围重构。

## API Key 放在哪里

不要把 API key、token、cookie 或认证文件提交到项目。

GPT/Codex 的模型和 provider 通常放在用户级配置：

```text
~/.codex/config.toml
```

GPT/Codex 的 API key 通常放在：

```text
~/.codex/auth.json
```

Claude Code 的认证通常由 Claude CLI 或应用自己的登录态管理，不应该写进本项目。

项目里只保存规则和流程，不保存密钥。

## 常用命令

初始化：

```bash
bash setup_ai_harness.sh
```

覆盖更新模板：

```bash
bash setup_ai_harness.sh --force
```

查看当前 Harness 状态：

```bash
./init.sh
```

上下文接力自检：

```bash
./scripts/context_reset_check.sh
```

验收自检：

```bash
./scripts/evaluator_check.sh
```

技术债扫描：

```bash
./scripts/ai_debt_scan.sh
```

## 推荐给 Agent 的使用话术

规划需求：

```text
请阅读 AGENTS.md 和 prompts/planner.md，
把我的需求整理到 spec.md。
需求是：xxx
```

实现功能：

```text
请阅读 AGENTS.md、spec.md 和 prompts/generator.md，
先查找并复用已有同类逻辑，再按 spec.md/todo.md 的开发队列连续实现；
每完成一个小项就运行相关验证并记录结果，然后继续下一个明确可执行小项。
```

独立验收：

```text
请阅读 AGENTS.md、spec.md 和 prompts/evaluator.md，
运行真实验证，并把结果写入 evaluation.md。
```

全代码 Review：

```text
Claude Code 使用 /full-code-review；Codex 使用 full-code-review。
帮我做全项目代码 review，重点找 bug、风险和有效优化点，不要重复泛泛建议补测试。
```

长任务接力：

```text
请先运行 scripts/context_reset_check.sh，
然后按照 prompts/resume.md 恢复状态，并从 ai_snapshot.json/todo.md/当前 Task 继续开发队列。
```

交接收尾：

```text
请按照 prompts/handoff.md 停止扩展任务，
把当前状态写回文件系统，方便下一轮接手。
```

## 给团队的约定

- `CLAUDE.md` 和 `AGENTS.md` 只做短索引。
- 细节规则放到 `docs/ai/`。
- 模糊需求先写 `spec.md`。
- 新增代码前先查找已有实现和公共工具，能复用就复用。
- 实现后必须由 Evaluator 独立验收。
- 项目完成后再用 Claude `/full-code-review` 或 Codex `full-code-review` 做一次全仓库 review，不要拆成多次局部检查。
- 长任务必须更新状态文件。
- 技术债每天小步偿还，不攒到最后集中处理。
- API key 永远不要进仓库。
