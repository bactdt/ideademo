#!/usr/bin/env bash
# =============================================================================
# 脚本名称: ssh_key.sh
# 描    述: SSH 密钥管理工具 - 托管密钥同步、SSHD 配置、防火墙、fail2ban
# 版    本: v1.6 (认证策略显式化、SSHD 生效值校验与回滚保护)
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
SSHD_AUTH_BEGIN='# ==== BEGIN SSH AUTH MANAGED BY ssh_key.sh ===='
SSHD_AUTH_END='# ==== END SSH AUTH MANAGED BY ssh_key.sh ===='
SSHD_BIN="${SSHD_BIN:-}"

TARGET_USER="${TARGET_USER:-root}"
TARGET_HOME=""
AUTH_KEYS_FILE=""
CURRENT_SSH_PORT="22"
PENDING_SSH_PORT=""
# 认证项影响整个 sshd；TARGET_USER 仅用于 managed authorized_keys 和安全检查。
CURRENT_PASSWORD_AUTH="unknown"
CURRENT_PUBKEY_AUTH="unknown"
CURRENT_KBDINT_AUTH="unknown"
CURRENT_PERMIT_ROOT_LOGIN="unknown"
CURRENT_AUTHENTICATION_METHODS="unknown"
PASSWORD_AUTH="yes"
PUBKEY_AUTH="yes"
KBDINT_AUTH="yes"
PASSWORD_TOUCHED=0
PUBKEY_TOUCHED=0
KBDINT_TOUCHED=0

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

find_sshd_binary() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
    return 0
  fi
  [[ -x "/usr/sbin/sshd" ]] && { printf '%s\n' "/usr/sbin/sshd"; return 0; }
  return 1
}

ensure_sshd_binary() {
  if [[ -n "$SSHD_BIN" ]]; then
    command -v "$SSHD_BIN" >/dev/null 2>&1 || [[ -x "$SSHD_BIN" ]] || die "找不到 sshd: $SSHD_BIN"
    SSHD_BIN="$(command -v "$SSHD_BIN" 2>/dev/null || printf '%s\n' "$SSHD_BIN")"
    return 0
  fi
  SSHD_BIN="$(find_sshd_binary)" || die "未找到 sshd，无法读取或校验 SSHD 配置"
}

sshd_effective_values() {
  local option="$1"
  "$SSHD_BIN" -T -f "$SSHD_MAIN" 2>/dev/null | awk -v option="$option" '$1 == option { print $2 }'
}

sshd_effective_value() {
  local option="$1"
  sshd_effective_values "$option" | head -1
}

sshd_effective_arguments() {
  local option="$1"
  "$SSHD_BIN" -T -f "$SSHD_MAIN" 2>/dev/null | awk -v option="$option" '
    $1 == option {
      $1=""
      sub(/^[[:space:]]+/, "")
      print
      exit
    }
  '
}

normalize_yes_no() {
  case "$1" in
    yes|no) printf '%s\n' "$1" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

auth_state_label() {
  case "$1" in
    yes) printf '%s\n' "启用" ;;
    no) printf '%s\n' "禁用" ;;
    *) printf '%s\n' "未知" ;;
  esac
}

authentication_methods_label() {
  case "$CURRENT_AUTHENTICATION_METHODS" in
    any) printf '%s\n' "默认(any)" ;;
    unknown) printf '%s\n' "未知" ;;
    *) printf '%s\n' "自定义(拒绝自动修改)" ;;
  esac
}

sshd_config_files() {
  local file
  printf '%s\n' "$SSHD_MAIN"
  for file in "${SSHD_MAIN}.d/"*; do
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
}

sshd_include_paths() {
  local file="$1"
  awk '
    tolower($1) == "include" {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^#/) break
        print $i
      }
    }
  ' "$file"
}

is_supported_include_path() {
  local include_path="$1" ssh_dir
  ssh_dir="$(dirname "$SSHD_MAIN")"
  case "$include_path" in
    "${SSHD_MAIN}.d/"*|"$ssh_dir/sshd_config.d/"*|"sshd_config.d/"*) return 0 ;;
    *) return 1 ;;
  esac
}

