#!/usr/bin/env bash
# =============================================================================
# 脚本名称: ssh_key.sh
# 描    述: SSH 密钥管理工具 - 托管密钥同步、SSHD 配置、防火墙、fail2ban
# 版    本: v1.1 (security hardened)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
umask 077

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

# =========================================================
# 固定公钥定义区（你只需要维护这里）
# 一行一个 key，不要换行
SSH_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB525kOyxHEeE8DV5BXfIC9kRR3NUSEQ2yBpsw/IPo8I newnew@mydevice"
  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIIJFcDer20hJSHUh9nUDZFkzAEQ4ZDPhna+TC6fLX7NEAAAABHNzaDo= vps"
)

# =========================================================
# 托管区块标记（脚本只管理这个区块，别的 key 不动）
MANAGED_BEGIN='# ==== BEGIN MANAGED BY ssh_key.sh ===='
MANAGED_END='# ==== END MANAGED BY ssh_key.sh ===='

# fail2ban jail 文件
F2B_JAIL=/etc/fail2ban/jail.d/sshd.local

# 备份保留数（目录内保留最近 N 个）
BACKUP_KEEP_COUNT=5

# =========================================================
# 运行态变量（菜单里切换）
# 安全验证 SUDO_USER
validate_username() {
  local u="$1"
  # 用户名只允许字母、数字、下划线、连字符，且必须以字母或下划线开头
  [[ "$u" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || return 1
  # 验证用户确实存在
  getent passwd "$u" >/dev/null 2>&1 || return 1
  return 0
}

_init_user="${SUDO_USER:-$(id -un)}"
if validate_username "$_init_user"; then
  TARGET_USER="$_init_user"
else
  TARGET_USER="$(id -un)"
fi
unset _init_user

DISABLE_PASSWORD=0
SSH_PORT=""
OLD_SSH_PORT=""
OLD_SSH_PORTS=()  # 存储所有监听端口（多端口场景）

SSHD_MAIN=/etc/ssh/sshd_config
SSHD_DCONF=/etc/ssh/sshd_config.d/99-keys.conf

LAST_BACKUP=""
LAST_BACKUP_TARGET=""

# ===================== 基础工具 ==========================
log()  { printf '%s\n' "[OK] $*"; }
warn() { printf '%s\n' "[WARN] $*" >&2; }
die()  { printf '%s\n' "[ERROR] $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die "需要 root 运行"; }

validate_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  (( 1 <= 10#$1 && 10#$1 <= 65535 )) || return 1
  return 0
}

# 检查端口是否已在监听列表中
port_in_listening() {
  local p="$1"
  local port
  for port in "${OLD_SSH_PORTS[@]:-}"; do
    [[ "$port" == "$p" ]] && return 0
  done
  return 1
}

get_home_of_user() {
  local u="$1"
  getent passwd "$u" | awk -F: '{print $6}'
}

# 验证 SSH 公钥格式安全性（防止注入攻击）
validate_ssh_key() {
  local key="$1"
  # 检查是否包含换行符（防止多行注入）
  if [[ "$key" == *$'\n'* ]] || [[ "$key" == *$'\r'* ]]; then
    return 1
  fi
  # 检查是否以有效的 SSH 密钥类型开头（不允许前置选项如 command=）
  if [[ ! "$key" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp[0-9]+))[[:space:]] ]]; then
    return 1
  fi
  # 检查是否只包含允许的字符（字母、数字、base64字符、空格、注释用字符）
  if [[ ! "$key" =~ ^[a-zA-Z0-9+/=@._[:space:]-]+$ ]]; then
    return 1
  fi
  return 0
}

# 安全写入公钥（带验证）- 输出到 stdout
write_validated_keys() {
  echo "$MANAGED_BEGIN"
  for k in "${SSH_KEYS[@]:-}"; do
    if [[ -n "${k:-}" ]]; then
      if validate_ssh_key "$k"; then
        echo "$k"
      else
        warn "跳过无效或可疑的公钥: ${k:0:50}..."
      fi
    fi
  done
  echo "$MANAGED_END"
}

refresh_paths() {
  TARGET_HOME="$(get_home_of_user "$TARGET_USER" || true)"
  [[ -n "${TARGET_HOME:-}" ]] || die "无法获取用户 $TARGET_USER 的 home"
  SSH_DIR="$TARGET_HOME/.ssh"
  KEY_FILE="$SSH_DIR/authorized_keys"
}

backup_file() {
  require_root
  local f="$1"
  [[ -f "$f" ]] || { warn "跳过备份：不存在 $f"; return 0; }

  local dir base ts bak
  dir="$(dirname "$f")"
  base="$(basename "$f")"
  ts="$(date +%F_%H%M%S)"
  bak="$dir/${base}.bak.${ts}"

  cp -a "$f" "$bak"
  LAST_BACKUP="$bak"
  LAST_BACKUP_TARGET="$f"
  log "已备份：$bak"

  # 清理旧备份（同目录同前缀）- 兼容 macOS/BSD，防止符号链接攻击
  local old_backups
  old_backups=$(ls -1t "$dir/${base}.bak."* 2>/dev/null | tail -n +"$((BACKUP_KEEP_COUNT+1))" || true)
  if [[ -n "$old_backups" ]]; then
    while IFS= read -r old_file; do
      # 安全检查：确保是普通文件且不是符号链接
      if [[ -f "$old_file" && ! -L "$old_file" ]]; then
        # 验证文件仍在预期目录内（防止路径遍历）
        local real_dir
        real_dir="$(cd "$(dirname "$old_file")" 2>/dev/null && pwd)"
        if [[ "$real_dir" == "$dir" ]]; then
          rm -f "$old_file"
        fi
      fi
    done <<< "$old_backups"
  fi
}

restore_last_backup() {
  require_root
  [[ -n "$LAST_BACKUP" && -n "$LAST_BACKUP_TARGET" ]] || die "没有记录到备份（仅本次运行内创建的备份可回滚）"
  [[ -f "$LAST_BACKUP" ]] || die "备份不存在：$LAST_BACKUP"
  cp -a "$LAST_BACKUP" "$LAST_BACKUP_TARGET"
  log "✅ 已回滚：$LAST_BACKUP_TARGET  ←  $LAST_BACKUP"

  if [[ "$LAST_BACKUP_TARGET" == "$SSHD_MAIN" || "$LAST_BACKUP_TARGET" == "$SSHD_DCONF" ]]; then
    log "ℹ️ 检测到回滚的是 sshd 配置，正在重载 sshd..."
    if sshd -t 2>/dev/null; then
      reload_sshd
    else
      warn "回滚后 sshd -t 未通过，请手动检查"
    fi
  fi
}

# ===================== SSH 目录/密钥 ======================
setup_ssh_directory() {
  require_root
  refresh_paths

  # 安全检查：确保 .ssh 不是符号链接（防止符号链接攻击）
  if [[ -L "$SSH_DIR" ]]; then
    die "安全错误：$SSH_DIR 是符号链接，拒绝操作"
  fi
  if [[ -e "$SSH_DIR" && ! -d "$SSH_DIR" ]]; then
    die "安全错误：$SSH_DIR 存在但不是目录"
  fi

  # 安全检查：确保 authorized_keys 不是符号链接
  if [[ -L "$KEY_FILE" ]]; then
    die "安全错误：$KEY_FILE 是符号链接，拒绝操作"
  fi

  # 创建 .ssh 目录（如果不存在）
  if [[ ! -d "$SSH_DIR" ]]; then
    install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$SSH_DIR"
  else
    # 确保权限正确
    chmod 700 "$SSH_DIR"
    chown "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
  fi

  # 仅在文件不存在时创建（不清空现有文件！）
  if [[ ! -f "$KEY_FILE" ]]; then
    install -m 600 -o "$TARGET_USER" -g "$TARGET_USER" /dev/null "$KEY_FILE"
  else
    # 确保权限正确
    chmod 600 "$KEY_FILE"
    chown "$TARGET_USER:$TARGET_USER" "$KEY_FILE"
  fi
}

show_authorized_keys() {
  refresh_paths
  echo
  echo "====== $KEY_FILE ======"
  [[ -f "$KEY_FILE" ]] && nl -ba "$KEY_FILE" || echo "(不存在)"
  echo "======================="
  echo
}

sync_fixed_keys_add_only() {
  require_root
  refresh_paths
  setup_ssh_directory

  backup_file "$KEY_FILE"

  local tmp
  tmp="$(mktemp "$SSH_DIR/tmp.XXXXXX")"
  register_temp_file "$tmp"
  chmod 0600 "$tmp"
  chown "$TARGET_USER:$TARGET_USER" "$tmp"

  # 移除旧托管区块，保留其它 key
  awk -v b="$MANAGED_BEGIN" -v e="$MANAGED_END" '
    $0==b {in_block=1; next}
    $0==e {in_block=0; next}
    !in_block {print}
  ' "$KEY_FILE" > "$tmp"

  # 追加托管区块（只加不减）- 使用安全验证
  write_validated_keys >> "$tmp"

  mv "$tmp" "$KEY_FILE"
  chown "$TARGET_USER:$TARGET_USER" "$KEY_FILE"
  chmod 0600 "$KEY_FILE"
  log "✅ 已同步托管公钥（只加不减）：$KEY_FILE"
}

sync_fixed_keys_overwrite() {
  require_root
  refresh_paths
  setup_ssh_directory

  # 安全校验：确保 SSH_KEYS 数组非空且包含有效公钥（使用增强验证）
  local valid_key_count=0
  for k in "${SSH_KEYS[@]:-}"; do
    if [[ -n "${k:-}" ]] && validate_ssh_key "$k"; then
      ((valid_key_count++)) || true
    fi
  done

  if [[ "$valid_key_count" -eq 0 ]]; then
    die "SSH_KEYS 数组为空或不包含有效公钥，覆盖操作将导致 authorized_keys 被清空！请检查脚本配置。"
  fi

  # 二次确认
  warn ">>> 危险操作：即将覆盖 $KEY_FILE，原有的非托管公钥将被删除！"
  warn ">>> 将写入 $valid_key_count 个托管公钥"
  read -r -p "确认覆盖？[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log "已取消覆盖操作"
    return 1
  fi

  backup_file "$KEY_FILE"

  # 使用安全验证写入公钥
  write_validated_keys > "$KEY_FILE"

  chown "$TARGET_USER:$TARGET_USER" "$KEY_FILE"
  chmod 0600 "$KEY_FILE"
  warn "已覆盖 authorized_keys（危险模式）：$KEY_FILE"
}

# ===================== systemd/sshd =======================
detect_sshd_service_name() {
  # 不同发行版可能用 ssh.service / sshd.service / openssh-server.service
  # 有的系统 sshd.service 是 alias（别名），更稳的是优先使用 ssh.service
  if ! command -v systemctl >/dev/null 2>&1; then
    echo ""
    return
  fi

  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1,$2}' | grep -q '^ssh\.service[[:space:]]'; then
    echo "ssh"
    return
  fi

  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1,$2}' | grep -q '^sshd\.service[[:space:]]'; then
    echo "sshd"
    return
  fi

  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1,$2}' | grep -q '^openssh-server\.service[[:space:]]'; then
    echo "openssh-server"
    return
  fi

  echo ""
}

