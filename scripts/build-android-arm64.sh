#!/usr/bin/env bash
# Compatibility wrapper: arm64 is the default of build-android.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ANDROID_TARGET="${ANDROID_TARGET:-aarch64-linux-android}"
exec "$ROOT/scripts/build-android.sh" "$@"