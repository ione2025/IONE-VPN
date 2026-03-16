#!/usr/bin/env bash
# =============================================================================
# IONE VPN - Recover handshakes/traffic and apply stealth profile safely
#
# Modes:
#   MODE=compat  -> universal compatibility (WireGuard clients): J/S=0
#   MODE=stealth -> AmneziaWG masking profile (requires AWG-capable clients)
#
# Keeps speed profile from yesterday:
#   - awg0 MTU = 1280
#   - MSS = 1240
#   - BBR + fq qdisc
#
# Usage:
#   cd /opt/ione-vpn && git pull
#   MODE=compat  bash deploy/recover_awg_handshake_and_stealth.sh
#   MODE=stealth bash deploy/recover_awg_handshake_and_stealth.sh
# =============================================================================
set -euo pipefail

MODE="${MODE:-compat}"
AWG_IF="${WG_INTERFACE:-awg0}"
WG_SUBNET_CIDR="${WG_SUBNET_CIDR:-10.9.9.0/24}"
AWG_DIR="/etc/amnezia/amneziawg"
AWG_CONF="${AWG_DIR}/${AWG_IF}.conf"
ETH_IF=$(ip route | awk '/default/ {print $5; exit}')

if [ -z "${ETH_IF:-}" ]; then
  echo "[ERR] Could not detect egress interface"; exit 1
fi
if [ ! -f "$AWG_CONF" ]; then
  echo "[ERR] Missing $AWG_CONF"; exit 1
fi

WG_BIN="awg"
QBIN="awg-quick"
if ! command -v awg >/dev/null 2>&1; then WG_BIN="wg"; fi
if ! command -v awg-quick >/dev/null 2>&1; then QBIN="wg-quick"; fi

set_or_add() {
  local key="$1" value="$2" file="$3"
  if grep -Eq "^\s*${key}\s*=" "$file"; then
    sed -i "s/^\s*${key}\s*=.*/${key} = ${value}/" "$file"
  else
    awk -v k="$key" -v v="$value" '
      BEGIN{ins=0}
      /^\[Interface\]/{print; print k " = " v; ins=1; next}
      {print}
      END{if(!ins){print "[Interface]"; print k " = " v}}
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}

remove_mss_rules() {
  for OLD in 1200 1240 1380 1460; do
    while iptables -t mangle -C FORWARD -i "$AWG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$OLD" 2>/dev/null; do
      iptables -t mangle -D FORWARD -i "$AWG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$OLD"
    done
    while iptables -t mangle -C FORWARD -i "$ETH_IF" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$OLD" 2>/dev/null; do
      iptables -t mangle -D FORWARD -i "$ETH_IF" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$OLD"
    done
  done
  while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  done
}

echo "[INFO] Applying speed baseline (BBR + fq + MTU1280 + MSS1240)..."
modprobe tcp_bbr 2>/dev/null || true
cat > /etc/sysctl.d/99-ione-vpn-perf.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${ETH_IF}.rp_filter = 2
net.ipv4.conf.${AWG_IF}.rp_filter = 2
EOF
sysctl --system >/dev/null || true

set_or_add "ListenPort" "443" "$AWG_CONF"
set_or_add "MTU" "1280" "$AWG_CONF"

if [ "$MODE" = "stealth" ]; then
  echo "[INFO] MODE=stealth: enabling low-overhead Amnezia masking"
  set_or_add "Jc"   "${AWG_JC:-1}" "$AWG_CONF"
  set_or_add "Jmin" "${AWG_JMIN:-32}" "$AWG_CONF"
  set_or_add "Jmax" "${AWG_JMAX:-96}" "$AWG_CONF"
  set_or_add "S1"   "${AWG_S1:-16}" "$AWG_CONF"
  set_or_add "S2"   "${AWG_S2:-32}" "$AWG_CONF"
  set_or_add "H1"   "${AWG_H1:-11}" "$AWG_CONF"
  set_or_add "H2"   "${AWG_H2:-22}" "$AWG_CONF"
  set_or_add "H3"   "${AWG_H3:-33}" "$AWG_CONF"
  set_or_add "H4"   "${AWG_H4:-44}" "$AWG_CONF"
