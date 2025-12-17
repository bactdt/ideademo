#!/usr/bin/env bash
# =============================================================================
# 脚本名称: ssh_key.sh
# 描    述: SSH 密钥管理工具 - 托管密钥同步、SSHD 配置、防火墙、fail2ban
# 版    本: v1.0
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
umask 077

# =========================================================
# 固定公钥定义区（你只需要维护这里）
# 一行一个 key，不要换行
SSH_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB525kOyxHEeE8DV5BXfIC9kRR3NUSEQ2yBpsw/IPo8I newnew@mydevice"
)

# 托管区块标记（脚本只会改这里的内容）
MANAGED_BEGIN="# ==== BEGIN MANAGED BY ssh_key.sh ===="
MANAGED_END="# ==== END MANAGED BY ssh_key.sh ===="

# fail2ban jail 文件
F2B_JAIL="/etc/fail2ban/jail.d/sshd.local"

# 备份保留数量（超过此数量的旧备份将被清理）
BACKUP_KEEP_COUNT=5

# =========================================================

log()  { echo -e "$*"; }
warn() { echo -e "⚠️ $*"; }
die()  { echo -e "❌ $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限（请用 sudo 运行）"; }

# ---------- 运行状态 ----------
TARGET_USER="${SUDO_USER:-$(id -un)}"
DISABLE_PASSWORD=0
SSH_PORT=""         # 为空表示不改端口（保持现状）
OLD_SSH_PORT=""     # 读取系统当前生效端口，用于提示/关闭旧端口
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DCONF="/etc/ssh/sshd_config.d/99-keys.conf"
LAST_BACKUP=""
LAST_BACKUP_TARGET=""

# ---------- 基础 ----------
get_home_of_user() { getent passwd "$1" | awk -F: '{print $6}'; }

refresh_paths() {
  TARGET_HOME="$(get_home_of_user "$TARGET_USER" || true)"
  [[ -n "${TARGET_HOME:-}" ]] || die "用户不存在或无 home：$TARGET_USER"
  SSH_DIR="$TARGET_HOME/.ssh"
  KEY_FILE="$SSH_DIR/authorized_keys"
}

validate_pubkey_line() {
  local k="$1"
  # 检查是否包含换行/回车/制表符
  [[ "$k" != *$'\n'* && "$k" != *$'\r'* && "$k" != *$'\t'* ]] || return 1
  # 支持的密钥类型：ed25519, rsa, dss, ecdsa-sha2-nistp*, sk-ssh-ed25519, sk-ecdsa-sha2-nistp256
  [[ "$k" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/]{50,}={0,3}([[:space:]].*)?$ ]]
}

validate_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( 1 <= 10#$p && 10#$p <= 65535 ))
}

setup_ssh_directory() {
  refresh_paths
  mkdir -p "$SSH_DIR"
  chmod 0700 "$SSH_DIR"
  touch "$KEY_FILE"
  chmod 0600 "$KEY_FILE"
  chown "$TARGET_USER:$TARGET_USER" "$SSH_DIR" "$KEY_FILE" 2>/dev/null || true
}

detect_uses_dconf() {
  [[ -f "$SSHD_MAIN" ]] || return 1
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "$SSHD_MAIN"
}

choose_sshd_target() {
  if detect_uses_dconf; then
    echo "$SSHD_DCONF"
  else
    echo "$SSHD_MAIN"
  fi
}

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local b="${f}.bak.$(date +%F_%H%M%S)"
  cp -a "$f" "$b"
  LAST_BACKUP="$b"
  LAST_BACKUP_TARGET="$f"
  log "✅ 已备份：$b"
  # 清理旧备份
  cleanup_old_backups "$f"
}

