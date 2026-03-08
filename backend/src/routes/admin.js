'use strict';

const router = require('express').Router();
const { body, param } = require('express-validator');
const adminController = require('../controllers/adminController');
const { protect, restrictTo } = require('../middleware/auth');
const { apiLimiter } = require('../middleware/rateLimiter');

router.get('/dashboard', apiLimiter, protect, restrictTo('admin'), adminController.dashboard);
router.get('/users', apiLimiter, protect, restrictTo('admin'), adminController.listUsers);
router.patch(
  '/users/:userId/subscription',
  apiLimiter,
  protect,
  restrictTo('admin'),
  param('userId').notEmpty(),
  body('tier').isIn(['free', 'monthly', 'quarterly', 'yearly']),
  adminController.updateSubscription,
);
router.patch(
  '/users/:userId/toggle-status',
  apiLimiter,
  protect,
  restrictTo('admin'),
  param('userId').notEmpty(),
  adminController.toggleUserStatus,
);
router.get('/wg-peers', apiLimiter, protect, restrictTo('admin'), adminController.wgPeers);

module.exports = router;
