#!/bin/bash
set -eux

mkdir -p /opt/lab10

cat > /opt/lab10/index.html <<'HTML'
AWS ELB Troubleshooting Lab 10

Application: Target Registration Troubleshooting
Backend Port: 8080
Status: Healthy
HTML

cat > /opt/lab10/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab10-web.service <<'UNIT'
[Unit]
Description=Lab 10 ALB Target Registration Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab10
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab10-web.service
