#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NPM_DIR="/npm"
COMPOSE_CMD=()
SUDO_CMD=()

log() { printf '[ling-update] %s\n' "$*"; }
warn() { printf '[ling-update][WARN] %s\n' "$*" >&2; }

init_privilege_helper() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO_CMD=(sudo)
  else
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
    warn "未找到 docker compose / docker-compose，跳过 NPM 更新。"
    return 1
  fi
}

main() {
  init_privilege_helper
  chmod +x "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/menu.sh" "$SCRIPT_DIR/update.sh" "$SCRIPT_DIR/uninstall.sh" 2>/dev/null || true

  if command -v xbctl >/dev/null 2>&1; then
    log "尝试更新 xboard-node。"
    run_privileged xbctl update || true
  else
    warn "未找到 xbctl，跳过 xboard-node 更新。"
  fi

  if [ -f "$NPM_DIR/docker-compose.yml" ] && resolve_compose; then
    log "拉取并重启 Nginx Proxy Manager。"
    (cd "$NPM_DIR" && "${COMPOSE_CMD[@]}" pull && "${COMPOSE_CMD[@]}" up -d)
  fi

  log "更新流程完成。"
}

main "$@"