has_unmanaged_include() {
  local file include_path
  while IFS= read -r file; do
    while IFS= read -r include_path; do
      [[ -n "$include_path" ]] || continue
      is_supported_include_path "$include_path" || return 0
    done < <(sshd_include_paths "$file")
  done < <(sshd_config_files)
  return 1
}

has_active_match_rule() {
  local file
  while IFS= read -r file; do
    if awk 'tolower($1) == "match" { found=1 } END { exit !found }' "$file"; then
      return 0
    fi
  done < <(sshd_config_files)
  return 1
}

authorized_keys_file_is_effective() {
  refresh_paths
  local configured_paths path old_ifs
  local -a paths=()
  configured_paths="$(sshd_effective_arguments authorizedkeysfile || true)"
  [[ -n "$configured_paths" && "$configured_paths" != "none" ]] || return 1

  old_ifs="$IFS"
  IFS=$' \t' read -r -a paths <<< "$configured_paths"
  IFS="$old_ifs"
  for path in "${paths[@]}"; do
    [[ "$path" == "none" ]] && continue
    path="${path//%h/$TARGET_HOME}"
    path="${path//%u/$TARGET_USER}"
    [[ "$path" == /* ]] || path="$TARGET_HOME/$path"
    [[ "$path" == "$AUTH_KEYS_FILE" ]] && return 0
  done
  return 1
}

has_usable_authorized_key() {
  refresh_paths
  authorized_keys_file_is_effective || return 1
  command -v ssh-keygen >/dev/null 2>&1 || return 1
  [[ -s "$AUTH_KEYS_FILE" ]] || return 1
  ssh-keygen -lf "$AUTH_KEYS_FILE" >/dev/null 2>&1
}

managed_auth_block_is_well_formed() {
  awk -v begin="$SSHD_AUTH_BEGIN" -v end="$SSHD_AUTH_END" '
    BEGIN { ok=1; inside=0; begins=0; ends=0 }
    $0 == begin {
      if (inside || begins >= 1) ok=0
      inside=1
      begins++
      next
    }
    $0 == end {
      if (!inside || ends >= 1) ok=0
      inside=0
      ends++
      next
    }
    END { exit !(ok && !inside && begins == ends && begins <= 1) }
  ' "$SSHD_MAIN"
}

copy_file_preserving_metadata() {
  local source="$1" destination="$2"
  if cp --preserve=all "$source" "$destination" 2>/dev/null; then
    return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]] && cp -p "$source" "$destination"; then
    return 0
  fi
  warn "无法保留 $source 的完整元数据，已拒绝替换 SSHD 配置"
  return 1
}

prepare_sshd_temp() {
  local tmp="$1"
  [[ -f "$SSHD_MAIN" && ! -L "$SSHD_MAIN" ]] || {
    warn "$SSHD_MAIN 不是可安全替换的常规文件"
    return 1
  }
  copy_file_preserving_metadata "$SSHD_MAIN" "$tmp"
}

replace_sshd_main_from() {
  local source="$1" tmp
  [[ -f "$source" ]] || return 1
  tmp="$(mktemp "${SSHD_MAIN}.tmp.XXXXXX")" || return 1
  TEMP_FILES+=("$tmp")
  prepare_sshd_temp "$tmp" || return 1
  copy_file_preserving_metadata "$source" "$tmp" || return 1
  mv -f "$tmp" "$SSHD_MAIN"
}

write_managed_auth_block() {
  managed_auth_block_is_well_formed || {
    warn "检测到损坏、倒置或重复的 ssh_key.sh 认证配置块，已拒绝覆盖"
    return 1
  }

  local tmp
  tmp="$(mktemp "${SSHD_MAIN}.tmp.XXXXXX")" || {
    warn "无法创建 SSHD 配置临时文件"
    return 1
  }
  TEMP_FILES+=("$tmp")
  prepare_sshd_temp "$tmp" || return 1

  # sshd 对多数配置项采用首次出现的值，因此托管块必须位于 Include 之前。
  {
    printf '%s\n' "$SSHD_AUTH_BEGIN"
    printf 'PasswordAuthentication %s\n' "$PASSWORD_AUTH"
    printf 'KbdInteractiveAuthentication %s\n' "$KBDINT_AUTH"
    printf 'PubkeyAuthentication %s\n' "$PUBKEY_AUTH"
    printf '%s\n' "$SSHD_AUTH_END"
    awk -v begin="$SSHD_AUTH_BEGIN" -v end="$SSHD_AUTH_END" '
      $0 == begin { managed=1; next }
      managed && $0 == end { managed=0; next }
      !managed { print }
    ' "$SSHD_MAIN"
  } > "$tmp" || {
    warn "写入 SSHD 认证配置失败"
    return 1
  }

  mv -f "$tmp" "$SSHD_MAIN"
}

has_port_directive_outside_main() {
  local file
  while IFS= read -r file; do
    [[ "$file" == "$SSHD_MAIN" ]] && continue
    if awk 'tolower($1) == "port" { found=1 } END { exit !found }' "$file"; then
      return 0
    fi
  done < <(sshd_config_files)
  return 1
}

update_sshd_port() {
  local port="$1" tmp
  tmp="$(mktemp "${SSHD_MAIN}.tmp.XXXXXX")" || {
    warn "无法创建 SSHD 配置临时文件"
    return 1
  }
  TEMP_FILES+=("$tmp")
  prepare_sshd_temp "$tmp" || return 1

  awk -v port="$port" '
    tolower($1) == "port" {
      if (!changed) {
        print "Port " port
        changed=1
      }
      next
    }
    { print }
    END {
      if (!changed) print "Port " port
    }
  ' "$SSHD_MAIN" > "$tmp" || {
    warn "写入 SSHD 端口配置失败"
    return 1
  }

  mv -f "$tmp" "$SSHD_MAIN"
}

validate_sshd_config() {
  local output
  if ! output="$("$SSHD_BIN" -t -f "$SSHD_MAIN" 2>&1)"; then
    warn "sshd_config 校验失败: ${output:-未返回错误详情}"
    return 1
  fi
  return 0
}

verify_effective_authentication() {
  local password_auth pubkey_auth kbdint_auth
  password_auth="$(sshd_effective_value passwordauthentication || true)"
  pubkey_auth="$(sshd_effective_value pubkeyauthentication || true)"
  kbdint_auth="$(sshd_effective_value kbdinteractiveauthentication || true)"

  [[ "$password_auth" == "$PASSWORD_AUTH" ]] || {
    warn "PasswordAuthentication 实际值为 ${password_auth:-未知}，不是期望值 $PASSWORD_AUTH"
    return 1
  }
  [[ "$pubkey_auth" == "$PUBKEY_AUTH" ]] || {
    warn "PubkeyAuthentication 实际值为 ${pubkey_auth:-未知}，不是期望值 $PUBKEY_AUTH"
    return 1
  }
  [[ "$kbdint_auth" == "$KBDINT_AUTH" ]] || {
    warn "KbdInteractiveAuthentication 实际值为 ${kbdint_auth:-未知}，不是期望值 $KBDINT_AUTH"
    return 1
  }
}

verify_effective_port() {
  [[ -n "$PENDING_SSH_PORT" ]] || return 0
  local ports
  ports="$(sshd_effective_values port | paste -sd ',' - 2>/dev/null || true)"
  [[ "$ports" == "$PENDING_SSH_PORT" ]] || {
    warn "SSH 端口实际值为 ${ports:-未知}，不是期望值 $PENDING_SSH_PORT"
    return 1
  }
}

reload_sshd() {
  systemctl reload sshd 2>/dev/null || \
    systemctl reload ssh 2>/dev/null || \
    service ssh reload 2>/dev/null || \
    service sshd reload 2>/dev/null
}

restore_sshd_backup() {
  [[ -n "${LAST_SSHD_BACKUP:-}" && -f "$LAST_SSHD_BACKUP" ]] || return 1
  replace_sshd_main_from "$LAST_SSHD_BACKUP" || return 1
  warn "已恢复 SSHD 配置备份: $LAST_SSHD_BACKUP"
}

firewall_port_is_open() {
  local port="$1" backend="$2"
  case "$backend" in
    ufw)       ufw status 2>/dev/null | grep -Fq "$port/tcp" ;;
    firewalld) firewall-cmd --permanent --query-port="$port/tcp" >/dev/null 2>&1 ;;
    iptables)  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null ;;
    none)      return 1 ;;
    *)         return 2 ;;
  esac
}

rollback_sshd_transaction() {
  local opened_firewall_port="${1:-}"
  restore_sshd_backup || warn "自动恢复 SSHD 配置失败"
  if [[ -n "$opened_firewall_port" ]]; then
    close_port_firewall "$opened_firewall_port" || warn "无法撤销新端口 $opened_firewall_port/tcp 的防火墙规则"
  fi
}

require_confirmation() {
  local prompt="$1" answer
  read -r -p "$prompt 输入 YES 继续: " answer || return 1
  [[ "$answer" == "YES" ]] || {
    warn "操作已取消"
    return 1
  }
}

validate_auth_transition() {
  if [[ "$PASSWORD_AUTH" != "yes" && "$PASSWORD_AUTH" != "no" ]] || \
     [[ "$PUBKEY_AUTH" != "yes" && "$PUBKEY_AUTH" != "no" ]] || \
     [[ "$KBDINT_AUTH" != "yes" && "$KBDINT_AUTH" != "no" ]]; then
    warn "认证待应用值只能为 yes 或 no"
    return 1
  fi
  if has_unmanaged_include; then
    warn "检测到无法完整检查的 Include 路径；为避免忽略条件策略，脚本拒绝自动修改认证项"
    return 1
  fi
  if has_active_match_rule; then
    warn "检测到 Match 规则；为避免覆盖条件认证策略，脚本拒绝自动修改认证项"
    return 1
  fi
  if [[ "$CURRENT_AUTHENTICATION_METHODS" != "any" ]]; then
    warn "AuthenticationMethods=${CURRENT_AUTHENTICATION_METHODS}；脚本只管理默认认证组合"
    return 1
  fi
  if [[ "$PASSWORD_AUTH" == "no" && "$PUBKEY_AUTH" == "no" && "$KBDINT_AUTH" == "no" ]]; then
    warn "不能同时禁用密码、密钥和键盘交互认证，否则可能没有可用的 SSH 登录方式"
    return 1
  fi

  if [[ "$PASSWORD_AUTH" == "no" && "$KBDINT_AUTH" == "no" ]]; then
    if ! authorized_keys_file_is_effective; then
      warn "拒绝关闭全部密码类认证：sshd 的 AuthorizedKeysFile 未包含 $AUTH_KEYS_FILE"
      return 1
    fi
    if ! has_usable_authorized_key; then
      warn "拒绝关闭全部密码类认证：$AUTH_KEYS_FILE 中没有可验证的公钥"
      return 1
    fi
    if [[ "$CURRENT_PASSWORD_AUTH" != "no" || "$CURRENT_KBDINT_AUTH" != "no" ]]; then
      require_confirmation "请先在另一 SSH 会话验证 $TARGET_USER 的密钥登录。"
    fi
  fi

  if [[ "$PUBKEY_AUTH" == "no" ]]; then
    if [[ "$TARGET_USER" == "root" && "$CURRENT_PERMIT_ROOT_LOGIN" != "yes" ]]; then
      warn "拒绝禁用公钥认证：root 的 PermitRootLogin=${CURRENT_PERMIT_ROOT_LOGIN}，非密钥登录不是可靠回退方式"
      return 1
    fi
    if [[ "$CURRENT_PUBKEY_AUTH" != "no" ]]; then
      require_confirmation "请先在另一 SSH 会话验证 $TARGET_USER 的非密钥登录。"
    fi
  fi
}

sync_state_from_sshd() {
  ensure_sshd_binary
  if ! validate_sshd_config; then
    CURRENT_SSH_PORT="unknown"
    CURRENT_PASSWORD_AUTH="unknown"
    CURRENT_PUBKEY_AUTH="unknown"
    CURRENT_KBDINT_AUTH="unknown"
    CURRENT_PERMIT_ROOT_LOGIN="unknown"
    CURRENT_AUTHENTICATION_METHODS="unknown"
    return 0
  fi

  CURRENT_SSH_PORT="$(sshd_effective_values port | paste -sd ',' - 2>/dev/null || true)"
  [[ -n "$CURRENT_SSH_PORT" ]] || CURRENT_SSH_PORT="unknown"
  CURRENT_PASSWORD_AUTH="$(normalize_yes_no "$(sshd_effective_value passwordauthentication || true)")"
  CURRENT_PUBKEY_AUTH="$(normalize_yes_no "$(sshd_effective_value pubkeyauthentication || true)")"
  CURRENT_KBDINT_AUTH="$(normalize_yes_no "$(sshd_effective_value kbdinteractiveauthentication || true)")"
  CURRENT_PERMIT_ROOT_LOGIN="$(sshd_effective_value permitrootlogin || true)"
  [[ -n "$CURRENT_PERMIT_ROOT_LOGIN" ]] || CURRENT_PERMIT_ROOT_LOGIN="unknown"
  CURRENT_AUTHENTICATION_METHODS="$(sshd_effective_value authenticationmethods || true)"
  [[ -n "$CURRENT_AUTHENTICATION_METHODS" ]] || CURRENT_AUTHENTICATION_METHODS="unknown"

  if [[ "$PASSWORD_TOUCHED" -eq 0 && "$CURRENT_PASSWORD_AUTH" != "unknown" ]]; then
    PASSWORD_AUTH="$CURRENT_PASSWORD_AUTH"
  fi
  if [[ "$PUBKEY_TOUCHED" -eq 0 && "$CURRENT_PUBKEY_AUTH" != "unknown" ]]; then
    PUBKEY_AUTH="$CURRENT_PUBKEY_AUTH"
  fi
  if [[ "$KBDINT_TOUCHED" -eq 0 && "$CURRENT_KBDINT_AUTH" != "unknown" ]]; then
    KBDINT_AUTH="$CURRENT_KBDINT_AUTH"
  fi
}

# ===================== 显示状态 =====================
show_status() {
  sync_state_from_sshd
  refresh_paths

  local fw_backend match_state
  fw_backend="$(detect_firewall_backend)"
  match_state="未检测到"
  has_active_match_rule && match_state="已检测到(拒绝自动修改)"

  print_header "SSH 密钥管理工具 - 状态面板"
  print_row "目标用户" "$TARGET_USER"
  print_row "用户主目录" "$TARGET_HOME"
  print_row "authorized_keys" "$AUTH_KEYS_FILE"
  print_row "认证策略范围" "全局"
  print_menu_sep
  print_row "当前 SSH 端口" "$CURRENT_SSH_PORT"
  print_row "待应用端口" "${PENDING_SSH_PORT:-(无)}"
  print_row "密码认证(有效)" "$(auth_state_label "$CURRENT_PASSWORD_AUTH")"
  print_row "密钥认证(有效)" "$(auth_state_label "$CURRENT_PUBKEY_AUTH")"
  print_row "键盘交互(有效)" "$(auth_state_label "$CURRENT_KBDINT_AUTH")"
  print_row "密码认证(待应用)" "$(auth_state_label "$PASSWORD_AUTH")"
  print_row "密钥认证(待应用)" "$(auth_state_label "$PUBKEY_AUTH")"
  print_row "键盘交互(待应用)" "$(auth_state_label "$KBDINT_AUTH")"
  [[ "$TARGET_USER" == "root" ]] && print_row "PermitRootLogin" "$CURRENT_PERMIT_ROOT_LOGIN"
  print_row "认证组合" "$(authentication_methods_label)"
  print_row "Match 规则" "$match_state"
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

toggle_password_auth() {
  local next="$PASSWORD_AUTH"
  [[ "$next" == "yes" ]] && next="no" || next="yes"
  if [[ "$next" == "no" && "$PUBKEY_AUTH" == "no" && "$KBDINT_AUTH" == "no" ]]; then
    warn "不能同时禁用密码、密钥和键盘交互认证"
    return 0
  fi
  PASSWORD_AUTH="$next"
  PASSWORD_TOUCHED=1
  log "密码认证(待应用) = $PASSWORD_AUTH"
}

toggle_pubkey_auth() {
  local next="$PUBKEY_AUTH"
  [[ "$next" == "yes" ]] && next="no" || next="yes"
  if [[ "$next" == "no" && "$PASSWORD_AUTH" == "no" && "$KBDINT_AUTH" == "no" ]]; then
    warn "不能同时禁用密码、密钥和键盘交互认证"
    return 0
  fi
  PUBKEY_AUTH="$next"
  PUBKEY_TOUCHED=1
  log "密钥认证(待应用) = $PUBKEY_AUTH"
}

toggle_kbdint_auth() {
  local next="$KBDINT_AUTH"
  [[ "$next" == "yes" ]] && next="no" || next="yes"
  if [[ "$next" == "no" && "$PASSWORD_AUTH" == "no" && "$PUBKEY_AUTH" == "no" ]]; then
    warn "不能同时禁用密码、密钥和键盘交互认证"
    return 0
  fi
  KBDINT_AUTH="$next"
  KBDINT_TOUCHED=1
  log "键盘交互认证(待应用) = $KBDINT_AUTH"
}

set_ssh_port() {
  read -r -p "输入新的 SSH 端口 [当前: $CURRENT_SSH_PORT]: " new_port || return 0
  [[ -z "$new_port" ]] && { log "保持当前端口"; return 0; }
  validate_port "$new_port" || { warn "端口无效"; return 0; }
  PENDING_SSH_PORT="$new_port"
  log "待应用端口: $PENDING_SSH_PORT"
}

apply_sshd_config() {
  require_root
  ensure_sshd_binary
  sync_state_from_sshd

  if ! validate_auth_transition; then
    return 0
  fi
  if [[ -n "$PENDING_SSH_PORT" ]] && has_port_directive_outside_main; then
    warn "检测到 Include 配置中的 Port 指令；脚本拒绝混合修改端口，避免留下多个监听端口"
    return 0
  fi
  if ! backup_file "$SSHD_MAIN"; then
    warn "无法备份 $SSHD_MAIN，已取消应用"
    return 0
  fi
  LAST_SSHD_BACKUP="$LAST_BACKUP"
  if ! write_managed_auth_block; then
    warn "认证配置未写入"
    return 0
  fi

  local opened_firewall_port=""
  if [[ -n "$PENDING_SSH_PORT" ]]; then
    local fw_backend firewall_state
    fw_backend="$(detect_firewall_backend)"
    if [[ "$fw_backend" == "none" ]]; then
      warn "未检测到活动防火墙，请确认 $PENDING_SSH_PORT/tcp 可从外部访问"
    elif firewall_port_is_open "$PENDING_SSH_PORT" "$fw_backend"; then
      :
    else
      firewall_state=$?
      if [[ "$firewall_state" -ne 1 ]]; then
        warn "无法安全判断 $fw_backend 的端口规则，已恢复 SSHD 配置"
        rollback_sshd_transaction
        return 0
      fi
      if ! open_port_firewall "$PENDING_SSH_PORT"; then
        warn "新端口防火墙放行失败，已恢复 SSHD 配置"
        rollback_sshd_transaction
        return 0
      fi
      opened_firewall_port="$PENDING_SSH_PORT"
    fi

    if ! update_sshd_port "$PENDING_SSH_PORT"; then
      warn "SSH 端口配置未写入，已恢复 SSHD 配置"
      rollback_sshd_transaction "$opened_firewall_port"
      return 0
    fi
  fi

  if ! validate_sshd_config; then
    warn "新 SSHD 配置未通过校验，已恢复备份"
    rollback_sshd_transaction "$opened_firewall_port"
    return 0
  fi
  if ! verify_effective_authentication; then
    warn "认证配置未按预期生效，已恢复备份"
    rollback_sshd_transaction "$opened_firewall_port"
    return 0
  fi
  if ! verify_effective_port; then
    warn "端口配置未按预期生效，已恢复备份"
    rollback_sshd_transaction "$opened_firewall_port"
    return 0
  fi
  if ! reload_sshd; then
    warn "SSHD 重载失败，正在恢复备份"
    rollback_sshd_transaction "$opened_firewall_port"
    if validate_sshd_config; then
      reload_sshd || warn "恢复后的 SSHD 配置也未能重载，请立即在当前控制台检查服务"
    fi
    return 0
  fi

  [[ -n "$PENDING_SSH_PORT" ]] && log "SSH 端口已切换为: $PENDING_SSH_PORT"
  PENDING_SSH_PORT=""
  PASSWORD_TOUCHED=0
  PUBKEY_TOUCHED=0
  KBDINT_TOUCHED=0
  sync_state_from_sshd
  log "SSHD 配置已应用：密码认证=$PASSWORD_AUTH，密钥认证=$PUBKEY_AUTH，键盘交互认证=$KBDINT_AUTH"
}

# ===================== 备份回滚 =====================
LAST_BACKUP=""
LAST_SSHD_BACKUP=""
backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
  copy_file_preserving_metadata "$file" "$backup" || return 1
  LAST_BACKUP="$backup"
  log "已备份: $backup"
}

backup_sshd_config() {
  if backup_file "$SSHD_MAIN"; then
    LAST_SSHD_BACKUP="$LAST_BACKUP"
  fi
}

restore_last_backup() {
  ensure_sshd_binary
  if [[ -z "$LAST_SSHD_BACKUP" || ! -f "$LAST_SSHD_BACKUP" ]]; then
    warn "没有可回滚的 SSHD 配置备份"
    return 0
  fi
  if ! replace_sshd_main_from "$LAST_SSHD_BACKUP"; then
    warn "无法恢复 SSHD 配置备份"
    return 0
  fi
  if ! validate_sshd_config; then
    warn "恢复后的 SSHD 配置未通过校验，请在当前控制台检查"
    return 0
  fi
  reload_sshd || warn "SSHD 重载失败，请在当前控制台检查服务"
  log "已回滚 SSHD 配置: $LAST_SSHD_BACKUP"
  sync_state_from_sshd
}

# ===================== UFW Docker after.rules =====================
modify_ufw_after_rules_for_docker_port() {
  require_root
  local p="$1"
  validate_port "$p" || die "非法端口：$p"

  local file="/etc/ufw/after.rules"
  [[ -f "$file" ]] || die "$file 不存在"

  backup_file "$file"

  local rule="-A ufw-user-forward -p tcp --dport $p -j ACCEPT"
  local mark="# ssh_key.sh docker allow $p/tcp"

  # 幂等：已存在即跳过
  if grep -qF "$rule" "$file" 2>/dev/null; then
    log "after.rules 已存在 Docker 放行规则: $p/tcp"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  TEMP_FILES+=("$tmp")

  # 优先插入到 '# BEGIN UFW AND DOCKER' 对应 filter 块的 COMMIT 前
  awk -v rule="$rule" -v mark="$mark" '
    BEGIN {in_block=0; in_filter=0; inserted=0}
    /^# BEGIN UFW AND DOCKER/ {in_block=1; print; next}
    in_block && /^\*filter/ {in_filter=1; print; next}
    in_block && in_filter && /^COMMIT/ && inserted==0 {
      print mark
      print rule
      inserted=1
      print
      next
    }
    {print}
    /^# END UFW AND DOCKER/ {in_block=0; in_filter=0}
  ' "$file" > "$tmp"

  # 若未插入（无该区块），退化为在最后一个 COMMIT 前插入
  if ! grep -qF "$rule" "$tmp"; then
    awk -v rule="$rule" -v mark="$mark" '
      {lines[NR]=$0}
      END {
        last_commit=0
        for (i=1;i<=NR;i++) if (lines[i] ~ /^COMMIT$/) last_commit=i
        if (last_commit==0) {
          for (i=1;i<=NR;i++) print lines[i]
          print "*filter"
          print ":ufw-user-forward - [0:0]"
          print mark
          print rule
          print "COMMIT"
        } else {
          for (i=1;i<=NR;i++) {
            if (i==last_commit) {
              print mark
              print rule
            }
            print lines[i]
          }
        }
      }
    ' "$tmp" > "${tmp}.2"
    mv "${tmp}.2" "$tmp"
  fi

  cat "$tmp" > "$file"
  chmod 640 "$file"

  local reload_err
  reload_err="$(ufw reload 2>&1)" \
    && log "已写入 after.rules 并重载 UFW: 放行 Docker 端口 $p/tcp" \
    || warn "规则已写入，但 ufw reload 失败（${reload_err:-无详细信息}），请手动执行: ufw reload"
}

configure_ufw_docker_rules_menu() {
  while true; do
    echo ""
    print_line
    printf "|%s|\n" "$(pad_to " UFW Docker 规则配置" "$BOX_INNER")"
    print_line
    print_menu_item "[1] 放行 Docker TCP 端口 (写入 /etc/ufw/after.rules)"
    print_menu_item "[2] 返回上级菜单"
    print_line

    read -r -p "请选择: " sub || return 0
    case "$sub" in
      1)
        read -r -p "输入要放行的 Docker 端口(TCP): " port || true
        [[ -n "${port:-}" ]] && modify_ufw_after_rules_for_docker_port "$port"
        ;;
      2) return 0 ;;
      *) warn "无效选项" ;;
    esac
    echo ""
    read -r -p "回车继续..." _ || return 0
  done
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
    print_menu_item "[7] 切换密码认证        [8] 切换密钥认证"
    print_menu_item "[9] 切换键盘交互认证"
    print_menu_item "[10] 设置 SSH 端口     [11] 应用 SSHD 配置"
    print_menu_sep
    print_menu_item "[12] 查看防火墙         [13] 添加端口"
    print_menu_item "[14] 删除端口           [15] 持久化规则"
    print_menu_sep
    print_menu_item "[16] 配置 fail2ban      [17] 查看 fail2ban"
    print_menu_item "[18] 备份 sshd_config   [19] 回滚 sshd_config"
    print_menu_item "[20] 安装/启用 UFW (放行SSH)"
    print_menu_item "[21] UFW Docker 规则配置"
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
      7) toggle_password_auth ;;
      8) toggle_pubkey_auth ;;
      9) toggle_kbdint_auth ;;
      10) set_ssh_port ;;
      11) apply_sshd_config ;;
      12) show_firewall_rules ;;
      13) read -r -p "端口: " port || true; [[ -n "$port" ]] && open_port_firewall "$port" ;;
      14) read -r -p "端口: " port || true; [[ -n "$port" ]] && close_port_firewall "$port" ;;
      15) persist_iptables_rules ;;
      16) configure_fail2ban ;;
      17) show_fail2ban_status ;;
      18) backup_sshd_config ;;
      19) restore_last_backup ;;
      20) install_enable_ufw ;;
      21) configure_ufw_docker_rules_menu ;;
      0) log "Bye."; exit 0 ;;
      *) warn "无效选项" ;;
    esac
    
    echo ""
    read -r -p "回车继续..." _ || exit 0
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  require_root
  main_loop
fi
