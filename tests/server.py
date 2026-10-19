#!/usr/bin/env python3
"""Throttled HTTP server for worker tests.

GET  .../api/...  -> 404, so the worker falls back to the configured servers
GET  .../ping...  -> small answer after 20 ms
GET  anything     -> 200 MiB of zeros at RATE bytes/s per connection
POST anything     -> reads the body (chunked or not) at RATE bytes/s, answers "ok"
"""
import http.server
import socketserver
import sys
import time

PORT = int(sys.argv[1])
RATE = int(sys.argv[2]) if len(sys.argv) > 2 else 2_500_000
CHUNK = 65536


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, body):
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if '/api/' in self.path:
            self.send_error(404)
            return
        if 'ping' in self.path:
            time.sleep(0.02)
            return self.reply(b'pong')

        total = 200 * 1024 * 1024
        self.send_response(200)
        self.send_header('Content-Length', str(total))
        self.end_headers()
        buf = b'\0' * CHUNK
        start = time.time()
        sent = 0
        try:
            while sent < total:
                self.wfile.write(buf)
                sent += CHUNK
                delay = sent / RATE - (time.time() - start)
                if delay > 0:
                    time.sleep(delay)
        except OSError:
            pass

    def do_POST(self):
        start = time.time()
        got = 0

        def read(n):
            nonlocal got
            while n:
                b = self.rfile.read(min(n, CHUNK))
                if not b:
                    return
                n -= len(b)
                got += len(b)
                delay = got / RATE - (time.time() - start)
                if delay > 0:
                    time.sleep(delay)

        if 'chunked' in self.headers.get('Transfer-Encoding', ''):
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    break
                read(size)
                self.rfile.readline()
        else:
            read(int(self.headers.get('Content-Length', 0)))

        self.reply(b'ok')


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass  # clients cut transfers at the deadline on purpose


Server(('127.0.0.1', PORT), Handler).serve_forever()
