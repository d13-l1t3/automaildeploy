#!/usr/bin/env bash
set -euo pipefail

cp /etc/dovecot/custom/dovecot.conf /etc/dovecot/dovecot.conf
cp /etc/dovecot/custom/passwd       /etc/dovecot/passwd

groupadd -g 5000 vmail 2>/dev/null || true
useradd -u 5000 -g vmail -d /var/vmail -s /usr/sbin/nologin vmail 2>/dev/null || true
mkdir -p /var/vmail
chown -R vmail:vmail /var/vmail

exec dovecot -F
