#!/usr/bin/env bash
# =============================================================================
# IONE VPN – Boost download speed on the AWG droplet (no restart required)
#
# Root causes addressed:
#  1. CUBIC at 370ms RTT → very slow window ramp-up.  BBR fixes this.
#  2. Server awg0 MTU=1420  →  outer WG packets = 1480 bytes.  Any mobile/4G
#     path with link MTU < 1480 fragments the outer UDP.  WireGuard's AEAD tag
#     covers the whole inner packet, so IP-fragmented outer UDP cannot be
#     decrypted → downloads stall.  Fix: set server awg0 MTU=1280 so outer
#     packets are 1340 bytes (safe on every network).
#  3. MSS 1200 (old fixed value) is too conservative.  Correct value given
#     client MTU=1280: MSS = 1280 - 40 (IP+TCP headers) = 1240.
#  4. 128 MB socket buffers from previous tuning cause buffer-bloat which
#     inflates RTT and confuses congestion control.  32 MB (2× BDP) is right.
#
# Run as root on the droplet (live – no AWG restart needed):
#   cd /opt/ione-vpn && git pull && bash deploy/boost_download_speed.sh
# =============================================================================
set -euo pipefail

AWG_IF="${WG_INTERFACE:-awg0}"
WG_SUBNET_CIDR="${WG_SUBNET_CIDR:-10.9.9.0/24}"
# All clients (Android/iOS/Windows) use MTU 1280 – must match app_constants.dart
CLIENT_MTU="${CLIENT_MTU:-1280}"

ETH_IF=$(ip route | awk '/default/ {print $5; exit}')
if [ -z "${ETH_IF:-}" ]; then
  echo "[ERR] Could not detect default network interface"; exit 1
fi

# Derived constants
WG_OVERHEAD=60                               # IPv4(20)+UDP(8)+WG data header(32) bytes
OUTER_MTU=$(( CLIENT_MTU + WG_OVERHEAD ))   # 1340 – safe on 4G/LTE (link MTU ≥ 1400)
OPTIMAL_MSS=$(( CLIENT_MTU - 40 ))          # 1240 = 1280 - IP(20) - TCP(20)

echo "[INFO] ETH: $ETH_IF | AWG: $AWG_IF | Client MTU: $CLIENT_MTU"
echo "[INFO] Outer WG packet: ${OUTER_MTU}B | TCP MSS: ${OPTIMAL_MSS}B"

# ─── 1. Load BBR kernel module ────────────────────────────────────────────────
echo "[INFO] Loading BBR..."
modprobe tcp_bbr 2>/dev/null || true
# Verify the module is available
if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  echo "[WARN] BBR not in available list – kernel may be too old. Falling back to CUBIC."
  CC="cubic"
else
  CC="bbr"
fi

# ─── 2. Optimized sysctl (overwrites any previous ione-vpn sysctl files) ─────
echo "[INFO] Writing /etc/sysctl.d/99-ione-vpn-perf.conf..."
cat > /etc/sysctl.d/99-ione-vpn-perf.conf << EOF
# IONE VPN – Download speed optimisation
# Applied by deploy/boost_download_speed.sh – do not edit manually.

# IP / IPv6
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# Congestion control: BBR + FQ is the best pairing for a 370ms RTT VPN.
# BBR probes available bandwidth without backing off on isolated packet loss;
# FQ enables per-flow pacing so BBR can accurately measure queue depth.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC}

# Socket buffers sized for bandwidth-delay product:
#   BDP = 350 Mbps × 0.370 s / 8 ≈ 16 MB
#   max = 32 MB (2× BDP) – avoids buffer-bloat from the old 128 MB config.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432

# Handle bursty traffic from 10+ concurrent VPN clients
net.core.netdev_max_backlog = 10000
net.core.netdev_budget = 600

# Connection tracking: 500 connections/client × 10 clients × 2 (generous)
net.netfilter.nf_conntrack_max = 131072

# Loose rp_filter: allows asymmetric routing paths through the AWG tunnel.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${ETH_IF}.rp_filter = 2
net.ipv4.conf.${AWG_IF}.rp_filter = 2

