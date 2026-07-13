#!/usr/bin/env bash
# Cross-compile obscura + obscura-worker for Android without permanently
# modifying the project tree. All source patches are applied for the duration
# of the build and restored on exit.
#
# Usage:
#   ANDROID_NDK_HOME=/path/to/ndk ./scripts/build-android.sh
#   ANDROID_NDK_HOME=... ANDROID_TARGET=x86_64-linux-android ./scripts/build-android.sh
#
# Env:
#   ANDROID_NDK_HOME / ANDROID_NDK_ROOT  required
#   ANDROID_TARGET                      rust triple (default: aarch64-linux-android)
#   ANDROID_API_LEVEL                   NDK API level (default: 28)
#   GN / NINJA                          host tools for rusty_v8 from-source
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

API_LEVEL="${ANDROID_API_LEVEL:-28}"
TARGET="${ANDROID_TARGET:-aarch64-linux-android}"
NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"

case "$TARGET" in
  aarch64-linux-android)
    ABI_NAME="arm64-v8a"
    CLANG_PREFIX="aarch64-linux-android"
    ;;
  armv7-linux-androideabi)
    ABI_NAME="armeabi-v7a"
    CLANG_PREFIX="armv7a-linux-androideabi"
    ;;
  x86_64-linux-android)
    ABI_NAME="x86_64"
    CLANG_PREFIX="x86_64-linux-android"
    ;;
  i686-linux-android)
    ABI_NAME="x86"
    CLANG_PREFIX="i686-linux-android"
    ;;
  *)
    echo "Unsupported ANDROID_TARGET=$TARGET" >&2
    echo "Supported: aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android" >&2
    exit 1
    ;;
esac

if [[ -z "$NDK_HOME" ]]; then
  echo "ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) must point at an Android NDK" >&2
  exit 1
fi
if [[ ! -d "$NDK_HOME" ]]; then
  echo "NDK not found at $NDK_HOME" >&2
  exit 1
fi

PREBUILT="$(echo "$NDK_HOME"/toolchains/llvm/prebuilt/*)"
if [[ ! -d "$PREBUILT" ]]; then
  echo "NDK prebuilt toolchain missing under $NDK_HOME/toolchains/llvm/prebuilt" >&2
  exit 1
fi

CLANG="$PREBUILT/bin/${CLANG_PREFIX}${API_LEVEL}-clang"
CLANGXX="$PREBUILT/bin/${CLANG_PREFIX}${API_LEVEL}-clang++"
AR_BIN="$PREBUILT/bin/llvm-ar"
if [[ ! -x "$CLANG" ]]; then
  echo "clang not found: $CLANG (check ANDROID_API_LEVEL=$API_LEVEL)" >&2
  exit 1
fi

TARGET_ENV="${TARGET//-/_}"
export PATH="$PREBUILT/bin:${PATH}"
export ANDROID_NDK_HOME="$NDK_HOME"
export ANDROID_NDK_ROOT="$NDK_HOME"
export "CC_${TARGET_ENV}=$CLANG"
export "CXX_${TARGET_ENV}=$CLANGXX"
export "AR_${TARGET_ENV}=$AR_BIN"
export "CARGO_TARGET_$(echo "$TARGET" | tr 'a-z-' 'A-Z_')_LINKER=$CLANG"

export GN="${GN:-$(command -v gn || true)}"
export NINJA="${NINJA:-$(command -v ninja || true)}"
if [[ -z "$GN" || -z "$NINJA" ]]; then
  echo "gn and ninja must be on PATH (or set GN=/path/to/gn NINJA=/path/to/ninja)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Temporary project patches: backup originals and restore on any exit.
# ---------------------------------------------------------------------------
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/obscura-android-backup.XXXXXX")"
PATCHED_FILES=()

backup_file() {
  local f="$1"
  mkdir -p "$BACKUP_DIR/$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR/$f"
  PATCHED_FILES+=("$f")
}

restore_patches() {
  local f
  for f in "${PATCHED_FILES[@]:-}"; do
    if [[ -f "$BACKUP_DIR/$f" ]]; then
      cp -a "$BACKUP_DIR/$f" "$f"
    fi
  done
  rm -rf "$BACKUP_DIR"
}
trap restore_patches EXIT

rustup target add "$TARGET" >/dev/null

# V8 startup snapshots are architecture-specific. Cross-builds must not bake a
# host snapshot into the Android binary (see release.yml / issue #290). Patch
# obscura-js only for this build, then restore. Register files before patching
# so the EXIT trap restores even if the patch step fails mid-way.
for f in crates/obscura-js/build.rs crates/obscura-js/src/runtime.rs; do
  backup_file "$f"
done

python3 - "$BACKUP_DIR" <<'PY'
import shutil
import sys
from pathlib import Path

