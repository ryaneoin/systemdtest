# nm2-ingest

GitOps bootstrap for the NM2 ingest stack. Clone to a blank VM, run one command, hand the rendered service files to the platform team.

## Stack

| Service | Role | Config method |
|---|---|---|
| **Telegraf** | Host metrics & log collection | TOML config files (templated) |
| **vmagent-prod** | Receives remote_write, fans out to Azure Central + Azure East | CLI flags via `run.sh` |
| **Prometheus** | Local metrics storage, query endpoint | CLI flags via `run.sh` |
| **Loki** | Log aggregation, receives from Telegraf | `config.yaml` (templated) + CLI flags |

All four are grouped under a single `nm2-ingest.target` systemd target.

## Data flow

```
Host metrics ──► Telegraf ──► vmagent (local :8429) ──► Azure Central (remote_write)
                                                     └──► Azure East   (remote_write)

Host logs ──────► Telegraf ──► Loki (local :3100)

vmagent scrapes /metrics of all four local services ──► Azure Central + Azure East
```

## Repository layout

```
nm2-ingest/
├── config/
│   ├── versions.conf              # Binary versions — bump here to upgrade
│   └── env/
│       ├── dev.env                # Dev-specific variables
│       ├── uat.env
│       └── prod.env
├── telegraf/
│   └── conf.d/
│       ├── agent.toml.tmpl        # Agent global settings
│       ├── inputs.toml.tmpl       # What to collect (host metrics, systemd units)
│       └── outputs.toml.tmpl      # Where to send (vmagent + Loki)
├── vmagent/
│   ├── run.sh.tmpl                # CLI flags for vmagent-prod
│   └── scrape.yaml.tmpl           # Prometheus scrape config for local services
├── prometheus/
│   └── run.sh.tmpl                # CLI flags for prometheus
├── loki/
│   ├── config.yaml.tmpl           # Loki config (storage, retention, ports)
│   └── run.sh.tmpl                # CLI flags for loki
├── systemd/
│   ├── nm2-ingest.target          # Umbrella target (static — no templating needed)
│   ├── nm2-vmagent.service.tmpl
│   ├── nm2-telegraf.service.tmpl
│   ├── nm2-prometheus.service.tmpl
│   └── nm2-loki.service.tmpl
└── install.sh                     # Single entrypoint — run this on the VM
```

> **Rule:** Only `.tmpl` files and `versions.conf` / `*.env` files live in git.  
> Generated files (`*.toml`, `*.yaml`, `run.sh`, `*.service`) are produced by `install.sh` and stay on the host.

---

## Bootstrap a new host

### Prerequisites

The VM needs:
- OS user `nm2` (created by platform team)
- `curl`, `tar`, `unzip`, `gettext-base` (`envsubst`) installed
- Outbound HTTPS to GitHub releases and Azure remote_write endpoints

```bash
sudo apt-get install -y curl tar unzip gettext-base
```

### One-shot bootstrap

```bash
# Clone
git clone https://github.com/ryaneoin/nm2-ingest.git /home/nm2/nm2-ingest
cd /home/nm2/nm2-ingest

# Run as the nm2 user, passing the target environment
./install.sh prod        # or: dev | uat
```

### Or bootstrap without git (curl)

```bash
ENV=prod
curl -fsSL https://github.com/ryaneoin/nm2-ingest/archive/refs/heads/main.tar.gz \
  | tar -xz -C /home/nm2/
mv /home/nm2/nm2-ingest-main /home/nm2/nm2-ingest
cd /home/nm2/nm2-ingest && ./install.sh $ENV
```

### What install.sh produces

After a successful run:

```
/home/nm2/
├── bin/
│   ├── telegraf          (+ .version sidecar)
│   ├── vmagent-prod      (+ .version sidecar)
│   ├── prometheus        (+ .version sidecar)
│   └── loki              (+ .version sidecar)
├── telegraf/conf.d/      (rendered TOML configs)
├── vmagent/              (rendered run.sh + scrape.yaml)
├── prometheus/           (rendered run.sh)
├── loki/                 (rendered run.sh + config.yaml)
├── data/                 (prometheus/ loki/ vmagent-cache/)
├── logs/
└── systemd/              ← hand these to platform team
    ├── nm2-ingest.target
    ├── nm2-vmagent.service
    ├── nm2-telegraf.service
    ├── nm2-prometheus.service
    └── nm2-loki.service
```

---

## Platform team handoff

After `install.sh` completes, it prints the exact commands needed. For reference:

```bash
sudo cp /home/nm2/systemd/*.service /etc/systemd/system/
sudo cp /home/nm2/systemd/nm2-ingest.target /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nm2-ingest.target
```

**That's the only sudo interaction required.**

### Verify

```bash
systemctl status nm2-ingest.target
systemctl status nm2-vmagent nm2-telegraf nm2-prometheus nm2-loki

# Tail logs
journalctl -u nm2-vmagent -f
journalctl -u nm2-telegraf -f
```

---

## Upgrading a binary

Edit `config/versions.conf`, commit, then on the host:

```bash
cd /home/nm2/nm2-ingest
git pull
./install.sh prod
# Then platform team restarts the affected service:
# sudo systemctl restart nm2-vmagent   (or whichever changed)
```

`install.sh` skips any binary that is already at the correct version, so re-running is fast and safe.

## Updating config or flags

Edit the relevant `.tmpl` file, commit, then on the host:

```bash
git pull && ./install.sh prod
sudo systemctl restart nm2-ingest.target   # or individual unit
```

---

## Ports

| Service | Port | Protocol |
|---|---|---|
| vmagent — remote_write ingest | 8429 | HTTP |
| vmagent — metrics `/metrics` | 8429 | HTTP |
| Prometheus | 9090 | HTTP |
| Loki — push / query | 3100 | HTTP |
| Loki — gRPC | 9096 | gRPC |
| Telegraf — internal metrics | 9273 | HTTP |

---

## Environment variables reference

All variables are defined in `config/env/<ENV>.env`.  
See the inline comments in each file. Key ones:

| Variable | Used by | Purpose |
|---|---|---|
| `VMAGENT_REMOTE_WRITE_URL_1/2` | vmagent | Azure Central / East endpoints |
| `TELEGRAF_REMOTE_WRITE_URL` | Telegraf | Local vmagent endpoint |
| `TELEGRAF_LOKI_URL` | Telegraf | Local Loki endpoint |
| `PROMETHEUS_RETENTION_TIME` | Prometheus | Local data retention |
| `LOKI_RETENTION_PERIOD` | Loki | Log retention |
