#!/usr/bin/env bash
# =============================================================================
# 脚本名称: ssh_key.sh
# 描    述: SSH 密钥管理工具 - 托管密钥同步、SSHD 配置、防火墙、fail2ban
# 版    本: v1.5 (修复 stdin EOF 死循环；pad_to 改为纯 bash 实现)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
umask 077

# ===================== 通用工具函数 =====================
ts() { date '+%F %T'; }
log()  { printf "[%s] \033[32m[INFO]\033[0m  %s\n" "$(ts)" "$*" >&2; }
warn() { printf "[%s] \033[33m[WARN]\033[0m  %s\n" "$(ts)" "$*" >&2; }
die()  { printf "[%s] \033[31m[ERROR]\033[0m %s\n" "$(ts)" "$*" >&2; exit 1; }

require_root() {
  local uid="${EUID:-$(id -u)}"
  [[ "$uid" -eq 0 ]] || die "必须以 root 权限运行。请使用：sudo bash $0"
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ===================== 配置区 =====================
SSH_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB525kOyxHEeE8DV5BXfIC9kRR3NUSEQ2yBpsw/IPo8I newnew@mydevice"
  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIIJFcDer20hJSHUh9nUDZFkzAEQ4ZDPhna+TC6fLX7NEAAAABHNzaDo= vps"
)

MANAGED_BEGIN='# ==== BEGIN MANAGED BY ssh_key.sh ===='
MANAGED_END='# ==== END MANAGED BY ssh_key.sh ===='
SSHD_MAIN="/etc/ssh/sshd_config"

TARGET_USER="${TARGET_USER:-root}"
TARGET_HOME=""
AUTH_KEYS_FILE=""
CURRENT_SSH_PORT="22"
PENDING_SSH_PORT=""
# 当前值从 sshd_config 读取；DISABLE_PASSWORD 作为“待应用”的期望值，避免被状态刷新覆盖
CURRENT_DISABLE_PASSWORD="no"
DISABLE_PASSWORD="no"
PASSWORD_TOUCHED=0

# ===================== 临时文件清理 =====================
TEMP_FILES=()
cleanup_temp_files() {
  for f in "${TEMP_FILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup_temp_files EXIT
trap 'warn "收到中断信号"; exit 130' INT TERM HUP

# ===================== 防火墙检测（优化版） =====================
detect_firewall_backend() {
  if command -v ufw >/dev/null 2>&1; then
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -1 || true)
    if [[ "$ufw_status" == *"active"* ]]; then
      echo "ufw"; return 0
    fi
  fi
  
  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      echo "firewalld"; return 0
    fi
  fi
  
  if command -v nft >/dev/null 2>&1; then
    local nft_rules
    # grep -c 在“0 匹配”时会输出 0 但退出码为 1；再加上 || echo 0 会变成两行 "0\n0"
    nft_rules=$(nft list ruleset 2>/dev/null | grep -c "chain" || true)
    [[ -z "$nft_rules" ]] && nft_rules=0
    if [[ "$nft_rules" -gt 0 ]]; then
      echo "nftables"; return 0
    fi
  fi
  
  if command -v iptables >/dev/null 2>&1; then
    echo "iptables"; return 0
  fi
  
  echo "none"
}

# ===================== 防火墙操作 =====================
open_port_firewall() {
  local p="$1"
  validate_port "$p" || die "非法端口：$p"
  
  local backend
  backend="$(detect_firewall_backend)"
  log "检测到防火墙后端: $backend"
  
  case "$backend" in
    ufw)
      ufw allow "$p/tcp" comment "SSH" >/dev/null 2>&1 && log "UFW: 已放行 $p/tcp" || { warn "UFW: 放行失败"; return 1; }
      ;;
    firewalld)
      firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1 && \
      firewall-cmd --reload >/dev/null 2>&1 && log "firewalld: 已放行 $p/tcp" || { warn "firewalld: 放行失败"; return 1; }
      ;;
    nftables)
      nft add rule inet filter input tcp dport "$p" accept 2>/dev/null && log "nftables: 已放行 $p/tcp" || \
      nft add rule ip filter INPUT tcp dport "$p" accept 2>/dev/null && log "nftables: 已放行 $p/tcp" || \
      { warn "nftables: 放行失败"; return 1; }
      ;;
    iptables)
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null && log "iptables: 已放行 $p/tcp" || { warn "iptables: 放行失败"; return 1; }
      ;;
    none)
      warn "未检测到防火墙，请手动放行 $p/tcp"; return 1
      ;;
  esac
  return 0
}

