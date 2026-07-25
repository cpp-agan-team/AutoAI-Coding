#!/usr/bin/env bash

set -euo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/real_test_helper.bash"

tmp=$(new_test_dir)
trap 'cleanup_real_workspace "$tmp"' EXIT
repo="$tmp/real OpenSpec 1.6.0 contract"
init_git_repo "$repo"

note '使用真实 npm/npx 完成 fresh 默认初始化（可能访问 registry 并写 npm cache）'
run_setup "$repo"
assert_status 0

version=$(cd "$repo" && scripts/openspec_cli.sh --version)
[[ "$version" == 1.6.0 ]] || fail "固定 runner 版本不是 1.6.0：$version"

note 'tools none 不安装任何 /opsx commands 或 OpenSpec skills'
opsx_assets=$(find "$repo" -path "$repo/.git" -prune -o \
    \( -path '*/commands/opsx*' -o -path '*/skills/openspec*' -o \
       -path '*/skills/opsx*' -o -iname 'opsx-*' \) -print)
[[ -z "$opsx_assets" ]] || fail "发现不应生成的 /opsx asset：$opsx_assets"

change=real-contract-smoke
new_json="$tmp/new-change.json"
initial_status="$tmp/initial-status.json"
initial_instructions="$tmp/initial-instructions.json"

note '直接调用固定 runner，校验 new change 原始 JSON 中的绝对路径契约'
(
    cd "$repo"
    scripts/openspec_cli.sh new change "$change" --json > "$new_json"
    scripts/openspec_cli.sh status --change "$change" --json > "$initial_status"
    scripts/openspec_cli.sh instructions apply --change "$change" --json > "$initial_instructions"
)

node - "$new_json" "$repo" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const [file, repo, change] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const expectedDir = path.join(fs.realpathSync(repo), 'openspec', 'changes', change);
if (data?.change?.id !== change || data.change.schema !== 'spec-driven') {
  throw new Error('new change identity/schema contract mismatch');
}
for (const value of [data.change.path, data.change.metadataPath, data?.root?.path]) {
  if (typeof value !== 'string' || !path.isAbsolute(value)) {
    throw new Error(`expected an absolute path, got ${JSON.stringify(value)}`);
  }
}
if (path.resolve(data.change.path) !== expectedDir) throw new Error('change.path mismatch');
if (path.resolve(data.change.metadataPath) !== path.join(expectedDir, '.openspec.yaml')) {
  throw new Error('metadataPath mismatch');
}
if (path.resolve(data.root.path) !== fs.realpathSync(repo)) throw new Error('root.path mismatch');
NODE

node - "$initial_status" "$initial_instructions" "$change" <<'NODE'
const fs = require('fs');
const [statusFile, instructionsFile, change] = process.argv.slice(2);
const status = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
const instructions = JSON.parse(fs.readFileSync(instructionsFile, 'utf8'));
if (status.changeName !== change || status.schemaName !== 'spec-driven' || status.isComplete !== false) {
  throw new Error('initial status identity/completion mismatch');
}
const path = require('path');
const root = status.root?.path;
const expectedChangeRoot = path.join(root, 'openspec', 'changes', change);
const outputs = {proposal:'proposal.md', design:'design.md', specs:'specs/**/*.md', tasks:'tasks.md'};
if (!path.isAbsolute(root || '') || status.root?.source !== 'nearest' ||
    status.planningHome?.kind !== 'repo' || status.planningHome?.root !== root ||
    status.planningHome?.changesDir !== path.join(root, 'openspec', 'changes') ||
    status.planningHome?.defaultSchema !== 'spec-driven' || status.changeRoot !== expectedChangeRoot) {
  throw new Error('status planning-home/change-root contract mismatch');
}
for (const [id, outputPath] of Object.entries(outputs)) {
  const entry = status.artifactPaths?.[id];
  if (entry?.outputPath !== outputPath || entry?.resolvedOutputPath !== path.join(expectedChangeRoot, outputPath) ||
      !Array.isArray(entry?.existingOutputPaths)) {
    throw new Error(`status artifactPaths contract mismatch: ${id}`);
  }
}
const artifactState = Object.fromEntries(status.artifacts.map(item => [item.id, item.status]));
if (artifactState.proposal !== 'ready' || artifactState.design !== 'blocked' ||
    artifactState.specs !== 'blocked' || artifactState.tasks !== 'blocked') {
  throw new Error(`unexpected initial artifacts: ${JSON.stringify(artifactState)}`);
}
if (instructions.state !== 'blocked' || instructions.progress.total !== 0 ||
    !instructions.missingArtifacts.includes('tasks')) {
  throw new Error('initial apply instructions are not blocked on tasks');
}
NODE

change_dir="$repo/openspec/changes/$change"
mkdir -p "$change_dir/specs/contract-smoke"

cat > "$change_dir/proposal.md" <<'EOF'
## Why

Exercise the pinned OpenSpec release against its real repository-local data model.

## What Changes

- Add one observable contract-smoke capability.

## Capabilities

### New Capabilities

- `contract-smoke`: Defines the observable smoke result.

### Modified Capabilities

