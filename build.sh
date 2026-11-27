#!/usr/bin/env bash
# Sentinel Precision cross-platform release builder.
#
# The default mode builds one target and embeds the already-exported frontend.
# `./build.sh --release` builds and packages all supported desktop/server targets.
#
# Environment variables:
#   SENTINEL_PRECISION_TARGET_OS=linux             One target OS in single-target mode.
#   SENTINEL_PRECISION_TARGET_ARCH=amd64           One target arch in single-target mode.
#   SENTINEL_PRECISION_TARGETS=linux/amd64,...     Comma-separated targets for multi-target mode.
#   SENTINEL_PRECISION_BUILD_VERSION=vX.Y.Z        Version embedded in the binary and archive name.
#   SENTINEL_PRECISION_OUTPUT=/path/to/sentinelprecision       Explicit binary path in single-target mode.
#   SENTINEL_PRECISION_OUTPUT_DIR=dist             Directory for default binary paths.
#   SENTINEL_PRECISION_PACKAGE=1                   Create a zip archive for each target.
#   SENTINEL_PRECISION_PACKAGE_DIR=dist            Directory for release archives.
#   SENTINEL_PRECISION_COMPRESS=off                UPX mode: off, auto, or required.
#   SENTINEL_PRECISION_UPX_ARGS="--best --lzma"    Arguments passed to UPX.
#   SENTINEL_PRECISION_SKIP_FRONTEND=1             Reuse server/webui/dist (for CI artifact builds).
#   SENTINEL_PRECISION_SKIP_NPM_CI=1               Skip npm ci while rebuilding the frontend.
#   SENTINEL_PRECISION_GOSUMDB=sum.golang.org      Go checksum database.
set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)"

info() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./build.sh                         Build for the current OS and architecture
  ./build.sh --target linux/amd64   Build one specific target
  ./build.sh --release               Build and package all supported targets

Options:
  --release              Build the amd64/arm64 targets for Linux, macOS, and Windows, and generate zips
  --target OS/ARCH       Set a single target, e.g. windows/amd64
  --upx                  Force UPX compression of the binary (may affect compatibility on some Linux environments)
  --no-compress          No UPX; use only Go linker trimming and zip compression
  --help                 Show this help

The multi-target list can be overridden via SENTINEL_PRECISION_TARGETS, e.g.:
  SENTINEL_PRECISION_TARGETS=linux/amd64,windows/amd64 ./build.sh --release
EOF
}

RELEASE_TARGETS_DEFAULT="linux/amd64,linux/arm64,darwin/amd64,darwin/arm64,windows/amd64"
SENTINEL_PRECISION_RELEASE="${SENTINEL_PRECISION_RELEASE:-0}"
SENTINEL_PRECISION_COMPRESS="${SENTINEL_PRECISION_COMPRESS:-off}"
SENTINEL_PRECISION_PACKAGE="${SENTINEL_PRECISION_PACKAGE:-0}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)
      SENTINEL_PRECISION_RELEASE=1
      SENTINEL_PRECISION_PACKAGE=1
      shift
      ;;
    --target)
      [ "$#" -ge 2 ] || die "--target requires an OS/ARCH argument"
      target_arg="$2"
      case "$target_arg" in
        */*)
          SENTINEL_PRECISION_TARGET_OS="${target_arg%%/*}"
          SENTINEL_PRECISION_TARGET_ARCH="${target_arg##*/}"
          SENTINEL_PRECISION_TARGETS="$target_arg"
          ;;
        *) die "target must be OS/ARCH, e.g. linux/amd64" ;;
      esac
      shift 2
      ;;
    --no-compress)
      SENTINEL_PRECISION_COMPRESS=0
      shift
      ;;
    --upx)
      SENTINEL_PRECISION_COMPRESS=required
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (use --help for usage)" ;;
  esac
done

command -v go >/dev/null 2>&1 || die "Go not detected (the project requires Go 1.26 or newer)"

SENTINEL_PRECISION_GOSUMDB="${SENTINEL_PRECISION_GOSUMDB:-sum.golang.org}"
if [ -z "${SENTINEL_PRECISION_BUILD_VERSION:-}" ]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SENTINEL_PRECISION_BUILD_VERSION="$(git describe --tags --always --dirty)"
  else
    SENTINEL_PRECISION_BUILD_VERSION="dev"
  fi
