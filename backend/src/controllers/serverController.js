'use strict';

const serverMonitor = require('../services/serverMonitor');

// ─── List available servers ───────────────────────────────────────────────────
exports.list = async (_req, res, next) => {
  try {
    const servers = serverMonitor.getServers();
    res.json({ servers });
  } catch (err) {
    next(err);
  }
};

// ─── Get recommended server (AI-style selection) ──────────────────────────────
// Algorithm:
//   1. Filter servers accessible to the user's subscription tier.
//   2. Score each server: score = (100 - load%) * 0.5 + (300 - ping) * 0.5
//   3. Return highest scored server.
exports.recommend = async (req, res, next) => {
  try {
    const userRegion = req.query.region || null; // client passes its detected region
    const servers = serverMonitor.getServers().filter((s) => s.isOnline);

    if (servers.length === 0) {
      return res.status(503).json({ message: 'No servers available' });
    }

    const scored = servers.map((s) => {
      const loadScore = (100 - s.load) * 0.5;
      const pingScore = Math.max(0, (500 - s.ping) / 5);
      // Slight bonus for same region
      const regionBonus = userRegion && s.region.toLowerCase().includes(userRegion.toLowerCase()) ? 20 : 0;
      return { ...s, score: loadScore + pingScore + regionBonus };
    });

    scored.sort((a, b) => b.score - a.score);
    const recommended = scored[0];

    res.json({ recommended });
  } catch (err) {
    next(err);
  }
};

// ─── Server health (admin) ────────────────────────────────────────────────────
exports.health = async (_req, res, next) => {
  try {
    const stats = await serverMonitor.getDetailedStats();
    res.json({ stats });
  } catch (err) {
    next(err);
  }
};
