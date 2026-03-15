'use strict';

require('dotenv').config();

const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const morgan = require('morgan');

const connectDB = require('./config/database');
const connectRedis = require('./config/redis');
const logger = require('./config/logger');

const authRoutes = require('./routes/auth');
const vpnRoutes = require('./routes/vpn');
const serverRoutes = require('./routes/servers');
const deviceRoutes = require('./routes/devices');
const adminRoutes = require('./routes/admin');
const { globalErrorHandler, notFound } = require('./middleware/errorHandler');

const app = express();
// Trust one proxy hop (nginx) so that express-rate-limit resolves the real
// client IP from X-Forwarded-For rather than throwing ERR_ERL_UNEXPECTED_X_FORWARDED_FOR.
app.set('trust proxy', 1);

async function ensureAdminAccount() {
  const User = require('./models/User');

  const adminEmail = (process.env.ADMIN_EMAIL || 'admin@ionecenter.com').toLowerCase();
  const adminPassword = process.env.ADMIN_PASSWORD;

  const existing = await User.findOne({ email: adminEmail }).select('+password');
  if (existing) {
    let changed = false;
    if (existing.role !== 'admin') {
      existing.role = 'admin';
      changed = true;
    }
    if (existing.subscription?.tier !== 'ultra') {
      existing.subscription.tier = 'ultra';
      existing.subscription.maxDevices = 50;
      existing.subscription.unlimitedBandwidth = true;
      existing.subscription.allServers = true;
      changed = true;
    }
    if (changed) {
      await existing.save();
      logger.info(`Admin account updated: ${adminEmail}`);
    }
    return;
  }

  if (!adminPassword) {
    logger.warn(`ADMIN_PASSWORD not set; cannot create admin account ${adminEmail}`);
    return;
  }

  await User.create({
    email: adminEmail,
    password: adminPassword,
    role: 'admin',
    subscription: {
      tier: 'ultra',
      maxDevices: 50,
      unlimitedBandwidth: true,
      allServers: true,
    },
  });

  logger.info(`Admin account created: ${adminEmail}`);
}

// ─── Security middleware ──────────────────────────────────────────────────────
app.use(helmet());
app.use(cors({
  origin: process.env.ALLOWED_ORIGINS
    ? process.env.ALLOWED_ORIGINS.split(',')
    : '*',
  credentials: true,
}));

// ─── Request parsing ──────────────────────────────────────────────────────────
app.use(express.json({ limit: '10kb' }));
app.use(express.urlencoded({ extended: true, limit: '10kb' }));

// ─── Logging ─────────────────────────────────────────────────────────────────
if (process.env.NODE_ENV !== 'test') {
  app.use(morgan('combined', { stream: { write: (msg) => logger.info(msg.trim()) } }));
}

// ─── Health check ────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', app: 'IONE VPN', version: '1.0.0' });
});
// ─── Prometheus metrics ──────────────────────────────────────────────────
// Exposes lightweight text-format metrics for Prometheus scraping.
// Access is protected by a static bearer token (METRICS_TOKEN env var).
// If METRICS_TOKEN is not set, the endpoint is disabled.
app.get('/metrics', async (req, res) => {
  const token = process.env.METRICS_TOKEN;
  if (!token) return res.status(404).end();

  const authHeader = req.headers['authorization'] || '';
  if (authHeader !== `Bearer ${token}`) {
    return res.status(401).end();
  }

  try {
    const User = require('./models/User');
    const Device = require('./models/Device');
    const [totalUsers, activeDevices, freeUsers, premiumUsers, ultraUsers] = await Promise.all([
      User.countDocuments(),
      Device.countDocuments({ isActive: true }),
      User.countDocuments({ 'subscription.tier': 'free' }),
      User.countDocuments({ 'subscription.tier': { $in: ['premium', 'monthly', 'quarterly', 'yearly'] } }),
      User.countDocuments({ 'subscription.tier': 'ultra' }),
    ]);

    const lines = [
      '# HELP ione_vpn_users_total Total registered users',
      '# TYPE ione_vpn_users_total gauge',
      `ione_vpn_users_total ${totalUsers}`,
      '# HELP ione_vpn_users_free Users on free tier',
      '# TYPE ione_vpn_users_free gauge',
      `ione_vpn_users_free ${freeUsers}`,
      '# HELP ione_vpn_users_premium Users on premium tier',
      '# TYPE ione_vpn_users_premium gauge',
      `ione_vpn_users_premium ${premiumUsers}`,
      '# HELP ione_vpn_users_ultra Users on ultra tier',
      '# TYPE ione_vpn_users_ultra gauge',
      `ione_vpn_users_ultra ${ultraUsers}`,
      '# HELP ione_vpn_devices_active Active WireGuard devices',
      '# TYPE ione_vpn_devices_active gauge',
      `ione_vpn_devices_active ${activeDevices}`,
      '# HELP ione_vpn_up API health (1 = up)',
      '# TYPE ione_vpn_up gauge',
      `ione_vpn_up 1`,
    ];

    res.set('Content-Type', 'text/plain; version=0.0.4; charset=utf-8');
    res.send(lines.join('\n') + '\n');
  } catch (err) {
    logger.error('Metrics endpoint error:', err);
    res.status(500).end();
  }
});
// ─── Routes ──────────────────────────────────────────────────────────────────
app.use('/api/v1/auth', authRoutes);
app.use('/api/v1/vpn', vpnRoutes);
app.use('/api/v1/servers', serverRoutes);
app.use('/api/v1/devices', deviceRoutes);
app.use('/api/v1/admin', adminRoutes);

// ─── 404 / Error handlers ────────────────────────────────────────────────────
app.use(notFound);
app.use(globalErrorHandler);

// ─── Bootstrap ───────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;

async function start() {
  await connectDB();
  await connectRedis();
  await ensureAdminAccount();
  // Rebuild the WireGuard IP pool from existing DB records so allocation
  // is correct after server restarts (usedIps is otherwise in-memory only).
  const wireguardService = require('./services/wireguardService');
  await wireguardService.rebuildUsedIps();
  const server = app.listen(PORT, () => {
    logger.info(`IONE VPN API running on port ${PORT} [${process.env.NODE_ENV}]`);
  });

  // ── Graceful shutdown (PM2 cluster reload / SIGINT / SIGTERM) ────────────
  // Stops accepting new connections, waits for in-flight requests to finish,
  // then exits. This enables zero-downtime rolling reloads in cluster mode.
  const shutdown = (signal) => {
    logger.info(`${signal} received – shutting down gracefully`);
    server.close(async () => {
      try {
        const mongoose = require('mongoose');
        await mongoose.disconnect();
        logger.info('MongoDB disconnected');
      } catch (_) {}
      logger.info('Process exiting');
      process.exit(0);
    });
    // Force-kill if requests haven't drained within 10 s
    setTimeout(() => {
      logger.error('Graceful shutdown timed out – forcing exit');
      process.exit(1);
    }, 10_000).unref();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT',  () => shutdown('SIGINT'));
}

if (require.main === module) {
  start().catch((err) => {
    logger.error('Failed to start server:', err);
    process.exit(1);
  });
}

module.exports = app; // exported for testing
