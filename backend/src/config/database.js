'use strict';

const mongoose = require('mongoose');
const logger = require('./logger');

let isConnected = false;

async function connectDB() {
  if (isConnected) return;
  const uri = process.env.MONGODB_URI || 'mongodb://localhost:27017/ione_vpn';
  await mongoose.connect(uri, {
    serverSelectionTimeoutMS: 5000,
    // Connection pool: 10 connections handles ~200 concurrent API requests.
    // PM2 cluster mode multiplies this per worker (each worker gets its own pool).
    maxPoolSize: 10,
    minPoolSize: 2,
    // Close idle connections after 30 s to free server resources.
    maxIdleTimeMS: 30_000,
    // Heartbeat keeps replica-set awareness fresh (important for Atlas/future scaling).
    heartbeatFrequencyMS: 10_000,
  });
  isConnected = true;
  logger.info('MongoDB connected');

  mongoose.connection.on('error', (err) => {
    logger.error('MongoDB connection error:', err);
  });
  mongoose.connection.on('disconnected', () => {
    isConnected = false;
    logger.warn('MongoDB disconnected');
  });
}

module.exports = connectDB;
