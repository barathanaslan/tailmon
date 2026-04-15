#!/usr/bin/env bash
# install-server.sh -- install studiod as a launchd system daemon on the Mac Studio.
#
# This script is invoked on the Mac Studio (NOT on the MacBook). The
# expected workflow is:
#
#   ssh macstudio
#   cd ~/studio-cli
#   sudo bash deploy/install-server.sh
#
# It performs the following steps, all idempotently where possible:
#
#   1. Asserts macOS + root.
#   2. Discovers the Tailscale IPv4 address.
#   3. Builds a venv at /opt/studiod/venv with the [collector] extras.
#   4. Generates a 256-bit bearer token at /etc/studiod/token (mode 0600,
#      root-owned), unless one already exists.
#   5. Renders com.bosphorify.studiod.plist with the Tailscale IP
#      substituted in, and copies it to /Library/LaunchDaemons.
#   6. Bootstraps the launchd job and waits for /health to return 200.
#
# Re-running the script is safe: it detects an existing install and
# refuses to clobber it unless --reinstall is passed.

set -euo pipefail

PROG="install-server.sh"
LABEL="com.bosphorify.studiod"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
INSTALL_ROOT="/opt/studiod"
VENV_DIR="${INSTALL_ROOT}/venv"
TOKEN_DIR="/etc/studiod"
TOKEN_FILE="${TOKEN_DIR}/token"
LOG_OUT="/var/log/studiod.out.log"
LOG_ERR="/var/log/studiod.err.log"
DAEMON_PORT="8765"
HEALTH_TIMEOUT="10"

REINSTALL="0"
REPO_DIR=""

print_usage() {
    cat <<EOF
Usage: sudo bash ${PROG} [--repo-dir PATH] [--reinstall] [--help]

Options:
  --repo-dir PATH    Path to the studio-cli repo on this host
                     (default: directory containing this script's parent)
  --reinstall        Tear down an existing install (preserving the token)
                     and re-bootstrap. Without this flag, an existing
                     install causes the script to bail out.
  --help, -h         Show this message.

Environment:
  STUDIOD_PORT       Override the HTTP port (default ${DAEMON_PORT}).

This script must be run as root on macOS. It does NOT need network egress
beyond Tailscale itself + uv's package index.
EOF
}

log() {
    printf '[%s] %s\n' "${PROG}" "$*"
}

die() {
    printf '[%s] error: %s\n' "${PROG}" "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "must be run as root (try: sudo bash ${PROG})"
    fi
}

require_darwin() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        die "this script only runs on macOS"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-dir)
                REPO_DIR="${2:-}"
                shift 2
                ;;
            --reinstall)
                REINSTALL="1"
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                die "unknown argument: $1 (try --help)"
                ;;
        esac
    done
}

detect_repo_dir() {
    if [[ -n "${REPO_DIR}" ]]; then
        return
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_DIR="$(cd "${script_dir}/.." && pwd)"
    if [[ ! -f "${REPO_DIR}/pyproject.toml" ]]; then
        die "could not auto-detect repo dir; pass --repo-dir PATH"
    fi
}

detect_tailscale_ip() {
    local ts
    ts="$(command -v tailscale || true)"
    if [[ -z "${ts}" ]]; then
        for cand in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
            if [[ -x "${cand}" ]]; then
                ts="${cand}"
                break
            fi
        done
    fi
    if [[ -z "${ts}" ]]; then
        die "tailscale binary not found; install Tailscale first"
    fi
    local ip
    ip="$("${ts}" ip -4 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
    if [[ -z "${ip}" ]]; then
        die "tailscale ip -4 returned empty; is Tailscale up? (run: ${ts} status)"
    fi
    if [[ ! "${ip}" =~ ^100\. ]]; then
        die "tailscale IP ${ip} is not in the 100.x.x.x CGNAT range; refusing to bind"
    fi
    printf '%s' "${ip}"
}

ensure_dirs() {
    install -d -m 0755 -o root -g wheel "${INSTALL_ROOT}"
    install -d -m 0700 -o root -g wheel "${TOKEN_DIR}"
    : > "${LOG_OUT}" || true
    : > "${LOG_ERR}" || true
    chmod 0640 "${LOG_OUT}" "${LOG_ERR}"
    chown root:wheel "${LOG_OUT}" "${LOG_ERR}"
}

ensure_python_and_uv() {
    # Resolve a Python 3.12+ interpreter. Check PATH first, then known
    # Homebrew locations (root's PATH via sudo often excludes /opt/homebrew).
    PY_BIN=""
    local cand v
    for cand in \
        "$(command -v python3 2>/dev/null || true)" \
        /opt/homebrew/bin/python3.14 \
        /opt/homebrew/bin/python3.13 \
        /opt/homebrew/bin/python3.12 \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3.14 \
        /usr/local/bin/python3.13 \
        /usr/local/bin/python3.12 \
        /usr/local/bin/python3
    do
        [[ -z "${cand}" ]] && continue
        [[ ! -x "${cand}" ]] && continue
        v="$("${cand}" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
        if [[ -n "${v}" ]] && [[ "$(printf '%s\n3.12\n' "${v}" | sort -V | head -n1)" == "3.12" ]]; then
            PY_BIN="${cand}"
            log "using python ${v} at ${cand}"
            break
        fi
    done
    if [[ -z "${PY_BIN}" ]]; then
        die "python 3.12+ required; tried PATH, /opt/homebrew/bin, /usr/local/bin"
    fi

    if command -v uv >/dev/null 2>&1; then
        UV_BIN="$(command -v uv)"
        return
    fi
    for cand in /opt/homebrew/bin/uv /usr/local/bin/uv; do
        if [[ -x "${cand}" ]]; then
            UV_BIN="${cand}"
            return
        fi
    done
    UV_BIN=""
    log "uv not found; will fall back to python3 -m venv + pip"
}

