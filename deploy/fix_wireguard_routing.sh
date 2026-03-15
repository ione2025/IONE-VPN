#!/usr/bin/env bash
# =============================================================================
# IONE VPN - Repair AmneziaWG internet forwarding/NAT on an existing droplet
# Run as root: bash /opt/ione-vpn/deploy/fix_wireguard_routing.sh
# =============================================================================
set -euo pipefail

# Default to awg0 (AmneziaWG); override with WG_INTERFACE=wg0 for vanilla WG
WG_IF="${WG_INTERFACE:-awg0}"
WG_PORT="${WG_PORT:-443}"  # Default matches app_constants.dart wgPort
WG_SUBNET_CIDR="${WG_SUBNET_CIDR:-10.9.9.0/24}"
ETH_IF=$(ip route | awk '/default/ {print $5; exit}')

if [ -z "${ETH_IF:-}" ]; then
  echo "[ERR] Could not detect default network interface"
  exit 1
fi

echo "[INFO] Using egress interface: $ETH_IF"

# 1) Ensure kernel forwarding is enabled now and persisted.
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
cat >/etc/sysctl.d/99-ione-vpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system >/dev/null

# 2) Ensure UFW permits routed traffic between wg0 and internet interface.
if [ -f /etc/default/ufw ]; then
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
fi
ufw default allow routed || true
ufw allow "${WG_PORT}/udp" || true
ufw route allow in on "$WG_IF" out on "$ETH_IF" || true
ufw route allow in on "$ETH_IF" out on "$WG_IF" || true
ufw --force reload || true

# 3) Ensure NAT and forward rules exist (idempotent).
while iptables -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$WG_IF" -j ACCEPT; done
while iptables -C FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null; do iptables -D FORWARD -o "$WG_IF" -j ACCEPT; done
iptables -I FORWARD 1 -i "$WG_IF" -j ACCEPT
iptables -I FORWARD 1 -o "$WG_IF" -j ACCEPT
iptables -t nat -C POSTROUTING -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE
# Clamp MSS on forwarded TCP to prevent PMTU black-hole stalls (slow downloads).
while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; done
iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# IPv6 NAT – required so client 10.8.0.x addresses are translated to the
# server's public IPv6 address before packets leave the egress interface.
ip6tables -t nat -C POSTROUTING -o "$ETH_IF" -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -o "$ETH_IF" -j MASQUERADE

# Tunnel interface tuning for lower queueing delay + higher throughput.
ip link set dev "$WG_IF" txqueuelen 1000 2>/dev/null || true
tc qdisc replace dev "$WG_IF" root fq 2>/dev/null || true

# Persist iptables rules if netfilter-persistent is available.
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save || true
fi

# 4) Restart AmneziaWG (awg-quick preferred, fall back to wg-quick).
if systemctl list-units --full -all 2>/dev/null | grep -q "awg-quick@${WG_IF}"; then
  systemctl restart "awg-quick@${WG_IF}"
elif systemctl list-units --full -all 2>/dev/null | grep -q "wg-quick@${WG_IF}"; then
  systemctl restart "wg-quick@${WG_IF}"
else
  awg-quick down "$WG_IF" 2>/dev/null || wg-quick down "$WG_IF" 2>/dev/null || true
  awg-quick up   "$WG_IF" 2>/dev/null || wg-quick up   "$WG_IF" 2>/dev/null || true
fi

sleep 1
awg show "$WG_IF" 2>/dev/null || wg show "$WG_IF" 2>/dev/null || true

echo "[OK] AmneziaWG routing/NAT repair completed. Reconnect the VPN client and test web browsing."
