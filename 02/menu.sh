#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="ling-menu"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ENV_FILE="${SCRIPT_DIR}/deploy.env"
NPM_DIR="/npm"
NPM_COMPOSE_FILE="${NPM_DIR}/docker-compose.yml"

DEFAULT_NPM_HTTP_PORT=80
DEFAULT_NPM_HTTPS_PORT=443
DEFAULT_NPM_ADMIN_PORT=81
DEFAULT_XBOARD_PANEL_URL="https://panel.example.com"
DEFAULT_XBOARD_TOKEN="TOKEN"
DEFAULT_XBOARD_MACHINE_ID=1

NPM_HTTP_PORT="${NPM_HTTP_PORT:-}"
NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-}"
NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-}"
XBOARD_PANEL_URL="${XBOARD_PANEL_URL:-}"
XBOARD_TOKEN="${XBOARD_TOKEN:-}"
XBOARD_MACHINE_ID="${XBOARD_MACHINE_ID:-}"
COMPOSE_CMD=()
SUDO_CMD=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

pause() {
  read -r -p "按回车继续..." _ || true
}

init_privilege_helper() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=()
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    SUDO_CMD=(sudo)
    return 0
  fi

  error "当前不是 root，且系统没有 sudo。请切换到 root 后运行 ling。"
  exit 1
}

run_privileged() {
  "${SUDO_CMD[@]}" "$@"
}

shell_quote() {
  printf '%q' "$1"
}

apply_defaults() {
  NPM_HTTP_PORT="${NPM_HTTP_PORT:-${DEFAULT_NPM_HTTP_PORT}}"
  NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-${DEFAULT_NPM_HTTPS_PORT}}"
  NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-${DEFAULT_NPM_ADMIN_PORT}}"
  XBOARD_PANEL_URL="${XBOARD_PANEL_URL:-${DEFAULT_XBOARD_PANEL_URL}}"
  XBOARD_TOKEN="${XBOARD_TOKEN:-${DEFAULT_XBOARD_TOKEN}}"
  XBOARD_MACHINE_ID="${XBOARD_MACHINE_ID:-${DEFAULT_XBOARD_MACHINE_ID}}"
}