- None.

## Impact

Only this disposable test repository is affected.
EOF

cat > "$change_dir/design.md" <<'EOF'
## Context

This disposable fixture verifies the upstream CLI contract.

## Goals / Non-Goals

**Goals:** Verify real OpenSpec status, instructions, validation, and archive JSON.

**Non-Goals:** Exercise or bypass the AutoAI managed archive gate.

## Decisions

Use one new capability and one independently trackable task.

## Risks / Trade-offs

The explicit real suite depends on npm registry/cache availability.
EOF

cat > "$change_dir/specs/contract-smoke/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Contract smoke succeeds
The fixture SHALL expose a successful contract smoke result.

#### Scenario: Successful smoke
- **WHEN** the contract fixture is evaluated
- **THEN** it reports a successful result
EOF

cat > "$change_dir/tasks.md" <<'EOF'
## 1. Contract smoke

- [ ] 1.1 Execute the real OpenSpec 1.6.0 contract smoke
EOF

ready_status="$tmp/ready-status.json"
ready_instructions="$tmp/ready-instructions.json"
(
    cd "$repo"
    scripts/openspec_cli.sh status --change "$change" --json > "$ready_status"
    scripts/openspec_cli.sh instructions apply --change "$change" --json > "$ready_instructions"
)

node - "$ready_status" "$ready_instructions" <<'NODE'
const fs = require('fs');
const [statusFile, instructionsFile] = process.argv.slice(2);
const status = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
const instructions = JSON.parse(fs.readFileSync(instructionsFile, 'utf8'));
if (status.isComplete !== true || status.artifacts.some(item => item.status !== 'done')) {
  throw new Error('planning artifacts did not transition to done');
}
if (instructions.state !== 'ready' || instructions.progress.total !== 1 ||
    instructions.progress.complete !== 0 || instructions.progress.remaining !== 1 ||
    instructions.tasks.length !== 1 || instructions.tasks[0].done !== false) {
  throw new Error('unchecked task did not produce ready/remaining instructions');
}
NODE

sed -i 's/- \[ \]/- [x]/' "$change_dir/tasks.md"
done_instructions="$tmp/done-instructions.json"
validation_json="$tmp/strict-validation.json"
(
    cd "$repo"
    scripts/openspec_cli.sh instructions apply --change "$change" --json > "$done_instructions"
    scripts/openspec_cli.sh validate "$change" --type change --strict --json > "$validation_json"
)

node - "$done_instructions" "$validation_json" "$change" <<'NODE'
const fs = require('fs');
const [instructionsFile, validationFile, change] = process.argv.slice(2);
const instructions = JSON.parse(fs.readFileSync(instructionsFile, 'utf8'));
const validation = JSON.parse(fs.readFileSync(validationFile, 'utf8'));
if (instructions.state !== 'all_done' || instructions.progress.total !== 1 ||
    instructions.progress.complete !== 1 || instructions.progress.remaining !== 0 ||
    instructions.tasks.some(task => task.done !== true)) {
  throw new Error('checked task did not transition instructions to all_done');
}
if (validation.summary?.totals?.failed !== 0 || validation.items.length !== 1 ||
    validation.items[0].id !== change || validation.items[0].valid !== true ||
    validation.items[0].issues.some(issue => issue.level === 'ERROR')) {
  throw new Error('strict change validation did not pass');
}
NODE

note '直接 CLI archive 只做上游 1.6.0 contract smoke；它不代表受管归档门禁通过'
archive_json="$tmp/archive.json"
(
    cd "$repo"
    scripts/openspec_cli.sh archive "$change" --yes --json > "$archive_json"
)

node - "$archive_json" "$repo" "$change" <<'NODE'
const fs = require('fs');
const path = require('path');
const [file, repo, change] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const archive = data?.archive;
if (archive?.change !== change || archive.specsUpdated !== true || archive.totals?.added !== 1) {
  throw new Error('archive JSON identity/spec update contract mismatch');
}
if (!/^\d{4}-\d{2}-\d{2}-real-contract-smoke$/.test(archive.archivedAs)) {
  throw new Error(`invalid archivedAs: ${archive.archivedAs}`);
}
const expected = path.join(fs.realpathSync(repo), 'openspec', 'changes', 'archive', archive.archivedAs);
if (!path.isAbsolute(archive.path) || path.resolve(archive.path) !== expected ||
    !fs.statSync(expected).isDirectory()) {
  throw new Error('archive absolute path/filesystem contract mismatch');
}
NODE

all_validation="$tmp/all-validation.json"
(
    cd "$repo"
    scripts/openspec_cli.sh validate --all --strict --json --no-interactive > "$all_validation"
)
node - "$all_validation" "$repo/openspec/specs/contract-smoke/spec.md" <<'NODE'
const fs = require('fs');
const [file, mainSpec] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
if (!fs.existsSync(mainSpec)) throw new Error('archived ADDED delta was not applied to main specs');
if (data.summary?.totals?.failed !== 0 || data.items.length < 1 ||
    data.items.some(item => item.valid !== true)) {
  throw new Error('post-archive strict --all validation failed');
}
NODE
