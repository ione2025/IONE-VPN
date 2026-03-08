'use strict';

const jwt = require('jsonwebtoken');
const User = require('../models/User');

/**
 * Protect – verifies JWT and attaches req.user.
 */
exports.protect = async (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ message: 'Authentication required' });
    }

    const token = authHeader.slice(7);
    let payload;
    try {
      payload = jwt.verify(token, process.env.JWT_SECRET);
    } catch {
      return res.status(401).json({ message: 'Invalid or expired token' });
    }

    if (payload.type !== 'access') {
      return res.status(401).json({ message: 'Wrong token type' });
    }

    const user = await User.findById(payload.sub);
    if (!user || !user.isActive) {
      return res.status(401).json({ message: 'User not found or suspended' });
    }

    if (user.changedPasswordAfter(payload.iat)) {
      return res.status(401).json({ message: 'Password changed – please log in again' });
    }

    // Attach both id and the full doc for controllers that need subscription info
    req.user = { id: String(user._id), doc: user };
    next();
  } catch (err) {
    next(err);
  }
};

/**
 * Restrict – only allows specified roles (use after protect).
 */
exports.restrictTo = (...roles) => (req, res, next) => {
  if (!roles.includes(req.user.doc.role)) {
    return res.status(403).json({ message: 'Insufficient permissions' });
  }
  next();
};
