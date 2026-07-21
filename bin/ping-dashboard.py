#!/usr/bin/env python3
# =============================================================================
# bin/ping-dashboard.py — Live visual monitor for the Ping stack.
#
#   A dependency-free (Python stdlib only) web dashboard. A background thread
#   polls the same live sources as ping-monitor.sh (port health, dsreplication
#   status, the PingFederate cluster API, the PF->PD datastore, LB routing,
#   per-JVM memory) into a snapshot; the browser auto-refreshes it via
#   /api/status and renders status tiles, a topology view, replication and
#   cluster panels, and a memory panel — light/dark aware.
#
#   Config is read from pingconfig.env (sourced at startup). Start via
#   `bin/ping-control.sh start dash` or directly:
#       bash -c 'source ./pingconfig.env && python3 bin/ping-dashboard.py'
# =============================================================================
import base64, json, os, re, shutil, socket, ssl, subprocess, tempfile, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load_env():
    """Source pingconfig.env in a subshell and capture the resolved variables."""
    try:
        # set -a auto-exports every assignment so `env` lists them (pingconfig.env
        # uses plain KEY=VALUE, not `export`, so a bare source wouldn't surface them).
        out = subprocess.check_output(
            ["bash", "-c", "set -a; source ./pingconfig.env >/dev/null 2>&1; set +a; env"],
            cwd=ROOT, text=True, timeout=15)
        env = {}
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1); env[k] = v
        return env
    except Exception:
        return dict(os.environ)

E = load_env()
def g(k, d=""): return E.get(k, d)
def gi(k, d=0):
    try: return int(E.get(k, d))
    except Exception: return d

PD1_DIR, PD2_DIR = g("PINGDIR_DIR"), g("PINGDIR2_DIR")
PF1_DIR, PF2_DIR = g("PINGFED_DIR"), g("PINGFED2_DIR")
PA_DIR = g("PINGACCESS_DIR")
PD_COUNT, PF_COUNT = gi("PINGDIR_COUNT", 1), gi("PINGFED_COUNT", 1)
LB_ON = g("LB_ENABLED", "false") == "true"
PF_HOST = g("PINGFED_HOSTNAME", "localhost")
PF_ADMIN_PORT = gi("PINGFED_ADMIN_PORT", 9999)
PF2_ENGINE_PORT = gi("PINGFED2_ENGINE_PORT", 9032)
PF_ENGINE_PORT = gi("PINGFED_ENGINE_PORT", 9031)
PA_HOST = g("PINGACCESS_HOSTNAME", "localhost")
PA_ADMIN_PORT = gi("PINGACCESS_ADMIN_PORT", 9000)
PA_ENGINE_PORT = gi("PINGACCESS_ENGINE_PORT", 3000)
PA_ADMIN_API = g("PINGACCESS_ADMIN_API")
PD1_LDAP, PD1_LDAPS = gi("PINGDIR_LDAP_PORT", 1389), gi("PINGDIR_LDAPS_PORT", 1636)
PD2_LDAP, PD2_LDAPS = gi("PINGDIR2_LDAP_PORT", 2389), gi("PINGDIR2_LDAPS_PORT", 2636)
PD_ROOT_DN, PD_PW = g("PINGDIR_ROOT_DN"), g("PINGDIR_ROOT_PASSWORD")
REPL_UID = g("PINGDIR_REPL_ADMIN_UID", "admin")
DS_ID = g("PINGFED_PD_DATASTORE_ID", "pingdirectory-ldap")
PF_ADMIN_UID, PF_PW = g("PINGFED_ADMIN_UID", "pfadmin"), g("DEFAULT_PASSWORD")
LB_PORT = gi("LB_HTTPS_PORT", 443)
LB_PF_URL = g("LB_PF_BASE_URL", "https://%s" % PF_HOST)
LB_APP_URL = g("LB_APP_BASE_URL", "https://app.example.com")
APP_PORT = int((g("SAMPLE_APP_TARGET", "http://localhost:8090").rsplit(":", 1)[-1]).split("/")[0])
RT_URL = LB_PF_URL if LB_ON else g("PINGFED_BASE_URL", "https://%s:%d" % (PF_HOST, PF_ENGINE_PORT))
APP_URL = LB_APP_URL if LB_ON else "https://%s:%d" % (g("SAMPLE_APP_VIRTUAL_HOST", "app.example.com"), PA_ENGINE_PORT)
DASH_PORT = gi("DASHBOARD_PORT", 8600)
DASH_CERT = g("DASHBOARD_CERT") or "%s/dashboard/dashboard.pem" % g("BASE_INSTALL_DIR", "/ping")
PFADMIN = "https://%s:%d/pf-admin-api/v1" % (PF_HOST, PF_ADMIN_PORT)

