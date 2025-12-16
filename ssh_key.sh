#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

log() { echo -e "$*"; }
die() { echo -e "❌ $*" >&2; exit 1; }

# 选择目标用户：sudo 场景默认写 SUDO_USER 的 home；否则写当前用户
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || die "无法获取用户 $TARGET_USER 的 home"

SSH_DIR="$TARGET_HOME/.ssh"
KEY_FILE="$SSH_DIR/authorized_keys"

setup_ssh_directory() {
  mkdir -p "$SSH_DIR"
  chmod 0700 "$SSH_DIR"
  touch "$KEY_FILE"
  chmod 0600 "$KEY_FILE"
  chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
}

add_ssh_key_if_not_exists() {
  local ssh_key="$1"

  # 基础格式校验：拒绝换行/控制字符，且必须包含 ssh-xxx 前缀与主体
  [[ "$ssh_key" != *$'\n'* && "$ssh_key" != *$'\r'* ]] || die "公钥包含换行，拒绝写入"
  [[ "$ssh_key" =~ ^ssh-(ed25519|rsa|ecdsa)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] \
    || die "公钥格式看起来不对：${ssh_key:0:40}..."

  if sudo -u "$TARGET_USER" grep -qxF -- "$ssh_key" "$KEY_FILE"; then
    log "✅ SSH 公钥已存在: ${ssh_key:0:30}..."
  else
    printf '%s\n' "$ssh_key" | sudo -u "$TARGET_USER" tee -a "$KEY_FILE" >/dev/null
    log "✅ 已添加 SSH 公钥: ${ssh_key:0:30}..."
  fi
}

configure_sshd() {
  local sshd_config="/etc/ssh/sshd_config"
  [ -w "$sshd_config" ] || die "无法写入 $sshd_config，请以 root 运行"

  cp -a "$sshd_config" "$sshd_config.bak.$(date +%F_%H%M%S)"

  # 用“存在则替换，不存在则追加”的方式，避免重复；尽量放在文件末尾但避免 Match 语义问题：
  # 这里简单做法是：在首次 Match 之前插入；若无 Match 则追加到末尾。
  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { done_pk=0; done_pa=0; done_pwa=0; inserted=0; }
    function emit_defaults() {
      if (!done_pk)  { print "PubkeyAuthentication yes"; done_pk=1; }
      if (!done_pa)  { print "PasswordAuthentication no"; done_pa=1; }
      inserted=1;
    }
    {
      if ($0 ~ /^[[:space:]]*Match[[:space:]]/ && !inserted) {
        emit_defaults()
      }
      # 跳过旧配置行（含注释形式）
      if ($0 ~ /^[[:space:]]*#?[[:space:]]*PubkeyAuthentication[[:space:]]+/)  { done_pk=1; next; }
      if ($0 ~ /^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+/){ done_pa=1; next; }
      print $0
    }
    END {
      if (!inserted) emit_defaults()
    }
  ' "$sshd_config" > "$tmp"

  cat "$tmp" > "$sshd_config"
  rm -f "$tmp"

  # 校验配置
  if command -v sshd >/dev/null; then
    sshd -t -f "$sshd_config" || die "sshd_config 校验失败，已保留备份文件"
  else
    die "找不到 sshd 命令，无法校验配置"
  fi

  # reload 优先，避免断开现有连接（但仍建议你保留当前会话，另开新会话验证）
  if command -v systemctl >/dev/null; then
    if systemctl list-unit-files | grep -q '^sshd\.service'; then
      systemctl reload sshd || systemctl restart sshd
    elif systemctl list-unit-files | grep -q '^ssh\.service'; then
      systemctl reload ssh || systemctl restart ssh
    else
      die "systemd 下找不到 ssh/sshd 服务名，请手动 reload"
    fi
  elif command -v service >/dev/null; then
    service ssh reload || service ssh restart || service sshd restart || true
  else
    die "找不到服务管理命令，请手动重载 SSH"
  fi

  log "✅ 已启用公钥登录并禁用密码登录（请务必另开新终端验证密钥可用后再断开当前连接）"
}

main() {
  setup_ssh_directory

  SSH_KEYS=(
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC3uRpLhjTx7ECNFJPT2VNhW8CnKtroIWj1YV2vcon5o9dsHk6e18FMTcGXQIcnhFASKhVCLQ0vSr86fWSFoyEDxcIMS1r107EYPBjrEeDNkauSxZNuiYOmFmlVuY7mWZWTb9qSf6BOd7PW6csU233ON8M0DVpq3fm4yF2pBM0yFztoOejcb70bGaeyYNQkKaMKvaLGg9dX7R3oJTKaB0bokmd3ozzQbKeQ3a4iQ+Es5cWTm0NsoB3H3yPZUFBjyDFucUsNYnsug4wLu3W3nwX56j+Za+tLo4VDYGbAm1Fp+W1jnNuOkO9ZostDGLpLkVqOSpKVwbpaSPYNHYpPauFxjfKgeNlwzJjWL93pKpSvnjIvfvinDNHRiiNd1wBuZnEy6eigCxLiqvz1aDOeECkrMIBrH7Cjji2tPv7gOHAyfw3im0DRpTsOj61nCMtsXASuTfOEDjMcurWOPs5+BC/m8FhmipUzpGgSqsDEVyMkFzvruMMhN3mdoBVMwFiZ29Ram5oI4MPWZqw3LicbmsJ4hai3wbeNlKMEeS/INOJAR1DEpXNC7oqW9Z2JQVNVsEGbn1f4YvnMUbigMoiJJZxshCHCAaZk4fzcchLUZytVdzA2wZGosr6TIEJ8bqD6Q3ecYdQfC1nhqBjOpJIZ8WpqjF1wixlgew9rUsN22BVc8w== newnew@mydevice"
  )

  for key in "${SSH_KEYS[@]}"; do
    add_ssh_key_if_not_exists "$key"
  done

  configure_sshd
}

main "$@"
