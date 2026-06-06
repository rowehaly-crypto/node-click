#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="ling-node-stack"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ENV_FILE="${SCRIPT_DIR}/deploy.env"
MENU_FILE="${SCRIPT_DIR}/menu.sh"
NPM_DIR="/npm"
NPM_COMPOSE_FILE="${NPM_DIR}/docker-compose.yml"
XBOARD_NODE_INSTALL_URL="${XBOARD_NODE_INSTALL_URL:-https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh}"

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

SUDO_CMD=()
PKG_MANAGER=""
OS_ID=""
OS_VERSION_ID=""
OS_PRETTY_NAME=""
DETECTED_SERVER_IP=""
COMPOSE_CMD=()

log() { printf '[%s] %s\n' "$PROJECT_NAME" "$*"; }
warn() { printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2; }
die() { warn "$*"; exit 1; }

run_privileged() {
  "${SUDO_CMD[@]}" "$@"
}

shell_quote() {
  printf '%q' "$1"
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

  die "当前不是 root，且系统没有 sudo。请切换到 root 后重新执行。"
}

load_os_release() {
  [ -f /etc/os-release ] || die "无法识别 Linux 发行版：缺少 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_PRETTY_NAME="${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"
  log "当前系统: ${OS_PRETTY_NAME}"

  case "$OS_ID" in
    debian|ubuntu)
      PKG_MANAGER="apt"
      ;;
    centos|rhel|rocky|almalinux|fedora)
      if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
      elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
      fi
      ;;
    *)
      if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
      elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
      elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
      else
        die "暂不支持自动安装依赖的系统: ${OS_PRETTY_NAME}"
      fi
      ;;
  esac
}

install_packages() {
  [ "$#" -gt 0 ] || return 0
  case "$PKG_MANAGER" in
    apt)
      run_privileged apt-get update
      run_privileged apt-get install -y "$@"
      ;;
    dnf)
      run_privileged dnf install -y "$@"
      ;;
    yum)
      run_privileged yum install -y "$@"
      ;;
    *)
      die "未找到可用的软件包管理器，无法安装: $*"
      ;;
  esac
}

package_available() {
  local package="$1"
  case "$PKG_MANAGER" in
    apt)
      run_privileged apt-get update
      apt-cache show "$package" >/dev/null 2>&1
      ;;
    dnf)
      dnf list "$package" >/dev/null 2>&1
      ;;
    yum)
      yum list "$package" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    log "已检测到 curl。"
    return 0
  fi

  log "未检测到 curl，开始安装。"
  install_packages curl ca-certificates
  command -v curl >/dev/null 2>&1 || die "curl 安装失败，请手动安装后重试。"
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

check_and_enable_bbr() {
  local kernel
  local current_cc
  kernel="$(uname -r | cut -d- -f1)"
  log "当前内核版本: ${kernel}"

  if ! version_ge "$kernel" "4.9"; then
    die "BBR 需要 Linux kernel >= 4.9，当前为 ${kernel}。请升级内核后重试。"
  fi

  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [ "$current_cc" = "bbr" ]; then
    log "当前拥塞控制算法已经是 bbr。"
    return 0
  fi

  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    run_privileged modprobe tcp_bbr 2>/dev/null || true
  fi

  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    die "当前内核未提供 bbr 拥塞控制算法，请升级内核后重试。"
  fi

  log "将拥塞控制算法永久设置为 bbr。"
  run_privileged mkdir -p /etc/sysctl.d
  run_privileged tee /etc/sysctl.d/99-ling-bbr.conf >/dev/null <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  run_privileged sysctl --system >/dev/null

  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  [ "$current_cc" = "bbr" ] || die "BBR 设置后未生效，当前算法: ${current_cc:-unknown}"
  log "BBR 已启用。"
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
    log "加载配置文件: ${DEPLOY_ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    . "$DEPLOY_ENV_FILE"
    set +a
  fi
  apply_defaults
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

prompt_port() {
  local label="$1"
  local current="$2"
  local value
  while true; do
    printf '%s [%s]: ' "$label" "$current" >&2
    read -r value || true
    value="${value:-$current}"
    if is_valid_port "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "请输入 1-65535 之间的端口号。"
  done
}

configure_interactively() {
  if [ -t 0 ]; then
    NPM_ADMIN_PORT="$(prompt_port "Nginx Proxy Manager 管理端口" "$NPM_ADMIN_PORT")"
  else
    log "非交互环境，NPM 管理端口使用默认/环境配置: ${NPM_ADMIN_PORT}"
  fi

  is_valid_port "$NPM_ADMIN_PORT" || die "NPM_ADMIN_PORT 无效: ${NPM_ADMIN_PORT}"
  [ "$NPM_ADMIN_PORT" != "$NPM_HTTP_PORT" ] || die "NPM 管理端口不能与 HTTP 端口相同: ${NPM_ADMIN_PORT}"
  [ "$NPM_ADMIN_PORT" != "$NPM_HTTPS_PORT" ] || die "NPM 管理端口不能与 HTTPS 端口相同: ${NPM_ADMIN_PORT}"
}

write_deploy_env() {
  local quoted_panel
  local quoted_token
  quoted_panel="$(shell_quote "$XBOARD_PANEL_URL")"
  quoted_token="$(shell_quote "$XBOARD_TOKEN")"
  run_privileged tee "$DEPLOY_ENV_FILE" >/dev/null <<EOF
# ling-node-stack local config
# 由 install.sh 自动生成/更新
NPM_HTTP_PORT=${NPM_HTTP_PORT}
NPM_HTTPS_PORT=${NPM_HTTPS_PORT}
NPM_ADMIN_PORT=${NPM_ADMIN_PORT}
XBOARD_PANEL_URL=${quoted_panel}
XBOARD_TOKEN=${quoted_token}
XBOARD_MACHINE_ID=${XBOARD_MACHINE_ID}
EOF
}

install_xboard_node() {
  log "开始安装 xboard-node。"
  curl -fsSL "$XBOARD_NODE_INSTALL_URL" | run_privileged bash -s -- \
    --mode machine \
    --panel "$XBOARD_PANEL_URL" \
    --token "$XBOARD_TOKEN" \
    --machine-id "$XBOARD_MACHINE_ID"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "已检测到 Docker。"
  else
    log "未检测到 Docker，开始安装。"
    case "$PKG_MANAGER" in
      apt)
        install_packages docker.io
        ;;
      dnf|yum)
        install_packages docker
        ;;
      *)
        die "无法为当前系统自动安装 Docker。"
        ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1; then
    run_privileged systemctl enable --now docker || true
  elif command -v service >/dev/null 2>&1; then
    run_privileged service docker start || true
  fi

  if run_privileged docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("${SUDO_CMD[@]}" docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("${SUDO_CMD[@]}" docker-compose)
  else
    case "$PKG_MANAGER" in
      apt)
        if package_available docker-compose-plugin; then
          install_packages docker-compose-plugin
        elif package_available docker-compose-v2; then
          install_packages docker-compose-v2
        elif package_available docker-compose; then
          install_packages docker-compose
        fi
        ;;
      dnf|yum)
        if package_available docker-compose-plugin; then
          install_packages docker-compose-plugin
        elif package_available docker-compose; then
          install_packages docker-compose
        fi
        ;;
    esac
  fi

  if run_privileged docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("${SUDO_CMD[@]}" docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("${SUDO_CMD[@]}" docker-compose)
  else
    die "未找到 docker compose / docker-compose。"
  fi

  run_privileged docker info >/dev/null 2>&1 || die "无法访问 Docker daemon，请确认 Docker 已启动。"
}

