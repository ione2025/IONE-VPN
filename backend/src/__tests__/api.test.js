'use strict';

/**
 * Integration tests for IONE VPN backend API.
 *
 * Prerequisites:
 *   - MongoDB must be running on localhost:27017 (the test DB is dropped after each run).
 *     Start with: `mongod --dbpath /tmp/ione-test-db --fork --logpath /tmp/mongod.log`
 *   - Redis is mocked (no real Redis needed).
 *   - WireGuard CLI is mocked (no real WireGuard needed).
 *
 * Run: npm test
 */

// ─── Environment setup (must happen before app is loaded) ─────────────────────
process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test_jwt_secret_that_is_long_enough_to_pass_validation';
process.env.JWT_REFRESH_SECRET = 'test_refresh_secret_that_is_long_enough_too';
process.env.JWT_EXPIRES_IN = '1h';
process.env.JWT_REFRESH_EXPIRES_IN = '2h';
process.env.MONGODB_URI = 'mongodb://127.0.0.1:27017/ione_vpn_test';

// Mock Redis so the test doesn't need a real Redis server
jest.mock('../config/redis', () => {
  const fn = jest.fn().mockResolvedValue(undefined);
  fn.getRedis = jest.fn();
  return fn;
});

// Mock WireGuard CLI calls
jest.mock('../services/wireguardService', () => ({
  addPeer: jest.fn().mockResolvedValue({
    clientPrivateKey: 'FAKE_PRIVATE_KEY',
    clientPublicKey: 'FAKE_PUBLIC_KEY',
    presharedKey: 'FAKE_PSK',
    assignedIp: '10.8.0.2/32',
    configFile: '[Interface]\nPrivateKey = FAKE_PRIVATE_KEY',
  }),
  removePeer: jest.fn().mockResolvedValue(undefined),
  getPeerStats: jest.fn().mockResolvedValue([]),
}));

jest.mock('../services/openvpnService', () => ({
  generateClientConfig: jest.fn().mockResolvedValue('client\ndev tun'),
}));

const mongoose = require('mongoose');
const request = require('supertest');
const app = require('../app');

// ─── DB lifecycle ─────────────────────────────────────────────────────────────
beforeAll(async () => {
  await mongoose.connect(process.env.MONGODB_URI);
});

afterAll(async () => {
  await mongoose.connection.dropDatabase();
  await mongoose.disconnect();
});

afterEach(async () => {
  const collections = mongoose.connection.collections;
  for (const key in collections) {
    await collections[key].deleteMany({});
  }
});

// ─── Helpers ──────────────────────────────────────────────────────────────────
async function registerAndLogin(email = 'test@example.com', password = 'Password123') {
  await request(app).post('/api/v1/auth/register').send({ email, password });
  const res = await request(app).post('/api/v1/auth/login').send({ email, password });
  return res.body.tokens.access;
}

// ─── Health ───────────────────────────────────────────────────────────────────
describe('GET /health', () => {
  it('returns 200 with app info', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'ok', app: 'IONE VPN' });
  });
});

// ─── Auth: register ───────────────────────────────────────────────────────────
describe('POST /api/v1/auth/register', () => {
  it('creates a new user and returns tokens', async () => {
    const res = await request(app)
      .post('/api/v1/auth/register')
      .send({ email: 'new@example.com', password: 'StrongPass1' });

    expect(res.status).toBe(201);
    expect(res.body).toHaveProperty('tokens.access');
    expect(res.body).toHaveProperty('tokens.refresh');
    expect(res.body.user.email).toBe('new@example.com');
    expect(res.body.user).not.toHaveProperty('password');
  });

  it('rejects duplicate email with 409', async () => {
    await request(app)
      .post('/api/v1/auth/register')
      .send({ email: 'dup@example.com', password: 'StrongPass1' });

    const res = await request(app)
      .post('/api/v1/auth/register')
      .send({ email: 'dup@example.com', password: 'AnotherPass1' });

    expect(res.status).toBe(409);
  });

  it('rejects short passwords with 422', async () => {
    const res = await request(app)
      .post('/api/v1/auth/register')
      .send({ email: 'weak@example.com', password: 'short' });

    expect(res.status).toBe(422);
  });
});

