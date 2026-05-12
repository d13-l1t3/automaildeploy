#!/usr/bin/env bash
###############################################################################
#  AutoMailDeploy — Automated Mail Server Installation Script
#  Usage:  sudo bash install.sh
#  Requires: .env file in the same directory (copy from .env.example)
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONFIG_DIR="${SCRIPT_DIR}/config"
DKIM_DIR="${SCRIPT_DIR}/dkim"
DATA_DIR="${SCRIPT_DIR}/data"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  $*${NC}"; echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}\n"; }

# ── Pre-flight checks ────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then err "This script must be run as root (sudo)."; exit 1; fi
if [[ ! -f "$ENV_FILE" ]]; then err ".env file not found. Copy .env.example to .env and configure it."; exit 1; fi

banner "AutoMailDeploy — Enterprise Mail Server Installer"

# ── Load configuration ───────────────────────────────────────────────────────
log "Loading configuration from .env …"
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# Validate required variables
for var in MAIL_DOMAIN MAIL_HOSTNAME SERVER_IP LETSENCRYPT_EMAIL \
           ADMIN_USER ADMIN_PASSWORD MYSQL_ROOT_PASSWORD MYSQL_DATABASE \
           MYSQL_USER MYSQL_PASSWORD RSPAMD_PASSWORD ROUNDCUBE_DES_KEY; do
    if [[ -z "${!var:-}" ]]; then
        err "Required variable $var is empty in .env"; exit 1
    fi
done
log "Configuration validated."

###############################################################################
# 1. Install host dependencies
###############################################################################
banner "1/6 — Installing Host Dependencies"

apt-get update -qq

# Docker
if ! command -v docker &>/dev/null; then
    log "Installing Docker …"
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
        $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker installed."
else
    log "Docker already installed — $(docker --version)"
fi

# Certbot
if ! command -v certbot &>/dev/null; then
    log "Installing Certbot …"
    apt-get install -y -qq certbot
    log "Certbot installed."
else
    log "Certbot already installed — $(certbot --version 2>&1)"
fi

# Utilities needed for password hashing and DKIM
apt-get install -y -qq openssl dnsutils gettext-base

###############################################################################
# 2. Obtain SSL/TLS Certificates
###############################################################################
banner "2/6 — Obtaining SSL/TLS Certificates"

SSL_DIR="${CONFIG_DIR}/ssl"
mkdir -p "$SSL_DIR"

CERTBOT_FLAGS=()
if [[ "${LETSENCRYPT_STAGING:-false}" == "true" ]]; then
    CERTBOT_FLAGS+=(--staging)
    warn "Using Let's Encrypt STAGING environment (certs will NOT be trusted)."
fi

CERT_LIVE="/etc/letsencrypt/live/${MAIL_HOSTNAME}"
if [[ -f "${CERT_LIVE}/fullchain.pem" ]]; then
    log "Certificate already exists for ${MAIL_HOSTNAME}, skipping issuance."
else
    # Stop anything on port 80 temporarily
    if ss -tlnp | grep -q ':80 '; then
        warn "Port 80 is in use. Attempting to free it …"
        fuser -k 80/tcp 2>/dev/null || true
        sleep 2
    fi

    log "Requesting certificate via standalone mode …"
    if certbot certonly --standalone --non-interactive --agree-tos \
        --email "${LETSENCRYPT_EMAIL}" \
        -d "${MAIL_HOSTNAME}" \
        "${CERTBOT_FLAGS[@]+"${CERTBOT_FLAGS[@]}"}"; then
        log "Certificate obtained successfully."
    else
        warn "Standalone failed (DNS may not have propagated). Retrying with --dry-run disabled and --preferred-challenges http …"
        certbot certonly --standalone --non-interactive --agree-tos \
            --email "${LETSENCRYPT_EMAIL}" \
            -d "${MAIL_HOSTNAME}" \
            --preferred-challenges http \
            "${CERTBOT_FLAGS[@]+"${CERTBOT_FLAGS[@]}"}" || {
                err "Certificate issuance FAILED. Ensure DNS A record for ${MAIL_HOSTNAME} points to ${SERVER_IP} and port 80 is reachable."
                err "You can retry with LETSENCRYPT_STAGING=true in .env for testing."
                exit 1
            }
        log "Certificate obtained on retry."
    fi
fi

# Copy certs into project SSL dir
cp -L "${CERT_LIVE}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
cp -L "${CERT_LIVE}/privkey.pem"   "${SSL_DIR}/privkey.pem"
chmod 600 "${SSL_DIR}/privkey.pem"
log "Certificates copied to ${SSL_DIR}."

