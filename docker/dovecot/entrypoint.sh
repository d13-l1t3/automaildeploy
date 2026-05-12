#!/usr/bin/env bash
set -euo pipefail

# Copy generated configs from the read-only mount into Dovecot's config dir
cp /etc/dovecot/custom/dovecot.conf /etc/dovecot/dovecot.conf
cp /etc/dovecot/custom/passwd       /etc/dovecot/passwd

# The passwd file must be readable by Dovecot's auth worker (runs as user 'dovecot').
# Mode 600 (root-only) causes "[UNAVAILABLE] Temporary authentication failure".
# Use chmod 644 as a safe fallback if the 'dovecot' group doesn't exist.
if getent group dovecot >/dev/null 2>&1; then
    chown root:dovecot /etc/dovecot/passwd
    chmod 640 /etc/dovecot/passwd
else
    chmod 644 /etc/dovecot/passwd
fi

# Create vmail user for mailbox storage
groupadd -g 5000 vmail 2>/dev/null || true
useradd -u 5000 -g vmail -d /var/vmail -s /usr/sbin/nologin vmail 2>/dev/null || true
mkdir -p /var/vmail
chown -R vmail:vmail /var/vmail

exec dovecot -F
