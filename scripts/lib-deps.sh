# shellcheck shell=sh
# ============================================================================
# lib-deps.sh — POSIX-sh dependency bootstrap, shared by the release scripts.
#
# Source it, then call:
#   dep_zig            -> prints a usable zig path (downloads the pinned zig if absent)
#   dep_cargo          -> ensures cargo is on PATH (installs rustup if absent)
#   dep_cc             -> ensures a C compiler is present (neuron's sqlite build)
#   dep_desk_libs      -> ensures raylib's GL/X11/wayland dev libs (Linux desktop link)
#
# All are best-effort and idempotent. Honor ASSUME_YES=1 for unattended runs.
# Uses the same pinned Zig version and package set as deploy.py / the CI.
# ============================================================================

DEP_ZIG_VERSION="${DEP_ZIG_VERSION:-0.16.0}"
DEP_ROOT="${DEP_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"

_dep_say() { printf '\033[1;31m▌\033[0m %s\n' "$*" >&2; }
_dep_have() { command -v "$1" >/dev/null 2>&1; }
_dep_yes() {  # _dep_yes "question" -> 0 to proceed
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || return 0                       # non-interactive (CI/pipe) → proceed
  printf '%s [Y/n] ' "$1" >&2; read -r a || return 0
  case "$a" in n*|N*) return 1 ;; *) return 0 ;; esac
}

# ---- sudo shim: use sudo only when needed and available -------------------
_dep_sudo() {
  if [ "$(id -u 2>/dev/null || echo 0)" = 0 ]; then "$@"; return $?; fi
  if _dep_have sudo; then sudo "$@"; return $?; fi
  _dep_say "need root to run: $*  (no sudo found — run as root or install manually)"
  return 1
}

# ---- OS package install: detect the manager, map to its names -------------
# _dep_pkg_install <apt names> | <dnf names> | <pacman names>   (pipe-separated groups)
_dep_pkg_install() {
  _apt="$1"; _dnf="$2"; _pac="$3"
  if _dep_have apt-get; then _dep_sudo apt-get update -qq && _dep_sudo apt-get install -y $_apt
  elif _dep_have dnf;    then _dep_sudo dnf install -y $_dnf
  elif _dep_have yum;    then _dep_sudo yum install -y $_dnf
  elif _dep_have pacman; then _dep_sudo pacman -Sy --needed --noconfirm $_pac
  elif _dep_have zypper; then _dep_sudo zypper --non-interactive install $_dnf
  elif _dep_have apk;    then _dep_sudo apk add $_apt
  elif _dep_have brew;   then brew install $_apt
  else _dep_say "no supported package manager (apt/dnf/pacman/zypper/apk/brew) — install manually: $_apt"; return 1
  fi
}

# ---- zig (download the pinned release into $DEP_ROOT/.zig if not on PATH) --
dep_zig() {
  if [ -n "${ZIG:-}" ] && [ -x "$ZIG" ]; then printf '%s\n' "$ZIG"; return 0; fi
  if _dep_have zig; then command -v zig; return 0; fi
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) _os=windows; _ext=zip ;; Darwin*) _os=macos; _ext=tar.xz ;; *) _os=linux; _ext=tar.xz ;; esac
  case "$(uname -m)" in arm64|aarch64) _arch=aarch64 ;; *) _arch=x86_64 ;; esac
  _zexe="zig"; [ "$_os" = windows ] && _zexe="zig.exe"
  _local="$DEP_ROOT/.zig/$_zexe"
  [ -x "$_local" ] && { printf '%s\n' "$_local"; return 0; }
  _dep_yes "download Zig $DEP_ZIG_VERSION into ./.zig now (~50 MB)?" || { _dep_say "install Zig from https://ziglang.org/download/ and re-run"; return 1; }
  _base="zig-$_arch-$_os-$DEP_ZIG_VERSION"
  _url="https://ziglang.org/download/$DEP_ZIG_VERSION/$_base.$_ext"
  _tmp="$DEP_ROOT/.zig-dl"; rm -rf "$_tmp"; mkdir -p "$_tmp"
  _dep_say "fetching Zig $DEP_ZIG_VERSION"
  if _dep_have curl; then curl -fsSL "$_url" -o "$_tmp/z.$_ext"
  elif _dep_have wget; then wget -qO "$_tmp/z.$_ext" "$_url"
  else _dep_say "need curl or wget to download zig"; return 1; fi
  ( cd "$_tmp" && case "$_ext" in zip) unzip -q "z.$_ext" ;; *) tar xf "z.$_ext" ;; esac )
  rm -rf "$DEP_ROOT/.zig"
  mv "$_tmp/$_base" "$DEP_ROOT/.zig"
  rm -rf "$_tmp"
  chmod +x "$_local" 2>/dev/null || true
  [ -x "$_local" ] && { printf '%s\n' "$_local"; return 0; }
  _dep_say "zig download failed — install from https://ziglang.org/download/"; return 1
}

# ---- rust/cargo (rustup, minimal profile) ---------------------------------
dep_cargo() {
  _dep_have cargo && return 0
  [ -x "$HOME/.cargo/bin/cargo" ] && { PATH="$HOME/.cargo/bin:$PATH"; export PATH; _dep_have cargo && return 0; }
  _dep_yes "the neuron memory engine needs Rust — install it now via rustup?" || { _dep_say "install from https://rustup.rs and re-run"; return 1; }
  if _dep_have curl; then curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  elif _dep_have wget; then wget -qO- https://sh.rustup.rs | sh -s -- -y --profile minimal
  else _dep_say "need curl or wget to install rustup"; return 1; fi
  PATH="$HOME/.cargo/bin:$PATH"; export PATH
  _dep_have cargo && return 0
  _dep_say "cargo still not on PATH — open a new shell (rustup changed PATH) and re-run"; return 1
}

# ---- a C compiler (cargo's sqlite build needs one) ------------------------
dep_cc() {
  { _dep_have cc || _dep_have gcc || _dep_have clang; } && return 0
  case "$(uname -s)" in
    Darwin*) _dep_yes "install the Xcode command-line tools (C compiler)?" && xcode-select --install 2>/dev/null || true ;;
    *) _dep_yes "install a C compiler (needed to build the memory engine)?" && _dep_pkg_install "build-essential" "gcc" "base-devel" || true ;;
  esac
  { _dep_have cc || _dep_have gcc || _dep_have clang; } && return 0
  _dep_say "no C compiler yet — install one (macOS: xcode-select --install; Debian: build-essential; Fedora: gcc)"; return 1
}

# ---- raylib GL/X11/wayland dev libs (Linux desktop link) ------------------
dep_desk_libs() {
  [ "$(uname -s)" = Linux ] || return 0   # only Linux needs these; win/mac raylib is self-contained
  _dep_yes "install raylib's GL/X11/wayland dev libraries (needed to build the desktop)?" || return 1
  _dep_pkg_install \
    "libgl1-mesa-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libwayland-dev libxkbcommon-dev" \
    "mesa-libGL-devel libX11-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel wayland-devel libxkbcommon-devel" \
    "mesa libx11 libxrandr libxinerama libxcursor libxi wayland libxkbcommon"
}
