'use strict';

const router = require('express').Router();
const { body } = require('express-validator');
const authController = require('../controllers/authController');
const { protect } = require('../middleware/auth');
const { authLimiter } = require('../middleware/rateLimiter');

const emailRule = body('email').isEmail().normalizeEmail();
const passwordRule = body('password').isLength({ min: 8 }).withMessage('Password must be at least 8 characters');

router.post('/register', authLimiter, [emailRule, passwordRule], authController.register);
router.post('/login', authLimiter, [emailRule, passwordRule], authController.login);
router.post('/refresh', authController.refreshToken);

// Protected
router.get('/me', protect, authController.me);
router.patch(
  '/change-password',
  protect,
  [
    body('currentPassword').notEmpty(),
    body('newPassword').isLength({ min: 8 }),
  ],
  authController.changePassword,
);
router.delete('/account', protect, body('password').notEmpty(), authController.deleteAccount);

module.exports = router;
