'use strict';

const router = require('express').Router();
const serverController = require('../controllers/serverController');
const { protect, restrictTo } = require('../middleware/auth');
const { apiLimiter } = require('../middleware/rateLimiter');

router.use(apiLimiter);

router.get('/', protect, serverController.list);
router.get('/recommend', protect, serverController.recommend);
router.get('/health', protect, restrictTo('admin'), serverController.health);

module.exports = router;
