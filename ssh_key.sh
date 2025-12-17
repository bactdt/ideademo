#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

# =========================================================
# 固定公钥定义区（唯一需要日后维护的地方）
# 一行一个 key，不要换行
SSH_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB525kOyxHEeE8DV5BXfIC9kRR3NUSEQ2yBpsw/IPo8I newnew@mydevice"
  # "ssh-ed25519 AAAA... backup@laptop"
)

# 是否允许“强制覆盖” authorized_keys（危险：会删除不在 SSH_KEYS 中的旧 key）
# 0 = 默认安全模式（只加不减）  1 = 允许菜单里选择覆盖
ALLOW_FORCE_OVERWRITE=0
# =========================================================

log()  { echo -e "$*"; }
warn() { echo -e "⚠️ $*"; }
die()  { echo -e "❌ $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# ---------- 状态 ----------
TARGET_USER="${SUDO_USER:-$(id -un)}"
DISABLE_PASSWORD=0
SSHD_CONFIG="/etc/ssh/sshd_config"
LAST_BACKUP=""

get_home_of_user() {
  local u="$1"
  local pwline
  pwline="$(getent passwd "$u" || true)"
  [[ -n "$pwline" ]] || return 1
  awk -F: '{print $6}' <<<"$pwline"
}

refresh_paths() {
  TARGET_HOME="$(get_home_of_user "$TARGET_USER" || true)"
  [[ -n "${TARGET_HOME:-}" ]] || die "用户不存在或无 home：$TARGET_USER"
  SSH_DIR="$TARGET_HOME/.ssh"
  KEY_FILE="$SSH_DIR/authorized_keys"
}

as_target_user() {
  # root 且目标用户不是当前用户时才需要 sudo -u
  if [[ "$(id -u)" -eq 0 && "$(id -un)" != "$TARGET_USER" ]]; then
    need_cmd sudo
    sudo -u "$TARGET_USER" "$@"
  else
    "$@"
  fi
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "此操作需要 root，请用 sudo 运行脚本"
}

validate_pubkey_line() {
  local k="$1"
  [[ "$k" != *$'\n'* && "$k" != *$'\r'* && "$k" != *$'\t'* ]] || return 1
  [[ "$k" =~ ^ssh-(ed25519|rsa|ecdsa)[[:space:]]+[A-Za-z0-9+/]{50,}={0,3}([[:space:]].*)?$ ]]
}

setup_ssh_directory() {
  refresh_paths
  mkdir -p "$SSH_DIR"
  chmod 0700 "$SSH_DIR"
  touch "$KEY_FILE"
  chmod 0600 "$KEY_FILE"
  # 不递归 chown，避免误伤
  chown "$TARGET_USER:$TARGET_USER" "$SSH_DIR" "$KEY_FILE" 2>/dev/null || true
}

sync_authorized_keys_append_only() {
  refresh_paths
  setup_ssh_directory

  local added=0
  local exists=0

  for key in "${SSH_KEYS[@]}"; do
    validate_pubkey_line "$key" || die "公钥格式错误：${key:0:80}..."

    if as_target_user grep -qxF -- "$key" "$KEY_FILE"; then
      exists=$((exists+1))
    else
      printf '%s\n' "$key" | as_target_user tee -a "$KEY_FILE" >/dev/null
      added=$((added+1))
    fi
  done

  log "✅ 公钥同步完成（只加不减）：新增 $added 条，已存在 $exists 条"
}

sync_authorized_keys_force_overwrite() {
  [[ "$ALLOW_FORCE_OVERWRITE" -eq 1 ]] || die "已禁用覆盖模式（ALLOW_FORCE_OVERWRITE=0）"
  refresh_paths
  setup_ssh_directory

  # 备份
  local bak="$KEY_FILE.bak.$(date +%F_%H%M%S)"
  as_target_user cp -a "$KEY_FILE" "$bak"
  log "✅ 已备份 authorized_keys：$bak"

  # 覆盖写入
  as_target_user : > "$KEY_FILE"
  local written=0
  for key in "${SSH_KEYS[@]}"; do
    validate_pubkey_line "$key" || die "公钥格式错误：${key:0:80}..."
    printf '%s\n' "$key" | as_target_user tee -a "$KEY_FILE" >/dev/null
    written=$((written+1))
  done

  chmod 0600 "$KEY_FILE"
  log "✅ 公钥同步完成（覆盖模式）：写入 $written 条（其余旧 key 已移除）"
}

show_authorized_keys() {
  refresh_paths
  [[ -f "$KEY_FILE" ]] || die "不存在：$KEY_FILE"
  echo "----- $KEY_FILE -----"
  nl -ba "$KEY_FILE" | sed -e 's/\t/    /g'
  echo "---------------------"
}

backup_sshd_config() {
  require_root
  [[ -w "$SSHD_CONFIG" ]] || die "无法写入：$SSHD_CONFIG"
  local bak="${SSHD_CONFIG}.bak.$(date +%F_%H%M%S)"
  cp -a "$SSHD_CONFIG" "$bak"
  LAST_BACKUP="$bak"
  log "✅ 已备份：$bak"
}

restore_sshd_config() {
  require_root
  [[ -n "$LAST_BACKUP" ]] || die "没有记录到备份文件（本次运行内）。"
  [[ -f "$LAST_BACKUP" ]] || die "备份文件不存在：$LAST_BACKUP"
  cp -a "$LAST_BACKUP" "$SSHD_CONFIG"
  log "✅ 已回滚到：$LAST_BACKUP"
}

configure_sshd() {
  require_root
  need_cmd awk
  need_cmd sshd

  backup_sshd_config

  if grep -Eq '^[[:space:]]*Include[[:space:]]+' "$SSHD_CONFIG"; then
    warn "检测到 Include：sshd_config.d 可能覆盖主配置，请留意。"
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v disable_pw="$DISABLE_PASSWORD" '
    BEGIN { done_pk=0; done_pa=0; inserted=0; }
    function emit_defaults() {
      if (!done_pk) { print "PubkeyAuthentication yes"; done_pk=1; }
      if (disable_pw==1 && !done_pa) { print "PasswordAuthentication no"; done_pa=1; }
      inserted=1;
    }
    {
      if ($0 ~ /^[[:space:]]*Match[[:space:]]/ && !inserted) emit_defaults()

      if ($0 ~ /^[[:space:]]*#?[[:space:]]*PubkeyAuthentication[[:space:]]+/) { done_pk=1; next; }
      if (disable_pw==1 && $0 ~ /^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+/) { done_pa=1; next; }

      print $0
    }
    END { if (!inserted) emit_defaults() }
  ' "$SSHD_CONFIG" > "$tmp"

  cat "$tmp" > "$SSHD_CONFIG"
  rm -f "$tmp"

  sshd -t -f "$SSHD_CONFIG" || die "sshd_config 校验失败（已备份：$LAST_BACKUP）"

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^sshd\.service'; then
      systemctl reload sshd || systemctl restart sshd
    elif systemctl list-unit-files | grep -q '^ssh\.service'; then
      systemctl reload ssh || systemctl restart ssh
    else
      die "systemd 下找不到 ssh/sshd 服务名，请手动重载"
    fi
  elif command -v service >/dev/null 2>&1; then
    service ssh reload || service ssh restart || service sshd restart || true
  else
    die "找不到服务管理命令，请手动重载 SSH"
  fi

  if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
    log "✅ 已启用公钥登录并禁用密码登录（务必另开终端验证密钥可用后再断开当前连接）"
  else
    log "✅ 已确保启用公钥登录（未禁用密码登录）"
  fi
}

toggle_disable_password() {
  if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
    DISABLE_PASSWORD=0
    log "已关闭：禁用密码登录"
  else
    DISABLE_PASSWORD=1
    warn "已开启：禁用密码登录（⚠️ 有锁死风险，务必先验证密钥可用）"
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

show_status() {
  refresh_paths
  echo
  echo "====== 当前状态 ======"
  echo "运行用户: $(id -un) (uid=$(id -u))"
  echo "目标用户: $TARGET_USER"
  echo "目标HOME: $TARGET_HOME"
  echo "authorized_keys: $KEY_FILE"
  echo "固定公钥条数: ${#SSH_KEYS[@]}"
  echo "禁用密码登录: $([[ "$DISABLE_PASSWORD" -eq 1 ]] && echo 开启 || echo 关闭)"
  echo "最近备份: ${LAST_BACKUP:-无}"
  echo "覆盖模式允许: $([[ "$ALLOW_FORCE_OVERWRITE" -eq 1 ]] && echo 是 || echo 否)"
  echo "======================"
  echo
}

menu() {
  cat <<'EOF'
[1] 显示当前状态
[2] 切换目标用户
[3] 初始化 ~/.ssh 权限
[4] 同步固定公钥（只加不减，推荐）
[5] 同步固定公钥（覆盖模式，危险）
[6] 查看 authorized_keys
[7] 切换“禁用密码登录”开关
[8] 应用 SSHD 配置（确保公钥登录 / 可选禁用密码）
[9] 备份 sshd_config
[10] 回滚 sshd_config（回滚到本次运行记录的最后备份）
[0] 退出
EOF
}

main_loop() {
  refresh_paths
  while true; do
    clear || true
    menu
    read -r -p "请选择: " choice
    case "${choice:-}" in
      1) show_status ;;
      2) select_target_user ;;
      3) setup_ssh_directory; log "✅ 已初始化 $SSH_DIR 与 $KEY_FILE" ;;
      4) sync_authorized_keys_append_only ;;
      5) sync_authorized_keys_force_overwrite ;;
      6) show_authorized_keys ;;
      7) toggle_disable_password ;;
      8) apply_sshd_config ;;
      9) restore_last_backup ;;
      0) log "Bye."; exit 0 ;;
      *) warn "无效选项：$choice" ;;
    esac

    echo
    read -r -p "回车继续..." _
  done
}


# 启动
main_loop
