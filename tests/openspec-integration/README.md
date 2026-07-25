# OpenSpec integration regression harness

该目录验证 `setup_ai_harness.sh` 的公开模式、preflight 原子边界和文件所有权。所有场景都在 `$TMPDIR` 下创建临时目标 Git 仓库；测试结束后自动清理，不会在用户项目生成 Harness 文件。

运行全部用例：

```bash
bash tests/openspec-integration/run.sh
```

按文件名筛选：

```bash
bash tests/openspec-integration/run.sh preflight
```

默认使用仓库根目录的脚本，也可以测试另一个实现：

```bash
HARNESS_SETUP_SCRIPT=/absolute/path/setup_ai_harness.sh \
  bash tests/openspec-integration/run.sh
```

`fixtures/stubs/bin/` 提供可控的 Node/npm/npx/OpenSpec 1.6.0 替身，因此常规回归不访问 registry。stub 覆盖 setup/preflight 和受管生命周期的可控契约；默认 `run.sh` 故意不运行真实依赖套件。

`fixtures/legacy/recognized/` 只保存能够被迁移器识别的最小旧 Harness 制品，用于验证 legacy 制品识别、迁移分类、备份与恢复。统一入口不会根据这些 fixture 重新生成旧 Harness；普通初始化遇到对应制品时必须 fail closed，并提示使用显式迁移。

runner 使用三态结果：退出码 `0` 计为 `PASS`，退出码 `77` 计为
`SKIP`，其他非零退出码计为 `FAIL`。runner 会继续执行其余文件并在最后汇总，
便于一次看到所有回归缺口。默认情况下只有 `FAIL` 使 runner 返回非零；发布或
完整工具链认证不允许条件跳过时，应启用严格模式：

```bash
AUTOAI_REQUIRE_NO_SKIPS=1 bash tests/openspec-integration/run.sh
AUTOAI_REQUIRE_NO_SKIPS=1 bash tests/openspec-integration/run-real.sh
```

严格模式下只要出现一个 `SKIP`，runner 就返回非零。不依赖可选项目工具的
确定性离线用例都应通过；真实工程形态用例在缺少其声明的本机构建工具时可以
返回 `77`，但发布级兼容矩阵必须用严格模式把这种缺口当作未完成。其他失败都
视为实现回归，而不是“尚未融合”的预期状态。

通用项目适配还有五组聚焦离线用例：

- `test_project_portability.sh` 验证多适配器候选聚合、嵌套/package/fragment
  置信边界、Profile 模块路径、build graph 环、adapter-export 来源、`**/`
  glob、wrapper `required_tools`、Doctor、最深模块归属、原子 gitlink 上下文、
  派生目录符号链接安全、Campaign 和策略。
- `test_project_real_shapes.sh` 使用真实 CMake/CTest/C++，验证纯 Header-only
  SDK、安装后的 SHARED SDK 下游消费、MODULE 插件 `dlopen`/dispatch 和缺插件
  负例；缺少项目工具时以 `77` 单独统计。
- `test_project_multimodule_cross.sh` 使用嵌套 CMake 与 Make 模块、独立 cwd 和
  command identity，构建并检查 ELF32 目标产物，同时证明缺少 target runner
  只阻塞 `target-run`，不会伪造设备行为或误伤未声明的 test/install 能力。
- `test_project_autotools_native.sh` 使用真实 Autotools 工具链执行
  `autoreconf → configure → build → check → install`，再从安装产物编译、链接和
  运行下游 consumer；缺少声明工具时以 `77` 单独统计。
- `test_project_qmake_native.sh` 使用真实 qmake 和 Make 构建不依赖 Qt runtime
  的 C++ CLI，再通过受管入口运行行为验证；缺少声明工具时以 `77` 单独统计。

