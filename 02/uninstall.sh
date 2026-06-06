#!/usr/bin/env bash
set -Eeuo pipefail

NPM_DIR="/npm"
COMPOSE_CMD=()
SUDO_CMD=()

log() { printf '[ling-uninstall] %s\n' "$*"; }
warn() { printf '[ling-uninstall][WARN] %s\n' "$*" >&2; }

init_privilege_helper() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO_CMD=(sudo)
  else
    warn "当前不是 root，且系统没有 sudo。部分卸载步骤可能失败。"
    SUDO_CMD=()
  fi
}

run_privileged() {
  "${SUDO_CMD[@]}" "$@"
}

resolve_compose() {
  if run_privileged docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("${SUDO_CMD[@]}" docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("${SUDO_CMD[@]}" docker-compose)
  else
    return 1
  fi
}

main() {
  init_privilege_helper

  if [ -f "$NPM_DIR/docker-compose.yml" ] && resolve_compose; then
    log "停止 Nginx Proxy Manager。"
    (cd "$NPM_DIR" && "${COMPOSE_CMD[@]}" down) || true
  fi

  if command -v xbctl >/dev/null 2>&1; then
    log "停止 xboard-node 服务。"
    run_privileged xbctl service stop || run_privileged xbctl stop || true
  fi

  run_privileged rm -f /usr/local/bin/ling
  log "已移除 ling 快捷命令。"
  warn "未删除 ${NPM_DIR} 数据目录；如需清理，请确认后手动删除。"
}

main "$@"
