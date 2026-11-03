#!/bin/bash
set -eux

mkdir -p /opt/lab04

cat > /opt/lab04/app.py <<'PY'
#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time

FAULT_FILE = Path("/opt/lab04/enable-slow")


class Handler(BaseHTTPRequestHandler):

    protocol_version = "HTTP/1.1"

    def do_GET(self):

        if self.path == "/health":
            body = b"OK\n"

        elif self.path == "/slow":

            if FAULT_FILE.exists():
                print("Simulating 20-second backend delay", flush=True)
                time.sleep(20)

            body = b"Slow endpoint completed\n"

        elif self.path == "/":
            body = b"AWS ELB Lab 04 - Application Healthy\n"

        else:
            body = b"Not Found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            print("Client connection closed before response", flush=True)

    def log_message(self, format, *args):
        print("%s - %s" % (self.address_string(), format % args),
              flush=True)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    print("Lab 04 HTTP server listening on port 8080", flush=True)
    server.serve_forever()
PY

cat > /etc/systemd/system/lab04-web.service <<'UNIT'
[Unit]
Description=Lab 04 ALB Timeout Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/lab04/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab04-web.service
