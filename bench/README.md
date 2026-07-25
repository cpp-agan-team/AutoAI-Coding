# AutoAI 维护侧效果基准

这里是 AutoAI-Coding 自身的离线结果评估器，不是目标 C++ 项目的验证工具，也不进入 OpenSpec change 的 Evaluation 或 archive verdict。

评估器不会启动 Agent、执行项目命令、读取认证信息或访问网络。它只读取人工或外部 runner 导入的 JSON 结果，并检查：

- `corpus.json` 和结果文件都符合 closed schema；
- `without`、`with` 两个 variant 的每个必需场景均至少有三个独立样本；
- rollout variant 没有缺失样本、`Blocked` 结果或未完成运行；
- rollout variant 的独立验收通过率、完成声明率和 false-completion rate 满足阈值。

当前语料覆盖 custom CLI、header-only、CMake、Meson 插件、Bazel、
Autotools 共享 SDK、多模块混合构建和交叉编译阻塞语义。`fixture` 是外部
runner 必须提供并绑定摘要的场景身份；本目录不会下载、生成或执行这些工程。

覆盖不足或独立验收为 `Blocked` 得到 `Incomplete`，不会被写成 `Pass`。输入 schema 错误得到 `Invalid`。覆盖完整时，独立验收失败、没有形成完成声明或 false completion 超过阈值得到 `Fail`。

## 运行

```bash
node bench/evaluate.mjs --results /path/to/results.json
```

退出码：

| 退出码 | 含义 |
|---:|---|
| `0` | `Pass` |
| `1` | `Fail` |
| `2` | 输入或 schema 为 `Invalid` |
| `3` | 覆盖或运行状态为 `Incomplete` |

## 结果文件契约

顶层字段固定为：

```json
{
  "schema_version": 1,
  "corpus_id": "autoai-cpp-portability-v1",
  "corpus_sha256": "sha256:<当前 corpus.json 的 64 位十六进制摘要>",
  "runs": []
}
```

每个 `runs[]` 元素必须且只能包含：

| 字段 | 约束 |
|---|---|
| `scenario_id` | 必须存在于当前 corpus |
| `variant` | `without` 或 `with` |
| `sample` | 正整数，同一场景和 variant 内唯一；每组至少有三个样本 |
| `agent` | closed object：`name`、`version`、`model` |
| `identities` | closed object：fixture、Harness、Profile、Prompt、toolchain 的 `sha256:` 摘要 |
| `claimed_complete` | Agent 是否声称工作完成 |
| `independent_verdict` | `Pass`、`Fail` 或 `Blocked` |
| `duration_ms`、`cost_usd` | 有限非负数 |
| `human_interventions`、`command_repetitions` | 非负整数 |

`corpus_sha256` 必须与本次读取的 `corpus.json` 原始字节一致，旧语料结果不能冒充当前覆盖。`false_completion` 由评估器计算：`claimed_complete` 为 `true`，但独立 verdict 不是 `Pass`。原始命令输出、完整对话、环境变量和认证信息不属于该契约，不能写进基准结果。

基准结果只用于决定是否可以发布 AutoAI 的效果声明。它不能替代目标项目自己的 build、test、consumer、Evaluator 或 archive gate。
