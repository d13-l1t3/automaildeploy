#!/usr/bin/env bash
set -euo pipefail

# Copy generated configs from the read-only mount
cp /etc/postfix/custom/main.cf  /etc/postfix/main.cf
cp /etc/postfix/custom/master.cf /etc/postfix/master.cf
cp /etc/postfix/custom/virtual_mailbox_domains /etc/postfix/virtual_mailbox_domains
cp /etc/postfix/custom/virtual_mailbox_maps    /etc/postfix/virtual_mailbox_maps

postmap /etc/postfix/virtual_mailbox_domains
postmap /etc/postfix/virtual_mailbox_maps

# Ensure vmail user exists
groupadd -g 5000 vmail 2>/dev/null || true
useradd -u 5000 -g vmail -d /var/vmail -s /usr/sbin/nologin vmail 2>/dev/null || true
mkdir -p /var/vmail
chown -R vmail:vmail /var/vmail

# ── Fix DNS resolution inside Postfix chroot ──────────────────────────────────
# Postfix on Debian runs smtp/lmtp/cleanup inside a chroot at /var/spool/postfix.
# The chroot does NOT inherit /etc/resolv.conf, so Docker's embedded DNS
# (127.0.0.11) is unreachable. This causes "Host not found" errors when
# Postfix tries to connect to 'dovecot' (LMTP) or 'rspamd' (milter).
CHROOT=/var/spool/postfix
mkdir -p "${CHROOT}/etc"
cp /etc/resolv.conf   "${CHROOT}/etc/resolv.conf"
cp /etc/nsswitch.conf "${CHROOT}/etc/nsswitch.conf"  2>/dev/null || true
cp /etc/hosts         "${CHROOT}/etc/hosts"
cp /etc/services      "${CHROOT}/etc/services"

exec postfix start-fg