backup_root = Path(sys.argv[1])
build_rs = Path("crates/obscura-js/build.rs")
runtime_rs = Path("crates/obscura-js/src/runtime.rs")
if not build_rs.exists() or not runtime_rs.exists():
    raise SystemExit("obscura-js sources not found — wrong checkout?")

for path in (build_rs, runtime_rs):
    dest = backup_root / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)

# Record for the shell trap (also backed up here for safety).
print("backed-up crates/obscura-js/build.rs")
print("backed-up crates/obscura-js/src/runtime.rs")

build_rs.write_text(
    """use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=js/bootstrap.js");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rustc-check-cfg=cfg(obscura_runtime_bootstrap)");

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let snapshot_path = out_dir.join("OBSCURA_SNAPSHOT.bin");

    let target = std::env::var("TARGET").unwrap_or_default();
    let host = std::env::var("HOST").unwrap_or_default();
    // V8 startup snapshots are architecture-specific. Cross-builds skip the
    // host snapshot and execute bootstrap.js at runtime instead.
    let cross_compiling = !target.is_empty() && !host.is_empty() && target != host;

    if cross_compiling {
        println!("cargo:warning=cross-compiling {target} on {host}: skipping V8 snapshot, using runtime bootstrap");
        println!("cargo:rustc-cfg=obscura_runtime_bootstrap");
        std::fs::write(&snapshot_path, b"").expect("Failed to write placeholder snapshot");
        println!(
            "cargo:rustc-env=OBSCURA_SNAPSHOT_PATH={}",
            snapshot_path.display()
        );
        return;
    }

    let bootstrap_js = include_str!("js/bootstrap.js");

    let output = deno_core::snapshot::create_snapshot(
        deno_core::snapshot::CreateSnapshotOptions {
            cargo_manifest_dir: env!("CARGO_MANIFEST_DIR"),
            startup_snapshot: None,
            skip_op_registration: true,
            extensions: vec![],
            extension_transpiler: None,
            with_runtime_cb: Some(Box::new(move |runtime| {
                runtime
                    .execute_script("<obscura:bootstrap>", bootstrap_js.to_string())
                    .expect("bootstrap.js should not fail during snapshot creation");
            })),
        },
        None,
    )
    .expect("Failed to create V8 snapshot");

    std::fs::write(&snapshot_path, &*output.output).expect("Failed to write snapshot");
    println!(
        "cargo:rustc-env=OBSCURA_SNAPSHOT_PATH={}",
        snapshot_path.display()
    );

    for file in &output.files_loaded_during_snapshot {
        println!("cargo:rerun-if-changed={}", file.display());
    }
}
"""
)

rt = runtime_rs.read_text()
if "obscura_runtime_bootstrap" in rt:
    print(f"{runtime_rs} already has runtime bootstrap support — leave as-is")
else:
    old = "static SNAPSHOT: &[u8] = include_bytes!(env!(\"OBSCURA_SNAPSHOT_PATH\"));\n"
    new = (
        "#[cfg(not(obscura_runtime_bootstrap))]\n"
        "static SNAPSHOT: &[u8] = include_bytes!(env!(\"OBSCURA_SNAPSHOT_PATH\"));\n"
        "\n"
        "#[cfg(obscura_runtime_bootstrap)]\n"
        "const BOOTSTRAP_JS: &str = include_str!(\"../js/bootstrap.js\");\n"
    )
    if old not in rt:
        raise SystemExit(f"could not find SNAPSHOT binding in {runtime_rs}")
    rt = rt.replace(old, new, 1)

    old2 = """        let mut runtime = JsRuntime::new(RuntimeOptions {
            extensions: vec![build_extension()],
            module_loader: Some(module_loader),
            startup_snapshot: Some(SNAPSHOT),
            ..Default::default()
        });
"""
    new2 = """        #[cfg(not(obscura_runtime_bootstrap))]
        let mut runtime = JsRuntime::new(RuntimeOptions {
            extensions: vec![build_extension()],
            module_loader: Some(module_loader),
            startup_snapshot: Some(SNAPSHOT),
            ..Default::default()
        });

        #[cfg(obscura_runtime_bootstrap)]
        let mut runtime = {
            let mut rt = JsRuntime::new(RuntimeOptions {
                extensions: vec![build_extension()],
                module_loader: Some(module_loader),
                startup_snapshot: None,
                ..Default::default()
            });
            rt.execute_script("<obscura:bootstrap>", BOOTSTRAP_JS.to_string())
                .expect("bootstrap.js should not fail at runtime");
            rt
        };
"""
    if old2 not in rt:
        raise SystemExit(
            f"could not find JsRuntime::new block in {runtime_rs}\n"
            "upstream layout may have changed — update scripts/build-android.sh"
        )
    runtime_rs.write_text(rt.replace(old2, new2, 1))
    print(f"patched {runtime_rs} for runtime bootstrap (temporary)")

print(f"patched {build_rs} for cross-compile snapshot skip (temporary)")
PY

