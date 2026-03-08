# IONE VPN

**Secure. Fast. Private.** — A cross-platform VPN application backed by a DigitalOcean Singapore droplet.

## Features

- 🔒 WireGuard & OpenVPN protocols with AES-256 encryption
- ⚡ One-click connect with AI-based server recommendation
- 🛡️ Kill switch & DNS leak protection
- 📊 Real-time upload/download speed meters
- 🌙 Dark / light mode
- 📱 Cross-platform: Windows, macOS, iOS, Android
- 🔑 Zero-log policy — no activity, no IPs, no timestamps stored
- 👥 Up to 10 simultaneous devices (Premium)

## Quick Start

See **[SETUP.md](SETUP.md)** for the complete step-by-step guide covering:

1. DigitalOcean droplet configuration
2. Repository configuration
3. Building the Windows `.exe` installer

## Project Structure

```
IONE-VPN/
├── backend/                 # Node.js/Express API
│   ├── src/
│   │   ├── app.js           # Entry point
│   │   ├── config/          # DB, Redis, logger
│   │   ├── controllers/     # auth, vpn, server, device, admin
│   │   ├── middleware/       # JWT auth, rate limiting, error handler
│   │   ├── models/          # User, Device (Mongoose)
│   │   ├── routes/          # REST endpoints
│   │   └── services/        # WireGuard, OpenVPN, server monitor
│   ├── .env.example         # Template – copy to .env and fill in
│   └── Dockerfile
│
├── flutter_app/             # Flutter cross-platform client
│   ├── lib/
│   │   ├── constants/       # Theme, app-wide constants
│   │   ├── models/          # Server, User, ConnectionStats
│   │   ├── providers/       # VPN state, Auth state, Theme
│   │   ├── screens/         # Splash, Login, Home, Servers, Settings, Subscription
│   │   ├── services/        # API client (Dio)
│   │   └── widgets/         # ConnectButton, SpeedMeter, ServerTile
│   └── pubspec.yaml
│
├── deploy/
│   ├── setup_server.sh      # Full droplet setup (run as root)
│   ├── wireguard_setup.sh   # WireGuard key generation & config
│   ├── nginx.conf           # Nginx reverse proxy config
│   ├── docker-compose.yml   # Optional Docker deployment
│   └── windows_installer.iss # Inno Setup script → .exe installer
│
└── SETUP.md                 # ← Complete setup documentation
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/auth/register` | Create account |
| POST | `/api/v1/auth/login` | Sign in, receive JWT |
| GET  | `/api/v1/auth/me` | Current user info |
| POST | `/api/v1/vpn/config` | Generate WireGuard/OpenVPN config |
| POST | `/api/v1/vpn/connect` | Record connect event |
| POST | `/api/v1/vpn/disconnect` | Record disconnect event |
| GET  | `/api/v1/servers` | List VPN servers |
| GET  | `/api/v1/servers/recommend` | AI-recommended server |
| GET  | `/api/v1/devices` | List user's devices |
| DELETE | `/api/v1/devices/:id` | Revoke a device |
| GET  | `/api/v1/admin/dashboard` | Admin stats (admin only) |

## Tech Stack

| Layer | Technology |
|-------|-----------|
| VPN Protocol | WireGuard (primary), OpenVPN |
| Backend | Node.js 20, Express 4, MongoDB 7, Redis 7 |
| Auth | JWT (access + refresh tokens) |
| Frontend | Flutter 3.19+ |
| Server | DigitalOcean (Singapore), Nginx reverse proxy |
| Process Manager | PM2 |
| Subscriptions | Stripe (configured via `.env`) |

## License

MIT