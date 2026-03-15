// PM2 ecosystem config for IONE VPN backend.
// Deploy: cp deploy/ecosystem.config.js /opt/ione-vpn/
//         cd /opt/ione-vpn && pm2 start ecosystem.config.js --env production
// Update: pm2 reload ecosystem.config.js --env production

module.exports = {
  apps: [
    {
      name: 'ione-vpn',
      script: 'src/app.js',
      cwd: '/opt/ione-vpn/backend',

      // ── Clustering ─────────────────────────────────────────────────────────
      // 'max' spawns one worker per vCPU. On a 1-vCPU droplet this equals 1
      // but the setting is portable — upgrade the droplet and it scales automatically.
      instances: 'max',
      exec_mode: 'cluster',

      // ── Environment ────────────────────────────────────────────────────────
      env_production: {
        NODE_ENV: 'production',
        // All secrets loaded from /opt/ione-vpn/backend/.env via dotenv.
      },

      // ── Stability ──────────────────────────────────────────────────────────
      // Restart the process if it exceeds 512 MB (prevents slow OOM)
      max_memory_restart: '512M',
      // Restart delay (ms) between crash-restart loops to avoid thrashing
      restart_delay: 2000,
      // Number of consecutive crash-restarts before PM2 stops retrying
      max_restarts: 15,
      // Keep unstable processes alive at least 5 s before counting a crash
      min_uptime: '5s',
      // Kill the old process cleanly on reload (avoids zombie connections)
      kill_timeout: 5000,

      // ── Logging ────────────────────────────────────────────────────────────
      // Log to structured JSON files; pm2-logrotate (installed below) will
      // rotate them daily so they never fill the disk.
      out_file: '/root/.pm2/logs/ione-vpn-out.log',
      error_file: '/root/.pm2/logs/ione-vpn-error.log',
      merge_logs: true,           // single log stream across cluster workers
      log_date_format: 'YYYY-MM-DD HH:mm:ss Z',

      // ── Health ─────────────────────────────────────────────────────────────
      // PM2 sends SIGINT then SIGKILL; app's graceful shutdown handles them.
      wait_ready: false,
      listen_timeout: 8000,

      // ── Watch ──────────────────────────────────────────────────────────────
      watch: false,               // never watch in production
    },
  ],
};
