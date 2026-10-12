"""A tiny stand-in for the GitHub API, for test/run.sh only.

Serves /repos/<owner>/<repo>/releases/latest and /assets/<name> from the folder given as argv[2]:
  <folder>/release.json  the release document (asset "url"s are rewritten to this server)
  <folder>/<asset name>  the files
Private repositories (argv[3] = "private") need "Authorization: Bearer test-token"; the header is logged to
<folder>/auth.log so the test can check that the redirect target never received it.
An asset listed in <folder>/redirect-http gets a 302 to a plain-http address (which the installer must refuse).
"""

import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
ROOT = pathlib.Path(sys.argv[2])
PRIVATE = sys.argv[3] == "private"
BASE = f"http://127.0.0.1:{PORT}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        auth = self.headers.get("Authorization")
        with open(ROOT / "auth.log", "a") as log:
            log.write(f"{self.path} {'auth' if auth else 'noauth'}\n")
        if self.path.startswith("/storage/"):
            name = self.path.removeprefix("/storage/")
            return self._send(200, (ROOT / name).read_bytes())
        if PRIVATE and auth != "Bearer test-token":
            return self._send(404, b'{"message":"Not Found"}')
        if self.path.endswith("/releases/latest"):
            doc = json.loads((ROOT / "release.json").read_text())
            for a in doc["assets"]:
                a["url"] = f"{BASE}/assets/{a['name']}"
            return self._send(200, json.dumps(doc).encode())
        if self.path.startswith("/assets/"):
            name = self.path.removeprefix("/assets/")
            redirect = ROOT / "redirect-http"
            if redirect.exists() and name in redirect.read_text().split():
                return self._send(302, headers={"Location": f"{BASE}/storage/{name}"})
            return self._send(200, (ROOT / name).read_bytes())
        return self._send(404)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