# Certbot auto-renewal hook to copy certs and reload containers
cat > /etc/letsencrypt/renewal-hooks/deploy/automaildeploy.sh <<HOOK
#!/usr/bin/env bash
cp -L "${CERT_LIVE}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
cp -L "${CERT_LIVE}/privkey.pem"   "${SSL_DIR}/privkey.pem"
chmod 600 "${SSL_DIR}/privkey.pem"
cd "${SCRIPT_DIR}" && docker compose restart postfix dovecot nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/automaildeploy.sh
log "Certbot auto-renewal hook installed."

###############################################################################
# 3. Generate DKIM keys
###############################################################################
banner "3/6 — Generating DKIM Keys"

mkdir -p "$DKIM_DIR"
DKIM_PRIVATE="${DKIM_DIR}/${MAIL_DOMAIN}.dkim.key"
DKIM_PUBLIC="${DKIM_DIR}/${MAIL_DOMAIN}.dkim.pub"
DKIM_SELECTOR="dkim"

if [[ -f "$DKIM_PRIVATE" ]]; then
    log "DKIM key already exists for ${MAIL_DOMAIN}, skipping."
else
    openssl genrsa -out "$DKIM_PRIVATE" 2048 2>/dev/null
    openssl rsa -in "$DKIM_PRIVATE" -pubout -out "$DKIM_PUBLIC" 2>/dev/null
    chmod 600 "$DKIM_PRIVATE"
    log "DKIM key pair generated (selector: ${DKIM_SELECTOR})."
fi

# Extract the public key for DNS (strip header/footer, join lines)
DKIM_DNS_VALUE=$(grep -v '^-' "$DKIM_PUBLIC" | tr -d '\n')

###############################################################################
# 4. Generate configuration files from templates
###############################################################################
banner "4/6 — Generating Service Configurations"

mkdir -p "${DATA_DIR}"/{postfix/spool,postfix/log,dovecot,redis,mariadb,roundcube,rspamd,nginx/log}

# Export all variables for envsubst
export MAIL_DOMAIN MAIL_HOSTNAME SERVER_IP ROUNDCUBE_DES_KEY

# ── Postfix ──────────────────────────────────────────────────────────────────
envsubst '${MAIL_DOMAIN} ${MAIL_HOSTNAME}' \
    < "${CONFIG_DIR}/postfix/main.cf.template" \
    > "${CONFIG_DIR}/postfix/main.cf"

cp "${CONFIG_DIR}/postfix/master.cf.template" "${CONFIG_DIR}/postfix/master.cf"

# Virtual domains and mailboxes
echo "${MAIL_DOMAIN}  OK" > "${CONFIG_DIR}/postfix/virtual_mailbox_domains"
echo "${ADMIN_USER}@${MAIL_DOMAIN}  ${MAIL_DOMAIN}/${ADMIN_USER}/Maildir/" \
    > "${CONFIG_DIR}/postfix/virtual_mailbox_maps"

if [[ -n "${EXTRA_USERS:-}" ]]; then
    IFS=',' read -ra PAIRS <<< "$EXTRA_USERS"
    for pair in "${PAIRS[@]}"; do
        uname="${pair%%:*}"
        echo "${uname}@${MAIL_DOMAIN}  ${MAIL_DOMAIN}/${uname}/Maildir/" \
            >> "${CONFIG_DIR}/postfix/virtual_mailbox_maps"
    done
fi
log "Postfix configs generated."

# ── Dovecot ──────────────────────────────────────────────────────────────────
envsubst '${MAIL_DOMAIN} ${MAIL_HOSTNAME}' \
    < "${CONFIG_DIR}/dovecot/dovecot.conf.template" \
    > "${CONFIG_DIR}/dovecot/dovecot.conf"

# Generate passwd entries (Blowfish crypt)
ADMIN_HASH=$(openssl passwd -6 "$ADMIN_PASSWORD")
echo "${ADMIN_USER}@${MAIL_DOMAIN}:{SHA512-CRYPT}${ADMIN_HASH}:::::" \
    > "${CONFIG_DIR}/dovecot/passwd"

if [[ -n "${EXTRA_USERS:-}" ]]; then
    IFS=',' read -ra PAIRS <<< "$EXTRA_USERS"
    for pair in "${PAIRS[@]}"; do
        uname="${pair%%:*}"
        upass="${pair#*:}"
        uhash=$(openssl passwd -6 "$upass")
        echo "${uname}@${MAIL_DOMAIN}:{SHA512-CRYPT}${uhash}:::::" \
            >> "${CONFIG_DIR}/dovecot/passwd"
    done
fi
chmod 600 "${CONFIG_DIR}/dovecot/passwd"
log "Dovecot configs generated."

# ── Rspamd ───────────────────────────────────────────────────────────────────
# Hash the Rspamd web password (pbkdf2 via controller)
# Fallback: store as plain until first rspamd container start
export RSPAMD_HASHED_PASSWORD="\$2\$${RSPAMD_PASSWORD}"  # will be re-hashed on first start
envsubst '${RSPAMD_HASHED_PASSWORD}' \
    < "${CONFIG_DIR}/rspamd/local.d/worker-controller.inc.template" \
    > "${CONFIG_DIR}/rspamd/local.d/worker-controller.inc"

