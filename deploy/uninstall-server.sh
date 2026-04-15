#!/usr/bin/env bash
# uninstall-server.sh -- tear down the studiod launchd daemon.
#
# Run on the Mac Studio:
#
#   ssh macstudio
#   sudo bash ~/studio-cli/deploy/uninstall-server.sh
#
# By default this preserves /etc/studiod/token so you can reinstall
# without having to re-distribute the token to the MacBook. Pass
# --purge-token to also delete it.

set -euo pipefail

PROG="uninstall-server.sh"
LABEL="com.bosphorify.studiod"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
INSTALL_ROOT="/opt/studiod"
TOKEN_DIR="/etc/studiod"
TOKEN_FILE="${TOKEN_DIR}/token"
LOG_OUT="/var/log/studiod.out.log"
LOG_ERR="/var/log/studiod.err.log"

PURGE_TOKEN="0"
PURGE_LOGS="0"

print_usage() {
    cat <<EOF
Usage: sudo bash ${PROG} [--purge-token] [--purge-logs] [--help]

Options:
  --purge-token    Also delete ${TOKEN_FILE}.
  --purge-logs     Also delete ${LOG_OUT} and ${LOG_ERR}.
  --help, -h       Show this message.
EOF
}

log() {
    printf '[%s] %s\n' "${PROG}" "$*"
}

die() {
    printf '[%s] error: %s\n' "${PROG}" "$*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-token) PURGE_TOKEN="1"; shift ;;
            --purge-logs) PURGE_LOGS="1"; shift ;;
            --help|-h) print_usage; exit 0 ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
    done
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

stop_daemon() {
    if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
        log "launchctl bootout system/${LABEL}"
        launchctl bootout "system/${LABEL}" || log "bootout returned non-zero (continuing)"
    else
        log "${LABEL} is not loaded"
    fi
}

remove_files() {
    if [[ -f "${PLIST_PATH}" ]]; then
        log "rm ${PLIST_PATH}"
        rm -f "${PLIST_PATH}"
    fi
    if [[ -d "${INSTALL_ROOT}" ]]; then
        log "rm -rf ${INSTALL_ROOT}"
        rm -rf "${INSTALL_ROOT}"
    fi

    if [[ "${PURGE_TOKEN}" == "1" ]]; then
        if [[ -f "${TOKEN_FILE}" ]]; then
            log "rm ${TOKEN_FILE}"
            rm -f "${TOKEN_FILE}"
        fi
        if [[ -d "${TOKEN_DIR}" ]]; then
            rmdir "${TOKEN_DIR}" 2>/dev/null || true
        fi
    else
        log "preserving ${TOKEN_FILE} (pass --purge-token to remove)"
    fi

    if [[ "${PURGE_LOGS}" == "1" ]]; then
        rm -f "${LOG_OUT}" "${LOG_ERR}"
    fi
}

main() {
    parse_args "$@"
    require_darwin
    require_root
    stop_daemon
    remove_files
    log "uninstall complete"
}

main "$@"