reload_sshd() {
  need_cmd sshd
  sshd -t || die "sshd 配置语法校验失败（sshd -t 未通过）"

  local action="reload"
  # 端口变更时用 restart（reload 在部分系统下不会可靠地重新绑定端口）
  if [[ -n "${SSH_PORT:-}" ]]; then
    action="restart"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    local svc
    svc="$(detect_sshd_service_name)"
    if [[ -n "$svc" ]]; then
      if [[ "$action" == "reload" ]]; then
        systemctl reload "$svc" || systemctl restart "$svc"
      else
        systemctl restart "$svc"
      fi
      return 0
    fi
  fi

  # 非 systemd 系统：使用 service 命令或直接操作主进程
  if command -v service >/dev/null 2>&1; then
    if service ssh "$action" 2>/dev/null || service sshd "$action" 2>/dev/null; then
      return 0
    fi
  fi

  # 最后兜底：只向主 sshd 进程发送 HUP（不影响会话子进程）
  local main_pid
  main_pid=$(pgrep -o sshd 2>/dev/null || true)
  if [[ -n "$main_pid" ]]; then
    warn "未找到 systemd/service，尝试向主 sshd 进程 (PID=$main_pid) 发送 HUP 信号"
    kill -HUP "$main_pid" 2>/dev/null || true
    return 0
  fi

  die "找不到运行中的 sshd，无法重载"
}

