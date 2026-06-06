#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# xboard-node + NPM 运维管理菜单 (ling 命令)
# ============================================================

PROJECT_NAME="ling-menu"
NPM_DIR="/npm"
XBOARD_NODE_INSTALL_SCRIPT="/etc/xboard-node/install.sh"
XBOARD_NODE_SERVICE="xboard-node"

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- 日志 ----------
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
title()   { echo -e "${BOLD}${CYAN}$*${NC}"; }

# ---------- 工具函数 ----------
pause() {
  echo ""
  read -r -p "按回车键返回菜单..."
}

need_root_or_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    return 0
  fi
  error "此操作需要 root 权限。请使用 root 用户运行，或安装 sudo。"
  return 1
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

fetch_public_ip() {
  local value
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    value="$(curl -4fsSL --max-time 5 "$url" 2>/dev/null | \
      awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit}' || true)"
    if is_ipv4 "$value"; then printf '%s' "$value"; return 0; fi
  done
  return 1
}

fetch_local_ip() {
  local value
  if command -v ip >/dev/null 2>&1; then
    value="$(ip route get 1.1.1.1 2>/dev/null | \
      awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
    if is_ipv4 "$value"; then printf '%s' "$value"; return 0; fi
  fi
  value="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if is_ipv4 "$value"; then printf '%s' "$value"; return 0; fi
  return 1
}

detect_ip() {
  local ip
  ip="$(fetch_public_ip || true)"
  if is_ipv4 "$ip"; then echo "$ip"; return 0; fi
  ip="$(fetch_local_ip || true)"
  if is_ipv4 "$ip"; then echo "$ip"; return 0; fi
  echo "你的服务器IP"
}

get_npm_port() {
  # 从 docker-compose.yml 中解析 NPM 管理端口
  if [ -f "${NPM_DIR}/docker-compose.yml" ]; then
    grep -E "^[[:space:]]*-[[:space:]]*'[0-9]+:81'" "${NPM_DIR}/docker-compose.yml" 2>/dev/null | \
      head -1 | sed -E "s/.*'([0-9]+):81'.*/\1/" || echo "81"
  elif [ -f "${NPM_DIR}/compose.yaml" ]; then
    grep -E "^[[:space:]]*-[[:space:]]*\"?[0-9]+:81\"?" "${NPM_DIR}/compose.yaml" 2>/dev/null | \
      head -1 | sed -E 's/.*"([0-9]+):81".*/\1/' || echo "81"
  else
    echo "81"
  fi
}

check_xbctl() {
  if command -v xbctl >/dev/null 2>&1; then
    return 0
  fi
  if [ -x /usr/local/bin/xbctl ]; then
    export PATH="/usr/local/bin:$PATH"
    return 0
  fi
  if [ -x /usr/bin/xbctl ]; then
    export PATH="/usr/bin:$PATH"
    return 0
  fi
  return 1
}

check_compose() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

run_compose() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$NPM_DIR" && run_privileged docker compose "$@")
  else
    (cd "$NPM_DIR" && run_privileged docker-compose "$@")
  fi
}

# ============================================================
# Menu Functions
# ============================================================

# 1. 查看 xboard node 服务状态
menu_status() {
  echo ""
  title "══════════════════════════════════════════"
  title "  xboard-node 服务状态"
  title "══════════════════════════════════════════"
  echo ""

  # 使用 ss 查看相关端口
  echo -e "${BOLD}📡 监听端口 (xboard / sing-box / xray):${NC}"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -E 'xboard|sing-box|xray' || echo "  未检测到相关进程。"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | grep -E 'xboard|sing-box|xray' || echo "  未检测到相关进程。"
  else
    warn "ss / netstat 均不可用，无法检测端口。"
  fi

  echo ""
  echo -e "${BOLD}🔧 systemd 服务状态:${NC}"
  if command -v systemctl >/dev/null 2>&1; then
    local state active enabled
    state=$(systemctl show "$XBOARD_NODE_SERVICE" --property LoadState --value 2>/dev/null || echo "not-found")
    if [ "$state" = "not-found" ] || [ -z "$state" ]; then
      warn "xboard-node 服务未安装或不存在。"
    else
      active=$(systemctl is-active "$XBOARD_NODE_SERVICE" 2>/dev/null || echo "unknown")
      enabled=$(systemctl is-enabled "$XBOARD_NODE_SERVICE" 2>/dev/null || echo "unknown")
      echo "  LoadState:  ${state}"
      echo "  Active:     ${active}"
      echo "  Enabled:    ${enabled}"
      echo ""
      systemctl status "$XBOARD_NODE_SERVICE" --lines=10 --no-pager 2>/dev/null || true
    fi
  else
    warn "systemctl 不可用。"
  fi

  echo ""
  echo -e "${BOLD}📋 xbctl 实例信息:${NC}"
  if check_xbctl; then
    xbctl list 2>/dev/null || echo "  无法获取实例列表。"
  else
    warn "xbctl 未找到。请检查 xboard-node 是否正确安装。"
  fi
}

