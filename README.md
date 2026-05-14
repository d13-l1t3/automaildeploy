# AutoMailDeploy

Automated, single-server enterprise email infrastructure deployed via Docker Compose.

**Stack:** Postfix · Dovecot · Rspamd · Roundcube · Nginx · Let's Encrypt · Redis · MariaDB

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/d13-l1t3/automaildeploy.git
cd automaildeploy

# 2. Create and edit your configuration
cp .env.example .env
nano .env   # fill in domain, passwords, mailboxes

# 3. Run the installer (as root)
sudo bash install.sh

# 4. Add the DNS records printed at the end of installation
```

## Repository Structure

```
automaildeploy/
├── .env.example                         # Configuration template
├── .gitignore
├── install.sh                           # Main installation script
├── manage_users.sh                      # Mailbox management (add/remove/passwd)
├── docker-compose.yml                   # Service orchestration
├── docker/
│   ├── postfix/
│   │   ├── Dockerfile
│   │   └── entrypoint.sh
│   └── dovecot/
│       ├── Dockerfile
│       └── entrypoint.sh
├── config/
│   ├── postfix/
│   │   ├── main.cf.template
│   │   └── master.cf.template
│   ├── dovecot/
│   │   ├── dovecot.conf.template
│   │   └── passwd
│   ├── nginx/
│   │   ├── nginx.conf
│   │   └── mail.conf.template
│   ├── rspamd/
│   │   ├── local.d/
│   │   │   ├── worker-proxy.inc
│   │   │   ├── worker-normal.inc
│   │   │   ├── worker-controller.inc.template
│   │   │   ├── redis.conf
│   │   │   ├── dkim_signing.conf.template
│   │   │   ├── milter_headers.conf
│   │   │   ├── actions.conf
│   │   │   └── classifier-bayes.conf
│   │   └── override.d/
│   │       └── milter_headers.conf
│   ├── roundcube/
│   │   └── config.inc.php.template
│   └── ssl/                             # (generated — TLS certs)
├── dkim/                                # (generated — DKIM keys)
└── data/                                # (generated — runtime volumes)
```

## Configuration

All settings live in a single **`.env`** file. Key variables:

| Variable | Description |
|---|---|
| `MAIL_DOMAIN` | Primary domain (e.g. `example.com`) |
| `MAIL_HOSTNAME` | Mail server FQDN (e.g. `mail.example.com`) |
| `SERVER_IP` | Public IPv4 of the server |
| `ADMIN_USER` / `ADMIN_PASSWORD` | Default admin mailbox |
| `EXTRA_USERS` | Additional users as `user1:pass1,user2:pass2` |
| `MYSQL_*` | MariaDB credentials for Roundcube |
| `RSPAMD_PASSWORD` | Rspamd web UI password |
| `ROUNDCUBE_DES_KEY` | 24-char encryption key for Roundcube |

## User Management

```bash
sudo ./manage_users.sh add    john  'SecureP@ss'    # Create mailbox
sudo ./manage_users.sh remove john                   # Remove mailbox
sudo ./manage_users.sh passwd john  'NewP@ss'        # Change password
sudo ./manage_users.sh list                          # List all mailboxes
```

## Security Features

- **TLS 1.2+ only** on all services (SMTP, IMAP, HTTPS)
- **No open relay** — submission/smtps require SASL authentication
- **DKIM signing** via Rspamd with auto-generated 2048-bit RSA key
- **SPF, DMARC** records generated and printed post-install
- **Rspamd** with Bayes classifier, greylisting, and configurable thresholds
- **Network isolation** — all containers on a single Docker bridge network
- **HSTS** and security headers on Nginx
- **Auto-renewal** of TLS certificates via Certbot deploy hook

## DNS Records

After installation, `install.sh` prints the exact DNS records to add. They are also saved to `DNS_RECORDS.txt` for reference.

## License

MIT