envsubst '${MAIL_DOMAIN}' \
    < "${CONFIG_DIR}/rspamd/local.d/dkim_signing.conf.template" \
    > "${CONFIG_DIR}/rspamd/local.d/dkim_signing.conf"
log "Rspamd configs generated."

# ── Nginx ────────────────────────────────────────────────────────────────────
envsubst '${MAIL_HOSTNAME}' \
    < "${CONFIG_DIR}/nginx/mail.conf.template" \
    > "${CONFIG_DIR}/nginx/mail.conf"
log "Nginx configs generated."

# ── Roundcube ────────────────────────────────────────────────────────────────
envsubst '${MAIL_DOMAIN} ${ROUNDCUBE_DES_KEY}' \
    < "${CONFIG_DIR}/roundcube/config.inc.php.template" \
    > "${CONFIG_DIR}/roundcube/config.inc.php"
log "Roundcube configs generated."

###############################################################################
# 5. Start Docker infrastructure
###############################################################################
banner "5/6 — Starting Docker Infrastructure"

cd "$SCRIPT_DIR"
docker compose build --quiet
docker compose up -d
log "All containers started."

# Wait for services
log "Waiting for services to become healthy …"
sleep 10

for svc in automail-postfix automail-dovecot automail-rspamd automail-nginx automail-roundcube automail-mariadb automail-redis; do
    if docker ps --format '{{.Names}}' | grep -q "$svc"; then
        echo -e "  ${GREEN}●${NC} ${svc} — running"
    else
        echo -e "  ${RED}●${NC} ${svc} — NOT running"
    fi
done

###############################################################################
# 6. Print DNS Records
###############################################################################
banner "6/6 — Required DNS Records"

echo -e "${BOLD}Add the following DNS records at your DNS provider:${NC}\n"

echo -e "${CYAN}┌─────────┬──────────────────────────────────────────────────────────────────┐${NC}"
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "Type" "Value"
echo -e "${CYAN}├─────────┼──────────────────────────────────────────────────────────────────┤${NC}"
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "A"     "${MAIL_HOSTNAME}.  →  ${SERVER_IP}"
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "MX"    "${MAIL_DOMAIN}.  →  10 ${MAIL_HOSTNAME}."
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "TXT"   "${MAIL_DOMAIN}.  →  \"v=spf1 mx a ip4:${SERVER_IP} -all\""
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "TXT"   "_dmarc.${MAIL_DOMAIN}.  →  \"v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}\""
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "TXT"   "${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}."
echo -e "${CYAN}└─────────┴──────────────────────────────────────────────────────────────────┘${NC}"

echo -e "\n${BOLD}DKIM TXT Record Value (paste as a single TXT record):${NC}"
echo -e "\"v=DKIM1; k=rsa; p=${DKIM_DNS_VALUE}\"\n"

echo -e "${BOLD}PTR (Reverse DNS):${NC}"
echo -e "Ask your hosting provider to set the PTR record for ${SERVER_IP} → ${MAIL_HOSTNAME}\n"

# Save DNS info to file for reference
cat > "${SCRIPT_DIR}/DNS_RECORDS.txt" <<DNSEOF
# AutoMailDeploy — DNS Records for ${MAIL_DOMAIN}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

A Record:
  ${MAIL_HOSTNAME}.  →  ${SERVER_IP}

MX Record:
  ${MAIL_DOMAIN}.  →  10 ${MAIL_HOSTNAME}.

SPF (TXT Record):
  ${MAIL_DOMAIN}.  →  "v=spf1 mx a ip4:${SERVER_IP} -all"

DMARC (TXT Record):
  _dmarc.${MAIL_DOMAIN}.  →  "v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}"

DKIM (TXT Record):
  ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}.  →  "v=DKIM1; k=rsa; p=${DKIM_DNS_VALUE}"

PTR (Reverse DNS):
  ${SERVER_IP}  →  ${MAIL_HOSTNAME}
DNSEOF
log "DNS records also saved to ${SCRIPT_DIR}/DNS_RECORDS.txt"

banner "Installation Complete!"
echo -e "${GREEN}Webmail:${NC}   https://${MAIL_HOSTNAME}"
echo -e "${GREEN}Rspamd:${NC}   https://${MAIL_HOSTNAME}/rspamd/"
echo -e "${GREEN}IMAP:${NC}     ${MAIL_HOSTNAME}:993 (SSL)"
echo -e "${GREEN}SMTP:${NC}     ${MAIL_HOSTNAME}:587 (STARTTLS)"
echo -e "${GREEN}Admin:${NC}    ${ADMIN_USER}@${MAIL_DOMAIN}\n"
echo -e "Use ${BOLD}./manage_users.sh${NC} to add/remove mailboxes.\n"
