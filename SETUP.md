# IONE VPN – Complete Setup Guide

This document walks you through **everything** you need to do to go from zero to a fully working IONE VPN installation:

1. Preparing your DigitalOcean Singapore droplet (server)
2. Editing the repository configuration
3. Building the Windows desktop app (`.exe` installer)

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Part 1 – Droplet Setup (Server)](#part-1--droplet-setup-server)
  - [1.1 Create the droplet](#11-create-the-droplet)
  - [1.2 Run the automated setup script](#12-run-the-automated-setup-script)
  - [1.3 Configure WireGuard](#13-configure-wireguard)
  - [1.4 Edit the backend `.env` file](#14-edit-the-backend-env-file)
  - [1.5 Start the API server](#15-start-the-api-server)
  - [1.6 (Optional) Add HTTPS with Let's Encrypt](#16-optional-add-https-with-lets-encrypt)
- [Part 2 – Repository Configuration](#part-2--repository-configuration)
  - [2.1 Clone the repo](#21-clone-the-repo)
  - [2.2 Set the API base URL in the Flutter app](#22-set-the-api-base-url-in-the-flutter-app)
  - [2.3 Verify backend runs locally (optional)](#23-verify-backend-runs-locally-optional)
- [Part 3 – Building the Windows Executable](#part-3--building-the-windows-executable)
  - [3.1 Install Flutter on your PC](#31-install-flutter-on-your-pc)
  - [3.2 Build the Windows app](#32-build-the-windows-app)
  - [3.3 Create an installer with Inno Setup](#33-create-an-installer-with-inno-setup)
  - [3.4 Run IONE VPN on your PC](#34-run-ione-vpn-on-your-pc)
- [Part 4 – Multi-Device Setup](#part-4--multi-device-setup)
- [Part 5 – Troubleshooting](#part-5--troubleshooting)
- [Environment Variable Reference](#environment-variable-reference)

---

## Prerequisites

| Tool | Where to get it | Required for |
|------|----------------|-------------|
| DigitalOcean account | [digitalocean.com](https://digitalocean.com) | Server |
| SSH key pair | `ssh-keygen -t ed25519` | Server access |
| Git | [git-scm.com](https://git-scm.com) | All |
| Flutter SDK 3.19+ | [flutter.dev/docs/get-started/install](https://flutter.dev/docs/get-started/install) | Windows app |
| Visual Studio 2022 (Desktop workload) | [visualstudio.microsoft.com](https://visualstudio.microsoft.com) | Windows build |
| Inno Setup 6 *(optional)* | [jrsoftware.org/isinfo.php](https://jrsoftware.org/isinfo.php) | `.exe` installer |

---

## Part 1 – Droplet Setup (Server)

### 1.1 Create the droplet

1. Log in to [cloud.digitalocean.com](https://cloud.digitalocean.com).
2. Click **Create → Droplets**.
3. Choose:
   - **Region:** Singapore (`SGP1`)
   - **Image:** Ubuntu 22.04 LTS (x64)
   - **Size:** at minimum **Basic – 2 GB RAM / 1 vCPU / 50 GB SSD** (handles 10 simultaneous devices comfortably)
   - **Authentication:** add your SSH public key
4. Click **Create Droplet** and note the **IPv4 address** — you will need it throughout this guide.  
   We refer to it as `<DROPLET_IP>` below.

### 1.2 Run the automated setup script

SSH into your droplet as `root`, then run the one-line setup:

```bash
ssh root@<DROPLET_IP>

# On the droplet:
git clone https://github.com/ione2025/IONE-VPN.git /opt/ione-vpn
bash /opt/ione-vpn/deploy/setup_server.sh
```

The script automatically installs:
- Node.js 20, PM2
- MongoDB 7
- Redis 7
- Nginx
- WireGuard + tools
- OpenVPN + Easy-RSA
- UFW firewall (opens ports 22, 80, 443, **51820/udp**, 1194/udp)

> **Expected duration:** ~5–10 minutes on a fresh droplet.

### 1.3 Configure WireGuard

After `setup_server.sh` completes, run the WireGuard configuration script:

```bash
bash /opt/ione-vpn/deploy/wireguard_setup.sh
```

At the end it prints three values — **copy them now**, you need them in the next step:

```
WG_SERVER_PRIVATE_KEY=<generated_value>
WG_SERVER_PUBLIC_KEY=<generated_value>
WG_SERVER_ENDPOINT=<DROPLET_IP>:51820
```

### 1.4 Edit the backend `.env` file

```bash
cp /opt/ione-vpn/backend/.env.example /opt/ione-vpn/backend/.env
nano /opt/ione-vpn/backend/.env
```

Fill in **every** value marked with `<...>`. The critical ones are:

| Variable | What to put |
|----------|-------------|
| `MONGODB_URI` | `mongodb://localhost:27017/ione_vpn` |
| `REDIS_HOST` | `127.0.0.1` |
| `REDIS_PASSWORD` | The password you set in `/etc/redis/redis.conf` (step 1.2 sets it to `CHANGE_THIS_REDIS_PASSWORD` — change it!) |
| `JWT_SECRET` | A random 64-character string. Generate with: `openssl rand -hex 32` |
| `JWT_REFRESH_SECRET` | Another random 64-character string |
| `WG_SERVER_PRIVATE_KEY` | Printed by `wireguard_setup.sh` |
| `WG_SERVER_PUBLIC_KEY` | Printed by `wireguard_setup.sh` |
| `WG_SERVER_ENDPOINT` | `<DROPLET_IP>:51820` |
| `SERVER_IP` | Your droplet's IPv4 address |
| `ADMIN_EMAIL` | Your admin email |
| `ADMIN_PASSWORD` | A strong admin password |

Save the file (`Ctrl+X → Y → Enter` in nano).

### 1.5 Start the API server

```bash
cd /opt/ione-vpn/backend
npm ci --omit=dev

# Start with PM2 so it survives reboots
pm2 start src/app.js --name ione-vpn-api
pm2 save
pm2 logs ione-vpn-api   # verify it started successfully
```

Test the API is running:

```bash
curl http://localhost:3000/health
# Expected: {"status":"ok","app":"IONE VPN","version":"1.0.0"}
```

Copy the Nginx config and reload:

```bash
cp /opt/ione-vpn/deploy/nginx.conf /etc/nginx/sites-available/ione-vpn
# Edit the file and replace YOUR_DOMAIN_OR_IP with your actual droplet IP
sed -i "s/YOUR_DOMAIN_OR_IP/<DROPLET_IP>/" /etc/nginx/sites-available/ione-vpn
ln -sf /etc/nginx/sites-available/ione-vpn /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

Test from your local machine:

```bash
curl http://<DROPLET_IP>/health
# Expected: {"status":"ok","app":"IONE VPN","version":"1.0.0"}
```

### 1.6 (Optional) Add HTTPS with Let's Encrypt

If you have a domain pointed to the droplet:

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d yourdomain.com
```

Then uncomment the HTTPS block in `/etc/nginx/sites-available/ione-vpn` and reload Nginx.

---

## Part 2 – Repository Configuration

### 2.1 Clone the repo

On your **development PC** (not the droplet):

```bash
git clone https://github.com/ione2025/IONE-VPN.git
cd IONE-VPN
```

### 2.2 Set the API base URL in the Flutter app

Open `flutter_app/lib/constants/app_constants.dart` and update the one line:

```dart
// BEFORE:
static const String apiBaseUrl = 'https://YOUR_DROPLET_IP_OR_DOMAIN/api/v1';

// AFTER (use http:// if you haven't set up TLS yet):
static const String apiBaseUrl = 'http://<DROPLET_IP>/api/v1';
// OR with a domain + HTTPS:
static const String apiBaseUrl = 'https://yourdomain.com/api/v1';
```

Save the file.

### 2.3 Verify backend runs locally (optional)

You can run the backend locally for development (requires MongoDB and Redis installed locally):

```bash
cd backend
cp .env.example .env
# Edit .env with local values (keep WG_ variables empty for local dev)
npm install
npm run dev
# API available at http://localhost:3000
```

---

## Part 3 – Building the Windows Executable

### 3.1 Install Flutter on your PC

1. Download Flutter from [flutter.dev/docs/get-started/install/windows](https://docs.flutter.dev/get-started/install/windows).
2. Extract to `C:\flutter` (or any path **without spaces**).
3. Add `C:\flutter\bin` to your `PATH` environment variable.
4. Install **Visual Studio 2022** with the **"Desktop development with C++"** workload.
5. Open a new PowerShell window and verify:

```powershell
flutter doctor
```

All checks should pass (you can ignore Android/iOS items for Windows-only builds).

### 3.2 Build the Windows app

```powershell
cd IONE-VPN\flutter_app

# Get dependencies
flutter pub get

# Build the Windows release
flutter build windows --release
```

The output is placed in:
```
flutter_app\build\windows\x64\runner\Release\
```

That folder contains `ione_vpn.exe` and all required DLLs. You can copy this entire folder to any Windows 10/11 PC and run it directly.

### 3.3 Create an installer with Inno Setup

For a proper `.exe` installer that installs IONE VPN like a regular Windows application:

1. Install **Inno Setup 6** from [jrsoftware.org/isinfo.php](https://jrsoftware.org/isinfo.php).
2. Open Inno Setup and **create a new script** with the wizard:
   - **Application name:** `IONE VPN`
   - **Application version:** `1.0.0`
   - **Application folder:** leave as default (`Program Files\IONE VPN`)
   - **Main executable:** browse to `flutter_app\build\windows\x64\runner\Release\ione_vpn.exe`
   - **Include all files in the folder:** yes (this includes the required DLLs)
   - **Create a desktop shortcut:** yes
   - **Output folder:** choose a folder for the final `.exe`
   - **Output base filename:** `IONE_VPN_Setup`
3. Click **Compile** (`Ctrl+F9`).
4. Your installer is created as `IONE_VPN_Setup.exe`.

Alternatively, use the ready-made script below. Save it as `deploy\windows_installer.iss` and compile it with Inno Setup:

```iss
[Setup]
AppName=IONE VPN
AppVersion=1.0.0
AppPublisher=IONE
DefaultDirName={autopf}\IONE VPN
DefaultGroupName=IONE VPN
OutputDir=..\dist
OutputBaseFilename=IONE_VPN_Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\flutter_app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs

[Icons]
Name: "{group}\IONE VPN"; Filename: "{app}\ione_vpn.exe"
Name: "{commondesktop}\IONE VPN"; Filename: "{app}\ione_vpn.exe"

[Run]
Filename: "{app}\ione_vpn.exe"; Description: "Launch IONE VPN"; Flags: nowait postinstall skipifsilent
```

### 3.4 Run IONE VPN on your PC

1. Double-click `IONE_VPN_Setup.exe` and follow the wizard.
2. Launch **IONE VPN** from the desktop shortcut or Start menu.
3. Register a new account (or log in if you already have one).
4. Press **Connect** — the app will call your droplet API, receive a WireGuard config, and establish the tunnel.

> **Windows note:** The WireGuard tunnel on Windows requires the **WireGuard for Windows** client (`wireguard.exe`) to manage the kernel tunnel driver. IONE VPN hands off the generated `.conf` file to WireGuard for Windows automatically. Install it from [wireguard.com/install](https://www.wireguard.com/install/).

---

## Part 4 – Multi-Device Setup

IONE VPN supports up to 10 simultaneous devices on a Premium subscription.

Each device generates its own WireGuard key pair the first time it connects. The backend assigns a unique IP address in the `10.8.0.0/24` subnet per device.

To add a new device:
1. Install the IONE VPN app on the new device.
2. Log in with the **same account**.
3. Press **Connect** — a new device config is automatically generated and registered.

To manage or revoke devices:
- **In the app:** Settings → Devices → Revoke
- **Via API:** `DELETE /api/v1/devices/:deviceId` (with auth token)
- **Admin dashboard:** `GET /api/v1/admin/dashboard`

---

## Part 5 – Troubleshooting

### API returns connection refused

- Check PM2: `pm2 status` and `pm2 logs ione-vpn-api`
- Check Nginx: `systemctl status nginx`
- Check MongoDB: `systemctl status mongod`
- Check port 3000: `ss -tlnp | grep 3000`

### WireGuard won't start

```bash
journalctl -xeu wg-quick@wg0
# Most common cause: IP forwarding not enabled
sysctl net.ipv4.ip_forward   # must return 1
```

### Flutter build fails (`flutter doctor` errors)

- Ensure Visual Studio 2022 with "Desktop development with C++" workload is installed.
- Run `flutter config --enable-windows-desktop` once.
- Delete `flutter_app\build\` and retry.

### Cannot connect from the app

1. Confirm the droplet firewall allows UDP 51820: `ufw status`
2. Confirm WireGuard is running: `wg show`
3. Confirm `apiBaseUrl` in `app_constants.dart` matches your droplet's address.

---

## Environment Variable Reference

Full list of variables for `backend/.env`:

| Variable | Description | Example |
|----------|-------------|---------|
| `PORT` | API listen port | `3000` |
| `NODE_ENV` | Environment | `production` |
| `MONGODB_URI` | MongoDB connection string | `mongodb://localhost:27017/ione_vpn` |
| `REDIS_HOST` | Redis host | `127.0.0.1` |
| `REDIS_PORT` | Redis port | `6379` |
| `REDIS_PASSWORD` | Redis auth password | `your_redis_password` |
| `JWT_SECRET` | Access token signing secret (64+ chars) | `openssl rand -hex 32` |
| `JWT_EXPIRES_IN` | Access token lifetime | `7d` |
| `JWT_REFRESH_SECRET` | Refresh token signing secret (64+ chars) | `openssl rand -hex 32` |
| `JWT_REFRESH_EXPIRES_IN` | Refresh token lifetime | `30d` |
| `WG_INTERFACE` | WireGuard interface name | `wg0` |
| `WG_CONFIG_DIR` | WireGuard config directory | `/etc/wireguard` |
| `WG_SERVER_PUBLIC_KEY` | Server WireGuard public key | output of `wireguard_setup.sh` |
| `WG_SERVER_PRIVATE_KEY` | Server WireGuard private key | output of `wireguard_setup.sh` |
| `WG_SERVER_ENDPOINT` | Public endpoint for clients | `<DROPLET_IP>:51820` |
| `WG_SUBNET` | VPN subnet | `10.8.0.0/24` |
| `WG_DNS` | DNS servers pushed to clients | `1.1.1.1,1.0.0.1` |
| `SERVER_IP` | Droplet public IPv4 | `<DROPLET_IP>` |
| `SERVER_REGION` | Human-readable region label | `Singapore` |
| `STRIPE_SECRET_KEY` | Stripe secret key (subscriptions) | `sk_live_...` |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook secret | `whsec_...` |
| `ADMIN_EMAIL` | Admin account email | `admin@yourdomain.com` |
| `ADMIN_PASSWORD` | Admin account password | strong password |
| `RATE_LIMIT_WINDOW_MS` | Rate limit window in ms | `900000` (15 min) |
| `RATE_LIMIT_MAX` | Max requests per window (general) | `100` |
| `AUTH_RATE_LIMIT_MAX` | Max login attempts per window | `10` |
