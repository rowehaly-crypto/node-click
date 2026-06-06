#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xboard-node + NPM 一键安装
# 用法: bash <(curl -fsSL https://.../01/install.sh)
# ============================================================

# --- 常量 ---------------------------------------------------
NPM_DIR="/npm"
XBOARD_NODE_URL="https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh"
MENU_BIN="/usr/local/bin/ling"
MENU_FILE="/usr/local/share/ling-menu.sh"
DEFAULT_NPM_PORT=81
GITHUB_BASE="https://raw.githubusercontent.com/rowehaly-crypto/node-click/main/01"

NPM_ADMIN_PORT=""
SUDO_CMD=()
COMPOSE_CMD=()

# --- 简洁日志 -----------------------------------------------
info()  { printf '  \033[0;34m[+]\033[0m %s\n' "$*"; }
warn()  { printf '  \033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()   { printf '  \033[0;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }
ok()    { printf '  \033[0;32m[V]\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1;36m[%s]\033[0m %s\n' "$1" "$2"; }

# --- 权限 ---------------------------------------------------
init_privilege() {
  if [ "$(id -u)" -eq 0 ]; then SUDO_CMD=(); return 0; fi
  if command -v sudo >/dev/null 2>&1; then SUDO_CMD=(sudo); return 0; fi
  # 极简 Debian 无 sudo
  if command -v apt-get >/dev/null 2>&1 && command -v su >/dev/null 2>&1; then
    su -c "apt-get update -qq && apt-get install -y sudo" 2>/dev/null || true
    if command -v sudo >/dev/null 2>&1; then SUDO_CMD=(sudo); return 0; fi
  fi
  err "需要 root 权限。请执行 su - 切换到 root 后重试。"
}
run() { "${SUDO_CMD[@]}" "$@"; }

# --- 工具函数 -----------------------------------------------
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
download_to() { curl -fsSL --connect-timeout 10 --retry 2 "$1" -o "$2" || err "下载失败: $1"; }

detect_ip() {
  local ip
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip=$(curl -4fsSL --max-time 5 "$url" 2>/dev/null | awk 'NF{print;exit}' || true)
    is_ipv4 "$ip" && { echo "$ip"; return 0; }
  done
  command -v hostname >/dev/null 2>&1 && { ip=$(hostname -I 2>/dev/null | awk '{print $1}'); is_ipv4 "$ip" && { echo "$ip"; return 0; }; }
  echo "服务器IP"
}

check_compose() {
  if docker compose version >/dev/null 2>&1; then COMPOSE_CMD=(docker compose); return 0; fi
  if command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD=(docker-compose); return 0; fi
  return 1
}
compose() { (cd "$NPM_DIR" && run "${COMPOSE_CMD[@]}" "$@"); }

# ============================================================
# Step: 系统检测
# ============================================================
do_system_check() {
  step "1/7" "系统检测"

  [ -f /etc/os-release ] || err "仅支持 Linux 系统。"
  . /etc/os-release 2>/dev/null || true
  info "${NAME:-Linux} ${VERSION_ID:-}"

  # curl
  if command -v curl >/dev/null 2>&1; then
    info "curl 已就绪"
  else
    info "安装 curl..."
    if command -v apt-get >/dev/null 2>&1; then
      run apt-get update -qq && run apt-get install -y curl
    elif command -v yum >/dev/null 2>&1; then
      run yum install -y curl
    elif command -v dnf >/dev/null 2>&1; then
      run dnf install -y curl
    else
      err "请先手动安装 curl"
    fi
    ok "curl 安装完成"
  fi
}

# ============================================================
# Step: BBR 拥堵控制
# ============================================================
do_bbr() {
  step "2/7" "BBR 拥堵控制"

  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

  if [ "$cc" = "bbr" ]; then
    info "BBR 已启用"
    return 0
  fi

  # 检查内核版本 >= 4.9
  local major minor
  major=$(uname -r | cut -d. -f1)
  minor=$(uname -r | cut -d. -f2)
  if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 9 ]; }; then
    err "内核版本过低 ($(uname -r))，BBR 需要 >= 4.9。请升级内核。"
  fi

  info "当前算法: $cc，开启 BBR..."
  run modprobe tcp_bbr 2>/dev/null || { warn "无法加载 tcp_bbr 模块，跳过 BBR"; return 0; }
  run mkdir -p /etc/modules-load.d
  echo "tcp_bbr" | run tee /etc/modules-load.d/bbr.conf >/dev/null
  run sysctl -w net.core.default_qdisc=fq >/dev/null
  run sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

  # 持久化
  local sf="/etc/sysctl.conf"
  grep -q "^net.core.default_qdisc" "$sf" 2>/dev/null \
    && run sed -i 's/^net.core.default_qdisc.*/net.core.default_qdisc=fq/' "$sf" \
    || echo "net.core.default_qdisc=fq" | run tee -a "$sf" >/dev/null
  grep -q "^net.ipv4.tcp_congestion_control" "$sf" 2>/dev/null \
    && run sed -i 's/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control=bbr/' "$sf" \
    || echo "net.ipv4.tcp_congestion_control=bbr" | run tee -a "$sf" >/dev/null
  run sysctl -p >/dev/null 2>&1 || true

  local new_cc
  new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  [ "$new_cc" = "bbr" ] && ok "BBR 已启用" || warn "BBR 状态: $new_cc，请手动检查"
}

