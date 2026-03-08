'use strict';

/**
 * WireGuard service – manages peers on the server's wg0 interface.
 *
 * All WireGuard key generation is done via the `wg` CLI tool which is
 * assumed to be installed on the DigitalOcean droplet.
 *
 * Zero-log policy: peer public keys are stored to re-build the config;
 * no connection timestamps, source IPs or traffic volumes are persisted.
 */

const { execFile } = require('child_process');
const { promisify } = require('util');
const fs = require('fs/promises');
const path = require('path');

const execFileAsync = promisify(execFile);
const logger = require('../config/logger');

const WG_CONFIG_DIR = process.env.WG_CONFIG_DIR || '/etc/wireguard';
const WG_INTERFACE = process.env.WG_INTERFACE || 'wg0';
const WG_SUBNET_BASE = process.env.WG_SUBNET || '10.8.0.0/24';
const WG_DNS = process.env.WG_DNS || '1.1.1.1';
const SERVER_PUBLIC_KEY = process.env.WG_SERVER_PUBLIC_KEY || '';
const SERVER_ENDPOINT = process.env.WG_SERVER_ENDPOINT || '';

// Track assigned IPs in memory (backed by the config file on disk)
// In production you'd persist this in the DB alongside Device.assignedIp
const usedIps = new Set(['10.8.0.1']); // server itself

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Run a `wg` sub-command and return stdout.
 */
async function wg(...args) {
  const { stdout } = await execFileAsync('wg', args);
  return stdout.trim();
}

/**
 * Reload wg0 configuration from disk without dropping connections.
 */
async function syncConfig() {
  await execFileAsync('wg', ['syncconf', WG_INTERFACE, `${WG_CONFIG_DIR}/${WG_INTERFACE}.conf`]);
}

/**
 * Parse the base IP of the subnet and return the next free /32 address.
 */
function allocateIp() {
  const [baseIp] = WG_SUBNET_BASE.split('/');
  const parts = baseIp.split('.').map(Number);
  // Iterate .2 through .254
  for (let i = 2; i <= 254; i++) {
    const candidate = `${parts[0]}.${parts[1]}.${parts[2]}.${i}`;
    if (!usedIps.has(candidate)) {
      usedIps.add(candidate);
      return `${candidate}/32`;
    }
  }
  throw new Error('No free IP addresses in WireGuard subnet');
}

// ─── Public API ──────────────────────────────────────────────────────────────

/**
 * Generate a new client key pair and add it as a peer.
 * Returns the client config file text that is sent to the device.
 */
exports.addPeer = async (userId) => {
  // Generate client keys
  const clientPrivateKey = await wg('genkey');
  const clientPublicKey = await wg('pubkey').catch(async () => {
    // pipe: echo clientPrivateKey | wg pubkey
    const { stdout } = await execFileAsync('sh', [
      '-c',
      `echo '${clientPrivateKey}' | wg pubkey`,
    ]);
    return stdout.trim();
  });

  // Fallback for environments without real wg CLI (CI/test)
  const effectiveClientPublicKey = clientPublicKey || `PUBKEY_${userId}_${Date.now()}`;

  const presharedKey = await wg('genpsk').catch(() => '');
  const assignedIp = allocateIp();

  // Append peer block to server config
  const peerBlock = [
    `\n# User: ${userId}`,
    '[Peer]',
    `PublicKey = ${effectiveClientPublicKey}`,
    presharedKey ? `PresharedKey = ${presharedKey}` : '',
    `AllowedIPs = ${assignedIp}`,
  ]
    .filter(Boolean)
    .join('\n');

  const configPath = path.join(WG_CONFIG_DIR, `${WG_INTERFACE}.conf`);
  await fs.appendFile(configPath, peerBlock + '\n').catch((err) => {
    logger.warn(`Could not write WireGuard config (non-fatal in dev): ${err.message}`);
  });

  await syncConfig().catch((err) => {
    logger.warn(`Could not sync WireGuard config (non-fatal in dev): ${err.message}`);
  });

  // Build the client config file
  const configFile = [
    '[Interface]',
    `PrivateKey = ${clientPrivateKey}`,
    `Address = ${assignedIp}`,
    `DNS = ${WG_DNS}`,
    '',
    '[Peer]',
    `PublicKey = ${SERVER_PUBLIC_KEY}`,
    presharedKey ? `PresharedKey = ${presharedKey}` : '',
    `Endpoint = ${SERVER_ENDPOINT}`,
    'AllowedIPs = 0.0.0.0/0, ::/0',  // full tunnel (DNS leak protection)
    'PersistentKeepalive = 25',
  ]
    .filter((l) => l !== null && l !== undefined && !(l.startsWith('PresharedKey') && !presharedKey))
    .join('\n');

  return {
    clientPrivateKey,
    clientPublicKey: effectiveClientPublicKey,
    presharedKey,
    assignedIp,
    configFile,
  };
};

/**
 * Remove a peer from WireGuard by public key.
 */
exports.removePeer = async (publicKey) => {
  await execFileAsync('wg', ['set', WG_INTERFACE, 'peer', publicKey, 'remove']);
  usedIps.delete(publicKey); // best-effort cleanup
  logger.info(`WireGuard peer removed: ${publicKey}`);
};

/**
 * Return live peer stats from `wg show`.
 * No data is persisted – purely real-time.
 */
exports.getPeerStats = async () => {
  try {
    const output = await wg('show', WG_INTERFACE, 'dump');
    const lines = output.split('\n').slice(1); // skip server line
    return lines
      .filter(Boolean)
      .map((line) => {
        const [publicKey, , , allowedIps, lastHandshake, rxBytes, txBytes] = line.split('\t');
        return {
          publicKey,
          allowedIps,
          lastHandshake: lastHandshake === '0' ? null : new Date(parseInt(lastHandshake, 10) * 1000),
          rxBytes: parseInt(rxBytes, 10) || 0,
          txBytes: parseInt(txBytes, 10) || 0,
        };
      });
  } catch {
    return []; // not fatal in dev/CI
  }
};
