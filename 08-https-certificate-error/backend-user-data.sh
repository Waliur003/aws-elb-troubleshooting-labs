#!/bin/bash
set -eux

mkdir -p /opt/lab08

cat > /opt/lab08/index.html <<'HTML'
AWS ELB Troubleshooting Lab 08

Application: HTTPS Certificate Troubleshooting
Backend: EC2 Python HTTP Server
Status: Healthy
HTML

cat > /opt/lab08/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab08-web.service <<'UNIT'
[Unit]
Description=Lab 08 HTTPS ALB Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab08
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab08-web.service
