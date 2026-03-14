'use strict';

const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const { validationResult } = require('express-validator');
const User = require('../models/User');
const logger = require('../config/logger');

// ─── Helpers ─────────────────────────────────────────────────────────────────
function signToken(payload, secret, expiresIn) {
  return jwt.sign(payload, secret, { expiresIn });
}

function issueTokenPair(userId) {
  const access = signToken(
    { sub: userId, type: 'access' },
    process.env.JWT_SECRET,
    process.env.JWT_EXPIRES_IN || '7d',
  );
  const refresh = signToken(
    { sub: userId, type: 'refresh' },
    process.env.JWT_REFRESH_SECRET,
    process.env.JWT_REFRESH_EXPIRES_IN || '30d',
  );
  return { access, refresh };
}

function hashResetToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

// ─── Register ────────────────────────────────────────────────────────────────
exports.register = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(422).json({ errors: errors.array() });
    }

    const { email, password } = req.body;

    const existing = await User.findOne({ email });
    if (existing) {
      return res.status(409).json({ message: 'Email already registered' });
    }

    const user = await User.create({ email, password });
    const tokens = issueTokenPair(user._id);

    logger.info(`New user registered: ${email}`);
    res.status(201).json({ user: user.toPublic(), tokens });
  } catch (err) {
    next(err);
  }
};

// ─── Login ───────────────────────────────────────────────────────────────────
exports.login = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(422).json({ errors: errors.array() });
    }

    const { email, password } = req.body;
    const user = await User.findOne({ email }).select('+password');

    if (!user || !(await user.comparePassword(password))) {
      return res.status(401).json({ message: 'Invalid email or password' });
    }

    if (!user.isActive) {
      return res.status(403).json({ message: 'Account suspended' });
    }

    const tokens = issueTokenPair(user._id);
    logger.info(`User logged in: ${email}`);
    res.json({ user: user.toPublic(), tokens });
  } catch (err) {
    next(err);
  }
};

// ─── Refresh token ────────────────────────────────────────────────────────────
exports.refreshToken = async (req, res, next) => {
  try {
    const { refreshToken } = req.body;
    if (!refreshToken) {
      return res.status(400).json({ message: 'Refresh token required' });
    }

    let payload;
    try {
      payload = jwt.verify(refreshToken, process.env.JWT_REFRESH_SECRET);
    } catch {
      return res.status(401).json({ message: 'Invalid or expired refresh token' });
    }

    if (payload.type !== 'refresh') {
      return res.status(401).json({ message: 'Wrong token type' });
    }

    const user = await User.findById(payload.sub);
    if (!user || !user.isActive) {
      return res.status(401).json({ message: 'User not found or suspended' });
    }

    const tokens = issueTokenPair(user._id);
    res.json({ tokens });
  } catch (err) {
    next(err);
  }
};

// ─── Get current user ────────────────────────────────────────────────────────
exports.me = async (req, res, next) => {
  try {
    const user = await User.findById(req.user.id);
    if (!user) return res.status(404).json({ message: 'User not found' });
    res.json({ user: user.toPublic() });
  } catch (err) {
    next(err);
  }
};

// ─── Change password ─────────────────────────────────────────────────────────
exports.changePassword = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(422).json({ errors: errors.array() });
    }

    const { currentPassword, newPassword } = req.body;
    const user = await User.findById(req.user.id).select('+password');

    if (!(await user.comparePassword(currentPassword))) {
      return res.status(401).json({ message: 'Current password is incorrect' });
    }

    user.password = newPassword;
    await user.save();

    logger.info(`Password changed for user: ${user.email}`);
    res.json({ message: 'Password updated successfully' });
  } catch (err) {
    next(err);
  }
};

// ─── Delete account ───────────────────────────────────────────────────────────
exports.deleteAccount = async (req, res, next) => {
  try {
    const { password } = req.body;
    const user = await User.findById(req.user.id).select('+password');

    if (!user || !(await user.comparePassword(password))) {
      return res.status(401).json({ message: 'Invalid password' });
    }

    await user.deleteOne();
    logger.info(`Account deleted: ${user.email}`);
    res.json({ message: 'Account deleted successfully' });
  } catch (err) {
    next(err);
  }
};

// ─── Forgot password ────────────────────────────────────────────────────────
exports.forgotPassword = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(422).json({ errors: errors.array() });
    }

    const { email } = req.body;
    const user = await User.findOne({ email }).select('+passwordResetToken +passwordResetExpires');

    // Always return a generic success response to avoid account enumeration.
    if (!user || !user.isActive) {
      return res.json({ message: 'If the email exists, reset instructions have been sent.' });
    }

    const rawToken = crypto.randomBytes(32).toString('hex');
    user.passwordResetToken = hashResetToken(rawToken);
    user.passwordResetExpires = new Date(Date.now() + 1000 * 60 * 30); // 30 minutes
    await user.save();

    // Integrators can send this token by email/SMS. For now we log it so the
    // flow works even when no mail provider is configured yet.
    logger.info(`Password reset token generated for ${email}: ${rawToken}`);

    const payload = {
      message: 'If the email exists, reset instructions have been sent.',
    };

    // In non-production environments return token to help QA/mobile testing.
    if (process.env.NODE_ENV !== 'production') {
      payload.resetToken = rawToken;
    }

    res.json(payload);
  } catch (err) {
    next(err);
  }
};

// ─── Reset password ─────────────────────────────────────────────────────────
exports.resetPassword = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(422).json({ errors: errors.array() });
    }

    const { token, newPassword } = req.body;
    const hashedToken = hashResetToken(token);

    const user = await User.findOne({
      passwordResetToken: hashedToken,
      passwordResetExpires: { $gt: new Date() },
      isActive: true,
    }).select('+password');

    if (!user) {
      return res.status(400).json({ message: 'Invalid or expired reset token' });
    }

    user.password = newPassword;
    user.passwordResetToken = undefined;
    user.passwordResetExpires = undefined;
    await user.save();

    logger.info(`Password reset completed for user: ${user.email}`);
    res.json({ message: 'Password reset successfully' });
  } catch (err) {
    next(err);
  }
};