# 清理旧备份，保留最近 BACKUP_KEEP_COUNT 个
cleanup_old_backups() {
  local f="$1"
  local pattern="${f}.bak.*"
  local count
  count="$(find "$(dirname "$f")" -maxdepth 1 -name "$(basename "$f").bak.*" -type f 2>/dev/null | wc -l)"
  if (( count > BACKUP_KEEP_COUNT )); then
    local to_delete
    to_delete="$(find "$(dirname "$f")" -maxdepth 1 -name "$(basename "$f").bak.*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n "$((count - BACKUP_KEEP_COUNT))" | cut -d' ' -f2-)"
    if [[ -n "$to_delete" ]]; then
      echo "$to_delete" | while IFS= read -r old_bak; do
        rm -f "$old_bak" && log "🗑️ 已清理旧备份：$old_bak"
      done
    fi
  fi
}

restore_last_backup() {
  require_root
  [[ -n "$LAST_BACKUP" && -n "$LAST_BACKUP_TARGET" ]] || die "没有记录到备份（仅本次运行内创建的备份可回滚）"
  [[ -f "$LAST_BACKUP" ]] || die "备份不存在：$LAST_BACKUP"
  cp -a "$LAST_BACKUP" "$LAST_BACKUP_TARGET"
  log "✅ 已回滚：$LAST_BACKUP_TARGET  ←  $LAST_BACKUP"

  # 如果回滚的是 sshd 配置文件，自动重载 sshd
  if [[ "$LAST_BACKUP_TARGET" == "$SSHD_MAIN" || "$LAST_BACKUP_TARGET" == "$SSHD_DCONF" ]]; then
    log "ℹ️ 检测到回滚的是 sshd 配置，正在重载 sshd..."
    if sshd -t 2>/dev/null; then
      reload_sshd
      log "✅ sshd 已重载"
    else
      warn "sshd 配置校验失败（sshd -t），请手动检查并重载"
    fi
  fi
}

detect_sshd_service_name() {
  # 先优先用真正 enabled 的 ssh.service（在很多 Debian/Ubuntu 上就是它）
  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1,$2}' | grep -q '^ssh\.service[[:space:]]\+enabled'; then
    echo "ssh"
    return
  fi

  # 再尝试 sshd.service（有些系统是它）
  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1,$2}' | grep -q '^sshd\.service[[:space:]]\+enabled'; then
    echo "sshd"
    return
  fi

  # 如果 sshd 是 alias，也可以直接使用 ssh（更稳）
  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1,$2}' | grep -q '^sshd\.service[[:space:]]\+alias'; then
    echo "ssh"
    return
  fi

  echo ""
}


reload_sshd() {
  sshd -t || die "sshd 配置校验失败"

  if command -v systemctl >/dev/null 2>&1; then
    local svc
    svc="$(detect_sshd_service_name)"
    if [[ -n "$svc" ]]; then
      systemctl reload "$svc" || systemctl restart "$svc"
      return 0
    fi
  fi

  pkill -HUP sshd || die "无法重载 sshd"
}



# ---------- 托管式密钥管理 ----------
sync_authorized_keys_managed_block() {
  refresh_paths
  setup_ssh_directory

  # 使用统一备份函数，支持回滚
  backup_file "$KEY_FILE"

  # 先移除旧托管区块（保留其它内容）
  # 在目标目录创建临时文件，避免跨文件系统移动和权限问题
  local tmp
  tmp="$(mktemp "$SSH_DIR/tmp.XXXXXX")"
  # 确保临时文件有正确权限
  chmod 0600 "$tmp"

  awk -v b="$MANAGED_BEGIN" -v e="$MANAGED_END" '
    $0==b {in_block=1; next}
    $0==e {in_block=0; next}
    !in_block {print}
  ' "$KEY_FILE" > "$tmp" 2>/dev/null || true

  # 追加新的托管区块
  {
    echo "$MANAGED_BEGIN"
    for k in "${SSH_KEYS[@]}"; do
      validate_pubkey_line "$k" || die "公钥格式错误：${k:0:80}..."
      echo "$k"
    done
    echo "$MANAGED_END"
  } >> "$tmp"

  # 替换（使用 root 权限操作，最后再修正所有权）
  mv "$tmp" "$KEY_FILE"
  chmod 0600 "$KEY_FILE"
  chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$KEY_FILE" 2>/dev/null || true
  log "✅ 已同步托管密钥区块（可通过修改脚本 SSH_KEYS 来新增/撤销托管 key；非托管 key 不受影响）"
}

