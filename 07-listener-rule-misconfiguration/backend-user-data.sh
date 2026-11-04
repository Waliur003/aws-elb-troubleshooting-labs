#!/bin/bash
set -eux

mkdir -p /opt/lab07

cat > /opt/lab07/app.py <<'PY'
#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):

        if self.path == "/health":
            status = 200
            body = b"OK\n"

        elif self.path == "/":
            status = 200
            body = b"AWS ELB Lab 07 - Home Page\n"

        elif self.path == "/app":
            status = 200
            body = b"AWS ELB Lab 07 - Application Working\n"

        else:
            status = 404
            body = b"Not Found\n"

        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer(
        ("0.0.0.0", 8080),
        Handler
    )

    server.serve_forever()
PY

cat > /etc/systemd/system/lab07-web.service <<'UNIT'
[Unit]
Description=Lab 07 ALB Listener Rule Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/lab07/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab07-web.service
