#!/usr/bin/env python3
"""
Simple HTTP server for testing video playback in NexusPVR.
Serves a video file with range request support (required for seeking).

Usage:
    python3 test-server.py /path/to/video.mkv [port]

Then in NexusPVR, play: http://<your-ip>:<port>/video
"""

import sys
import os
from http.server import HTTPServer, BaseHTTPRequestHandler

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <video-file> [port]")
    sys.exit(1)

VIDEO_PATH = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9000

if not os.path.isfile(VIDEO_PATH):
    print(f"Error: {VIDEO_PATH} not found")
    sys.exit(1)

VIDEO_SIZE = os.path.getsize(VIDEO_PATH)
EXT = os.path.splitext(VIDEO_PATH)[1].lower()
CONTENT_TYPE = {
    ".mkv": "video/x-matroska",
    ".mp4": "video/mp4",
    ".ts": "video/mp2t",
    ".avi": "video/x-msvideo",
    ".webm": "video/webm",
    ".mov": "video/quicktime",
}.get(EXT, "application/octet-stream")


class VideoHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/video", "/"):
            self.send_error(404)
            return

        range_header = self.headers.get("Range")
        if range_header:
            self._serve_range(range_header)
        else:
            self._serve_full()

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE)
        self.send_header("Content-Length", str(VIDEO_SIZE))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

    def _serve_full(self):
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE)
        self.send_header("Content-Length", str(VIDEO_SIZE))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        with open(VIDEO_PATH, "rb") as f:
            while chunk := f.read(1024 * 1024):
                try:
                    self.wfile.write(chunk)
                except BrokenPipeError:
                    break

    def _serve_range(self, range_header):
        try:
            range_spec = range_header.replace("bytes=", "")
            start_str, end_str = range_spec.split("-")
            start = int(start_str) if start_str else 0
            end = int(end_str) if end_str else VIDEO_SIZE - 1
        except ValueError:
            self.send_error(416, "Invalid range")
            return

        if start >= VIDEO_SIZE:
            self.send_error(416, "Range not satisfiable")
            return

        end = min(end, VIDEO_SIZE - 1)
        length = end - start + 1

        self.send_response(206)
        self.send_header("Content-Type", CONTENT_TYPE)
        self.send_header("Content-Length", str(length))
        self.send_header("Content-Range", f"bytes {start}-{end}/{VIDEO_SIZE}")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

        with open(VIDEO_PATH, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk_size = min(1024 * 1024, remaining)
                chunk = f.read(chunk_size)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except BrokenPipeError:
                    break
                remaining -= len(chunk)

    def log_message(self, format, *args):
        # Compact logging
        print(f"{self.address_string()} {args[0]}")


if __name__ == "__main__":
    import socket
    hostname = socket.gethostname()
    try:
        local_ip = socket.gethostbyname(hostname)
    except socket.gaierror:
        local_ip = "localhost"

    print(f"Serving: {VIDEO_PATH}")
    print(f"Size:    {VIDEO_SIZE / (1024*1024):.1f} MB")
    print(f"Type:    {CONTENT_TYPE}")
    print(f"URL:     http://{local_ip}:{PORT}/video")
    print(f"         http://localhost:{PORT}/video")
    print()

    server = HTTPServer(("0.0.0.0", PORT), VideoHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
