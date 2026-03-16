'use strict';

/**
 * AmneziaWG service – manages peers on the server's awg0 interface.
 *
 * AmneziaWG is a fork of WireGuard that adds per-packet junk-injection
 * obfuscation (Jc, Jmin, Jmax, S1-S4, H1-H4) to defeat Deep Packet
 * Inspection in China, Iran, and Russia. With all J/S parameters at zero
 * it is wire-compatible with vanilla WireGuard – zero overhead.
 *
 * Key generation uses Node.js built-in crypto (Curve25519 / x25519):
 *   • No binary required – works in CI/test without mocking.
 *   • 32-byte Curve25519 keys compatible with both awg and wg.
 *
 * Runtime peer commands call `awg` / `awg-quick`, falling back to `wg` / `wg-quick`
 * when the AmneziaWG binary is absent (dev / CI).
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

// AmneziaWG uses its own config directory and interface name.
const WG_CONFIG_DIR = process.env.AWG_CONFIG_DIR || process.env.WG_CONFIG_DIR || '/etc/amnezia/amneziawg';
const WG_INTERFACE = process.env.AWG_INTERFACE || process.env.WG_INTERFACE || 'awg0';
const WG_SUBNET_BASE = process.env.AWG_SUBNET || process.env.WG_SUBNET || '10.9.9.0/24';
const WG_DNS = process.env.AWG_DNS || process.env.WG_DNS || '1.1.1.1';
const WG_MTU = process.env.AWG_MTU || process.env.WG_MTU || '1280';
const SERVER_PUBLIC_KEY = process.env.AWG_SERVER_PUBLIC_KEY || process.env.WG_SERVER_PUBLIC_KEY || '';
const SERVER_ENDPOINT = process.env.AWG_SERVER_ENDPOINT || process.env.WG_SERVER_ENDPOINT || '';

// AmneziaWG obfuscation parameters (must match server awg0.conf exactly).
// All-zero = vanilla WireGuard performance with no DPI fingerprint.
// To unblock in actively-filtered networks: set S4=16 first, then Jc=1.
const AWG_PARAMS_DEFAULT = {
  Jc:   parseInt(process.env.AWG_JC   ?? '0', 10),
  Jmin: parseInt(process.env.AWG_JMIN ?? '0', 10),
  Jmax: parseInt(process.env.AWG_JMAX ?? '0', 10),
  S1:   parseInt(process.env.AWG_S1   ?? '0', 10),
  S2:   parseInt(process.env.AWG_S2   ?? '0', 10),
  H1:   parseInt(process.env.AWG_H1   ?? '1', 10),
  H2:   parseInt(process.env.AWG_H2   ?? '2', 10),
  H3:   parseInt(process.env.AWG_H3   ?? '3', 10),
  H4:   parseInt(process.env.AWG_H4   ?? '4', 10),
};

// Track assigned IPs in memory (rebuilt from DB on startup via rebuildUsedIps)
const usedIps = new Set(['10.9.9.1']); // server itself

// ─── Key generation (pure Node.js – no `wg` binary required) ────────────────

/**
 * Generate a 256-bit pre-shared key (PSK) as a base64 string.
 *
 * Purpose: adds a symmetric-key layer on top of the Curve25519 ECDH handshake.
 * If Curve25519 is ever broken (e.g. by a quantum computer), the PSK still
 * provides 256-bit symmetric security. This is the same technique used by
 * Mullvad and ProtonVPN for post-quantum resistance.
 *
 * The PSK is unique per peer and is included in both the server peer block
 * and the generated client config file.
 */
function generateWgPsk() {
  return crypto.randomBytes(32).toString('base64');
}
exports.generateWgPsk = generateWgPsk;

/**
 * Generate a WireGuard key pair.
 *
 * In production, prefer native `wg` key generation to guarantee full
 * interoperability with kernel/user-space WireGuard implementations.
 * In CI/dev where `wg` might not exist, fall back to Node x25519.
 */
async function generateWgKeyPair() {
  try {
    const { stdout: privOut } = await execFileAsync('wg', ['genkey']);
    const privateKey = (privOut || '').trim();
    if (!privateKey) throw new Error('wg genkey returned empty output');

    const tmpPrivPath = path.join('/tmp', `wg.priv.${process.pid}.${Date.now()}`);
    try {
      await fs.writeFile(tmpPrivPath, `${privateKey}\n`, { mode: 0o600 });
      const { stdout: pubOut } = await execFileAsync('sh', ['-lc', `cat ${tmpPrivPath} | wg pubkey`]);
      const publicKey = (pubOut || '').trim();
      if (!publicKey) throw new Error('wg pubkey returned empty output');
      return { privateKey, publicKey };
    } finally {
      await fs.unlink(tmpPrivPath).catch(() => {});
    }
  } catch (err) {
    if (err.code !== 'ENOENT') {
      logger.warn(`Native wg key generation failed, falling back to Node x25519: ${err.message}`);
    }
  }

  const { privateKey: privObj, publicKey: pubObj } = crypto.generateKeyPairSync('x25519');
  const privateKey = privObj.export({ type: 'pkcs8', format: 'der' }).slice(-32).toString('base64');
  const publicKey = pubObj.export({ type: 'spki', format: 'der' }).slice(-32).toString('base64');
  return { privateKey, publicKey };
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
    logger.info(`AmneziaWG IP pool rebuilt: ${usedIps.size} IPs in use`);
  } catch (err) {
    logger.warn(`Could not rebuild WireGuard IP pool: ${err.message}`);
  }
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Run an `awg` (or `wg` fallback) sub-command and return stdout.
 * AmneziaWG ships the `awg` binary which is a drop-in superset of `wg`.
 * Resolves to an empty string when neither binary is present (dev/CI).
 */
