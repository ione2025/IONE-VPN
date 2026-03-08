'use strict';

const { validationResult } = require('express-validator');
const Device = require('../models/Device');
const wireguardService = require('../services/wireguardService');
const logger = require('../config/logger');

// ─── List user's devices ──────────────────────────────────────────────────────
exports.list = async (req, res, next) => {
  try {
    const devices = await Device.find({ userId: req.user.id, isActive: true }).select('-wgPresharedKey');
    res.json({ devices });
  } catch (err) {
    next(err);
  }
};

// ─── Rename a device ─────────────────────────────────────────────────────────
exports.rename = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) return res.status(422).json({ errors: errors.array() });

    const { deviceId } = req.params;
    const { name } = req.body;

    const device = await Device.findOneAndUpdate(
      { deviceId, userId: req.user.id },
      { name },
      { new: true },
    ).select('-wgPresharedKey');

    if (!device) return res.status(404).json({ message: 'Device not found' });
    res.json({ device });
  } catch (err) {
    next(err);
  }
};

// ─── Revoke (deactivate) a device ────────────────────────────────────────────
exports.revoke = async (req, res, next) => {
  try {
    const { deviceId } = req.params;
    const device = await Device.findOne({ deviceId, userId: req.user.id });
    if (!device) return res.status(404).json({ message: 'Device not found' });

    device.isActive = false;
    await device.save();

    // Remove the peer from WireGuard if applicable
    if (device.protocol === 'wireguard' && device.wgPublicKey) {
      await wireguardService.removePeer(device.wgPublicKey).catch((err) =>
        logger.warn('Could not remove WG peer (may already be gone):', err.message),
      );
    }

    logger.info(`Device revoked: ${deviceId} for user ${req.user.id}`);
    res.json({ message: 'Device revoked successfully' });
  } catch (err) {
    next(err);
  }
};
