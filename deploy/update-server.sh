#!/usr/bin/env bash
# update-server.sh -- fast-path iterative update for an already-installed
# studiod launchd daemon on the Mac Studio.
#
# Invocation (short enough that it never wraps in a typical terminal):
#
#   ssh -t macstudio "sudo bash deploy/update-server.sh"
#
# What it does, in order:
#   1. Sanity checks (macOS + root).
#   2. Reinstalls the [collector] extras into the existing venv. No
#      venv rebuild, no token regeneration, no plist rewrite.
#   3. launchctl kickstart -k on the daemon label so uvicorn picks up
#      the new code.
#   4. Polls /health locally until 200 (up to 10s), then exits.
#
# Anything more invasive (token rotation, venv rebuild, plist change)
# belongs in install-server.sh --reinstall, not here.

set -euo pipefail

PROG="update-server.sh"
LABEL="com.bosphorify.studiod"
INSTALL_ROOT="/opt/studiod"
VENV_DIR="${INSTALL_ROOT}/venv"
DAEMON_PORT="8765"
HEALTH_TIMEOUT="10"

REPO_DIR=""

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

detect_repo_dir() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_DIR="$(cd "${script_dir}/.." && pwd)"
    if [[ ! -f "${REPO_DIR}/pyproject.toml" ]]; then
        die "could not locate studio-cli repo (no pyproject.toml at ${REPO_DIR})"
    fi
}

require_venv() {
    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        die "venv missing at ${VENV_DIR}; run install-server.sh first"
    fi
}

detect_tailscale_ip() {
    # The daemon binds to the Tailscale CGNAT interface only (Phase 1
    # hardening: bind_host must be loopback or 100.64.0.0/10). Localhost
    # can't reach it, so the /health poll has to target the Tailscale IP.
    local ts=""
    for cand in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
        if [[ -x "${cand}" ]]; then
            ts="${cand}"
            break
        fi
    done
    if [[ -z "${ts}" ]]; then
        die "tailscale binary not found; cannot detect bind IP for health check"
    fi
    local ip
    ip="$("${ts}" ip -4 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
    if [[ -z "${ip}" ]]; then
        die "tailscale ip -4 returned empty; is Tailscale up?"
    fi
    if [[ ! "${ip}" =~ ^100\. ]]; then
        die "tailscale IP ${ip} is not in the 100.x.x.x CGNAT range"
    fi
    printf '%s' "${ip}"
}

reinstall_package() {
    # Prefer uv when available (matches install-server.sh behavior).
    local uv_bin=""
    if command -v uv >/dev/null 2>&1; then
        uv_bin="$(command -v uv)"
    else
        for cand in /opt/homebrew/bin/uv /usr/local/bin/uv; do
            if [[ -x "${cand}" ]]; then
                uv_bin="${cand}"
                break
            fi
        done
    fi

    log "reinstalling studio-cli[collector] from ${REPO_DIR}"
    if [[ -n "${uv_bin}" ]]; then
        VIRTUAL_ENV="${VENV_DIR}" "${uv_bin}" pip install \
            --python "${VENV_DIR}/bin/python" \
            --reinstall \
            "${REPO_DIR}[collector]"
    else
        "${VENV_DIR}/bin/pip" install --upgrade --force-reinstall \
            "${REPO_DIR}[collector]"
    fi
}

kick_daemon() {
    log "launchctl kickstart -k system/${LABEL}"
    launchctl kickstart -k "system/${LABEL}"
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
    die "health check failed after ${HEALTH_TIMEOUT}s; check /var/log/studiod.err.log"
}

main() {
    require_darwin
    require_root
    detect_repo_dir
    log "repo dir: ${REPO_DIR}"
    require_venv
    local ip
    ip="$(detect_tailscale_ip)"
    log "tailscale ip: ${ip}"
    reinstall_package
    kick_daemon
    verify_health "${ip}"
    log "update complete"
}

main "$@"
