# Darb: operations runbook

## First deploy (one Contabo VPS 8, Germany, Ubuntu 24.04)
1. On the server:
   - install Docker;
   - `ufw allow 22,443/tcp` and allow port 80 only from Cloudflare's ranges (or close it);
   - `git archive` the `darb/` tree to `/opt/darb/src`.
2. `cp darb/deploy/.env.example /opt/darb/.env` and fill it:
   - secrets: Django secret, Postgres password, `ANTHROPIC_API_KEY`, `DARB_PACK_KEK`;
   - RevenueCat webhook auth and v1 key, Google client ids, the Apple key file, SMTP, `SENTRY_DSN`;
   - R2 for pgBackRest; set `ARCHIVE_MODE=on`.
   - Then `chmod 600`.
3. **TLS:** in Cloudflare, SSL/TLS = Full (strict). Create an Origin Certificate (15 years). Put `origin.pem`,
   `origin.key` and a `server.conf` in `deploy/tls/`:
   ```nginx
   server { listen 443 ssl; http2 on; server_name darbedu.sa;
            ssl_certificate /etc/nginx/tls/origin.pem; ssl_certificate_key /etc/nginx/tls/origin.key;
            include /etc/nginx/darb-locations.conf; }
   ```
4. Start: `docker compose --env-file /opt/darb/.env up -d --build --profile backup`, then
   `docker compose exec api python manage.py createsuperuser` (your admin login).
5. **Cloudflare:**
   - DNS `darbedu.sa` proxied; `cdn.darbedu.sa` = the R2 bucket's custom domain;
   - one rate-limit rule (`/api/` per IP);
   - **Cloudflare Access** (free up to 50 users) on `darbedu.sa/darb-admin/*`, allowing your email only.
6. **Monitoring:**
   - Better Stack monitor on `https://darbedu.sa/api/health?deep=1` every 3 min (email/Slack);
   - Sentry gets backend errors, including the **AI spend alert**: an error when 24 h of AI passes `daily_spend_alert_usd`
     (admin → Config).
7. **Packs:** `manage.py packs build <slug> --out /tmp/packs`, upload to R2 (`packs/<slug>/...`),
   then `manage.py packs publish <slug>`.

## Routine
| What | How often | How |
|---|---|---|
| Backups | daily (full on Sundays, differential otherwise) + continuous WAL | `backup` service (pgBackRest → R2, encrypted, 5 fulls kept). Check `docker compose exec -u postgres db pgbackrest --stanza=darb info` weekly |
| Restore drill | before launch, then quarterly | `darb/deploy/tests/restore-test.sh` (on a spare VPS against R2), result into DARB-RESTORE.md |
| Review-log partitions | automatic (worker, hourly) | 14 months back, 2 ahead |
| AI spend | daily glance | admin → AI calls (month total, per paying account, top accounts) |
| Mistake reports | daily | admin → Reports → fix the item (admin → Pack items), "Fixed: tell the student" |
| Suspensions | when Sentry/admin shows them | admin → Accounts → filter inactive; restore after an appeal (support email) |
| Cloudflare CA changes | when Cloudflare announces | the app pins Cloudflare's CA roots (DARB-SECURITY.md): a new CA needs an app update first |
| Scaling | when a trigger fires | DARB-INFRA.md → Upgrade path |

## Incidents
- **Data breach (PDPL):** contain (rotate `DJANGO_SECRET_KEY`, revoke device tokens: `Device.objects.all().delete()`
  signs everyone out), assess, **notify SDAIA within 72 hours** where harm is possible, tell affected students and
  guardians, and log everything. A notice template is with the lawyer (DARB-PDPL.md).
- **Database lost:** restore from R2: `pgbackrest --stanza=darb restore` into an empty volume (the restore drill script
  shows every step); about 1 minute of writes can be lost (archive_timeout 60 s).
- **AI provider down:** students keep studying; AI features show "needs connection" and nothing is charged.
- **Processing records:** kept for the life of the processing plus 5 years (IR Art. 33). The admin's AI-call and
  report tables plus the backup logs are the record.
