# Ping Installer — PingDirectory + PingFederate + PingAccess

An automated, phased installer that stands up a **fully integrated Ping stack** on a
single host and configures it the way a real customer runs it — including
**externalized session and OAuth-grant storage in PingDirectory** (not in memory).

Modeled structurally on the ForgeRock `ping_platform_installer` (three-phase bash
orchestration, state tracking, idempotent Admin-API configuration).

---

## What it installs

| Order | Product | Version | Role in the stack |
|:-:|---|---|---|
| 1 | **PingDirectory** | 11.1.0.0 | LDAP user store **+** session / OAuth-grant store |
| 2 | **PingFederate** | 13.1.1 | Federation, OAuth 2.0 / OIDC token service |
| 3 | **PingAccess** | 9.1.0 | Access gateway / reverse proxy (enforcement point) |

Products install in dependency order: the data store first, the token service
second (it depends on the directory), the gateway last (it depends on the token
service).

---

## Sample architecture

Reference topology this installer builds — a browser reaching a protected app is
redirected to PingFederate to authenticate against PingDirectory, and
**PingFederate persists the resulting session + OAuth grants back into
PingDirectory** rather than holding them in memory.

```
                          ┌───────────────────────────────────────────────┐
                          │                   Browser                      │
                          └───────────────┬───────────────────────────────┘
                                          │ 1. GET protected app
                                          ▼
                        ┌─────────────────────────────────────┐
                        │            PingAccess                │  enforcement point
                        │   virtual host: app.example.com      │  admin :9000
                        │   site / application / access rules  │  engine:3000
                        └───────────────┬─────────────────────┘
                                        │ 2. no session → redirect to token provider (OIDC)
                                        ▼
                        ┌─────────────────────────────────────┐
                        │           PingFederate               │  token service
                        │   IdP adapter · OAuth/OIDC clients   │  admin :9999
                        │   token provider for PingAccess      │  engine:9031
                        └──────┬──────────────────────┬────────┘
              3. bind/search   │                      │  4. persist session + OAuth grants
                 authenticate  │                      │     (NOT in memory)
                               ▼                      ▼
                        ┌─────────────────────────────────────┐
                        │           PingDirectory              │  data + session store
                        │  ┌───────────────────────────────┐  │  LDAPS :1636
                        │  │ ou=people   (users)           │  │  HTTPS :1443
                        │  │ ou=sessions (PF SSO sessions) │  │  admin :8989
                        │  │ ou=oauth-grants (PF grants)   │  │
                        │  └───────────────────────────────┘  │
                        └─────────────────────────────────────┘
```

**Why sessions live in PingDirectory:** in-memory sessions are lost on every
PingFederate restart and cannot be shared across engine nodes. Externalizing them
to PingDirectory makes sessions durable and cluster-ready — the standard
production customer pattern. Toggle with `PINGFED_SESSION_STORAGE` in
`pingconfig.env` (`pingdirectory` | `memory`).

---

## Install flow

Everything is driven by `pingconfig.env` and run in three re-runnable phases.
Phase completion is tracked in `.install-state`; re-runs skip completed phases
unless `--force` is given.

```
Phase 1 — Install      unzip + license + baseline start   (PD → PF → PA)
Phase 2 — Configure    PD schema/data/service acct +
                       session & grant containers
                       → PF LDAP datastore, IdP adapter,
                         OAuth/OIDC clients, externalized sessions
                       → PA virtual host / site / app / rules
Phase 3 — Integrate    wire PA → PF token provider,
                       deploy sample protected app,
                       seed test users into PingDirectory
```

### Quick start

```bash
# 1. Drop product zips + licenses into software/ (already present):
#      software/pd/PingDirectory-*.zip + *.lic
#      software/pf/pingfederate-*.zip   + *.lic
#      software/pa/pingaccess-*.zip     + *.lic

# 2. Review and edit configuration (hosts, ports, passwords, storage mode)
vi pingconfig.env

# 3. Prepare the host (JDK, install user, directories, /etc/hosts)   [pending]
./bin/ping-setup.sh

# 4. Install everything
./bin/install_ping.sh --all

# ...or one phase at a time
./bin/install_ping.sh --phase1
./bin/install_ping.sh --phase2 --force
```

---

## Repository layout

```
ping_fed_installer/
├── pingconfig.env          # single source of truth: hosts, ports, licenses, storage mode, flags
├── lib/
│   ├── logging.sh          # shared CLI output (banners, steps, summary table)
│   └── rest_helpers.sh     # idempotent pf_* / pa_* Admin-API verbs        [pending]
├── bin/
│   ├── install_ping.sh     # phased orchestrator engine (state / preflight / rollback)
│   ├── ping-setup.sh       # host prerequisites                            [pending]
│   ├── ping-control.sh     # start / stop / restart / status / health      [pending]
│   ├── ping-monitor.sh     ping-logs.sh   ping-validate.sh                 [pending]
├── pingdir/                # setup profile · dsconfig batch · session/grant LDIF · pingdir.sh  [pending]
├── pingfed/                # /pf-admin-api payloads · pingfed.sh                                [pending]
├── pingaccess/             # /pa-admin-api payloads · pingaccess.sh                            [pending]
└── software/               # product zips + licenses  (gitignored, user-supplied)
    ├── pd/   pf/   pa/
```

---

## Configuration highlights (`pingconfig.env`)

| Variable | Purpose |
|---|---|
| `BASE_INSTALL_DIR` | where all three products install (default `/ping`) |
| `PING_HOSTNAME` | host all services bind/advertise (single-node) |
| `DEFAULT_PASSWORD` | shared admin password — **change before production** |
| `PINGFED_SESSION_STORAGE` | `pingdirectory` (externalized) or `memory` (dev) |
| `PINGFED_SESSIONS_BASE_DN` / `PINGFED_GRANTS_BASE_DN` | where PF writes sessions / grants in PD |
| `PINGDIR_COUNT` / `PINGFED_COUNT` / `PINGACCESS_COUNT` | instance counts (single-node now; clustering later) |
| `INSTALL_SAMPLE_APP` / `INSTALL_TEST_USERS` / `INSTALL_OIDC_CLIENT` | optional Phase 3 content |

Ports: PD LDAP 1389 / LDAPS 1636 / HTTPS 1443 / admin 8989 · PF admin 9999 /
engine 9031 · PA admin 9000 / engine 3000 / agent 3030.

---

## Status

This is an active build. Implemented so far:

- ✅ Project scaffold, `pingconfig.env`, `lib/logging.sh`
- ✅ Orchestrator engine (`bin/install_ping.sh`) — phases, state, preflight,
  rollback wired; **product install/configure bodies are stubs** that log intent
  and return success so the phase machinery is testable end-to-end
- ⏳ Product install scripts (PD / PF / PA), `rest_helpers.sh`, operator scripts

> **License note:** the supplied PingAccess license is `Version=9.0` while the
> software is `9.1.0`. PingAccess validates license version at startup — if 9.1
> rejects it, obtain a 9.1 development license. All three licenses expire
> **2026-08-18**.