// ─── Auth: login ──────────────────────────────────────────────────────────────
describe('POST /api/v1/auth/login', () => {
  it('returns tokens on valid credentials', async () => {
    await request(app).post('/api/v1/auth/register').send({ email: 'login@example.com', password: 'Pass12345' });

    const res = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: 'login@example.com', password: 'Pass12345' });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('tokens.access');
  });

  it('rejects wrong password with 401', async () => {
    await request(app).post('/api/v1/auth/register').send({ email: 'bad@example.com', password: 'Pass12345' });

    const res = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: 'bad@example.com', password: 'WrongPassword' });

    expect(res.status).toBe(401);
  });
});

// ─── Auth: me ─────────────────────────────────────────────────────────────────
describe('GET /api/v1/auth/me', () => {
  it('returns the current user', async () => {
    const token = await registerAndLogin('me@example.com');
    const res = await request(app)
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.user.email).toBe('me@example.com');
  });

  it('returns 401 without token', async () => {
    const res = await request(app).get('/api/v1/auth/me');
    expect(res.status).toBe(401);
  });
});

// ─── VPN: generate config ─────────────────────────────────────────────────────
describe('POST /api/v1/vpn/config', () => {
  it('generates a WireGuard config for a new device', async () => {
    const token = await registerAndLogin('vpn@example.com');
    const res = await request(app)
      .post('/api/v1/vpn/config')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'My Phone', platform: 'android', protocol: 'wireguard' });

    expect(res.status).toBe(201);
    expect(res.body).toHaveProperty('deviceId');
    expect(res.body).toHaveProperty('config');
    expect(res.body.protocol).toBe('wireguard');
  });

  it('rejects missing platform with 422', async () => {
    const token = await registerAndLogin('vpn2@example.com');
    const res = await request(app)
      .post('/api/v1/vpn/config')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'Device', protocol: 'wireguard' });

    expect(res.status).toBe(422);
  });
});

// ─── Servers ──────────────────────────────────────────────────────────────────
describe('GET /api/v1/servers', () => {
  it('lists available servers', async () => {
    const token = await registerAndLogin('srv@example.com');
    const res = await request(app)
      .get('/api/v1/servers')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.servers)).toBe(true);
    expect(res.body.servers[0]).toHaveProperty('region', 'Singapore');
  });
});

describe('GET /api/v1/servers/recommend', () => {
  it('returns a recommended server', async () => {
    const token = await registerAndLogin('rec@example.com');
    const res = await request(app)
      .get('/api/v1/servers/recommend')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('recommended');
    expect(res.body.recommended).toHaveProperty('id', 'sg-01');
  });
});

// ─── Devices ──────────────────────────────────────────────────────────────────
describe('GET /api/v1/devices', () => {
  it('lists registered devices', async () => {
    const token = await registerAndLogin('dev@example.com');

    // Register a device first
    await request(app)
      .post('/api/v1/vpn/config')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'Laptop', platform: 'windows', protocol: 'wireguard' });

    const res = await request(app)
      .get('/api/v1/devices')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.devices).toHaveLength(1);
    expect(res.body.devices[0].name).toBe('Laptop');
  });
});

describe('DELETE /api/v1/devices/:deviceId', () => {
  it('revokes a device', async () => {
    const token = await registerAndLogin('revoke@example.com');

    const configRes = await request(app)
      .post('/api/v1/vpn/config')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'OldPhone', platform: 'ios', protocol: 'wireguard' });

    const { deviceId } = configRes.body;

    const revokeRes = await request(app)
      .delete(`/api/v1/devices/${deviceId}`)
      .set('Authorization', `Bearer ${token}`);

    expect(revokeRes.status).toBe(200);
    expect(revokeRes.body.message).toMatch(/revoked/i);
  });
});
