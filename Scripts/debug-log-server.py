#!/usr/bin/env python3
"""
Simple HTTP server to capture debug logs from iOS app.

Usage:
    python3 debug-log-server.py [port]

The server listens on all interfaces (0.0.0.0) so it can receive
logs from iOS devices on the same network.

Logs are written to: debug-logs.jsonl (one JSON object per line)
"""

import http.server
import json
import sys
from datetime import datetime

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7248
LOG_FILE = "debug-logs.jsonl"

class LogHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body.decode('utf-8'))

            # Add server timestamp
            data['server_time'] = datetime.now().isoformat()

            # Pretty print to console
            timestamp = data.get('timestamp', 0)
            if timestamp:
                dt = datetime.fromtimestamp(timestamp / 1000)
                time_str = dt.strftime('%H:%M:%S.%f')[:-3]
            else:
                time_str = datetime.now().strftime('%H:%M:%S.%f')[:-3]

            location = data.get('location', 'unknown')
            message = data.get('message', '')
            log_data = data.get('data', {})
            hypothesis = data.get('hypothesisId', '')

            # Color coding based on hypothesis/message type
            if 'ERROR' in message.upper() or 'FAIL' in message.upper():
                color = '\033[91m'  # Red
            elif 'currentIDs' in str(log_data) or 'optimisticIDs' in str(log_data):
                color = '\033[93m'  # Yellow - important state
            elif 'restore' in message.lower():
                color = '\033[96m'  # Cyan - restoration
            elif 'notify' in message.lower():
                color = '\033[95m'  # Magenta - notifications
            else:
                color = '\033[92m'  # Green

            reset = '\033[0m'

            print(f"{color}[{time_str}] [{hypothesis}] {location}{reset}")
            print(f"  {message}")
            if log_data:
                for key, value in log_data.items():
                    print(f"    {key}: {value}")
            print()

            # Write to log file
            with open(LOG_FILE, 'a') as f:
                f.write(json.dumps(data) + '\n')

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        except json.JSONDecodeError as e:
            print(f"JSON decode error: {e}")
            print(f"Body: {body[:200]}")
            self.send_response(400)
            self.end_headers()

    def do_GET(self):
        """Health check endpoint"""
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'Debug log server running\n')

    def log_message(self, format, *args):
        # Suppress default HTTP logging
        pass

def get_local_ip():
    """Get the local IP address for display"""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"

if __name__ == '__main__':
    local_ip = get_local_ip()

    print(f"\033[1m=== Debug Log Server ===\033[0m")
    print(f"Listening on: http://0.0.0.0:{PORT}")
    print(f"Local IP: http://{local_ip}:{PORT}")
    print(f"Log file: {LOG_FILE}")
    print()
    print("To enable logging in iOS app, set environment variable:")
    print("  INSTANT_DEBUG_LOG=1")
    print()
    print(f"Update Reactor.swift URL to: http://{local_ip}:{PORT}/ingest/debug")
    print()
    print("Waiting for logs...\n")

    server = http.server.HTTPServer(('0.0.0.0', PORT), LogHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
