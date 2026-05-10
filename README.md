# Self-Hosted Observability Stack

> **Prometheus + Grafana + Alertmanager + Exporters** — because SSH-tail'ing logs is not a monitoring strategy.

[![Docker](https://img.shields.io/badge/docker-compose-blue?logo=docker)](https://docs.docker.com/compose/)
[![Prometheus](https://img.shields.io/badge/Prometheus-latest-orange?logo=prometheus)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-latest-orange?logo=grafana)](https://grafana.com/)
[![CI](https://github.com/DynamicKarabo/monitoring-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/DynamicKarabo/monitoring-stack/actions/workflows/ci.yml)

---

## The Problem / Why This Stack

Running a handful of services on a single VPS doesn't justify a Datadog subscription ($$$ per host), a New Relic license, or the overhead of a managed observability SaaS. But flying blind is worse:

- **Before:** `docker ps`, `top`, `df -h`, and `journalctl -u` — manual, reactive, and forgotten until pager duty.
- **The gap:** No historical metrics, no trend analysis, no alerting. If Postgres crashes at 3 AM, you find out when users do.
- **The constraint:** Minimal budget, single VPS, containerized workload. The stack must fit in Docker Compose, auto-configure itself, and stay out of the way.

This stack is the result of that constraint: a **production-grade, self-contained observability platform** that costs nothing but the VPS it runs on, delivers real-time metrics, auto-provisions dashboards, and shouts at you on Telegram when things break.

---

## Architecture

```
graph TD
    A[Node Exporter] -->|host metrics:9100| P[Prometheus]
    B[cAdvisor] -->|container metrics:8080| P
    C[Postgres Exporter] -->|db metrics:9187| P
    D[Blackbox Exporter] -->|http probes:9115| P
    P -->|alert| E[Alertmanager]
    E -->|notify| F[Telegram]
    G[Grafana] -->|query| P
    H[User] -->|dashboards:3000| G
```

### Data Flow Narrative

1. **Scrape layer:** Four exporters collect host-level metrics (Node Exporter), container-level metrics (cAdvisor), PostgreSQL database metrics, and HTTP endpoint health (Blackbox Exporter).
2. **Collection & evaluation:** Prometheus scrapes every 15s, evaluates alert rules every 15s, and stores time-series data in its own TSDB (persistent volume).
3. **Alert routing:** When an alert fires, Prometheus pushes it to Alertmanager, which groups by `alertname` + `severity`, waits 30s for batching, and sends a Telegram notification with HTML formatting.
4. **Visualization:** Grafana queries Prometheus via an auto-provisioned datasource and serves three pre-loaded dashboards (host, containers, Postgres) — zero configuration required.

---

## What Makes This Different

| Before (SSH & raw logs) | After (this stack) |
|---|---|
| `ssh user@vps && top` | Real-time CPU/memory/disk graphs in Grafana |
| `docker logs --tail 100` | Container-level metrics from cAdvisor |
| Only know Postgres is down when app breaks | Postgres exporter with query performance metrics |
| Manual `curl` to check if app is responding | Blackbox HTTP probes every 15s |
| No alerting | Telegram alerts within 2 minutes of failure |
| Manual dashboard setup every time | Auto-provisioned dashboards + datasource |
| Forget about disk until it's full | `DiskSpaceLow` critical alert at 10% |

**Key wins:**
- **Zero-click setup** — deploy with one script, dashboards appear automatically
- **Cost** — $0 beyond VPS hosting (no per-host SaaS fees)
- **Self-contained** — everything in Docker Compose, no external dependencies
- **Portable** — runs on any Linux box with Docker; configs are version-controlled

---

## Obstacles & Troubleshooting

Every line in this repo was earned through trial, error, and late-night debugging. Here are the fires we put out:

### 1. No CI Workflow — The Missing Safety Net (Solved ✅)

**Status:** Resolved — CI pipeline is live at `.github/workflows/ci.yml` with YAML linting, Docker Compose validation, Prometheus config validation, and Grafana dashboard JSON checks.

### 2. Postgres Exporter → `host.docker.internal`

The Postgres exporter connects to a database running on the host (not in a container) via `host.docker.internal:5432`. This works on Linux only if:

- Docker Compose uses the `host` network mode, **or**
- the `extra_hosts` directive maps `host.docker.internal` to `host-gateway` (requires Docker Compose v2+)
- the host firewall allows port 5432 from Docker's bridge network

We rely on Docker's built-in `host.docker.internal` resolution on Docker Desktop (macOS/Windows) and `extra_hosts` on Linux. If Prometheus shows `postgres-exporter` as `DOWN`, this connection is the first place to check.

### 3. Blackbox Exporter Probe Timing

The blackbox exporter probes multiple internal HTTP endpoints (`prometheus:9090`, `grafana:3000`, `alertmanager:9093`, and `host.docker.internal:30080` for Miniflux). With a 5-second probe timeout and 15-second scrape interval, a slow endpoint can cause cascading scrape failures. Solution: we keep the probe module simple (`GET`, 5s timeout) and rely on `miniflux.yml` for targeted Miniflux alerting.

### 4. cAdvisor: Privileged Mode & `/dev/kmsg`

cAdvisor needs extensive access to the host's filesystem and cgroups to report container metrics. The compose file sets:

```yaml
privileged: true
devices:
  - /dev/kmsg:/dev/kmsg
```

The privileged mode grants access to `/rootfs`, `/var/run`, `/sys`, and `/var/lib/docker`. The `/dev/kmsg` device mount is required on modern kernels where cAdvisor reads kernel messages for container boot timing. On some VPS kernels (e.g., OpenVZ, LXC), `/dev/kmsg` may not be available — you'll see a warning in cAdvisor logs, but metrics still work.

### 5. Grafana Provisioning Path Quirks

Grafana's provisioning system is picky about paths:

- **Dashboards source:** `/var/lib/grafana/dashboards` (mounted from `../grafana/dashboards`)
- **Provisioning config:** `/etc/grafana/provisioning` (mounted from `../grafana/provisioning`)
- **Data directory:** `/var/lib/grafana` (persistent volume `grafana-data`)

The dashboard provider config (`dashboards.yml`) points to `/var/lib/grafana/dashboards`, **not** the provisioning directory. This is non-obvious — if you copy the wrong path, dashboards silently fail to load.

### 6. Alertmanager Telegram Webhook Setup

Alertmanager uses the native `telegram_configs` receiver (built into Alertmanager v0.23+). The setup requires:

1. Creating a Telegram bot via @BotFather and saving the token
2. Finding the numeric chat ID via `https://api.telegram.org/bot<TOKEN>/getUpdates`
3. Restarting Alertmanager to apply the config

Common pitfalls: chat ID must be numeric, the bot must have been sent at least one message before it shows up in `getUpdates`, and `send_resolved: true` means you'll get both firing + resolved notifications.

### 7. The `:latest` Tag Tax

Every image in `docker-compose.yml` uses the `:latest` tag:

| Service | Image | Pinned? |
|---|---|---|
| Prometheus | `prom/prometheus:latest` | ❌ |
| Grafana | `grafana/grafana:latest` | ❌ |
| Alertmanager | `prom/alertmanager:latest` | ❌ |
| Node Exporter | `prom/node-exporter:latest` | ❌ |
| cAdvisor | `gcr.io/cadvisor/cadvisor:latest` | ❌ |
| Postgres Exporter | `prometheuscommunity/postgres-exporter:latest` | ❌ |
| Blackbox Exporter | `prom/blackbox-exporter:latest` | ❌ |

This means `docker compose pull` can introduce breaking changes without warning. Pinning to a specific version (e.g., `v2.53.0`) is recommended for production.

---

## Component Specs

Eight services orchestrated by Docker Compose:

| Service | Port | Role |
|---|---|---|
| Prometheus | 9090 | Metrics collection, TSDB storage, alert rule evaluation |
| Grafana | 3000 | Dashboards, visualization, auto-provisioned datasource |
| Alertmanager | 9093 | Alert deduplication, grouping, Telegram routing |
| Node Exporter | 9100 | Host-level metrics (CPU, memory, disk, network) |
| cAdvisor | 8080 | Container-level resource usage & performance |
| Postgres Exporter | 9187 | PostgreSQL query performance, connections, replication |
| Blackbox Exporter | 9115 | HTTP/HTTPS endpoint probing, SSL expiry checks |
| Miniflux | 30080 | RSS reader (monitored externally via blackbox) |

### Resource Footprint

On a typical VPS (2 vCPU, 4 GB RAM):

| Component | Memory (idle) | CPU (idle) | Storage |
|---|---|---|---|
| Prometheus | ~150 MB | <0.5% | ~1 GB/30 days |
| Grafana | ~80 MB | <0.3% | dashboard configs only |
| Alertmanager | ~25 MB | <0.1% | negligible |
| Node Exporter | ~20 MB | <0.1% | none |
| cAdvisor | ~40 MB | <0.3% | none |
| Postgres Exporter | ~15 MB | <0.1% | none |
| Blackbox Exporter | ~15 MB | <0.1% | none |
| **Total** | **~345 MB** | **~1.5%** | **~1 GB/month** |

---

## Quick Start

```bash
git clone https://github.com/DynamicKarabo/monitoring-stack.git
cd monitoring-stack
chmod +x scripts/setup.sh
./scripts/setup.sh
```

Or manually:

```bash
cd docker
docker compose up -d
```

### First-Time Setup

1. **Configure Telegram alerts** — Edit `alertmanager/alertmanager.yml`:
   - Set `bot_token` to your Telegram bot token (from @BotFather)
   - Set `chat_id` to the numeric chat ID (use `getUpdates` API to find it)
   - Restart: `docker compose restart alertmanager`
2. **Access Grafana** at `http://<vps-ip>:3000` (default: `admin` / `admin`)

### Available Dashboards

| Dashboard | ID | Source |
|---|---|---|
| Node Exporter Full | 1860 | grafana.com/grafana/dashboards/1860 |
| Docker Container | 17994 | grafana.com/grafana/dashboards/17994 |
| PostgreSQL | 9628 | grafana.com/grafana/dashboards/9628 |

Dashboards are auto-provisioned — they appear in Grafana immediately after startup with zero manual configuration.

### Alert Rules

| Alert | Severity | Condition |
|---|---|---|
| InstanceDown | critical | A Prometheus scrape target is unreachable |
| ServiceDown | critical | An HTTP endpoint probe has failed (5xx, timeout) |
| HttpProbeFailure | warning | Non-2xx/3xx status codes detected |
| HighCpuUsage | warning | CPU > 80% for 5 minutes |
| HighMemoryUsage | warning | Memory > 85% for 5 minutes |
| DiskSpaceLow | critical | Disk space < 10% |
| MinifluxProbeFailing | critical | Miniflux HTTP probe failing for 2+ minutes |

---

## CI/CD

**Status:** ✅ Implemented — GitHub Actions workflow runs on every PR and push to `main`.

The [CI pipeline](.github/workflows/ci.yml) validates all config changes before deployment:

| Check | Tool | What it validates |
|---|---|---|
| YAML lint | `yamllint` | All `.yml` files follow consistent formatting |
| Compose validate | `docker compose config` | Compose file is syntactically valid |
| Prometheus config | `promtool check config` | Prometheus scrape targets, rule files, and global config |
| Alert rules | `promtool check rules` | All alert rule files are valid PromQL |
| Dashboard JSON | `jq` | Grafana dashboard JSONs are valid and parseable |

This replaces the previous manual deploy process (`git pull && docker compose up -d`) with an automated validation gate — broken configs never reach production.

---

## Directory Structure

```
monitoring-stack/
├── alertmanager/
│   └── alertmanager.yml           # Alert routing & Telegram config
├── docker/
│   └── docker-compose.yml         # All services definition
├── grafana/
│   ├── dashboards/                # Pre-loaded dashboard JSONs
│   │   ├── node-exporter-full.json
│   │   ├── docker-container.json
│   │   └── postgres.json
│   └── provisioning/
│       ├── dashboards/
│       │   └── dashboards.yml     # Auto-provisioning config
│       └── datasources/
│           └── datasources.yml    # Prometheus data source
├── prometheus/
│   ├── alerts/
│   │   ├── common.rules.yml       # Core alerting rules
│   │   └── miniflux.yml           # Miniflux-specific alerts
│   ├── blackbox.yml               # Blackbox exporter config
│   └── prometheus.yml             # Main Prometheus config
├── scripts/
│   └── setup.sh                   # Idempotent bootstrap script
├── .gitignore
└── README.md
```

---

## Roadmap

### Short-term

- [x] **Core stack** — Prometheus, Grafana, Alertmanager, exporters
- [x] **Auto-provisioning** — Dashboards and datasource configure themselves
- [x] **Telegram alerting** — Real-time notifications via bot
- [x] **Idempotent setup** — Single script to bootstrap everything

### Medium-term

- [ ] **Pin image versions** — Replace `:latest` with specific version tags across all services
- [x] **CI pipeline** — GitHub Actions workflow with Prometheus rule linting, Docker Compose validation, and YAML linting
- [x] **Promtool validation** — `promtool check rules` and `promtool check config` running in CI
- [ ] **Version dashboards** — Track dashboard JSONs in version control with changelog comments
- [ ] **Healthcheck endpoints** — Add Docker healthchecks to every service in compose
- [ ] **Grafana alerting** — Move some alerts from Prometheus/Alertmanager to Grafana's built-in alerting for richer notification templates

### Long-term

- [ ] **Log aggregation** — Add Loki + Promtail for centralized log collection
- [ ] **Tracing** — Add Tempo or Jaeger for distributed tracing
- [ ] **Uptime monitoring** — External synthetic checks from a second VPS or a free service (UptimeRobot, BetterStack)
- [ ] **Backup strategy** — Automated TSDB snapshots and Grafana config backups

---

## License

MIT
