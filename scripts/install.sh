#!/usr/bin/env sh
set -eu

echo "VOX Assistant - Headless Installer"

if [ "$(uname -s)" != "Linux" ]; then
    echo "Error: this installer supports Linux only." >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64) RELEASE_ARCH="x86_64" ;;
    aarch64|arm64) RELEASE_ARCH="aarch64" ;;
    *)
        echo "Error: unsupported Linux architecture '$(uname -m)'." >&2
        echo "Supported: x86_64, aarch64." >&2
        exit 1
        ;;
esac

# --- Release source defaults -------------------------------------------------
# A bare `curl ... | sh` resolves the newest release from a manifest committed to
# the public release repository, then downloads that repository's release asset.
# Everything below can be overridden by environment variables.
VOXY_RELEASE_REPO="${VOXY_RELEASE_REPO:-ATom4869/vox-assistant}"
VOXY_RELEASE_MANIFEST_URL="${VOXY_RELEASE_MANIFEST_URL:-https://raw.githubusercontent.com/$VOXY_RELEASE_REPO/main/latest.json}"
VOXY_RELEASE_ASSET_BASE_URL="${VOXY_RELEASE_ASSET_BASE_URL:-https://github.com/$VOXY_RELEASE_REPO/releases/download}"
# Pinned minisign public key for published releases. Fill this in once the
# release key exists (plan step B4); while empty, only SHA-256 is enforced.
VOXY_PINNED_MINISIGN_PUBLIC_KEY="${VOXY_PINNED_MINISIGN_PUBLIC_KEY:-RWTZgH5P2pHvbC9C3ov299lpNiVON7yT5iiNi9qP+5ycQSUVnhYwbLzD}"

VOX_HOME="${VOX_HOME:-$HOME/.vox}"
INSTALL_BIN="${HOME}/.local/bin"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
mkdir -p "$VOX_HOME" "$INSTALL_BIN" "$SYSTEMD_DIR" "$HOME/workspace"

SOURCE_BINARY=""
if [ -n "${VOX_AGENT_BINARY:-}" ]; then
    SOURCE_BINARY="$VOX_AGENT_BINARY"
elif [ -z "${VOX_AGENT_DOWNLOAD_URL:-}" ] && [ -x "./src-tauri/target/release/voxy" ]; then
    SOURCE_BINARY="./src-tauri/target/release/voxy"
elif [ -z "${VOX_AGENT_DOWNLOAD_URL:-}" ] && [ -x "./voxy" ]; then
    SOURCE_BINARY="./voxy"
elif [ -z "${VOX_AGENT_DOWNLOAD_URL:-}" ] && command -v voxy >/dev/null 2>&1; then
    SOURCE_BINARY="$(command -v voxy)"
fi

# Resolve the newest published release when no explicit source was provided.
# This is what makes a bare `curl ... | sh` work on a clean host.
if [ -z "$SOURCE_BINARY" ] && [ -z "${VOX_AGENT_DOWNLOAD_URL:-}" ]; then
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required to download the VOX agent release." >&2
        exit 1
    fi
    echo "Resolving the latest $RELEASE_ARCH release from $VOXY_RELEASE_REPO ..."
    MANIFEST="$(
        curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
            "$VOXY_RELEASE_MANIFEST_URL"
    )" || {
        echo "Error: could not fetch the release manifest: $VOXY_RELEASE_MANIFEST_URL" >&2
        echo "Set VOX_AGENT_DOWNLOAD_URL to install from a specific artifact instead." >&2
        exit 1
    }

    # The manifest is flat JSON produced by scripts/prepare-headless-release.mjs,
    # so a plain shell can read it without depending on jq.
    manifest_value() {
        printf '%s\n' "$MANIFEST" | sed -n \
            "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" |
            head -n 1
    }

    RELEASE_TAG="$(manifest_value tag)"
    RELEASE_FILE="$(manifest_value "${RELEASE_ARCH}_file")"
    RELEASE_SHA256="$(manifest_value "${RELEASE_ARCH}_sha256")"

    if [ -z "$RELEASE_TAG" ] || [ -z "$RELEASE_FILE" ]; then
        echo "Error: release manifest has no usable entry for architecture '$RELEASE_ARCH'." >&2
        exit 1
    fi
    case "$RELEASE_TAG" in
        *[!A-Za-z0-9._+-]*)
            echo "Error: release manifest returned an invalid tag." >&2
            exit 1
            ;;
    esac
    case "$RELEASE_FILE" in
        *[!A-Za-z0-9._+-]*)
            echo "Error: release manifest returned an invalid artifact name." >&2
            exit 1
            ;;
    esac

    VOX_AGENT_DOWNLOAD_URL="$VOXY_RELEASE_ASSET_BASE_URL/$RELEASE_TAG/$RELEASE_FILE"
    export VOX_AGENT_DOWNLOAD_URL
    echo "Selected release: $RELEASE_FILE (tag $RELEASE_TAG)"

    # The manifest lives on the release repo's main branch while the binary is a
    # release asset, so its digest is a stronger trust anchor than a .sha256 file
    # served from the same place as the binary.
    if [ -z "${VOX_AGENT_SHA256:-}" ] && [ -n "$RELEASE_SHA256" ]; then
        VOX_AGENT_SHA256="$RELEASE_SHA256"
        export VOX_AGENT_SHA256
    fi
