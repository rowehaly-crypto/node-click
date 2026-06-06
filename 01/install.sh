#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xboard-node + Nginx Proxy Manager 一键安装脚本
# ============================================================

PROJECT_NAME="xboard-node-one-click"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NPM_DIR="/npm"
XBOARD_NODE_INSTALL_URL="https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh"
MENU_SCRIPT="${SCRIPT_DIR}/menu.sh"
MENU_TARGET="/usr/local/bin/ling"
MENU_BACKUP="/usr/local/share/ling-menu.sh"

DEFAULT_NPM_ADMIN_PORT=81
NPM_ADMIN_PORT=""

# ---------- 全局状态 ----------
SUDO_CMD=()
COMPOSE_CMD=()
DETECTED_SERVER_IP=""
XBOARD_NODE_INSTALLED=0

# ---------- 日志 ----------
log()   { printf '[%s] %s\n' "$PROJECT_NAME" "$*"; }
warn()  { printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2; }
die()   { warn "$*"; exit 1; }

# ---------- 权限处理 ----------
init_privilege() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=()
    log "以 root 身份运行。"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    SUDO_CMD=(sudo)
    log "使用 sudo 执行特权操作。"
    return 0
  fi

  # 极简 Debian：没有 sudo 且不是 root
  log "检测到极简系统环境（无 sudo），尝试解决..."

  # 如果有 apt-get，尝试通过 su 安装 sudo
  if command -v apt-get >/dev/null 2>&1 && command -v su >/dev/null 2>&1; then
    warn "正在通过 su 安装 sudo，可能需要输入 root 密码..."
    if su -c "apt-get update -qq && apt-get install -y sudo" 2>/dev/null; then
      if command -v sudo >/dev/null 2>&1; then
        SUDO_CMD=(sudo)
        log "sudo 安装成功，继续执行。"
        return 0
      fi
    fi
  fi

  die "当前不是 root 用户且没有 sudo 命令。请执行: su - 切换到 root，再重新运行本脚本。"
}

run_privileged() {
  "${SUDO_CMD[@]}" "$@"
}

# ============================================================
# Step 1: 检查 Linux 系统版本
# ============================================================
check_linux() {
  echo ""
  log "============================================"
  log "  Step 1: 检测 Linux 系统版本"
  log "============================================"

  if [ ! -f /etc/os-release ]; then
    die "无法找到 /etc/os-release，请确认当前系统为 Linux。"
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  log "当前系统: ${NAME:-Unknown} ${VERSION_ID:-Unknown} (${ID:-unknown})"

  case "${ID:-}" in
    debian|ubuntu|raspbian|deepin|uos)
      log "检测到 Debian 系列系统，完全支持。"
      ;;
    centos|rhel|fedora|rocky|alma|openEuler)
      log "检测到 RHEL 系列系统，将以兼容模式运行。"
      warn "部分包管理命令可能与 Debian 不同，如有问题请手动干预。"
      ;;
    *)
      warn "当前系统 (${ID:-unknown}) 未经全面测试，安装可能遇到问题。"
      ;;
  esac
}

# ============================================================
# Step 2: 检查并安装 curl
# ============================================================
ensure_curl() {
  echo ""
  log "============================================"
  log "  Step 2: 检查 curl"
  log "============================================"

  if command -v curl >/dev/null 2>&1; then
    log "curl 已就绪: $(curl --version 2>/dev/null | head -1 || echo 'ok')"
    return 0
  fi

  log "未检测到 curl，开始安装..."
  if command -v apt-get >/dev/null 2>&1; then
    run_privileged apt-get update -qq
    run_privileged apt-get install -y curl
  elif command -v yum >/dev/null 2>&1; then
    run_privileged yum install -y curl
  elif command -v dnf >/dev/null 2>&1; then
    run_privileged dnf install -y curl
  else
    die "无法自动安装 curl，请手动安装: apt-get install -y curl"
  fi

  command -v curl >/dev/null 2>&1 || die "curl 安装失败，请手动检查。"
  log "curl 安装完成。"
}

# ============================================================
# Step 3: 检查并开启 BBR 拥堵控制算法
# ============================================================
check_kernel_version() {
  local major minor
  major=$(uname -r | cut -d. -f1)
  minor=$(uname -r | cut -d. -f2)

  # BBR 需要内核 >= 4.9
  if [ "$major" -lt 4 ]; then
    return 1
  elif [ "$major" -eq 4 ] && [ "$minor" -lt 9 ]; then
    return 1
  fi
  return 0
}