# Fetch crates so we can patch rusty_v8 before the real compile.
# Registry patches live outside the project tree and are reapplied idempotently.
cargo fetch --target "$TARGET"

V8_SRC="$(find "${CARGO_HOME:-$HOME/.cargo}/registry/src" -maxdepth 2 -type d -name 'v8-137.*' | sort -V | tail -1)"
if [[ -z "$V8_SRC" || ! -f "$V8_SRC/build.rs" ]]; then
  # Broader match if the major version moves.
  V8_SRC="$(find "${CARGO_HOME:-$HOME/.cargo}/registry/src" -maxdepth 2 -type d -name 'v8-*' | sort -V | tail -1)"
fi
if [[ -z "$V8_SRC" || ! -f "$V8_SRC/build.rs" ]]; then
  echo "Could not locate rusty_v8 sources under cargo registry" >&2
  exit 1
fi
echo "Patching rusty_v8 at $V8_SRC"

python3 - "$V8_SRC" <<'PY'
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
build_rs = root / "build.rs"
text = build_rs.read_text()
needle = """  // Build from source
  if env_bool("V8_FROM_SOURCE") {
"""
repl = """  // Build from source. Android has no prebuilt librusty_v8 archives, so always
  // compile from source for android targets even when V8_FROM_SOURCE is unset
  // (keeps the host build-script on the fast prebuilt path).
  let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
  if env_bool("V8_FROM_SOURCE") || target_os == "android" {
"""
if 'target_os == "android"' not in text or "Android has no prebuilt" not in text:
    if needle not in text:
        # Already-patched or layout changed — try a looser match.
        if "V8_FROM_SOURCE" not in text:
            raise SystemExit(f"unexpected build.rs layout in {build_rs}")
        print("warning: could not apply android-from-source patch (layout changed); relying on V8_FROM_SOURCE")
    else:
        build_rs.write_text(text.replace(needle, repl, 1))
        print("patched rusty_v8 build.rs for android-from-source")
else:
    print("rusty_v8 build.rs already patched")

android_gn = root / "build/android"
if android_gn.exists():
    for gn in android_gn.rglob("*.gn"):
        for m in re.finditer(r'pydeps_file\s*=\s*"([^"]+)"', gn.read_text()):
            rel = m.group(1)
            for path in (gn.parent / rel, root / "build/android" / rel):
                if not path.exists() and str(path).startswith(str(root)):
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("# stub for rusty_v8 android cross build\n")
                    print(f"stubbed {path.relative_to(root)}")

ndk_link = root / "third_party/android_toolchain/ndk"
ndk_link.parent.mkdir(parents=True, exist_ok=True)
src = root / "third_party/android_ndk"
host_ndk = Path(os.environ["ANDROID_NDK_HOME"])
target = src if (src / "toolchains/llvm/prebuilt").exists() else host_ndk
if ndk_link.is_symlink() or ndk_link.is_file():
    ndk_link.unlink()
if not ndk_link.exists():
    ndk_link.symlink_to(target)
    print(f"linked android_toolchain/ndk -> {target}")
else:
    print(f"using existing {ndk_link}")
PY

# __clear_cache is referenced by V8 arm64/arm. Provide a tiny no-op shim so the
# final link succeeds with the NDK clang driver.
SHIM_DIR="${CARGO_TARGET_DIR:-$ROOT/target}/android-shim/${TARGET}"
mkdir -p "$SHIM_DIR"
case "$TARGET" in
  aarch64-linux-android)
    cat > "$SHIM_DIR/clear_cache_shim.S" <<'ASM'
    .text
    .global __clear_cache
    .type __clear_cache, %function
__clear_cache:
    ret
ASM
    "$CLANG" -c "$SHIM_DIR/clear_cache_shim.S" -o "$SHIM_DIR/clear_cache_shim.o"
    export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=$SHIM_DIR/clear_cache_shim.o"
    ;;
  armv7-linux-androideabi)
    cat > "$SHIM_DIR/clear_cache_shim.S" <<'ASM'
    .text
    .global __clear_cache
    .type __clear_cache, %function
__clear_cache:
    bx lr
ASM
    "$CLANG" -c "$SHIM_DIR/clear_cache_shim.S" -o "$SHIM_DIR/clear_cache_shim.o"
    export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=$SHIM_DIR/clear_cache_shim.o"
    ;;
esac

unset V8_FROM_SOURCE || true

echo "Building $TARGET ($ABI_NAME, API $API_LEVEL) ..."
cargo build --release --target "$TARGET" --bin obscura --bin obscura-worker --features stealth

OUT="${CARGO_TARGET_DIR:-$ROOT/target}/${TARGET}/release"
echo "Built ($ABI_NAME):"
ls -lh "$OUT/obscura" "$OUT/obscura-worker"
file "$OUT/obscura" "$OUT/obscura-worker"

# trap restores project sources on exit
