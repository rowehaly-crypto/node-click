#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xboard-node + NPM 卸载脚本
# ============================================================

PROJECT_NAME="xboard-node-one-click-uninstall"
NPM_DIR="/npm"
MENU_TARGET="/usr/local/bin/ling"
MENU_BACKUP="/usr/local/share/ling-menu.sh"
XBOARD_NODE_SERVICE="xboard-node"

# 默认不删除数据，传入 PURGE_DATA=1 时彻底删除
PURGE_DATA="${PURGE_DATA:-0}"

SUDO_CMD=()

# ---------- 日志 ----------
log()   { printf '[%s] %s\n' "$PROJECT_NAME" "$*"; }
warn()  { printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2; }
die()   { warn "$*"; exit 1; }

# ---------- 权限 ----------
init_privilege() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=()
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO_CMD=(sudo)
    return 0
  fi
  die "需要 root 权限。请切换到 root 用户后再执行。"
}

run_privileged() { "${SUDO_CMD[@]}" "$@"; }

# ---------- 停止并删除 NPM ----------
remove_npm() {
  log "处理 Nginx Proxy Manager..."

  if [ ! -d "$NPM_DIR" ]; then
    log "NPM 目录不存在，跳过。"
    return 0
  fi

  # 停止容器
  if [ -f "${NPM_DIR}/docker-compose.yml" ] || [ -f "${NPM_DIR}/compose.yaml" ]; then
    if docker compose version >/dev/null 2>&1; then
      (cd "$NPM_DIR" && run_privileged docker compose down 2>/dev/null || true)
    elif command -v docker-compose >/dev/null 2>&1; then
      (cd "$NPM_DIR" && run_privileged docker-compose down 2>/dev/null || true)
    else
      warn "docker compose 不可用，跳过容器停止。"
    fi
  fi

  # 删除 NPM 镜像
  if command -v docker >/dev/null 2>&1; then
    docker images jc21/nginx-proxy-manager -q 2>/dev/null | xargs -r docker rmi 2>/dev/null || true
  fi

  if [ "$PURGE_DATA" = "1" ]; then
    log "删除 NPM 数据和目录..."
    run_privileged rm -rf "$NPM_DIR"
    log "NPM 数据已彻底删除。"
  else
    log "保留 NPM 数据目录: $NPM_DIR"
    log "（如需彻底删除，请使用: PURGE_DATA=1 ./uninstall.sh）"
  fi
}

# ---------- 停止并删除 xboard-node ----------
remove_xboard_node() {
  log "处理 xboard-node..."

  # 停止服务
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl show "$XBOARD_NODE_SERVICE" --property LoadState --value 2>/dev/null | grep -qv "not-found"; then
      log "停止并禁用 xboard-node 服务..."
      run_privileged systemctl stop "$XBOARD_NODE_SERVICE" 2>/dev/null || true
      run_privileged systemctl disable "$XBOARD_NODE_SERVICE" 2>/dev/null || true
    fi
  fi

  if [ "$PURGE_DATA" = "1" ]; then
    log "删除 xboard-node 配置和数据..."
    # 删除配置文件目录
    run_privileged rm -rf /etc/xboard-node 2>/dev/null || true
    # 删除二进制文件
    run_privileged rm -f /usr/local/bin/xboard-node /usr/bin/xboard-node 2>/dev/null || true
    run_privileged rm -f /usr/local/bin/xbctl /usr/bin/xbctl 2>/dev/null || true
    # 删除服务文件
    run_privileged rm -f /etc/systemd/system/xboard-node.service 2>/dev/null || true
    run_privileged systemctl daemon-reload 2>/dev/null || true
    log "xboard-node 已彻底删除。"
  else
    log "保留 xboard-node 配置和数据。"
  fi
}

# ---------- 删除菜单 ----------
remove_menu() {
  log "移除管理菜单..."

  run_privileged rm -f "$MENU_TARGET" 2>/dev/null || true
  run_privileged rm -f "$MENU_BACKUP" 2>/dev/null || true

  log "ling 命令已移除。"
}

# ---------- 删除 BBR 配置 ----------
remove_bbr() {
  [ "$PURGE_DATA" = "1" ] || return 0

  log "还原 BBR 相关配置..."
  # 注意：我们只清理我们写入的持久化配置
  # 不主动恢复为非 BBR（用户可能之后还想用）

  local sysctl_file="/etc/sysctl.conf"
  if [ -f "$sysctl_file" ]; then
    run_privileged sed -i '/^net.core.default_qdisc=fq$/d' "$sysctl_file" 2>/dev/null || true
    run_privileged sed -i '/^net.ipv4.tcp_congestion_control=bbr$/d' "$sysctl_file" 2>/dev/null || true
  fi
  run_privileged rm -f /etc/modules-load.d/bbr.conf 2>/dev/null || true

  warn "BBR 持久化配置已清除。当前连接仍使用 BBR，重启后将恢复系统默认。"
}

# ---------- 确认 ----------
confirm_uninstall() {
  echo ""
  echo "============================================"
  echo "  ⚠️  卸载确认"
  echo "============================================"
  echo ""

  if [ "$PURGE_DATA" = "1" ]; then
    echo "  模式: 彻底卸载（删除所有数据）"
    echo "  将删除:"
    echo "    - Nginx Proxy Manager 容器及 /npm 目录"
    echo "    - xboard-node 服务及 /etc/xboard-node/ 配置"
    echo "    - xbctl 及 xboard-node 二进制文件"
    echo "    - ling 管理菜单"
    echo "    - BBR 持久化配置（当前连接不受影响）"
  else
    echo "  模式: 仅停止服务（保留数据）"
    echo "  将执行:"
    echo "    - 停止 Nginx Proxy Manager 容器"
    echo "    - 停止 xboard-node 服务"
    echo "    - 移除 ling 管理菜单"
    echo "  将保留:"
    echo "    - /npm 目录及 NPM 数据"
    echo "    - xboard-node 配置文件"
  fi

  echo ""
  read -r -p "确认执行卸载？[y/N]: " confirm
  case "$confirm" in
    y|Y) return 0 ;;
    *) echo "已取消卸载。"; exit 0 ;;
  esac
}

# ---------- 主流程 ----------
main() {
  init_privilege
  confirm_uninstall

  echo ""
  log "开始卸载..."

  remove_npm
  remove_xboard_node
  remove_menu
  remove_bbr

  echo ""
  if [ "$PURGE_DATA" = "1" ]; then
    log "彻底卸载完成。所有相关文件已删除。"
  else
    log "卸载完成（数据已保留）。"
    log "如需彻底删除所有数据，请执行: PURGE_DATA=1 bash $0"
  fi
}

main "$@"