close_port_firewall() {
  local p="$1"
  validate_port "$p" || die "非法端口：$p"
  
  local backend
  backend="$(detect_firewall_backend)"
  
  case "$backend" in
    ufw)      ufw delete allow "$p/tcp" >/dev/null 2>&1 && log "UFW: 已关闭 $p/tcp" ;;
    firewalld) firewall-cmd --permanent --remove-port="$p/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 && log "firewalld: 已关闭 $p/tcp" ;;
    nftables) warn "nftables: 请手动删除 $p/tcp 规则" ;;
    iptables) iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null && log "iptables: 已关闭 $p/tcp" ;;
    *)        warn "未检测到防火墙" ;;
  esac
}

show_firewall_rules() {
  local backend
  backend="$(detect_firewall_backend)"
  
  print_header "防火墙规则 (后端: $backend)"
  
  case "$backend" in
    ufw)       ufw status numbered 2>/dev/null || ufw status ;;
    firewalld) firewall-cmd --list-all 2>/dev/null ;;
    nftables)  nft list ruleset 2>/dev/null | head -50 ;;
    iptables)  iptables -L INPUT -n --line-numbers 2>/dev/null ;;
    none)      echo "未检测到活动的防火墙" ;;
  esac
}

persist_iptables_rules() {
  local backend
  backend="$(detect_firewall_backend)"
  
  case "$backend" in
    ufw|firewalld) log "$backend 自动持久化" ;;
    nftables)      nft list ruleset > /etc/nftables.conf 2>/dev/null && log "nftables: 已保存" ;;
    iptables)
      if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save && log "iptables: 已保存"
      elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 && log "iptables: 已保存到 /etc/iptables/rules.v4"
      fi
      ;;
  esac
}

# ===================== 界面函数 =====================
# 说明：中文在终端里通常是“全角”(宽度=2)，bash/printf 的字段宽度按字符数算，
# 会导致方框/竖线看起来不对齐。这里用 python3 按“显示宽度”(近似 wcwidth)做补齐。

BOX_INNER=62

