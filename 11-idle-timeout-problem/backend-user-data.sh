#!/bin/bash
set -eux

mkdir -p /opt/lab11

cat > /opt/lab11/app.py <<'PY'
#!/usr/bin/env python3

import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):

    def do_GET(self):

        if self.path == "/health":
            status = 200
            body = b"OK\n"

        elif self.path == "/":
            status = 200
            body = b"AWS ELB Lab 11 - Application Healthy\n"

        elif self.path == "/slow":
            time.sleep(12)
            status = 200
            body = b"Slow operation completed after 12 seconds\n"

        else:
            status = 404
            body = b"Not Found\n"

        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        except (BrokenPipeError, ConnectionResetError):
            self.log_message(
                "Client disconnected before response completed"
            )


if __name__ == "__main__":

    server = ThreadingHTTPServer(
        ("0.0.0.0", 8080),
        Handler
    )

    server.serve_forever()
PY

cat > /etc/systemd/system/lab11-web.service <<'UNIT'
[Unit]
Description=Lab 11 ALB Idle Timeout Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/lab11/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab11-web.service