# 2. 启动 xboard node 服务
menu_xb_start() {
  echo ""
  title "══════════════════════════════════════════"
  title "  启动 xboard-node 服务"
  title "══════════════════════════════════════════"
  echo ""

  if ! need_root_or_sudo; then return 1; fi

  local started=0

  # 尝试 xbctl start
  if check_xbctl; then
    info "执行: xbctl start"
    if run_privileged xbctl start 2>/dev/null; then
      success "xbctl start 执行成功。"
      started=1
    else
      warn "xbctl start 执行失败（可能已启动或配置未完成）。"
    fi
  fi

  # 尝试 systemd service start
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl show "$XBOARD_NODE_SERVICE" --property LoadState --value 2>/dev/null | grep -qv "not-found"; then
      info "执行: systemctl start ${XBOARD_NODE_SERVICE}"
      run_privileged systemctl start "$XBOARD_NODE_SERVICE" 2>/dev/null && {
        success "systemctl start 执行成功。"
        started=1
      } || warn "systemctl start 执行失败。"
    fi
  fi

  if check_xbctl; then
    info "执行: xbctl service start"
    run_privileged xbctl service start 2>/dev/null && {
      success "xbctl service start 执行成功。"
      started=1
    } || warn "xbctl service start 执行失败。"
  fi

  if [ "$started" -eq 0 ]; then
    warn "xboard-node 可能已经启动，或者安装不完整。"
    warn "请先确认已正确绑定 --panel 和 --token（菜单第 7 项）。"
  fi
}

# 3. 启动 Nginx Proxy Manager
menu_npm_start() {
  echo ""
  title "══════════════════════════════════════════"
  title "  启动 Nginx Proxy Manager"
  title "══════════════════════════════════════════"
  echo ""

  if ! need_root_or_sudo; then return 1; fi

  if [ ! -f "${NPM_DIR}/docker-compose.yml" ] && [ ! -f "${NPM_DIR}/compose.yaml" ]; then
    error "未找到 NPM 配置文件: ${NPM_DIR}/docker-compose.yml"
    error "请先运行 install.sh 完成 NPM 安装。"
    return 1
  fi

  if ! check_compose; then
    error "Docker Compose 不可用。"
    return 1
  fi

  info "启动 Nginx Proxy Manager..."
  run_compose up -d
  success "Nginx Proxy Manager 已启动。"

  local npm_port
  npm_port=$(get_npm_port)
  echo "  管理后台: http://$(detect_ip):${npm_port}"
}

# 4. 重启 xboard node 服务
menu_xb_restart() {
  echo ""
  title "══════════════════════════════════════════"
  title "  重启 xboard-node 服务"
  title "══════════════════════════════════════════"
  echo ""

  if ! need_root_or_sudo; then return 1; fi

  local done_restart=0

  # xbctl restart
  if check_xbctl; then
    info "执行: xbctl restart"
    if run_privileged xbctl restart 2>/dev/null; then
      success "xbctl restart 执行成功。"
      done_restart=1
    else
      warn "xbctl restart 失败。"
    fi
  fi

  # systemd restart
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl show "$XBOARD_NODE_SERVICE" --property LoadState --value 2>/dev/null | grep -qv "not-found"; then
      info "执行: systemctl restart ${XBOARD_NODE_SERVICE}"
      run_privileged systemctl restart "$XBOARD_NODE_SERVICE" 2>/dev/null && {
        success "systemctl restart ${XBOARD_NODE_SERVICE} 成功。"
        done_restart=1
      } || warn "systemctl restart 失败。"
    fi
  fi

  # xbctl service restart
  if check_xbctl; then
    info "执行: xbctl service restart"
    run_privileged xbctl service restart 2>/dev/null && {
      success "xbctl service restart 执行成功。"
      done_restart=1
    } || warn "xbctl service restart 失败。"
  fi

  if [ "$done_restart" -eq 0 ]; then
    error "xboard-node 重启失败。请检查服务状态。"
  fi
}

