#!/usr/bin/env bash
# =============================================================================
# 脚本名称: ssh_key.sh
# 描    述: SSH 密钥管理工具 - 托管密钥同步、SSHD 配置、防火墙、fail2ban
# 版    本: v1.1 (security hardened)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
umask 077
# ===================== 通用工具函数（必须先定义） =====================

ts() { date '+%F %T'; }

log()  { echo "[$(ts)] [INFO]  $*" >&2; }
warn() { echo "[$(ts)] [WARN]  $*" >&2; }
die()  { echo "[$(ts)] [ERROR] $*" >&2; exit 1; }

# 需要 root 才能继续（脚本多处会调用）
require_root() {
  local uid
  uid="${EUID:-$(id -u)}"
  if [[ "$uid" -ne 0 ]]; then
    echo "[$(ts)] [ERROR] 必须以 root 权限运行。" >&2
    if command -v sudo >/dev/null 2>&1; then
      echo "[$(ts)] [ERROR] 请使用：sudo bash $0" >&2
    else
      echo "[$(ts)] [ERROR] 系统无 sudo，请切换到 root 用户再运行。" >&2
    fi
    exit 1
  fi
}

# 端口校验：1-65535 的纯数字
validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

# 如果你后面有 refresh_paths，这里提供一个“安全兜底”
# 有定义就用你自己的；没定义也不会炸
refresh_paths() { :; }

# 如果你后面有 sync_state_from_sshd，这里也提供兜底
sync_state_from_sshd() { return 0; }

# 如果你后面有 show_status，这里兜底（避免菜单一开始就报错）
show_status() {
  echo "（show_status 未实现：请在脚本其他部分提供完整实现）"
}


# 设置安全 PATH，防止 PATH 污染攻击
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# =========================================================
# 临时文件清理（异常退出时自动清理）
TEMP_FILES=()
cleanup_temp_files() {
  for f in "${TEMP_FILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup_temp_files EXIT
trap 'warn "收到中断信号"; exit 130' INT TERM HUP

register_temp_file() {
  TEMP_FILES+=("$1")
}

# 固定公钥定义区（你只需要维护这里）
SSH_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB525kOyxHEeE8DV5BXfIC9kRR3NUSEQ2yBpsw/IPo8I newnew@mydevice"
  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIIJFcDer20hJSHUh9nUDZFkzAEQ4ZDPhna+TC6fLX7NEAAAABHNzaDo= vps"
)

# 托管区块标记（脚本只管理这个区块，别的 key 不动）
MANAGED_BEGIN='# ==== BEGIN MANAGED BY ssh_key.sh ===='
MANAGED_END='# ==== END MANAGED BY ssh_key.sh ===='

# ===================== 防火墙相关 =======================
detect_firewall_backend() {
  # 返回：iptables / firewalld / ufw / none
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q '^Status: active' 2>/dev/null; then
      echo "ufw"; return 0
    fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    local pol
    pol="$(iptables -L INPUT -n 2>/dev/null | awk 'NR==1{gsub(/[()]/,""); for(i=1;i<=NF;i++) if($i=="policy"){print $(i+1); exit}}' 2>/dev/null || true)"
    if [[ "$pol" == "DROP" || "$pol" == "REJECT" ]]; then
      echo "iptables"; return 0
    fi
    if (iptables -L INPUT -n --line-numbers 2>/dev/null | tail -n +3 | grep -q . 2>/dev/null) 2>/dev/null; then
      echo "iptables"; return 0
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "firewalld"; return 0
  fi
  echo "none"
}

open_port_ufw() {
  local p="$1"
  if ufw allow "$p/tcp" >/dev/null 2>&1; then
    log "UFW 已放行 $p/tcp"
    return 0
  else
    warn "UFW 放行 $p/tcp 失败"
    return 1
  fi
}

close_port_ufw() {
  local p="$1"
  if ufw delete allow "$p/tcp" >/dev/null 2>&1; then
    log "UFW 已关闭 $p/tcp"
    return 0
  else
    warn "UFW 关闭 $p/tcp 失败"
    return 1
  fi
}

open_port_firewall() {
  require_root
  local p="$1"
  validate_port "$p" || die "非法端口：$p"

  local backend result=0
  backend="$(detect_firewall_backend)"
  case "$backend" in
    iptables)  open_port_iptables "$p" || result=1 ;;
    firewalld) open_port_firewalld "$p" || result=1 ;;
    ufw)       open_port_ufw "$p" || result=1 ;;  # 确保这里调用的是ufw
    *)
      warn "未检测到生效的防火墙后端（iptables/firewalld/ufw）"
      warn ">>> 请手动配置防火墙或云安全组放行端口 ${p}/tcp"
      result=1
      ;;
  esac

  if [[ "$result" -ne 0 ]]; then
    warn ">>> 防火墙放行端口 $p 可能失败！如果继续修改 SSHD 端口，可能导致锁死！"
    warn ">>> 建议：在另一终端保持当前 SSH 连接，或确认控制台访问可用后再继续"
  fi
  return $result
}