pad_to() {
  local text="$1"
  local width="$2"
  local cur=0
  local ch cp i=0
  local len=${#text}
  while (( i < len )); do
    ch="${text:$i:1}"
    printf -v cp '%d' "'$ch" 2>/dev/null || cp=63
    # 东亚全角/宽字符范围（近似）：U+1100–U+11FF, U+2E80–U+303F, U+3040–U+9FFF,
    # U+A000–U+A4CF, U+AC00–U+D7AF, U+F900–U+FAFF, U+FE10–U+FE6F, U+FF00–U+FFEF,
    # U+1F300–U+1F9FF 等常见范围
    if (( (cp >= 0x1100 && cp <= 0x11FF) ||
          (cp >= 0x2E80 && cp <= 0x303F) ||
          (cp >= 0x3040 && cp <= 0x9FFF) ||
          (cp >= 0xA000 && cp <= 0xA4CF) ||
          (cp >= 0xAC00 && cp <= 0xD7AF) ||
          (cp >= 0xF900 && cp <= 0xFAFF) ||
          (cp >= 0xFE10 && cp <= 0xFE6F) ||
          (cp >= 0xFF00 && cp <= 0xFFEF) ||
          (cp >= 0x1F300 && cp <= 0x1F9FF) )); then
      (( cur += 2 ))
    else
      (( cur += 1 ))
    fi
    (( i++ ))
  done
  local pad=$(( width - cur ))
  if (( pad > 0 )); then
    printf '%s%*s' "$text" "$pad" ""
  elif (( pad == 0 )); then
    printf '%s' "$text"
  else
    # 文本超出宽度：逐字符截断，与原 python3 版本行为一致
    local out="" out_cur=0 ch_w
    i=0
    while (( i < len )); do
      ch="${text:$i:1}"
      printf -v cp '%d' "'$ch" 2>/dev/null || cp=63
      if (( (cp >= 0x1100 && cp <= 0x11FF) ||
            (cp >= 0x2E80 && cp <= 0x303F) ||
            (cp >= 0x3040 && cp <= 0x9FFF) ||
            (cp >= 0xA000 && cp <= 0xA4CF) ||
            (cp >= 0xAC00 && cp <= 0xD7AF) ||
            (cp >= 0xF900 && cp <= 0xFAFF) ||
            (cp >= 0xFE10 && cp <= 0xFE6F) ||
            (cp >= 0xFF00 && cp <= 0xFFEF) ||
            (cp >= 0x1F300 && cp <= 0x1F9FF) )); then
        ch_w=2
      else
        ch_w=1
      fi
      (( out_cur + ch_w > width )) && break
      out+="$ch"
      (( out_cur += ch_w ))
      (( i++ ))
    done
    local tail_pad=$(( width - out_cur ))
    if (( tail_pad > 0 )); then
      printf '%s%*s' "$out" "$tail_pad" ""
    else
      printf '%s' "$out"
    fi
  fi
}

print_line() {
  printf "+%s+\n" "$(printf '%.0s-' $(seq 1 $BOX_INNER))"
}

print_header() {
  local title="$1"
  echo ""
  print_line
  printf "|%s|\n" "$(pad_to "$title" "$BOX_INNER")"
  print_line
}

print_row() {
  local k="$1"
  local v="$2"
  local left right
  left="$(pad_to "$k" 20)"
  right="$(pad_to "$v" 37)"
  printf "| %s : %s |\n" "$left" "$right"
}

print_menu_header() {
  echo ""
  print_line
  printf "|%s|\n" "$(pad_to "操作菜单" "$BOX_INNER")"
  print_line
}

print_menu_item() {
  printf "|%s|\n" "$(pad_to " $1" "$BOX_INNER")"
}

print_menu_sep() {
  printf "|%s|\n" "$(printf '%.0s-' $(seq 1 $BOX_INNER))"
}
# ===================== 路径刷新 =====================
refresh_paths() {
  if [[ "$TARGET_USER" == "root" ]]; then
    TARGET_HOME="/root"
  else
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    [[ -z "$TARGET_HOME" ]] && die "用户 $TARGET_USER 不存在"
  fi
  AUTH_KEYS_FILE="$TARGET_HOME/.ssh/authorized_keys"
}

sync_state_from_sshd() {
  # 在 set -euo pipefail 下，grep 找不到匹配会返回 1，导致整个脚本直接退出。
  # 这里把“未匹配”视为正常情况（使用默认值）。
  CURRENT_SSH_PORT=$( (grep -E "^Port\s+" "$SSHD_MAIN" 2>/dev/null || true) | awk '{print $2}' | head -1 )
  [[ -z "$CURRENT_SSH_PORT" ]] && CURRENT_SSH_PORT="22"

  local pwd_auth
  pwd_auth=$( (grep -E "^PasswordAuthentication\s+" "$SSHD_MAIN" 2>/dev/null || true) | awk '{print $2}' | head -1 )
  [[ "$pwd_auth" == "no" ]] && CURRENT_DISABLE_PASSWORD="yes" || CURRENT_DISABLE_PASSWORD="no"
  # 如果用户还没做“切换密码登录”，则让待应用值跟随当前值；一旦切换过，就不再被刷新覆盖
  if [[ "${PASSWORD_TOUCHED:-0}" -eq 0 ]]; then
    DISABLE_PASSWORD="$CURRENT_DISABLE_PASSWORD"
  fi
}

# ===================== 显示状态 =====================
show_status() {
  sync_state_from_sshd
  refresh_paths
  
  local fw_backend
  fw_backend="$(detect_firewall_backend)"
  
  print_header "SSH 密钥管理工具 - 状态面板"
  print_row "目标用户" "$TARGET_USER"
  print_row "用户主目录" "$TARGET_HOME"
  print_row "authorized_keys" "$AUTH_KEYS_FILE"
  print_menu_sep
  print_row "当前 SSH 端口" "$CURRENT_SSH_PORT"
  print_row "待应用端口" "${PENDING_SSH_PORT:-(无)}"
  print_row "密码登录(当前禁用?)" "$CURRENT_DISABLE_PASSWORD"
  print_row "密码登录(待应用禁用?)" "$DISABLE_PASSWORD"
  print_menu_sep
  print_row "防火墙后端" "$fw_backend"
  print_row "托管公钥数量" "${#SSH_KEYS[@]}"
  print_line
  echo ""
}

# ===================== SSH 相关操作 =====================
select_target_user() {
  read -r -p "输入目标用户名 [默认: root]: " input_user || return 0
  TARGET_USER="${input_user:-root}"
  refresh_paths
  log "已切换到用户: $TARGET_USER"
}

setup_ssh_directory() {
  refresh_paths
  mkdir -p "$TARGET_HOME/.ssh"
  chmod 700 "$TARGET_HOME/.ssh"
  touch "$AUTH_KEYS_FILE"
  chmod 600 "$AUTH_KEYS_FILE"
  [[ "$TARGET_USER" != "root" ]] && chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.ssh"
  log "~/.ssh 目录已初始化"
}

sync_fixed_keys_add_only() {
  refresh_paths
  setup_ssh_directory
  local added=0
  for key in "${SSH_KEYS[@]}"; do
    if ! grep -qF "$key" "$AUTH_KEYS_FILE" 2>/dev/null; then
      echo "$key" >> "$AUTH_KEYS_FILE"
      ((added++))
    fi
  done
  log "同步完成，新增 $added 个公钥"
}

sync_fixed_keys_overwrite() {
  refresh_paths
  setup_ssh_directory
  backup_file "$AUTH_KEYS_FILE"

  # “覆盖”按直觉应当是：用托管公钥完全重建 authorized_keys
  # 旧实现只替换托管区块，文件里其他手工 key 会保留，用户会感觉“没覆盖”。
  local tmp
  tmp="$(mktemp)"
  TEMP_FILES+=("$tmp")

  {
    echo "$MANAGED_BEGIN"
    printf '%s\n' "${SSH_KEYS[@]}"
    echo "$MANAGED_END"
  } > "$tmp"

  cat "$tmp" > "$AUTH_KEYS_FILE"
  chmod 600 "$AUTH_KEYS_FILE"
  [[ "$TARGET_USER" != "root" ]] && chown "$TARGET_USER:$TARGET_USER" "$AUTH_KEYS_FILE" || true

  log "authorized_keys 已覆盖重建，共 ${#SSH_KEYS[@]} 个公钥"
}

show_authorized_keys() {
  refresh_paths
  print_header "authorized_keys 内容"
  [[ -f "$AUTH_KEYS_FILE" ]] && cat -n "$AUTH_KEYS_FILE" || echo "(文件不存在)"
  print_line
}

toggle_disable_password() {
  PASSWORD_TOUCHED=1
  [[ "$DISABLE_PASSWORD" == "yes" ]] && DISABLE_PASSWORD="no" || DISABLE_PASSWORD="yes"
  log "禁用密码登录(待应用) = $DISABLE_PASSWORD (需应用配置生效)"
}

set_ssh_port() {
  read -r -p "输入新的 SSH 端口 [当前: $CURRENT_SSH_PORT]: " new_port || return 0
  [[ -z "$new_port" ]] && { log "保持当前端口"; return; }
  validate_port "$new_port" || { warn "端口无效"; return; }
  PENDING_SSH_PORT="$new_port"
  log "待应用端口: $PENDING_SSH_PORT"
}

apply_sshd_config() {
  require_root
  backup_file "$SSHD_MAIN"
  
  grep -q "^PubkeyAuthentication" "$SSHD_MAIN" && \
    sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_MAIN" || \
    echo "PubkeyAuthentication yes" >> "$SSHD_MAIN"
  
  if [[ "$DISABLE_PASSWORD" == "yes" ]]; then
    grep -q "^PasswordAuthentication" "$SSHD_MAIN" && \
      sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_MAIN" || \
      echo "PasswordAuthentication no" >> "$SSHD_MAIN"
    grep -q "^ChallengeResponseAuthentication" "$SSHD_MAIN" && \
      sed -i 's/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_MAIN"
    log "已禁用密码登录"
  else
    grep -q "^PasswordAuthentication" "$SSHD_MAIN" && \
      sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_MAIN"
    log "已允许密码登录"
  fi
  
  if [[ -n "${PENDING_SSH_PORT:-}" ]]; then
    open_port_firewall "$PENDING_SSH_PORT" || warn "防火墙放行可能失败"
    grep -q "^Port" "$SSHD_MAIN" && \
      sed -i "s/^Port.*/Port $PENDING_SSH_PORT/" "$SSHD_MAIN" || \
      echo "Port $PENDING_SSH_PORT" >> "$SSHD_MAIN"
    log "SSH 端口: $PENDING_SSH_PORT"
    CURRENT_SSH_PORT="$PENDING_SSH_PORT"
    PENDING_SSH_PORT=""
  fi
  
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || warn "SSHD 重启失败"
  log "SSHD 配置已应用"
}

# ===================== 备份回滚 =====================
LAST_BACKUP=""
backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$file" "$backup"
  LAST_BACKUP="$backup"
  log "已备份: $backup"
}