# ============================================================
# Step: xboard-node
# ============================================================
do_xboard_node() {
  step "3/7" "xboard-node 节点"

  # 已安装则跳过（除非用户要求重装）
  if command -v xbctl >/dev/null 2>&1 || [ -x /usr/local/bin/xbctl ] || [ -x /usr/bin/xbctl ]; then
    info "xboard-node 已安装，跳过"
    export PATH="/usr/local/bin:/usr/bin:$PATH"
    return 0
  fi

  info "下载安装脚本..."
  local script
  script=$(curl -fsSL "$XBOARD_NODE_URL") || err "无法下载 xboard-node 安装脚本"

  info "执行安装（machine 模式）..."
  if [ "$(id -u)" -eq 0 ]; then
    echo "$script" | bash -s -- --mode machine --panel https://panel.example.com --token PLACEHOLDER --machine-id 1
  else
    echo "$script" | sudo bash -s -- --mode machine --panel https://panel.example.com --token PLACEHOLDER --machine-id 1
  fi

  export PATH="/usr/local/bin:/usr/bin:$PATH"
  command -v xbctl >/dev/null 2>&1 || [ -x /usr/local/bin/xbctl ] || [ -x /usr/bin/xbctl ] \
    || warn "xbctl 未找到，请检查 xboard-node 是否安装成功"

  ok "xboard-node 安装完成"
}

# ============================================================
# Step: Docker
# ============================================================
do_docker() {
  step "4/7" "Docker 环境"

  # Docker 已运行则跳过
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    info "Docker 已运行"
  else
    info "安装 Docker..."
    if command -v apt-get >/dev/null 2>&1; then
      curl -fsSL https://get.docker.com | run bash
    elif command -v yum >/dev/null 2>&1; then
      run yum install -y docker
    elif command -v dnf >/dev/null 2>&1; then
      run dnf install -y docker
    else
      err "无法自动安装 Docker"
    fi
    command -v systemctl >/dev/null 2>&1 && run systemctl enable --now docker 2>/dev/null || true
    command -v service >/dev/null 2>&1 && run service docker start 2>/dev/null || true
    docker info >/dev/null 2>&1 || err "Docker 无法启动"
    ok "Docker 安装完成"
  fi

  # Compose
  if check_compose; then
    info "Docker Compose 已就绪"
    return 0
  fi

  info "安装 Docker Compose 插件..."
  if command -v apt-get >/dev/null 2>&1; then
    run apt-get update -qq
    run apt-get install -y docker-compose-plugin 2>/dev/null || \
    run apt-get install -y docker-compose-v2 2>/dev/null || \
    run apt-get install -y docker-compose 2>/dev/null || \
    err "Compose 安装失败"
  fi
  check_compose || err "Compose 安装后仍不可用"
  ok "Docker Compose 已安装"
}

