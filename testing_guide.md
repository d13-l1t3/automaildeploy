# AutoMailDeploy — Testing Guide

## Part 1: Sample `.env` Data

### Option A — Testing on a Real VPS (Recommended)

If you have a VPS (DigitalOcean, Hetzner, etc.) with a real domain:

```env
MAIL_DOMAIN=yourdomain.com
MAIL_HOSTNAME=mail.yourdomain.com
SERVER_IP=<your VPS public IP>

LETSENCRYPT_EMAIL=you@gmail.com
LETSENCRYPT_STAGING=true            # ← use staging certs while testing!

ADMIN_USER=admin
ADMIN_PASSWORD=Adm1n_T3st!Secur3

EXTRA_USERS=alice:Al1ce_P@ss2026,bob:B0b_Str0ng!Pass

MYSQL_ROOT_PASSWORD=MyRootDB_2026!xQ
MYSQL_DATABASE=roundcubemail
MYSQL_USER=roundcube
MYSQL_PASSWORD=RcubeDB_s3cur3!Zk

RSPAMD_PASSWORD=Rsp@md_W3bUI!2026

ROUNDCUBE_DES_KEY=a1b2c3d4e5f6a7b8c9d0e1f2    # exactly 24 chars

DOCKER_SUBNET=172.28.0.0/16
TZ=Europe/Kiev
```

> [!IMPORTANT]
> Set `LETSENCRYPT_STAGING=true` for your first runs. Staging certs won't be browser-trusted, but Let's Encrypt won't rate-limit you while you iterate. Switch to `false` once everything works.

### Option B — Local Testing (no real domain)

For local/VM testing without a domain, use self-signed certs by skipping certbot:

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

For local testing, generate a self-signed cert **before** running `install.sh`:

```bash
mkdir -p config/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout config/ssl/privkey.pem \
  -out config/ssl/fullchain.pem \
  -subj "/CN=mail.test.local"
```

Then comment out phase 2 (SSL section) in `install.sh`, or just let it fail gracefully — the script will still work if certs are already in `config/ssl/`.

---

## Part 2: Functional Verification After Install

Run these commands on the server after `install.sh` completes:

### 2.1 — Check all containers are running

```bash
docker compose ps
```

Expected: all 7 containers `Up` (postfix, dovecot, rspamd, redis, mariadb, roundcube, nginx).

### 2.2 — Test SMTP connectivity

```bash
# From the server itself:
openssl s_client -connect localhost:465 -quiet    # SMTPS (implicit TLS)
openssl s_client -starttls smtp -connect localhost:587 -quiet  # Submission

# Verify anti-relay (should be REJECTED):
telnet localhost 25
EHLO test.com
MAIL FROM:<spammer@evil.com>
RCPT TO:<someone@gmail.com>
# Expected: 554 Relay access denied
```

### 2.3 — Test IMAP connectivity

```bash
openssl s_client -connect localhost:993 -quiet
# Type after connected:
a1 LOGIN admin@yourdomain.com "Adm1n_T3st!Secur3"
a2 LIST "" "*"
a3 LOGOUT
```

### 2.4 — Send a test email between local users

```bash
# From inside the postfix container:
docker compose exec postfix bash -c '
  echo "Subject: Test Email
From: admin@'"$MAIL_DOMAIN"'
To: alice@'"$MAIL_DOMAIN"'

This is a test message." | sendmail -t
'
```

Then verify delivery:

```bash
# Check alice's maildir:
docker compose exec dovecot ls -la /var/vmail/$MAIL_DOMAIN/alice/Maildir/new/
```

### 2.5 — Test Roundcube Webmail

Open `https://mail.yourdomain.com` in a browser and log in with:
- **User:** `admin@yourdomain.com`
- **Password:** `Adm1n_T3st!Secur3`

### 2.6 — Test Rspamd Web UI

Open `https://mail.yourdomain.com/rspamd/` and enter the `RSPAMD_PASSWORD`.

### 2.7 — Verify user management

```bash
sudo ./manage_users.sh list
sudo ./manage_users.sh add testuser "Test_P@ss!789"
sudo ./manage_users.sh list
sudo ./manage_users.sh passwd testuser "New_P@ss!000"
sudo ./manage_users.sh remove testuser
```

---

## Part 3: Anti-Spam & Anti-Phishing Testing

### 3.1 — GTUBE Test (Generic Test for Unsolicited Bulk Email)

The **GTUBE string** is a standardized test pattern that every spam filter (including Rspamd) is designed to catch. Send an email containing this exact string in the body:

```
XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X
```

Test from the server:

```bash
docker compose exec postfix bash -c '
  echo "Subject: GTUBE Spam Test
From: admin@'"$MAIL_DOMAIN"'
To: alice@'"$MAIL_DOMAIN"'

This is a spam test.
XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X
End of test." | sendmail -t
'
```

