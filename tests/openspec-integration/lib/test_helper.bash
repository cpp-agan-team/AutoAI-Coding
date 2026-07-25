#!/usr/bin/env bash

set -euo pipefail

TEST_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$TEST_ROOT/../.." && pwd)
SETUP_SCRIPT=${HARNESS_SETUP_SCRIPT:-"$REPO_ROOT/setup_ai_harness.sh"}
STUB_BIN="$TEST_ROOT/fixtures/stubs/bin"
RUN_STATUS=0
RUN_OUTPUT=

fail() {
    printf '[ASSERT] %s\n' "$*" >&2
    if [[ -n "${RUN_OUTPUT:-}" ]]; then
        printf '%s\n' '--- setup output ---' >&2
        printf '%s\n' "$RUN_OUTPUT" >&2
        printf '%s\n' '--- end setup output ---' >&2
    fi
    return 1
}

note() {
    printf '[TEST] %s\n' "$*"
}

new_test_dir() {
    mktemp -d "${TMPDIR:-/tmp}/autoai-openspec-test.XXXXXX"
}

init_git_repo() {
    local directory=$1
    mkdir -p "$directory"
    git -C "$directory" init -q
}

run_setup() {
    local directory=$1
    shift
    local setup_input=${SETUP_INPUT:-$'\n\n\n'}
    local -a setup_args=("$@")
    local add_default_profile=1
    local profile_supplied=0
    local migration_mode=0
    local dry_run=0
    local arg

    for arg in "${setup_args[@]}"; do
        case "$arg" in
            --project-profile)
                profile_supplied=1
                ;;
            --migrate-openspec)
                migration_mode=1
                ;;
            --dry-run)
                dry_run=1
                ;;
            --detect-project|--help|-h|--version)
                add_default_profile=0
                ;;
        esac
    done
    if [[ "$migration_mode" -eq 1 && "$dry_run" -eq 1 ]]; then
        add_default_profile=0
    fi
    if [[ "$add_default_profile" -eq 1 && "$profile_supplied" -eq 0 ]]; then
        setup_args+=(--project-profile "$TEST_ROOT/fixtures/default/project-profile.json")
    fi

    RUN_OUTPUT=
    RUN_STATUS=0
    set +e
    RUN_OUTPUT=$(
        cd "$directory" || exit 97
        printf '%s' "$setup_input" | bash "$SETUP_SCRIPT" "${setup_args[@]}" 2>&1
    )
    RUN_STATUS=$?
    set -e
}

seed_recognized_legacy_harness() {
    local directory=$1
    local fixture="$TEST_ROOT/fixtures/legacy/recognized"
    mkdir -p "$directory"
    cp -p -- \
        "$fixture/spec.md" \
        "$fixture/todo.md" \
        "$fixture/ai_snapshot.json" \
        "$directory/"
}

assert_status() {
    local expected=$1
    if [[ "$RUN_STATUS" -ne "$expected" ]]; then
        fail "期望退出码 $expected，实际为 $RUN_STATUS"
    fi
}

assert_status_in() {
    local actual=$RUN_STATUS
    local expected
    for expected in "$@"; do
        if [[ "$actual" -eq "$expected" ]]; then
            return 0
        fi
    done
    fail "实际退出码 $actual 不在预期集合：$*"
}

assert_contains() {
    local haystack=$1
    local needle=$2
    if [[ "$haystack" != *"$needle"* ]]; then
        fail "输出中缺少：$needle"
    fi
}

assert_not_contains() {
    local haystack=$1
    local needle=$2
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "输出中不应出现：$needle"
    fi
}

assert_file_contains() {
    local file=$1
    local needle=$2
    [[ -f "$file" ]] || fail "文件不存在：$file"
    grep -Fq -- "$needle" "$file" || fail "文件 $file 中缺少：$needle"
}

assert_file_not_contains() {
    local file=$1
    local needle=$2
    [[ -f "$file" ]] || fail "文件不存在：$file"
    if grep -Fq -- "$needle" "$file"; then
        fail "文件 $file 中不应出现：$needle"
    fi
}

assert_path_exists() {
    local path=$1
    [[ -e "$path" || -L "$path" ]] || fail "路径不存在：$path"
}

assert_path_absent() {
    local path=$1
    [[ ! -e "$path" && ! -L "$path" ]] || fail "路径不应存在：$path"
}

