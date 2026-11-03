#!/bin/bash
set -eux

mkdir -p /opt/lab05

cat > /opt/lab05/index.html <<'HTML'
AWS ELB Troubleshooting Lab 05

Application: Python HTTP Server
Application Port: 8080
Status: Healthy
HTML

cat > /opt/lab05/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab05-web.service <<'UNIT'
[Unit]
Description=Lab 05 ALB Target Port Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab05
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab05-web.service
