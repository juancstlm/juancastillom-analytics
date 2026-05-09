# juancastillom-analytics

Self-hosted [Umami](https://umami.is) analytics for `*.juancastillom.com` and other personal sites, exposed at `https://analytics.juancastillom.com` via a Cloudflare Tunnel.

A single Umami instance serves many sites — each site gets its own Website ID inside the Umami dashboard.

## Architecture

```
   Browser on any site
          |
          v  https
  analytics.juancastillom.com  (Cloudflare edge, TLS terminated here)
          |
          v  Cloudflare Tunnel (outbound from LXC, no open ports)
       cloudflared  ->  umami:3000  ->  postgres
```

Runs as three containers in one Docker Compose stack on a Proxmox LXC:

- `umami` — the Umami app
- `db` — Postgres 15, data persisted to `./umami-db`
- `cloudflared` — Cloudflare tunnel, no inbound ports needed

## Quick install on Proxmox

Run this on the **Proxmox host** as root. It creates an unprivileged Debian 12 LXC, installs Docker, clones this repo, writes `.env`, and brings up the stack.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/juancstlm/juancastillom-analytics/main/install.sh)"
```

You'll be prompted for VMID, hostname, storage, network, and the three secrets (`APP_SECRET` and `DB_PASSWORD` can be auto-generated; `TUNNEL_TOKEN` you paste from Cloudflare Zero Trust). Create the Cloudflare Tunnel **before** running the script so you have a token ready — see [step 1 below](#1-create-the-cloudflare-tunnel).

After the script finishes, jump to [step 4](#4-log-in-to-umami) to change the default admin password.

## Manual setup

### 1. Create the Cloudflare Tunnel

Cloudflare dashboard -> Zero Trust -> Networks -> Connectors -> Create tunnel -> Cloudflared.

Copy the tunnel token. Then under **Public Hostname** add:

- Subdomain: `analytics`
- Domain: `juancastillom.com`
- Service: `http://umami:3000`

Cloudflare creates the `analytics.juancastillom.com` CNAME automatically.

### 2. Configure env vars

```bash
cp .env.example .env
# edit .env and fill in DB_PASSWORD, APP_SECRET, TUNNEL_TOKEN
# generate APP_SECRET with: openssl rand -base64 48
```

### 3. Start the stack

```bash
docker compose up -d
docker compose logs -f
```

### 4. Log in to Umami

Open `https://analytics.juancastillom.com`. Default credentials:

- Username: `admin`
- Password: `umami`

**Change the admin password immediately** under Settings -> Profile.

## Adding a new site

1. In Umami: **Settings -> Websites -> Add website**. Set name and domain.
2. Copy the **Website ID** (UUID).
3. On the site, load the tracker. For Next.js:

   ```tsx
   import Script from 'next/script';

   <Script
     src="https://analytics.juancastillom.com/script.js"
     data-website-id="WEBSITE-UUID-HERE"
     strategy="afterInteractive"
   />
   ```

   For plain HTML:

   ```html
   <script
     defer
     src="https://analytics.juancastillom.com/script.js"
     data-website-id="WEBSITE-UUID-HERE"
   ></script>
   ```

If `TRACKER_SCRIPT_NAME` in `.env` is changed (e.g. to dodge adblockers), update the `src` to match (e.g. `/stuff.js`).

## Backups

Postgres data lives in `./umami-db`. Run `./backups/backup.sh` to write a gzipped dump to `./backups/`. Schedule via cron:

```
0 3 * * * cd /opt/juancastillom-analytics && ./backups/backup.sh >> /var/log/umami-backup.log 2>&1
```

Restore with:

```bash
gunzip -c backups/umami-YYYYMMDD-HHMMSS.sql.gz | docker compose exec -T db psql -U umami -d umami
```

## Rotating the tunnel token

1. Cloudflare Zero Trust -> Tunnels -> select tunnel -> Configure -> rotate token.
2. Update `TUNNEL_TOKEN` in `.env`.
3. `docker compose up -d cloudflared` to recreate the container.

## Upgrading Umami

```bash
docker compose pull
docker compose up -d
```

Umami runs DB migrations on startup. Take a backup first.

## Files

- `docker-compose.yml` — the three-service stack
- `.env.example` — template for required env vars
- `install.sh` — one-shot Proxmox installer (creates the LXC and bootstraps everything)
- `backups/backup.sh` — gzipped `pg_dump`, keeps the last 30 dumps