build_venv() {
    if [[ -d "${VENV_DIR}" ]] && [[ "${REINSTALL}" != "1" ]]; then
        log "venv already exists at ${VENV_DIR} (reusing; pass --reinstall to rebuild)"
    else
        if [[ -d "${VENV_DIR}" ]]; then
            log "removing existing venv at ${VENV_DIR}"
            rm -rf "${VENV_DIR}"
        fi
        log "creating venv at ${VENV_DIR}"
        if [[ -n "${UV_BIN}" ]]; then
            "${UV_BIN}" venv --python "${PY_BIN}" "${VENV_DIR}"
        else
            "${PY_BIN}" -m venv "${VENV_DIR}"
        fi
    fi

    log "installing studio-cli[collector] from ${REPO_DIR}"
    if [[ -n "${UV_BIN}" ]]; then
        VIRTUAL_ENV="${VENV_DIR}" "${UV_BIN}" pip install --python "${VENV_DIR}/bin/python" "${REPO_DIR}[collector]"
    else
        "${VENV_DIR}/bin/pip" install --upgrade pip
        "${VENV_DIR}/bin/pip" install "${REPO_DIR}[collector]"
    fi
}

generate_token() {
    if [[ -s "${TOKEN_FILE}" ]]; then
        log "token already exists at ${TOKEN_FILE} (preserving)"
        return
    fi
    log "generating new bearer token at ${TOKEN_FILE}"
    umask 077
    openssl rand -base64 32 | tr -d '\n' > "${TOKEN_FILE}"
    chmod 0600 "${TOKEN_FILE}"
    chown root:wheel "${TOKEN_FILE}"
}

detect_tmux_user() {
    # B17: the collector needs to target the user's tmux namespace
    # (/tmp/tmux-<uid>/default), not root's. The user who ran
    # ``sudo bash install-server.sh`` is captured here via $SUDO_USER and
    # baked into the plist via __TMUX_USER__. The daemon wraps every tmux
    # call in ``sudo -u <TMUX_USER>`` at runtime.
    if [[ -z "${SUDO_USER:-}" ]]; then
        die "SUDO_USER is empty; run this script via 'sudo bash install-server.sh' (not as direct root) so we can capture the tmux user"
    fi
    if ! id -u "${SUDO_USER}" >/dev/null 2>&1; then
        die "SUDO_USER=${SUDO_USER} is not a valid local user"
    fi
    printf '%s' "${SUDO_USER}"
}

write_plist() {
    local ip="$1"
    local tmux_user="$2"
    local src="${REPO_DIR}/deploy/com.bosphorify.studiod.plist"
    if [[ ! -f "${src}" ]]; then
        die "plist template missing: ${src}"
    fi
    log "rendering plist: tailscale ip ${ip}, tmux user ${tmux_user} -> ${PLIST_PATH}"
    local tmp
    tmp="$(mktemp)"
    sed -e "s|__TAILSCALE_IP__|${ip}|g" -e "s|__TMUX_USER__|${tmux_user}|g" "${src}" > "${tmp}"
    install -m 0644 -o root -g wheel "${tmp}" "${PLIST_PATH}"
    rm -f "${tmp}"
}

is_loaded() {
    launchctl print "system/${LABEL}" >/dev/null 2>&1
}

bootstrap_daemon() {
    if is_loaded; then
        if [[ "${REINSTALL}" != "1" ]]; then
            die "${LABEL} is already loaded; pass --reinstall to replace it (or run uninstall-server.sh first)"
        fi
        log "bootout existing ${LABEL} (reinstall mode)"
        launchctl bootout "system/${LABEL}" || true
    fi
    log "launchctl bootstrap system ${PLIST_PATH}"
    launchctl bootstrap system "${PLIST_PATH}"
    launchctl enable "system/${LABEL}" || true
}

verify_health() {
    local ip="$1"
    local url="http://${ip}:${DAEMON_PORT}/health"
    log "waiting for ${url} ..."
    local i
    for ((i = 0; i < HEALTH_TIMEOUT; i++)); do
        if curl -sf "${url}" >/dev/null; then
            log "health check OK"
            return 0
        fi
        sleep 1
    done
    die "health check failed after ${HEALTH_TIMEOUT}s; check ${LOG_ERR}"
}

print_summary() {
    local ip="$1"
    cat <<EOF

------------------------------------------------------------
studiod is up at http://${ip}:${DAEMON_PORT}

Bearer token: ${TOKEN_FILE}
   Copy it to the MacBook with:
     ssh macstudio sudo cat ${TOKEN_FILE} > ~/.config/studio-cli/token
     chmod 600 ~/.config/studio-cli/token

Logs:
   tail -f ${LOG_OUT}
   tail -f ${LOG_ERR}
   log show --predicate 'process == "studiod"' --last 5m

To uninstall: sudo bash ${REPO_DIR}/deploy/uninstall-server.sh
------------------------------------------------------------
EOF
}

main() {
    parse_args "$@"
    require_darwin
    require_root
    detect_repo_dir
    log "repo dir: ${REPO_DIR}"
    local ip
    ip="$(detect_tailscale_ip)"
    log "tailscale ip: ${ip}"
    local tmux_user
    tmux_user="$(detect_tmux_user)"
    log "tmux user: ${tmux_user}"
    ensure_dirs
    ensure_python_and_uv
    build_venv
    generate_token
    write_plist "${ip}" "${tmux_user}"
    bootstrap_daemon
    verify_health "${ip}"
    print_summary "${ip}"
}

main "$@"