**Expected result:** Rspamd should **reject** this message (score ≥ 15). Check Rspamd logs:

```bash
docker compose logs rspamd | tail -20
```

### 3.2 — Send a Phishing-style Email

Test with common phishing indicators — urgent language, suspicious sender, fake links:

```bash
docker compose exec postfix bash -c '
  echo "Subject: URGENT: Your account has been compromised!
From: security-alert@'"$MAIL_DOMAIN"'
To: admin@'"$MAIL_DOMAIN"'
Content-Type: text/html

<html>
<body>
<p>Dear user,</p>
<p>We detected unauthorized access to your account. Click
<a href=\"http://evil-phishing-site.example.com/steal-password\">here</a>
to verify your identity immediately or your account will be suspended.</p>
<p>Enter your password and SSN to confirm ownership.</p>
</body>
</html>" | sendmail -t
'
```

Check what Rspamd scored it:

```bash
docker compose logs rspamd | grep -A5 "phish\|score"
```

### 3.3 — Use `rspamc` to Scan Emails Directly

You can test the Rspamd engine without actually sending mail:

```bash
# Create a test spam message
cat > /tmp/test_spam.eml <<'EOF'
From: spammer@evil.example.com
To: victim@example.com
Subject: Buy cheap pills now!!!
Date: Mon, 12 May 2026 10:00:00 +0000

BUY NOW! CHEAP V1AGRA! FREE ROLEX! Click here: http://malware.example.com
You have WON $1,000,000! Send your bank details now!
XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X
EOF

# Scan it with rspamc
docker compose exec rspamd rspamc < /tmp/test_spam.eml
```

The output shows **every rule that matched** and the **total score**. Example output:

```
Results for file: stdin
Action: reject
Score: 1025.80 / 15.00
Symbol: GTUBE (1000.00)
Symbol: MISSING_MID (2.50)
Symbol: ONCE_RECEIVED (0.10)
...
```

### 3.4 — Test DKIM Signing (Outbound)

Send an email to an external address (Gmail works great) and check the headers:

```bash
docker compose exec postfix bash -c '
  echo "Subject: DKIM Test
From: admin@'"$MAIL_DOMAIN"'
To: your-personal@gmail.com

Testing DKIM signature." | sendmail -t
'
```

In Gmail, open the message → **"Show original"** → look for:

```
Authentication-Results: ...
    dkim=pass header.d=yourdomain.com header.s=dkim
    spf=pass
```

### 3.5 — Test SPF Enforcement (Inbound)

Use an external tool to send a forged email claiming to be from your domain but from a different IP:

```bash
# From a DIFFERENT server (not your mail server):
telnet <YOUR_MAIL_SERVER_IP> 25
EHLO test
MAIL FROM:<admin@yourdomain.com>
RCPT TO:<admin@yourdomain.com>
DATA
Subject: SPF Forgery Test

This email is forged.
.
QUIT
```

**Expected:** Rspamd should add a high SPF_FAIL score. Check:

```bash
docker compose logs rspamd | grep -i "spf"
```

### 3.6 — Verify Rspamd Score Thresholds

The system has three tiers configured in `config/rspamd/local.d/actions.conf`:

| Score | Action | What happens |
|---|---|---|
| **≥ 4** | Greylist | Temporarily defers delivery (legitimate servers retry) |
| **≥ 6** | Add header | Delivers but adds `X-Spam: Yes` header |
| **≥ 15** | Reject | Outright rejects at SMTP level |

View real-time scoring in the Rspamd UI at `https://mail.yourdomain.com/rspamd/` → **History** tab.

### 3.7 — Bayes Learning (Train the Filter)

```bash
# Mark a message as spam (train Bayes):
docker compose exec rspamd rspamc learn_spam < /path/to/spam.eml

# Mark a message as ham (not spam):
docker compose exec rspamd rspamc learn_ham < /path/to/legitimate.eml

# Check Bayes statistics:
docker compose exec rspamd rspamc stat
```

### 3.8 — External Deliverability Test Tools

Once DNS records are set up and `LETSENCRYPT_STAGING=false`:

| Tool | URL | What it tests |
|---|---|---|
| **mail-tester.com** | https://www.mail-tester.com | Send email to their address → get a 0-10 score |
| **MXToolbox** | https://mxtoolbox.com | DNS, SPF, DKIM, DMARC, blacklist checks |
| **DKIM Validator** | https://dkimvalidator.com | Validates DKIM signature |
| **Learndmarc.com** | https://learndmarc.com | Visual SPF/DKIM/DMARC flow |

> [!TIP]
> The best single test: go to https://www.mail-tester.com, copy the random address they give you, send an email to it from Roundcube, then check your score. Aim for **9/10 or higher**.
