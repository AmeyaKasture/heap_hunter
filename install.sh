#!/usr/bin/env bash
#
# Heap Hunter installer.
#
#   ./install.sh      Download the latest release binary from GitHub, install it
#                     into a directory on $PATH and wire up the environment.
#   ./install.sh -l   Verify the local Zig toolchain and the Zig dependency
#                     tree, build the production binary from source, install it
#                     into a directory on $PATH and wire up the environment.
#
set -euo pipefail

REPO_SLUG="AmeyaKasture/heap_hunter"
BIN_NAME="hunt"
INSTALL_DIR="${HEAP_HUNTER_INSTALL_DIR:-$HOME/.local/bin}"
ENV_FILE="${HEAP_HUNTER_ENV_FILE:-$HOME/.heap_hunter_env}"
INDEX_DIR_VALUE="${HEAP_HUNTER_INDEX_DIR:-index}"
SORTING_BUDGET_MB="${HEAP_HUNTER_SORTING_BUDGET_MB:-4096}"
OPTIMIZE_MODE="ReleaseFast"
API_URL="https://api.github.com/repos/${REPO_SLUG}/releases/latest"
MODE="release"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BLUE=$'\033[1;34m'
    C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[1;31m'
else
    C_RESET=""
    C_BLUE=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
fi

step() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
Heap Hunter installer

Usage:
  ./install.sh [-l]

Options:
  -l, --local     Build from the local source tree instead of downloading a
                   release binary. Verifies the Zig toolchain version and the
                   Zig dependency tree, then runs a production build.
  -u, --uninstall Remove the installed binary, the PATH entry and the config
                   file created by this installer.
  -h, --help      Show this help and exit.

Environment:
  HEAP_HUNTER_INSTALL_DIR   Install directory (default: $HOME/.local/bin)
  HEAP_HUNTER_ENV_FILE      Environment file written and sourced
                            (default: $HOME/.heap_hunter_env)
  HEAP_HUNTER_CONFIG_FILE   Config file to create
                            (default: $XDG_CONFIG_HOME/hunt/config.json or
                            $HOME/.config/hunt/config.json)
  HEAP_HUNTER_INDEX_DIR     index-dir value written to the config
                            (default: index)
  HEAP_HUNTER_SORTING_BUDGET_MB
                            sorting-budget-mb written to the config
                            (default: 4096)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -l | --local)
            MODE="local"
            ;;
        -u | --uninstall)
            MODE="uninstall"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_DIR=""
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, pa, "."); nb = split(b, pb, ".");
        n = (na > nb) ? na : nb;
        for (i = 1; i <= n; i++) {
            x = (i <= na) ? pa[i] + 0 : 0;
            y = (i <= nb) ? pb[i] + 0 : 0;
            if (x > y) exit 0;
            if (x < y) exit 1;
        }
        exit 0;
    }'
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        printf ''
    fi
}

download() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 20 -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        die "neither curl nor wget is available"
    fi
}

detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Linux) OS_TAG="linux" ;;
        Darwin) OS_TAG="macos" ;;
        MINGW* | MSYS* | CYGWIN*) OS_TAG="windows" ;;
        *) die "unsupported operating system: $os" ;;
    esac
    case "$arch" in
        x86_64 | amd64) ARCH_TAG="amd64" ;;
        arm64 | aarch64) ARCH_TAG="arm64" ;;
        *) die "unsupported architecture: $arch" ;;
    esac
    PLATFORM="${OS_TAG}-${ARCH_TAG}"
    if [ "$OS_TAG" = "windows" ]; then
        ASSET_NAME="heap_hunter-${PLATFORM}.zip"
        BIN_FILE="hunt.exe"
    else
        ASSET_NAME="heap_hunter-${PLATFORM}.tar.gz"
        BIN_FILE="hunt"
    fi
}

detect_shell() {
    case "${SHELL:-}" in
        */zsh) echo "zsh" ;;
        */bash) echo "bash" ;;
        */fish) echo "fish" ;;
        *) echo "posix" ;;
    esac
}

write_env_file() {
    local shell="$1"
    if [ "$shell" = "fish" ]; then
        cat >"$ENV_FILE" <<EOF
if not contains "$INSTALL_DIR" \$PATH
    set -gx PATH "$INSTALL_DIR" \$PATH
end
EOF
    else
        cat >"$ENV_FILE" <<EOF
case ":\$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) export PATH="$INSTALL_DIR:\$PATH" ;;
esac
EOF
    fi
}

detect_rc_file() {
    case "$(detect_shell)" in
        fish) echo "$HOME/.config/fish/config.fish" ;;
        zsh) echo "$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                echo "$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
        *) echo "$HOME/.profile" ;;
    esac
}

