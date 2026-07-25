#!/usr/bin/env bash

set -euo pipefail

REAL_TEST_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$REAL_TEST_ROOT/lib/test_helper.bash"

cleanup_real_workspace() {
    local directory=$1
    if [[ "${REAL_TEST_KEEP_TMP:-0}" == 1 ]]; then
        note "保留真实测试工作区：$directory"
    else
        rm -rf -- "$directory"
    fi
}

assert_no_governance_install_leak() {
    local prefix=$1
    local hits
    hits=$(find "$prefix" \
        \( -path '*/openspec/*' -o -path '*/.ai-harness/*' -o \
           -path '*/changes/*/harness/*' -o -name PROJECT_ATTRIBUTION.md -o -name CLAUDE.md -o -name AGENTS.md -o \
           -name ai_snapshot.json \) -print 2>/dev/null || true)
    [[ -z "$hits" ]] || fail "显式安装面包含治理制品：$hits"
}

run_cmake_pipeline() {
    local source_dir=$1
    local build_dir=$2
    local install_dir=$3
    shift 3
    cmake -S "$source_dir" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$install_dir" "$@"
    cmake --build "$build_dir" --parallel 2
    ctest --test-dir "$build_dir" --output-on-failure
    cmake --install "$build_dir"
}
