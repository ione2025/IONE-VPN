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
 *
 * Important: `wg syncconf` accepts only pure WireGuard keys. Our server file
 * is a `wg-quick` config (contains Address/DNS/PostUp/PostDown), so we must
 * strip it first via `wg-quick strip` and then sync the stripped file.
 */
async function syncConfig() {
  const configPath = `${WG_CONFIG_DIR}/${WG_INTERFACE}.conf`;
  const tmpPath = path.join('/tmp', `${WG_INTERFACE}.sync.${process.pid}.${Date.now()}.conf`);

  try {
    const { stdout } = await execFileAsync('wg-quick', ['strip', configPath]);
    await fs.writeFile(tmpPath, stdout, { mode: 0o600 });
    await execFileAsync('wg', ['syncconf', WG_INTERFACE, tmpPath]);
  } catch (err) {
    if (err.code === 'ENOENT') {
      logger.warn('wg/wg-quick binary not found - skipping syncconf (dev/CI)');
      return;
    }
    const details = err.stderr ? `${err.message}\n${err.stderr}` : err.message;
    throw new Error(`Could not sync WireGuard config: ${details}`);
  } finally {
    await fs.unlink(tmpPath).catch(() => {});
  }
}

/**
 * Remove a peer block by public key from the persistent wg0.conf file.
 * This keeps disk config in sync with runtime state so old peers do not
 * come back on restart/sync.
 */
async function removePeerFromConfig(publicKey) {
  const configPath = path.join(WG_CONFIG_DIR, `${WG_INTERFACE}.conf`);
  let content;
  try {
    content = await fs.readFile(configPath, 'utf8');
  } catch (err) {
    logger.warn(`Could not read WireGuard config for peer removal: ${err.message}`);
    return;
  }

  const peerBlockRegex = /(?:^|\n)(?:# User:.*\n)?\[Peer\][\s\S]*?(?=\n(?:# User:.*\n)?\[Peer\]|\s*$)/g;
  const peerBlocks = content.match(peerBlockRegex) || [];
  if (peerBlocks.length === 0) return;

  const keptBlocks = peerBlocks.filter((block) => {
    const lines = block.split('\n');
    const pubLine = lines.find((line) => line.trim().toLowerCase().startsWith('publickey'));
    if (!pubLine) return true;
    const candidate = pubLine.split('=').slice(1).join('=').trim();
    return candidate !== publicKey;
  });

  if (keptBlocks.length === peerBlocks.length) return;

  const baseConfig = content.replace(peerBlockRegex, '').trimEnd();
  const rebuilt = [baseConfig, ...keptBlocks.map((b) => b.trim())]
    .filter((s) => s && s.length > 0)
    .join('\n\n') + '\n';

  await fs.writeFile(configPath, rebuilt, { mode: 0o600 });
}

/**
 * Return the server public key used in generated client configs.
 * Prefer the live key file on the server when available to avoid stale .env
 * values after key rotation.
 */
async function getServerPublicKey() {
  const keyPath = path.join(WG_CONFIG_DIR, 'publickey');
  try {
    const key = (await fs.readFile(keyPath, 'utf8')).trim();
    if (key) return key;
  } catch (_) {
    // Fall back to env below.
  }
  return (SERVER_PUBLIC_KEY || '').trim();
}

/**
 * Return server endpoint for generated client configs.
 * Prefer explicit WG_SERVER_ENDPOINT; otherwise derive from SERVER_IP.
 */
function getServerEndpoint() {
  const explicit = (SERVER_ENDPOINT || '').trim();
  if (explicit) return explicit;

  const serverIp = (process.env.SERVER_IP || '').trim();
  if (!serverIp) return '';

  const port = (process.env.WG_PORT || '51820').trim();
  return `${serverIp}:${port}`;
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
  const serverPublicKey = await getServerPublicKey();
  const serverEndpoint = getServerEndpoint();

  if (!serverPublicKey) {
    throw new Error('WireGuard server public key is missing. Set WG_SERVER_PUBLIC_KEY or /etc/wireguard/publickey.');
  }
  if (!serverEndpoint) {
    throw new Error('WireGuard server endpoint is missing. Set WG_SERVER_ENDPOINT or SERVER_IP.');
  }

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
    `PublicKey = ${serverPublicKey}`,
    `PresharedKey = ${presharedKey}`,
    `Endpoint = ${serverEndpoint}`,
    // Route all IPv4 traffic through the VPN.
    'AllowedIPs = 0.0.0.0/0',
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
  await removePeerFromConfig(publicKey).catch((err) => {
    logger.warn(`Could not remove peer from WireGuard config file: ${err.message}`);
  });
  await syncConfig().catch((err) => {
    logger.warn(`Could not sync WireGuard config after peer removal: ${err.message}`);
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