enable_bbr() {
  log "正在启用 BBR 拥堵控制算法..."

  # 加载 tcp_bbr 模块
  if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
    run_privileged modprobe tcp_bbr 2>/dev/null || {
      warn "无法加载 tcp_bbr 内核模块，你的内核可能未编译 BBR 支持。"
      warn "请更换支持 BBR 的内核后重试。"
      return 1
    }
  fi

  # 确保开机自动加载
  run_privileged mkdir -p /etc/modules-load.d
  echo "tcp_bbr" | run_privileged tee /etc/modules-load.d/bbr.conf >/dev/null

  # 设置排队算法和拥堵控制
  run_privileged sysctl -w net.core.default_qdisc=fq >/dev/null
  run_privileged sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

  # 持久化到 /etc/sysctl.conf
  local sysctl_file="/etc/sysctl.conf"
  if ! grep -q "^net.core.default_qdisc" "$sysctl_file" 2>/dev/null; then
    echo "net.core.default_qdisc=fq" | run_privileged tee -a "$sysctl_file" >/dev/null
  else
    run_privileged sed -i 's/^net.core.default_qdisc.*/net.core.default_qdisc=fq/' "$sysctl_file"
  fi

  if ! grep -q "^net.ipv4.tcp_congestion_control" "$sysctl_file" 2>/dev/null; then
    echo "net.ipv4.tcp_congestion_control=bbr" | run_privileged tee -a "$sysctl_file" >/dev/null
  else
    run_privileged sed -i 's/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control=bbr/' "$sysctl_file"
  fi

  run_privileged sysctl -p >/dev/null 2>&1 || true
  log "BBR 配置已写入 sysctl，重启后仍然生效。"
}

check_and_enable_bbr() {
  echo ""
  log "============================================"
  log "  Step 3: 检查拥堵控制算法"
  log "============================================"

  local current_cc
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  log "当前拥堵控制算法: ${current_cc}"

  if [ "$current_cc" = "bbr" ]; then
    log "BBR 已启用，无需修改。"
    return 0
  fi

  # 检查内核版本
  if ! check_kernel_version; then
    local kv
    kv=$(uname -r)
    warn "内核版本过低: ${kv}。BBR 需要 Linux 内核 >= 4.9。请升级内核后重试。"
	    die "  参考命令: apt-get install -y linux-image-amd64 (Debian/Ubuntu)"
  fi

  log "当前拥堵算法不是 BBR (${current_cc})，开始启用 BBR..."
  if enable_bbr; then
    # 验证
    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$new_cc" = "bbr" ]; then
      log "BBR 已成功启用。"
    else
      warn "BBR 启用后验证失败，当前算法仍为: ${new_cc}。请检查内核配置。"
    fi
  fi
}

