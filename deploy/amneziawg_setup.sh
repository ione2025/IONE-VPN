#!/usr/bin/env bash
# =============================================================================
# IONE VPN – AmneziaWG Server Setup
# Replaces vanilla WireGuard with AmneziaWG for DPI bypass (China/Iran/Russia).
#
# AmneziaWG adds per-packet junk-injection obfuscation fields (Jc, Jmin, Jmax,
# S1–S4, H1–H4) that make handshake packets look like random UDP noise to Deep
# Packet Inspection systems. With all *J/S/H* parameters set to zero the
# protocol is wire-compatible with vanilla WireGuard — zero obfuscation overhead.
# Increase S4 (1–16 bytes) or Jc (1 junk packet) only if actively blocked.
#
# Run as root on Ubuntu 22.04: bash deploy/amneziawg_setup.sh
# =============================================================================
set -euo pipefail

AWG_IF="awg0"
AWG_DIR="/etc/amnezia/amneziawg"
AWG_PORT="443"          # UDP 443 – disguised as QUIC/HTTPS, not filtered by GFW
AWG_SUBNET="10.9.9.1/24"
AWG_SUBNET_CIDR="10.9.9.0/24"
AWG_DNS="1.1.1.1,8.8.8.8"
MTU="1420"              # Optimal for most ISPs; use 1280 only on PPPoE/mobile with fragmentation

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[AWG]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ─── 0. Detect network interface ─────────────────────────────────────────────
ETH_IF=$(ip route | awk '/default/ {print $5; exit}')
info "Egress interface: $ETH_IF"

# ─── 1. Install AmneziaWG kernel module + tools ──────────────────────────────
info "Installing AmneziaWG..."
apt-get update -y
apt-get install -y curl git make dkms linux-headers-"$(uname -r)" build-essential

# Official AmneziaWG installer (builds awg kernel module + awg-quick tool)
if ! command -v awg &>/dev/null; then
  TMP=$(mktemp -d)
  curl -fsSL https://raw.githubusercontent.com/anten-ka/amneziawg-installer/main/install_amneziawg.sh \
    -o "$TMP/install_amneziawg.sh"
  chmod +x "$TMP/install_amneziawg.sh"
  # Non-interactive env vars let the installer skip prompts
  AWG_PORT_ENV=$AWG_PORT \
  AWG_SUBNET_ENV=$AWG_SUBNET \
  bash "$TMP/install_amneziawg.sh" --non-interactive || true
  rm -rf "$TMP"
fi

# If the automated installer did not create the directory, make it ourselves
mkdir -p "$AWG_DIR"
chmod 700 "$AWG_DIR"

# ─── 2. Generate server keys (idempotent) ────────────────────────────────────
if [ ! -f "$AWG_DIR/privatekey" ]; then
  info "Generating AmneziaWG server key pair..."
  # awg uses the same key format as wg (Curve25519)
  if command -v awg &>/dev/null; then
    awg genkey | tee "$AWG_DIR/privatekey" | awg pubkey > "$AWG_DIR/publickey"
  else
    wg genkey | tee "$AWG_DIR/privatekey" | wg pubkey > "$AWG_DIR/publickey"
  fi
  chmod 600 "$AWG_DIR/privatekey"
fi

SERVER_PRIVATE_KEY=$(cat "$AWG_DIR/privatekey")
SERVER_PUBLIC_KEY=$(cat "$AWG_DIR/publickey")
info "Server public key: $SERVER_PUBLIC_KEY"