Superpowers 融合由四层离线回归覆盖：`test_superpowers_governance.sh` 验证 Planner 调查/自审、系统化 RCA、角色和“不安装插件/第二事实源/第二 verdict”边界；`test_tdd_evidence_v2.sh` 验证 snapshot v3、TDD Policy、RED/GREEN/REGRESSION、显式 legacy upgrade 与例外；`test_review_evidence_v2.sh` 验证六层 review input、两阶段 findings 和不可变历史；`test_isolation_pilot.sh` 验证 Fresh Context、linked-worktree lease 及零自动 Git 生命周期。后三项需要 Node 子进程调用本地 Git；若执行环境禁止该系统调用，会以 `EPERM` 失败，不能误判为业务契约结果。

`test_verification_workspace_cleanup.sh` 聚焦验证一次性程序零留存：受管成功/失败命令都清理固定本机工作区，一次性 capability 在 driver 启动前消费，残留可被检查并安全清理；陈旧锁、只读 purpose 的破坏性 cleanup、无锁调用、symlink 清理和把临时路径伪装成 closing evidence 都会 fail closed。

`test_attribution_contract.sh` 验证统一 OpenSpec 模式生成“cpp辅导的阿甘”项目署名、两个 Agent 入口的首次讲解首句规则和完整性检查器；已有 README/第三方源码保持字节与权限不变，署名篡改阻断恢复、验收和归档，检查器权限可由 `--force` 修复，旧 manifest 的精确模板中断状态可恢复，非 AutoAI 作者声明或自定义 Agent 入口即使在 `--force` 下也不会被接管。

Integration Completeness 的离线主线由八个用例覆盖：

- `test_integration_planning_contract.sh`：closed plan、requirement/task 交叉边、task obligation、exact probe 和完整 `kind × role` 笛卡尔积。
- `test_integration_empty_surface_lifecycle.sh`：纯文档 `surfaces: []` 从规划冻结、例外证据、独立 Evaluation 到 archive 的完整闭环，并确认零 production candidate。
- `test_integration_nonblocking_exception_identity_transfer.sh`：普通非阻塞 ALTERNATIVE 的 exact probe/marker 闭包，以及 AST identity 从 removed/base 到 added/current 的显式跨侧转移。
- `test_integration_surface_report.sh`：all-done 后 reviewed inventory、task evidence 新鲜度、candidate 分区、`complete/review_required/orphaned` 和归档恢复深验。
- `test_integration_evaluation_validator.sh`：Evaluation v3 的逐 surface/candidate assessment、mapped coarse orphan backlink、Fail/Blocked/Pass 聚合及对角证据拒绝。
- `test_integration_ast_discovery.sh`：canned base/current AST、overload/template/rename、多配置和安全边界；危险输入为 `invalid`，缺工具/能力/解析为 `blocked`。
- `test_integration_upgrade_v3.sh`：snapshot v3 + verification v2 到 v4/v3 的显式 journal、半写恢复和旧证据保护。
- `test_integration_provisional_recovery.sh`：hardware/external exception 的 provisional obligation、Environment Blocked 与后续真实 REGRESSION 恢复。

task completion 只检查规划中已知的 surface ID、当前 obligation 和 exact probe；未知表面由 all-done 后的 report 与 Evaluator 完整 diff 发现。reviewed 模式的 mapped coarse candidate 若在同一文件中藏有额外具体表面，必须由 Evaluation orphan 与双向 backlink 阻断，不能误把 report `complete` 当成逐符号证明。

## 显式真实依赖套件

当本机具备 Git、Node/npm/npx、CMake、CTest 和 C++ 编译器时，显式运行：

```bash
bash tests/openspec-integration/run-real.sh
```

也可以按文件名筛选：

```bash
bash tests/openspec-integration/run-real.sh openspec_160
bash tests/openspec-integration/run-real.sh cpp_cmake
```

真实套件固定通过被测 Harness 的 runner 使用
`npx --yes --package=@fission-ai/openspec@1.6.0`。冷缓存时 npm 可能访问 registry，并会读写用户 npm cache；固定包版本不等于锁定 tarball、registry、传输链路或缓存内容。因此它不并入默认离线回归，网络或 registry 故障也应与产品逻辑失败分开判断。生成的 runner 会设置 `OPENSPEC_TELEMETRY=0`，但这不会消除 npm 自身的网络与缓存副作用。