def host_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]; s.close(); return ip
    except Exception: return "127.0.0.1"

def ensure_cert():
    """Self-signed cert for the dashboard (SAN covers ping.<domain> + host IP).
    The stack is HTTPS end-to-end, so browsers force TLS on this port too."""
    if os.path.exists(DASH_CERT): return DASH_CERT
    try:
        os.makedirs(os.path.dirname(DASH_CERT), exist_ok=True)
        td = tempfile.mkdtemp(); key = os.path.join(td, "k"); crt = os.path.join(td, "c")
        san = "subjectAltName=DNS:%s,DNS:localhost,IP:%s,IP:127.0.0.1" % (PF_HOST, host_ip())
        subprocess.check_call(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
             "-out", crt, "-days", "825", "-subj", "/CN=%s" % PF_HOST, "-addext", san],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        with open(DASH_CERT, "w") as o: o.write(open(crt).read()); o.write(open(key).read())
        os.chmod(DASH_CERT, 0o600); shutil.rmtree(td, ignore_errors=True)
        return DASH_CERT
    except Exception:
        return None

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE

# ---- collectors -------------------------------------------------------------
def port_up(port, host="127.0.0.1"):
    try:
        with socket.create_connection((host, port), timeout=2): return True
    except Exception: return False

def http_code(url):
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=5, context=CTX) as r: return r.status
    except urllib.error.HTTPError as e: return e.code
    except Exception: return 0

def pf_get(path):
    try:
        req = urllib.request.Request(PFADMIN + path)
        tok = base64.b64encode(("%s:%s" % (PF_ADMIN_UID, PF_PW)).encode()).decode()
        req.add_header("Authorization", "Basic " + tok)
        req.add_header("X-XSRF-Header", "PingFederate")
        with urllib.request.urlopen(req, timeout=6, context=CTX) as r:
            return json.loads(r.read().decode())
    except Exception: return None

def pgrep1(pat):
    try:
        out = subprocess.check_output(["pgrep", "-f", pat], text=True, timeout=4)
        for pid in out.split():
            if pid.strip() and pid.strip() != str(os.getpid()): return int(pid)
    except Exception: pass
    return None

def rss_mb(pid):
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith("VmRSS:"): return round(int(line.split()[1]) / 1024)
    except Exception: pass
    return None

def replication():
    if PD_COUNT <= 1: return None
    src_port = PD1_LDAPS if port_up(PD1_LDAPS) else PD2_LDAPS
    if not port_up(src_port): return {"enabled": False, "nodes": [], "insync": False}
    pwf = None
    try:
        import tempfile
        fd, pwf = tempfile.mkstemp(); os.write(fd, PD_PW.encode()); os.close(fd); os.chmod(pwf, 0o600)
        out = subprocess.check_output(
            ["%s/bin/dsreplication" % PD1_DIR, "status", "--hostname", "localhost",
             "--port", str(src_port), "--useSSL", "--trustAll", "--adminUID", REPL_UID,
             "--adminPasswordFile", pwf, "--no-prompt"], text=True, timeout=20,
            stderr=subprocess.DEVNULL)
    except Exception:
        return {"enabled": False, "nodes": [], "insync": False}
    finally:
        if pwf and os.path.exists(pwf): os.remove(pwf)
    nodes, enabled = [], "Enabled" in out
    for line in out.splitlines():
        if re.match(r"\s*pingdirectory-\d", line):
            cols = re.split(r"\s+:\s+", line.strip())
            if len(cols) >= 5:
                name = cols[0].split(" ")[0]
                try: entries, backlog = int(cols[2]), int(cols[4])
                except Exception: entries, backlog = None, None
                nodes.append({"name": name, "entries": entries, "backlog": backlog})
    insync = enabled and nodes and all((n["backlog"] == 0) for n in nodes if n["backlog"] is not None)
    return {"enabled": enabled, "nodes": nodes, "insync": bool(insync)}

