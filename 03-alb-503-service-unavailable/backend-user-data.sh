#!/bin/bash
set -eux

mkdir -p /opt/lab03

cat > /opt/lab03/index.html <<'HTML'
AWS ELB Troubleshooting Lab 03

Application: Python HTTP Server
Status: Running
Target Group: Registered
HTML

cat > /opt/lab03/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab03-web.service <<'UNIT'
[Unit]
Description=Lab 03 ALB Backend Web Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab03
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target

[Install]
Alias=lab03-app.service
UNIT

systemctl daemon-reload
systemctl enable --now lab03-web.service