show_authorized_keys() {
  refresh_paths
  [[ -f "$KEY_FILE" ]] || die "不存在：$KEY_FILE"
  echo "----- $KEY_FILE -----"
  nl -ba "$KEY_FILE" | sed -e 's/\t/    /g'
  echo "---------------------"
}

# ---------- 防火墙：增/删端口 ----------
open_port_ufw() { ufw allow "${1}/tcp" >/dev/null; log "✅ UFW 已放行：${1}/tcp"; }
close_port_ufw() { ufw delete allow "${1}/tcp" >/dev/null || true; log "✅ UFW 已删除：${1}/tcp"; }

open_port_firewalld() {
  firewall-cmd --permanent --add-port="${1}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
  log "✅ firewalld 已放行（permanent）：${1}/tcp"
}
close_port_firewalld() {
  firewall-cmd --permanent --remove-port="${1}/tcp" >/dev/null || true
  firewall-cmd --reload >/dev/null
  log "✅ firewalld 已删除（permanent）：${1}/tcp"
}

open_port_iptables() {
  local p="$1"
  if iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
    log "✅ iptables 已存在放行规则：${p}/tcp"
  else
    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    log "✅ iptables 已放行：${p}/tcp（可能不持久）"
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null || true
    log "ℹ️ 已尝试 netfilter-persistent 保存规则"
  else
    warn "iptables 规则可能在重启后丢失（未检测到 netfilter-persistent）"
  fi
}
close_port_iptables() {
  local p="$1"
  iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
  log "⚠️ iptables 已尝试删除：${p}/tcp（请确认是否持久化）"
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null || true
    log "ℹ️ 已尝试 netfilter-persistent 保存规则"
  fi
}

open_port_firewall() {
  require_root
  local p="$1"
  validate_port "$p" || die "非法端口：$p"

  if command -v ufw >/dev/null 2>&1; then
    open_port_ufw "$p"; return 0
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    open_port_firewalld "$p"; return 0
  fi
  if command -v iptables >/dev/null 2>&1; then
    open_port_iptables "$p"; return 0
  fi
  warn "未检测到 ufw/firewalld/iptables，无法自动放行 ${p}/tcp"
}

close_port_firewall() {
  require_root
  local p="$1"
  validate_port "$p" || die "非法端口：$p"

  if command -v ufw >/dev/null 2>&1; then
    close_port_ufw "$p"; return 0
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    close_port_firewalld "$p"; return 0
  fi
  if command -v iptables >/dev/null 2>&1; then
    close_port_iptables "$p"; return 0
  fi
  warn "未检测到 ufw/firewalld/iptables，无法自动删除 ${p}/tcp"
}

show_firewall_rules() {
  require_root
  echo
  echo "====== 防火墙规则（自动识别）======"
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --get-active-zones || true
    firewall-cmd --list-all || true
  elif command -v iptables >/dev/null 2>&1; then
    iptables -L INPUT -n --line-numbers || true
  else
    echo "未检测到 ufw/firewalld/iptables"
  fi
  echo "==================================="
  echo
}

# ---------- SELinux：允许 sshd 绑定新端口 ----------
selinux_is_enforcing() {
  command -v getenforce >/dev/null 2>&1 || return 1
  [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]
}

