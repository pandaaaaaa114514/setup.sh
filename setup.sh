
#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 12 SSH + TOTP 初期設定
# rootで実行すること

ADMIN_USER="admin"
SSH_CONFIG="/etc/ssh/sshd_config"
PAM_CONFIG="/etc/pam.d/sshd"
BACKUP_DIR="/root/ssh-setup-backup-$(date +%Y%m%d-%H%M%S)"

if [[ "$EUID" -ne 0 ]]; then
    echo "rootで実行してください。"
    exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
    echo "Debian専用スクリプトです。"
    exit 1
fi

echo "======================================"
echo " Debian Server Initial Setup"
echo "======================================"

# --------------------------------------
# 入力
# --------------------------------------

read -rp "新しいSSHポート番号: " SSH_PORT

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] ||
   (( 10#$SSH_PORT < 1024 || 10#$SSH_PORT > 65535 )); then
    echo "1024〜65535のポートを指定してください。"
    exit 1
fi

SSH_PORT=$((10#$SSH_PORT))

echo
echo "adminユーザーのパスワードを設定します。"

if ! id "$ADMIN_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$ADMIN_USER"
fi

passwd "$ADMIN_USER"

usermod -aG sudo "$ADMIN_USER"

# --------------------------------------
# APT
# --------------------------------------

echo "[1/9] パッケージ更新"

apt-get update
DEBIAN_FRONTEND=noninteractive \
    apt-get upgrade -y

# --------------------------------------
# Packages
# --------------------------------------

echo "[2/9] 必要パッケージのインストール"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    sudo \
    git \
    ufw \
    openssh-server \
    libpam-google-authenticator \
    qrencode

# --------------------------------------
# Backup
# --------------------------------------

echo "[3/9] SSH設定バックアップ"

mkdir -p "$BACKUP_DIR"

cp -a "$SSH_CONFIG" "$BACKUP_DIR/sshd_config"
cp -a "$PAM_CONFIG" "$BACKUP_DIR/pam_sshd"

# --------------------------------------
# TOTP
# --------------------------------------

echo "[4/9] TOTP設定"

# adminのTOTP秘密鍵を生成
# -t: TOTP
# -d: トークン再利用防止
# -f: 確認なし
# -r/-R: 試行回数制限
# -w: 時刻ずれ許容
# -Q UTF8: QRコード出力
# -s: 保存先

TOTP_FILE="/home/$ADMIN_USER/.google_authenticator"

if [[ -e "$TOTP_FILE" ]]; then
    echo "既存のTOTP設定を維持します。"
else
    runuser -u "$ADMIN_USER" -- \
        google-authenticator \
        -t -d -f \
        -r 3 -R 30 \
        -w 3 \
        -Q UTF8 \
        -s "$TOTP_FILE"
fi

chown "$ADMIN_USER:$ADMIN_USER" "$TOTP_FILE"
chmod 600 "$TOTP_FILE"

# --------------------------------------
# PAM
# --------------------------------------

echo "[5/9] PAM設定"

# Debian標準のcommon-authを維持し、
# パスワード認証後にTOTPを要求する。

sed -i \
    '/^[[:space:]]*auth[[:space:]].*pam_google_authenticator\.so/d' \
    "$PAM_CONFIG"

echo "auth required pam_google_authenticator.so" \
    >> "$PAM_CONFIG"

# --------------------------------------
# SSH Configuration
# --------------------------------------

echo "[6/9] SSH設定"

# DebianのInclude設定による上書きを避けるため、
# 先頭で専用設定ファイルを読み込ませる。

mkdir -p /etc/ssh/sshd_config.d

CUSTOM_CONFIG="/etc/ssh/sshd_config.d/00-initial-security.conf"

if [[ -e "$CUSTOM_CONFIG" ]]; then
    cp -a "$CUSTOM_CONFIG" \
        "$BACKUP_DIR/00-initial-security.conf"
fi

cat > "$CUSTOM_CONFIG" <<EOF
Port $SSH_PORT

PermitRootLogin no

PasswordAuthentication no
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes

AuthenticationMethods keyboard-interactive:pam

PermitEmptyPasswords no
X11Forwarding no
EOF

# Includeを先頭に配置
if ! grep -Eq \
    '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' \
    "$SSH_CONFIG"; then

    sed -i \
        '1i Include /etc/ssh/sshd_config.d/*.conf' \
        "$SSH_CONFIG"
fi

# --------------------------------------
# SSH validation
# --------------------------------------

echo "[7/9] SSH設定検証"

if ! sshd -t; then
    echo "SSH設定にエラーがあります。"
    echo "バックアップ: $BACKUP_DIR"
    exit 1
fi

# --------------------------------------
# Firewall
# --------------------------------------

echo "[8/9] UFW設定"

ufw allow "$SSH_PORT/tcp"

# 既存のUFWルールは削除しない。
ufw --force enable

# --------------------------------------
# SSH restart
# --------------------------------------

echo "[9/9] SSH設定反映"

systemctl enable ssh
systemctl reload ssh

echo
echo "======================================"
echo " 初期設定完了"
echo "======================================"
echo
echo "SSHユーザー: $ADMIN_USER"
echo "SSHポート: $SSH_PORT"
echo "root SSHログイン: 無効"
echo "認証方式: パスワード + TOTP"
echo "Git: インストール済み"
echo "UFW: 有効"
echo
echo "接続コマンド:"
echo "ssh -p $SSH_PORT $ADMIN_USER@サーバーIP"
echo
echo "重要:"
echo "現在のSSH接続は閉じず、"
echo "別ターミナルからログインを確認してください。"
echo
echo "TOTP設定ファイル:"
echo "$TOTP_FILE"
echo
echo "バックアップ:"
echo "$BACKUP_DIR"
