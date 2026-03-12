'use strict';

/**
 * WireGuard service – manages peers on the server's wg0 interface.
 *
 * Key generation uses Node.js built-in crypto (Curve25519 / x25519) so that:
 *   • No `wg` binary is required for generating keys – works in CI/test without mocking.
 *   • Real WireGuard-compatible keys (32-byte Curve25519) are produced in all environments.
 *
 * Runtime peer-management commands (syncconf, set, show) still call the `wg`
 * CLI when it is present on the DigitalOcean droplet, but degrade gracefully
 * with a warning log when it is absent (dev / CI).
 *
 * Zero-log policy: peer public keys are stored to re-build the config;
 * no connection timestamps, source IPs or traffic volumes are persisted.
 */

const crypto = require('crypto');
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

// Track assigned IPs in memory (rebuilt from DB on startup via rebuildUsedIps)
const usedIps = new Set(['10.8.0.1']); // server itself

// ─── Key generation (pure Node.js – no `wg` binary required) ────────────────

/**
 * Generate a WireGuard-compatible Curve25519 key pair.
 * Returns { privateKey, publicKey } as standard base64 strings (44 chars each).
 *
 * Node.js exports x25519 keys in DER format with an ASN.1 header.
 * The actual 32-byte Curve25519 scalar/point is always the last 32 bytes of
 * the DER buffer, so `.slice(-32)` extracts the raw WireGuard-compatible key.
 */
function generateWgKeyPair() {
  const { privateKey: privObj, publicKey: pubObj } = crypto.generateKeyPairSync('x25519');
  // Extract the raw 32-byte scalars from the DER-encoded key objects
  const privateKey = privObj.export({ type: 'pkcs8', format: 'der' }).slice(-32).toString('base64');
  const publicKey  = pubObj.export({ type: 'spki',  format: 'der' }).slice(-32).toString('base64');
  return { privateKey, publicKey };
}

/**
 * Generate a WireGuard-compatible 32-byte preshared key (base64).
 */
function generatePsk() {
  return crypto.randomBytes(32).toString('base64');
}

/**
 * Rebuild the in-memory usedIps set from all active Device records.
 * Call once on application start so IP allocation is correct after restarts.
 */
exports.rebuildUsedIps = async () => {
  try {
    const Device = require('../models/Device');
    const devices = await Device.find({ isActive: true, assignedIp: { $exists: true, $ne: null } }, 'assignedIp');
    for (const d of devices) {
      if (d.assignedIp) {
        // assignedIp is stored as "10.8.0.2/32" — strip the CIDR
        usedIps.add(d.assignedIp.split('/')[0]);
      }
    }
    logger.info(`WireGuard IP pool rebuilt: ${usedIps.size} IPs in use`);
  } catch (err) {
    logger.warn(`Could not rebuild WireGuard IP pool: ${err.message}`);
  }
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Run a `wg` sub-command and return stdout.
 * Resolves to an empty string when the `wg` binary is not present (dev/CI).
 */
async function wg(...args) {
  try {
    const { stdout } = await execFileAsync('wg', args);
    return stdout.trim();
  } catch (err) {
    if (err.code === 'ENOENT') {
      logger.warn(`wg binary not found – skipping: wg ${args.join(' ')}`);
      return '';
    }
    throw err;
  }
}

/**
 * Reload wg0 configuration from disk without dropping connections.
 * Non-fatal: logs a warning if the `wg` binary or config is unavailable.
 */
async function syncConfig() {
  await execFileAsync('wg', ['syncconf', WG_INTERFACE, `${WG_CONFIG_DIR}/${WG_INTERFACE}.conf`]).catch((err) => {
    logger.warn(`Could not sync WireGuard config (non-fatal in dev/CI): ${err.message}`);
  });
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
  const { privateKey: clientPrivateKey, publicKey: clientPublicKey } = generateWgKeyPair();
  const presharedKey = generatePsk();
  const assignedIp = allocateIp();

  // Append peer block to server config
  const peerBlock = [
    `\n# User: ${userId}`,
    '[Peer]',
    `PublicKey = ${clientPublicKey}`,
    `PresharedKey = ${presharedKey}`,
    `AllowedIPs = ${assignedIp}`,
  ].join('\n');

  const configPath = path.join(WG_CONFIG_DIR, `${WG_INTERFACE}.conf`);
  await fs.appendFile(configPath, peerBlock + '\n').catch((err) => {
    logger.warn(`Could not write WireGuard config (non-fatal in dev/CI): ${err.message}`);
  });

  await syncConfig();

  // Build the client config file
  const configFile = [
    '[Interface]',
    `PrivateKey = ${clientPrivateKey}`,
    `Address = ${assignedIp}`,
    `DNS = ${WG_DNS}`,
    '',
    '[Peer]',
    `PublicKey = ${SERVER_PUBLIC_KEY}`,
    `PresharedKey = ${presharedKey}`,
    `Endpoint = ${SERVER_ENDPOINT}`,
    // Two complementary /1 blocks cover the entire IPv4 space and take
    // precedence over any default route, routing all IPv4 traffic through
    // the VPN without overriding the default route entry itself.
    'AllowedIPs = 0.0.0.0/1, 128.0.0.0/1',
    'PersistentKeepalive = 25',
  ].join('\n');

  return {
    clientPrivateKey,
    clientPublicKey,
    presharedKey,
    assignedIp,
    configFile,
  };
};

/**
 * Remove a peer from WireGuard by public key.
 * Non-fatal: logs a warning if the `wg` binary is not available.
 * @param {string} publicKey - the client's WireGuard public key
 * @param {string} [assignedIp] - the IP to release back to the pool (e.g. "10.8.0.2/32")
 */
exports.removePeer = async (publicKey, assignedIp) => {
  await execFileAsync('wg', ['set', WG_INTERFACE, 'peer', publicKey, 'remove']).catch((err) => {
    logger.warn(`Could not remove WireGuard peer (non-fatal in dev/CI): ${err.message}`);
  });
  if (assignedIp) {
    // Strip the CIDR suffix to release the bare IP back to the pool
    usedIps.delete(assignedIp.split('/')[0]);
  }
  logger.info(`WireGuard peer removed: ${publicKey}`);
};

/**
 * Return live peer stats from `wg show`.
 * Returns an empty array when the `wg` binary is not available (dev/CI).
 * No data is persisted – purely real-time.
 */
exports.getPeerStats = async () => {
  const output = await wg('show', WG_INTERFACE, 'dump');
  if (!output) return [];
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
};
