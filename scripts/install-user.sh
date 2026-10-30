#!/usr/bin/env bash
# Installs Inkpane for the current user. The .desktop file is required: the desktop
# portal only grants global shortcuts to apps it can match to an installed launcher.
#   scripts/install-user.sh              install
#   scripts/install-user.sh --autostart  install and start Inkpane at login
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_ID="org.vyrnexis.Inkpane"
BIN_SRC="$ROOT_DIR/bin/inkpane"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"

if [ ! -x "$BIN_SRC" ] || [ ! -x "$ROOT_DIR/bin/inkpane-mcp" ]; then
  echo "Missing $BIN_SRC - run 'nimble Release' first." >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR"
install -m 755 "$BIN_SRC" "$BIN_DIR/inkpane"
install -m 755 "$ROOT_DIR/bin/inkpane-mcp" "$BIN_DIR/inkpane-mcp"   # for AI clients
install -m 644 "$ROOT_DIR"/data/icons/hicolor/scalable/apps/*.svg "$ICON_DIR/"
sed -e "s|@APP_BIN@|$BIN_DIR/inkpane|g" "$ROOT_DIR/data/$APP_ID.desktop" > "$APP_DIR/$APP_ID.desktop"
chmod 644 "$APP_DIR/$APP_ID.desktop"

if [ "${1:-}" = "--autostart" ]; then
  mkdir -p "$AUTOSTART_DIR"
  cp "$APP_DIR/$APP_ID.desktop" "$AUTOSTART_DIR/$APP_ID.desktop"
  echo "Inkpane will start at login."
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
echo "Installed Inkpane to $BIN_DIR/inkpane"