# 5. 重启 Nginx Proxy Manager
menu_npm_restart() {
  echo ""
  title "══════════════════════════════════════════"
  title "  重启 Nginx Proxy Manager"
  title "══════════════════════════════════════════"
  echo ""

  if ! need_root_or_sudo; then return 1; fi

  if [ ! -f "${NPM_DIR}/docker-compose.yml" ] && [ ! -f "${NPM_DIR}/compose.yaml" ]; then
    error "未找到 NPM 配置文件。"
    return 1
  fi

  if ! check_compose; then
    error "Docker Compose 不可用。"
    return 1
  fi

  info "重启 Nginx Proxy Manager..."
  run_compose restart
  success "Nginx Proxy Manager 已重启。"

  local npm_port
  npm_port=$(get_npm_port)
  echo "  管理后台: http://$(detect_ip):${npm_port}"
}

# 6. 查看 Nginx Proxy Manager 登录地址
menu_npm_info() {
  echo ""
  title "══════════════════════════════════════════"
  title "  Nginx Proxy Manager 登录信息"
  title "══════════════════════════════════════════"
  echo ""

  local server_ip npm_port
  server_ip=$(detect_ip)
  npm_port=$(get_npm_port)

  echo -e "  ${BOLD}管理后台地址:${NC}"
  echo -e "    ${GREEN}http://${server_ip}:${npm_port}${NC}"
  echo ""
  echo -e "  ${BOLD}默认登录凭据:${NC}"
  echo "    邮箱: admin@example.com"
  echo "    密码: changeme"
  echo ""
  echo -e "  ${YELLOW}⚠️  首次登录后会要求修改邮箱和密码。${NC}"
  echo ""
  echo -e "  ${BOLD}Docker 状态:${NC}"

  if check_compose; then
    run_compose ps 2>/dev/null || warn "无法获取 NPM 容器状态。"
  else
    warn "Docker Compose 不可用。"
  fi
}

