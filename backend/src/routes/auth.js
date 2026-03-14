'use strict';

const router = require('express').Router();
const { body } = require('express-validator');
const authController = require('../controllers/authController');
const { protect } = require('../middleware/auth');
const { authLimiter, apiLimiter, loginLimiter } = require('../middleware/rateLimiter');

const emailRule = body('email').isEmail().normalizeEmail();
const passwordRule = body('password').isLength({ min: 8 }).withMessage('Password must be at least 8 characters');

router.post('/register', authLimiter, [emailRule, passwordRule], authController.register);
router.post('/login', loginLimiter, [emailRule, passwordRule], authController.login);
router.post('/refresh', apiLimiter, authController.refreshToken);
router.post('/forgot-password', authLimiter, [emailRule], authController.forgotPassword);
router.post(
  '/reset-password',
  authLimiter,
  [
    body('token').isString().isLength({ min: 16 }),
    body('newPassword').isLength({ min: 8 }).withMessage('Password must be at least 8 characters'),
  ],
  authController.resetPassword,
);

// Protected
router.get('/me', apiLimiter, protect, authController.me);
router.patch(
  '/change-password',
  apiLimiter,
  protect,
  [
    body('currentPassword').notEmpty(),
    body('newPassword').isLength({ min: 8 }),
  ],
  authController.changePassword,
);
router.delete('/account', apiLimiter, protect, body('password').notEmpty(), authController.deleteAccount);

module.exports = router;
