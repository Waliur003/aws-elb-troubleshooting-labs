#!/bin/bash
set -eux

mkdir -p /opt/lab01

cat > /opt/lab01/index.html <<'HTML'
AWS ELB Troubleshooting Lab 01

Application: Python HTTP Server
Service: Backend EC2
Status: Running
HTML

cat > /opt/lab01/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab01-web.service <<'UNIT'
[Unit]
Description=Lab 01 ALB Backend HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab01
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab01-web.service
