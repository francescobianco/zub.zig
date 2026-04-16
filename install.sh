#!/usr/bin/env bash
set -euo pipefail

ZUB_BOOTSTRAP_ZIG_VERSION="${ZUB_BOOTSTRAP_ZIG_VERSION:-0.15.1}"
ZUB_SOURCE_URL="${ZUB_SOURCE_URL:-https://github.com/francescobianco/zub.zig/archive/refs/heads/main.tar.gz}"
ZUB_PREFIX="${ZUB_PREFIX:-$HOME/.local}"
ZUB_BIN_DIR="$ZUB_PREFIX/bin"

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ensure_cmd() {
    if ! need_cmd "$1"; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

ensure_cmd curl
ensure_cmd tar

mkdir -p "$ZUB_BIN_DIR"

if ! need_cmd zvm && [ ! -x "$HOME/.zvm/self/zvm" ]; then
    echo "installing zvm"
    curl -fsSL https://www.zvm.app/install.sh | bash
fi

export ZVM_INSTALL="${ZVM_INSTALL:-$HOME/.zvm/self}"
export PATH="$PATH:$HOME/.zvm/bin:$ZVM_INSTALL"

if ! need_cmd zvm; then
    echo "zvm was not found after installation" >&2
    exit 1
fi

echo "installing Zig $ZUB_BOOTSTRAP_ZIG_VERSION via zvm"
zvm install "$ZUB_BOOTSTRAP_ZIG_VERSION"

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

echo "downloading zub sources"
curl -fsSL "$ZUB_SOURCE_URL" -o "$tmpdir/zub.tar.gz"
tar -xzf "$tmpdir/zub.tar.gz" -C "$tmpdir"

srcdir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "$srcdir" ]; then
    echo "unable to locate extracted zub sources" >&2
    exit 1
fi

echo "building zub"
(
    cd "$srcdir"
    zvm run "$ZUB_BOOTSTRAP_ZIG_VERSION" build -Doptimize=ReleaseSafe --prefix "$ZUB_PREFIX"
)

if [ ! -x "$ZUB_BIN_DIR/zub" ]; then
    echo "zub binary was not installed correctly" >&2
    exit 1
fi

echo
echo "zub installed in $ZUB_BIN_DIR/zub"
echo "ensure $ZUB_BIN_DIR is in PATH"
echo "example: zub install pbm"
