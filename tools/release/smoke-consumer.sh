#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
ARTIFACT_DIR=
VERSION=

usage() {
    cat <<'EOF'
Usage:
  bash tools/release/smoke-consumer.sh --dir <artifact-directory> [--version <x.y.z>]

Verifies an AutoAI release artifact, extracts it into an isolated temporary
directory, initializes a disposable Git-managed custom C++ project through the
packaged setup script, runs Doctor and a reviewed Project Profile command, and
starts one OpenSpec change. The OpenSpec CLI is replaced by a local protocol
stub, so this smoke test never accesses the network or an npm registry.
EOF
}

die() {
    printf '[ERR] %s\n' "$*" >&2
    exit 2
}

while (($# > 0)); do
    case "$1" in
        --dir)
            (($# >= 2)) || die '--dir requires a directory'
            ARTIFACT_DIR=$2
            shift
            ;;
        --version)
            (($# >= 2)) || die '--version requires a value'
            VERSION=$2
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

[[ -n "$ARTIFACT_DIR" ]] || die '--dir is required'
[[ -n "$VERSION" ]] || VERSION=$(tr -d '\r\n' < "$REPO_ROOT/VERSION")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'version must be semantic x.y.z'

for command_name in bash git node npm tar mktemp; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "missing required command: $command_name"
done

ARTIFACT_DIR=$(CDPATH= cd -- "$ARTIFACT_DIR" && pwd)
node "$SCRIPT_DIR/verify-integrity.mjs" --dir "$ARTIFACT_DIR" --version "$VERSION" >/dev/null

tmp=$(mktemp -d "${TMPDIR:-/tmp}/autoai-release-smoke.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
package_root="$tmp/package"
consumer="$tmp/consumer"
fake_bin="$tmp/fake-bin"
mkdir -p "$package_root" "$consumer/tools" "$consumer/src" "$fake_bin"

tar -xzf "$ARTIFACT_DIR/autoai-coding-$VERSION.tar.gz" -C "$package_root"
packaged_setup="$package_root/autoai-coding-$VERSION/setup_ai_harness.sh"
[[ -f "$packaged_setup" && ! -L "$packaged_setup" && -x "$packaged_setup" ]] ||
    die 'verified release did not contain an executable setup_ai_harness.sh'

cat > "$consumer/tools/project-smoke" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'AUTOAI_RELEASE_CONSUMER_OK\n'
EOF
chmod 0755 "$consumer/tools/project-smoke"

cat > "$consumer/src/smoke.cpp" <<'EOF'
int autoai_release_smoke() {
    return 0;
}
EOF

cat > "$consumer/project-profile.json" <<'EOF'
{
  "schema_version": 1,
  "modules": [
    {
      "id": "root",
      "root": ".",
      "adapter": "custom",
      "cpp_standards": [
        "unknown"
      ],
      "compilers": [
        "unknown"
      ],
      "target_platforms": [
        "unknown"
      ],
      "path_roles": {
        "production": [
          "src/**"
        ],
        "test": [],
        "example": [],
        "generated": [],
        "vendor": [],
        "build_metadata": [
          "tools/project-smoke"
        ]
      },
      "capabilities": {
        "static-analysis": [
          "project-smoke"
        ]
      },
      "build_graph_entries": [],
      "distribution_surfaces": []
    }
  ],
  "commands": [
    {
      "id": "project-smoke",
      "module_ids": [
        "root"
      ],
      "capability": "static-analysis",
      "argv": [
        "./tools/project-smoke"
      ],
      "cwd": ".",
      "timeout_seconds": 30,
      "inherit_env": [],
      "output_roles": [
        "analysis"
      ],
      "side_effects": []
    }
  ],
  "toolchain_identity": []
}
EOF

cat > "$fake_bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version || "${1:-}" == -v ]]; then
    printf '10.0.0\n'
    exit 0
fi
args=("$@")
index=-1
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == openspec ]]; then
        index=$i
        break
    fi
done
((index >= 0)) || exit 64
command_args=("${args[@]:index + 1}")
case "${command_args[0]:---help}" in
    --version|-v|version)
        printf '1.6.0\n'
        ;;
    init)
        mkdir -p openspec/specs openspec/changes/archive
        [[ -f openspec/config.yaml ]] || printf 'schema: spec-driven\n' > openspec/config.yaml
        ;;
    validate)
        printf '{"items":[],"summary":{"totals":{"failed":0}}}\n'
        ;;
    new)
        [[ "${command_args[1]:-}" == change && -n "${command_args[2]:-}" ]] || exit 64
        change=${command_args[2]}
        root=$(pwd -P)
        mkdir -p "openspec/changes/$change"
        printf 'schema: spec-driven\n' > "openspec/changes/$change/.openspec.yaml"
        printf '{"change":{"id":"%s","path":"%s/openspec/changes/%s","metadataPath":"%s/openspec/changes/%s/.openspec.yaml","schema":"spec-driven"}}\n' \
            "$change" "$root" "$change" "$root" "$change"
        ;;
    *)
        exit 64
        ;;
esac
EOF
chmod 0755 "$fake_bin/npx"

git -C "$consumer" init -q
git -C "$consumer" config user.name 'AutoAI Release Smoke'
git -C "$consumer" config user.email 'autoai-smoke@example.invalid'
git -C "$consumer" add src tools project-profile.json
git -C "$consumer" commit -qm 'seed isolated consumer'

(
    cd "$consumer"
    printf '\n' |
        PATH="$fake_bin:$PATH" \
        bash "$packaged_setup" --project-profile project-profile.json >/dev/null ||
        die 'packaged setup failed in the isolated consumer'

    scripts/project_profile.sh --check --json >/dev/null ||
        die 'generated Project Profile check failed in the isolated consumer'
    scripts/workflow_contract_check.sh --json >/dev/null ||
        die 'generated workflow contract check failed in the isolated consumer'
    PATH="$fake_bin:$PATH" scripts/harness_doctor.sh --json > "$tmp/doctor.json" || {
        cat "$tmp/doctor.json" >&2
        die 'generated Doctor failed in the isolated consumer'
    }
    scripts/project_command.sh project-smoke --json > "$tmp/project-command.json" ||
        die 'reviewed Project Profile command failed in the isolated consumer'
    scripts/change_new.sh release-smoke-change >/dev/null ||
        die 'basic OpenSpec change creation failed in the isolated consumer'
)

node - "$tmp/doctor.json" "$tmp/project-command.json" "$consumer/ai_snapshot.json" <<'NODE'
const fs = require('fs');
const [doctorFile, commandFile, snapshotFile] = process.argv.slice(2);
const doctor = JSON.parse(fs.readFileSync(doctorFile, 'utf8'));
const command = JSON.parse(fs.readFileSync(commandFile, 'utf8'));
const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
if (!['pass', 'degraded'].includes(doctor.summary?.status) ||
    command.schema_version !== 1 || command.status !== 'Pass' ||
    command.identity?.command_id !== 'project-smoke' ||
    !String(command.stdout).includes('AUTOAI_RELEASE_CONSUMER_OK') ||
    snapshot.workflow !== 'openspec' ||
    snapshot.active_change !== 'release-smoke-change') {
  throw new Error('isolated release consumer lifecycle did not close');
}
NODE

printf '[OK] isolated release consumer smoke passed for %s\n' "$VERSION"
