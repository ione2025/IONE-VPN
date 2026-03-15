#!/usr/bin/env bash
# =============================================================================
# IONE VPN - Revert AWG host networking to a simple WireGuard-like profile
# Keeps AmneziaWG enabled, but removes aggressive kernel tuning and restores
# conservative forwarding/NAT behavior closer to the previously fast setup.
#
# Run as root on the droplet:
#   bash /opt/ione-vpn/deploy/apply_awg_simple_profile.sh
# =============================================================================
set -euo pipefail

AWG_IF="${WG_INTERFACE:-awg0}"
WG_SUBNET_CIDR="${WG_SUBNET_CIDR:-10.9.9.0/24}"
ETH_IF=$(ip route | awk '/default/ {print $5; exit}')

if [ -z "${ETH_IF:-}" ]; then
  echo "[ERR] Could not detect default network interface"
  exit 1
fi

echo "[INFO] Using egress interface: $ETH_IF"

echo "[INFO] Applying simple sysctl profile..."
cat >/etc/sysctl.d/99-ione-awg.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${ETH_IF}.rp_filter = 2
net.ipv4.conf.${AWG_IF}.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
EOF
sysctl --system >/dev/null

echo "[INFO] Resetting forwarding/NAT rules to a simple profile..."
# Keep UFW routed traffic enabled.
if [ -f /etc/default/ufw ]; then
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
fi
ufw default allow routed || true
ufw route allow in on "$AWG_IF" out on "$ETH_IF" || true
ufw route allow in on "$ETH_IF" out on "$AWG_IF" || true
ufw --force reload || true

# Remove custom MSS rules from previous tuning.
while iptables -t mangle -C FORWARD -i "$AWG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null; do
  iptables -t mangle -D FORWARD -i "$AWG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
 done
while iptables -t mangle -C FORWARD -i "$ETH_IF" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null; do
  iptables -t mangle -D FORWARD -i "$ETH_IF" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
 done
while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
  iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
 done
iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Rebuild simple stateful forwarding rules.
while iptables -C FORWARD -i "$AWG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
  iptables -D FORWARD -i "$AWG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
 done
while iptables -C FORWARD -i "$ETH_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
  iptables -D FORWARD -i "$ETH_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
 done
iptables -I FORWARD 1 -i "$ETH_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 1 -i "$AWG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT

while iptables -t nat -C POSTROUTING -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE 2>/dev/null; do
  iptables -t nat -D POSTROUTING -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE
 done
iptables -t nat -I POSTROUTING 1 -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE

# Remove tunnel-side qdisc tweaks to match a simpler baseline.
tc qdisc del dev "$AWG_IF" root 2>/dev/null || true
ip link set dev "$AWG_IF" txqueuelen 500 2>/dev/null || true

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save || true
fi

echo "[INFO] Restarting $AWG_IF..."
if systemctl list-units --full -all 2>/dev/null | grep -q "awg-quick@${AWG_IF}"; then
  systemctl restart "awg-quick@${AWG_IF}"
else
  awg-quick down "$AWG_IF" 2>/dev/null || true
  awg-quick up "$AWG_IF" 2>/dev/null || true
fi

sleep 1
awg show "$AWG_IF" 2>/dev/null || true

echo "[OK] Simple AWG profile applied. Reconnect client and retest download speed."