fi

# Prefer the explicitly pinned release key when the caller did not supply one.
if [ -z "${VOX_AGENT_MINISIGN_PUBLIC_KEY:-}" ] && [ -n "$VOXY_PINNED_MINISIGN_PUBLIC_KEY" ]; then
    VOX_AGENT_MINISIGN_PUBLIC_KEY="$VOXY_PINNED_MINISIGN_PUBLIC_KEY"
    export VOX_AGENT_MINISIGN_PUBLIC_KEY
fi

TARGET_BINARY="$INSTALL_BIN/voxy"
PREVIOUS_BINARY="$INSTALL_BIN/voxy.previous"
TEMP_BINARY="$INSTALL_BIN/.voxy.new.$$"
BACKUP_TEMP="$INSTALL_BIN/.voxy.previous.new.$$"
UNIT_FILE="$SYSTEMD_DIR/vox-agent.service"
UNIT_TEMP="$SYSTEMD_DIR/.vox-agent.service.new.$$"
SIGNATURE_TEMP="$INSTALL_BIN/.voxy.minisig.$$"
CHECKSUM_TEMP="$INSTALL_BIN/.voxy.sha256.$$"
HAD_PREVIOUS=0
WAS_ACTIVE=0
REPLACED_BINARY=0
cleanup() {
    rm -f "$TEMP_BINARY" "$BACKUP_TEMP" "$UNIT_TEMP" "$SIGNATURE_TEMP" "$CHECKSUM_TEMP"
}
trap cleanup EXIT

if [ -n "$SOURCE_BINARY" ]; then
    if [ "$SOURCE_BINARY" != "$TARGET_BINARY" ]; then
        cp "$SOURCE_BINARY" "$TEMP_BINARY"
    else
        cp "$TARGET_BINARY" "$TEMP_BINARY"
    fi
elif [ -n "${VOX_AGENT_DOWNLOAD_URL:-}" ]; then
    case "$VOX_AGENT_DOWNLOAD_URL" in
        https://*) ;;
        *)
            echo "Error: VOX_AGENT_DOWNLOAD_URL must use HTTPS." >&2
            exit 1
            ;;
    esac
    if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        echo "Error: curl and sha256sum are required to verify the downloaded binary." >&2
        exit 1
    fi
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error "$VOX_AGENT_DOWNLOAD_URL" --output "$TEMP_BINARY"

    DOWNLOAD_NAME="${VOX_AGENT_DOWNLOAD_URL##*/}"
    case "$DOWNLOAD_NAME" in
        ""|*[!A-Za-z0-9._+-]*)
            echo "Error: release download URL must end in a plain artifact filename." >&2
            exit 1
            ;;
    esac
    if [ -n "${VOX_AGENT_SHA256:-}" ]; then
        NORMALIZED_SHA256=$(printf '%s' "$VOX_AGENT_SHA256" | tr '[:upper:]' '[:lower:]')
    else
        CHECKSUM_URL="${VOX_AGENT_CHECKSUM_URL:-${VOX_AGENT_DOWNLOAD_URL}.sha256}"
        case "$CHECKSUM_URL" in
            https://*) ;;
            *)
                echo "Error: VOX_AGENT_CHECKSUM_URL must use HTTPS." >&2
                exit 1
                ;;
        esac
        curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error "$CHECKSUM_URL" --output "$CHECKSUM_TEMP"
        NORMALIZED_SHA256=$(awk -v expected="$DOWNLOAD_NAME" \
            '$2 == expected && length($1) == 64 && $1 ~ /^[[:xdigit:]]+$/ { print tolower($1); count++ }
             END { if (count != 1) exit 1 }' "$CHECKSUM_TEMP") || {
            echo "Error: checksum manifest must contain exactly one valid entry for $DOWNLOAD_NAME." >&2
            exit 1
        }
    fi
    case "$NORMALIZED_SHA256" in
        *[!0-9a-f]*)
            echo "Error: checksum must contain exactly 64 hexadecimal characters." >&2
            exit 1
            ;;
    esac
    if [ "${#NORMALIZED_SHA256}" -ne 64 ]; then
        echo "Error: checksum must contain exactly 64 hexadecimal characters." >&2
        exit 1
    fi

    if [ -n "${VOX_AGENT_MINISIGN_PUBLIC_KEY:-}" ] || [ -n "${VOX_AGENT_SIGNATURE_URL:-}" ]; then
        if [ -z "${VOX_AGENT_MINISIGN_PUBLIC_KEY:-}" ]; then
            echo "Error: VOX_AGENT_MINISIGN_PUBLIC_KEY is required when a signature URL is set." >&2
            exit 1
        fi
        if ! command -v minisign >/dev/null 2>&1; then
            echo "Error: minisign is required to verify the downloaded signature." >&2
            exit 1
        fi
        SIGNATURE_URL="${VOX_AGENT_SIGNATURE_URL:-${VOX_AGENT_DOWNLOAD_URL}.minisig}"
        case "$SIGNATURE_URL" in
            https://*) ;;
            *)
                echo "Error: VOX_AGENT_SIGNATURE_URL must use HTTPS." >&2
                exit 1
                ;;
        esac
        curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error "$SIGNATURE_URL" --output "$SIGNATURE_TEMP"
        minisign -Vm "$TEMP_BINARY" -P "$VOX_AGENT_MINISIGN_PUBLIC_KEY" -x "$SIGNATURE_TEMP"
    fi

    printf '%s  %s\n' "$NORMALIZED_SHA256" "$TEMP_BINARY" | sha256sum --check --status || {
        echo "Error: downloaded voxy checksum does not match; refusing to install." >&2
        exit 1
    }
