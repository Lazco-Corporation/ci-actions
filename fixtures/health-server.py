#!/usr/bin/env python3
"""Minimal health-endpoint stub for the verify-deployment self-test.

Serves STUB_CODE with {"status": "ok", "version": STUB_VERSION} on PORT.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(
            {"status": "ok", "version": os.environ.get("STUB_VERSION", "1.2.3")}
        ).encode()
        self.send_response(int(os.environ.get("STUB_CODE", "200")))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(os.environ.get("PORT", "18080"))), Handler).serve_forever()