# Safety
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
EOF

# Remove old conflicting files
rm -f /etc/sysctl.d/99-ione-awg.conf /etc/sysctl.d/99-ione-vpn.conf 2>/dev/null || true

sysctl --system > /dev/null
echo "[OK] sysctl applied (cc=${CC})"

# ─── 3. FQ qdisc on both interfaces ──────────────────────────────────────────
echo "[INFO] Applying FQ qdisc to $AWG_IF and $ETH_IF..."
ip link set dev "$AWG_IF" txqueuelen 1000 2>/dev/null || true
tc qdisc replace dev "$AWG_IF" root fq 2>/dev/null || \
  tc qdisc add    dev "$AWG_IF" root fq 2>/dev/null || true
tc qdisc replace dev "$ETH_IF" root fq 2>/dev/null || true
echo "[OK] FQ applied"

# ─── 4. Set server AWG interface MTU = client MTU (1280) ─────────────────────
# With server awg0 MTU=1420 the encrypted outer packets are 1480 bytes.
# Many 4G/LTE and PPPoE paths have an effective MTU of 1400–1460 bytes and
# will fragment these, silently destroying download throughput.
# Setting server awg0 MTU=1280 makes outer packets 1340 bytes – safe everywhere.
echo "[INFO] Setting $AWG_IF MTU → $CLIENT_MTU..."
ip link set dev "$AWG_IF" mtu "$CLIENT_MTU" 2>/dev/null || true

# Also update the persistent conf so AWG restart keeps the correct MTU.
AWG_CONF="/etc/amnezia/amneziawg/${AWG_IF}.conf"
if [ -f "$AWG_CONF" ]; then
  sed -i "s/^MTU\s*=.*/MTU = ${CLIENT_MTU}/" "$AWG_CONF"
  echo "[OK] Updated MTU in $AWG_CONF"
fi
echo "[OK] $AWG_IF MTU set to $CLIENT_MTU (outer packet = ${OUTER_MTU}B)"

# ─── 5. Fix MSS clamping ─────────────────────────────────────────────────────
# Remove every old MSS rule (both --clamp-mss-to-pmtu and fixed --set-mss).
echo "[INFO] Rebuilding MSS clamp rules (MSS=$OPTIMAL_MSS)..."

# Remove clamp-mss-to-pmtu (too large – uses awg0 MTU=1420 on server side)
while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
  iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu
done

# Remove all directional fixed-MSS rules for common stale values
for OLD in 1200 1240 1380 1460; do
  while iptables -t mangle -C FORWARD \
        -i "$AWG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss $OLD 2>/dev/null; do
    iptables -t mangle -D FORWARD \
        -i "$AWG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss $OLD
  done
  while iptables -t mangle -C FORWARD \
        -i "$ETH_IF" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss $OLD 2>/dev/null; do
    iptables -t mangle -D FORWARD \
        -i "$ETH_IF" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss $OLD
  done
done

# Insert the single correct MSS for client MTU=1280
#   eth0→awg0: clamps MSS in SYN-ACKs coming back to clients
#   awg0→eth0: clamps MSS in SYNs leaving to internet servers
iptables -t mangle -I FORWARD 1 \
    -i "$ETH_IF" -o "$AWG_IF" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$OPTIMAL_MSS"
iptables -t mangle -I FORWARD 1 \
    -i "$AWG_IF" -o "$ETH_IF" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$OPTIMAL_MSS"
echo "[OK] MSS=$OPTIMAL_MSS"

# ─── 6. Persist iptables rules ───────────────────────────────────────────────
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save || true
fi

# ─── 7. Summary ──────────────────────────────────────────────────────────────
echo ""
echo "================================================================="
echo "[OK] Download boost applied. No VPN restart needed."
echo "     Disconnect + reconnect on each device, then run a speed test."
echo "================================================================="
echo ""
echo "Live verification:"
echo "  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc"
echo "  tc qdisc show dev $AWG_IF"
echo "  ip link show $AWG_IF | grep -o 'mtu [0-9]*'"
echo "  iptables -t mangle -L FORWARD -n | grep TCPMSS"