setup_path() {
    local shell rc marker
    shell="$(detect_shell)"
    mkdir -p "$INSTALL_DIR"
    rc="$(detect_rc_file)"

    if [ "$shell" = "fish" ]; then
        marker="# >>> heap_hunter installer >>>"
        mkdir -p "$(dirname "$rc")"
        if ! grep -qF "$marker" "$rc" 2>/dev/null; then
            {
                printf '\n%s\n' "$marker"
                printf 'test -f "%s"; and source "%s"\n' "$ENV_FILE" "$ENV_FILE"
                printf '# <<< heap_hunter installer <<<\n'
            } >>"$rc"
        fi
    else
        marker="# >>> heap_hunter installer >>>"
        touch "$rc"
        if ! grep -qF "$marker" "$rc" 2>/dev/null; then
            {
                printf '\n%s\n' "$marker"
                printf '[ -f "%s" ] && . "%s"\n' "$ENV_FILE" "$ENV_FILE"
                printf '# <<< heap_hunter installer <<<\n'
            } >>"$rc"
        fi
    fi

    write_env_file "$shell"
    # shellcheck disable=SC1090
    . "$ENV_FILE"

    RC_FILE="$rc"
    ok "environment file written to ${ENV_FILE}"
    ok "startup file updated: ${rc}"
}

install_binary() {
    local src="$1"
    [ -f "$src" ] || die "built binary not found at ${src}"
    mkdir -p "$INSTALL_DIR"
    cp "$src" "${INSTALL_DIR}/${BIN_FILE}"
    chmod 0755 "${INSTALL_DIR}/${BIN_FILE}"
    ok "installed ${BIN_NAME} -> ${INSTALL_DIR}/${BIN_FILE}"
}

# Mirrors the search order used by the tool itself (src/Config.zig): the first
# candidate is the one the tool will pick up.
resolve_config_path() {
    if [ -n "${HEAP_HUNTER_CONFIG_FILE:-}" ]; then
        CONFIG_FILE="$HEAP_HUNTER_CONFIG_FILE"
        CONFIG_DIR="$(dirname "$CONFIG_FILE")"
        return
    fi
    if [ "$OS_TAG" = "windows" ]; then
        if [ -n "${APPDATA:-}" ]; then
            CONFIG_DIR="${APPDATA}/hunt"
        elif [ -n "${USERPROFILE:-}" ]; then
            CONFIG_DIR="${USERPROFILE}/.hunt"
        else
            CONFIG_DIR="${HOME}/.hunt"
        fi
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
        CONFIG_DIR="${XDG_CONFIG_HOME}/hunt"
    elif [ -n "${HOME:-}" ]; then
        CONFIG_DIR="${HOME}/.config/hunt"
    else
        CONFIG_DIR="${HOME}/.hunt"
    fi
    CONFIG_FILE="${CONFIG_DIR}/config.json"
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

create_config() {
    resolve_config_path
    if [ -f "$CONFIG_FILE" ]; then
        warn "config file already exists, leaving it unchanged: ${CONFIG_FILE}"
        return
    fi
    mkdir -p "$CONFIG_DIR"
    local index_escaped
    index_escaped="$(json_escape "$INDEX_DIR_VALUE")"
    cat >"$CONFIG_FILE" <<EOF
{
  "index-dir": "${index_escaped}",
  "sorting-budget-mb": ${SORTING_BUDGET_MB}
}
EOF
    chmod 0644 "$CONFIG_FILE"
    ok "config file created: ${CONFIG_FILE}"
}

print_summary() {
    printf '\n'
    ok "Heap Hunter installed successfully"
    printf '\n'
    printf 'Config file:\n'
    printf '    %s\n' "$CONFIG_FILE"
    printf '    index-dir:          %s\n' "$INDEX_DIR_VALUE"
    printf '    sorting-budget-mb:  %s\n' "$SORTING_BUDGET_MB"
    printf '\n'
    printf 'Index location (index-dir "%s" is resolved relative to the current directory):\n' "$INDEX_DIR_VALUE"
    printf '    hunt index <dump.hprof>     ->  ./%s/<dump-name>.idx/\n' "$INDEX_DIR_VALUE"
    printf '    hunt overview <dump.hprof>  ->  ./%s/<dump-name>.idx/\n' "$INDEX_DIR_VALUE"
    printf '    hunt info <dump.hprof>      ->  ./%s/<dump-name>.idx/\n' "$INDEX_DIR_VALUE"
    printf '    hunt info                   ->  ./%s\n' "$INDEX_DIR_VALUE"
    printf '\n'
    printf 'Override per run with:  %s <command> --index-dir <dir>\n' "$BIN_NAME"
    printf '\n'
    printf 'Activate %s in your current shell with:\n\n' "$BIN_NAME"
    printf '    source %s\n\n' "$RC_FILE"
    printf 'or open a new terminal. Then run:\n\n'
    printf '    %s --help\n\n' "$BIN_NAME"
}

verify_install() {
    local version
    version="$("${INSTALL_DIR}/${BIN_NAME}" --version 2>&1 | head -n1)" ||
        die "${BIN_NAME} failed to run after installation"
    ok "verified: ${version}"
}

release_json() {
    local out="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 20 -H "Accept: application/vnd.github+json" \
            -o "$out" "$API_URL" 2>/dev/null || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "$API_URL" 2>/dev/null || return 1
    else
        return 1
    fi
    [ -s "$out" ]
}

parse_release_json() {
    local json="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$json" "$ASSET_NAME" <<'PY' || true
import json
import sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)

print("tag=" + str(data.get("tag_name", "")))
print("assets=" + ",".join(a.get("name", "") for a in data.get("assets", [])))
for asset in data.get("assets", []):
    if asset.get("name") == sys.argv[2]:
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            digest = digest.split(":", 1)[1]
        print("digest=" + digest)
        break
PY
    fi
}

