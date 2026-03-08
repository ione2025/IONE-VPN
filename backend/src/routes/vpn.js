'use strict';

const router = require('express').Router();
const { body } = require('express-validator');
const vpnController = require('../controllers/vpnController');
const { protect } = require('../middleware/auth');
const { apiLimiter } = require('../middleware/rateLimiter');

router.post(
  '/config',
  apiLimiter,
  protect,
  [
    body('name').trim().notEmpty().isLength({ max: 64 }),
    body('platform').isIn(['ios', 'android', 'windows', 'macos', 'linux', 'browser']),
    body('protocol').optional().isIn(['wireguard', 'openvpn', 'ikev2']),
  ],
  vpnController.generateConfig,
);

router.get('/status', apiLimiter, protect, vpnController.getStatus);
router.post('/connect', apiLimiter, protect, body('deviceId').notEmpty(), vpnController.connect);
router.post('/disconnect', apiLimiter, protect, body('deviceId').notEmpty(), vpnController.disconnect);
router.get('/speedtest', apiLimiter, protect, vpnController.speedTest);

module.exports = router;
