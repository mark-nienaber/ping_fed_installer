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


# ============================================================ 1. architecture
def arch_overview(OUT):
    W, H = 1040, 800
    s = SVG(W, H, "Integrated Ping stack the installer builds")
    cx = W / 2
    s.header("The stack the installer builds",
             "One host, three products, wired the way a customer runs them — sessions and grants kept in the directory")

    bw = 440
    bx = cx - bw / 2
    s.node(cx - 110, 74, 220, 44, "Browser", fill=USER_FILL, stroke=USER_LINE, size=13)

    # PingAccess
    s.node(bx, 156, bw, 66, "PingAccess", sub="enforcement point  ·  vhost app.example.com",
           fill=PA_FILL, stroke=PA_LINE, size=14, subsize=10.5, badge="9000 / 3000")
    # PingFederate
    s.node(bx, 288, bw, 66, "PingFederate", sub="OAuth 2.0 / OIDC token service  ·  IdP adapter",
           fill=PF_FILL, stroke=PF_LINE, size=14, subsize=10.5, badge="9999 / 9031")

    # PingDirectory container with its DIT
    dy = 420
    s.container(bx - 6, dy, bw + 12, 250, "PINGDIRECTORY — DATA + SESSION STORE",
                fill=SITE_FILL, stroke=PD_LINE, dash=None)
    ou = [("ou=people", "end users"), ("ou=applications", "cn=pingfederate service acct"),
          ("ou=AuthenticationSessions", "PF SSO sessions"), ("ou=AccessGrant", "PF OAuth grants")]
    oy = dy + 40
    for i, (dn, note) in enumerate(ou):
        yy = oy + i * 50
        s.rect(bx + 18, yy, bw - 36, 40, "#ffffff", PD_LINE, r=6, sw=1.3)
        s.text(bx + 34, yy + 24, dn, size=12, weight="700", anchor="start", family=MONO)
        s.text(bx + bw - 34, yy + 24, note, size=10.5, fill=MUTED, anchor="end")
    s.caption(cx, dy + 250 + 18, "LDAP 1389  ·  LDAPS 1636 (+ admin connector)  ·  HTTPS 1443 (Admin API / SCIM)")

    # edges — each line ends exactly ON its target box's top border, so the
    # arrowhead tip (which sits at the line's end) lands on the box line.
    s.line(cx, 118, cx, 156, sw=1.8)
    s.edge_label(cx, 138, "1 · GET protected app")
    s.line(cx, 222, cx, 288, sw=1.8)
    s.edge_label(cx, 255, "2 · no session → OIDC redirect")
    # PF -> PD: two labelled arrows landing on the directory container border
    s.path(f"M {cx-70} 354 L {cx-70} {dy}", sw=1.6)
    s.edge_label(cx - 70, 388, "3 · bind + search")
    s.path(f"M {cx+70} 354 L {cx+70} {dy}", sw=1.6)
    s.edge_label(cx + 70, 388, "4 · persist session + grants")

    s.callout(bx, 710, bw, "In-memory sessions die on every restart and cannot be shared "
              "across engines. Writing them to PingDirectory makes SSO durable and cluster-ready.",
              title="Why sessions live in the directory", kind="note")
    return [s.save(OUT / "arch-overview.svg")]


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
def ha_topology(OUT):
    W, H = 1120, 740
    s = SVG(W, H, "Clustered / load-balanced topology")
    s.header("Clustered mode — set the counts, get an HA stack",
             "PINGDIR_COUNT=2 · PINGFED_COUNT=2 · LB_ENABLED=true builds this instead of single-node")
    cx = W / 2

    s.node(cx - 120, 72, 240, 44, "Browser", sub="https · :443", fill=USER_FILL, stroke=USER_LINE,
           size=12.5, subsize=9.5)
    s.node(cx - 210, 146, 420, 56, "HAProxy load balancer",
           sub="terminates client TLS on :443 · routes by Host · re-encrypts to backends",
           fill=LB_FILL, stroke=LB_LINE, size=13.5, subsize=10)
    s.line(cx, 116, cx, 146, sw=1.8)

    # PA (left) + PF cluster (right)
    pay = 258
    s.node(96, pay, 300, 84, "PingAccess", sub="engine :3000 · app.example.com",
           fill=PA_FILL, stroke=PA_LINE, size=13.5, subsize=10)
    s.container(470, pay - 16, 554, 116, "PINGFEDERATE CLUSTER", fill=SITE_FILL, stroke=PF_LINE, dash=None)
    s.node(490, pay + 10, 248, 64, "node 1 · CONSOLE", sub="admin :9999 · config authority",
           fill=PF_FILL, stroke=PF_LINE, size=12.5, subsize=9.5)
    s.node(756, pay + 10, 248, 64, "node 2 · ENGINE", sub="runtime :9032 · stateless",
           fill=PF_FILL, stroke=PF_LINE, size=12.5, subsize=9.5)
    s.path(f"M 738 {pay+42} L 756 {pay+42}", both=True, stroke=PF_LINE, sw=1.5)
    s.edge_label(747, pay + 32, "/cluster/replicate")

    # HAProxy -> PA and -> PF engine, by Host — each arrow ends on its box border
    s.path(f"M {cx-140} 202 L {cx-140} 228 L 246 228 L 246 {pay}", sw=1.6)
    s.edge_label(246, 228, "app.example.com")
    s.path(f"M {cx+140} 202 L {cx+140} 228 L 880 228 L 880 {pay-16}", sw=1.6)
    s.edge_label(880, 228, "ping.example.com")

    # PA -> PF (token provider = LB issuer) — ends on the PF cluster's left border
    s.line(396, pay + 42, 470, pay + 42, sw=1.6)
    s.edge_label(432, pay + 32, "token provider")

    # PD replication
    pdy = 470
    s.container(300, pdy, 520, 150, "PINGDIRECTORY REPLICATION", fill=SITE_FILL, stroke=PD_LINE, dash=None)
    s.node(322, pdy + 40, 230, 84, "node 1", sub="LDAPS :1636",
           fill=PD_FILL, stroke=PD_LINE, size=13, subsize=10)
    s.node(568, pdy + 40, 230, 84, "node 2", sub="LDAPS :2636",
           fill=PD_FILL, stroke=PD_LINE, size=13, subsize=10)
    s.path(f"M 552 {pdy+82} L 568 {pdy+82}", both=True, stroke=PD_LINE, sw=2)
    s.edge_label(560, pdy + 72, "dsreplication")
    s.caption(560, pdy + 138, "each node holds users · sessions · grants — writes replicate both ways")

    # PF engine -> both PD nodes, LDAPS failover
    s.path(f"M 750 {pay+100} L 750 442 L 437 442 L 437 {pdy+38}", sw=1.5, stroke=PF_LINE, dash="5 4")
    s.path(f"M 750 {pay+100} L 750 442 L 683 442 L 683 {pdy+38}", sw=1.5, stroke=PF_LINE, dash="5 4")
    s.edge_label(560, 442, "LDAPS · both nodes · failover")

    s.callout(40, H - 66, W - 80,
              "Every PF→PD link — the runtime datastore and the admin-console LDAP auth — is "
              "LDAPS with both directory nodes listed for failover, binding as the least-privilege "
              "cn=pingfederate service account. Stop node 1 mid-flow and SSO keeps working via node 2.",
              title="Secure + highly available", kind="ok")
    return [s.save(OUT / "ha-topology.svg")]


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
             "Every script is COUNT / LB_ENABLED aware — it manages exactly the components the config declares")

    cards = [
        ("ping-setup.sh", "Host prerequisites: JDK 21, install user, directories, /etc/hosts, "
         "ulimits, and firewall ports.", PD_LINE),
        ("install_ping.sh", "The phased orchestrator — preflight, .install-state tracking, "
         "--phase1/2/3, --force, rollback.", PF_LINE),
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
    fns = (arch_overview, install_phases, sso_flow, ha_topology,
           externalized_storage, operator_tooling)
    return [p for fn in fns for p in fn(OUT)]