install_from_release() {
    local url tag="" digest="" assets=""
    TMP_DIR="$(mktemp -d)"

    step "resolving latest release for ${PLATFORM}"

    if release_json "${TMP_DIR}/release.json"; then
        parse_release_json "${TMP_DIR}/release.json" >"${TMP_DIR}/release.env" || true
        if [ -f "${TMP_DIR}/release.env" ]; then
            while IFS='=' read -r key value; do
                case "$key" in
                    tag) tag="$value" ;;
                    digest) digest="$value" ;;
                    assets) assets="$value" ;;
                esac
            done <"${TMP_DIR}/release.env"
        fi
    fi

    if [ -z "$tag" ]; then
        warn "could not query the GitHub release API, falling back to the latest release redirect"
        url="https://github.com/${REPO_SLUG}/releases/latest/download/${ASSET_NAME}"
    else
        url="https://github.com/${REPO_SLUG}/releases/download/${tag}/${ASSET_NAME}"
    fi

    if [ -n "$assets" ] && [ "${assets#*$ASSET_NAME}" = "$assets" ]; then
        err "no release asset for ${PLATFORM} (${ASSET_NAME})"
        err "available assets: ${assets}"
        exit 1
    fi

    step "downloading ${ASSET_NAME}"
    if ! download "$url" "${TMP_DIR}/${ASSET_NAME}"; then
        err "failed to download ${url}"
        if [ -n "$assets" ]; then
            err "available assets: ${assets}"
        fi
        exit 1
    fi
    ok "downloaded ${ASSET_NAME}"

    if [ -n "$digest" ]; then
        local actual
        actual="$(sha256_of "${TMP_DIR}/${ASSET_NAME}")"
        if [ -n "$actual" ] && [ "$actual" != "$digest" ]; then
            die "checksum mismatch for ${ASSET_NAME} (expected ${digest}, got ${actual})"
        fi
        ok "checksum verified (sha256 ${actual:0:16}...)"
    else
        warn "no checksum published for this asset, skipping verification"
    fi

    step "extracting"
    mkdir -p "${TMP_DIR}/extract"
    case "$ASSET_NAME" in
        *.tar.gz | *.tgz) tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}/extract" ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -oq "${TMP_DIR}/${ASSET_NAME}" -d "${TMP_DIR}/extract"
            elif command -v python3 >/dev/null 2>&1; then
                python3 -m zipfile -e "${TMP_DIR}/${ASSET_NAME}" "${TMP_DIR}/extract"
            else
                die "no unzip tool available to extract ${ASSET_NAME}"
            fi
            ;;
        *) die "unsupported archive type: ${ASSET_NAME}" ;;
    esac

    local found
    found="$(find "${TMP_DIR}/extract" -type f -name "${BIN_FILE}" | head -n1)"
    [ -n "$found" ] || die "could not find ${BIN_FILE} inside ${ASSET_NAME}"

    install_binary "$found"
}

