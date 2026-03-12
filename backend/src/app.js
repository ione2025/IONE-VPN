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
  // Rebuild the WireGuard IP pool from existing DB records so allocation
  // is correct after server restarts (usedIps is otherwise in-memory only).
  const wireguardService = require('./services/wireguardService');
  await wireguardService.rebuildUsedIps();
  app.listen(PORT, () => {
    logger.info(`IONE VPN API running on port ${PORT} [${process.env.NODE_ENV}]`);
  });
}

if (require.main === module) {
  start().catch((err) => {
    logger.error('Failed to start server:', err);
    process.exit(1);
  });
}

module.exports = app; // exported for testing
