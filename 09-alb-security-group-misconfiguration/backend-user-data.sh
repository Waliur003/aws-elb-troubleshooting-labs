#!/bin/bash
set -eux

mkdir -p /opt/lab09

cat > /opt/lab09/index.html <<'HTML'
AWS ELB Troubleshooting Lab 09

Application: Security Group Troubleshooting
Backend Port: 8080
Status: Healthy
HTML

cat > /opt/lab09/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab09-web.service <<'UNIT'
[Unit]
Description=Lab 09 ALB Security Group Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab09
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab09-web.service
