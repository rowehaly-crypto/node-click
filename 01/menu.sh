#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# xboard-node + NPM 运维管理菜单
# 用法: ling  或  bash menu.sh
# ============================================================

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

# -- 1. 查看 xboard-node 状态 --
m1() {
  echo; echo -e "${W}${C}xboard-node 服务状态${N}"; echo
  echo -e "${W}监听端口 (xboard/sing-box/xray):${N}"
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

# -- 6. 查看 NPM 登录信息 --
m6() {
  echo; echo -e "${W}${C}NPM 登录信息${N}"; echo
  local ip port; ip=$(detect_ip); port=$(get_npm_port)
  echo -e "  ${W}地址:${N} ${G}http://${ip}:${port}${N}"
  echo -e "  ${W}账号:${N} admin@example.com"
  echo -e "  ${W}密码:${N} changeme（首次登录强制修改）"
  echo; compose_ok && compose ps 2>/dev/null || warn "无法获取容器状态"
}

# -- 7. 绑定 Panel / Token --
m7() {
  echo; echo -e "${W}${C}绑定 Panel 和 Token${N}"; echo
  need_root || return 1

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
  if ss -tlnp 2>/dev/null | grep -q ":${port}\b"; then
    ok "正在监听:"; ss -tlnp 2>/dev/null | grep ":${port}\b" | while read -r l; do echo "  $l"; done
  else warn "未监听"; fi
  echo
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | grep -q "${port}/tcp" && ok "UFW 已放行" || warn "UFW 未放行"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp" && ok "firewalld 已放行" || warn "firewalld 未放行"
  fi
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