# ============================================================
# Step: Nginx Proxy Manager
# ============================================================
do_npm() {
  step "5/7" "Nginx Proxy Manager"

  # 询问端口
  if [ -t 0 ]; then
    printf '  请输入 NPM 管理端口 [%s]: ' "$DEFAULT_NPM_PORT"
    read -r answer || true
    NPM_ADMIN_PORT="${answer:-$DEFAULT_NPM_PORT}"
  else
    NPM_ADMIN_PORT="$DEFAULT_NPM_PORT"
  fi
  [[ "$NPM_ADMIN_PORT" =~ ^[0-9]+$ ]] && [ "$NPM_ADMIN_PORT" -ge 1 ] && [ "$NPM_ADMIN_PORT" -le 65535 ] \
    || { warn "端口无效，使用默认 $DEFAULT_NPM_PORT"; NPM_ADMIN_PORT="$DEFAULT_NPM_PORT"; }

  # 创建目录和 compose 文件
  run mkdir -p "${NPM_DIR}/data" "${NPM_DIR}/letsencrypt"
  run tee "${NPM_DIR}/docker-compose.yml" >/dev/null <<EOF
services:
  app:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '${NPM_ADMIN_PORT}:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      DISABLE_IPV6: 'true'
EOF

  # 启动
  info "启动 NPM（端口 ${NPM_ADMIN_PORT}）..."
  compose pull 2>/dev/null || true
  compose up -d

  # 等待就绪
  local i=0
  while [ "$i" -lt 30 ]; do
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NPM_ADMIN_PORT}" 2>/dev/null | grep -qE '^(200|302|301|401|403)' && break
    sleep 2
    i=$((i + 2))
  done
  [ "$i" -lt 30 ] && ok "NPM 已启动" || warn "NPM 启动较慢，请稍后检查"
}

# ============================================================
# Step: 管理菜单 (ling)
# ============================================================
do_menu() {
  step "6/7" "管理菜单 (ling)"

  # 写入菜单脚本（内嵌，不依赖外部文件）
  run tee "$MENU_FILE" >/dev/null <<'MENUEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

NPM_DIR="/npm"
XBN_SERVICE="xboard-node"
XBN_INSTALL="/etc/xboard-node/install.sh"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; W='\033[1m'; N='\033[0m'
info()  { echo -e "${B}[INFO]${N} $*"; }
warn()  { echo -e "${Y}[WARN]${N} $*"; }
err()   { echo -e "${R}[ERR]${N} $*" >&2; }
ok()    { echo -e "${G}[OK]${N} $*"; }

pause() { echo; read -r -p "按回车返回菜单..."; }

need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  command -v sudo >/dev/null 2>&1 && return 0
  err "需要 root 权限"; return 1
}
run() { [ "$(id -u)" -eq 0 ] && "$@" || sudo "$@"; }

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
detect_ip() {
  local ip
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip=$(curl -4fsSL --max-time 5 "$u" 2>/dev/null | awk 'NF{print;exit}' || true)
    is_ipv4 "$ip" && { echo "$ip"; return 0; }
  done
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  is_ipv4 "$ip" && { echo "$ip"; return 0; }
  echo "服务器IP"
}

get_npm_port() {
  [ -f "${NPM_DIR}/docker-compose.yml" ] || [ -f "${NPM_DIR}/compose.yaml" ] || { echo "81"; return; }
  local f="${NPM_DIR}/docker-compose.yml"
  [ -f "$f" ] || f="${NPM_DIR}/compose.yaml"
  grep -E "^[[:space:]]*-[[:space:]]*'?[0-9]+:81'?" "$f" 2>/dev/null | head -1 | sed -E "s/.*'?([0-9]+):81.*/\1/" || echo "81"
}

check_xbctl() {
  command -v xbctl >/dev/null 2>&1 && return 0
  [ -x /usr/local/bin/xbctl ] && { export PATH="/usr/local/bin:$PATH"; return 0; }
  [ -x /usr/bin/xbctl ] && { export PATH="/usr/bin:$PATH"; return 0; }
  return 1
}

compose_ok() { docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; }
compose() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$NPM_DIR" && run docker compose "$@")
  else
    (cd "$NPM_DIR" && run docker-compose "$@")
  fi
}