fi
# Release tags are commonly passed with a v prefix; keep the binary version consistent.
SENTINEL_PRECISION_BUILD_VERSION="${SENTINEL_PRECISION_BUILD_VERSION#v}"
SENTINEL_PRECISION_OUTPUT_DIR="${SENTINEL_PRECISION_OUTPUT_DIR:-dist}"
SENTINEL_PRECISION_PACKAGE_DIR="${SENTINEL_PRECISION_PACKAGE_DIR:-$SENTINEL_PRECISION_OUTPUT_DIR}"
SENTINEL_PRECISION_UPX_ARGS="${SENTINEL_PRECISION_UPX_ARGS:---best --lzma}"

if [ "${SENTINEL_PRECISION_RELEASE}" = "1" ]; then
  SENTINEL_PRECISION_TARGETS="${SENTINEL_PRECISION_TARGETS:-$RELEASE_TARGETS_DEFAULT}"
else
  SENTINEL_PRECISION_TARGET_OS="${SENTINEL_PRECISION_TARGET_OS:-$(GOSUMDB="$SENTINEL_PRECISION_GOSUMDB" go env GOOS)}"
  SENTINEL_PRECISION_TARGET_ARCH="${SENTINEL_PRECISION_TARGET_ARCH:-$(GOSUMDB="$SENTINEL_PRECISION_GOSUMDB" go env GOARCH)}"
  SENTINEL_PRECISION_TARGETS="${SENTINEL_PRECISION_TARGETS:-${SENTINEL_PRECISION_TARGET_OS}/${SENTINEL_PRECISION_TARGET_ARCH}}"
fi

if [ "${SENTINEL_PRECISION_SKIP_FRONTEND:-0}" = "1" ]; then
  [ -d server/webui/dist ] || die "SENTINEL_PRECISION_SKIP_FRONTEND=1 but server/webui/dist does not exist"
else
  command -v npm >/dev/null 2>&1 || die "npm not detected (building the frontend static assets requires Node.js/npm)"
  command -v rsync >/dev/null 2>&1 || die "rsync not detected"
  info "Building frontend static assets"
  if [ "${SENTINEL_PRECISION_SKIP_NPM_CI:-0}" != "1" ]; then
    (cd web && npm ci --ignore-scripts)
  fi
  (cd web && npm run build:static)
  info "Syncing frontend assets to server/webui/dist"
  mkdir -p server/webui/dist
  rsync -a --delete web/out/ server/webui/dist/
fi

compress_binary() {
  binary="$1"
  goos="$2"
  case "$SENTINEL_PRECISION_COMPRESS" in
    0|off|false|none)
      info "Skipping UPX: $binary"
      return 0
      ;;
    auto|required|true|1) ;;
    *) die "SENTINEL_PRECISION_COMPRESS must be off, auto, or required" ;;
  esac

  if ! command -v upx >/dev/null 2>&1; then
    if [ "$SENTINEL_PRECISION_COMPRESS" = "required" ]; then
      die "SENTINEL_PRECISION_COMPRESS=required but upx was not detected"
    fi
    warn "upx not detected; keeping the linker-compressed result: $binary"
    return 0
  fi

  before=$(wc -c < "$binary" | tr -d ' ')
  upx_args="$SENTINEL_PRECISION_UPX_ARGS"
  [ "$goos" = "darwin" ] && upx_args="$upx_args --force-macos"
  # shellcheck disable=SC2086
  if ! upx $upx_args -- "$binary"; then
    if [ "$SENTINEL_PRECISION_COMPRESS" = "required" ]; then
      die "UPX compression failed: $binary"
    fi
    warn "UPX does not support this target format; keeping the uncompressed binary: $binary"
    return 0
  fi
  after=$(wc -c < "$binary" | tr -d ' ')
  ok "UPX compression done: $binary (${before} -> ${after} bytes)"
}