load_deploy_env() {
  if [ -f "$DEPLOY_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$DEPLOY_ENV_FILE"
    set +a
  fi
  apply_defaults
}

save_deploy_env() {
  local quoted_panel
  local quoted_token
  quoted_panel="$(shell_quote "$XBOARD_PANEL_URL")"
  quoted_token="$(shell_quote "$XBOARD_TOKEN")"
  run_privileged tee "$DEPLOY_ENV_FILE" >/dev/null <<EOF
# ling-node-stack local config
# 由 menu.sh 自动生成/更新
NPM_HTTP_PORT=${NPM_HTTP_PORT}
NPM_HTTPS_PORT=${NPM_HTTPS_PORT}
NPM_ADMIN_PORT=${NPM_ADMIN_PORT}
XBOARD_PANEL_URL=${quoted_panel}
XBOARD_TOKEN=${quoted_token}
XBOARD_MACHINE_ID=${XBOARD_MACHINE_ID}
EOF
}

ensure_compose_ready() {
  if run_privileged docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("${SUDO_CMD[@]}" docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("${SUDO_CMD[@]}" docker-compose)
  else
    error "未找到 docker compose / docker-compose。"
    return 1
  fi

  run_privileged docker info >/dev/null 2>&1 || {
    error "无法访问 Docker daemon。"
    return 1
  }
}

run_npm_compose() {
  [ -f "$NPM_COMPOSE_FILE" ] || {
    warn "未找到 ${NPM_COMPOSE_FILE}，请先执行安装。"
    return 1
  }
  ensure_compose_ready || return 1
  (cd "$NPM_DIR" && "${COMPOSE_CMD[@]}" "$@")
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

first_nonempty_line() {
  awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit}'
}

resolve_server_ip() {
  local value
  if command -v curl >/dev/null 2>&1; then
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
      value="$(curl -4fsSL --max-time 5 "$url" 2>/dev/null | first_nonempty_line || true)"
      if is_ipv4 "$value"; then
        printf '%s' "$value"
        return 0
      fi
    done
  fi

  value="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if is_ipv4 "$value"; then
    printf '%s' "$value"
  else
    printf '%s' "服务器IP"
  fi
}

show_xboard_node_status() {
  info "xboard node 端口监听状态"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp | grep -E 'xboard|sing-box|xray' || warn "未发现 xboard / sing-box / xray 监听进程。"
  else
    warn "系统缺少 ss 命令。"
  fi

  echo
  if command -v xbctl >/dev/null 2>&1; then
    info "xbctl service status"
    run_privileged xbctl service status || true
  else
    warn "未找到 xbctl。"
  fi
}

start_xboard_node() {
  command -v xbctl >/dev/null 2>&1 || {
    error "未找到 xbctl，请先安装 xboard-node。"
    return 1
  }

  run_privileged xbctl start || true
  run_privileged xbctl service start || true
  success "已执行 xboard node 启动命令。"
}

restart_xboard_node() {
  command -v xbctl >/dev/null 2>&1 || {
    error "未找到 xbctl，请先安装 xboard-node。"
    return 1
  }

  run_privileged xbctl restart || true
  run_privileged xbctl service restart || true
  success "已执行 xboard node 重启命令。"
}

start_npm() {
  if run_npm_compose up -d; then
    success "Nginx Proxy Manager 已启动。"
  else
    return 1
  fi
}

restart_npm() {
  if run_npm_compose restart; then
    success "Nginx Proxy Manager 已重启。"
  else
    return 1
  fi
}

show_npm_login() {
  local ip
  load_deploy_env
  ip="$(resolve_server_ip)"
  echo "Nginx Proxy Manager 登录地址: http://${ip}:${NPM_ADMIN_PORT}"
  echo "默认账号: admin@example.com"
  echo "默认密码: changeme"
}

bind_xboard_node() {
  local panel
  local token
  local machine_id

  command -v xbctl >/dev/null 2>&1 || {
    error "未找到 xbctl，请先安装 xboard-node。"
    return 1
  }

  load_deploy_env
  read -r -p "请输入 panel 地址 [${XBOARD_PANEL_URL}]: " panel
  panel="${panel:-$XBOARD_PANEL_URL}"
  read -r -p "请输入 token [${XBOARD_TOKEN}]: " token
  token="${token:-$XBOARD_TOKEN}"
  read -r -p "请输入 machine-id [${XBOARD_MACHINE_ID}]: " machine_id
  machine_id="${machine_id:-$XBOARD_MACHINE_ID}"

  [ -n "$panel" ] || {
    warn "panel 地址不能为空。"
    return 1
  }
  [ -n "$token" ] || {
    warn "token 不能为空。"
    return 1
  }
  [[ "$machine_id" =~ ^[0-9]+$ ]] || {
    warn "machine-id 必须是数字。"
    return 1
  }

  if run_privileged xbctl bind add-machine --panel "$panel" --token "$token" --machine-id "$machine_id"; then
    :
  else
    warn "使用 --panel 失败，尝试兼容参数 --panel-url。"
    run_privileged xbctl bind add-machine --panel-url "$panel" --token "$token" --machine-id "$machine_id" || return 1
  fi

  XBOARD_PANEL_URL="$panel"
  XBOARD_TOKEN="$token"
  XBOARD_MACHINE_ID="$machine_id"
  save_deploy_env
  restart_xboard_node || true
  success "xboard node 绑定配置已更新。"
}

show_port_status() {
  local port
  read -r -p "请输入要检查的端口: " port
  is_valid_port "$port" || {
    warn "端口无效: ${port}"
    return 1
  }

  info "监听状态"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp | grep -E ":${port}\\b" || warn "未发现 ${port}/tcp 正在监听。"
  else
    warn "系统缺少 ss 命令。"
  fi

  echo
  info "本机防火墙状态"
  if command -v ufw >/dev/null 2>&1; then
    ufw status numbered | grep -E "${port}/tcp|${port}" || warn "UFW 中未看到 ${port}/tcp 规则。"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --list-ports | tr ' ' '\n' | grep -E "^${port}/tcp$" || warn "firewalld 中未看到 ${port}/tcp 规则。"
  else
    warn "未检测到 UFW / firewalld。云服务器还需检查云平台安全组。"
  fi
}

open_port() {
  local port
  read -r -p "请输入要放行的端口: " port
  is_valid_port "$port" || {
    warn "端口无效: ${port}"
    return 1
  }

  if command -v ufw >/dev/null 2>&1; then
    run_privileged ufw allow "${port}/tcp"
    success "已通过 UFW 放行 ${port}/tcp。"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    run_privileged firewall-cmd --permanent --add-port="${port}/tcp"
    run_privileged firewall-cmd --reload
    success "已通过 firewalld 放行 ${port}/tcp。"
  else
    warn "未检测到 UFW / firewalld，请手动放行 ${port}/tcp。云服务器还需检查云平台安全组。"
  fi
}

show_menu() {
  clear 2>/dev/null || true
  echo "=========================================="
  echo "          ling 运维管理菜单"
  echo "=========================================="
  echo "1. 查看 xboard node 服务状态"
  echo "2. 启动 xboard node 服务"
  echo "3. 启动 nginx-proxy-manager"
  echo "4. 重启 xboard node 服务"
  echo "5. 重启 nginx-proxy-manager"
  echo "6. 查看 nginx-proxy-manager 登录地址"
  echo "7. 为 xboard node 绑定 panel 和 token"
  echo "8. 查看端口放行状态"
  echo "9. 放行一个端口"
  echo "0. 退出菜单"
  echo "=========================================="
}

main() {
  init_privilege_helper
  load_deploy_env

  while true; do
    show_menu
    read -r -p "请输入选项: " choice
    echo
    case "$choice" in
      1) show_xboard_node_status || true; pause ;;
      2) start_xboard_node || true; pause ;;
      3) start_npm || true; pause ;;
      4) restart_xboard_node || true; pause ;;
      5) restart_npm || true; pause ;;
      6) show_npm_login || true; pause ;;
      7) bind_xboard_node || true; pause ;;
      8) show_port_status || true; pause ;;
      9) open_port || true; pause ;;
      0) success "已退出。"; exit 0 ;;
      *) warn "无效选项，请重新输入。"; pause ;;
    esac
  done
}

main "$@"
