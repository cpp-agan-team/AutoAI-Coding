#!/usr/bin/env bash

set -uo pipefail

TEST_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FILTER=${1:-}
passed=0
failed=0
skipped=0
selected=0
require_no_skips=${AUTOAI_REQUIRE_NO_SKIPS:-0}

for command_name in git node npm npx; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '[ERROR] 真实集成套件缺少依赖：%s\n' "$command_name" >&2
        exit 2
    fi
done

while IFS= read -r test_file; do
    test_name=$(basename -- "$test_file")
    if [[ -n "$FILTER" && "$test_name" != *"$FILTER"* ]]; then
        continue
    fi

    selected=$((selected + 1))
    printf '\n==> %s\n' "$test_name"
    if bash "$test_file"; then
        printf '[PASS] %s\n' "$test_name"
        passed=$((passed + 1))
    else
        status=$?
        if (( status == 77 )); then
            printf '[SKIP] %s (exit=77)\n' "$test_name"
            skipped=$((skipped + 1))
        else
            printf '[FAIL] %s (exit=%s)\n' "$test_name" "$status" >&2
            failed=$((failed + 1))
        fi
    fi
done < <(find "$TEST_ROOT/real" -maxdepth 1 -type f -name 'test_*.sh' -print | LC_ALL=C sort)

if (( selected == 0 )); then
    printf '[ERROR] 没有找到匹配的真实集成测试：%s\n' "${FILTER:-<all>}" >&2
    exit 2
fi

printf '\nReal-suite summary: %d passed, %d failed, %d skipped, %d total\n' \
    "$passed" "$failed" "$skipped" "$selected"
if (( failed > 0 )); then
    exit 1
fi
if [[ "$require_no_skips" == 1 ]] && (( skipped > 0 )); then
    printf '[ERROR] AUTOAI_REQUIRE_NO_SKIPS=1，但有 %d 个真实集成测试被跳过\n' "$skipped" >&2
    exit 1
fi
exit 0
