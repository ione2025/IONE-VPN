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
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2
sysctl -w "net.ipv4.conf.${ETH_IF}.rp_filter=2" || true
sysctl -w "net.ipv4.conf.${WG_IF}.rp_filter=2" || true
cat >/etc/sysctl.d/99-ione-vpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
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

# Ensure awg traffic is accepted inside UFW's own forward chain ordering.
# This avoids packets hitting ufw-before-forward drops before generic FORWARD rules.
if iptables -L ufw-before-forward -n >/dev/null 2>&1; then
  while iptables -C ufw-before-forward -i "$WG_IF" -j ACCEPT 2>/dev/null; do
    iptables -D ufw-before-forward -i "$WG_IF" -j ACCEPT
  done
  while iptables -C ufw-before-forward -o "$WG_IF" -j ACCEPT 2>/dev/null; do
    iptables -D ufw-before-forward -o "$WG_IF" -j ACCEPT
  done
  iptables -I ufw-before-forward 1 -i "$WG_IF" -j ACCEPT
  iptables -I ufw-before-forward 1 -o "$WG_IF" -j ACCEPT
fi

# 3) Ensure NAT and forward rules exist (idempotent).
while iptables -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$WG_IF" -j ACCEPT; done
while iptables -C FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null; do iptables -D FORWARD -o "$WG_IF" -j ACCEPT; done
while iptables -C FORWARD -i "$ETH_IF" -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$ETH_IF" -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; done
while iptables -C FORWARD -i "$WG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$WG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT; done
iptables -I FORWARD 1 -i "$ETH_IF" -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 1 -i "$WG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 1 -i "$WG_IF" -j ACCEPT
iptables -I FORWARD 1 -o "$WG_IF" -j ACCEPT
while iptables -t nat -C POSTROUTING -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE 2>/dev/null; do iptables -t nat -D POSTROUTING -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE; done
iptables -t nat -I POSTROUTING 1 -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE
# Clamp MSS on forwarded TCP to prevent PMTU black-hole stalls (slow downloads).
while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; done
# MSS = 1240 = client MTU(1280) - IP(20) - TCP(20).
# Outer WG packet = 1280 + 60 = 1340B, safe on 4G/LTE (link MTU ≥ 1400).
# Old value was 1200 (too conservative) and --clamp-mss-to-pmtu (uses server
# awg0 MTU=1420 → MSS=1380 → outer=1480B → fragmented on some mobile paths).
for OLD_MSS in 1200 1380 1460; do
  while iptables -t mangle -C FORWARD -i "$WG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $OLD_MSS 2>/dev/null; do iptables -t mangle -D FORWARD -i "$WG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $OLD_MSS; done
  while iptables -t mangle -C FORWARD -i "$ETH_IF" -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $OLD_MSS 2>/dev/null; do iptables -t mangle -D FORWARD -i "$ETH_IF" -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $OLD_MSS; done
done
while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; done
iptables -t mangle -I FORWARD 1 -i "$WG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
iptables -t mangle -I FORWARD 1 -i "$ETH_IF" -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
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