# 7. 为 xboard node 绑定 --panel 和 --token
menu_bind_panel_token() {
  echo ""
  title "══════════════════════════════════════════"
  title "  绑定 xboard-node 的 Panel 和 Token"
  title "══════════════════════════════════════════"
  echo ""

  if ! need_root_or_sudo; then return 1; fi

  local panel_url token machine_id

  # 读取当前配置（如果存在）
  if [ -f /etc/xboard-node/config.yml ]; then
    echo -e "${BLUE}当前配置:${NC}"
    echo "──────────────────────────────────────"
    # 尝试从 config.yml 提取 panel_url
    local current_panel
    current_panel=$(grep -E '^[[:space:]]*panel_url:' /etc/xboard-node/config.yml 2>/dev/null | \
      awk '{print $2}' | tr -d '"'"'" || echo "未设置")
    echo "  当前 Panel: ${current_panel}"
    echo "──────────────────────────────────────"
    echo ""
  fi

  # 输入新的 panel URL
  read -r -p "请输入 Panel 地址 (例: https://panel.yourdomain.com): " panel_url
  if [ -z "$panel_url" ]; then
    warn "Panel 地址不能为空，已取消。"
    return 1
  fi

  # 输入新的 token
  read -r -p "请输入通信 Token: " token
  if [ -z "$token" ]; then
    warn "Token 不能为空，已取消。"
    return 1
  fi

  # 输入 machine-id
  read -r -p "请输入 Machine ID [1]: " machine_id
  machine_id="${machine_id:-1}"

  echo ""
  echo "即将使用以下参数绑定:"
  echo "  Panel:      ${panel_url}"
  echo "  Token:      ${token:0:8}****"
  echo "  Machine ID: ${machine_id}"
  echo ""

  read -r -p "确认绑定？[y/N]: " confirm
  case "$confirm" in
    y|Y) ;;
    *) info "已取消。"; return 0 ;;
  esac

  echo ""

  # 方法 1: 使用 xbctl config init (如果支持)
  local bound=0
  if check_xbctl; then
    info "尝试通过 xbctl config init 更新配置..."
    if xbctl config init \
      --mode machine \
      --panel-url "$panel_url" \
      --token "$token" \
      --node-id "$machine_id" \
      --config /etc/xboard-node/config.yml 2>/dev/null; then
      success "配置已通过 xbctl 更新。"
      bound=1
    else
      warn "xbctl config init 失败，尝试其他方法..."
    fi
  fi

  # 方法 2: 重新运行安装脚本
  if [ "$bound" -eq 0 ] && [ -f "$XBOARD_NODE_INSTALL_SCRIPT" ]; then
    info "通过安装脚本重新配置..."
    if run_privileged bash "$XBOARD_NODE_INSTALL_SCRIPT" \
      --mode machine \
      --panel "$panel_url" \
      --token "$token" \
      --machine-id "$machine_id" 2>/dev/null; then
      success "配置已通过安装脚本更新。"
      bound=1
    else
      error "安装脚本配置失败。"
    fi
  fi

  # 方法 3: 直接从 URL 重新下载安装脚本
  if [ "$bound" -eq 0 ]; then
    info "从远程重新下载安装脚本..."
    if curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | \
      run_privileged bash -s -- \
        --mode machine \
        --panel "$panel_url" \
        --token "$token" \
        --machine-id "$machine_id"; then
      success "配置已通过远程脚本更新。"
      bound=1
    else
      error "远程脚本配置失败。"
    fi
  fi

  if [ "$bound" -eq 0 ]; then
    error "所有绑定方法均失败。请检查网络连接和权限后重试。"
    return 1
  fi

  # 重启服务使配置生效
  echo ""
  info "重启 xboard-node 服务使配置生效..."
  if check_xbctl; then
    run_privileged xbctl restart 2>/dev/null || true
  fi
  if command -v systemctl >/dev/null 2>&1; then
    run_privileged systemctl restart "$XBOARD_NODE_SERVICE" 2>/dev/null || true
  fi

  success "绑定完成！xboard-node 将使用新的 Panel 和 Token 连接。"
  echo ""
  info "可以用以下命令验证:"
  echo "  xbctl list"
  echo "  systemctl status ${XBOARD_NODE_SERVICE}"
}

# 8. 查看端口放行状态
menu_port_check() {
  echo ""
  title "══════════════════════════════════════════"
  title "  查看端口状态"
  title "══════════════════════════════════════════"
  echo ""

  local port
  read -r -p "请输入要检查的端口号: " port

  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    error "无效的端口号: $port"
    return 1
  fi

  echo ""
  echo -e "${BOLD}检查端口 ${port}:${NC}"
  echo ""

  # 1. 检查端口是否在监听
  echo -e "${CYAN}[1] 监听状态:${NC}"
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnp 2>/dev/null | grep -q ":${port}\b"; then
      success "端口 ${port} 正在监听:"
      ss -tlnp 2>/dev/null | grep ":${port}\b" | while read -r line; do
        echo "  $line"
      done
    else
      warn "端口 ${port} 未在监听。"
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tlnp 2>/dev/null | grep -q ":${port}\b"; then
      success "端口 ${port} 正在监听:"
      netstat -tlnp 2>/dev/null | grep ":${port}\b" | while read -r line; do
        echo "  $line"
      done
    else
      warn "端口 ${port} 未在监听。"
    fi
  fi

  echo ""

  # 2. 检查本机防火墙状态
  echo -e "${CYAN}[2] 本机防火墙状态:${NC}"
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "${port}/tcp"; then
      success "UFW 已放行 ${port}/tcp:"
      ufw status 2>/dev/null | grep "${port}/tcp" | while read -r line; do
        echo "  $line"
      done
    else
      warn "UFW 未放行 ${port}/tcp。"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp"; then
      success "firewalld 已放行 ${port}/tcp。"
    else
      warn "firewalld 未放行 ${port}/tcp。"
    fi
  elif command -v iptables >/dev/null 2>&1; then
    if run_privileged iptables -L INPUT -n 2>/dev/null | grep -q "dpt:${port}\b"; then
      success "iptables 中存在端口 ${port} 的规则。"
    else
      warn "iptables 中未找到端口 ${port} 的规则。"
    fi
  else
    warn "未检测到可管理的防火墙（UFW / firewalld / iptables）。"
  fi

  echo ""

  # 3. 尝试本地连接测试
  echo -e "${CYAN}[3] 本地连通性测试:${NC}"
  if timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    success "端口 ${port} 本地可连接。"
  else
    warn "端口 ${port} 本地不可连接。"
  fi

  echo ""
  info "如果本机可访问但公网不可达，请检查云平台安全组/防火墙设置。"
}

