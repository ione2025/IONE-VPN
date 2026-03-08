'use strict';

const router = require('express').Router();
const { body } = require('express-validator');
const vpnController = require('../controllers/vpnController');
const { protect } = require('../middleware/auth');
const { apiLimiter } = require('../middleware/rateLimiter');

router.use(protect, apiLimiter);

router.post(
  '/config',
  [
    body('name').trim().notEmpty().isLength({ max: 64 }),
    body('platform').isIn(['ios', 'android', 'windows', 'macos', 'linux', 'browser']),
    body('protocol').optional().isIn(['wireguard', 'openvpn', 'ikev2']),
  ],
  vpnController.generateConfig,
);

router.get('/status', vpnController.getStatus);
router.post('/connect', body('deviceId').notEmpty(), vpnController.connect);
router.post('/disconnect', body('deviceId').notEmpty(), vpnController.disconnect);
router.get('/speedtest', vpnController.speedTest);

module.exports = router;
