'use strict';

const router = require('express').Router();
const { body, param } = require('express-validator');
const deviceController = require('../controllers/deviceController');
const { protect } = require('../middleware/auth');
const { apiLimiter } = require('../middleware/rateLimiter');

router.use(protect, apiLimiter);

router.get('/', deviceController.list);
router.patch(
  '/:deviceId/rename',
  param('deviceId').notEmpty(),
  body('name').trim().notEmpty().isLength({ max: 64 }),
  deviceController.rename,
);
router.delete('/:deviceId', param('deviceId').notEmpty(), deviceController.revoke);

module.exports = router;
