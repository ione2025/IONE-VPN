'use strict';

const Redis = require('ioredis');
const logger = require('./logger');

let client = null;

async function connectRedis() {
  if (client) return client;

  const options = {
    host: process.env.REDIS_HOST || '127.0.0.1',
    port: parseInt(process.env.REDIS_PORT || '6379', 10),
    password: process.env.REDIS_PASSWORD || undefined,
    retryStrategy: (times) => Math.min(times * 100, 3000),
    lazyConnect: true,
  };

  client = new Redis(options);

  client.on('connect', () => logger.info('Redis connected'));
  client.on('error', (err) => logger.error('Redis error:', err));

  await client.connect();
  return client;
}

function getRedis() {
  if (!client) throw new Error('Redis not initialised – call connectRedis() first');
  return client;
}

module.exports = connectRedis;
module.exports.getRedis = getRedis;
