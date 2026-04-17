#!/usr/bin/env bash
# ── nm2-ingest install.sh ─────────────────────────────────────────────────────
# Bootstraps the full nm2-ingest stack on a blank VM.
#
# Usage:
#   ./install.sh <ENV>
#   ENV: dev | uat | prod
#
# What it does:
#   1. Validates dependencies and arguments
#   2. Loads versions.conf + config/env/<ENV>.env
#   3. Creates directory structure under /home/nm2
#   4. Downloads binaries (skips if already at correct version)
#   5. Templates all .tmpl files via envsubst
#   6. Renders systemd service files to /home/nm2/systemd/
#   7. Prints platform team instructions for service registration
#
# Re-running is safe — installs are idempotent.
# To upgrade a binary: bump the version in config/versions.conf, re-run.

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}══ $* ══${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/home/nm2
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

# ── Validate arguments ────────────────────────────────────────────────────────
ENV="${1:-}"
[[ -z "$ENV" ]] && error "Usage: $0 <dev|uat|prod>"
[[ "$ENV" =~ ^(dev|uat|prod)$ ]] || error "ENV must be dev, uat, or prod — got: ${ENV}"

section "nm2-ingest bootstrap — ENV=${ENV}"

# ── Check dependencies ────────────────────────────────────────────────────────
section "Checking dependencies"
MISSING=()
for cmd in curl tar unzip envsubst sha256sum; do
  if command -v "$cmd" &>/dev/null; then
    info "  found: $cmd"
  else
    MISSING+=("$cmd")
  fi
done
[[ ${#MISSING[@]} -gt 0 ]] && error "Missing required commands: ${MISSING[*]}\n  Install with: sudo apt-get install -y curl tar unzip gettext-base coreutils"

# ── Load config ───────────────────────────────────────────────────────────────
section "Loading configuration"
VERSIONS_FILE="${SCRIPT_DIR}/config/versions.conf"
ENV_FILE="${SCRIPT_DIR}/config/env/${ENV}.env"

[[ -f "$VERSIONS_FILE" ]] || error "Not found: ${VERSIONS_FILE}"
[[ -f "$ENV_FILE" ]]      || error "Not found: ${ENV_FILE}"

# Export all non-comment vars from both files so envsubst can use them
set -a
# shellcheck source=/dev/null
source "$VERSIONS_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

info "Loaded versions.conf — Telegraf=${TELEGRAF_VERSION} vmagent=${VMAGENT_VERSION} Prometheus=${PROMETHEUS_VERSION} Loki=${LOKI_VERSION}"
info "Loaded ${ENV}.env — host=${NM2_HOSTNAME}"

# ── Directory structure ───────────────────────────────────────────────────────
section "Creating directory structure"
dirs=(
  "${BASE}/bin"
  "${BASE}/telegraf/conf.d"
  "${BASE}/vmagent"
  "${BASE}/prometheus"
  "${BASE}/loki"
  "${BASE}/data/prometheus"
  "${BASE}/data/loki"
  "${BASE}/data/vmagent-cache"
  "${BASE}/logs"
  "${BASE}/systemd"
)
for d in "${dirs[@]}"; do
  mkdir -p "$d"
  info "  $d"
done

# ── Binary download helpers ───────────────────────────────────────────────────
# Tracks installed versions in .version sidecar files alongside each binary.
# Re-running install.sh only re-downloads when the version has changed.

version_file() { echo "${1}.version"; }

needs_download() {
  local dest="$1" expected_ver="$2"
  local vf
  vf="$(version_file "$dest")"
  if [[ -f "$dest" && -f "$vf" && "$(cat "$vf")" == "$expected_ver" ]]; then
    return 1  # already at correct version
  fi
  return 0
}

mark_version() {
  local dest="$1" ver="$2"
  echo "$ver" > "$(version_file "$dest")"
}

# ── Download Telegraf ─────────────────────────────────────────────────────────
section "Telegraf ${TELEGRAF_VERSION}"
TELEGRAF_DEST="${BASE}/bin/telegraf"
if needs_download "$TELEGRAF_DEST" "$TELEGRAF_VERSION"; then
  TELEGRAF_URL="https://dl.influxdata.com/telegraf/releases/telegraf-${TELEGRAF_VERSION}_linux_amd64.tar.gz"
  info "Downloading ${TELEGRAF_URL}"
  curl -fsSL "$TELEGRAF_URL" -o "${TMPDIR_WORK}/telegraf.tar.gz"
  tar -xzf "${TMPDIR_WORK}/telegraf.tar.gz" -C "${TMPDIR_WORK}"
  cp "${TMPDIR_WORK}/telegraf-${TELEGRAF_VERSION}/usr/bin/telegraf" "$TELEGRAF_DEST"
  chmod +x "$TELEGRAF_DEST"
  mark_version "$TELEGRAF_DEST" "$TELEGRAF_VERSION"
  info "Installed telegraf ${TELEGRAF_VERSION} → ${TELEGRAF_DEST}"
else
  info "telegraf ${TELEGRAF_VERSION} already installed, skipping"
fi

# ── Download vmagent-prod (from vmutils-prod OSS release) ────────────────────
section "vmagent-prod ${VMAGENT_VERSION}"
VMAGENT_DEST="${BASE}/bin/vmagent-prod"
if needs_download "$VMAGENT_DEST" "$VMAGENT_VERSION"; then
  VMUTILS_URL="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VMAGENT_VERSION}/vmutils-linux-amd64-v${VMAGENT_VERSION}.tar.gz"
  info "Downloading ${VMUTILS_URL}"
  curl -fsSL -L "$VMUTILS_URL" -o "${TMPDIR_WORK}/vmutils.tar.gz"
  tar -xzf "${TMPDIR_WORK}/vmutils.tar.gz" -C "${TMPDIR_WORK}"
  cp "${TMPDIR_WORK}/vmagent-prod" "$VMAGENT_DEST"
  chmod +x "$VMAGENT_DEST"
  mark_version "$VMAGENT_DEST" "$VMAGENT_VERSION"
  info "Installed vmagent-prod ${VMAGENT_VERSION} → ${VMAGENT_DEST}"
else
  info "vmagent-prod ${VMAGENT_VERSION} already installed, skipping"
fi

# ── Download Prometheus ───────────────────────────────────────────────────────
section "Prometheus ${PROMETHEUS_VERSION}"
PROMETHEUS_DEST="${BASE}/bin/prometheus"
if needs_download "$PROMETHEUS_DEST" "$PROMETHEUS_VERSION"; then
  PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
  info "Downloading ${PROM_URL}"
  curl -fsSL -L "$PROM_URL" -o "${TMPDIR_WORK}/prometheus.tar.gz"
  tar -xzf "${TMPDIR_WORK}/prometheus.tar.gz" -C "${TMPDIR_WORK}"
  cp "${TMPDIR_WORK}/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" "$PROMETHEUS_DEST"
  chmod +x "$PROMETHEUS_DEST"
  mark_version "$PROMETHEUS_DEST" "$PROMETHEUS_VERSION"
  info "Installed prometheus ${PROMETHEUS_VERSION} → ${PROMETHEUS_DEST}"
else
  info "prometheus ${PROMETHEUS_VERSION} already installed, skipping"
fi

# ── Download Loki ─────────────────────────────────────────────────────────────
section "Loki ${LOKI_VERSION}"
LOKI_DEST="${BASE}/bin/loki"
if needs_download "$LOKI_DEST" "$LOKI_VERSION"; then
  LOKI_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"
  info "Downloading ${LOKI_URL}"
  curl -fsSL -L "$LOKI_URL" -o "${TMPDIR_WORK}/loki.zip"
  unzip -q "${TMPDIR_WORK}/loki.zip" -d "${TMPDIR_WORK}/loki-extract"
  cp "${TMPDIR_WORK}/loki-extract/loki-linux-amd64" "$LOKI_DEST"
  chmod +x "$LOKI_DEST"
  mark_version "$LOKI_DEST" "$LOKI_VERSION"
  info "Installed loki ${LOKI_VERSION} → ${LOKI_DEST}"
else
  info "loki ${LOKI_VERSION} already installed, skipping"
fi

# ── Template rendering ────────────────────────────────────────────────────────
# All .tmpl files are rendered via envsubst.
# The source .tmpl files live in the repo; rendered output goes to BASE.

render() {
  local src="$1" dest="$2"
  envsubst < "$src" > "$dest"
  info "  rendered: $(basename "$src") → ${dest}"
}

section "Rendering Telegraf config"
render "${SCRIPT_DIR}/telegraf/conf.d/agent.toml.tmpl"   "${BASE}/telegraf/conf.d/agent.toml"
render "${SCRIPT_DIR}/telegraf/conf.d/inputs.toml.tmpl"  "${BASE}/telegraf/conf.d/inputs.toml"
render "${SCRIPT_DIR}/telegraf/conf.d/outputs.toml.tmpl" "${BASE}/telegraf/conf.d/outputs.toml"

section "Rendering vmagent config"
render "${SCRIPT_DIR}/vmagent/run.sh.tmpl"       "${BASE}/vmagent/run.sh"
render "${SCRIPT_DIR}/vmagent/scrape.yaml.tmpl"  "${BASE}/vmagent/scrape.yaml"
chmod +x "${BASE}/vmagent/run.sh"

section "Rendering Prometheus config"
render "${SCRIPT_DIR}/prometheus/run.sh.tmpl" "${BASE}/prometheus/run.sh"
chmod +x "${BASE}/prometheus/run.sh"

section "Rendering Loki config"
render "${SCRIPT_DIR}/loki/config.yaml.tmpl" "${BASE}/loki/config.yaml"
render "${SCRIPT_DIR}/loki/run.sh.tmpl"      "${BASE}/loki/run.sh"
chmod +x "${BASE}/loki/run.sh"

section "Rendering systemd service files"
render "${SCRIPT_DIR}/systemd/nm2-vmagent.service.tmpl"    "${BASE}/systemd/nm2-vmagent.service"
render "${SCRIPT_DIR}/systemd/nm2-telegraf.service.tmpl"   "${BASE}/systemd/nm2-telegraf.service"
render "${SCRIPT_DIR}/systemd/nm2-prometheus.service.tmpl" "${BASE}/systemd/nm2-prometheus.service"
render "${SCRIPT_DIR}/systemd/nm2-loki.service.tmpl"       "${BASE}/systemd/nm2-loki.service"
cp     "${SCRIPT_DIR}/systemd/nm2-ingest.target"           "${BASE}/systemd/nm2-ingest.target"

# ── Done — print platform team instructions ───────────────────────────────────
section "Install complete"
echo ""
echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  PLATFORM TEAM — action required to activate services           │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo "  Run the following as root / with sudo:"
echo ""
echo "    cp ${BASE}/systemd/*.service /etc/systemd/system/"
echo "    cp ${BASE}/systemd/nm2-ingest.target /etc/systemd/system/"
echo "    systemctl daemon-reload"
echo "    systemctl enable --now nm2-ingest.target"
echo ""
echo "  To verify:"
echo "    systemctl status nm2-ingest.target"
echo "    systemctl status nm2-vmagent nm2-telegraf nm2-prometheus nm2-loki"
echo ""
echo "  Service files are in: ${BASE}/systemd/"
echo ""
info "nm2-ingest ${ENV} bootstrap complete ✓"
