"""Diagrams for the Ping Installer README.

Generated SVGs land in docs/images/. Render PNGs for GitHub with
tooling/make_diagrams.py (which shells out to rsvg-convert).

Palette is semantic and shared with the drawing kit:
  PD_*  PingDirectory (green)   PF_*  PingFederate (teal)
  PRX_* PingAccess    (orange)  LB_*  HAProxy / VIP (purple)
  USER_* browser (white)        SRC_* external (grey)
"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from svgkit import *  # noqa

PA_FILL, PA_LINE = PRX_FILL, PRX_LINE   # PingAccess reuses the gateway/orange role



# ============================================================ 2. install phases
def install_phases(OUT):
    W, H = 1120, 470
    s = SVG(W, H, "Three-phase installer flow")
    s.header("Three re-runnable phases",
             "Driven by pingconfig.env · state tracked in .install-state · every step idempotent (check-then-create)")

    y = s.chevrons(40, 92, W - 80, [
        ("Phase 1 · Install", "unzip · license · baseline start"),
        ("Phase 2 · Configure", "schema · datastore · adapters · clients"),
        ("Phase 3 · Integrate", "wire PA→PF · sample app · test users")],
        h=64, size=13, subsize=10)

    cards = [
        ("PingDirectory", "OUs, PF admin user + least-privilege service account, ACIs, PF "
         "schema, session + grant containers, and grant indexes.", PD_LINE),
        ("PingFederate", "LDAP admin auth, service-account datastore bind, externalized "
         "sessions + grants, IdP adapter, HTML-form PCV, OAuth / OIDC clients.", PF_LINE),
        ("PingAccess", "Accept SLA + rotate password, PingFederate token provider, virtual "
         "host, site, application, and the identity mapping to a header.", PA_LINE)]
    y = s.cards(40, y + 30, W - 80, cards, cols=3)

    s.callout(40, y + 22, W - 80,
              "Products install in dependency order — the data store first, the token service "
              "second (it needs the directory), the gateway last (it needs the token service). "
              "Any phase re-runs safely; completed phases are skipped unless --force is given.",
              title="Dependency order", kind="note")
    return [s.save(OUT / "install-phases.svg")]


# ============================================================ 3. SSO sequence
def sso_flow(OUT):
    W, H = 1120, 700
    s = SVG(W, H, "End-to-end SSO the installer proves")
    s.header("One login, end to end",
             "What the installer proves: a browser reaches the protected app and comes back with an injected identity")

    y = s.lanes(40, 78, W - 80,
                [("Browser", USER_FILL, USER_LINE),
                 ("PingAccess", PA_FILL, PA_LINE),
                 ("PingFederate", PF_FILL, PF_LINE),
                 ("PingDirectory", PD_FILL, PD_LINE)],
                [(0, 1, "GET https://app.example.com/"),
                 (1, 0, "302 → PingFederate (no session)", "dashed"),
                 (0, 2, "follow redirect to /as/authorization.oauth2"),
                 (2, 0, "HTML login form", "dashed"),
                 (0, 2, "POST testuser1 / password"),
                 (2, 3, "bind + search as service account"),
                 (3, 2, "user found; write SSO session", "dashed"),
                 (2, 0, "302 back to app with ?code="),
                 (0, 1, "deliver code to /pa/oidc/cb"),
                 (1, 2, "exchange code for tokens"),
                 (1, 0, "200 — app shows X-USER: testuser1", "dashed")],
                step_gap=38)

    s.callout(40, y + 16, W - 80,
              "The SSO session written at step 7 lands in ou=AuthenticationSessions in "
              "PingDirectory — durable across restarts, and in clustered mode present on both "
              "replicated nodes. The X-USER header is proof the whole chain fired.",
              title="Proof it worked", kind="ok")
    return [s.save(OUT / "sso-flow.svg")]


# ============================================================ 4. HA topology
def platform_topology(OUT):
    W, H = 1120, 780
    s = SVG(W, H, "Platform topology")
    s.header("One topology; HA is the only difference",
             "Everything is behind the load balancer. HA sets how many PingFederate and PingDirectory nodes sit behind it — dashed = added by HA=true")
    cx = W / 2

    s.node(cx - 120, 66, 240, 42, "Browser", sub="https · :443", fill=USER_FILL, stroke=USER_LINE,
           size=12.5, subsize=9.5)
    s.node(cx - 230, 138, 460, 58, "HAProxy load balancer",
           sub="single front door on :443 · routes by Host · app.example.com + ping.example.com",
           fill=LB_FILL, stroke=LB_LINE, size=13.5, subsize=10)
    s.line(cx, 108, cx, 138, sw=1.8)

    # PA (always 1) on the left; PF (node 1 always, node 2 added by HA) on the right
    pay = 282
    s.node(90, pay, 300, 84, "PingAccess", sub="engine :3000 · protects the app",
           fill=PA_FILL, stroke=PA_LINE, size=13.5, subsize=10)
    s.container(470, pay - 22, 560, 122, "PINGFEDERATE", fill=SITE_FILL, stroke=PF_LINE, dash=None)
    s.node(490, pay + 6, 250, 66, "node 1", sub="always on",
           fill=PF_FILL, stroke=PF_LINE, size=12.5, subsize=9.5)
    s.node(760, pay + 6, 250, 66, "node 2", sub="adds an engine",
           fill=PF_FILL, stroke=PF_LINE, size=12.5, subsize=9.5, dash="5 4", badge="HA")
    s.path(f"M 740 {pay+39} L 760 {pay+39}", both=True, stroke=PF_LINE, sw=1.5, dash="5 4")
    s.edge_label(750, pay + 29, "cluster")

    # LB -> PA (app.example.com) and LB -> PF (ping.example.com), by Host
    s.path(f"M {cx-160} 196 L {cx-160} 232 L 240 232 L 240 {pay}", sw=1.6)
    s.edge_label(310, 232, "app.example.com")
    s.path(f"M {cx+160} 196 L {cx+160} 232 L 890 232 L 890 {pay-22}", sw=1.6)
    s.edge_label(820, 232, "ping.example.com")

    # PA -> LB -> PF: PingAccess reaches PingFederate THROUGH the LB (issuer =
    # the LB URL), never an engine directly. Dashed arrow from PA back up to the LB.
    s.path(f"M 390 {pay+30} L 430 {pay+30} L 430 196", sw=1.5, dash="5 4", stroke=PA_LINE)
    s.edge_label(474, pay + 20, "token provider")
    s.edge_label(430, 214, "via ping.example.com")

    # PD (node 1 always, node 2 added by HA and replicated)
    pdy = 500
    s.container(300, pdy, 520, 150, "PINGDIRECTORY", fill=SITE_FILL, stroke=PD_LINE, dash=None)
    s.node(322, pdy + 40, 230, 84, "node 1", sub="LDAPS :1636",
           fill=PD_FILL, stroke=PD_LINE, size=13, subsize=10)
    s.node(568, pdy + 40, 230, 84, "node 2", sub="LDAPS :2636",
           fill=PD_FILL, stroke=PD_LINE, size=13, subsize=10, dash="5 4", badge="HA")
    s.path(f"M 552 {pdy+82} L 568 {pdy+82}", both=True, stroke=PD_LINE, sw=2, dash="5 4")
    s.edge_label(560, pdy + 72, "replication")
    s.caption(560, pdy + 138, "each node holds users · sessions · grants")

    # PingFederate -> PingDirectory: direct LDAPS (solid to node 1, dashed failover to node 2)
    s.path(f"M 750 {pay+100} L 750 472 L 437 472 L 437 {pdy+38}", sw=1.5, stroke=PF_LINE)
    s.path(f"M 750 {pay+100} L 750 472 L 683 472 L 683 {pdy+38}", sw=1.5, stroke=PF_LINE, dash="5 4")
    s.edge_label(560, 472, "LDAPS direct · failover in HA")

    s.callout(40, H - 80, W - 80,
              "PingAccess sits behind the load balancer and reaches PingFederate through it, at "
              "ping.example.com — never an engine node directly, so failover and scaling are transparent. "
              "HA=false is node 1 of each; HA=true adds the dashed second node: PingFederate becomes a "
              "console + engine cluster and PingDirectory replicates, with the PF-to-PD link failing over "
              "across both directory nodes over LDAPS.",
              title="Everything through the front door", kind="note")
    return [s.save(OUT / "topology.svg")]


# ============================================================ 5. externalized storage
def externalized_storage(OUT):
    W, H = 1120, 430
    s = SVG(W, H, "In-memory vs externalized session storage")
    s.header("Where PingFederate keeps its sessions",
             "The single toggle PINGFED_SESSION_STORAGE decides whether the stack is dev-grade or production-grade")

    lb, rb = s.split(40, 92, W - 80, 205, "MEMORY  —  dev only", "PINGDIRECTORY  —  production pattern")
    s.para(lb[0] + 20, lb[1] + 30, "Sessions and OAuth grants live in the PingFederate JVM heap.",
           lb[2] - 40, size=11, fill=INK)
    for i, t in enumerate(["Lost on every restart — users re-authenticate",
                           "Cannot be shared across engine nodes",
                           "Blocks horizontal scaling of the runtime"]):
        s.text(lb[0] + 20, lb[1] + 74 + i * 30, "✗", size=13, fill=BAD_LINE, anchor="start", weight="700")
        s.text(lb[0] + 42, lb[1] + 74 + i * 30, t, size=10.5, fill=INK, anchor="start")

    s.para(rb[0] + 20, rb[1] + 30, "Sessions and grants are written to the replicated directory.",
           rb[2] - 40, size=11, fill=INK)
    for i, t in enumerate(["Durable across PingFederate restarts",
                           "Shared by every engine — any node serves any user",
                           "Indexed + least-privilege service-account bind"]):
        s.text(rb[0] + 20, rb[1] + 74 + i * 30, "✓", size=13, fill=OK_LINE, anchor="start", weight="700")
        s.text(rb[0] + 42, rb[1] + 74 + i * 30, t, size=10.5, fill=INK, anchor="start")

    s.callout(40, H - 60, W - 80,
              "PINGFED_SESSION_STORAGE = pingdirectory | memory. The installer defaults to "
              "pingdirectory and provisions the ou=AuthenticationSessions and ou=AccessGrant "
              "containers, the service-account ACIs, and the grant indexes to back it.",
              title="One toggle in pingconfig.env", kind="note")
    return [s.save(OUT / "externalized-storage.svg")]


# ============================================================ 6. operator tooling
def operator_tooling(OUT):
    W, H = 1120, 430
    s = SVG(W, H, "Operator scripts that drive the stack")
    s.header("One toolbox drives the whole system",
             "Every script reads HA and manages exactly the components the config declares")

    cards = [
        ("ping-setup.sh", "Host prerequisites: JDK 21, install user, directories, /etc/hosts, "
         "ulimits, and firewall ports.", PD_LINE),
        ("install_ping.sh", "The phased orchestrator: preflight, .install-state tracking, "
         "--phase1/2/3, --force, --reinstall, rollback.", PF_LINE),
        ("ping-control.sh", "Start / stop / restart / status for pd pd2 pf pf2 pa app lb — "
         "dependency-ordered, detached, port-aware.", PA_LINE),
        ("ping-validate.sh", "Mode-aware read-only health checks — 23/23 green in clustered "
         "mode across every hop.", PD_LINE),
        ("ping-monitor.sh", "Terminal dashboard: replication, PF cluster, PF→PD link, LB "
         "routing, per-JVM memory. --watch to loop.", PF_LINE),
        ("ping-dashboard.py", "Live visual web dashboard on :8600 — topology and health, "
         "auto-refresh, stdlib server, no deps.", LB_LINE),
        ("ping-logs.sh", "Tail, follow (-f) or error-filter (-e) any product's logs by name.", PA_LINE),
        ("ping-test-sso.sh", "Drives the end-to-end browser SSO flow and asserts the injected "
         "identity header comes back.", PD_LINE)]
    y = s.cards(40, 92, W - 80, cards, cols=4)

    s.callout(40, y + 22, W - 80,
              "ping-control.sh start all brings the stack up in dependency order (pd → pd2 → pf "
              "→ pf2 → pa → app → lb); stop reverses it. Each PingFederate node is matched by its "
              "pf.home, so bouncing the console never touches the engine.",
              title="Whole-system lifecycle", kind="note")
    return [s.save(OUT / "operator-tooling.svg")]


def build(OUT):
    fns = (install_phases, sso_flow, platform_topology,
           externalized_storage, operator_tooling)
    return [p for fn in fns for p in fn(OUT)]