def cluster():
    if PF_COUNT <= 1: return None
    d = pf_get("/cluster/status")
    if not d: return {"nodes": [], "required": None, "ok": False}
    nodes = [{"index": n.get("index"), "mode": n.get("mode"), "address": n.get("address"),
              "repl": n.get("replicationStatus")} for n in d.get("nodes", [])]
    ok = any(n["mode"] == "CLUSTERED_CONSOLE" for n in nodes) and \
         any(n["mode"] == "CLUSTERED_ENGINE" for n in nodes) and \
         all(n["repl"] == "SUCCEEDED" for n in nodes)
    return {"nodes": nodes, "required": d.get("replicationRequired"), "ok": ok}

def pf_pd_link():
    out = {"datastore_ssl": None, "hostnames": [], "admin_ldaps": None}
    ds = pf_get("/dataStores/%s" % DS_ID)
    if ds:
        out["datastore_ssl"] = bool(ds.get("useSsl"))
        out["hostnames"] = ds.get("hostnames", [])
    try:
        with open("%s/bin/ldap.properties" % PF1_DIR) as f:
            for line in f:
                if line.startswith("ldap.url="):
                    out["admin_ldaps"] = line.split("=", 1)[1].strip().startswith("ldaps://")
                    out["admin_url"] = line.split("=", 1)[1].strip()
    except Exception: pass
    return out

def resources():
    mt = ma = 0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"): mt = int(line.split()[1])
                elif line.startswith("MemAvailable:"): ma = int(line.split()[1])
    except Exception: pass
    specs = [("PD-1", "%s/config/config.ldif" % PD1_DIR)]
    if PD_COUNT > 1: specs.append(("PD-2", "%s/config/config.ldif" % PD2_DIR))
    specs.append(("PF-1", "pf.home=%s " % PF1_DIR))
    if PF_COUNT > 1: specs.append(("PF-2", "pf.home=%s " % PF2_DIR))
    specs.append(("PA", "com.pingidentity.pa.cli.Starter"))
    jvms = []
    for label, pat in specs:
        pid = pgrep1(pat)
        jvms.append({"label": label, "pid": pid, "rss_mb": rss_mb(pid) if pid else None})
    return {"mem_total_mb": round(mt / 1024), "mem_used_mb": round((mt - ma) / 1024),
            "mem_avail_mb": round(ma / 1024), "jvms": jvms}

def components():
    c = [{"id": "pd1", "name": "PingDirectory-1", "role": "node 1",
          "up": port_up(PD1_LDAPS), "detail": "LDAP %d / LDAPS %d" % (PD1_LDAP, PD1_LDAPS)}]
    if PD_COUNT > 1:
        c.append({"id": "pd2", "name": "PingDirectory-2", "role": "node 2 (replica)",
                  "up": port_up(PD2_LDAPS), "detail": "LDAP %d / LDAPS %d" % (PD2_LDAP, PD2_LDAPS)})
    c.append({"id": "pf1", "name": "PingFederate-1", "role": "CONSOLE" if PF_COUNT > 1 else "STANDALONE",
              "up": port_up(PF_ADMIN_PORT), "detail": "admin %d" % PF_ADMIN_PORT})
    if PF_COUNT > 1:
        hb = http_code("https://%s:%d/pf/heartbeat.ping" % (PF_HOST, PF2_ENGINE_PORT))
        c.append({"id": "pf2", "name": "PingFederate-2", "role": "ENGINE",
                  "up": port_up(PF2_ENGINE_PORT), "detail": "engine %d · heartbeat %d" % (PF2_ENGINE_PORT, hb)})
    c.append({"id": "pa", "name": "PingAccess", "role": "gateway",
              "up": port_up(PA_ADMIN_PORT), "detail": "admin %d / engine %d" % (PA_ADMIN_PORT, PA_ENGINE_PORT)})
    c.append({"id": "app", "name": "Sample app", "role": "origin",
              "up": port_up(APP_PORT), "detail": "origin :%d" % APP_PORT})
    if LB_ON:
        c.append({"id": "lb", "name": "Load Balancer", "role": "HAProxy (TLS)",
                  "up": port_up(LB_PORT), "detail": ":%d" % LB_PORT})
    return c

