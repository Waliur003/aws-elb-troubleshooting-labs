#!/bin/bash
set -eux

mkdir -p /opt/lab02

cat > /opt/lab02/app.py <<'PY'
#!/usr/bin/env python3

import socketserver
from pathlib import Path

FAULT_FILE = Path("/opt/lab02/enable-502")

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)

        data = b""

        try:
            while b"\r\n\r\n" not in data and len(data) < 16384:
                chunk = self.request.recv(4096)

                if not chunk:
                    return

                data += chunk
        except (TimeoutError, OSError):
            return

        first_line = data.split(b"\r\n", 1)[0]
        path = first_line.split(b" ")[1:2]

        if path == [b"/health"]:
            body = b"OK\n"
            response = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/plain\r\n"
                b"Content-Length: 3\r\n"
                b"Connection: close\r\n"
                b"\r\n" + body
            )

        elif FAULT_FILE.exists():
            # Intentionally invalid HTTP response.
            response = b"NOT_AN_HTTP_RESPONSE\r\n\r\n"

        else:
            body = b"AWS ELB Lab 02 - Backend Healthy\n"
            response = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/plain\r\n"
                + f"Content-Length: {len(body)}\r\n".encode()
                + b"Connection: close\r\n"
                + b"\r\n"
                + body
            )

        try:
            self.request.sendall(response)
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("0.0.0.0", 8080), Handler) as server:
    server.serve_forever()
PY

cat > /etc/systemd/system/lab02-web.service <<'UNIT'
[Unit]
Description=Lab 02 ALB HTTP Response Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/lab02/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab02-web.service