else
    echo "Error: voxy binary is unavailable." >&2
    echo "Provide VOX_AGENT_BINARY, set VOX_AGENT_DOWNLOAD_URL, or allow access to" >&2
    echo "the release manifest at $VOXY_RELEASE_MANIFEST_URL." >&2
    exit 1
fi

chmod 755 "$TEMP_BINARY"
if ! "$TEMP_BINARY" --version >/dev/null 2>&1; then
    echo "Error: candidate voxy binary failed its version check; refusing to install." >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemctl is required to install the user service." >&2
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required to verify the installed agent service health." >&2
    exit 1
fi

if systemctl --user is-active --quiet vox-agent; then
    WAS_ACTIVE=1
fi

if [ -x "$TARGET_BINARY" ]; then
    cp -p "$TARGET_BINARY" "$BACKUP_TEMP"
    mv -f "$BACKUP_TEMP" "$PREVIOUS_BINARY"
    HAD_PREVIOUS=1
fi

mv -f "$TEMP_BINARY" "$TARGET_BINARY"
REPLACED_BINARY=1
export VOX_HOME
export PATH="$INSTALL_BIN:$PATH"

rollback_install() {
    echo "Error: installation/startup failed; restoring the previous agent binary." >&2
    if [ "$HAD_PREVIOUS" -eq 1 ]; then
        cp -p "$PREVIOUS_BINARY" "$BACKUP_TEMP" &&
            mv -f "$BACKUP_TEMP" "$TARGET_BINARY" || {
                echo "Error: failed to restore $PREVIOUS_BINARY to $TARGET_BINARY." >&2
                return 1
            }
    else
        rm -f "$TARGET_BINARY"
    fi
    REPLACED_BINARY=0
    systemctl --user daemon-reload || true
    if [ "$WAS_ACTIVE" -eq 1 ] && [ "$HAD_PREVIOUS" -eq 1 ]; then
        systemctl --user restart vox-agent || true
    else
        systemctl --user stop vox-agent || true
    fi
    return 1
}

wait_for_agent_health() {
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        if systemctl --user is-active --quiet vox-agent &&
            curl --fail --silent --show-error --max-time 2 \
                http://127.0.0.1:7777/health >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "Error: voxy did not become healthy at http://127.0.0.1:7777/health." >&2
    return 1
}

on_signal() {
    if [ "$REPLACED_BINARY" -eq 1 ]; then
        rollback_install || true
    fi
    exit 1
}
trap on_signal HUP INT TERM

if ! "$TARGET_BINARY" init --workspace "$HOME/workspace"; then
    rollback_install
    exit 1
fi
if ! "$TARGET_BINARY" install-service --print > "$UNIT_TEMP"; then
    rollback_install
    exit 1
fi
if ! mv -f "$UNIT_TEMP" "$UNIT_FILE"; then
    rollback_install
    exit 1
fi
if ! systemctl --user daemon-reload ||
    ! systemctl --user enable --now vox-agent ||
    ! systemctl --user restart vox-agent ||
    ! wait_for_agent_health; then
    rollback_install
    exit 1
fi
REPLACED_BINARY=0

echo ""
echo "VOX installed as the 'voxy' command and started as a systemd user service."
if [ "$HAD_PREVIOUS" -eq 1 ]; then
    echo "Previous binary retained at: $PREVIOUS_BINARY"
    echo "To roll back: voxy rollback"
fi
echo "Pair a browser with: voxy pair"
echo "For service persistence after logout, enable systemd lingering:"
echo "  sudo loginctl enable-linger $USER"
echo "To finish account/workspace setup: voxy onboard"
