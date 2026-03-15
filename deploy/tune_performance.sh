#!/usr/bin/env bash
# =============================================================================
# IONE VPN – Live-server performance tuning
# Run as root on the droplet to maximise VPN throughput and minimise latency.
# Safe to run while AmneziaWG is running – no downtime required.
#
#   bash deploy/tune_performance.sh
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[TUNE]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

AWG_IF="awg0"
ETH_IF=$(ip route | awk '/default/ {print $5; exit}')
info "Egress interface: $ETH_IF"

# ── 1. Kernel parameters ──────────────────────────────────────────────────────
info "Applying kernel tuning..."

# Write persistent config (survives reboot)
cat >/etc/sysctl.d/99-ione-awg.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# ── BBR congestion control ────────────────────────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── Socket buffers (128 MB) ───────────────────────────────────────────────────
# A gigabit link with 100 ms RTT needs 100 Mbit / 8 = 12.5 MB in-flight buffer.
# 128 MB gives headroom for multiple concurrent streams and burst traffic.
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ── Throughput & latency ──────────────────────────────────────────────────────
# Prevents TCP halving congestion window after an idle pause – critical for VPN.
net.ipv4.tcp_slow_start_after_idle = 0
# Probe for correct MTU when ICMP unreachables are blocked by intermediate routers.
net.ipv4.tcp_mtu_probing = 1
# TCP Fast Open: saves 1 RTT on repeat connections (client + server side).
net.ipv4.tcp_fastopen = 3
# Cap unsent-data buffer so BBR doesn't over-queue and spike latency.
net.ipv4.tcp_notsent_lowat = 16384
# Low-latency UDP poll: cuts IRQ-to-app delay for WireGuard packet processing.
net.core.busy_poll = 50
net.core.busy_read = 50

# ── Connection handling ───────────────────────────────────────────────────────
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# ── Connection tracking ───────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = 1048576

# ── Security ──────────────────────────────────────────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
SYSCTL

# Load BBR module then apply all settings
modprobe tcp_bbr 2>/dev/null || true
sysctl --system >/dev/null
info "sysctl applied"

# ── 2. MSS clamping (THE fix for slow TCP over VPN) ──────────────────────────
# When a client opens a TCP connection through the VPN, the two endpoints
# negotiate a Maximum Segment Size (MSS) based on their local MTU (typically
# 1460 for Ethernet 1500). Those segments are then encapsulated inside WireGuard
# packets. If the resulting outer packet exceeds the tunnel MTU (1420) and the
# DF bit is set, the packet is silently dropped and the connection stalls or
# appears to work at 1–5% of actual link speed.
#
# MSS clamping intercepts TCP SYN/SYN-ACK and rewrites the MSS so it fits
# inside the tunnel. Packets: tunnel MTU 1420 − WG overhead 80 = MSS 1340.
# The kernel calculates this automatically with --clamp-mss-to-pmtu.
info "Applying MSS clamping..."
# Remove stale rule if it already exists (idempotent)
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu
info "MSS clamping active"

# ── 3. WireGuard interface tuning ─────────────────────────────────────────────
if ip link show "$AWG_IF" &>/dev/null; then
  # Increase TX queue so the WireGuard thread can batch more packets per cycle.
  ip link set dev "$AWG_IF" txqueuelen 1000

  # Replace default pfifo_fast with FQ (Fair Queuing) on the tunnel interface.
  # FQ paces packet bursts so BBR works effectively and latency stays low even
  # when the tunnel is saturated.
  tc qdisc replace dev "$AWG_IF" root fq 2>/dev/null || \
    tc qdisc add    dev "$AWG_IF" root fq 2>/dev/null || true

  info "awg0: txqueuelen=1000, qdisc=fq"
else
  warn "$AWG_IF is not up – skipping interface tuning. Run after AWG starts."
fi

# ── 4. Physical NIC offloading ────────────────────────────────────────────────
# GRO/GSO/TSO let the NIC driver combine or split packets in hardware/driver,
# reducing the number of system calls and CPU cycles per byte transferred.
if command -v ethtool &>/dev/null; then
  ethtool -K "$ETH_IF" gro on gso on tso on 2>/dev/null || true
  info "ethtool: GRO/GSO/TSO enabled on $ETH_IF"
else
  warn "ethtool not found – install with: apt-get install -y ethtool"
fi

# ── 5. CPU performance governor ───────────────────────────────────────────────
# On bare-metal or Dedicated CPU droplets, switching from powersave→performance
# eliminates CPU frequency ramp-up latency (10–50 ms) between packets.
if ls /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor &>/dev/null 2>&1; then
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$gov"
  done
  info "CPU governor: performance"
else
  info "cpufreq not available (shared VM – already running at fixed frequency)"
fi

# ── 6. ARP & neighbour cache ──────────────────────────────────────────────────
# Prevents neighbour-table overflow under high connection count.
sysctl -w net.ipv4.neigh.default.gc_thresh1=4096 >/dev/null
sysctl -w net.ipv4.neigh.default.gc_thresh2=8192 >/dev/null
sysctl -w net.ipv4.neigh.default.gc_thresh3=16384 >/dev/null

# ── 7. Persist iptables rules across reboots ─────────────────────────────────
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save
elif command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "====================================================================="
info " Performance tuning complete."
info ""
info " Key change: MSS clamping applied – this is the #1 fix for slow TCP"
info " over WireGuard.  Large packets are now resized to fit the tunnel"
info " instead of being silently dropped."
info ""
info " Verify MSS rule:  iptables -t mangle -L FORWARD -v -n"
info " Verify qdisc:     tc qdisc show dev awg0"
info " Monitor traffic:  watch -n1 'awg show awg0'"
info "====================================================================="