else
  echo "[INFO] MODE=compat: zero obfuscation for universal client compatibility"
  set_or_add "Jc"   "0" "$AWG_CONF"
  set_or_add "Jmin" "0" "$AWG_CONF"
  set_or_add "Jmax" "0" "$AWG_CONF"
  set_or_add "S1"   "0" "$AWG_CONF"
  set_or_add "S2"   "0" "$AWG_CONF"
  set_or_add "H1"   "1" "$AWG_CONF"
  set_or_add "H2"   "2" "$AWG_CONF"
  set_or_add "H3"   "3" "$AWG_CONF"
  set_or_add "H4"   "4" "$AWG_CONF"
fi

# Ensure firewall + forward rules
ufw allow 443/udp >/dev/null 2>&1 || true
ufw default allow routed >/dev/null 2>&1 || true
ufw route allow in on "$AWG_IF" out on "$ETH_IF" >/dev/null 2>&1 || true
ufw route allow in on "$ETH_IF" out on "$AWG_IF" >/dev/null 2>&1 || true
ufw --force reload >/dev/null 2>&1 || true

while iptables -C FORWARD -i "$AWG_IF" -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$AWG_IF" -j ACCEPT; done
while iptables -C FORWARD -o "$AWG_IF" -j ACCEPT 2>/dev/null; do iptables -D FORWARD -o "$AWG_IF" -j ACCEPT; done
while iptables -C FORWARD -i "$ETH_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$ETH_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; done
while iptables -C FORWARD -i "$AWG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$AWG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT; done
iptables -I FORWARD 1 -i "$ETH_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 1 -i "$AWG_IF" -o "$ETH_IF" -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 1 -i "$AWG_IF" -j ACCEPT
iptables -I FORWARD 1 -o "$AWG_IF" -j ACCEPT

while iptables -t nat -C POSTROUTING -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE 2>/dev/null; do iptables -t nat -D POSTROUTING -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE; done
iptables -t nat -I POSTROUTING 1 -s "$WG_SUBNET_CIDR" -o "$ETH_IF" -j MASQUERADE

remove_mss_rules
iptables -t mangle -I FORWARD 1 -i "$ETH_IF" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
iptables -t mangle -I FORWARD 1 -i "$AWG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240

ip link set dev "$AWG_IF" mtu 1280 2>/dev/null || true
ip link set dev "$AWG_IF" txqueuelen 1000 2>/dev/null || true
tc qdisc replace dev "$AWG_IF" root fq 2>/dev/null || true
tc qdisc replace dev "$ETH_IF" root fq 2>/dev/null || true

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi

# Restart interface to apply Interface-level J/S/H and MTU from conf
if systemctl list-units --full -all 2>/dev/null | grep -q "awg-quick@${AWG_IF}"; then
  systemctl restart "awg-quick@${AWG_IF}"
elif systemctl list-units --full -all 2>/dev/null | grep -q "wg-quick@${AWG_IF}"; then
  systemctl restart "wg-quick@${AWG_IF}"
else
  ${QBIN} down "$AWG_IF" 2>/dev/null || true
  ${QBIN} up "$AWG_IF"
fi

sleep 1
echo ""
echo "===================== STATUS ====================="
$WG_BIN show "$AWG_IF" || true
echo "--------------------------------------------------"
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
ip link show "$AWG_IF" | grep -o 'mtu [0-9]*' || true
iptables -t mangle -L FORWARD -n | grep TCPMSS || true
echo "=================================================="

echo "[OK] Recovery complete."
echo "[NOTE] If MODE=stealth was used, regenerate client configs so J/S/H match."