临时项目默认创建在 `$TMPDIR` 并在用例结束后删除。排查失败时可保留现场：

```bash
REAL_TEST_KEEP_TMP=1 bash tests/openspec-integration/run-real.sh
```

真实目录当前有九个 `test_*.sh`，分别覆盖上游契约、产品构建/安装边界、七类 surface、兼容生命周期和可选 AST：

- `test_openspec_160_contract.sh` 验证 fresh 初始化、不安装 `/opsx` assets、`new change` 原始 JSON 的绝对路径、artifact status、apply instructions 从 blocked/ready 到 `all_done`、strict validation，以及上游 archive JSON 和主 spec 应用。该用例直接调用 OpenSpec CLI archive 只用于验证官方 1.6.0 contract，**不代表** AutoAI 的 `scripts/change_archive.sh` 受管归档门禁通过。
- `test_cpp_cmake_surfaces.sh` 构造并真实 configure/build/test/install 两个 C++/CMake 项目：micro 组件，以及同时包含 compatible 和 BREAKING change 的多变更 API 项目。两者都验证显式 target/source/install 闭包不会收录 Harness、OpenSpec 或 change-local evidence；另有一个故意使用 `install(DIRECTORY .)` 的负向 fixture，必须检出治理文件泄漏。
- `test_managed_cpp_lifecycle.sh` 在独立真实 C++/CMake 项目中通过固定 OpenSpec `1.6.0` 和生成的受管 wrapper 走完 `change_new`、v4/v3 规划/实现双基线、RED → GREEN → surface-bound REGRESSION、change-final inventory、独立 Evaluator exact probe、closed-schema Pass、archive、主 spec 合并、evidence 保留和 active 清理；同一 probe 内真实执行 clean build、CTest 和 CLI。
- `test_managed_breaking_multichange.sh` 在另一个真实 C++/CMake 项目中先保留一个非 active change，再对已安装公开 API 执行 medium/BREAKING 受管闭环；同时验证旧 consumer 编译被拒绝、下游迁移后通过、主 spec 合并、整个 `harness/` 随 archive 保留、非 active change 未受影响。
- `test_managed_internal_api_reachability.sh` 先证明“单元测试直接调用”不能完成 internal API 接入，再连接真实 production caller，运行 exact probe、独立 Evaluation 和 archive。
- `test_managed_surface_kind_matrix.sh` 覆盖 callback/plugin、configuration、protocol/persistence、CLI 和 build/install：注册不 dispatch、配置只解析、协议只生产、CLI 未接线、仅主仓 build 都先拒绝，接入真实消费者后才归档。
- `test_managed_cli_compatibility_lifecycle.sh` 走完 CLI deprecation → removal，验证 old consumer、replacement consumer、absence probe、多角色 exact evidence 和两次独立归档。
- `test_managed_cpp_compatibility_matrix.sh` 走完 internal API、installed external API 和 CMake surface 的 deprecation → removal，保留旧/替代/缺失角色证据及双 archive。
- `test_managed_clang_ast_lifecycle.sh` 使用真实 Clang 对 base/current 声明做候选发现，验证同一 header 的额外 overload/template 阻断、修复后重验及缺工具 Blocked。该用例只有在 `AUTOAI_REAL_CLANGXX` 或 PATH 提供兼容 `clang++` 时实际执行；否则明确打印 `SKIP` 并以 `77` 退出，由 runner 单独统计。默认 runner 的“无失败”摘要可能包含这个 SKIP，不能据此宣称真实 AST 已认证；要求真实 AST 必须执行时使用 `AUTOAI_REQUIRE_NO_SKIPS=1`。

默认套件使用可控 OpenSpec stub 覆盖大量失败分支；真实套件再用上游 OpenSpec `1.6.0` 和真实 CMake/C++ consumer 验证端到端契约。两层组合既验证确定性门禁，也避免只在 registry 可用时才能诊断失败分支。发布记录应分别保存 offline summary、real summary 和 Clang fixture 是否实际执行，不把条件 SKIP 计作真实兼容性证据。
