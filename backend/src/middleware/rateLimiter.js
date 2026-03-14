'use strict';

const rateLimit = require('express-rate-limit');
const User = require('../models/User');

const windowMs = parseInt(process.env.RATE_LIMIT_WINDOW_MS || '900000', 10); // 15 min

function authKeyGenerator(req) {
  const email = typeof req.body?.email === 'string'
    ? req.body.email.trim().toLowerCase()
    : 'anonymous';
  return `${req.ip}:${email}`;
}

async function hasValidLoginCredentials(req) {
  const email = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : '';
  const password = typeof req.body?.password === 'string' ? req.body.password : '';

  if (!email || !password) return false;

  const user = await User.findOne({ email }).select('+password');
  if (!user || !user.isActive) return false;

  return user.comparePassword(password);
}

/**
 * General API rate limiter.
 */
exports.apiLimiter = rateLimit({
  windowMs,
  max: parseInt(process.env.RATE_LIMIT_MAX || '100', 10),
  standardHeaders: true,
  legacyHeaders: false,
  message: { message: 'Too many requests, please try again later.' },
});

/**
 * Stricter limiter for general auth endpoints.
 */
exports.authLimiter = rateLimit({
  windowMs,
  max: parseInt(process.env.AUTH_RATE_LIMIT_MAX || '10', 10),
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: authKeyGenerator,
  message: { message: 'Too many authentication attempts, please try again later.' },
  skipSuccessfulRequests: true,
});

/**
 * Login limiter that never blocks a request carrying correct credentials.
 */
exports.loginLimiter = rateLimit({
  windowMs,
  max: parseInt(process.env.AUTH_RATE_LIMIT_MAX || '10', 10),
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: authKeyGenerator,
  message: { message: 'Too many login attempts, please try again later.' },
  skipSuccessfulRequests: true,
  skip: hasValidLoginCredentials,
});