write_npm_compose() {
  run_privileged mkdir -p "$NPM_DIR/data" "$NPM_DIR/letsencrypt"
  run_privileged tee "$NPM_COMPOSE_FILE" >/dev/null <<EOF
services:
  app:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "${NPM_HTTP_PORT}:80"
      - "${NPM_HTTPS_PORT}:443"
      - "${NPM_ADMIN_PORT}:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF
}

install_npm() {
  log "写入 Nginx Proxy Manager Compose 配置: ${NPM_COMPOSE_FILE}"
  write_npm_compose
  log "启动 Nginx Proxy Manager。"
  (cd "$NPM_DIR" && "${COMPOSE_CMD[@]}" up -d)
}

install_menu_shortcut() {
  [ -f "$MENU_FILE" ] || die "未找到菜单脚本: ${MENU_FILE}"
  run_privileged chmod +x "$MENU_FILE"
  log "安装菜单快捷命令: ling"
  run_privileged tee /usr/local/bin/ling >/dev/null <<EOF
#!/usr/bin/env bash
exec bash "${MENU_FILE}" "\$@"
EOF
  run_privileged chmod +x /usr/local/bin/ling
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

first_nonempty_line() {
  awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit}'
}

resolve_server_ip() {
  local value
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    value="$(curl -4fsSL --max-time 5 "$url" 2>/dev/null | first_nonempty_line || true)"
    if is_ipv4 "$value"; then
      DETECTED_SERVER_IP="$value"
      return 0
    fi
  done

  value="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if is_ipv4 "$value"; then
    DETECTED_SERVER_IP="$value"
  else
    DETECTED_SERVER_IP="服务器IP"
  fi
}

open_local_ports() {
  local ports=("$@")
  local port

  if command -v ufw >/dev/null 2>&1; then
    for port in "${ports[@]}"; do
      run_privileged ufw allow "${port}/tcp" || true
    done
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for port in "${ports[@]}"; do
      run_privileged firewall-cmd --permanent --add-port="${port}/tcp" || true
    done
    run_privileged firewall-cmd --reload || true
    return 0
  fi

  warn "未检测到 UFW / firewalld，已跳过本机防火墙自动放行。"
  return 0
}

print_open_ports() {
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | awk 'NR==1 || /LISTEN/'
    return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null || true
    return 0
  fi
  warn "未找到 ss / netstat，无法列出当前监听端口。"
}

print_success() {
  resolve_server_ip
  echo
  echo "=========================================="
  echo "安装完成"
  echo "=========================================="
  echo "Nginx Proxy Manager: http://${DETECTED_SERVER_IP}:${NPM_ADMIN_PORT}"
  echo "默认账号: admin@example.com"
  echo "默认密码: changeme"
  echo
  echo "管理菜单: ling"
  echo "NPM Compose: ${NPM_COMPOSE_FILE}"
  echo
  echo "已尝试放行 TCP 端口: ${NPM_HTTP_PORT}, ${NPM_HTTPS_PORT}, ${NPM_ADMIN_PORT}"
  echo "如果使用云服务器，还需要在云平台安全组放行这些端口。"
  echo
  echo "当前监听端口:"
  print_open_ports || true
  echo "=========================================="
}

main() {
  init_privilege_helper
  load_os_release
  ensure_curl
  check_and_enable_bbr
  load_deploy_env
  configure_interactively
  write_deploy_env
  install_xboard_node
  ensure_docker
  install_npm
  install_menu_shortcut
  open_local_ports "$NPM_HTTP_PORT" "$NPM_HTTPS_PORT" "$NPM_ADMIN_PORT"
  print_success
}

main "$@"
