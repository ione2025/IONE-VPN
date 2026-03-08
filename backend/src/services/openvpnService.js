'use strict';

/**
 * OpenVPN service – generates client configuration files.
 *
 * Assumes the server's CA certificate and TLS key are pre-generated and
 * placed in the paths specified by environment variables.
 */

const fs = require('fs/promises');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);
const logger = require('../config/logger');

const CONFIG_DIR = process.env.OPENVPN_CONFIG_DIR || '/etc/openvpn/server';
const CA_CERT_PATH = process.env.OPENVPN_CA_CERT || '/etc/openvpn/server/ca.crt';
const SERVER_IP = process.env.SERVER_IP || '127.0.0.1';
const SERVER_PORT = process.env.OPENVPN_PORT || '1194';

/**
 * Generate a client .ovpn config file.
 * The client key pair is generated via Easy-RSA on the server.
 */
exports.generateClientConfig = async (userId, deviceName) => {
  // Sanitise name for filesystem use
  const safeName = `${userId}-${deviceName}`.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64);

  let caCert = '# CA certificate not available in dev mode';
  try {
    caCert = await fs.readFile(CA_CERT_PATH, 'utf8');
  } catch {
    logger.warn('OpenVPN CA cert not found – generating stub config for dev');
  }

  // In production: call easy-rsa to generate client cert/key
  // For now we produce the inline config skeleton that the admin will
  // complete once Easy-RSA is run on the droplet.
  const config = [
    'client',
    'dev tun',
    'proto udp',
    `remote ${SERVER_IP} ${SERVER_PORT}`,
    'resolv-retry infinite',
    'nobind',
    'persist-key',
    'persist-tun',
    'remote-cert-tls server',
    'cipher AES-256-GCM',
    'auth SHA256',
    'verb 3',
    'key-direction 1',
    '',
    '# DNS leak protection',
    'block-outside-dns',
    `dhcp-option DNS 1.1.1.1`,
    `dhcp-option DNS 1.0.0.1`,
    '',
    '<ca>',
    caCert.trim(),
    '</ca>',
    '',
    '# <cert> and <key> must be filled in per-device by the server admin or Easy-RSA automation.',
    `# Client name: ${safeName}`,
  ].join('\n');

  logger.info(`OpenVPN config generated for user ${userId}, device: ${deviceName}`);
  return config;
};