# -- 1. 查看状态 --
m1() {
  echo; echo -e "${W}${C}xboard-node 服务状态${N}"; echo
  echo -e "${W}监听端口:${N}"
  ss -tlnp 2>/dev/null | grep -E 'xboard|sing-box|xray' || echo "  未检测到"
  echo; echo -e "${W}systemd:${N}"
  if command -v systemctl >/dev/null 2>&1; then
    local s; s=$(systemctl show "$XBN_SERVICE" --property LoadState --value 2>/dev/null || echo "not-found")
    [ "$s" = "not-found" ] && { warn "xboard-node 服务未安装"; return; }
    echo "  LoadState: $s"
    echo "  Active:    $(systemctl is-active "$XBN_SERVICE" 2>/dev/null || echo unknown)"
    echo "  Enabled:   $(systemctl is-enabled "$XBN_SERVICE" 2>/dev/null || echo unknown)"
  else warn "systemctl 不可用"; fi
  echo; echo -e "${W}xbctl:${N}"
  check_xbctl && xbctl list 2>/dev/null || warn "xbctl 不可用"
}

# -- 2. 启动 xboard-node --
m2() {
  echo; need_root || return 1
  local s=0
  check_xbctl && { info "xbctl start"; run xbctl start 2>/dev/null && { ok "完成"; s=1; } || warn "失败"; }
  command -v systemctl >/dev/null 2>&1 && systemctl show "$XBN_SERVICE" --property LoadState --value 2>/dev/null | grep -qv "not-found" && {
    info "systemctl start xboard-node"; run systemctl start "$XBN_SERVICE" 2>/dev/null && { ok "完成"; s=1; } || warn "失败"
  }
  check_xbctl && { info "xbctl service start"; run xbctl service start 2>/dev/null && { ok "完成"; s=1; } || warn "失败"; }
  [ "$s" -eq 0 ] && warn "可能已启动或配置不完整，请先绑定 Panel/Token"
}

# -- 3. 启动 NPM --
m3() {
  echo; need_root || return 1
  [ -f "${NPM_DIR}/docker-compose.yml" ] || [ -f "${NPM_DIR}/compose.yaml" ] || { err "NPM 未安装"; return 1; }
  compose_ok || { err "Docker Compose 不可用"; return 1; }
  info "启动 NPM..."; compose up -d; ok "NPM 已启动"
  echo "  后台: http://$(detect_ip):$(get_npm_port)"
}

# -- 4. 重启 xboard-node --
m4() {
  echo; need_root || return 1
  local s=0
  check_xbctl && { info "xbctl restart"; run xbctl restart 2>/dev/null && { ok "完成"; s=1; } || warn "失败"; }
  command -v systemctl >/dev/null 2>&1 && systemctl show "$XBN_SERVICE" --property LoadState --value 2>/dev/null | grep -qv "not-found" && {
    info "systemctl restart"; run systemctl restart "$XBN_SERVICE" 2>/dev/null && { ok "完成"; s=1; } || warn "失败"
  }
  check_xbctl && { info "xbctl service restart"; run xbctl service restart 2>/dev/null && { ok "完成"; s=1; } || warn "失败"; }
  [ "$s" -eq 0 ] && err "重启失败，请检查服务状态"
}

# -- 5. 重启 NPM --
m5() {
  echo; need_root || return 1
  [ -f "${NPM_DIR}/docker-compose.yml" ] || [ -f "${NPM_DIR}/compose.yaml" ] || { err "NPM 未安装"; return 1; }
  compose_ok || { err "Docker Compose 不可用"; return 1; }
  info "重启 NPM..."; compose restart; ok "NPM 已重启"
}

# -- 6. 查看 NPM 地址 --
m6() {
  echo; echo -e "${W}${C}NPM 登录信息${N}"; echo
  local ip port; ip=$(detect_ip); port=$(get_npm_port)
  echo -e "  ${W}地址:${N} ${G}http://${ip}:${port}${N}"
  echo -e "  ${W}账号:${N} admin@example.com"
  echo -e "  ${W}密码:${N} changeme（首次登录强制修改）"
  echo; compose_ok && compose ps 2>/dev/null || warn "无法获取容器状态"
}