async function awgExec(...args) {
  for (const bin of ['awg', 'wg']) {
    try {
      const { stdout } = await execFileAsync(bin, args);
      return stdout.trim();
    } catch (err) {
      if (err.code === 'ENOENT') continue; // try next binary
      throw err;
    }
  }
  logger.warn(`Neither awg nor wg binary found – skipping: ${args.join(' ')}`);
  return '';
}
// Keep `wg` alias so any internal callers still work.
const wg = awgExec;

/**
 * Reload awg0 configuration from disk without dropping connections.
 *
 * `awg syncconf` / `wg syncconf` accept only stripped WireGuard keys.
 * We must strip the wg-quick directives (Address/MTU/PostUp/PostDown/AWG params)
 * first via `awg-quick strip` (or `wg-quick strip` as fallback).
 */
async function syncConfig() {
  const configPath = `${WG_CONFIG_DIR}/${WG_INTERFACE}.conf`;
  const tmpPath = path.join('/tmp', `${WG_INTERFACE}.sync.${process.pid}.${Date.now()}.conf`);

  try {
    // Try awg-quick first (AmneziaWG), fall back to wg-quick (vanilla WireGuard).
    let stripped;
    for (const bin of ['awg-quick', 'wg-quick']) {
      try {
        const { stdout } = await execFileAsync(bin, ['strip', configPath]);
        stripped = stdout;
        break;
      } catch (e) {
        if (e.code !== 'ENOENT') throw e;
      }
    }
    if (stripped === undefined) {
      logger.warn('awg-quick / wg-quick not found – skipping syncconf (dev/CI)');
      return;
    }
    await fs.writeFile(tmpPath, stripped, { mode: 0o600 });
    // awg syncconf is a superset of wg syncconf; fall back to wg.
    for (const bin of ['awg', 'wg']) {
      try {
        await execFileAsync(bin, ['syncconf', WG_INTERFACE, tmpPath]);
        return;
      } catch (e) {
        if (e.code !== 'ENOENT') throw e;
      }
    }
    logger.warn('awg / wg syncconf binary not found – skipping (dev/CI)');
  } catch (err) {
    const details = err.stderr ? `${err.message}\n${err.stderr}` : err.message;
    throw new Error(`Could not sync AmneziaWG config: ${details}`);
  } finally {
    await fs.unlink(tmpPath).catch(() => {});
  }
}

/**
 * Remove a peer block by public key from the persistent awg0.conf file.
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

async function getLiveWireGuardPort() {
  const confPath = path.join(WG_CONFIG_DIR, `${WG_INTERFACE}.conf`);
  try {
    const conf = await fs.readFile(confPath, 'utf8');
    const match = conf.match(/^\s*ListenPort\s*=\s*(\d+)\s*$/im);
    if (match && match[1]) return match[1].trim();
  } catch (_) {
    // Ignore and fall back to env.
  }
  return '';
}

function parseAwgNumber(conf, key) {
  const regex = new RegExp(`^\\s*${key}\\s*=\\s*(-?\\d+)\\s*$`, 'im');
  const match = conf.match(regex);
  if (!match || !match[1]) return null;
  const num = Number.parseInt(match[1], 10);
  return Number.isNaN(num) ? null : num;
}

/**
 * Return AWG obfuscation params used in generated client configs.
 * Prefer live /etc/amnezia/amneziawg/awg0.conf values so client and server
 * always match after runtime profile changes.
 */