package_binary() {
  binary="$1"
  goos="$2"
  goarch="$3"
  package_name="sentinelprecision-${SENTINEL_PRECISION_BUILD_VERSION}-${goos}-${goarch}"
  package_root="${SENTINEL_PRECISION_PACKAGE_DIR}/${package_name}"
  archive="${SENTINEL_PRECISION_PACKAGE_DIR}/${package_name}.zip"

  command -v zip >/dev/null 2>&1 || die "packaging requires zip"
  rm -rf "$package_root" "$archive"
  mkdir -p "$package_root"
  cp "$binary" "$package_root/"
  # The guardian start script is the official entry point: the page's one-click
  # update relies on it to relaunch the process after it exits; running the sentinelprecision
  # binary directly means it never comes back up after an update. Ship only the one
  # matching the target OS.
  if [ "$goos" = "windows" ]; then
    cp start.bat "$package_root/"
  else
    cp start.sh "$package_root/"
    chmod +x "$package_root/start.sh"
  fi
  cp -R skills "$package_root/"
  cp config.example.json "$package_root/"
  if [ -f README.md ]; then cp README.md "$package_root/"; fi
  (cd "$SENTINEL_PRECISION_PACKAGE_DIR" && zip -q -r -9 "$(basename "$archive")" "$(basename "$package_root")")
  rm -rf "$package_root"
  ok "Release archive: $archive"
}

build_target() {
  target="$1"
  case "$target" in
    */*) ;;
    *) die "invalid target: $target (must be OS/ARCH)" ;;
  esac
  goos="${target%%/*}"
  goarch="${target##*/}"
  case "$goos" in
    linux|darwin|windows) ;;
    *) die "unsupported OS: $goos (supported: linux, darwin, windows)" ;;
  esac

  binary_name="sentinelprecision"
  [ "$goos" = "windows" ] && binary_name="sentinelprecision.exe"
  if [ -n "${SENTINEL_PRECISION_OUTPUT:-}" ] && [ "$SENTINEL_PRECISION_RELEASE" != "1" ]; then
    output="$SENTINEL_PRECISION_OUTPUT"
  else
    output="${SENTINEL_PRECISION_OUTPUT_DIR}/sentinelprecision-${goos}-${goarch}/${binary_name}"
  fi
  mkdir -p "$(dirname "$output")"

  info "Compiling ${goos}/${goarch}, version ${SENTINEL_PRECISION_BUILD_VERSION}"
  GOSUMDB="$SENTINEL_PRECISION_GOSUMDB" \
  CGO_ENABLED=0 \
  GOOS="$goos" \
  GOARCH="$goarch" \
  go build \
    -tags embedui \
    -trimpath \
    -ldflags "-s -w -buildid= -X main.version=${SENTINEL_PRECISION_BUILD_VERSION}" \
    -o "$output" \
    ./cmd/sentinelprecision

  compress_binary "$output" "$goos"
  if command -v file >/dev/null 2>&1; then file "$output"; fi
  if [ "$SENTINEL_PRECISION_PACKAGE" = "1" ]; then package_binary "$output" "$goos" "$goarch"; fi
  ok "Build complete: $output"
}

write_checksums() {
  [ "$SENTINEL_PRECISION_PACKAGE" = "1" ] || return 0
  checksum_file="$SENTINEL_PRECISION_PACKAGE_DIR/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$SENTINEL_PRECISION_PACKAGE_DIR" && for archive in *.zip; do sha256sum "$archive"; done > "$(basename "$checksum_file")")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$SENTINEL_PRECISION_PACKAGE_DIR" && for archive in *.zip; do shasum -a 256 "$archive"; done > "$(basename "$checksum_file")")
  else
    warn "Neither sha256sum nor shasum detected; skipping SHA256SUMS"
    return 0
  fi
  ok "Checksum file: $checksum_file"
}

mkdir -p "$SENTINEL_PRECISION_OUTPUT_DIR"
if [ "$SENTINEL_PRECISION_PACKAGE" = "1" ]; then mkdir -p "$SENTINEL_PRECISION_PACKAGE_DIR"; fi

old_ifs="$IFS"
IFS=','
read -r -a targets <<< "$SENTINEL_PRECISION_TARGETS"
IFS="$old_ifs"
[ "${#targets[@]}" -gt 0 ] || die "SENTINEL_PRECISION_TARGETS must not be empty"
for target in "${targets[@]}"; do
  target="${target//[[:space:]]/}"
  [ -n "$target" ] || continue
  build_target "$target"
done

if [ "$SENTINEL_PRECISION_PACKAGE" = "1" ]; then
  write_checksums
  info "Release packages generated in: $SENTINEL_PRECISION_PACKAGE_DIR"
fi