# ============================================================
# Step 4: 安装 xboard-node 服务
# ============================================================
install_xboard_node() {
  echo ""
  log "============================================"
  log "  Step 4: 安装 xboard-node 服务"
  log "============================================"

  # 检查是否已安装
  if command -v xbctl >/dev/null 2>&1 || [ -f /usr/local/bin/xbctl ] || [ -f /usr/bin/xbctl ]; then
    log "检测到 xboard-node 可能已安装。"
    if command -v xbctl >/dev/null 2>&1; then
      xbctl version 2>/dev/null || true
    fi
    read -r -p "是否重新安装/覆盖？[y/N]: " confirm
    case "$confirm" in
      y|Y) log "继续安装..." ;;
      *)   log "跳过 xboard-node 安装。"; XBOARD_NODE_INSTALLED=1; return 0 ;;
    esac
  fi

  log "下载并执行 xboard-node 安装脚本..."
  log "使用 Machine 模式（--panel 和 --token 为占位值，安装后可通过菜单重新绑定）"

  # 先下载脚本内容，避免 curl 失败时 bash 拿到空输入静默退出
  local install_url="${XBOARD_NODE_INSTALL_URL}"
  local script_text
  script_text=$(curl -fsSL "$install_url") || die "无法下载 xboard-node 安装脚本，请检查网络连接。"
  log "脚本下载成功，开始执行..."

  if [ "$(id -u)" -eq 0 ]; then
    echo "$script_text" | bash -s -- \
      --mode machine \
      --panel https://panel.example.com \
      --token PLACEHOLDER_TOKEN \
      --machine-id 1
  else
    echo "$script_text" | sudo bash -s -- \
      --mode machine \
      --panel https://panel.example.com \
      --token PLACEHOLDER_TOKEN \
      --machine-id 1
  fi

  # 检查安装结果
  if command -v xbctl >/dev/null 2>&1; then
    XBOARD_NODE_INSTALLED=1
    log "xboard-node 安装成功！"
    xbctl version 2>/dev/null || true
  elif [ -x /usr/local/bin/xbctl ]; then
    XBOARD_NODE_INSTALLED=1
    export PATH="/usr/local/bin:$PATH"
    log "xboard-node 安装成功！（xbctl 位于 /usr/local/bin/xbctl）"
  elif [ -x /usr/bin/xbctl ]; then
    XBOARD_NODE_INSTALLED=1
    log "xboard-node 安装成功！（xbctl 位于 /usr/bin/xbctl）"
  else
    warn "xboard-node 安装可能不完整，未找到 xbctl 命令。"
    warn "请手动检查 /usr/local/bin/ 或 /usr/bin/ 目录。"
  fi

  # 确保 xbctl 在 PATH 中
  if [ "$XBOARD_NODE_INSTALLED" -eq 1 ]; then
    export PATH="/usr/local/bin:/usr/bin:$PATH"
  fi
}