def collect():
    lb = None
    if LB_ON:
        lb = {"pf": http_code(LB_PF_URL + "/pf/heartbeat.ping"), "app": http_code(LB_APP_URL + "/")}
    return {"ts": int(time.time()),
            "mode": {"pd": PD_COUNT, "pf": PF_COUNT, "lb": LB_ON},
            "urls": {"pf_admin": "https://%s:%d/pingfederate/app" % (PF_HOST, PF_ADMIN_PORT),
                     "pa_admin": "https://%s:%d/" % (PA_HOST, PA_ADMIN_PORT),
                     "app": APP_URL + "/", "issuer": RT_URL},
            "components": components(), "replication": replication(),
            "cluster": cluster(), "link": pf_pd_link(), "lb": lb, "resources": resources()}

SNAP = {"ts": 0, "loading": True}
LOCK = threading.Lock()
def collector_loop(interval=5):
    global SNAP
    while True:
        try:
            s = collect()
            with LOCK: SNAP = s
        except Exception as ex:
            with LOCK: SNAP = {"ts": int(time.time()), "error": str(ex)}
        time.sleep(interval)

# ---- HTTP -------------------------------------------------------------------
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype):
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/api/status"):
            with LOCK: body = json.dumps(SNAP).encode()
            self._send(200, body, "application/json")
        elif self.path == "/" or self.path.startswith("/index"):
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain")

PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ping Stack — Live Monitor</title>
<style>
:root{
  --bg:#f4f6f9; --surface:#ffffff; --surface2:#f0f2f6; --border:#dfe3ea;
  --ink:#1c2430; --muted:#5b6675; --faint:#8a94a3;
  --good:#1f9d57; --good-bg:#e5f5ec; --warn:#b7791f; --warn-bg:#fbf1dc;
  --crit:#d13b3b; --crit-bg:#fbe7e7; --accent:#3557b7;
  --shadow:0 1px 2px rgba(20,30,50,.06),0 2px 8px rgba(20,30,50,.05);
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0f1420; --surface:#171d2b; --surface2:#1e2637; --border:#2a3345;
  --ink:#e7ecf3; --muted:#9aa6b6; --faint:#697384;
  --good:#3fce7f; --good-bg:#123024; --warn:#e0b458; --warn-bg:#332811;
  --crit:#f27171; --crit-bg:#361a1c; --accent:#7f9cf0;
  --shadow:0 1px 2px rgba(0,0,0,.3),0 2px 10px rgba(0,0,0,.25);
}}
:root[data-theme=dark]{
  --bg:#0f1420; --surface:#171d2b; --surface2:#1e2637; --border:#2a3345;
  --ink:#e7ecf3; --muted:#9aa6b6; --faint:#697384;
  --good:#3fce7f; --good-bg:#123024; --warn:#e0b458; --warn-bg:#332811;
  --crit:#f27171; --crit-bg:#361a1c; --accent:#7f9cf0;
}
:root[data-theme=light]{
  --bg:#f4f6f9; --surface:#ffffff; --surface2:#f0f2f6; --border:#dfe3ea;
  --ink:#1c2430; --muted:#5b6675; --faint:#8a94a3;
  --good:#1f9d57; --good-bg:#e5f5ec; --warn:#b7791f; --warn-bg:#fbf1dc;
  --crit:#d13b3b; --crit-bg:#fbe7e7; --accent:#3557b7;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:20px 18px 48px}
header{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin-bottom:18px}
h1{font-size:19px;margin:0;font-weight:650;letter-spacing:.2px}
.sub{color:var(--muted);font-size:12.5px}
.pill{display:inline-flex;align-items:center;gap:7px;padding:5px 12px;border-radius:999px;font-weight:600;font-size:13px}
.pill.good{background:var(--good-bg);color:var(--good)} .pill.crit{background:var(--crit-bg);color:var(--crit)} .pill.warn{background:var(--warn-bg);color:var(--warn)}
.spacer{flex:1}
.meta{color:var(--faint);font-size:12px;display:flex;align-items:center;gap:10px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--good);box-shadow:0 0 0 0 var(--good);animation:pulse 2s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(63,206,127,.5)}70%{box-shadow:0 0 0 7px rgba(63,206,127,0)}100%{box-shadow:0 0 0 0 rgba(63,206,127,0)}}
button.theme{background:var(--surface);border:1px solid var(--border);color:var(--muted);border-radius:8px;padding:5px 10px;cursor:pointer;font-size:12px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:16px}
.tile{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px 16px;box-shadow:var(--shadow)}
.tile .k{color:var(--muted);font-size:12px;font-weight:500}
.tile .v{font-size:26px;font-weight:680;margin-top:4px;font-variant-numeric:tabular-nums}
.tile .v small{font-size:14px;color:var(--faint);font-weight:500}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:16px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:16px 18px;box-shadow:var(--shadow)}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted);margin:0 0 12px;font-weight:600}
.full{grid-column:1/-1}
.badge{display:inline-flex;align-items:center;gap:5px;font-size:11.5px;font-weight:650;padding:2px 8px;border-radius:6px;white-space:nowrap}
.badge.good{background:var(--good-bg);color:var(--good)} .badge.crit{background:var(--crit-bg);color:var(--crit)} .badge.warn{background:var(--warn-bg);color:var(--warn)}
.row{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--border)}
.row:last-child{border-bottom:0}
.row .name{font-weight:600} .row .det{color:var(--faint);font-size:12px}
.topo{display:flex;align-items:stretch;gap:10px;overflow-x:auto;padding:4px 0}
.tier{display:flex;flex-direction:column;gap:8px;justify-content:center;min-width:118px}
.arrow{display:flex;align-items:center;color:var(--faint);font-size:20px;padding:0 2px}
.node{border:1.5px solid var(--border);border-radius:10px;padding:9px 11px;background:var(--surface2);min-width:118px}
.node.good{border-color:var(--good)} .node.crit{border-color:var(--crit)}
.node .nn{font-weight:650;font-size:12.5px;display:flex;align-items:center;gap:6px}
.node .nd{color:var(--faint);font-size:11px;margin-top:2px}
.led{width:8px;height:8px;border-radius:50%;display:inline-block;flex:0 0 auto}
.led.good{background:var(--good)} .led.crit{background:var(--crit)} .led.warn{background:var(--warn)}
.bar{height:8px;border-radius:5px;background:var(--surface2);overflow:hidden;margin-top:6px}
.bar > i{display:block;height:100%;border-radius:5px;background:var(--accent)}
.bar.good > i{background:var(--good)} .bar.warn > i{background:var(--warn)} .bar.crit > i{background:var(--crit)}
.kv{color:var(--faint);font-size:12px} .mono{font-variant-numeric:tabular-nums;font-feature-settings:"tnum"}
a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline}
.muted{color:var(--muted)} .err{color:var(--crit);font-weight:600}
</style></head>
<body>
<div class="wrap">
<header>
  <h1>Ping Stack</h1><span class="sub">live monitor</span>
  <span id="overall" class="pill good">—</span>
  <span class="spacer"></span>
  <span class="meta"><span class="dot" id="beat"></span><span id="updated">connecting…</span></span>
  <button class="theme" id="themeBtn" title="Toggle theme">◐ theme</button>
</header>
<div class="tiles" id="tiles"></div>
<div class="card full" style="margin-bottom:16px"><h2>Topology &amp; traffic path</h2><div class="topo" id="topo"></div></div>
<div class="grid">
  <div class="card"><h2>Components</h2><div id="components"></div></div>
  <div class="card" id="replCard"><h2>PingDirectory replication</h2><div id="replication"></div></div>
  <div class="card" id="clusterCard"><h2>PingFederate cluster</h2><div id="cluster"></div></div>
  <div class="card" id="linkCard"><h2>PingFederate → PingDirectory link</h2><div id="link"></div></div>
  <div class="card full"><h2>Resources</h2><div id="resources"></div></div>
