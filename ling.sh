#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xboard-node + NPM 一键安装
# 用法: bash <(curl -fsSL https://.../01/install.sh)
# ============================================================

NPM_DIR="/npm"
MENU_BIN="/usr/local/bin/ling"
MENU_FILE="/usr/local/share/ling-menu.sh"
DEFAULT_NPM_PORT=81
NPM_ADMIN_PORT=""
SUDO_CMD=()
COMPOSE_CMD=()

# --- 日志 ---
info()  { printf '  \033[0;34m[+]\033[0m %s\n' "$*"; }
warn()  { printf '  \033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()   { printf '  \033[0;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }
ok()    { printf '  \033[0;32m[V]\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1;36m[%s]\033[0m %s\n' "$1" "$2"; }

# --- 权限 ---
init_privilege() {
  if [ "$(id -u)" -eq 0 ]; then SUDO_CMD=(); return 0; fi
  if command -v sudo >/dev/null 2>&1; then SUDO_CMD=(sudo); return 0; fi
  if command -v apt-get >/dev/null 2>&1 && command -v su >/dev/null 2>&1; then
    su -c "apt-get update -qq && apt-get install -y sudo" 2>/dev/null || true
    command -v sudo >/dev/null 2>&1 && { SUDO_CMD=(sudo); return 0; }
  fi
  err "需要 root 权限。请执行 su - 切换到 root 后重试。"
}
run() { "${SUDO_CMD[@]}" "$@"; }

# --- 工具 ---
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

check_compose() {
  docker compose version >/dev/null 2>&1 && { COMPOSE_CMD=(docker compose); return 0; }
  command -v docker-compose >/dev/null 2>&1 && { COMPOSE_CMD=(docker-compose); return 0; }
  return 1
}
compose() { (cd "$NPM_DIR" && run "${COMPOSE_CMD[@]}" "$@"); }

# ============================================================
# Step 1: BBR
# ============================================================
do_bbr() {
  step "1/5" "BBR 拥堵控制"

  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  [ "$cc" = "bbr" ] && { info "BBR 已启用"; return 0; }

  local major minor
  major=$(uname -r | cut -d. -f1)
  minor=$(uname -r | cut -d. -f2)
  [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 9 ]; } \
    && err "内核 $(uname -r) 过低，BBR 需要 >= 4.9"

  info "开启 BBR..."
  run modprobe tcp_bbr 2>/dev/null || { warn "无法加载 tcp_bbr，跳过"; return 0; }
  run mkdir -p /etc/modules-load.d
  echo "tcp_bbr" | run tee /etc/modules-load.d/bbr.conf >/dev/null
  run sysctl -w net.core.default_qdisc=fq >/dev/null
  run sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

  local sf="/etc/sysctl.conf"
  grep -q "^net.core.default_qdisc" "$sf" 2>/dev/null \
    && run sed -i 's/^net.core.default_qdisc.*/net.core.default_qdisc=fq/' "$sf" \
    || echo "net.core.default_qdisc=fq" | run tee -a "$sf" >/dev/null
  grep -q "^net.ipv4.tcp_congestion_control" "$sf" 2>/dev/null \
    && run sed -i 's/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control=bbr/' "$sf" \
    || echo "net.ipv4.tcp_congestion_control=bbr" | run tee -a "$sf" >/dev/null
  run sysctl -p >/dev/null 2>&1 || true

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  [ "$cc" = "bbr" ] && ok "BBR 已启用" || warn "BBR 状态: $cc"
}

