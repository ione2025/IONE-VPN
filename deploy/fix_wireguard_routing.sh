#!/usr/bin/env bash
# =============================================================================
# IONE VPN - Repair WireGuard internet forwarding/NAT on an existing droplet
# Run as root: bash /opt/ione-vpn/deploy/fix_wireguard_routing.sh
# =============================================================================
set -euo pipefail

WG_IF="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-443}"  # Default matches app_constants.dart wgPort
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
iptables -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WG_IF" -j ACCEPT
iptables -C FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null || iptables -A FORWARD -o "$WG_IF" -j ACCEPT
iptables -t nat -C POSTROUTING -o "$ETH_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$ETH_IF" -j MASQUERADE
# IPv6 NAT – required so client 10.8.0.x addresses are translated to the
# server's public IPv6 address before packets leave the egress interface.
ip6tables -t nat -C POSTROUTING -o "$ETH_IF" -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -o "$ETH_IF" -j MASQUERADE

# Persist iptables rules if netfilter-persistent is available.
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save || true
fi

# 4) Restart WireGuard to re-apply PostUp/PostDown and verify.
systemctl restart "wg-quick@${WG_IF}"

sleep 1
wg show "$WG_IF" || true

echo "[OK] WireGuard routing/NAT repair completed. Reconnect the VPN client and test web browsing."