</div>
</div>
<script>
const REFRESH=5000;
const $=(id)=>document.getElementById(id);
const esc=(s)=>String(s==null?'':s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const cls=(ok)=>ok?'good':'crit';
const ico=(ok)=>ok?'✓':'✗';
function badge(ok,txt){return `<span class="badge ${cls(ok)}">${ico(ok)} ${esc(txt)}</span>`}
function warnbadge(txt){return `<span class="badge warn">● ${esc(txt)}</span>`}

// theme toggle (persists)
(function(){const s=localStorage.getItem('pingTheme'); if(s)document.documentElement.setAttribute('data-theme',s);
 $('themeBtn').onclick=()=>{const cur=document.documentElement.getAttribute('data-theme')||
   (matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');
   const nxt=cur==='dark'?'light':'dark'; document.documentElement.setAttribute('data-theme',nxt);
   localStorage.setItem('pingTheme',nxt);};})();

let lastTs=0;
async function tick(){
  let d; try{ d=await (await fetch('/api/status',{cache:'no-store'})).json(); }
  catch(e){ $('updated').innerHTML='<span class="err">dashboard unreachable</span>'; return; }
  if(d.loading){ $('updated').textContent='collecting…'; return; }
  render(d);
}
function agesec(ts){return Math.max(0,Math.floor(Date.now()/1000-ts));}
function render(d){
  if(d.error){ $('overall').className='pill crit'; $('overall').textContent='collector error'; return; }
  const comps=d.components||[];
  const down=comps.filter(c=>!c.up);
  const allUp=down.length===0;
  $('overall').className='pill '+(allUp?'good':'crit');
  $('overall').innerHTML=(allUp?'✓ All systems operational':'✗ '+down.length+' component'+(down.length>1?'s':'')+' down');
  lastTs=d.ts; $('updated').textContent='updated '+agesec(d.ts)+'s ago';

  // tiles
  const r=d.resources||{}, memPct=r.mem_total_mb?Math.round(100*r.mem_used_mb/r.mem_total_mb):0;
  const repl=d.replication, clu=d.cluster;
  const backlog=repl&&repl.nodes?repl.nodes.reduce((a,n)=>a+(n.backlog||0),0):null;
  const cok=clu?clu.nodes.filter(n=>n.repl==='SUCCEEDED').length:null, ctot=clu?clu.nodes.length:null;
  const tiles=[
    ['Components up', `${comps.length-down.length}<small>/${comps.length}</small>`, allUp?'good':'crit'],
  ];
  if(repl) tiles.push(['Replication backlog', backlog==null?'?':backlog, (backlog===0)?'good':'warn']);
  if(clu)  tiles.push(['Cluster nodes OK', `${cok}<small>/${ctot}</small>`, (clu.ok?'good':'warn')]);
  tiles.push(['Memory used', `${memPct}<small>%</small>`, memPct<85?'good':(memPct<95?'warn':'crit')]);
  $('tiles').innerHTML=tiles.map(([k,v,c])=>`<div class="tile"><div class="k">${k}</div><div class="v" style="color:var(--${c})">${v}</div></div>`).join('');

  // topology
  const byid={}; comps.forEach(c=>byid[c.id]=c);
  const node=(c)=>c?`<div class="node ${cls(c.up)}"><div class="nn"><span class="led ${cls(c.up)}"></span>${esc(c.name)}</div><div class="nd">${esc(c.role)}</div></div>`:'';
  const tiers=[];
  tiers.push(`<div class="tier"><div class="node"><div class="nn">🌐 Browser</div><div class="nd">:${d.mode.lb?'443':''}</div></div></div>`);
  if(byid.lb){tiers.push('<div class="arrow">→</div>'); tiers.push(`<div class="tier">${node(byid.lb)}</div>`);}
  tiers.push('<div class="arrow">→</div>');
  tiers.push(`<div class="tier">${node(byid.pf2)||node(byid.pf1)}${node(byid.pa)}</div>`);
  tiers.push('<div class="arrow">→</div>');
  tiers.push(`<div class="tier">${node(byid.pd1)}${byid.pd2?node(byid.pd2):''}</div>`);
  $('topo').innerHTML=tiers.join('');

  // components list
  $('components').innerHTML=comps.map(c=>`<div class="row"><div><div class="name">${esc(c.name)} <span class="kv">${esc(c.role)}</span></div><div class="det">${esc(c.detail)}</div></div>${c.up?badge(true,'UP'):badge(false,'DOWN')}</div>`).join('');

  // replication
  if(repl){ $('replCard').style.display='';
    let h=`<div style="margin-bottom:10px">${repl.enabled?badge(true,'Enabled'):badge(false,'Not enabled')} ${repl.insync?badge(true,'In sync'):warnbadge('Syncing / backlog')}</div>`;
    const maxE=Math.max(1,...repl.nodes.map(n=>n.entries||0));
    h+=repl.nodes.map(n=>{const bl=n.backlog||0;return `<div class="row"><div><div class="name">${esc(n.name)}</div><div class="bar ${bl===0?'good':'warn'}"><i style="width:${Math.round(100*(n.entries||0)/maxE)}%"></i></div></div><div style="text-align:right"><div class="mono">${n.entries==null?'?':n.entries} entries</div><div class="det mono">backlog ${bl}</div></div></div>`;}).join('');
    $('replication').innerHTML=h;
  } else $('replCard').style.display='none';

  // cluster
  if(clu){ $('clusterCard').style.display='';
    let h=`<div style="margin-bottom:10px">${clu.ok?badge(true,'Cluster healthy'):warnbadge('Degraded')} ${clu.required===false?'<span class="kv">config in sync</span>':(clu.required?warnbadge('replication required'):'')}</div>`;
    h+=clu.nodes.map(n=>`<div class="row"><div><div class="name">node ${esc(n.index)} · ${esc(n.mode)}</div><div class="det mono">${esc(n.address)}</div></div>${n.repl==='SUCCEEDED'?badge(true,n.repl):warnbadge(n.repl||'?')}</div>`).join('');
    $('cluster').innerHTML=h;
  } else $('clusterCard').style.display='none';

  // PF -> PD link
  const lk=d.link||{};
  let lh='';
  if(lk.datastore_ssl!=null) lh+=`<div class="row"><div class="name">Runtime datastore</div>${lk.datastore_ssl?badge(true,'LDAPS'):badge(false,'plaintext')}</div>`;
  lh+=`<div class="row"><div class="name">Admin-console auth</div>${lk.admin_ldaps?badge(true,'LDAPS'):(lk.admin_ldaps===false?badge(false,'plaintext'):warnbadge('n/a'))}</div>`;
  if(lk.hostnames&&lk.hostnames.length) lh+=`<div class="row"><div><div class="name">Failover hosts</div><div class="det mono">${lk.hostnames.map(esc).join('<br>')}</div></div>${badge(lk.hostnames.length>1,lk.hostnames.length+' hosts')}</div>`;
  $('link').innerHTML=lh;
  if(d.mode.pd<=1&&d.mode.pf<=1) $('linkCard').style.display=lk.datastore_ssl==null?'none':'';

  // resources
  let rh=`<div class="row"><div style="flex:1"><div class="name">Memory <span class="kv">${(r.mem_used_mb/1024).toFixed(1)} / ${(r.mem_total_mb/1024).toFixed(1)} GiB</span></div><div class="bar ${memPct<85?'good':(memPct<95?'warn':'crit')}"><i style="width:${memPct}%"></i></div></div><div class="mono" style="margin-left:12px">${memPct}%</div></div>`;
  const maxR=Math.max(1,...(r.jvms||[]).map(j=>j.rss_mb||0));
  rh+=(r.jvms||[]).map(j=>`<div class="row"><div style="flex:1"><div class="name">${esc(j.label)} ${j.pid?'<span class="kv mono">pid '+j.pid+'</span>':warnbadge('stopped')}</div>${j.rss_mb?`<div class="bar"><i style="width:${Math.round(100*j.rss_mb/maxR)}%"></i></div>`:''}</div><div class="mono" style="margin-left:12px">${j.rss_mb?j.rss_mb+' MB':'—'}</div></div>`).join('');
  $('resources').innerHTML=rh;
}
setInterval(()=>{ if(lastTs) $('updated').textContent='updated '+agesec(lastTs)+'s ago'; }, 1000);
tick(); setInterval(tick, REFRESH);
</script>
</body></html>"""

if __name__ == "__main__":
    threading.Thread(target=collector_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", DASH_PORT), H)
    scheme = "http"
    pem = ensure_cert()
    if pem:
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(pem)
            srv.socket = ctx.wrap_socket(srv.socket, server_side=True); scheme = "https"
        except Exception as ex:
            print("TLS setup failed (%s) — serving plaintext HTTP" % ex)
    print("Ping dashboard on %s://0.0.0.0:%d  (mode PDx%d PFx%d LB=%s)" % (scheme, DASH_PORT, PD_COUNT, PF_COUNT, LB_ON))
    try: srv.serve_forever()
    except KeyboardInterrupt: pass