assert_files_equal() {
    local expected=$1
    local actual=$2
    if ! diff -u -- "$expected" "$actual"; then
        fail "文件内容不同：$expected != $actual"
    fi
}

list_worktree_files() {
    local directory=$1
    (
        cd "$directory"
        find . -path './.git' -prune -o \( -type f -o -type l \) -print \
            | sed 's#^\./##' \
            | LC_ALL=C sort
    )
}

# 输出覆盖路径、类型、权限与内容的稳定摘要；故意忽略 .git 内部元数据。
fingerprint_tree() {
    local directory=$1
    (
        cd "$directory"
        while IFS= read -r -d '' path; do
            local_path=${path#./}
            if [[ -L "$path" ]]; then
                printf 'L\t%q\t%s\t%q\n' "$local_path" "$(stat -c '%a' -- "$path")" "$(readlink -- "$path")"
            elif [[ -d "$path" ]]; then
                printf 'D\t%q\t%s\n' "$local_path" "$(stat -c '%a' -- "$path")"
            elif [[ -f "$path" ]]; then
                printf 'F\t%q\t%s\t%s\n' "$local_path" "$(stat -c '%a' -- "$path")" "$(sha256sum -- "$path" | awk '{print $1}')"
            else
                printf 'O\t%q\t%s\n' "$local_path" "$(stat -c '%a' -- "$path")"
            fi
        done < <(find . -path './.git' -prune -o -mindepth 1 -print0 | LC_ALL=C sort -z)
    ) | sha256sum | awk '{print $1}'
}

fingerprint_paths() {
    local directory=$1
    shift
    local path
    for path in "$@"; do
        if [[ -f "$directory/$path" ]]; then
            printf '%s\t%s\t%s\n' "$path" "$(stat -c '%a' -- "$directory/$path")" \
                "$(sha256sum -- "$directory/$path" | awk '{print $1}')"
        elif [[ -L "$directory/$path" ]]; then
            printf '%s\tsymlink\t%q\n' "$path" "$(readlink -- "$directory/$path")"
        elif [[ -d "$directory/$path" ]]; then
            printf '%s\tdirectory\t%s\n' "$path" "$(stat -c '%a' -- "$directory/$path")"
        else
            printf '%s\tmissing\n' "$path"
        fi
    done
}

install_stub_path() {
    export REAL_TEST_PATH=$PATH
    export PATH="$STUB_BIN:$PATH"
}

reset_stub_environment() {
    export STUB_NODE_VERSION=v20.19.0
    export STUB_NPM_VERSION=10.8.2
    export STUB_OPENSPEC_VERSION=1.6.0
    export STUB_NPX_MODE=success
    export STUB_OPENSPEC_VALIDATE_MODE=success
    export STUB_OPENSPEC_STATUS_MODE=success
    export STUB_OPENSPEC_INSTRUCTIONS_MODE=success
    export STUB_OPENSPEC_NEW_MODE=success
    export STUB_OPENSPEC_TASK_TOTAL=1
    export STUB_OPENSPEC_INIT_ASSET_MODE=none
    export STUB_OPENSPEC_LIST_MODE=success
    : > "$STUB_CALL_LOG"
}

# Fresh changes use the current integrated family (local snapshot v4 and
# verification v3).  Older regression cases that deliberately exercise the
# Superpowers-era v3/v2 family must opt into that historical fixture shape
# explicitly instead of depending on the fresh-change default.
use_modern_v2_fixture() {
    local directory=${1:?repository directory required}
    local change=${2:?change ID required}
    node - "$directory/openspec/changes/$change/harness/ai_snapshot.json" \
        "$directory/openspec/changes/$change/harness/verification.json" "$change" <<'NODE'
const fs = require('fs');
const [snapshotFile, verificationFile, change] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
const verification = JSON.parse(fs.readFileSync(verificationFile, 'utf8'));
if (snapshot.schema_version !== 4 || verification.schema_version !== 3 ||
    verification.change_name !== change || verification.migration !== null ||
    !Array.isArray(verification.tasks) || verification.tasks.length !== 0) {
  throw new Error('fresh integrated evidence family mismatch');
}
snapshot.schema_version = 3;
delete snapshot.planned_integration_completeness_sha256;
verification.schema_version = 2;
fs.writeFileSync(snapshotFile, JSON.stringify(snapshot, null, 2) + '\n');
fs.writeFileSync(verificationFile, JSON.stringify(verification, null, 2) + '\n');
NODE
}