# ============================================================
# Step 5: 检查并安装 Docker
# ============================================================
ensure_docker() {
  echo ""
  log "============================================"
  log "  Step 5: 检查 Docker"
  log "============================================"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "Docker 已安装并正常运行。"
  else
    log "未检测到 Docker，开始安装..."

    if command -v apt-get >/dev/null 2>&1; then
      # Debian/Ubuntu: 先通过官方脚本安装
      log "使用 Docker 官方安装脚本..."
      curl -fsSL https://get.docker.com | run_privileged bash
    elif command -v yum >/dev/null 2>&1; then
      run_privileged yum install -y docker
    elif command -v dnf >/dev/null 2>&1; then
      run_privileged dnf install -y docker
    else
      die "无法自动安装 Docker，请手动安装。"
    fi

    # 启动 Docker
    if command -v systemctl >/dev/null 2>&1; then
      run_privileged systemctl enable --now docker 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
      run_privileged service docker start 2>/dev/null || true
    fi
  fi

  # 再次验证
  if ! docker info >/dev/null 2>&1; then
    die "Docker 无法正常运行。请检查 Docker 服务状态: systemctl status docker"
  fi
  log "Docker 运行正常。"

  # 检测 compose 命令
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    log "检测到: docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    log "检测到: docker-compose"
  else
    # 尝试安装 compose 插件
    log "未检测到 docker compose，尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      run_privileged apt-get update -qq
      run_privileged apt-get install -y docker-compose-plugin 2>/dev/null || \
      run_privileged apt-get install -y docker-compose-v2 2>/dev/null || \
      run_privileged apt-get install -y docker-compose 2>/dev/null || \
      die "docker-compose 安装失败，请手动安装。"
    else
      die "未找到 docker compose，请手动安装 docker-compose-plugin。"
    fi

    if docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_CMD=(docker-compose)
    fi
  fi

  # 最终验证：确保 COMPOSE_CMD 已正确设置，防止后续静默失败
  if [ ${#COMPOSE_CMD[@]} -eq 0 ]; then
    die "Docker Compose 安装后仍不可用。请手动检查: docker compose version"
  fi

  log "Docker Compose 就绪。"
}

# ============================================================
# Step 6: 安装 Nginx Proxy Manager
# ============================================================
prompt_npm_port() {
  echo ""
  if [ -t 0 ]; then
    printf '\033[1;34m请输入 Nginx Proxy Manager 管理后台端口 [%s]: \033[0m' "$DEFAULT_NPM_ADMIN_PORT"
    read -r answer || true
    if [ -n "$answer" ]; then
      NPM_ADMIN_PORT="$answer"
    else
      NPM_ADMIN_PORT="$DEFAULT_NPM_ADMIN_PORT"
    fi
  else
    log "非交互式终端，使用默认 NPM 管理端口: ${DEFAULT_NPM_ADMIN_PORT}"
    NPM_ADMIN_PORT="$DEFAULT_NPM_ADMIN_PORT"
  fi

  # 校验端口
  if ! [[ "$NPM_ADMIN_PORT" =~ ^[0-9]+$ ]] || \
     [ "$NPM_ADMIN_PORT" -lt 1 ] || \
     [ "$NPM_ADMIN_PORT" -gt 65535 ]; then
    warn "端口号无效: ${NPM_ADMIN_PORT}，使用默认端口 ${DEFAULT_NPM_ADMIN_PORT}"
    NPM_ADMIN_PORT="$DEFAULT_NPM_ADMIN_PORT"
  fi

  log "NPM 管理后台端口: ${NPM_ADMIN_PORT}"
}

setup_npm() {
  echo ""
  log "============================================"
  log "  Step 6: 安装 Nginx Proxy Manager"
  log "============================================"

  prompt_npm_port

  # 创建 /npm 目录
  run_privileged mkdir -p "${NPM_DIR}/data" "${NPM_DIR}/letsencrypt"

  # 写入 docker-compose.yml
  log "创建 /npm/docker-compose.yml ..."
  run_privileged tee "${NPM_DIR}/docker-compose.yml" >/dev/null <<DOCKER_COMPOSE
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
DOCKER_COMPOSE

  log "拉取 NPM 镜像并启动..."
  (cd "$NPM_DIR" && run_privileged "${COMPOSE_CMD[@]}" pull)
  (cd "$NPM_DIR" && run_privileged "${COMPOSE_CMD[@]}" up -d)

  # 等待 NPM 启动
  log "等待 Nginx Proxy Manager 启动..."
  local max_wait=30
  local waited=0
  while [ "$waited" -lt "$max_wait" ]; do
    if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NPM_ADMIN_PORT}" 2>/dev/null | grep -qE '^(200|302|301|401|403)'; then
      log "Nginx Proxy Manager 已启动。"
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  if [ "$waited" -ge "$max_wait" ]; then
    warn "NPM 启动超时，请手动检查: docker compose -f ${NPM_DIR}/docker-compose.yml ps"
  else
    log "Nginx Proxy Manager 安装完成。"
  fi
}

# ============================================================
# Step 7: 安装管理菜单 (ling 命令)
# ============================================================
install_menu() {
  echo ""
  log "============================================"
  log "  Step 7: 安装管理菜单"
  log "============================================"

  if [ ! -f "$MENU_SCRIPT" ]; then
    warn "未找到 menu.sh 文件: ${MENU_SCRIPT}"
    warn "请确保 menu.sh 和 install.sh 在同一目录下。"
    return 0
  fi

  # 备份 menu.sh 到系统目录，保证脚本目录删除后菜单仍可用
  run_privileged mkdir -p /usr/local/share
  run_privileged cp "$MENU_SCRIPT" "$MENU_BACKUP"
  run_privileged chmod +x "$MENU_BACKUP"
  log "菜单脚本已保存到: ${MENU_BACKUP}"

  # 创建 ling 快捷命令
  run_privileged tee "$MENU_TARGET" >/dev/null <<LING_CMD
#!/usr/bin/env bash
# ling - xboard-node 运维管理菜单
MENU_FILE="${MENU_BACKUP}"
if [ -f "\$MENU_FILE" ]; then
  exec bash "\$MENU_FILE" "\$@"
else
  echo "[ling] 菜单脚本不存在: \$MENU_FILE"
  echo "请重新运行安装脚本修复。"
  exit 1
fi
LING_CMD
  run_privileged chmod +x "$MENU_TARGET"

  log "管理菜单安装完成！"
  log "  使用方法: 在终端输入 ling 即可打开管理菜单。"
  log "  系统重启后仍然有效。"
}

# ============================================================
# 辅助函数
# ============================================================
is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

fetch_public_ip() {
  local value
  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    value="$(curl -4fsSL --max-time 5 "$url" 2>/dev/null | \
      awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit}' || true)"
    if is_ipv4 "$value"; then
      printf '%s' "$value"
      return 0
    fi
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

detect_server_ip() {
  DETECTED_SERVER_IP="$(fetch_public_ip || true)"
  if is_ipv4 "$DETECTED_SERVER_IP"; then return 0; fi

  DETECTED_SERVER_IP="$(fetch_local_ip || true)"
  if is_ipv4 "$DETECTED_SERVER_IP"; then return 0; fi

  DETECTED_SERVER_IP="你的服务器IP"
}

get_open_ports() {
  ss -tlnp 2>/dev/null | awk 'NR>1 {
    split($4, a, ":")
    port = a[length(a)]
    if (port ~ /^[0-9]+$/) print port
  }' | sort -n | uniq || true
}

open_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    run_privileged ufw allow "${port}/tcp" 2>/dev/null && \
      log "  UFW 已放行 ${port}/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    run_privileged firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null
    run_privileged firewall-cmd --reload 2>/dev/null
    log "  firewalld 已放行 ${port}/tcp"
  else
    warn "  未检测到 UFW/firewalld，请手动放行端口: ${port}/tcp"
  fi
}

