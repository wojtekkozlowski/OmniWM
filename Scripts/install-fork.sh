#!/bin/zsh
# Installs the prebuilt OmniWM Dev app from this fork's latest GitHub release.
# The release copy of OmniWM stays installed; switch back by quitting Dev and opening it.
set -euo pipefail

REPO="wojtekkozlowski/OmniWM"
ASSET="OmniWM-Dev-arm64.zip"
BUNDLE_ID="com.barut.OmniWM.dev"
APP="$HOME/Applications/OmniWM Dev.app"
BASE_URL="https://github.com/$REPO/releases/latest/download"

fail() {
  echo "install-fork: $*" >&2
  exit 1
}

[ "$(uname -m)" = "arm64" ] || fail "this build is for Apple Silicon Macs only"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading $ASSET..."
curl -fsSL "$BASE_URL/$ASSET" -o "$WORK/$ASSET"
curl -fsSL "$BASE_URL/$ASSET.sha256" -o "$WORK/$ASSET.sha256"

expected="$(awk '{print $1}' "$WORK/$ASSET.sha256")"
actual="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
[ "$expected" = "$actual" ] || fail "checksum mismatch: expected $expected, got $actual"

ditto -x -k "$WORK/$ASSET" "$WORK/unpacked"
[ -d "$WORK/unpacked/OmniWM Dev.app" ] || fail "the archive does not contain OmniWM Dev.app"

echo "Quitting any running OmniWM..."
osascript -e 'tell application id "com.barut.OmniWM" to quit' >/dev/null 2>&1 || true
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..40}; do
  pgrep -x OmniWM >/dev/null || break
  sleep 0.25
done
pgrep -x OmniWM >/dev/null && fail "OmniWM is still running; quit it and run this again"

mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$WORK/unpacked/OmniWM Dev.app" "$APP"

CONFIG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
if [ ! -e "$CONFIG_BASE/omniwm-dev" ] && [ -f "$CONFIG_BASE/omniwm/settings.toml" ]; then
  mkdir -p "$CONFIG_BASE/omniwm-dev"
  cp -L "$CONFIG_BASE/omniwm/settings.toml" "$CONFIG_BASE/omniwm-dev/settings.toml"
  echo "Copied your OmniWM settings to $CONFIG_BASE/omniwm-dev/settings.toml"
fi

defaults write "$BUNDLE_ID" OmniWMExperimentScrollOverlay -bool true

open "$APP"
echo "Installed $APP"
echo "Grant it Accessibility, Input Monitoring and Screen Recording when asked."