# -- 7. 绑定 Panel/Token --
m7() {
  echo; echo -e "${W}${C}绑定 Panel 和 Token${N}"; echo
  need_root || return 1

  # 显示当前配置
  [ -f /etc/xboard-node/config.yml ] && {
    local cp; cp=$(grep -E '^[[:space:]]*panel_url:' /etc/xboard-node/config.yml 2>/dev/null | awk '{print $2}' | tr -d "'\"" || echo "未设置")
    echo -e "  ${B}当前 Panel:${N} $cp"
    echo
  }

  local panel token mid
  read -r -p "  Panel 地址 (例: https://panel.example.com): " panel
  [ -z "$panel" ] && { warn "已取消"; return 1; }
  read -r -p "  Token: " token
  [ -z "$token" ] && { warn "已取消"; return 1; }
  read -r -p "  Machine ID [1]: " mid; mid="${mid:-1}"

  echo; echo "  Panel: ${panel}"; echo "  Token: ${token:0:8}****"; echo "  Machine ID: ${mid}"
  read -r -p "  确认绑定? [y/N]: " c
  [ "$c" = "y" ] || [ "$c" = "Y" ] || { info "已取消"; return 0; }

  local bound=0
  # 方法1: xbctl config init
  if check_xbctl && xbctl config init --mode machine --panel-url "$panel" --token "$token" --node-id "$mid" --config /etc/xboard-node/config.yml 2>/dev/null; then
    ok "xbctl 配置更新成功"; bound=1
  # 方法2: 本地 install.sh
  elif [ -f "$XBN_INSTALL" ]; then
    info "通过本地脚本重新配置..."
    run bash "$XBN_INSTALL" --mode machine --panel "$panel" --token "$token" --machine-id "$mid" 2>/dev/null && { ok "配置完成"; bound=1; } || warn "本地脚本失败"
  # 方法3: 远程脚本
  else
    info "从远程下载安装脚本..."
    curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | run bash -s -- --mode machine --panel "$panel" --token "$token" --machine-id "$mid" && { ok "配置完成"; bound=1; } || err "远程脚本失败"
  fi

  [ "$bound" -eq 0 ] && { err "绑定失败"; return 1; }

  # 重启生效
  info "重启服务..."
  check_xbctl && run xbctl restart 2>/dev/null || true
  command -v systemctl >/dev/null 2>&1 && run systemctl restart "$XBN_SERVICE" 2>/dev/null || true
  ok "绑定完成"
}

# -- 8. 查看端口状态 --
m8() {
  echo; local port
  read -r -p "  端口号: " port
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "无效端口"; return 1; }
  echo; echo -e "${W}端口 ${port} 状态:${N}"; echo
  # 监听
  if ss -tlnp 2>/dev/null | grep -q ":${port}\b"; then
    ok "正在监听:"; ss -tlnp 2>/dev/null | grep ":${port}\b" | while read -r l; do echo "  $l"; done
  else warn "未监听"; fi
  echo
  # 防火墙
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | grep -q "${port}/tcp" && ok "UFW 已放行" || warn "UFW 未放行"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp" && ok "firewalld 已放行" || warn "firewalld 未放行"
  fi
  # 连通性
  timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null && ok "本地可连接" || warn "本地不可达"
}

# -- 9. 放行端口 --
m9() {
  echo; need_root || return 1
  local port
  read -r -p "  端口号: " port
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "无效端口"; return 1; }
  if command -v ufw >/dev/null 2>&1; then
    run ufw allow "${port}/tcp" && ok "UFW 已放行 ${port}/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    run firewall-cmd --permanent --add-port="${port}/tcp" && run firewall-cmd --reload && ok "firewalld 已放行 ${port}/tcp"
  elif command -v iptables >/dev/null 2>&1; then
    run iptables -A INPUT -p tcp --dport "$port" -j ACCEPT && ok "iptables 已放行 ${port}/tcp" && warn "重启后失效，建议安装 ufw"
  else
    err "未找到防火墙，请手动放行"
  fi
}