choose_sshd_target() {
  # 优先 dconf（现代 Ubuntu/Debian 常用）
  if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN" 2>/dev/null; then
    echo "$SSHD_DCONF"
  else
    echo "$SSHD_MAIN"
  fi
}

preflight_lockout_check() {
  require_root
  need_cmd sshd

  # 如果准备禁用密码，必须确保至少已经有有效公钥写入，否则提示风险
  refresh_paths
  if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
    if [[ ! -s "$KEY_FILE" ]]; then
      die "检测到 authorized_keys 为空，但你要禁用密码登录：锁死风险极高。请先同步公钥。"
    fi
    # 验证是否存在至少一行有效的 ssh 公钥（ssh-rsa/ssh-ed25519/ecdsa-sha2 等）
    local valid_key_count
    valid_key_count=$(grep -cE '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp[0-9]+))' "$KEY_FILE" 2>/dev/null || echo 0)
    if [[ "$valid_key_count" -eq 0 ]]; then
      die "authorized_keys 中未找到有效的 SSH 公钥，禁用密码登录将导致锁死。请先同步公钥。"
    fi
    log "检测到 $valid_key_count 个有效公钥"
  fi

  log "防锁死自检通过"
}

neutralize_overrides_in_sshd_main() {
  # 如果主配置在 Include 之后仍写了 Port/PasswordAuthentication 等，会覆盖 dconf 的设置
  # 这里自动把这些"Include 之后的冲突项"注释掉，避免配置反弹
  # 注意：Match 区块内的配置不应被注释，因为它们是条件配置
  require_root
  [[ -f "$SSHD_MAIN" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  register_temp_file "$tmp"

  awk '
    BEGIN { after_inc=0; in_match=0 }
    {
      line=$0
      # 检测 Include 行
      if ($0 ~ /^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/sshd_config\.d\/\*\.conf([[:space:]]+.*)?$/) {
        after_inc=1
        print
        next
      }
      # 检测 Match 区块开始
      if ($0 ~ /^[[:space:]]*Match[[:space:]]+/) {
        in_match=1
        print
        next
      }
      # 检测 Match 区块结束（遇到另一个 Match 或非缩进的全局配置）
      # sshd_config 中 Match 区块一直持续到文件末尾或下一个 Match
      # 这里简化处理：如果遇到新的顶级配置项（非空格开头），退出 Match
      if (in_match==1 && $0 ~ /^[^[:space:]#]/ && $0 !~ /^[[:space:]]*Match[[:space:]]+/) {
        in_match=0
      }
      # 只在 Include 之后且不在 Match 区块内时注释冲突项
      if (after_inc==1 && in_match==0 && $0 !~ /^[[:space:]]*#/ &&
          $0 ~ /^[[:space:]]*(Port|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|PermitRootLogin|AuthorizedKeysFile|AuthenticationMethods)[[:space:]]+/) {
        print "#DISABLED_BY_ssh_key.sh# " line
        next
      }
      print
    }
  ' "$SSHD_MAIN" > "$tmp"

  if ! cmp -s "$SSHD_MAIN" "$tmp"; then
    backup_file "$SSHD_MAIN"
    cat "$tmp" > "$SSHD_MAIN"
    chmod 0600 "$SSHD_MAIN" || true
    warn "检测到主配置在 Include 之后存在覆盖项，已自动注释（避免反弹）"
  fi
  rm -f "$tmp"
}

apply_sshd_config() {
  preflight_lockout_check

  local target
  target="$(choose_sshd_target)"

  # 保存原始端口列表（在任何变更前）
  local original_ports=("${OLD_SSH_PORTS[@]:-}")
  local original_primary_port="${OLD_SSH_PORT:-}"

  # 避免主配置在 Include 之后覆盖 dconf 里的设置
  neutralize_overrides_in_sshd_main

  # ========== 双端口过渡策略 ==========
  # 如果要改端口，先配置双端口（旧+新），确认新端口可用后再移除旧端口
  local use_dual_port=0
  local dual_port_config=""

  if [[ -n "$SSH_PORT" ]]; then
    # 检查新端口是否已在监听列表中
    if port_in_listening "$SSH_PORT"; then
      log "端口 $SSH_PORT 已在监听中，无需变更"
      dual_port_config=""
      # 保持当前所有端口配置
      for p in "${OLD_SSH_PORTS[@]:-}"; do
        [[ -n "$dual_port_config" ]] && dual_port_config+=$'\n'
        dual_port_config+="Port $p"
      done
    elif [[ -n "${OLD_SSH_PORT:-}" && "$SSH_PORT" != "$OLD_SSH_PORT" ]]; then
      use_dual_port=1
      warn ">>> 端口变更检测：$OLD_SSH_PORT -> $SSH_PORT"
      warn ">>> 采用双端口过渡策略（新旧端口同时监听）防止锁死"
      # 保留所有现有端口，并添加新端口
      for p in "${OLD_SSH_PORTS[@]:-}"; do
        [[ -n "$dual_port_config" ]] && dual_port_config+=$'\n'
        dual_port_config+="Port $p"
      done
      dual_port_config+=$'\n'"Port ${SSH_PORT}"
    else
      dual_port_config="Port ${SSH_PORT}"
    fi
  fi

  # ========== 写入配置 ==========
  if [[ "$target" == "$SSHD_DCONF" ]]; then
    mkdir -p "$(dirname "$target")"
    log "使用 dconf 模式写入：$target"

    # 安全检查：确保目标不是符号链接
    if [[ -L "$target" ]]; then
      die "安全错误：$target 是符号链接，拒绝操作"
    fi

    backup_file "$target" || true

    # 使用原子替换：先写临时文件，再 mv
    local tmp_dconf
    tmp_dconf="$(mktemp "$(dirname "$target")/tmp.XXXXXX")"
    register_temp_file "$tmp_dconf"

    {
      echo "# Managed by ssh_key.sh"
      [[ -n "$dual_port_config" ]] && echo "$dual_port_config"
      echo "PubkeyAuthentication yes"
      if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "ChallengeResponseAuthentication no"
      fi
    } > "$tmp_dconf"

    chmod 0600 "$tmp_dconf"
    mv "$tmp_dconf" "$target"
  else
    # main 模式：在主文件尾部追加托管区块（尽量不破坏原配置）
    log "使用主配置模式写入：$target"
    backup_file "$target"

    local tmp
    tmp="$(mktemp)"
    register_temp_file "$tmp"

    # 注释掉可能冲突的配置项（保留原内容可追溯）
    sed -E \
      -e 's/^[[:space:]]*(Port[[:space:]]+)/#DISABLED_BY_ssh_key.sh# \1/' \
      -e 's/^[[:space:]]*(PubkeyAuthentication[[:space:]]+)/#DISABLED_BY_ssh_key.sh# \1/' \
      -e 's/^[[:space:]]*(PasswordAuthentication[[:space:]]+)/#DISABLED_BY_ssh_key.sh# \1/' \
      -e 's/^[[:space:]]*(KbdInteractiveAuthentication[[:space:]]+)/#DISABLED_BY_ssh_key.sh# \1/' \
      -e 's/^[[:space:]]*(ChallengeResponseAuthentication[[:space:]]+)/#DISABLED_BY_ssh_key.sh# \1/' \
      "$target" > "$tmp"

    {
      echo ""
      echo "# ========== BEGIN MANAGED BY ssh_key.sh =========="
      [[ -n "$dual_port_config" ]] && echo "$dual_port_config"
      echo "PubkeyAuthentication yes"
      if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "ChallengeResponseAuthentication no"
      fi
      echo "# ========== END MANAGED BY ssh_key.sh =========="
    } >> "$tmp"

    mv "$tmp" "$target"
    chmod 0600 "$target"
  fi

  # ========== 端口变更时先放行防火墙/SELinux ==========
  local firewall_ok=1
  if [[ -n "$SSH_PORT" ]]; then
    if ! open_port_firewall "$SSH_PORT"; then
      firewall_ok=0
      warn "=========================================="
      warn "  防火墙放行新端口 $SSH_PORT 失败！"
      warn "=========================================="
      warn "可能原因：无防火墙后端 / 权限不足 / 云安全组未配置"
      read -r -p "是否仍要继续？（风险：可能锁死）[y/N]: " force_continue
      if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
        die "已中止操作，请先配置防火墙/安全组后重试"
      fi
    fi
    ensure_selinux_ssh_port "$SSH_PORT"
  fi

  reload_sshd
  sync_state_from_sshd

  # ========== 双端口过渡：第二阶段 ==========
  if [[ "$use_dual_port" -eq 1 ]]; then
    echo
    warn "=========================================="
    warn "  双端口过渡阶段 - 新旧端口同时监听中"
    warn "=========================================="
    # 显示所有当前监听端口
    if [[ ${#OLD_SSH_PORTS[@]} -gt 1 ]]; then
      warn "当前监听: ${OLD_SSH_PORTS[*]} (含新端口 $SSH_PORT)"
    else
      warn "当前监听: $OLD_SSH_PORT (旧) + $SSH_PORT (新)"
    fi
    if [[ "$firewall_ok" -eq 0 ]]; then
      warn ">>> 注意：新端口防火墙放行可能失败！"
    fi
    echo
    warn ">>> 请在另一终端测试新端口连接："
    warn "    ssh -p $SSH_PORT user@host"
    echo
    read -r -p "新端口 $SSH_PORT 连接测试成功？[y/N]: " confirm_new_port

    if [[ "$confirm_new_port" =~ ^[Yy]$ ]]; then
      log "确认新端口可用，移除旧端口配置..."

      # 第二阶段：只保留新端口
      if [[ "$target" == "$SSHD_DCONF" ]]; then
        cat > "$target" <<EOF
# Managed by ssh_key.sh
Port ${SSH_PORT}
PubkeyAuthentication yes
EOF
        if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
          cat >> "$target" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
        fi
        chmod 0600 "$target"
      else
        # main 模式：注释掉所有旧端口（支持多端口）
        for old_p in "${OLD_SSH_PORTS[@]:-}"; do
          [[ "$old_p" == "$SSH_PORT" ]] && continue  # 跳过新端口
          sed -i.bak -E "s/^Port ${old_p}$/#REMOVED_BY_ssh_key.sh# Port ${old_p}/" "$target" 2>/dev/null || true
        done
      fi

      reload_sshd
      sync_state_from_sshd

      # 询问是否关闭旧端口防火墙（使用保存的原始端口列表）
      local ports_to_close=()
      for old_p in "${original_ports[@]:-}"; do
        [[ "$old_p" == "$SSH_PORT" ]] && continue  # 跳过新端口
        ports_to_close+=("$old_p")
      done

      if [[ ${#ports_to_close[@]} -gt 0 ]]; then
        echo
        if [[ ${#ports_to_close[@]} -gt 1 ]]; then
          read -r -p "是否关闭旧端口 ${ports_to_close[*]} 的防火墙规则？[Y/n]: " close_old
        else
          read -r -p "是否关闭旧端口 ${ports_to_close[0]} 的防火墙规则？[Y/n]: " close_old
        fi
        if [[ ! "$close_old" =~ ^[Nn]$ ]]; then
          for old_p in "${ports_to_close[@]}"; do
            close_port_firewall "$old_p" || true
            log "已关闭旧端口 $old_p 防火墙"
          done
        else
          warn "旧端口 ${ports_to_close[*]} 防火墙仍开放，建议稍后手动关闭"
        fi
      fi

      log "端口变更完成：${original_primary_port:-未知} -> $SSH_PORT"
    else
      warn ">>> 新端口测试未确认，保持双端口配置"
      warn ">>> 请手动排查问题后重新执行端口变更"
      warn ">>> 当前状态：新旧端口同时监听，不会锁死"
    fi
  fi

  log "SSHD 配置已应用"
}

# ===================== SELinux（可选） ====================
ensure_selinux_ssh_port() {
  require_root
  local p="$1"
  validate_port "$p" || return 0
  if command -v getenforce >/dev/null 2>&1; then
    local st
    st="$(getenforce 2>/dev/null || true)"
    if [[ "$st" == "Enforcing" || "$st" == "Permissive" ]]; then
      if command -v semanage >/dev/null 2>&1; then
        semanage port -a -t ssh_port_t -p tcp "$p" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$p" 2>/dev/null || true
        log "SELinux: 已确保 tcp/$p 属于 ssh_port_t"
      else
        warn "SELinux 开启但缺少 semanage（policycoreutils-python-utils），可能导致新端口无法绑定"
      fi
    fi
  fi
}

# ===================== 防火墙（多后端） ====================
detect_firewall_backend() {
  # 返回：iptables / firewalld / ufw / none
  # 注意：此函数需要容忍各种错误（权限、模块未加载等），确保最坏返回 none
  if command -v iptables >/dev/null 2>&1; then
    local pol
    pol="$(iptables -L INPUT -n 2>/dev/null | awk 'NR==1{gsub(/[()]/,""); for(i=1;i<=NF;i++) if($i=="policy"){print $(i+1); exit}}' 2>/dev/null || true)"
    if [[ "$pol" == "DROP" || "$pol" == "REJECT" ]]; then
      echo "iptables"; return 0
    fi
    # 使用子 shell 屏蔽 pipefail 影响
    if (iptables -L INPUT -n --line-numbers 2>/dev/null | tail -n +3 | grep -q . 2>/dev/null) 2>/dev/null; then
      echo "iptables"; return 0
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "firewalld"; return 0
  fi
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q '^Status: active' 2>/dev/null; then
      echo "ufw"; return 0
    fi
  fi
  echo "none"
}

ensure_ufw_enabled_if_no_active_firewall() {
  # 仅提示用户，不自动启用任何防火墙（避免冲突）
  local backend
  backend="$(detect_firewall_backend)"
  [[ "$backend" == "none" ]] || return 0

  warn "=========================================="
  warn "  未检测到生效的防火墙后端"
  warn "=========================================="
  warn "当前系统未启用 iptables/firewalld/ufw"
  warn "端口放行操作将无效，请手动配置："
  warn "  - 云服务器：检查安全组规则"
  warn "  - 物理服务器：手动启用防火墙"
  warn "=========================================="
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

open_port_firewalld() {
  local p="$1"
  if firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
    log "firewalld 已放行 $p/tcp"
    return 0
  else
    warn "firewalld 放行 $p/tcp 失败"
    return 1
  fi
}
close_port_firewalld() {
  local p="$1"
  if firewall-cmd --permanent --remove-port="$p/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
    log "firewalld 已关闭 $p/tcp"
    return 0
  else
    warn "firewalld 关闭 $p/tcp 失败"
    return 1
  fi
}

# iptables 持久化辅助函数
persist_iptables_rules() {
  # 尝试多种持久化方式
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
    log "iptables 规则已通过 netfilter-persistent 持久化"
    return 0
  fi
  if command -v iptables-save >/dev/null 2>&1; then
    if [[ -d /etc/iptables ]]; then
      iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
      log "iptables 规则已保存到 /etc/iptables/rules.v4"
      return 0
    elif [[ -f /etc/sysconfig/iptables ]]; then
      iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
      log "iptables 规则已保存到 /etc/sysconfig/iptables"
      return 0
    fi
  fi
  warn "⚠️ 无法自动持久化 iptables 规则，重启后可能丢失。请手动运行 iptables-save"
}

open_port_iptables() {
  local p="$1"
  # 允许 tcp/$p（如果已存在则不重复插入）
  if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1; then
    if ! iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
      warn "iptables 放行 $p/tcp 失败"
      return 1
    fi
  fi
  persist_iptables_rules
  log "iptables 已放行 $p/tcp"
  return 0
}
close_port_iptables() {
  local p="$1"
  local removed=0
  # 删除所有匹配规则（可能重复）
  while iptables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1; do
    if iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
      removed=1
    else
      break
    fi
  done
  if [[ "$removed" -eq 1 ]]; then
    persist_iptables_rules
    log "iptables 已关闭 $p/tcp"
    return 0
  else
    warn "iptables 关闭 $p/tcp 失败或规则不存在"
    return 1
  fi
}

open_port_firewall() {
  require_root
  local p="$1"
  validate_port "$p" || die "非法端口：$p"

  # 注意：不再自动启用 UFW，避免与现有防火墙策略冲突
  # 如需启用 UFW，请使用菜单中的防火墙管理功能

  local backend result=0
  backend="$(detect_firewall_backend)"
  case "$backend" in
    iptables)  open_port_iptables "$p" || result=1 ;;
    firewalld) open_port_firewalld "$p" || result=1 ;;
    ufw)       open_port_ufw "$p" || result=1 ;;
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

# ===================== 状态同步 ===========================
sync_state_from_sshd() {
  # 用 sshd 的"最终生效配置"同步状态（避免脚本变量欺骗）
  # 注意：某些系统/配置告警下 sshd -T 可能返回非 0（即使有输出）
  # 在 set -euo pipefail 下会导致脚本直接退出，所以必须吞掉退出码。
  [[ "$(id -u)" -eq 0 ]] || return 0
  command -v sshd >/dev/null 2>&1 || return 0

  local out
  out="$(sshd -T 2>/dev/null || true)"

  # 捕获所有监听端口（支持多端口/Match 场景）
  OLD_SSH_PORTS=()
  while IFS= read -r port; do
    [[ -n "$port" ]] && OLD_SSH_PORTS+=("$port")
  done < <(awk '$1=="port"{print $2}' <<<"$out" 2>/dev/null || true)

  # 保留 OLD_SSH_PORT 为主端口（向后兼容）
  OLD_SSH_PORT="${OLD_SSH_PORTS[0]:-}"

  local pa
  pa="$(awk '$1=="passwordauthentication"{print $2; exit}' <<<"$out" || true)"
  if [[ "$pa" == "no" ]]; then
    DISABLE_PASSWORD=1
  elif [[ "$pa" == "yes" ]]; then
    DISABLE_PASSWORD=0
  fi
}

# ===================== fail2ban ===========================
configure_fail2ban() {
  require_root

  # 用户确认
  warn ">>> 即将安装/配置 fail2ban（SSH 暴力破解防护）"
  read -r -p "确认继续？[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log "已取消 fail2ban 配置"
    return 0
  fi

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    warn "fail2ban 未安装，尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y -qq || warn "apt-get update 失败，继续尝试安装..."
      if ! apt-get install -y -qq fail2ban; then
        die "fail2ban 安装失败，请手动安装后重试"
      fi
    elif command -v yum >/dev/null 2>&1; then
      if ! yum install -y -q fail2ban; then
        die "fail2ban 安装失败，请手动安装后重试"
      fi
    elif command -v dnf >/dev/null 2>&1; then
      if ! dnf install -y -q fail2ban; then
        die "fail2ban 安装失败，请手动安装后重试"
      fi
    else
      die "无法自动安装 fail2ban（不支持的包管理器）。请手动安装后重试"
    fi
  fi

  local port_to_use
  port_to_use="$( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2; exit}' )"
  port_to_use="${port_to_use:-22}"

  mkdir -p "$(dirname "$F2B_JAIL")"

  # 安全检查：确保目标不是符号链接
  if [[ -L "$F2B_JAIL" ]]; then
    die "安全错误：$F2B_JAIL 是符号链接，拒绝操作"
  fi

  backup_file "$F2B_JAIL" || true

  # 使用原子替换：先写临时文件，再 mv
  local tmp_jail
  tmp_jail="$(mktemp "$(dirname "$F2B_JAIL")/tmp.XXXXXX")"
  register_temp_file "$tmp_jail"

  cat > "$tmp_jail" <<EOF
[sshd]
enabled = true
port = ${port_to_use}
logpath = %(sshd_log)s
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  chmod 0644 "$tmp_jail"
  mv "$tmp_jail" "$F2B_JAIL"

  if ! systemctl enable fail2ban --now 2>/dev/null; then
    warn "systemctl enable fail2ban 失败，请手动启用"
  fi
  if ! systemctl restart fail2ban 2>/dev/null; then
    warn "systemctl restart fail2ban 失败，请手动重启"
  fi
  log "fail2ban 已配置：sshd jail 端口=${port_to_use}（文件：$F2B_JAIL）"
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
  echo "==========================="
  echo
}

# ===================== 菜单/交互 ==========================
toggle_disable_password() {
  if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
    DISABLE_PASSWORD=0
    log "已关闭：禁用密码登录"
  else
    DISABLE_PASSWORD=1
    warn "已开启：禁用密码登录（⚠️ 应用前会做自检）"
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
  log "目标用户已切换为：$TARGET_USER（home=$TARGET_HOME）"
}

set_ssh_port() {
  read -r -p "输入要设置的 SSH 端口（留空=不改端口）: " p
  if [[ -z "${p:-}" ]]; then
    SSH_PORT=""
    log "未设置新端口"
    return 0
  fi
  validate_port "$p" || die "非法端口：$p"
  SSH_PORT="$p"
  log "准备设置 SSH 端口为：$SSH_PORT"
}

show_status() {
  refresh_paths
  sync_state_from_sshd || true

  echo
  echo "====== 当前状态 ======"
  echo "目标用户: $TARGET_USER  (home: $TARGET_HOME)"
  echo "authorized_keys: $KEY_FILE"
  echo "禁用密码登录(脚本开关): $([[ "$DISABLE_PASSWORD" -eq 1 ]] && echo 已开启 || echo 已关闭)"
  # 显示所有监听端口（多端口场景）
  if [[ ${#OLD_SSH_PORTS[@]} -gt 1 ]]; then
    echo "SSHD 实际端口: ${OLD_SSH_PORTS[*]} (多端口)"
  else
    echo "SSHD 实际端口: ${OLD_SSH_PORT:-未知}"
  fi
  echo "防火墙后端: $(detect_firewall_backend)"
  echo "======================"
  echo
}

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
