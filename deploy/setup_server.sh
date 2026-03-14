#!/usr/bin/env bash
# =============================================================================
# IONE VPN – DigitalOcean Droplet Full Setup Script
# OS: Ubuntu 22.04 LTS
# Run as root on a fresh droplet: bash setup_server.sh
# =============================================================================
set -euo pipefail

DROPLET_USER="ionevpn"
APP_DIR="/opt/ione-vpn"
NODE_VERSION="20"

# ─── Colour helpers ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ─── 1. System update ─────────────────────────────────────────────────────────
info "Updating system packages..."
apt-get update -y && apt-get upgrade -y
apt-get install -y curl git ufw fail2ban unzip net-tools

# ─── 2. Create app user ───────────────────────────────────────────────────────
if ! id "$DROPLET_USER" &>/dev/null; then
  info "Creating user $DROPLET_USER..."
  useradd -m -s /bin/bash "$DROPLET_USER"
fi

# ─── 3. Firewall (UFW) ────────────────────────────────────────────────────────
info "Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
# WireGuard requires forwarded/routed traffic to be accepted.
ufw default allow routed
ufw allow ssh
ufw allow 80/tcp    # HTTP (Let's Encrypt challenge)
ufw allow 443/tcp   # HTTPS
ufw allow 51820/udp # WireGuard
ufw allow 1194/udp  # OpenVPN

# Persist routed-forward policy in UFW config so VPN traffic survives reboots.
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true

# Allow forwarding between wg0 and the primary egress interface in UFW.
ETH_IF=$(ip route | awk '/default/ {print $5; exit}')
if [ -n "${ETH_IF:-}" ]; then
  ufw route allow in on wg0 out on "$ETH_IF" || true
  ufw route allow in on "$ETH_IF" out on wg0 || true
fi

ufw --force enable
info "Firewall active:"
ufw status

# ─── 4. Node.js ───────────────────────────────────────────────────────────────
info "Installing Node.js $NODE_VERSION..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
apt-get install -y nodejs
node -v && npm -v

# ─── 5. MongoDB 7 ─────────────────────────────────────────────────────────────
info "Installing MongoDB..."
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
  gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
  https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-7.0.list
apt-get update -y && apt-get install -y mongodb-org
systemctl enable --now mongod
info "MongoDB status: $(systemctl is-active mongod)"

# ─── 6. Redis ─────────────────────────────────────────────────────────────────
info "Installing Redis..."
apt-get install -y redis-server
REDIS_PASSWORD=$(openssl rand -base64 32)
info "Generated Redis password (save this – you need it in .env): $REDIS_PASSWORD"
sed -i "s/^# requirepass.*/requirepass $REDIS_PASSWORD/" /etc/redis/redis.conf
sed -i 's/^bind 127.0.0.1 ::1/bind 127.0.0.1/' /etc/redis/redis.conf
systemctl enable --now redis-server
info "Redis status: $(systemctl is-active redis-server)"

# ─── 7. Nginx ─────────────────────────────────────────────────────────────────
info "Installing Nginx..."
apt-get install -y nginx
systemctl enable --now nginx

# ─── 8. WireGuard ─────────────────────────────────────────────────────────────
info "Installing WireGuard..."
apt-get install -y wireguard wireguard-tools

# Enable IP forwarding
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ione-vpn.conf
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-ione-vpn.conf
sysctl --system

# ─── 9. OpenVPN ───────────────────────────────────────────────────────────────
info "Installing OpenVPN..."
apt-get install -y openvpn easy-rsa

# ─── 10. PM2 (Node.js process manager) ───────────────────────────────────────
info "Installing PM2..."
npm install -g pm2
pm2 startup systemd -u "$DROPLET_USER" --hp "/home/$DROPLET_USER"

# ─── 11. Clone / update repo ─────────────────────────────────────────────────
info "Setting up application directory..."
mkdir -p "$APP_DIR"
chown "$DROPLET_USER:$DROPLET_USER" "$APP_DIR"

# If the repo is already cloned, pull; otherwise clone
if [ -d "$APP_DIR/.git" ]; then
  su -c "cd $APP_DIR && git pull" "$DROPLET_USER"
else
  warn "Clone your repo manually: git clone https://github.com/ione2025/IONE-VPN.git $APP_DIR"
fi

info "Installing backend dependencies..."
if [ -f "$APP_DIR/backend/package.json" ]; then
  su -c "cd $APP_DIR/backend && npm ci --omit=dev" "$DROPLET_USER"
fi

# ─── 12. Copy Nginx config ───────────────────────────────────────────────────
if [ -f "$APP_DIR/deploy/nginx.conf" ]; then
  cp "$APP_DIR/deploy/nginx.conf" /etc/nginx/sites-available/ione-vpn
  ln -sf /etc/nginx/sites-available/ione-vpn /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
fi

# ─── 13. WireGuard config ────────────────────────────────────────────────────
info "Running WireGuard setup..."
if [ -f "$APP_DIR/deploy/wireguard_setup.sh" ]; then
  bash "$APP_DIR/deploy/wireguard_setup.sh"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
info "============================================================"
info " IONE VPN droplet setup complete!"
info " Next steps:"
info "   1. Edit $APP_DIR/backend/.env (see SETUP.md)"
info "   2. Run: su $DROPLET_USER -c 'cd $APP_DIR/backend && pm2 start src/app.js --name ione-vpn-api'"
info "   3. Set up SSL: certbot --nginx -d YOUR_DOMAIN"
info "============================================================"