# ─── 3. Detect public IP ────────────────────────────────────────────────────
DROPLET_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
  DROPLET_IP=$(curl -sf --max-time 5 "$url" || true)
  [[ "$DROPLET_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
done
info "Server IP: $DROPLET_IP"

# ─── 4. Kernel tuning ────────────────────────────────────────────────────────
info "Applying kernel tuning..."
sysctl -w net.ipv4.ip_forward=1
# IPv6 forwarding: disabled intentionally (recommended for China scenarios –
# the GFW actively exploits IPv6 to de-anonymise tunnel users)
cat >/etc/sysctl.d/99-ione-awg.conf <<SYSCTL
net.ipv4.ip_forward = 1
# IPv6 disabled (GFW can use IPv6 to de-anonymise VPN users)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
# TCP BBR – higher throughput, lower latency
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Socket buffers (128 MB) – needed for full-speed WireGuard on gigabit links
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
# Throughput & latency
# Prevents TCP halving its window after a brief idle pause (critical for VPN speed)
net.ipv4.tcp_slow_start_after_idle = 0
# Allow probing for the right MTU when black-hole routers drop oversized packets
net.ipv4.tcp_mtu_probing = 1
# TCP Fast Open: client+server (reduces HTTPS handshake by 1 RTT)
net.ipv4.tcp_fastopen = 3
# Reduce unsent data buffer so BBR doesn't over-queue (minimises latency spike)
net.ipv4.tcp_notsent_lowat = 16384
# Low-latency UDP poll (reduces IRQ-to-userspace delay for WireGuard packets)
net.core.busy_poll = 50
net.core.busy_read = 50
# Connection handling
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
# Detect dead WireGuard peers faster
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
# Connection-tracking table – prevents drops under high peer count
net.netfilter.nf_conntrack_max = 1048576
# Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
SYSCTL
modprobe tcp_bbr || true
sysctl --system >/dev/null

# ─── 5. UFW rules ────────────────────────────────────────────────────────────
info "Configuring UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed
# Only open what is needed – minimal attack surface
ufw allow 2222/tcp   comment 'SSH hardened port'
ufw allow 443/udp    comment 'AmneziaWG stealth port'
ufw allow 80/tcp     comment 'HTTP health / certbot'
ufw allow 443/tcp    comment 'HTTPS API'
# Block default SSH port after allowing 2222 (do this last to avoid lockout)
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
ufw route allow in on "$AWG_IF" out on "$ETH_IF" || true
ufw route allow in on "$ETH_IF" out on "$AWG_IF" || true
ufw --force enable

# ─── 6. Write awg0.conf ──────────────────────────────────────────────────────
info "Writing $AWG_DIR/$AWG_IF.conf ..."
cat >"$AWG_DIR/$AWG_IF.conf" <<EOF
# IONE VPN – AmneziaWG server configuration
# Generated by deploy/amneziawg_setup.sh – managed by backend API.
# Obfuscation parameters: all zero = vanilla WireGuard speed, no DPI fingerprint.
# To unblock in heavily censored networks: set S4=16, then Jc=1.

[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address    = $AWG_SUBNET
ListenPort = $AWG_PORT
MTU        = $MTU
SaveConfig = false

# ── AmneziaWG obfuscation parameters ─────────────────────────────────────────
# Jc   = number of junk packets injected before real handshake (0 = disabled)
# Jmin = minimum junk payload size in bytes
# Jmax = maximum junk payload size in bytes
# S1   = additional bytes appended to InitiationMessage
# S2   = additional bytes appended to ResponseMessage
# H1-4 = magic header values (must match client exactly)
Jc   = 0
Jmin = 0
Jmax = 0
S1   = 0
S2   = 0
H1   = 1
H2   = 2
H3   = 3
H4   = 4

# ── NAT – route AmneziaWG client traffic through the server internet interface ─
# MSS clamping: clamps TCP SYN/SYN-ACK segments so they fit inside the WireGuard
# MTU. Without this, large TCP packets are silently dropped and the connection
# appears to work but runs at 1-5% of expected speed.
PostUp   = iptables -I FORWARD 1 -i %i -j ACCEPT; \
           iptables -I FORWARD 1 -o %i -j ACCEPT; \
           iptables -t nat -A POSTROUTING -s $AWG_SUBNET_CIDR -o $ETH_IF -j MASQUERADE; \
           iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; \
           ip link set dev %i txqueuelen 1000; \
           tc qdisc replace dev %i root fq
PostDown = iptables -D FORWARD -i %i -j ACCEPT; \
           iptables -D FORWARD -o %i -j ACCEPT; \
           iptables -t nat -D POSTROUTING -s $AWG_SUBNET_CIDR -o $ETH_IF -j MASQUERADE; \
           iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true

# Peers are appended here by the backend API (same format as WireGuard).
EOF
chmod 600 "$AWG_DIR/$AWG_IF.conf"

# ─── 7. Enable and start awg0 ─────────────────────────────────────────────────
info "Starting AmneziaWG interface $AWG_IF..."
if command -v awg-quick &>/dev/null; then
  systemctl enable --now "awg-quick@$AWG_IF" || awg-quick up "$AWG_IF"
else
  # Fall back to wg-quick if awg-quick is not yet installed
  # (happens if the installer did not finish) – tunnel still works.
  warn "awg-quick not found, falling back to wg-quick"
  systemctl enable --now "wg-quick@$AWG_IF" || wg-quick up "$AWG_IF"
fi

# Do not restart UFW after awg0 is up; it can reorder/flush chains and degrade
# tunnel forwarding performance. Route rules were already applied above.

# ─── 8. SSH hardening ────────────────────────────────────────────────────────
info "Hardening SSH..."
SSHD=/etc/ssh/sshd_config
# Change port to 2222, disable root+password auth
sed -i 's/^#\?Port .*/Port 2222/'                        "$SSHD"
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/'    "$SSHD"
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD"
sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' "$SSHD"
systemctl restart sshd || true
warn "SSH is now on port 2222. Reconnect with: ssh -p 2222 root@$DROPLET_IP"

# ─── 9. Fail2Ban ──────────────────────────────────────────────────────────────
info "Configuring Fail2Ban..."
apt-get install -y fail2ban
cat >/etc/fail2ban/jail.d/ione-vpn.conf <<'F2B'
[sshd]
enabled  = true
port     = 2222
maxretry = 3
bantime  = 86400
findtime = 600
F2B
systemctl enable --now fail2ban

# ─── 10. Unattended upgrades ──────────────────────────────────────────────────
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

# ─── Done ─────────────────────────────────────────────────────────────────────
info "============================================================"
info " AmneziaWG setup complete!"
info ""
info " Add these to backend/.env:"
info "   AWG_SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY"
info "   AWG_SERVER_ENDPOINT=${DROPLET_IP}:${AWG_PORT}"
info "   SERVER_IP=$DROPLET_IP"
info ""
info " Verify tunnel: awg show $AWG_IF"
info "============================================================"
