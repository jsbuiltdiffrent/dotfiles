#!/usr/bin/env bash
#
# New-distro bootstrap script.
# Run this right after a fresh Debian/Ubuntu install to:
#   1. Update the system
#   2. Remove Firefox
#   3. Install Zen Browser
#   4. Restore Zen preferences/config from a dotfiles repo (optional)
#   5. Install Mullvad VPN
#
# --- Zen config restore setup ---
# To enable step 4, set DOTFILES_REPO below to a git repo URL containing:
#   zen/user.js          -> about:config overrides, copied into your Zen profile
#   zen/chrome/           -> userChrome.css / userContent.css, copied into <profile>/chrome/
#   zen/extensions.txt    -> one AMO extension slug/ID per line, opened for manual install
# Until DOTFILES_REPO is set, this step is skipped with a warning.

set -euo pipefail

DOTFILES_REPO="https://github.com/jsbuiltdiffrent/zen-browser-settings.git"
DOTFILES_CACHE="$HOME/.dotfiles-cache"

log() { printf '\n==> %s\n' "$1"; }
warn() { printf '\n!! %s\n' "$1" >&2; }

STATUS_UPDATE="skipped"
STATUS_FIREFOX="skipped"
STATUS_ZEN="skipped"
STATUS_ZEN_CONFIG="skipped"
STATUS_MULLVAD="skipped"

# 1. Preflight
if ! command -v apt >/dev/null 2>&1; then
    echo "This script targets apt-based distros (Debian/Ubuntu). apt not found." >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as a regular user with sudo access, not as root." >&2
    exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required but not installed." >&2
    exit 1
fi
sudo -v

log "Installing prerequisites (curl, git, openssl, ca-certificates, xz-utils)"
sudo apt update
sudo apt install -y curl git openssl ca-certificates xz-utils

# 2. System update
log "Updating system packages"
sudo apt update
sudo apt upgrade -y
STATUS_UPDATE="done"

# 3. Uninstall Firefox
log "Removing Firefox"
if snap list firefox >/dev/null 2>&1; then
    sudo snap remove firefox
fi
if dpkg -l firefox >/dev/null 2>&1 || dpkg -l firefox-esr >/dev/null 2>&1; then
    sudo apt purge -y firefox firefox-esr || true
fi
sudo apt autoremove -y
STATUS_FIREFOX="done"

# 4. Install Zen Browser
log "Installing Zen Browser"
curl -fsSL https://github.com/zen-browser/updates-server/raw/refs/heads/main/install.sh | "$SHELL"

if command -v zen >/dev/null 2>&1; then
    STATUS_ZEN="done"
    if [ ! -f "$HOME/.zen/profiles.ini" ]; then
        log "Creating Zen profile (first run)"
        zen --headless >/dev/null 2>&1 &
        ZEN_PID=$!
        sleep 8
        kill "$ZEN_PID" >/dev/null 2>&1 || true
        wait "$ZEN_PID" 2>/dev/null || true
    fi
else
    warn "Zen install did not produce a 'zen' command on PATH; check ~/.local/bin/zen"
    STATUS_ZEN="failed"
fi

# 5. Restore Zen config
if [ -z "$DOTFILES_REPO" ]; then
    warn "DOTFILES_REPO is not set — skipping Zen config restore. Edit this script to set it once you have a dotfiles repo."
elif [ ! -f "$HOME/.zen/profiles.ini" ]; then
    warn "No Zen profile found — skipping config restore."
else
    log "Restoring Zen config from $DOTFILES_REPO"
    if [ -d "$DOTFILES_CACHE/.git" ]; then
        git -C "$DOTFILES_CACHE" pull --ff-only
    else
        git clone --depth 1 "$DOTFILES_REPO" "$DOTFILES_CACHE"
    fi

    # Prefer the profile marked Default=1; fall back to the last profile
    # section seen if none is marked default. Also respect IsRelative,
    # since Path is only relative to ~/.zen when IsRelative=1.
    PROFILE_INFO=$(awk -F= '
        /^\[Profile/ { if (def == "1" && path != "") { exit } path=""; isrel="1"; def="0" }
        /^Path=/     { path=$2 }
        /^IsRelative=/ { isrel=$2 }
        /^Default=1/ { def="1" }
        END { print path "\t" isrel }
    ' "$HOME/.zen/profiles.ini")
    PROFILE_DIR="${PROFILE_INFO%%$'\t'*}"
    PROFILE_ISRELATIVE="${PROFILE_INFO##*$'\t'}"
    if [ -z "$PROFILE_DIR" ]; then
        warn "Could not resolve Zen profile path from profiles.ini — skipping config restore."
    else
        if [ "$PROFILE_ISRELATIVE" = "0" ]; then
            PROFILE_PATH="$PROFILE_DIR"
        else
            PROFILE_PATH="$HOME/.zen/$PROFILE_DIR"
        fi

        log "Decrypting and applying settings (you'll be prompted for the passphrase unless ZEN_SETTINGS_PASSPHRASE is set)"
        "$DOTFILES_CACHE/decrypt.sh"
        "$DOTFILES_CACHE/apply.sh" "$PROFILE_PATH"

        STATUS_ZEN_CONFIG="done"
    fi
fi

# 6. Install Mullvad VPN
log "Installing Mullvad VPN"
sudo curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc https://repository.mullvad.net/deb/mullvad-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=$(dpkg --print-architecture)] https://repository.mullvad.net/deb/stable stable main" | sudo tee /etc/apt/sources.list.d/mullvad.list >/dev/null
sudo apt update
sudo apt install -y mullvad-vpn
STATUS_MULLVAD="done"

# 7. Summary
log "Summary"
echo "System update:      $STATUS_UPDATE"
echo "Firefox removal:     $STATUS_FIREFOX"
echo "Zen Browser install: $STATUS_ZEN"
echo "Zen config restore:  $STATUS_ZEN_CONFIG"
echo "Mullvad VPN install: $STATUS_MULLVAD"