async function getLiveAwgParams() {
  const confPath = path.join(WG_CONFIG_DIR, `${WG_INTERFACE}.conf`);
  const keys = ['Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'H1', 'H2', 'H3', 'H4'];

  try {
    const conf = await fs.readFile(confPath, 'utf8');
    const live = { ...AWG_PARAMS_DEFAULT };
    for (const key of keys) {
      const parsed = parseAwgNumber(conf, key);
      if (parsed !== null) live[key] = parsed;
    }
    return live;
  } catch (_) {
    return { ...AWG_PARAMS_DEFAULT };
  }
}

/**
 * Return server endpoint for generated client configs.
 * Prefer explicit WG_SERVER_ENDPOINT; otherwise derive from SERVER_IP.
 */
async function getServerEndpoint() {
  const explicit = (SERVER_ENDPOINT || '').trim();
  const livePort = await getLiveWireGuardPort();
  if (explicit) {
    if (!livePort) return explicit;
    const host = explicit.split(':')[0];
    if (!host) return explicit;
    return `${host}:${livePort}`;
  }

  const serverIp = (process.env.SERVER_IP || '').trim();
  if (!serverIp) return '';

  const port = (livePort || process.env.WG_PORT || '51820').trim();
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
  const serverEndpoint = await getServerEndpoint();
  const awgParams = await getLiveAwgParams();

  if (!serverPublicKey) {
    throw new Error('AmneziaWG server public key is missing. Set AWG_SERVER_PUBLIC_KEY in .env or ensure /etc/amnezia/amneziawg/publickey exists.');
  }
  if (!serverEndpoint) {
    throw new Error('AmneziaWG server endpoint is missing. Set AWG_SERVER_ENDPOINT or SERVER_IP in .env.');
  }

  const { privateKey: clientPrivateKey, publicKey: clientPublicKey } = await generateWgKeyPair();
  const presharedKey = generateWgPsk();
  const assignedIp = allocateIp();

  // Append peer block to server config.
  // PresharedKey adds a post-quantum symmetric-encryption layer (RFC 8918).
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

  // Prefer syncconf so runtime and disk config stay identical.
  // If syncconf fails, fall back to adding the peer directly in the live
  // interface via `awg set` (or `wg set`) so /vpn/config still succeeds.
  let applied = false;
  try {
    await syncConfig();
    applied = true;
  } catch (err) {
    logger.warn(`syncconf failed while adding peer; trying runtime awg set fallback: ${err.message}`);
    for (const bin of ['awg', 'wg']) {
      try {
        await execFileAsync(bin, [
          'set', WG_INTERFACE,
          'peer', clientPublicKey,
          'allowed-ips', assignedIp,
        ]);
        applied = true;
        break;
      } catch (e) {
        if (e.code !== 'ENOENT') {
          logger.error(`Runtime ${bin} set fallback failed: ${e.message}`);
        }
      }
    }
  }

  if (!applied) {
    throw new Error('Could not apply new AmneziaWG peer (syncconf and runtime fallback both failed).');
  }

  // Build the AmneziaWG client config.
  // AWG obfuscation params (Jc, S1, S2, H1-H4) MUST match the server's
  // awg0.conf exactly or the handshake will be silently rejected.
  const configFile = [
    '[Interface]',
    `PrivateKey = ${clientPrivateKey}`,
    `Address = ${assignedIp}`,
    `DNS = ${WG_DNS}`,
    // Default MTU 1280 to avoid PMTU fragmentation on mobile/4G paths.
    `MTU = ${WG_MTU}`,
    // ─ AmneziaWG obfuscation parameters ───────────────────────────────────
    // All zero = vanilla WireGuard speed; no junk overhead.
    // Must be identical to server /etc/amnezia/amneziawg/awg0.conf.
    `Jc = ${awgParams.Jc}`,
    `Jmin = ${awgParams.Jmin}`,
    `Jmax = ${awgParams.Jmax}`,
    `S1 = ${awgParams.S1}`,
    `S2 = ${awgParams.S2}`,
    `H1 = ${awgParams.H1}`,
    `H2 = ${awgParams.H2}`,
    `H3 = ${awgParams.H3}`,
    `H4 = ${awgParams.H4}`,
    '',
    '[Peer]',
    `PublicKey = ${serverPublicKey}`,
    // PSK: post-quantum symmetric layer on top of Curve25519 ECDH (RFC 8918).
    `PresharedKey = ${presharedKey}`,
    `Endpoint = ${serverEndpoint}`,
    // IPv4-only full tunnel (GFW recommendation: disable IPv6 on server
    // to prevent the Great Firewall from using IPv6 to de-anonymise users).
    'AllowedIPs = 0.0.0.0/0',
    // Keepalive every 25 s maintains NAT mappings for weeks without disconnect.
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
  // Try awg first, fall back to wg
  for (const bin of ['awg', 'wg']) {
    try {
      await execFileAsync(bin, ['set', WG_INTERFACE, 'peer', publicKey, 'remove']);
      break;
    } catch (err) {
      if (err.code === 'ENOENT') continue;
      logger.warn(`Could not remove AmneziaWG peer (non-fatal in dev/CI): ${err.message}`);
      break;
    }
  }
  await removePeerFromConfig(publicKey).catch((err) => {
    logger.warn(`Could not remove peer from AWG config file: ${err.message}`);
  });
  await syncConfig().catch((err) => {
    logger.warn(`Could not sync AWG config after peer removal: ${err.message}`);
  });
  if (assignedIp) {
    usedIps.delete(assignedIp.split('/')[0]);
  }
  logger.info(`AmneziaWG peer removed: ${publicKey}`);
};

/**
 * Return live peer stats from `awg show` (falls back to `wg show`).
 * Returns an empty array when neither binary is available (dev/CI).
 * No data is persisted – purely real-time.
 */
exports.getPeerStats = async () => {
  const output = await awgExec('show', WG_INTERFACE, 'dump');
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