# 9. 放行端口
menu_port_open() {
  echo ""
  title "══════════════════════════════════════════"
  title "  放行端口"
  title "══════════════════════════════════════════"
  echo ""

  if ! need_root_or_sudo; then return 1; fi

  local port
  read -r -p "请输入要放行的端口号: " port

  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    error "无效的端口号: $port"
    return 1
  fi

  echo ""

  # 尝试 UFW
  if command -v ufw >/dev/null 2>&1; then
    run_privileged ufw allow "${port}/tcp" 2>/dev/null && \
      success "UFW 已放行 ${port}/tcp。"
    echo ""
    run_privileged ufw status verbose 2>/dev/null | grep "${port}" || true
    return 0
  fi

  # 尝试 firewalld
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    run_privileged firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null && \
      success "firewalld 规则已添加。"
    run_privileged firewall-cmd --reload 2>/dev/null && \
      success "firewalld 已重载。"
    echo ""
    run_privileged firewall-cmd --list-ports 2>/dev/null || true
    return 0
  fi

  # 尝试 iptables
  if command -v iptables >/dev/null 2>&1; then
    run_privileged iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && \
      success "iptables 规则已添加: ACCEPT tcp/${port}。"
    warn "注意: iptables 规则重启后可能丢失。建议安装 UFW: apt-get install -y ufw"
    return 0
  fi

  error "未找到可管理的防火墙。请手动放行端口 ${port}。"
  error "Debian/Ubuntu 可安装 UFW: apt-get install -y ufw"
}

# ============================================================
# 显示菜单
# ============================================================
show_menu() {
  clear
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}       ${BOLD}xboard-node 运维管理菜单${NC}          ${CYAN}║${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}1.${NC} 查看 xboard-node 服务状态           ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}2.${NC} 启动 xboard-node 服务               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}3.${NC} 启动 Nginx Proxy Manager            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}4.${NC} 重启 xboard-node 服务               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}5.${NC} 重启 Nginx Proxy Manager            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}6.${NC} 查看 NPM 登录地址                   ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}7.${NC} 绑定 Panel 和 Token                 ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}8.${NC} 查看端口放行状态                    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}9.${NC} 放行端口                            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${RED}0.${NC} 退出菜单                            ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo ""

  local npm_port server_ip
  npm_port=$(get_npm_port)
  server_ip=$(detect_ip)

  echo -e "  ${BOLD}快捷信息:${NC}"
  echo -e "  NPM 后台: ${GREEN}http://${server_ip}:${npm_port}${NC}"
  if command -v systemctl >/dev/null 2>&1; then
    echo -n "  xboard-node: "
    systemctl is-active "$XBOARD_NODE_SERVICE" 2>/dev/null && \
      echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}"
  fi
  echo ""
}

# ============================================================
# 主循环
# ============================================================
main() {
  # 检查基本依赖
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker 未安装或不在 PATH 中，部分功能不可用。"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl 未安装，部分功能（IP检测、远程安装）不可用。"
  fi

  while true; do
    show_menu
    read -r -p "请输入选项 [0-9]: " choice
    echo ""

    case "$choice" in
      1) menu_status;     pause ;;
      2) menu_xb_start;   pause ;;
      3) menu_npm_start;  pause ;;
      4) menu_xb_restart; pause ;;
      5) menu_npm_restart; pause ;;
      6) menu_npm_info;   pause ;;
      7) menu_bind_panel_token; pause ;;
      8) menu_port_check; pause ;;
      9) menu_port_open;  pause ;;
      0)
        success "已退出管理菜单。下次输入 ling 即可重新进入。"
        exit 0
        ;;
      *)
        error "无效选项，请输入 0-9。"
        sleep 1
        ;;
    esac
  done
}

main "$@"
