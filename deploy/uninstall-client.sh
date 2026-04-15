#!/usr/bin/env bash
# uninstall-client.sh -- remove the studio CLI from the MacBook.

set -euo pipefail

PROG="uninstall-client.sh"
CONFIG_DIR="${HOME}/.config/studio-cli"

PURGE_CONFIG="0"

print_usage() {
    cat <<EOF
Usage: bash ${PROG} [--purge-config] [--help]

Options:
  --purge-config   Also remove ${CONFIG_DIR} (config + token).
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
            --purge-config) PURGE_CONFIG="1"; shift ;;
            --help|-h) print_usage; exit 0 ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
    done
}

main() {
    parse_args "$@"
    if command -v uv >/dev/null 2>&1; then
        log "uv pip uninstall studio-cli"
        uv pip uninstall studio-cli || log "uv pip uninstall returned non-zero (continuing)"
    else
        log "uv not found; skipping package uninstall"
    fi

    if [[ "${PURGE_CONFIG}" == "1" ]]; then
        if [[ -d "${CONFIG_DIR}" ]]; then
            log "rm -rf ${CONFIG_DIR}"
            rm -rf "${CONFIG_DIR}"
        fi
    else
        log "preserving ${CONFIG_DIR} (pass --purge-config to remove)"
    fi

    log "uninstall complete"
    log "remember to remove the 'studio' shim from ~/.zshrc if you added one"
}

main "$@"
