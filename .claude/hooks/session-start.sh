#!/bin/bash
# Installs a Swift Linux toolchain in Claude Code cloud sessions so NocturneSyncCore can be built,
# formatted, and tested there. No-op outside cloud sessions and when the toolchain already exists.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

SWIFT_VERSION="6.1.2"
SWIFT_HOME="/opt/swift"

if [ ! -x "$SWIFT_HOME/usr/bin/swift" ]; then
  case "$(uname -m)" in
    x86_64) platform="ubuntu2404"; suffix="ubuntu24.04" ;;
    aarch64) platform="ubuntu2404-aarch64"; suffix="ubuntu24.04-aarch64" ;;
    *) echo "session-start: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  url="https://download.swift.org/swift-${SWIFT_VERSION}-release/${platform}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-${suffix}.tar.gz"
  tmp="$(mktemp -d)"
  echo "session-start: downloading Swift ${SWIFT_VERSION}"
  curl -sSfL "$url" -o "$tmp/swift.tar.gz"
  mkdir -p "$SWIFT_HOME"
  tar -xzf "$tmp/swift.tar.gz" -C "$SWIFT_HOME" --strip-components=1
  rm -rf "$tmp"
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"${SWIFT_HOME}/usr/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

"$SWIFT_HOME/usr/bin/swift" --version
