'use strict';

const { validationResult } = require('express-validator');
const Device = require('../models/Device');
const wireguardService = require('../services/wireguardService');
const openvpnService = require('../services/openvpnService');
const logger = require('../config/logger');

const MAX_DEVICES_FREE = 1;
const MAX_DEVICES_PREMIUM = 10;

// ─── Generate VPN config for a new device ────────────────────────────────────
exports.generateConfig = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(422).json({ errors: errors.array() });
    }

    const { name, platform, protocol = 'wireguard' } = req.body;
    const userId = req.user.id;
    const user = req.user.doc;

    // Enforce device limit
    const maxDevices = user.subscription?.unlimitedBandwidth
      ? MAX_DEVICES_PREMIUM
      : MAX_DEVICES_FREE;
    const activeDevices = await Device.countDocuments({ userId, isActive: true });
    if (activeDevices >= maxDevices) {
      return res.status(403).json({
        message: `Device limit reached (${maxDevices}). Upgrade to premium for up to ${MAX_DEVICES_PREMIUM} devices.`,
      });
    }

    let config;
    let deviceData = { userId, name, platform, protocol };

    if (protocol === 'wireguard') {
      const { clientPrivateKey, clientPublicKey, presharedKey, assignedIp, configFile } =
        await wireguardService.addPeer(userId);
      config = configFile;
      deviceData = { ...deviceData, wgPublicKey: clientPublicKey, wgPresharedKey: presharedKey, assignedIp };
    } else if (protocol === 'openvpn') {
      config = await openvpnService.generateClientConfig(userId, name);
    } else {
      return res.status(400).json({ message: `Unsupported protocol: ${protocol}` });
    }

    const device = await Device.create(deviceData);
    logger.info(`VPN config generated for user ${userId}, device ${device.deviceId}, protocol ${protocol}`);

    res.status(201).json({
      deviceId: device.deviceId,
      protocol,
      config, // raw config file content – client saves to disk
    });
  } catch (err) {
    next(err);
  }
};

// ─── Get connection status ────────────────────────────────────────────────────
exports.getStatus = async (req, res, next) => {
  try {
    const stats = await wireguardService.getPeerStats();
    const activeDevices = await Device.countDocuments({ userId: req.user.id, isActive: true });
    res.json({ activeDevices, peerStats: stats });
  } catch (err) {
    next(err);
  }
};

// ─── Record a connect event (called by client) ───────────────────────────────
exports.connect = async (req, res, next) => {
  try {
    const { deviceId } = req.body;
    const device = await Device.findOne({ deviceId, userId: req.user.id });
    if (!device) return res.status(404).json({ message: 'Device not found' });

    device.lastConnectedAt = new Date();
    await device.save();

    // Zero-log policy: we only update lastConnectedAt for device health, no IP recorded
    res.json({ message: 'Connected', serverEndpoint: process.env.WG_SERVER_ENDPOINT });
  } catch (err) {
    next(err);
  }
};

// ─── Record a disconnect event ────────────────────────────────────────────────
exports.disconnect = async (req, res, next) => {
  try {
    const { deviceId } = req.body;
    const device = await Device.findOne({ deviceId, userId: req.user.id });
    if (!device) return res.status(404).json({ message: 'Device not found' });

    // No session data is stored – zero-log policy
    res.json({ message: 'Disconnected' });
  } catch (err) {
    next(err);
  }
};

// ─── Speed test helper (returns server info for client-side test) ─────────────
exports.speedTest = async (req, res, next) => {
  try {
    res.json({
      testEndpoint: `http://${process.env.SERVER_IP}/speedtest`,
      serverRegion: process.env.SERVER_REGION || 'Singapore',
    });
  } catch (err) {
    next(err);
  }
};
