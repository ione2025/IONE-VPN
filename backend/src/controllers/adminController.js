'use strict';

const User = require('../models/User');
const Device = require('../models/Device');
const wireguardService = require('../services/wireguardService');
const serverMonitor = require('../services/serverMonitor');
const logger = require('../config/logger');

const TIER_DEVICE_LIMITS = {
  free: 1,
  premium: 10,
  ultra: 50,
};

function normalizeTier(tier) {
  if (tier === 'monthly' || tier === 'quarterly' || tier === 'yearly') {
    return 'premium';
  }
  return tier || 'free';
}

// ─── Dashboard overview ───────────────────────────────────────────────────────
exports.dashboard = async (_req, res, next) => {
  try {
    const [totalUsers, activeDevices, serverStats] = await Promise.all([
      User.countDocuments(),
      Device.countDocuments({ isActive: true }),
      serverMonitor.getDetailedStats(),
    ]);

    const [freeUsers, premiumUsers, ultraUsers] = await Promise.all([
      User.countDocuments({ 'subscription.tier': 'free' }),
      User.countDocuments({ 'subscription.tier': { $in: ['premium', 'monthly', 'quarterly', 'yearly'] } }),
      User.countDocuments({ 'subscription.tier': 'ultra' }),
    ]);

    res.json({
      totalUsers,
      freeUsers,
      premiumUsers,
      ultraUsers,
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
    const includeDevices = String(req.query.includeDevices || 'false').toLowerCase() === 'true';

    const [users, total] = await Promise.all([
      User.find().skip(skip).limit(limit).select('-password').sort({ createdAt: -1 }),
      User.countDocuments(),
    ]);

    const userIds = users.map((u) => u._id);
    const activeDevices = await Device.find({ userId: { $in: userIds }, isActive: true })
      .sort({ updatedAt: -1 })
      .select('deviceId userId name platform protocol assignedIp lastConnectedAt updatedAt createdAt');

    const byUser = new Map();
    for (const d of activeDevices) {
      const key = String(d.userId);
      if (!byUser.has(key)) byUser.set(key, []);
      byUser.get(key).push({
        deviceId: d.deviceId,
        name: d.name,
        platform: d.platform,
        protocol: d.protocol,
        assignedIp: d.assignedIp,
        lastConnectedAt: d.lastConnectedAt,
        createdAt: d.createdAt,
        updatedAt: d.updatedAt,
      });
    }

    const payloadUsers = users.map((u) => {
      const user = u.toPublic();
      const tier = normalizeTier(user.subscription?.tier);
      const devices = byUser.get(String(u._id)) || [];
      return {
        ...user,
        subscription: {
          ...(user.subscription || {}),
          tier,
          maxDevices: TIER_DEVICE_LIMITS[tier],
          unlimitedBandwidth: tier !== 'free',
          allServers: tier !== 'free',
        },
        activeDeviceCount: devices.length,
        devices: includeDevices ? devices : undefined,
      };
    });

    res.json({ users: payloadUsers, total, page, pages: Math.ceil(total / limit) });
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
      premium: { maxDevices: 10, unlimitedBandwidth: true, allServers: true },
      ultra: { maxDevices: 50, unlimitedBandwidth: true, allServers: true },
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

// ─── Delete user account (admin hard-delete) ──────────────────────────────────
exports.deleteUser = async (req, res, next) => {
  try {
    const { userId } = req.params;

    // Prevent self-deletion
    if (userId === String(req.user.id)) {
      return res.status(400).json({ message: 'Cannot delete your own admin account' });
    }

    const user = await User.findById(userId);
    if (!user) return res.status(404).json({ message: 'User not found' });

    // Remove all WireGuard peers for this user
    const devices = await Device.find({ userId, isActive: true, wgPublicKey: { $exists: true, $ne: null } });
    await Promise.all(
      devices.map((d) =>
        wireguardService
          .removePeer(d.wgPublicKey, d.assignedIp)
          .catch((err) => logger.warn(`Could not remove WG peer on user delete: ${err.message}`)),
      ),
    );

    await Device.deleteMany({ userId });
    await user.deleteOne();

    logger.info(`Admin hard-deleted user: ${user.email} (${userId})`);
    res.json({ message: `User ${user.email} deleted` });
  } catch (err) {
    next(err);
  }
};

// ─── Revoke ALL devices for a user (admin forced disconnect) ─────────────────
exports.revokeAllDevices = async (req, res, next) => {
  try {
    const { userId } = req.params;
    const devices = await Device.find({ userId, isActive: true, wgPublicKey: { $exists: true, $ne: null } });

    await Promise.all(
      devices.map((d) =>
        wireguardService
          .removePeer(d.wgPublicKey, d.assignedIp)
          .catch((err) => logger.warn(`Could not remove WG peer for device ${d.deviceId}: ${err.message}`)),
      ),
    );

    const result = await Device.updateMany({ userId }, { $set: { isActive: false } });
    logger.info(`Admin revoked all devices for userId ${userId}: ${result.modifiedCount} devices deactivated`);
    res.json({ message: 'All devices revoked', count: result.modifiedCount });
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
