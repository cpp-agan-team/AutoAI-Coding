#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
PACKAGE_NAME=autoai-coding
OUT_DIR=
ALLOW_DIRTY=0

usage() {
    cat <<'EOF'
Usage:
  bash tools/release/build-integrity.sh --out <directory> [--allow-dirty]

Builds a deterministic AutoAI-Coding release archive and integrity-only
sidecars. It never commits, tags, pushes, signs, publishes, or mutates sources.
EOF
}

die() {
    printf '[ERR] %s\n' "$*" >&2
    exit 2
}

while (($# > 0)); do
    case "$1" in
        --out)
            (($# >= 2)) || die '--out requires a directory'
            OUT_DIR=$2
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
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

[[ -n "$OUT_DIR" ]] || die '--out is required'
for command_name in git node tar gzip install mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done

git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die 'source directory is not a Git worktree'
[[ "$(git -C "$REPO_ROOT" rev-parse --show-toplevel)" == "$REPO_ROOT" ]] ||
    die 'release tool must reside in the repository root'

version=$(tr -d '\r\n' < "$REPO_ROOT/VERSION")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'VERSION must contain one semantic version'
revision=$(git -C "$REPO_ROOT" rev-parse HEAD)
[[ "$revision" =~ ^[0-9a-f]{40,64}$ ]] || die 'unable to resolve source revision'
source_date_epoch=$(git -C "$REPO_ROOT" show -s --format=%ct HEAD)
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || die 'unable to resolve source revision timestamp'

dirty=0
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]]; then
    dirty=1
fi
if ((dirty == 1 && ALLOW_DIRTY == 0)); then
    die 'source worktree is dirty; commit reviewed sources or pass --allow-dirty for a non-promotable artifact'
fi

release_root="${PACKAGE_NAME}-${version}"
base="${PACKAGE_NAME}-${version}"
archive_name="${base}.tar.gz"
manifest_name="${base}.content-manifest.json"
statement_name="${base}.integrity.json"
checksum_name="${archive_name}.sha256"

allowlist=(
    setup_ai_harness.sh
    VERSION
    README.md
    PROJECT_ATTRIBUTION.md
)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/autoai-release.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
stage="$tmp/stage/$release_root"
dist="$tmp/dist"
mkdir -p "$stage" "$dist"

for relative in "${allowlist[@]}"; do
    source_path="$REPO_ROOT/$relative"
    [[ -f "$source_path" && ! -L "$source_path" ]] ||
        die "allowlisted source is missing, non-regular, or a symlink: $relative"
    mode=0644
    [[ "$relative" == setup_ai_harness.sh ]] && mode=0755
    install -D -m "$mode" -- "$source_path" "$stage/$relative"
done
chmod 0755 "$stage"

manifest="$dist/$manifest_name"
node - "$manifest" "$stage" "$PACKAGE_NAME" "$version" "$release_root" \
    "${allowlist[@]}" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [manifest, stage, packageName, version, root, ...files] = process.argv.slice(2);
const digest = file => `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
const entries = files.map(relative => {
  const full = path.join(stage, relative);
  const stat = fs.lstatSync(full);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`unsafe staged type: ${relative}`);
  return {
    path: `${root}/${relative}`,
    type: 'file',
    mode: (stat.mode & 0o7777).toString(8).padStart(4, '0'),
    size: stat.size,
    sha256: digest(full),
  };
}).sort((left, right) => Buffer.from(left.path).compare(Buffer.from(right.path)));
const body = {
  schema_version: 1,
  package: packageName,
  version,
  root,
  files: entries,
};
fs.writeFileSync(manifest, `${JSON.stringify(body, null, 2)}\n`, { flag: 'wx', mode: 0o644 });
NODE

archive="$dist/$archive_name"
(
    cd "$tmp/stage"
    LC_ALL=C tar \
        --sort=name \
        "--mtime=@$source_date_epoch" \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        --format=ustar \
        -cf - \
        "$release_root" |
        gzip -n > "$archive"
)

statement="$dist/$statement_name"
node - "$statement" "$archive" "$manifest" "$PACKAGE_NAME" "$version" \
    "$revision" "$dirty" "$source_date_epoch" "$archive_name" "$manifest_name" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const [
  statement, archive, manifest, packageName, version, revision, dirty,
  sourceDateEpoch, archiveName, manifestName,
] = process.argv.slice(2);
const digest = file => `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
const body = {
  schema_version: 1,
  authenticity: 'integrity-only',
  package: packageName,
  version,
  generated_at: new Date(Number(sourceDateEpoch) * 1000).toISOString().replace('.000Z', 'Z'),
  source: {
    revision,
    dirty: dirty === '1',
  },
  artifact: {
    name: archiveName,
    size: fs.statSync(archive).size,
    sha256: digest(archive),
  },
  content_manifest: {
    name: manifestName,
    sha256: digest(manifest),
  },
};
fs.writeFileSync(statement, `${JSON.stringify(body, null, 2)}\n`, { flag: 'wx', mode: 0o644 });
NODE

node - "$statement" "$dist/$checksum_name" <<'NODE'
const fs = require('fs');
const [statementFile, checksumFile] = process.argv.slice(2);
const statement = JSON.parse(fs.readFileSync(statementFile, 'utf8'));
fs.writeFileSync(checksumFile, `${statement.artifact.sha256}\n`, { flag: 'wx', mode: 0o644 });
NODE

node "$SCRIPT_DIR/verify-integrity.mjs" --dir "$dist" --version "$version" >/dev/null ||
    die 'newly built artifact failed its own integrity verification'
bash "$SCRIPT_DIR/smoke-consumer.sh" --dir "$dist" --version "$version" ||
    die 'newly built artifact failed the isolated consumer smoke'

if [[ -e "$OUT_DIR" || -L "$OUT_DIR" ]]; then
    [[ -d "$OUT_DIR" && ! -L "$OUT_DIR" ]] ||
        die "output path is not a non-symlink directory: $OUT_DIR"
fi
mkdir -p "$OUT_DIR"
for name in "$archive_name" "$manifest_name" "$statement_name" "$checksum_name"; do
    [[ ! -e "$OUT_DIR/$name" && ! -L "$OUT_DIR/$name" ]] ||
        die "output already exists: $OUT_DIR/$name"
done
for name in "$archive_name" "$manifest_name" "$statement_name" "$checksum_name"; do
    install -m 0644 -- "$dist/$name" "$OUT_DIR/$name"
done

printf '%s\n' "$OUT_DIR/$archive_name"
printf '%s\n' "$OUT_DIR/$manifest_name"
printf '%s\n' "$OUT_DIR/$statement_name"
printf '%s\n' "$OUT_DIR/$checksum_name"