# -- 菜单 --
show() {
  clear
  echo; echo -e "${C}  ╔══════════════════════════════╗${N}"
  echo -e "${C}  ║${N}   ${W}xboard-node 运维菜单${N}      ${C}║${N}"
  echo -e "${C}  ╠══════════════════════════════╣${N}"
  echo -e "${C}  ║${N} ${G}1${N}. 查看 xboard-node 状态    ${C}║${N}"
  echo -e "${C}  ║${N} ${G}2${N}. 启动 xboard-node         ${C}║${N}"
  echo -e "${C}  ║${N} ${G}3${N}. 启动 NPM                 ${C}║${N}"
  echo -e "${C}  ║${N} ${G}4${N}. 重启 xboard-node         ${C}║${N}"
  echo -e "${C}  ║${N} ${G}5${N}. 重启 NPM                 ${C}║${N}"
  echo -e "${C}  ║${N} ${G}6${N}. 查看 NPM 登录信息        ${C}║${N}"
  echo -e "${C}  ║${N} ${G}7${N}. 绑定 Panel / Token       ${C}║${N}"
  echo -e "${C}  ║${N} ${G}8${N}. 查看端口状态             ${C}║${N}"
  echo -e "${C}  ║${N} ${G}9${N}. 放行端口                 ${C}║${N}"
  echo -e "${C}  ║${N} ${R}0${N}. 退出                     ${C}║${N}"
  echo -e "${C}  ╚══════════════════════════════╝${N}"
  echo
  local port ip; port=$(get_npm_port); ip=$(detect_ip)
  echo -e "  ${W}NPM:${N} ${G}http://${ip}:${port}${N}"
  command -v systemctl >/dev/null 2>&1 && {
    echo -n "  xboard-node: "
    systemctl is-active "$XBN_SERVICE" 2>/dev/null && echo -e "${G}运行中${N}" || echo -e "${R}未运行${N}"
  }
  echo
}

main() {
  while true; do
    show
    read -r -p "  选项 [0-9]: " c
    echo; case "$c" in
      1) m1; pause ;; 2) m2; pause ;; 3) m3; pause ;;
      4) m4; pause ;; 5) m5; pause ;; 6) m6; pause ;;
      7) m7; pause ;; 8) m8; pause ;; 9) m9; pause ;;
      0) ok "已退出。下次输入 ling 进入。"; exit 0 ;;
      *) err "无效选项" ; sleep 1 ;;
    esac
  done
}
main "$@"
MENUEOF

  run chmod +x "$MENU_FILE"

  # 创建 ling 快捷命令
  run tee "$MENU_BIN" >/dev/null <<EOF
#!/usr/bin/env bash
[ -f "$MENU_FILE" ] && exec bash "$MENU_FILE" "\$@" || { echo "[ling] 菜单文件丢失，请重新运行安装脚本"; exit 1; }
EOF
  run chmod +x "$MENU_BIN"
  ok "菜单已安装，输入 ling 打开"
}

# ============================================================
# Step: 防火墙
# ============================================================
do_firewall() {
  step "7/7" "防火墙放行"
  for port in 80 443 "$NPM_ADMIN_PORT"; do
    if command -v ufw >/dev/null 2>&1; then
      run ufw allow "${port}/tcp" 2>/dev/null && info "UFW 放行 ${port}/tcp" || true
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      run firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null && run firewall-cmd --reload 2>/dev/null && info "firewalld 放行 ${port}/tcp" || true
    fi
  done
}

# ============================================================
# 完成
# ============================================================
print_done() {
  local ip; ip=$(detect_ip)
  echo
  echo "  ╔══════════════════════════════════╗"
  echo "  ║          安装完成                ║"
  echo "  ╚══════════════════════════════════╝"
  echo
  echo -e "  ${W}NPM 后台:${N}  http://${ip}:${NPM_ADMIN_PORT}"
  echo -e "  ${W}默认账号:${N}  admin@example.com / changeme"
  echo -e "  ${W}管理菜单:${N}  ling"
  echo
  echo -e "  ${Y}下一步:${N} ling → 选项 7 → 绑定真实 Panel/Token"
  echo
}

# ============================================================
# 主流程
# ============================================================
main() {
  echo
  echo "  ╔══════════════════════════════════╗"
  echo "  ║  xboard-node + NPM 一键安装     ║"
  echo "  ╚══════════════════════════════════╝"

  init_privilege
  do_system_check
  do_bbr
  do_xboard_node
  do_docker
  do_npm
  do_menu
  do_firewall
  print_done
}

main "$@"