ensure_selinux_ssh_port() {
  local p="$1"
  validate_port "$p" || die "非法端口：$p"
  selinux_is_enforcing || return 0

  if ! command -v semanage >/dev/null 2>&1; then
    warn "SELinux 为 Enforcing，但没有 semanage；将尝试安装 policycoreutils-python-utils"
    if command -v dnf >/dev/null 2>&1; then
      dnf -y install policycoreutils-python-utils >/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
      yum -y install policycoreutils-python-utils >/dev/null || true
    elif command -v apt >/dev/null 2>&1; then
      apt update >/dev/null || true
      apt install -y policycoreutils-python-utils >/dev/null || true
    fi
  fi

  command -v semanage >/dev/null 2>&1 || die "SELinux Enforcing 且缺少 semanage，无法自动放行 ssh 端口（请安装 policycoreutils-python-utils）"

  # 已存在则跳过；不存在就 add；如果存在但类型不对则 modify
  if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t"{print $4}' | grep -qw "$p"; then
    log "✅ SELinux：端口 $p 已在 ssh_port_t 中"
    return 0
  fi

  semanage port -a -t ssh_port_t -p tcp "$p" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$p"
  log "✅ SELinux：已允许 sshd 使用端口 $p（ssh_port_t）"
}

# ---------- SSHD：生效配置查看 ----------
show_effective_sshd_config() {
  require_root
  need_cmd sshd
  echo
  echo "====== SSHD 最终生效配置（sshd -T）======"
  sshd -T | grep -Ei \
'^(port|listenaddress|pubkeyauthentication|passwordauthentication|permitrootlogin|allowusers|denyusers|clientaliveinterval|clientalivecountmax)[[:space:]]'
  echo "========================================="
  echo
}

# ---------- 防锁死自检 ----------
preflight_lockout_check() {
  require_root
  need_cmd sshd

  # 1) 托管 key 不能为空
  if [[ "${#SSH_KEYS[@]}" -lt 1 ]]; then
    die "SSH_KEYS 为空：禁止执行（否则可能锁死）"
  fi

  # 2) 如果要禁用密码，必须确保 authorized_keys 存在且非空（至少有托管块）
  refresh_paths
  setup_ssh_directory
  if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
    if ! [[ -s "$KEY_FILE" ]]; then
      die "你选择禁用密码登录，但 authorized_keys 为空：禁止执行（锁死风险）"
    fi
  fi

  # 3) 端口校验
  if [[ -n "$SSH_PORT" ]]; then
    validate_port "$SSH_PORT" || die "拟设置的 SSH_PORT 非法：$SSH_PORT"
  fi

  # 4) 如果 SELinux Enforcing 且要改端口，必须确保能放行（否则你之前的 Permission denied 会重现）
  if [[ -n "$SSH_PORT" ]] && selinux_is_enforcing; then
    # 不在这里修改，只检查工具是否具备
    if ! command -v semanage >/dev/null 2>&1; then
      warn "SELinux=Enforcing 且你要改端口，但当前无 semanage；应用时会尝试安装。"
    fi
  fi

  # 5) sshd 语法预检（在写入后还会再检）
  sshd -t || die "当前 sshd 配置本身就不通过（sshd -t 失败），先修复再操作"

  log "✅ 防锁死自检通过"
}