restore_last_backup() {
  [[ -z "$LAST_BACKUP" || ! -f "$LAST_BACKUP" ]] && { warn "没有可回滚的备份"; return 1; }
  local original="${LAST_BACKUP%.bak.*}"
  cp "$LAST_BACKUP" "$original"
  log "已回滚: $LAST_BACKUP"
  systemctl restart sshd 2>/dev/null || service sshd restart 2>/dev/null || true
}

# ===================== UFW（安装/启用） =====================
install_enable_ufw() {
  require_root
  sync_state_from_sshd

  if ! command -v ufw >/dev/null 2>&1; then
    log "正在安装 ufw..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y ufw -qq
    elif command -v yum >/dev/null 2>&1; then
      yum install -y epel-release || true
      yum install -y ufw || die "yum 安装 ufw 失败"
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y ufw || die "dnf 安装 ufw 失败"
    else
      die "无法安装 ufw（未识别包管理器）"
    fi
  fi

  local ssh_port
  ssh_port="$CURRENT_SSH_PORT"
  [[ -z "$ssh_port" ]] && ssh_port=22

  # 重要：先放行 SSH 再启用，避免把自己锁门外
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  ufw allow "$ssh_port/tcp" comment "SSH" >/dev/null 2>&1 || true

  ufw --force enable >/dev/null 2>&1 || die "ufw enable 失败"
  log "UFW 已启用：默认拒绝入站，已放行 SSH 端口 $ssh_port/tcp"
}