# ============================================================
# Step 2: Docker
# ============================================================
do_docker() {
  step "2/5" "Docker 环境"

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

  if check_compose; then
    info "Docker Compose 已就绪"
    return 0
  fi

  info "安装 Compose 插件..."
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
# Step 3: NPM
# ============================================================
do_npm() {
  step "3/5" "Nginx Proxy Manager"

  if [ -t 0 ]; then
    printf '  管理端口 [%s]: ' "$DEFAULT_NPM_PORT"
    read -r answer || true
    NPM_ADMIN_PORT="${answer:-$DEFAULT_NPM_PORT}"
  else
    NPM_ADMIN_PORT="$DEFAULT_NPM_PORT"
  fi
  [[ "$NPM_ADMIN_PORT" =~ ^[0-9]+$ ]] && [ "$NPM_ADMIN_PORT" -ge 1 ] && [ "$NPM_ADMIN_PORT" -le 65535 ] \
    || { warn "端口无效，使用默认 $DEFAULT_NPM_PORT"; NPM_ADMIN_PORT="$DEFAULT_NPM_PORT"; }

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

  info "启动 NPM（端口 ${NPM_ADMIN_PORT}）..."
  compose pull 2>/dev/null || true
  compose up -d

  local i=0
  while [ "$i" -lt 30 ]; do
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NPM_ADMIN_PORT}" 2>/dev/null | grep -qE '^(200|302|301|401|403)' && break
    sleep 2; i=$((i + 2))
  done
  [ "$i" -lt 30 ] && ok "NPM 已启动" || warn "NPM 启动较慢，请稍候检查"
}

# ============================================================
# Step 4: 菜单
# ============================================================
do_menu() {
  step "4/5" "管理菜单 (ling)"

  run tee "$MENU_FILE" >/dev/null <<'MENUEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

NPM_DIR="/npm"
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; W='\033[1m'; N='\033[0m'
info()  { echo -e "${B}[INFO]${N} $*"; }
warn()  { echo -e "${Y}[WARN]${N} $*"; }
err()   { echo -e "${R}[ERR]${N} $*" >&2; }
ok()    { echo -e "${G}[OK]${N} $*"; }
pause() { echo; read -r -p "按回车返回菜单..."; }

need_root() { [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1 || { err "需要 root 权限"; return 1; }; }
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
  local f="${NPM_DIR}/docker-compose.yml"
  [ -f "$f" ] || f="${NPM_DIR}/compose.yaml"
  [ -f "$f" ] || { echo "81"; return; }
  sed -nE "s/^[[:space:]]*-[[:space:]]*['\"]?([0-9]+):81['\"]?.*/\1/p" "$f" 2>/dev/null | head -1 || echo "81"
}

compose_ok() { docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; }
compose() {
  if docker compose version >/dev/null 2>&1; then (cd "$NPM_DIR" && run docker compose "$@")
  else (cd "$NPM_DIR" && run docker-compose "$@"); fi
}

# -- 1. 启动 NPM --
m1() {
  echo; need_root || return 1
  [ -f "${NPM_DIR}/docker-compose.yml" ] || [ -f "${NPM_DIR}/compose.yaml" ] || { err "NPM 未安装"; return 1; }
  compose_ok || { err "Docker Compose 不可用"; return 1; }
  info "启动 NPM..."; compose up -d; ok "NPM 已启动"
  echo "  后台: http://$(detect_ip):$(get_npm_port)"
}

# -- 2. 重启 NPM --
m2() {
  echo; need_root || return 1
  [ -f "${NPM_DIR}/docker-compose.yml" ] || [ -f "${NPM_DIR}/compose.yaml" ] || { err "NPM 未安装"; return 1; }
  compose_ok || { err "Docker Compose 不可用"; return 1; }
  info "重启 NPM..."; compose restart; ok "NPM 已重启"
}

# -- 3. 查看 NPM 信息 --
m3() {
  echo; echo -e "${W}${C}NPM 登录信息${N}"; echo
  local ip port; ip=$(detect_ip); port=$(get_npm_port)
  echo -e "  ${W}地址:${N} ${G}http://${ip}:${port}${N}"
  echo -e "  ${W}账号:${N} admin@example.com"
  echo -e "  ${W}密码:${N} changeme（首次登录强制修改）"
  echo; compose_ok && compose ps 2>/dev/null || warn "无法获取容器状态"
}

# -- 4. 查看节点状态 --
m4() {
  echo; echo -e "${W}${C}节点监听状态${N}"; echo
  echo -e "${W}相关进程 (xboard / sing-box / xray):${N}"
  if ss -tlnp 2>/dev/null | grep -E 'xboard|sing-box|xray'; then
    echo
  else
    echo "  未检测到相关进程"
  fi
}

# -- 5. 查看端口状态 --
m5() {
  echo; local port
  read -r -p "  端口号: " port
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "无效端口"; return 1; }
  echo; echo -e "${W}端口 ${port}:${N}"; echo
  ss -tlnp 2>/dev/null | grep -q ":${port}\b" && { ok "正在监听"; ss -tlnp 2>/dev/null | grep ":${port}\b" | while read -r l; do echo "  $l"; done; } || warn "未监听"
  echo
  command -v ufw >/dev/null 2>&1 && { ufw status 2>/dev/null | grep -q "${port}/tcp" && ok "UFW 已放行" || warn "UFW 未放行"; }
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 && { firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp" && ok "firewalld 已放行" || warn "firewalld 未放行"; }
  timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null && ok "本地可连接" || warn "本地不可达"
}

# -- 6. 放行端口 --
m6() {
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

show() {
  clear
  echo; echo -e "${C}  ╔══════════════════════════════╗${N}"
  echo -e "${C}  ║${N}     ${W}运维管理菜单${N}              ${C}║${N}"
  echo -e "${C}  ╠══════════════════════════════╣${N}"
  echo -e "${C}  ║${N}    ${Y}—— NPM ——${N}                ${C}║${N}"
  echo -e "${C}  ║${N} ${G}1${N}. 启动 NPM                  ${C}║${N}"
  echo -e "${C}  ║${N} ${G}2${N}. 重启 NPM                  ${C}║${N}"
  echo -e "${C}  ║${N} ${G}3${N}. 查看 NPM 登录信息         ${C}║${N}"
  echo -e "${C}  ║${N}    ${Y}—— 系统工具 ——${N}            ${C}║${N}"
  echo -e "${C}  ║${N} ${G}4${N}. 查看节点状态              ${C}║${N}"
  echo -e "${C}  ║${N} ${G}5${N}. 查看端口状态              ${C}║${N}"
  echo -e "${C}  ║${N} ${G}6${N}. 放行端口                  ${C}║${N}"
  echo -e "${C}  ║${N} ${R}0${N}. 退出                      ${C}║${N}"
  echo -e "${C}  ╚══════════════════════════════╝${N}"
  echo
  local port ip; port=$(get_npm_port); ip=$(detect_ip)
  echo -e "  ${W}NPM:${N} ${G}http://${ip}:${port}${N}"
  echo
}

main() {
  while true; do
    show
    read -r -p "  选项 [0-6]: " c
    echo; case "$c" in
      1) m1; pause ;; 2) m2; pause ;; 3) m3; pause ;;
      4) m4; pause ;; 5) m5; pause ;; 6) m6; pause ;;
      0) ok "已退出。下次输入 ling 进入。"; exit 0 ;;
      *) err "无效选项" ; sleep 1 ;;
    esac
  done
}
main "$@"
MENUEOF

  run chmod +x "$MENU_FILE"
  run tee "$MENU_BIN" >/dev/null <<EOF
