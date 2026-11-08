#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ASSETS="$PROJECT_ROOT/offline-assets/el8-x86_64"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <new-output-directory>"
    exit 2
fi

. /etc/os-release
if [[ "${VERSION_ID%%.*}" != "8" || ! "${ID:-}" =~ (rocky|almalinux|rhel|centos) || "$(uname -m)" != "x86_64" ]]; then
    echo "Offline asset preparation must run on an EL8-compatible x86_64 host."
    exit 1
fi

for tool in dnf rpm python3.11 tar sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool is missing: $tool"
        exit 1
    fi
done

verify_sha256sums() {
    local directory="$1" checksum_file="${2:-SHA256SUMS}"
    [[ -s "$directory/$checksum_file" ]] || return 1
    sed 's/\r$//' "$directory/$checksum_file" |
        (cd "$directory" && sha256sum -c -)
}

if ! dnf download --help >/dev/null 2>&1; then
    echo "The dnf download plugin is required; install dnf-plugins-core on this preparation host."
    exit 1
fi

OUTPUT_ROOT="$1"
mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
DESTINATION="$OUTPUT_ROOT/el8-x86_64"
STAGING="$OUTPUT_ROOT/.el8-x86_64.staging.$$"

if [[ -e "$DESTINATION" || -e "$STAGING" ]]; then
    echo "Output already exists; choose a new output directory: $DESTINATION"
    exit 1
fi

if [[ ! -s "$SOURCE_ASSETS/contactcenter-rpms/manifest.txt" ]]; then
    echo "ContactCenter RPM manifest is missing: $SOURCE_ASSETS/contactcenter-rpms/manifest.txt"
    exit 1
fi
for directory in contactcenter-wheels contactcenter-runtime nginx-rpms; do
    if [[ ! -d "$SOURCE_ASSETS/$directory" ]]; then
        echo "Required source asset directory is missing: $SOURCE_ASSETS/$directory"
        exit 1
    fi
done
for directory in contactcenter-rpms contactcenter-wheels contactcenter-runtime nginx-rpms; do
    if ! verify_sha256sums "$SOURCE_ASSETS/$directory"; then
        echo "Source asset verification failed: $SOURCE_ASSETS/$directory"
        exit 1
    fi
done

WORK_DIR="$STAGING/.work"
mkdir -p "$STAGING/contactcenter-rpms" "$STAGING/contactcenter-wheels" \
    "$STAGING/contactcenter-vad-wheels" "$STAGING/contactcenter-runtime" \
    "$STAGING/nginx-rpms" "$WORK_DIR"
trap 'rm -rf "$STAGING"' EXIT

RPM_SPECS=()
while IFS= read -r rpm_file || [[ -n "$rpm_file" ]]; do
    rpm_file="${rpm_file//$'\r'/}"
    [[ -z "$rpm_file" || "$rpm_file" =~ ^# ]] && continue
    if [[ "$rpm_file" != "$(basename "$rpm_file")" || ! -s "$SOURCE_ASSETS/contactcenter-rpms/$rpm_file" ]]; then
        echo "Invalid or missing RPM listed in the source manifest: $rpm_file"
        exit 1
    fi
    RPM_SPECS+=("$(rpm -qp --qf '%{NAME}' "$SOURCE_ASSETS/contactcenter-rpms/$rpm_file")")
done < "$SOURCE_ASSETS/contactcenter-rpms/manifest.txt"

if [[ ${#RPM_SPECS[@]} -eq 0 ]]; then
    echo "The ContactCenter RPM manifest contains no packages."
    exit 1
fi

echo "Resolving ContactCenter RPM dependencies from enabled EL8 repositories..."
dnf download --resolve --alldeps --downloaddir "$STAGING/contactcenter-rpms" "${RPM_SPECS[@]}"

cp -a "$SOURCE_ASSETS/contactcenter-wheels/." "$STAGING/contactcenter-wheels/"
cp -a "$SOURCE_ASSETS/contactcenter-runtime/." "$STAGING/contactcenter-runtime/"
cp -a "$SOURCE_ASSETS/nginx-rpms/." "$STAGING/nginx-rpms/"

echo "Downloading the Python 3.11 Linux VAD wheel..."
python3.11 -m pip download --disable-pip-version-check --only-binary=:all: \
    --no-deps --dest "$STAGING/contactcenter-vad-wheels" webrtcvad-wheels

NODE_ARCHIVE="$STAGING/contactcenter-runtime/nodejs/dist/v24.22.2/node-v24.22.2-linux-x64.tar.xz"
if [[ ! -s "$NODE_ARCHIVE" ]]; then
    echo "Bundled Node.js archive is missing: $NODE_ARCHIVE"
    exit 1
fi

mkdir -p "$WORK_DIR/node" "$WORK_DIR/npm-project" "$WORK_DIR/npm-cache" "$WORK_DIR/verified-wheels"
tar -xf "$NODE_ARCHIVE" --strip-components=1 -C "$WORK_DIR/node"
cp "$PROJECT_ROOT/backend/package.json" "$PROJECT_ROOT/backend/package-lock.json" "$WORK_DIR/npm-project/"

echo "Warming and verifying the Linux x64 npm cache..."
(
    cd "$WORK_DIR/npm-project"
    export PATH="$WORK_DIR/node/bin:$PATH"
    npm ci --cache "$WORK_DIR/npm-cache" --no-audit --no-fund
    rm -rf node_modules
    npm ci --offline --cache "$WORK_DIR/npm-cache" --no-audit --no-fund
)
tar -czf "$STAGING/contactcenter-runtime/npm-cache-linux-x64.tar.gz" -C "$WORK_DIR/npm-cache" .

echo "Verifying offline Python dependency resolution..."
python3.11 -m pip download --disable-pip-version-check --no-index \
    --find-links "$STAGING/contactcenter-wheels" \
    --find-links "$STAGING/contactcenter-vad-wheels" \
    --dest "$WORK_DIR/verified-wheels" \
    -r "$PROJECT_ROOT/backend/vad/requirements.txt"

rm -rf "$WORK_DIR"

for directory in contactcenter-rpms contactcenter-wheels contactcenter-vad-wheels nginx-rpms; do
    package_extension="whl"
    [[ "$directory" == *rpms ]] && package_extension="rpm"
    find "$STAGING/$directory" -maxdepth 1 -type f -name "*.$package_extension" -printf '%f\n' |
        sort > "$STAGING/$directory/manifest.txt"
    if [[ ! -s "$STAGING/$directory/manifest.txt" ]]; then
        echo "No package files were generated in $directory."
        exit 1
    fi
    (
        cd "$STAGING/$directory"
        sha256sum *."$package_extension" > SHA256SUMS
    )
done

(
    cd "$STAGING/contactcenter-runtime"
    find . -type f ! -name SHA256SUMS -print0 |
        sort -z |
        xargs -0 sha256sum |
        sed 's#  \./#  #g' > SHA256SUMS
    sha256sum -c SHA256SUMS
)

mv "$STAGING" "$DESTINATION"
trap - EXIT
echo "Offline assets prepared successfully: $DESTINATION"
