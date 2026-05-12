#!/usr/bin/env bash
set -euo pipefail

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

exec postfix start-fg