# ---------- 应用 SSHD 配置（合并策略，不破坏原有设置） ----------
apply_sshd_config() {
  preflight_lockout_check

  local target
  target="$(choose_sshd_target)"

  if [[ "$target" == "$SSHD_DCONF" ]]; then
    # dconf 模式：直接写入独立文件（推荐，不影响主配置）
    mkdir -p "$(dirname "$target")"
    log "ℹ️ 使用 dconf 模式写入：$target"
    backup_file "$target"

    {
      echo "# Managed by ssh_key.sh - $(date +%F_%H%M%S)"
      [[ -n "$SSH_PORT" ]] && echo "Port $SSH_PORT"
      echo "PubkeyAuthentication yes"
      [[ "$DISABLE_PASSWORD" -eq 1 ]] && echo "PasswordAuthentication no"
    } > "$target"
    chmod 0644 "$target"
  else
    # 主配置模式：使用合并策略，保留原有安全设置
    warn "未检测到 dconf Include，将合并修改主配置：$target"
    backup_file "$target"

    # 使用 awk 只注释全局配置，保留 Match 块内的配置不变
    local tmp
    tmp="$(mktemp)"
    [[ -n "$tmp" ]] || die "创建临时文件失败"

    # awk 逻辑：跟踪 Match 块，只在全局作用域注释相关配置
    awk '
      BEGIN { in_match = 0 }
      # 检测 Match 块开始（行首 Match，不区分大小写）
      /^[[:space:]]*[Mm]atch[[:space:]]/ { in_match = 1; print; next }
      # 检测 Match 块结束：遇到行首非空白字符的配置（非注释）
      in_match && /^[^[:space:]#]/ { in_match = 0 }
      # 全局作用域：注释掉冲突配置
      !in_match && /^[[:space:]]*Port[[:space:]]+/ {
        print "#DISABLED_BY_ssh_key.sh# " $0; next
      }
      !in_match && /^[[:space:]]*PubkeyAuthentication[[:space:]]+/i {
        print "#DISABLED_BY_ssh_key.sh# " $0; next
      }
      !in_match && /^[[:space:]]*PasswordAuthentication[[:space:]]+/i {
        print "#DISABLED_BY_ssh_key.sh# " $0; next
      }
      { print }
    ' "$target" > "$tmp"

    # 追加托管配置块（放在文件末尾，Match 块之前生效）
    {
      echo ""
      echo "# ========== BEGIN MANAGED BY ssh_key.sh =========="
      [[ -n "$SSH_PORT" ]] && echo "Port $SSH_PORT"
      echo "PubkeyAuthentication yes"
      [[ "$DISABLE_PASSWORD" -eq 1 ]] && echo "PasswordAuthentication no"
      echo "# ========== END MANAGED BY ssh_key.sh =========="
    } >> "$tmp"

    mv "$tmp" "$target"
    chmod 0600 "$target"
    log "✅ 已合并配置（Match 块内的细粒度策略已保留）"
  fi

  # 如果改端口：先放行防火墙 + SELinux（降低锁死风险）
  if [[ -n "$SSH_PORT" ]]; then
    open_port_firewall "$SSH_PORT"
    ensure_selinux_ssh_port "$SSH_PORT"
  fi

  # 最后再 reload/restart
  reload_sshd

  if [[ -n "$SSH_PORT" ]]; then
    warn "端口已配置为 $SSH_PORT。请立即新开终端测试：ssh -p $SSH_PORT user@host"
  fi
  if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
    warn "已禁用密码登录。务必确认新会话密钥可登录后再断开当前会话。"
  fi
  log "✅ SSHD 配置已应用"
}

# ---------- 同步脚本状态（让菜单显示真实生效值） ----------
sync_state_from_sshd() {
  # 从 sshd 的“最终生效配置”同步状态
  # 注意：在某些系统/配置告警下，sshd -T 会返回非 0
  # 如果不吞掉退出码，在 set -euo pipefail 下脚本会直接退出（你现在遇到的就是这个）
  [[ "$(id -u)" -eq 0 ]] || return 0
  command -v sshd >/dev/null 2>&1 || return 0

  local out
  out="$(sshd -T 2>/dev/null || true)"

  # 端口：可能有多个，这里取第一个用于“当前端口显示”
  OLD_SSH_PORT="$(awk '$1=="port"{print $2; exit}' <<<"$out" || true)"

  # 密码登录状态
  local pa
  pa="$(awk '$1=="passwordauthentication"{print $2; exit}' <<<"$out" || true)"
  if [[ "$pa" == "no" ]]; then
    DISABLE_PASSWORD=1
  elif [[ "$pa" == "yes" ]]; then
    DISABLE_PASSWORD=0
  fi
}


# ---------- 设置项 ----------
set_ssh_port() {
  read -r -p "请输入新的 SSH 端口 (1-65535): " p
  validate_port "$p" || die "非法端口：$p"
  SSH_PORT="$p"
  warn "已设置 SSH_PORT=$SSH_PORT（尚未生效，需应用 SSHD 配置）"
}

toggle_disable_password() {
  if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
    DISABLE_PASSWORD=0
    log "已关闭：禁用密码登录"
  else
    DISABLE_PASSWORD=1
    warn "已开启：禁用密码登录（⚠️ 锁死风险，应用前会做自检）"
  fi
}

select_target_user() {
  read -r -p "输入目标用户名（当前：$TARGET_USER）: " u
  [[ -n "${u:-}" ]] || return 0
  local home
  home="$(get_home_of_user "$u" || true)"
  [[ -n "$home" ]] || die "用户不存在：$u"
  TARGET_USER="$u"
  refresh_paths
  log "✅ 目标用户已切换：$TARGET_USER（home: $TARGET_HOME）"
}

# ---------- fail2ban：安装与配置 ----------

# 修复 CentOS 8 EOL 仓库问题
fix_centos8_repos() {
  # 检测是否为 CentOS 8
  if [[ -f /etc/centos-release ]] && grep -q "CentOS.*8" /etc/centos-release 2>/dev/null; then
    if grep -q "mirrorlist" /etc/yum.repos.d/CentOS-*.repo 2>/dev/null; then
      warn "检测到 CentOS 8 (EOL)，正在切换到 vault 仓库..."
      sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
      sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
      log "✅ 已切换到 vault.centos.org"
    fi
  fi
}

install_fail2ban() {
  require_root
  if command -v fail2ban-client >/dev/null 2>&1; then
    log "✅ fail2ban 已安装"
    return 0
  fi

  log "正在安装 fail2ban..."

  if command -v apt >/dev/null 2>&1; then
    # Debian/Ubuntu
    apt update || warn "apt update 失败，继续尝试安装"
    apt install -y fail2ban || { warn "fail2ban 安装失败"; return 1; }

  elif command -v dnf >/dev/null 2>&1; then
    # RHEL 8+/CentOS 8+/Fedora
    fix_centos8_repos

    # 安装 EPEL（fail2ban 在 EPEL 仓库）
    if ! rpm -q epel-release >/dev/null 2>&1; then
      log "安装 EPEL 仓库..."
      dnf -y install epel-release || warn "EPEL 安装失败"
    fi

    # 安装依赖（使用 --allowerasing 解决包冲突）
    log "安装依赖包..."
    if ! dnf -y install nftables python3-systemd 2>/dev/null; then
      warn "常规安装失败，尝试 --allowerasing 解决冲突..."
      dnf -y --allowerasing install nftables python3-systemd 2>/dev/null || {
        warn "依赖安装失败，检测包冲突..."
        # 显示冲突的 el7 包
        local el7_pkgs
        el7_pkgs="$(rpm -qa | grep -E '\.el7' | head -5)"
        if [[ -n "$el7_pkgs" ]]; then
          echo "─────────────────────────────────────"
          warn "检测到 CentOS 7 遗留包（可能是升级残留）："
          echo "$el7_pkgs"
          echo "..."
          echo "建议手动清理: dnf remove systemd-python"
          echo "或强制: dnf -y --allowerasing install fail2ban"
          echo "─────────────────────────────────────"
        fi
      }
    fi

    # 安装 fail2ban（使用 --allowerasing）
    if ! dnf -y install fail2ban 2>/dev/null; then
      log "尝试 --allowerasing 安装 fail2ban..."
      dnf -y --allowerasing install fail2ban || {
        warn "fail2ban 安装失败"
        warn "可尝试: dnf remove systemd-python && dnf install fail2ban"
        return 1
      }
    fi

  elif command -v yum >/dev/null 2>&1; then
    # RHEL 7/CentOS 7
    if ! rpm -q epel-release >/dev/null 2>&1; then
      log "安装 EPEL 仓库..."
      yum -y install epel-release || warn "EPEL 安装失败"
    fi
    yum -y install fail2ban || { warn "fail2ban 安装失败"; return 1; }

  else
    warn "无法识别包管理器，请手动安装 fail2ban"
    return 1
  fi

  # 验证安装
  if command -v fail2ban-client >/dev/null 2>&1; then
    log "✅ fail2ban 安装完成"
    return 0
  else
    warn "fail2ban 安装后未找到命令，请检查"
    return 1
  fi
}

configure_fail2ban() {
  require_root

  # 安装 fail2ban（失败时不退出，仅警告）
  if ! install_fail2ban; then
    warn "fail2ban 安装失败，跳过配置"
    return 1
  fi

  # 端口：优先用你设置的 SSH_PORT；否则用系统当前生效端口；再否则 22
  local port_to_use=""
  if [[ -n "$SSH_PORT" ]]; then
    port_to_use="$SSH_PORT"
  else
    sync_state_from_sshd
    port_to_use="${OLD_SSH_PORT:-22}"
  fi

  # 备份现有配置
  mkdir -p "$(dirname "$F2B_JAIL")"
  [[ -f "$F2B_JAIL" ]] && backup_file "$F2B_JAIL"

  # 写入新配置
  cat >"$F2B_JAIL" <<EOF
[sshd]
enabled = true
port = ${port_to_use}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
action = %(action_mwl)s
EOF

  # 启动服务（带错误处理）
  if systemctl enable fail2ban --now 2>/dev/null; then
    systemctl restart fail2ban 2>/dev/null || warn "fail2ban 重启失败"
    log "✅ fail2ban 已配置：端口=${port_to_use}"
  else
    warn "fail2ban 服务启动失败，请手动检查"
  fi
}

show_fail2ban_status() {
  require_root
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    warn "fail2ban 未安装"
    return 0
  fi
  echo
  echo "====== fail2ban 状态 ======"
  fail2ban-client status || true
  echo
  fail2ban-client status sshd || true
  echo "=========================="
  echo
}

# ---------- 端口切换完成（关闭旧端口三重保险） ----------
finalize_port_change() {
  require_root
  sync_state_from_sshd

  local current_port="${OLD_SSH_PORT:-22}"

  echo "══════ 端口切换完成向导（三重保险）══════"
  echo "当前 SSHD 监听端口: $current_port"

  # 检查是否已经改过端口
  if [[ "$current_port" == "22" ]]; then
    warn "当前仍在监听默认端口 22，请先执行 [5]+[8]"
    return 0
  fi

  echo "⚠️  请先用新端口测试: ssh -p $current_port user@host"
  read -r -p "已测试成功？[y/N]: " confirm
  [[ "${confirm:-}" =~ ^[Yy]$ ]] || { warn "请先测试"; return 0; }

  # Step 1: 检查 22 端口监听状态
  local listening_22
  listening_22="$(ss -tlnp 2>/dev/null | grep ':22[[:space:]]' || true)"
  if [[ -z "$listening_22" ]]; then
    log "✅ 1/3 sshd 不再监听 22"
  else
    warn "⚠️ 端口 22 仍在监听"
    read -r -p "继续？[y/N]: " cont
    [[ "${cont:-}" =~ ^[Yy]$ ]] || return 0
  fi

  # Step 2: 关闭防火墙
  read -r -p "关闭防火墙 22 端口？[Y/n]: " fw_confirm
  if [[ ! "${fw_confirm:-Y}" =~ ^[Nn]$ ]]; then
    close_port_firewall 22
    log "✅ 2/3 防火墙已删除 22"
  fi

  # Step 3: 云安全组提示
  echo "─────────────────────────────────────"
  echo "📋 3/3 云安全组（手动）:"
  echo "  1. 确认已放行: ${current_port}/TCP"
  echo "  2. 删除旧规则: 22/TCP"
  echo "  阿里云: ECS→安全组 | 腾讯云: CVM→安全组"
  echo "  AWS: EC2→Security Groups | Azure: VM→网络"
  echo "─────────────────────────────────────"
  read -r -p "已完成云安全组？[y/N]: " cloud_confirm
  [[ "${cloud_confirm:-}" =~ ^[Yy]$ ]] && log "✅ 3/3 云安全组已确认"

  log "🎉 端口切换完成！新端口: $current_port"
}

# ---------- 状态展示 ----------
show_status() {
  refresh_paths
  echo
  echo "====== 当前状态 ======"
  echo "运行用户: $(id -un) (uid=$(id -u))"
  echo "目标用户: $TARGET_USER"
  echo "authorized_keys: $KEY_FILE"
  echo "托管 key 条数: ${#SSH_KEYS[@]}"
  echo "拟设置 SSH_PORT: ${SSH_PORT:-不修改}"
  echo "系统当前生效端口: ${OLD_SSH_PORT:-未知（可用菜单查看生效配置）}"
  echo "禁用密码登录(当前显示): $([[ "$DISABLE_PASSWORD" -eq 1 ]] && echo 开启 || echo 关闭)"
  echo "最近备份: ${LAST_BACKUP:-无}"
  echo "======================"
  echo
}

# ---------- 菜单 ----------
menu() {
  cat <<'EOF'
═══════════════════ SSH 密钥管理工具 v1.0 ═══════════════════
📋 推荐流程: [3]同步密钥 → [5]设端口 → [7]自检 → [8]应用 → [16]完成切换

─── 基本 ───                    ─── SSHD ───
 [1] 当前状态  [2] 切换用户       [5] 设置端口    [6] 禁用密码
                                  [7] 防锁死自检  [8] 应用配置
─── 密钥 ───                      [9] 查看生效配置
 [3] 同步密钥  [4] 查看密钥
                                ─── 端口切换完成 ───
─── 防火墙 ───                   [16] 🔒 三重保险向导
 [10] 放行    [11] 删除              (停监听+关防火墙+云安全组提示)
 [12] 查看规则
                                ─── 其他 ───
─── fail2ban ───                 [15] 回滚备份
 [13] 安装配置 [14] 查看状态      [0] 退出

⚠️ 改端口后务必新开终端测试，确认能登录后再执行[16]关闭旧端口！
EOF
}

main_loop() {
  refresh_paths
  sync_state_from_sshd

  while true; do
    clear || true
    menu
    read -r -p "请选择: " choice
    case "${choice:-}" in
      1) show_status ;;
      2) select_target_user ;;
      3) sync_authorized_keys_managed_block ;;
      4) show_authorized_keys ;;
      5) set_ssh_port ;;
      6) toggle_disable_password ;;
      7) preflight_lockout_check ;;
      8) apply_sshd_config; sync_state_from_sshd ;;
      9) show_effective_sshd_config; sync_state_from_sshd ;;
      10)
        read -r -p "请输入要放行的端口: " p
        open_port_firewall "$p"
        ;;
      11)
        read -r -p "请输入要删除/关闭的端口（如 22）: " p
        close_port_firewall "$p"
        ;;
      12) show_firewall_rules ;;
      13) configure_fail2ban ;;
      14) show_fail2ban_status ;;
      15) restore_last_backup; sync_state_from_sshd ;;
      16) finalize_port_change ;;
      0) log "Bye."; exit 0 ;;
      *) warn "无效选项：$choice" ;;
    esac
    echo
    read -r -p "回车继续..." _
  done
}

main_loop
