#!/usr/bin/env bash
#
# Launcher for the wgsl-analyzer WGSL/WESL language server.
#
# Claude Code spawns this as the LSP `command`. The language server speaks LSP
# over stdio, so stdout MUST carry only the protocol stream — every diagnostic
# message here goes to stderr, and we `exec` the real binary so its stdio is
# wired straight through.
#
# Resolution order for the server binary:
#   1. $WGSL_ANALYZER_PATH              (explicit override, if executable)
#   2. fresh cached download            (fetched within the TTL, for this version)
#   3. freshly downloaded prebuilt      (the primary path for a supported target)
#   4. stale cached download            (offline fallback: refresh failed)
#   5. bundled submodule release build  (analyzer/target/release, if built)
#   6. `wgsl-analyzer` on $PATH
#
# Tiers 2-3 mean users don't need Rust/cargo: the launcher fetches the platform
# binary that upstream publishes, mirroring wgsl-analyzer's own editor bootstrap.
# We track the rolling `nightly` release, so a cached copy is refreshed once it
# ages past the TTL (tier 2 vs 3); tier 4 keeps things working offline.
# `scripts/build-server.sh` stays as an offline build path (tier 5).
#
set -euo pipefail

# Upstream release channel for the prebuilt server. `nightly` is a rolling release
# upstream rebuilds from `main`; the vendored submodule tracks the same nightly tag.
# Override WA_VERSION with a dated tag (e.g. 2026-04-26) to pin to an immutable build.
WA_VERSION="${WA_VERSION:-nightly}"
WA_REPO="wgsl-analyzer/wgsl-analyzer"

# A rolling tag (nightly) is mutable, so a cached copy is reused only until it ages
# past this many hours, then re-fetched (falling back to the stale copy if offline).
# Dated tags are immutable and never expire regardless of this value.
WA_NIGHTLY_TTL_HOURS="${WA_NIGHTLY_TTL_HOURS:-24}"

# CLAUDE_PLUGIN_ROOT is set by Claude Code; fall back to this script's parent
# directory so the launcher also works when run directly.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
BUILT="${PLUGIN_ROOT}/analyzer/target/release/wgsl-analyzer"

# Downloaded binaries persist here across plugin updates when Claude Code sets
# CLAUDE_PLUGIN_DATA; otherwise fall back to the XDG cache.
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-${XDG_CACHE_HOME:-$HOME/.cache}/wgsl-analyzer-lsp}"

log() { printf 'wgsl-analyzer-lsp: %s\n' "$*" >&2; }

# Map the host to the upstream release target triple. Echoes the triple, or an
# empty string for platforms upstream does not publish (e.g. Intel macOS).
detect_target() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "${os}" in
    Linux)
      case "${arch}" in
        x86_64|amd64)
          if (ldd --version 2>&1 | grep -qi musl) || [ -f /etc/alpine-release ]; then
            printf 'x86_64-unknown-linux-musl'
          else
            printf 'x86_64-unknown-linux-gnu'
          fi ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-gnu' ;;
        armv7l|armv7)  printf 'arm-unknown-linux-gnueabihf' ;;
      esac ;;
    Darwin)
      case "${arch}" in
        arm64|aarch64) printf 'aarch64-apple-darwin' ;;
      esac ;;
  esac
}

cached_binary() { printf '%s/wgsl-analyzer-%s-%s' "${CACHE_DIR}" "${WA_VERSION}" "$1"; }

# True when WA_VERSION is a rolling tag whose binary changes under a fixed name.
is_moving_tag() { [ "${WA_VERSION}" = "nightly" ]; }

