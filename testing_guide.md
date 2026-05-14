# AutoMailDeploy — Testing & Demo Guide

## Overview

This guide walks through a full deployment and verification of AutoMailDeploy — an automated, containerized enterprise mail server. It covers installation, automated testing, and manual functional verification of all components.

**Stack:** Postfix · Dovecot · Rspamd · Roundcube · Nginx · MariaDB · Redis

---

## Part 1: Installation (Fresh Deploy)

### 1.1 — Prerequisites

- A Linux server (Debian/Ubuntu) with root access
- Docker will be installed automatically if not present
- Ports 25, 80, 143, 443, 465, 587, 993, 4190 available

### 1.2 — Configure

```bash
git clone https://github.com/d13-l1t3/automaildeploy.git
cd automaildeploy
cp .env.example .env
nano .env
```

For local/VM testing, use these values:

```env
MAIL_DOMAIN=test.local
MAIL_HOSTNAME=mail.test.local
SERVER_IP=192.168.1.100

LETSENCRYPT_EMAIL=test@test.local
LETSENCRYPT_STAGING=true

ADMIN_USER=admin
ADMIN_PASSWORD=TestAdmin123!

EXTRA_USERS=john:John_Pass!123,jane:Jane_Pass!456

MYSQL_ROOT_PASSWORD=TestRootDB123!
MYSQL_DATABASE=roundcubemail
MYSQL_USER=roundcube
MYSQL_PASSWORD=TestRcubeDB123!

RSPAMD_PASSWORD=TestRspamd123!

ROUNDCUBE_DES_KEY=abcdef1234567890abcdef12

DOCKER_SUBNET=172.28.0.0/16
TZ=UTC
```

> **Note:** For `.local` / `.test` domains, the installer automatically generates a self-signed TLS certificate. For production with a real domain, set `LETSENCRYPT_STAGING=false`.

### 1.3 — Install

```bash
sudo bash install.sh
```

The installer will:
1. Install Docker and Certbot (if missing)
2. Generate or obtain TLS certificates
3. Generate a 2048-bit DKIM key pair
4. Render all service configs from templates
5. Build and start 7 Docker containers
6. Print the DNS records needed for the domain

After installation completes, wait ~15 seconds for all services to initialize:

```bash
sleep 15
```

---

## Part 2: Automated Test Suite

Run the comprehensive 14-point test suite:

```bash
sudo bash run_tests.sh
```

### What It Tests

| #  | Test | What It Verifies |
|----|------|-----------------|
| 1  | Container Health | All 7 containers running |
| 2  | SSL/TLS Endpoints | IMAPS (993), SMTPS (465), Submission (587) handshakes |
| 3  | IMAP Authentication | Login with correct creds succeeds, wrong creds rejected |
| 4  | Anti-Relay Protection | Server refuses to relay mail for external recipients |
| 5  | Mail Delivery (self) | Admin can send email to themselves |
| 6  | Cross-User Delivery | Admin can send email to another user |
| 7  | Rspamd Milter | Rspamd is connected to Postfix, no permission errors |
| 8  | GTUBE Spam Rejection | Known spam test pattern is detected and rejected |
| 9  | DKIM Signing | DKIM key exists, config is correct, key is accessible |
| 10 | User Management | Add, list, and remove mailbox via `manage_users.sh` |
| 11 | Nginx Proxy | HTTP→HTTPS redirect, Roundcube & Rspamd UI accessible |
| 12 | Dovecot Sieve | Default spam-to-Junk filter script is deployed |
| 13 | SMTP Banner | Correct hostname shown, software version hidden |
| 14 | MariaDB & Roundcube | Database connection works, Roundcube tables exist |

### Expected Output

```
  Passed:  35
  Failed:  0
  Warnings: 0

  All critical tests passed! ✔
```

---

## Part 3: Manual Demonstrations

These are step-by-step demos suitable for a live walkthrough or recording.

### Demo 1 — Verify Running Infrastructure

Show all containers are healthy:

```bash
sudo docker compose ps
```

Expected: all 7 containers show status `Up`.

### Demo 2 — Send and Receive Email (SMTP → LMTP → Maildir)

Send a test email from admin to admin:

