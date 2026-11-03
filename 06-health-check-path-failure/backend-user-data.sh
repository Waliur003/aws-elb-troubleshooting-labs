#!/bin/bash
set -eux

mkdir -p /opt/lab06

cat > /opt/lab06/index.html <<'HTML'
AWS ELB Troubleshooting Lab 06

Application: Python HTTP Server
Application Port: 8080
Health Check: /health
Status: Healthy
HTML

cat > /opt/lab06/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab06-web.service <<'UNIT'
[Unit]
Description=Lab 06 ALB Health Check Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab06
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab06-web.service