install_from_source() {
    local zon="${SCRIPT_DIR}/build.zig.zon"
    local zig_version min_version deps

    step "checking the Zig toolchain"
    command -v zig >/dev/null 2>&1 || die "zig not found in PATH, install Zig ${min_version:-0.16.0} or newer: https://ziglang.org/download/"
    zig_version="$(zig version)"
    ok "zig ${zig_version}"

    if [ -f "$zon" ]; then
        min_version="$(grep -oE '\.minimum_zig_version[[:space:]]*=[[:space:]]*"[^"]+"' "$zon" | sed -E 's/.*"([^"]+)".*/\1/' | head -n1)"
        if [ -n "$min_version" ]; then
            if version_ge "$zig_version" "$min_version"; then
                ok "zig ${zig_version} satisfies the required minimum ${min_version}"
            else
                die "zig ${zig_version} is older than the required minimum ${min_version}"
            fi
        else
            warn "no .minimum_zig_version declared in build.zig.zon, skipping the version check"
        fi
    else
        warn "build.zig.zon not found in ${SCRIPT_DIR}, skipping the version check"
    fi

    step "checking the Zig dependency tree"
    deps="$(
        awk '
            /\.dependencies[[:space:]]*=[[:space:]]*\./ {
                if ($0 ~ /\.\{[[:space:]]*\}[[:space:]]*,?/) { in_deps = 0 } else { in_deps = 1 }
                next
            }
            in_deps && /^[[:space:]]*\}/ { in_deps = 0; next }
            in_deps && /\.name[[:space:]]*=/ {
                line = $0
                sub(/.*\.name[[:space:]]*=[[:space:]]*\./, "", line)
                sub(/[^a-zA-Z0-9_].*$/, "", line)
                if (line != "") print line
            }
        ' "$SCRIPT_DIR/build.zig.zon" 2>/dev/null || true
    )"
    if [ -n "$deps" ]; then
        for dep in $deps; do
            printf '    dependency: %s\n' "$dep"
        done
    else
        printf '    no external dependencies declared\n'
    fi

    if ! (cd "$SCRIPT_DIR" && zig build --fetch); then
        die "zig dependency tree could not be resolved, run 'zig build --fetch' manually for details"
    fi
    ok "all Zig dependencies are satisfied"

    step "building the production binary (${OPTIMIZE_MODE})"
    (cd "$SCRIPT_DIR" && zig build "-Doptimize=${OPTIMIZE_MODE}")
    ok "build finished"

    install_binary "${SCRIPT_DIR}/zig-out/bin/${BIN_FILE}"
}

uninstall() {
    local rc marker backup

    step "removing the installed binary"
    if [ -f "${INSTALL_DIR}/${BIN_FILE}" ]; then
        rm -f "${INSTALL_DIR}/${BIN_FILE}"
        ok "removed ${INSTALL_DIR}/${BIN_FILE}"
    else
        printf '    nothing to remove at %s\n' "${INSTALL_DIR}/${BIN_FILE}"
    fi

    step "removing the PATH entry"
    rc="$(detect_rc_file)"
    marker="# >>> heap_hunter installer >>>"
    if [ -f "$rc" ] && grep -qF "$marker" "$rc" 2>/dev/null; then
        awk -v start="$marker" -v end="# <<< heap_hunter installer <<<" '
            $0 == start { skip = 1; next }
            skip && $0 == end { skip = 0; next }
            !skip { print }
        ' "$rc" >"${rc}.hunt.tmp"
        mv "${rc}.hunt.tmp" "$rc"
        ok "removed the installer block from ${rc}"
    else
        printf '    no installer block found in %s\n' "$rc"
    fi

    if [ -f "$ENV_FILE" ]; then
        rm -f "$ENV_FILE"
        ok "removed ${ENV_FILE}"
    fi

    step "removing the config file"
    resolve_config_path
    if [ -f "$CONFIG_FILE" ]; then
        backup="${CONFIG_FILE}.bak"
        rm -f "$backup"
        mv "$CONFIG_FILE" "$backup"
        ok "removed ${CONFIG_FILE} (backup: ${backup})"
    else
        printf '    no config file at %s\n' "$CONFIG_FILE"
    fi

    printf '\n'
    ok "Heap Hunter uninstalled"
    printf '\n'

    local other
    other="$(
        for dir in $(echo "$PATH" | tr ':' '\n'); do
            if [ -x "${dir}/${BIN_FILE}" ]; then
                printf '%s\n' "${dir}/${BIN_FILE}"
            fi
        done
        true
    )"
    if [ -n "$other" ]; then
        printf 'Other %s binaries still on your PATH (not managed by this installer):\n' "$BIN_NAME"
        printf '    %s\n' "$other"
        printf '\n'
    fi

    printf 'Open a new terminal or run:\n\n'
    printf '    exec %s\n\n' "$SHELL"
    printf 'to drop %s from the current PATH.\n' "$BIN_NAME"
}

main() {
    detect_platform

    if [ "$MODE" = "uninstall" ]; then
        uninstall
        exit 0
    fi

    case "$MODE" in
        local) install_from_source ;;
        release) install_from_release ;;
    esac

    step "adding ${INSTALL_DIR} to PATH"
    setup_path

    step "creating the config file"
    create_config

    verify_install

    print_summary
}

main