```bash
sudo docker compose exec postfix bash -c \
  'printf "Subject: Hello from AutoMailDeploy\nFrom: admin@test.local\nTo: admin@test.local\n\nThis message was delivered through Postfix -> Rspamd -> Dovecot LMTP.\n" | sendmail -t'
```

Wait a moment, then verify delivery:

```bash
sleep 3
sudo docker compose exec dovecot sh -c \
  'find /var/vmail/test.local/admin/Maildir/ -path "*/new/*" -type f -exec head -20 {} \;'
```

You should see the full email with headers including `X-Spamd-Bar` (Rspamd's spam score indicator).

### Demo 3 — Cross-User Email Delivery

Send from admin to john:

```bash
sudo docker compose exec postfix bash -c \
  'printf "Subject: Cross-user test\nFrom: admin@test.local\nTo: john@test.local\n\nThis email was delivered to a different mailbox.\n" | sendmail -t'
```

Verify john received it:

```bash
sleep 3
sudo docker compose exec dovecot sh -c \
  'find /var/vmail/test.local/john/Maildir/ -path "*/new/*" -type f | wc -l'
```

### Demo 4 — IMAP Login (Encrypted)

Connect to the IMAP server over TLS and authenticate:

```bash
openssl s_client -connect localhost:993 -quiet
```

Once connected, type:

```
a1 LOGIN admin@test.local "TestAdmin123!"
a2 LIST "" "*"
a3 SELECT INBOX
a4 LOGOUT
```

You should see:
- `a1 OK Logged in` — authentication succeeded
- Folder listing (INBOX, Sent, Drafts, Junk, Trash, Archive)
- `a3 OK` with message count in INBOX

### Demo 5 — Anti-Relay Protection

Verify the server refuses to relay email to external addresses:

```bash
sudo docker compose exec postfix bash -c '
  (sleep 0.5; printf "EHLO test.com\r\n";
   sleep 0.5; printf "MAIL FROM:<spammer@evil.com>\r\n";
   sleep 0.5; printf "RCPT TO:<someone@gmail.com>\r\n";
   sleep 0.5; printf "QUIT\r\n"; sleep 0.3
  ) | nc localhost 25'
```

Expected: `554 5.7.1 <someone@gmail.com>: Relay access denied`

### Demo 6 — Spam Rejection (GTUBE Test)

Send an email containing the GTUBE pattern — a standardized test string that all spam filters must reject:

```bash
sudo docker compose exec postfix bash -c \
  'printf "Subject: GTUBE Spam Test\nFrom: admin@test.local\nTo: admin@test.local\n\nXJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X\n" | sendmail -t'
```

Check Rspamd detected and rejected it:

```bash
sudo docker compose logs rspamd 2>&1 | grep -i "gtube"
```

Expected: Rspamd shows the GTUBE symbol with score 1000+ and action "reject".

Verify it did NOT land in the mailbox:

```bash
sudo docker compose exec postfix cat /var/log/mail.log | grep "GTUBE" | tail -3
```

Expected: `status=bounced (Gtube pattern)`

### Demo 7 — Rspamd Scan Engine (Direct)

Scan a crafted spam message directly with Rspamd, without sending it through Postfix:

```bash
sudo docker compose exec rspamd bash -c '
echo "From: spammer@evil.com
To: victim@test.local
Subject: BUY CHEAP PILLS NOW!!!

BUY NOW! FREE ROLEX! Click: http://malware.example.com
You have WON \$1,000,000! Send your bank details!
XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X" | rspamc'
```

This shows the full Rspamd analysis: every rule that matched, individual scores, and the final action (reject/add header/greylist).

### Demo 8 — DKIM Key Verification

Show the DKIM private key exists and is configured:

```bash
# Key on host
ls -la dkim/

# Key accessible inside Rspamd container
sudo docker compose exec rspamd ls -la /dkim/

# DKIM signing config
sudo docker compose exec rspamd cat /etc/rspamd/local.d/dkim_signing.conf
```

### Demo 9 — User Management (CRUD)

```bash
# List all mailboxes
sudo ./manage_users.sh list

# Create a new mailbox
sudo ./manage_users.sh add alice 'Alice_SecureP@ss!'

# Verify it was created
sudo ./manage_users.sh list

# Change password
sudo ./manage_users.sh passwd alice 'New_Alice_P@ss!'

# Remove the mailbox
sudo ./manage_users.sh remove alice

# Confirm removal
sudo ./manage_users.sh list
```

### Demo 10 — TLS Security Verification

Show that all services enforce modern TLS:

```bash
# Check SMTP TLS version and cipher
echo "QUIT" | timeout 3 openssl s_client -connect localhost:465 2>&1 | grep -E "Protocol|Cipher"

# Check IMAP TLS
echo "a1 LOGOUT" | timeout 3 openssl s_client -connect localhost:993 2>&1 | grep -E "Protocol|Cipher"

# Check HTTPS
echo "" | timeout 3 openssl s_client -connect localhost:443 2>&1 | grep -E "Protocol|Cipher"
```

Expected: TLSv1.2 or TLSv1.3 with strong ciphers (ECDHE, AES-GCM).

### Demo 11 — Nginx Web Interfaces

```bash
# HTTP automatically redirects to HTTPS
curl -s -o /dev/null -w "HTTP %{http_code} → " http://localhost/
curl -sk -o /dev/null -w "HTTPS %{http_code}\n" https://localhost/

# Rspamd web UI is accessible
curl -sk -o /dev/null -w "Rspamd UI: %{http_code}\n" https://localhost/rspamd/
```

Expected:
```
HTTP 301 → HTTPS 200
Rspamd UI: 200
```

### Demo 12 — Database Verification

```bash
# Connect to MariaDB and check Roundcube tables
sudo docker compose exec mariadb mariadb -uroundcube -pTestRcubeDB123! roundcubemail \
  -e "SHOW TABLES;" 2>/dev/null
```

Expected: 17 Roundcube tables (users, contacts, cache, identities, etc.)

---

## Part 4: Architecture Summary

```
┌─────────────────────────────────────────────────────────┐
│                    Internet / Client                     │
└──────┬──────────┬──────────┬──────────┬─────────────────┘
       │ :25/:465 │ :587     │ :993     │ :80/:443
       │ /:587    │          │          │
┌──────▼──────┐   │   ┌──────▼──────┐  ┌▼──────────────┐
│   Postfix   │◄──┘   │   Dovecot   │  │    Nginx      │
│   (SMTP)    │       │  (IMAP/LMTP)│  │ (reverse proxy)│
└──────┬──────┘       └──────▲──────┘  └──┬─────────┬──┘
       │ milter              │ LMTP       │         │
┌──────▼──────┐       ┌─────┴──────┐  ┌──▼────┐ ┌──▼────┐
│   Rspamd    │       │  Maildir   │  │Round- │ │Rspamd │
│ (anti-spam) │       │  Volume    │  │ cube  │ │Web UI │
└──────┬──────┘       └────────────┘  └──┬────┘ └───────┘
       │                                  │
┌──────▼──────┐                    ┌──────▼──────┐
│    Redis    │                    │   MariaDB   │
│  (Bayes DB) │                    │ (Roundcube) │
└─────────────┘                    └─────────────┘
```

### Mail Flow

1. **Inbound:** Client → Postfix (port 25/465/587) → Rspamd milter scan → Dovecot LMTP → Maildir
2. **Spam:** Rspamd score ≥ 15 → rejected at SMTP level; score ≥ 6 → delivered with `X-Spam: Yes` → Sieve files to Junk
3. **Webmail:** Browser → Nginx (HTTPS) → Roundcube (PHP-FPM) → Dovecot (IMAP) + Postfix (SMTP)
4. **Outbound:** Roundcube → Postfix (submission/587) → Rspamd (DKIM signing) → Internet

### Security Layers

| Layer | Protection |
|-------|-----------|
| TLS | TLSv1.2+ only on all services, strong ciphers |
| SASL | SMTP submission/smtps require authentication |
| Anti-relay | `reject_unauth_destination` blocks open relay |
| SPF/DKIM/DMARC | DNS records generated, DKIM signing active |
| Rspamd | Bayes classifier, greylisting, phishing detection |
| Sieve | Spam auto-filed to Junk folder |
| Nginx | HSTS, X-Frame-Options, HTTPS-only |
| Network | All containers on isolated Docker bridge |
