'use strict';

const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');

const SALT_ROUNDS = parseInt(process.env.BCRYPT_SALT_ROUNDS || '12', 10);

function normalizeTier(tier) {
  if (tier === 'monthly' || tier === 'quarterly' || tier === 'yearly') {
    return 'premium';
  }
  return tier || 'free';
}

// ─── Subscription sub-schema ──────────────────────────────────────────────────
const subscriptionSchema = new mongoose.Schema({
  tier: {
    type: String,
    // Keep legacy values for backward compatibility with existing records.
    enum: ['free', 'premium', 'ultra', 'monthly', 'quarterly', 'yearly'],
    default: 'free',
  },
  stripeCustomerId: { type: String, select: false },
  stripeSubscriptionId: { type: String, select: false },
  expiresAt: { type: Date, default: null },
  maxDevices: { type: Number, default: 1 },
  unlimitedBandwidth: { type: Boolean, default: false },
  allServers: { type: Boolean, default: false },
}, { _id: false });

// ─── User schema ─────────────────────────────────────────────────────────────
const userSchema = new mongoose.Schema(
  {
    email: {
      type: String,
      required: [true, 'Email is required'],
      unique: true,
      lowercase: true,
      trim: true,
      match: [/^\S+@\S+\.\S+$/, 'Invalid email format'],
    },
    password: {
      type: String,
      required: [true, 'Password is required'],
      minlength: 8,
      select: false, // never returned by default
    },
    role: {
      type: String,
      enum: ['user', 'admin'],
      default: 'user',
    },
    isActive: { type: Boolean, default: true },
    subscription: { type: subscriptionSchema, default: () => ({}) },
    passwordChangedAt: { type: Date, select: false },
    passwordResetToken: { type: String, select: false },
    passwordResetExpires: { type: Date, select: false },
  },
  { timestamps: true },
);

// ─── Hooks ────────────────────────────────────────────────────────────────────
userSchema.pre('save', async function hashPassword(next) {
  if (!this.isModified('password')) return next();
  this.password = await bcrypt.hash(this.password, SALT_ROUNDS);
  if (!this.isNew) this.passwordChangedAt = new Date();
  next();
});

// ─── Instance methods ────────────────────────────────────────────────────────
userSchema.methods.comparePassword = async function (candidate) {
  return bcrypt.compare(candidate, this.password);
};

userSchema.methods.changedPasswordAfter = function (jwtIssuedAt) {
  if (this.passwordChangedAt) {
    return this.passwordChangedAt.getTime() / 1000 > jwtIssuedAt;
  }
  return false;
};

userSchema.methods.toPublic = function () {
  const normalizedTier = normalizeTier(this.subscription?.tier);
  const limits = normalizedTier === 'ultra'
    ? { maxDevices: 50, unlimitedBandwidth: true, allServers: true }
    : normalizedTier === 'premium'
      ? { maxDevices: 10, unlimitedBandwidth: true, allServers: true }
      : { maxDevices: 1, unlimitedBandwidth: false, allServers: false };

  return {
    id: this._id,
    email: this.email,
    role: this.role,
    subscription: {
      ...(this.subscription?.toObject ? this.subscription.toObject() : this.subscription),
      tier: normalizedTier,
      maxDevices: limits.maxDevices,
      unlimitedBandwidth: limits.unlimitedBandwidth,
      allServers: limits.allServers,
    },
    createdAt: this.createdAt,
  };
};

const User = mongoose.model('User', userSchema);
module.exports = User;
