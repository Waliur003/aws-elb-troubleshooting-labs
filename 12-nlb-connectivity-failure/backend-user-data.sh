#!/bin/bash
set -eux

mkdir -p /opt/lab12

cat > /opt/lab12/index.html <<'HTML'
AWS ELB Troubleshooting Lab 12

Application: Network Load Balancer Connectivity
Backend Port: 8080
Status: Healthy
HTML

cat > /opt/lab12/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab12-web.service <<'UNIT'
[Unit]
Description=Lab12 NLB Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab12
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab12-web.service
