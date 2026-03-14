'use strict';

/**
 * Server monitor – tracks health and load metrics for all VPN servers.
 * Currently manages the single Singapore droplet; additional servers can
 * be added to the SERVERS array and the monitor will poll them all.
 */

const { execFile } = require('child_process');
const { promisify } = require('util');
const logger = require('../config/logger');

const execFileAsync = promisify(execFile);

// ─── Server registry ──────────────────────────────────────────────────────────
// Add more regions here as you expand.
const SERVERS = [
  {
    id: 'sg-01',
    name: 'Singapore 01',
    region: 'Singapore',
    country: 'SG',
    flag: '🇸🇬',
    ip: process.env.SERVER_IP || '127.0.0.1',
    wgPort: parseInt(process.env.WG_PORT || '51820', 10),
    ovpnPort: 1194,
    isOnline: true,
    load: 0,
    ping: 0,
    isPremiumOnly: false,
  },
];

// In-memory cache (refresh every 30 s)
let cachedStats = null;
let lastRefreshed = 0;
const CACHE_TTL_MS = 30_000;

// ─── Metric collection ────────────────────────────────────────────────────────

async function measurePing(ip) {
  try {
    const { stdout } = await execFileAsync('ping', ['-c', '3', '-W', '2', ip]);
    const match = stdout.match(/avg\s*=\s*[\d.]+\/([\d.]+)/);
    return match ? parseFloat(match[1]) : 999;
  } catch {
    return 999;
  }
}

async function measureLoad() {
  try {
    const { stdout } = await execFileAsync('sh', ['-c', "cat /proc/loadavg | awk '{print $1}'"], {
      timeout: 2000,
    });
    const load1m = parseFloat(stdout.trim());
    // Convert to a 0-100 percentage (assuming max meaningful load = nCPUs * 2)
    const cpuCount = require('os').cpus().length;
    return Math.min(100, Math.round((load1m / (cpuCount * 2)) * 100));
  } catch {
    return 0;
  }
}

// ─── Public API ───────────────────────────────────────────────────────────────

exports.getServers = () => SERVERS;

exports.getDetailedStats = async () => {
  const now = Date.now();
  if (cachedStats && now - lastRefreshed < CACHE_TTL_MS) return cachedStats;

  const stats = await Promise.all(
    SERVERS.map(async (s) => {
      const [ping, load] = await Promise.all([measurePing(s.ip), measureLoad()]);
      return {
        ...s,
        ping,
        load,
        isOnline: ping < 999,
      };
    }),
  );

  cachedStats = stats;
  lastRefreshed = now;
  return stats;
};

// ─── Background refresh ──────────────────────────────────────────────────────
if (process.env.NODE_ENV !== 'test') {
  setInterval(() => {
    exports.getDetailedStats().catch((err) =>
      logger.warn('Server monitor refresh failed:', err.message),
    );
  }, CACHE_TTL_MS);
}