# ===================== fail2ban =====================
configure_fail2ban() {
  require_root
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    log "正在安装 fail2ban..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y fail2ban -qq
    elif command -v yum >/dev/null 2>&1; then
      yum install -y epel-release && yum install -y fail2ban
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y fail2ban
    else
      die "无法安装 fail2ban"
    fi
  fi
  
  cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
maxretry = 3
bantime = 86400
EOF
  
  systemctl enable fail2ban 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || service fail2ban restart
  log "fail2ban 已配置并启动"
}

show_fail2ban_status() {
  command -v fail2ban-client >/dev/null 2>&1 || { warn "fail2ban 未安装"; return; }
  print_header "fail2ban 状态"
  fail2ban-client status 2>/dev/null || echo "未运行"
  fail2ban-client status sshd 2>/dev/null || true
  print_line
}

# ===================== 主菜单 =====================
main_loop() {
  refresh_paths
  sync_state_from_sshd
  
  while true; do
    # 非交互/无 TERM 环境下 clear 会报错并在 set -e 下直接退出
    if [[ -t 1 && -n "${TERM:-}" ]]; then clear; fi
    show_status
    
    print_menu_header
    print_menu_item "[1] 显示状态            [2] 切换用户"
    print_menu_item "[3] 初始化 ~/.ssh       [4] 同步公钥 (只加)"
    print_menu_item "[5] 同步公钥 (覆盖)     [6] 查看 authorized_keys"
    print_menu_sep
    print_menu_item "[7] 切换密码登录        [8] 设置 SSH 端口"
    print_menu_item "[9] 应用 SSHD 配置"
    print_menu_sep
    print_menu_item "[10] 查看防火墙         [11] 添加端口"
    print_menu_item "[12] 删除端口           [13] 持久化规则"
    print_menu_sep
    print_menu_item "[14] 配置 fail2ban      [15] 查看 fail2ban"
    print_menu_item "[16] 备份 sshd_config   [17] 回滚 sshd_config"
    print_menu_item "[18] 安装/启用 UFW (放行SSH)"
    print_menu_sep
    print_menu_item "[0] 退出"
    print_line
    
    read -r -p "请选择: " choice || { log "stdin 已关闭，退出"; exit 0; }
    case "$choice" in
      1) show_status ;;
      2) select_target_user ;;
      3) setup_ssh_directory ;;
      4) sync_fixed_keys_add_only ;;
      5) sync_fixed_keys_overwrite ;;
      6) show_authorized_keys ;;
      7) toggle_disable_password ;;
      8) set_ssh_port ;;
      9) apply_sshd_config ;;
      10) show_firewall_rules ;;
      11) read -r -p "端口: " port || true; [[ -n "$port" ]] && open_port_firewall "$port" ;;
      12) read -r -p "端口: " port || true; [[ -n "$port" ]] && close_port_firewall "$port" ;;
      13) persist_iptables_rules ;;
      14) configure_fail2ban ;;
      15) show_fail2ban_status ;;
      16) backup_file "$SSHD_MAIN" ;;
      17) restore_last_backup ;;
      18) install_enable_ufw ;;
      0) log "Bye."; exit 0 ;;
      *) warn "无效选项" ;;
    esac
    
    echo ""
    read -r -p "回车继续..." _ || exit 0
  done
}

require_root
main_loop
