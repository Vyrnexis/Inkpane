#!/usr/bin/env bash
set -eu
APP_ID="org.vyrnexis.Inkpane"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
"$BIN_DIR/inkpane" --quit >/dev/null 2>&1 || true
rm -f "$BIN_DIR/inkpane" "$BIN_DIR/inkpane-mcp"
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$APP_ID.desktop"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/$APP_ID.desktop"
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}"/icons/hicolor/scalable/apps/$APP_ID*.svg
echo "Removed Inkpane"
