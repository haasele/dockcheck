#!/usr/bin/env bash
# dockcheck installer (fork: haasele/dockcheck)
#
# Local:   ./install.sh                      (run inside a clone of the repo)
# Remote:  curl -fsSL https://raw.githubusercontent.com/haasele/dockcheck/main/install.sh | bash
#
# Installs dockcheck.sh + addons + notify templates to INSTALL_DIR and symlinks
# dockcheck.sh into BIN_DIR. An existing dockcheck.config / notify.sh is never touched.
#
# Defaults depend on who runs it:
#   as root / via sudo  -> system-wide: /opt/dockcheck  + symlink in /usr/local/bin  (available to everyone)
#   as normal user      -> per user:    ~/.local/share/dockcheck + symlink in ~/.local/bin
#
# Overrides (environment):
#   INSTALL_DIR   override the install directory
#   BIN_DIR       override the symlink directory
#   REPO          default: haasele/dockcheck
#   BRANCH        default: main

set -euo pipefail

REPO="${REPO:-haasele/dockcheck}"
BRANCH="${BRANCH:-main}"
if [[ "$(id -u)" -eq 0 ]]; then
  SCOPE="system-wide"
  INSTALL_DIR="${INSTALL_DIR:-/opt/dockcheck}"
  BIN_DIR="${BIN_DIR:-/usr/local/bin}"
else
  SCOPE="current user only"
  INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share/dockcheck}"
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
fi
TARBALL_URL="${DOCKCHECK_TARBALL:-https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz}"

say()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v bash >/dev/null && command -v tar >/dev/null || die "bash and tar are required."
command -v docker >/dev/null || warn "docker not found in PATH (needed to actually run dockcheck)."

# --- 1. find the source: local repo first, otherwise download -------------------------------
SRC=""
# When piped through 'curl | bash', BASH_SOURCE is empty -> skip the local check.
SELF_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "$SELF_DIR" && -f "$SELF_DIR/dockcheck.sh" && -d "$SELF_DIR/addons" ]]; then
  SRC="$SELF_DIR"
  say "Using local repository: $SRC"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  say "Not inside a repo - downloading $TARBALL_URL"
  if command -v curl >/dev/null; then
    curl -fsSL --retry 3 --connect-timeout 10 "$TARBALL_URL" -o "$TMP/src.tar.gz" || die "Download failed."
  elif command -v wget >/dev/null; then
    wget -q -t 3 -T 15 "$TARBALL_URL" -O "$TMP/src.tar.gz" || die "Download failed."
  else
    die "curl or wget is required for the remote install."
  fi
  mkdir -p "$TMP/src"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP/src" --strip-components=1 || die "Could not extract the archive."
  SRC="$TMP/src"
fi

[[ -f "$SRC/dockcheck.sh" ]]               || die "dockcheck.sh not found in source."
[[ -f "$SRC/addons/tagbump/tagbump.sh" ]]  || die "addons/tagbump/tagbump.sh not found in source."

# --- 2. install -----------------------------------------------------------------------------
say "Install scope: $SCOPE"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" || die "Cannot create $INSTALL_DIR / $BIN_DIR - for a system-wide install run with sudo."

install -m 0755 "$SRC/dockcheck.sh" "$INSTALL_DIR/dockcheck.sh"

# addons + notify templates: replaced as a whole so removed files do not linger
for d in addons notify_templates; do
  [[ -d "$SRC/$d" ]] || continue
  rm -rf "${INSTALL_DIR:?}/$d"
  cp -R "$SRC/$d" "$INSTALL_DIR/$d"
done

# reference config - never the active one
[[ -f "$SRC/default.config" ]] && cp "$SRC/default.config" "$INSTALL_DIR/default.config"

# symlink: dockcheck.sh resolves it with readlink -f and finds addons/ next to the real file
ln -sf "$INSTALL_DIR/dockcheck.sh" "$BIN_DIR/dockcheck.sh"

say "Installed to $INSTALL_DIR"
say "Linked      $BIN_DIR/dockcheck.sh"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not in your PATH. Add it, e.g.: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.profile" ;;
esac

if [[ ! -f "$INSTALL_DIR/dockcheck.config" ]]; then
  say "Optional: cp $INSTALL_DIR/default.config $INSTALL_DIR/dockcheck.config   (then edit)"
fi
if [[ "$(id -u)" -eq 0 ]]; then
  say "Note: docker login and 'regctl registry set' settings are per user - set them as root too."
else
  say "For a system-wide install (usable with sudo/cron as root): re-run with sudo."
fi

cat <<MSG

Done. Try:
  dockcheck.sh -n            # check only
  dockcheck.sh -n -T 2       # also look for newer versioned tags (tag bump addon)
Update later by running this installer again.
MSG
