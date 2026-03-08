'use strict';

const mongoose = require('mongoose');
const { v4: uuidv4 } = require('uuid');

const deviceSchema = new mongoose.Schema(
  {
    deviceId: {
      type: String,
      default: uuidv4,
      unique: true,
      index: true,
    },
    userId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'User',
      required: true,
      index: true,
    },
    name: {
      type: String,
      required: true,
      trim: true,
      maxlength: 64,
    },
    platform: {
      type: String,
      enum: ['ios', 'android', 'windows', 'macos', 'linux', 'browser'],
      required: true,
    },
    protocol: {
      type: String,
      enum: ['wireguard', 'openvpn', 'ikev2'],
      default: 'wireguard',
    },
    // WireGuard peer fields (stored so the server can rebuild wg0.conf)
    wgPublicKey: { type: String, sparse: true },
    wgPresharedKey: { type: String, select: false },
    assignedIp: { type: String }, // e.g. "10.8.0.2/32"

    isActive: { type: Boolean, default: true },
    lastConnectedAt: { type: Date },
  },
  { timestamps: true },
);

deviceSchema.index({ userId: 1, isActive: 1 });

const Device = mongoose.model('Device', deviceSchema);
module.exports = Device;