# True if $1 is an executable cached binary we can still trust: dated tags never
# expire; a moving tag is trusted only while younger than WA_NIGHTLY_TTL_HOURS.
# On any inability to read the clock/mtime we treat it as fresh, so a flaky `stat`
# never forces a needless re-download.
cache_fresh() {
  local file="$1" now mtime age ttl
  [ -x "${file}" ] || return 1
  is_moving_tag || return 0
  ttl=$(( WA_NIGHTLY_TTL_HOURS * 3600 ))
  now="$(date +%s 2>/dev/null)" || return 0
  mtime="$(stat -c %Y "${file}" 2>/dev/null || stat -f %m "${file}" 2>/dev/null)" || return 0
  [ -n "${mtime}" ] || return 0
  age=$(( now - mtime ))
  [ "${age}" -lt "${ttl}" ]
}

# Fetch + decompress the prebuilt binary into the cache. Echoes its path on
# success (stdout); all progress goes to stderr.
download_binary() {
  local target dest url gz
  target="$(detect_target)"
  if [ -z "${target}" ]; then
    log "no prebuilt binary for $(uname -s)/$(uname -m) — build it with scripts/build-server.sh or set \$WGSL_ANALYZER_PATH."
    return 1
  fi
  dest="$(cached_binary "${target}")"
  url="https://github.com/${WA_REPO}/releases/download/${WA_VERSION}/wgsl-analyzer-${target}.gz"
  gz="${dest}.download.gz"
  mkdir -p "${CACHE_DIR}"
  log "fetching wgsl-analyzer ${WA_VERSION} (${target}) from upstream release..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${gz}" || { rm -f "${gz}"; log "download failed: ${url}"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${gz}" "${url}" || { rm -f "${gz}"; log "download failed: ${url}"; return 1; }
  else
    log "need curl or wget to download the server binary."
    return 1
  fi
  gunzip -f "${gz}" || { rm -f "${gz}" "${dest}.download"; log "failed to decompress ${gz}"; return 1; }
  chmod +x "${dest}.download"
  mv -f "${dest}.download" "${dest}"
  touch "${dest}" 2>/dev/null || true # stamp fetch time so the TTL measures from now
  printf '%s' "${dest}"
}

resolve_server() {
  local target cached bin
  # 1. Explicit override always wins.
  if [ -n "${WGSL_ANALYZER_PATH:-}" ] && [ -x "${WGSL_ANALYZER_PATH}" ]; then
    printf '%s' "${WGSL_ANALYZER_PATH}"; return 0
  fi
  target="$(detect_target)"
  if [ -n "${target}" ]; then
    cached="$(cached_binary "${target}")"
    # 2. Reuse a cached copy while it is still fresh (immediate, no network).
    if cache_fresh "${cached}"; then printf '%s' "${cached}"; return 0; fi
    # 3. Otherwise fetch the latest (first run, or the nightly TTL has expired).
    if bin="$(download_binary)"; then printf '%s' "${bin}"; return 0; fi
    # 4. Refresh failed (offline/rate-limited): fall back to the stale cache.
    if [ -x "${cached}" ]; then
      log "refresh failed — using stale cached ${WA_VERSION} binary"
      printf '%s' "${cached}"; return 0
    fi
  fi
  # 5-6. No prebuilt for this platform, or nothing cached: locally-built, then PATH.
  if [ -x "${BUILT}" ]; then printf '%s' "${BUILT}"; return 0; fi
  if command -v wgsl-analyzer >/dev/null 2>&1; then command -v wgsl-analyzer; return 0; fi
  # Unsupported target with no cache still gets one download attempt for its error.
  if bin="$(download_binary)"; then printf '%s' "${bin}"; return 0; fi
  return 1
}

if ! SERVER="$(resolve_server)"; then
  {
    echo "wgsl-analyzer: could not obtain the language server binary."
    echo "Any of the following fixes it:"
    echo "  - ensure network access so the prebuilt binary can be downloaded, or"
    echo "  - build it locally:  \"${PLUGIN_ROOT}/scripts/build-server.sh\", or"
    echo "  - point \$WGSL_ANALYZER_PATH at an existing wgsl-analyzer binary."
  } >&2
  exit 127
fi

exec "${SERVER}" "$@"