close_port_firewall() {
  require_root
  local p="$1"
  validate_port "$p" || die "非法端口：$p"

  local backend
  backend="$(detect_firewall_backend)"
  case "$backend" in
    iptables)  close_port_iptables "$p" ;;
    firewalld) close_port_firewalld "$p" ;;
    ufw)       close_port_ufw "$p" ;;
    *)
      if command -v ufw >/dev/null 2>&1; then close_port_ufw "$p" || true; fi
      warn "未检测到生效的防火墙后端，无法保证已关闭 ${p}/tcp"
      ;;
  esac
}

# 新增添加端口的功能
add_port_to_firewall() {
  local p="$1"
  open_port_firewall "$p" && log "端口 $p 已成功添加到防火墙" || die "添加端口 $p 失败"
}

# 新增删除端口的功能
remove_port_from_firewall() {
  local p="$1"
  close_port_firewall "$p" && log "端口 $p 已成功从防火墙中删除" || die "删除端口 $p 失败"
}

show_firewall_rules() {
  require_root
  echo
  echo "====== 防火墙规则（自动识别）======"
  local backend
  backend="$(detect_firewall_backend)"
  echo "Backend: $backend"
  case "$backend" in
    iptables)  iptables -L INPUT -n --line-numbers || true ;;
    firewalld) firewall-cmd --get-active-zones || true; firewall-cmd --list-all || true ;;
    ufw)       ufw status verbose || true ;;
    none)
      command -v ufw >/dev/null 2>&1 && ufw status verbose || true
      command -v iptables >/dev/null 2>&1 && iptables -L INPUT -n --line-numbers || true
      ;;
  esac
  echo "==================================="
  echo
}

# ===================== 其他部分（省略） ====================
# 这部分代码可以保留不变，因为只涉及 SSH 密钥配置和 fail2ban 部分
# 如有需要继续进行修改，您可以根据脚本需求调整

main_loop() {
  refresh_paths
  sync_state_from_sshd || true

  while true; do
    clear || true
    show_status

    cat <<'MENU'
[1] 显示当前状态
[2] 切换目标用户
[3] 初始化 ~/.ssh 权限
[4] 同步固定公钥（只加不减，推荐）
[5] 同步固定公钥（覆盖模式，危险）
[6] 查看 authorized_keys
[7] 切换"禁用密码登录"开关
[8] 设置 SSH 端口（不立即生效）
[9] 应用 SSHD 配置（确保公钥登录 / 可选禁用密码 / 可选改端口）
[10] 防火墙规则查看（自动识别后端）
[11] 手动持久化 iptables 规则
[12] fail2ban 安装&配置
[13] fail2ban 状态查看
[14] 备份 sshd_config
[15] 回滚 sshd_config（回滚到本次运行记录的最后备份）
[16] 添加端口到防火墙
[17] 删除端口从防火墙
[0] 退出
MENU

    read -r -p "请选择: " choice
    case "$choice" in
      1) show_status ;;
      2) select_target_user ;;
      3) setup_ssh_directory; log "~/.ssh 权限已初始化" ;;
      4) sync_fixed_keys_add_only ;;
      5) sync_fixed_keys_overwrite ;;
      6) show_authorized_keys ;;
      7) toggle_disable_password ;;
      8) set_ssh_port ;;
      9) apply_sshd_config ;;
      10) show_firewall_rules ;;
      11) persist_iptables_rules ;;
      12) configure_fail2ban ;;
      13) show_fail2ban_status ;;
      14) backup_file "$SSHD_MAIN"; [[ -f "$SSHD_DCONF" ]] && backup_file "$SSHD_DCONF" || true ;;
      15) restore_last_backup; sync_state_from_sshd ;;
      16) read -r -p "输入要添加的端口: " port_to_add; add_port_to_firewall "$port_to_add" ;;
      17) read -r -p "输入要删除的端口: " port_to_remove; remove_port_from_firewall "$port_to_remove" ;;
      0) log "Bye."; exit 0 ;;
      *) warn "无效选项：$choice" ;;
    esac
    echo
    read -r -p "回车继续..." _
  done
}

# 入口：强制 root 权限
require_root
main_loop
