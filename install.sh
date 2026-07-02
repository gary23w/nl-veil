#!/bin/sh
# nl-veil one-command installer — Linux / macOS
#   curl -fsSL https://raw.githubusercontent.com/gary23w/nl-veil/main/install.sh | sh
#
# What it does (and nothing more): put the repo at $VEIL_HOME (default ~/nl-veil), link the
# `veil` command into ~/.local/bin, and tell you the next two commands. Python 3.9+ is the one
# thing it won't install for you; everything else (Zig, the neuron-db memory engine, a local
# model) is bootstrapped by `deploy.py` itself on first use, with a prompt before each download.
set -e

REPO="https://github.com/gary23w/nl-veil"
DIR="${VEIL_HOME:-$HOME/nl-veil}"

command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || {
  echo "! nl-veil needs Python 3.9+ first: https://www.python.org/downloads/"
  exit 1
}

if [ -d "$DIR/.git" ]; then
  echo "- updating the existing install at $DIR"
  git -C "$DIR" pull --ff-only
elif command -v git >/dev/null 2>&1; then
  echo "- cloning nl-veil into $DIR"
  git clone --depth 1 "$REPO" "$DIR"
else
  echo "- git not found; downloading a tarball into $DIR"
  mkdir -p "$DIR"
  curl -fsSL "$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$DIR" --strip-components=1
fi

chmod +x "$DIR/veil" 2>/dev/null || true
BIN="$HOME/.local/bin"
mkdir -p "$BIN"
ln -sf "$DIR/veil" "$BIN/veil"

echo ""
echo "  installed -> $DIR"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "  put it on your PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"   (add to your shell rc)" ;;
esac
echo ""
echo "  next:"
echo "    veil configure      # once - local Ollama, or any OpenAI-compatible endpoint (BYOK)"
echo "    veil                # the veil shell"