#!/usr/bin/env bash
[ -f "$MENU_FILE" ] && exec bash "$MENU_FILE" "\$@" || { echo "[ling] 菜单文件丢失，请重新运行安装脚本"; exit 1; }
EOF
  run chmod +x "$MENU_BIN"
  ok "菜单已安装，输入 ling 打开"
}

# ============================================================
# Step 5: 防火墙 + 完成
# ============================================================
do_finish() {
  step "5/5" "防火墙 & 完成"

  for port in 80 443 "$NPM_ADMIN_PORT"; do
    if command -v ufw >/dev/null 2>&1; then
      run ufw allow "${port}/tcp" 2>/dev/null && info "UFW 放行 ${port}/tcp" || true
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      run firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null && run firewall-cmd --reload 2>/dev/null && info "firewalld 放行 ${port}/tcp" || true
    fi
  done

  local ip; ip=$(detect_ip)
  echo
  echo "  ╔══════════════════════════════════╗"
  echo "  ║          安装完成                ║"
  echo "  ╚══════════════════════════════════╝"
  echo
  echo -e "  NPM 后台:  http://${ip}:${NPM_ADMIN_PORT}"
  echo -e "  默认账号:  admin@example.com / changeme"
  echo -e "  管理菜单:  ling"
  echo
}

# ============================================================
# 主流程
# ============================================================
main() {
  echo
  echo "  ╔══════════════════════════════════╗"
  echo "  ║     NPM 一键安装脚本            ║"
  echo "  ╚══════════════════════════════════╝"

  init_privilege
  do_bbr
  do_docker
  do_npm
  do_menu
  do_finish
}
main "$@"
