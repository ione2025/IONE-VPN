'use strict';

const router = require('express').Router();
const { body, param } = require('express-validator');
const adminController = require('../controllers/adminController');
const { protect, restrictTo } = require('../middleware/auth');
const { apiLimiter } = require('../middleware/rateLimiter');

router.use(protect, restrictTo('admin'), apiLimiter);

router.get('/dashboard', adminController.dashboard);
router.get('/users', adminController.listUsers);
router.patch(
  '/users/:userId/subscription',
  param('userId').notEmpty(),
  body('tier').isIn(['free', 'monthly', 'quarterly', 'yearly']),
  adminController.updateSubscription,
);
router.patch('/users/:userId/toggle-status', param('userId').notEmpty(), adminController.toggleUserStatus);
router.get('/wg-peers', adminController.wgPeers);

module.exports = router;