open_firewall_ports() {
  log "尝试放行必要的防火墙端口..."
  local port
  for port in 80 443 "$NPM_ADMIN_PORT"; do
    open_port "$port" || true
  done
}

# ============================================================
# 完成总结
# ============================================================
print_summary() {
  detect_server_ip

  echo ""
  echo "============================================"
  echo ""
  echo "  ██╗  ██╗██████╗  ██████╗  █████╗ ██████╗ ██████╗ "
  echo "  ╚██╗██╔╝██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔══██╗"
  echo "   ╚███╔╝ ██████╔╝██║   ██║███████║██████╔╝██║  ██║"
  echo "   ██╔██╗ ██╔══██╗██║   ██║██╔══██║██╔══██╗██║  ██║"
  echo "  ██╔╝ ██╗██████╔╝╚██████╔╝██║  ██║██║  ██║██████╔╝"
  echo "  ╚═╝  ╚═╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ "
  echo ""
  echo "           安装成功！"
  echo ""
  echo "============================================"
  echo ""

  cat <<SUMMARY
📋 服务信息
──────────────────────────────────────────
  xboard-node 服务:
    状态查看:   xbctl list
    服务管理:   systemctl status xboard-node
    CLI 工具:   xbctl --help

  Nginx Proxy Manager:
    管理后台:   http://${DETECTED_SERVER_IP}:${NPM_ADMIN_PORT}
    ⚠️  首次登录默认账号: admin@example.com
    ⚠️  首次登录默认密码: changeme
    ⚠️  登录后系统会要求立即修改密码！

📂 目录结构
──────────────────────────────────────────
  NPM 配置:     ${NPM_DIR}/docker-compose.yml
  NPM 数据:     ${NPM_DIR}/data/
  SSL 证书:     ${NPM_DIR}/letsencrypt/
  管理菜单:     ${MENU_BACKUP}

🔧 管理命令
──────────────────────────────────────────
  打开管理菜单:    ling
  直接运行菜单:    bash ${MENU_BACKUP}

🔌 当前监听端口
──────────────────────────────────────────
$(get_open_ports | while read -r p; do echo "  - ${p}/tcp"; done)

📝 重要后续步骤
──────────────────────────────────────────
  1️⃣  输入 ling 打开管理菜单
  2️⃣  选择菜单第 7 项，绑定正确的 --panel 和 --token
     （当前为占位值，必须替换为你的真实面板地址和 Token）
  3️⃣  确保云平台安全组已放行端口: 80, 443, ${NPM_ADMIN_PORT}

⚠️  云服务器用户请注意
──────────────────────────────────────────
  如果你使用的是云服务器（阿里云/腾讯云/AWS 等），
  除了本机防火墙外，还需在云平台安全组/防火墙中放行上述端口。
  否则公网无法访问。

SUMMARY
}

# ============================================================
# 主流程
# ============================================================
main() {
  echo ""
  echo "============================================"
  echo "  xboard-node + Nginx Proxy Manager"
  echo "  一键自动化安装脚本"
  echo "============================================"
  echo ""
  log "脚本目录: ${SCRIPT_DIR}"

  # 预处理
  init_privilege

  # 按顺序执行各步骤
  check_linux
  ensure_curl
  check_and_enable_bbr
  install_xboard_node
  ensure_docker
  setup_npm
  install_menu
  open_firewall_ports
  print_summary

  echo ""
  log "全部安装步骤已完成！输入 ling 开始管理。"
}

main "$@"
