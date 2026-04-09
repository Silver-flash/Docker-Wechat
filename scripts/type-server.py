#!/usr/bin/env python3
"""
/paste       POST  {text}  — set X11 clipboard + Ctrl+V to focused window
/toggle-ime  POST         — toggle ibus Chinese/English, return new state
/ime-status  GET          — return current state {"state":"中"|"En"}
"""
import http.server, subprocess, os, json, time

DISPLAY = os.environ.get("DISPLAY", ":1")

# Server-side IM state mirror
_ime = "En"


def _env():
    return {**os.environ, "DISPLAY": DISPLAY}


def _apply_ime(state):
    """Switch ibus engine between English keyboard and libpinyin."""
    env = _env()
    engine = "libpinyin" if state == "中" else "xkb:us::eng"
    subprocess.run(["ibus", "engine", engine], env=env, check=False)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/ime-status":
            self._json({"state": _ime})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        global _ime

        if self.path == "/toggle-ime":
            _ime = "中" if _ime == "En" else "En"
            _apply_ime(_ime)
            self._json({"state": _ime})
            return

        if self.path == "/paste":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length)
            try:
                text = json.loads(raw.decode("utf-8")).get("text", "")
            except Exception:
                text = raw.decode("utf-8", errors="replace")

            if not text:
                self.send_response(400)
                self._cors()
                self.end_headers()
                return

            env = _env()

            # Set both X11 clipboard selections to UTF-8 text
            for sel in ("primary", "clipboard"):
                p = subprocess.Popen(
                    ["xclip", "-selection", sel, "-rmlastnl"],
                    stdin=subprocess.PIPE, env=env,
                )
                p.communicate(text.encode("utf-8"))

            # Give xclip's background process time to become selection owner
            time.sleep(0.15)

            # Send Ctrl+V to whichever X11 window currently has focus
            r = subprocess.run(
                ["xdotool", "getactivewindow"],
                capture_output=True, text=True, env=env,
            )
            win = r.stdout.strip()
            if win:
                subprocess.run(
                    ["xdotool", "key", "--clearmodifiers", "--window", win, "ctrl+v"],
                    env=env, check=False,
                )
            else:
                subprocess.run(
                    ["xdotool", "key", "--clearmodifiers", "ctrl+v"],
                    env=env, check=False,
                )

            self.send_response(200)
            self._cors()
            self.end_headers()
            self.wfile.write(b"ok")
            return

        self.send_response(404)
        self.end_headers()

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def log_message(self, *a):
        pass


http.server.HTTPServer(("0.0.0.0", 7070), Handler).serve_forever()
