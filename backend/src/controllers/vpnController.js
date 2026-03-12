'use strict';

const { validationResult } = require('express-validator');
const Device = require('../models/Device');
const wireguardService = require('../services/wireguardService');
const openvpnService = require('../services/openvpnService');
const logger = require('../config/logger');

const MAX_DEVICES_FREE = 5;
const MAX_DEVICES_PREMIUM = 20;

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

    // Find best existing device to reuse:
    // 1. Exact match (same name + platform + protocol)
    // 2. Same platform + protocol
    // 3. Any active device for this user (cross-platform replacement)
    let existingDevice = await Device.findOne({
      userId,
      name,
      platform,
      protocol,
      isActive: true,
    }).sort({ updatedAt: -1 });

    if (!existingDevice) {
      existingDevice = await Device.findOne({
        userId,
        platform,
        protocol,
        isActive: true,
      }).sort({ updatedAt: -1 });
    }

    // Enforce device limit — but auto-replace the least-recently-used device
    // if the limit is hit, rather than blocking the user.  Free users can
    // always switch between devices seamlessly.
    // NOTE: user.subscription.maxDevices defaults to 1 in DB for legacy users;
    //       always derive the limit from the subscription tier instead so new
    //       constants take effect without a DB migration.
    const tier = user.subscription?.tier ?? 'free';
    const maxDevices = tier === 'free' ? MAX_DEVICES_FREE : MAX_DEVICES_PREMIUM;
    const activeDevices = await Device.countDocuments({ userId, isActive: true });
    const activeDevicesForLimit = existingDevice ? Math.max(0, activeDevices - 1) : activeDevices;

    if (!existingDevice && activeDevicesForLimit >= maxDevices) {
      // Auto-replace the oldest (least recently used) device instead of blocking.
      const lruDevice = await Device.findOne({ userId, isActive: true })
        .sort({ lastConnectedAt: 1, updatedAt: 1 });
      if (lruDevice) {
        logger.info(`Device limit reached for user ${userId}; replacing LRU device ${lruDevice.deviceId}`);
        existingDevice = lruDevice;
      }
    }

    let config;
    let deviceData = { userId, name, platform, protocol };

    if (protocol === 'wireguard') {
      const { clientPublicKey, presharedKey, assignedIp, configFile } =
        await wireguardService.addPeer(userId);
      config = configFile;
      deviceData = { ...deviceData, wgPublicKey: clientPublicKey, wgPresharedKey: presharedKey, assignedIp };
    } else if (protocol === 'openvpn') {
      config = await openvpnService.generateClientConfig(userId, name);
    } else {
      return res.status(400).json({ message: `Unsupported protocol: ${protocol}` });
    }

    let device;
    let statusCode;

    if (existingDevice) {
      if (existingDevice.protocol === 'wireguard' && existingDevice.wgPublicKey) {
        await wireguardService.removePeer(existingDevice.wgPublicKey, existingDevice.assignedIp).catch((err) =>
          logger.warn('Could not remove old WG peer while rotating config:', err.message),
        );
      }

      existingDevice.set(deviceData);
      device = await existingDevice.save();
      statusCode = 200;
    } else {
      device = await Device.create(deviceData);
      statusCode = 201;
    }

    logger.info(`VPN config generated for user ${userId}, device ${device.deviceId}, protocol ${protocol}, reused=${Boolean(existingDevice)}`);

    res.status(statusCode).json({
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
