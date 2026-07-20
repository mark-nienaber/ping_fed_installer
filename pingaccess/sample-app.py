#!/usr/bin/env python3
"""
sample-app.py — trivial backend origin for the PingAccess-protected demo app.

PingAccess reverse-proxies to this server (default http://localhost:8080). It is
deliberately unauthenticated: all access control happens at PingAccess, which
only forwards a request here after a valid PingFederate SSO web session exists.
The page echoes the identity headers PingAccess injects (e.g. the authenticated
user), so a successful end-to-end SSO is visible in the response body.

Usage:  python3 sample-app.py [port]      (default port 8080)
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Headers PingAccess commonly injects for the authenticated identity.
        ident_keys = [k for k in self.headers.keys()
                      if k.lower() in ("x-user", "x-username", "sub", "x-userid",
                                       "x-pf-user", "remote-user", "x-forwarded-user")]
        idents = "".join(
            f"<tr><td>{k}</td><td>{self.headers.get(k)}</td></tr>" for k in ident_keys
        ) or "<tr><td colspan=2><em>(no identity headers — configure an Identity Mapping in PingAccess to inject them)</em></td></tr>"
        allhdrs = "".join(
            f"<tr><td>{k}</td><td>{v}</td></tr>" for k, v in self.headers.items()
        )
        body = f"""<!doctype html><html><head><title>Protected Sample App</title>
<style>body{{font-family:system-ui,sans-serif;max-width:820px;margin:3rem auto;padding:0 1rem}}
h1{{color:#2b6}}table{{border-collapse:collapse;width:100%;margin:1rem 0}}
td{{border:1px solid #ccc;padding:.35rem .6rem;font-size:.9rem}}code{{background:#f4f4f4;padding:.1rem .3rem}}</style></head>
<body>
<h1>&#10003; You reached the protected app</h1>
<p>This origin (<code>localhost:{PORT}</code>) is only reachable through PingAccess after a
PingFederate SSO session was established (and validated against PingDirectory).</p>
<h3>Injected identity headers</h3><table>{idents}</table>
<h3>All request headers</h3><table>{allhdrs}</table>
<p><a href="/pa/oidc/logout">Logout</a></p>
</body></html>"""
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("[sample-app] " + (fmt % args) + "\n")


if __name__ == "__main__":
    print(f"[sample-app] serving on http://localhost:{PORT}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
