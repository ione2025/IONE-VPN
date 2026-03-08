'use strict';

const User = require('../models/User');
const Device = require('../models/Device');
const wireguardService = require('../services/wireguardService');
const serverMonitor = require('../services/serverMonitor');
const logger = require('../config/logger');

// ─── Dashboard overview ───────────────────────────────────────────────────────
exports.dashboard = async (_req, res, next) => {
  try {
    const [totalUsers, activeDevices, serverStats] = await Promise.all([
      User.countDocuments(),
      Device.countDocuments({ isActive: true }),
      serverMonitor.getDetailedStats(),
    ]);

    const premiumUsers = await User.countDocuments({
      'subscription.tier': { $ne: 'free' },
    });

    res.json({
      totalUsers,
      premiumUsers,
      activeDevices,
      serverStats,
    });
  } catch (err) {
    next(err);
  }
};

// ─── List all users (paginated) ───────────────────────────────────────────────
exports.listUsers = async (req, res, next) => {
  try {
    const page = Math.max(1, parseInt(req.query.page) || 1);
    const limit = Math.min(100, parseInt(req.query.limit) || 20);
    const skip = (page - 1) * limit;

    const [users, total] = await Promise.all([
      User.find().skip(skip).limit(limit).select('-password'),
      User.countDocuments(),
    ]);

    res.json({ users, total, page, pages: Math.ceil(total / limit) });
  } catch (err) {
    next(err);
  }
};

// ─── Update user subscription ─────────────────────────────────────────────────
exports.updateSubscription = async (req, res, next) => {
  try {
    const { userId } = req.params;
    const { tier, expiresAt } = req.body;

    const tierConfig = {
      free: { maxDevices: 1, unlimitedBandwidth: false, allServers: false },
      monthly: { maxDevices: 10, unlimitedBandwidth: true, allServers: true },
      quarterly: { maxDevices: 10, unlimitedBandwidth: true, allServers: true },
      yearly: { maxDevices: 10, unlimitedBandwidth: true, allServers: true },
    };

    if (!tierConfig[tier]) {
      return res.status(400).json({ message: 'Invalid subscription tier' });
    }

    const user = await User.findByIdAndUpdate(
      userId,
      {
        'subscription.tier': tier,
        'subscription.expiresAt': expiresAt || null,
        ...Object.fromEntries(
          Object.entries(tierConfig[tier]).map(([k, v]) => [`subscription.${k}`, v]),
        ),
      },
      { new: true },
    );

    if (!user) return res.status(404).json({ message: 'User not found' });
    logger.info(`Admin updated subscription for ${user.email} → ${tier}`);
    res.json({ user: user.toPublic() });
  } catch (err) {
    next(err);
  }
};

// ─── WireGuard peer list (live) ───────────────────────────────────────────────
exports.wgPeers = async (_req, res, next) => {
  try {
    const peers = await wireguardService.getPeerStats();
    res.json({ peers });
  } catch (err) {
    next(err);
  }
};

// ─── Suspend / unsuspend user ─────────────────────────────────────────────────
exports.toggleUserStatus = async (req, res, next) => {
  try {
    const { userId } = req.params;
    const user = await User.findById(userId);
    if (!user) return res.status(404).json({ message: 'User not found' });

    user.isActive = !user.isActive;
    await user.save();

    logger.info(`Admin ${user.isActive ? 'activated' : 'suspended'} user: ${user.email}`);
    res.json({ message: `User ${user.isActive ? 'activated' : 'suspended'}`, user: user.toPublic() });
  } catch (err) {
    next(err);
  }
};
