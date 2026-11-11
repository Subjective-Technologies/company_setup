#!/usr/bin/env bash
#
# company_setup.sh — provision a blank Ubuntu VPS with DevAgents API and CLIProxy.
#
# Usage:
#   sudo company_setup.sh <company_name>
#   company_setup.sh --dry-run <company_name>
#
# Writes the company name to /company_name.
# Creates /subjective and clones only what those two services execute:
#
#   services/subjective_devagents_fastapi   API, plus its plugin and lib submodules
#   services/CLIProxyAPI                    source of the proxy; the binary is downloaded
#   clients/desktop/subjective_chat         browser UI the API serves
#
# Then, as root, it installs and starts two systemd units:
#
#   cli-proxy-api.service                   0.0.0.0:8317
#   subjective-devagents-fastapi.service    0.0.0.0:8080
#
# The web dashboard reaches CLIProxy through Cloudflare at
# https://<company>-cliproxy.<zone> (DNS + Origin Rule :8317 are created by
# provision_server.py). So CLIProxy listens on all interfaces with
# management.allow-remote: true and the control panel on. Every request still
# needs the client key (/v1) or the management key (/v0/management).
# CLIPROXY_PUBLIC=0 keeps the old localhost-only mode.
# The client key is generated once and stored in
# /etc/subjective-devagents-fastapi.env (mode 600). It is not printed.
#
# Not installed. They are not required to execute the API or CLIProxy:
#   nginx on 127.0.0.1:8788 and the port-80 socket (public hostname front)
#   legacy Node chat on :8787
#   logs service on :8799
#   vendor CLIs (claude, codex, grok, cursor)
#   GitHub Actions runners, IRC
#
# Provider OAuth files under CLIProxyAPI/auths/ are also not created. The proxy
# process starts without them. A model call works after a login, for example:
#   sudo -u subjective /subjective/services/CLIProxyAPI/bin/cli-proxy-api \
#     --config /subjective/services/CLIProxyAPI/config.yaml --claude-login
#
# Re-running keeps existing checkouts, keys, env, and unit files. In config.yaml
# only server.host, management.allow-remote and disable-control-panel are
# re-enforced (and the proxy restarted if one of them changed).
# If /subjective is already the full monorepo, the script stops and changes nothing.

set -euo pipefail

GIT_ORG="${GIT_ORG:-https://github.com/Subjective-Technologies}"
SUBJECTIVE_ROOT="${SUBJECTIVE_ROOT:-/subjective}"
COMPANY_FILE="${COMPANY_FILE:-/company_name}"
SETUP_USER="${SETUP_USER:-subjective}"
ENV_FILE="${ENV_FILE:-/etc/subjective-devagents-fastapi.env}"
MGMT_KEY_FILE="${MGMT_KEY_FILE:-/etc/cli-proxy-api.management-key}"
CLIPROXY_VERSION="${CLIPROXY_VERSION:-}"
CLIPROXY_PUBLIC="${CLIPROXY_PUBLIC:-1}"
if [[ "$CLIPROXY_PUBLIC" == "1" ]]; then
  PROXY_HOST=""
  PROXY_ALLOW_REMOTE="true"
  PROXY_DISABLE_PANEL="false"
else
  PROXY_HOST="127.0.0.1"
  PROXY_ALLOW_REMOTE="false"
  PROXY_DISABLE_PANEL="true"
fi
PROXY_CONFIG_CHANGED=0
# HTTPS for the DevAgents API on :8080 (Let's Encrypt, same as production
# devagents-api.subjectivetechnologies.com). One certificate covers
# <company>-api.<zone> for every zone. DNS is created by provision_server.py;
# until it resolves, a timer retries every 15 minutes. API_TLS=0 disables.
API_TLS="${API_TLS:-1}"
API_TLS_ZONES="${API_TLS_ZONES:-subjectivetechnologies.com worktwins.com}"
API_TLS_DIR="/etc/subjective-devagents-fastapi/tls"

API_DIR="${SUBJECTIVE_ROOT}/services/subjective_devagents_fastapi"
PROXY_DIR="${SUBJECTIVE_ROOT}/services/CLIProxyAPI"
CHAT_DIR="${SUBJECTIVE_ROOT}/clients/desktop/subjective_chat"
PROXY_BIN="${PROXY_DIR}/bin/cli-proxy-api"
PROXY_CONFIG="${PROXY_DIR}/config.yaml"
RUNNER="${API_DIR}/run-systemd.sh"

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"

MODEL_CLAUDE="${SUBJECTIVE_DEVAGENTS_LLM_MODEL_CLAUDE:-claude-sonnet-4-5-20250929}"
MODEL_CODEX="${SUBJECTIVE_DEVAGENTS_LLM_MODEL_CODEX:-gpt-5.6-sol}"
MODEL_GROK="${SUBJECTIVE_DEVAGENTS_LLM_MODEL_GROK:-grok-4.6}"
MODEL_KIMI="${SUBJECTIVE_DEVAGENTS_LLM_MODEL_KIMI:-kimi-k2.8-code}"
PUBLIC_API="${SUBJECTIVE_DEVAGENTS_PUBLIC_API-}"

DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: company_setup.sh [--dry-run] <company_name>

Write <company_name> to /company_name, clone the DevAgents API and CLIProxy
into /subjective, and install both as systemd services. A real run needs root.
Existing checkouts, config, and unit files are kept. The full Subjective
monorepo at /subjective is never modified.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *) break ;;
  esac
done

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

COMPANY_NAME="$1"

case "$COMPANY_NAME" in
  ""|[-.]*|*/*|*$'\n'*|*' ' )
    echo "refuse: company name must be a single token without slashes" >&2
    exit 2
    ;;
esac

trimmed="${COMPANY_NAME#"${COMPANY_NAME%%[![:space:]]*}"}"
trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
if [[ -z "$trimmed" || "$trimmed" != "$COMPANY_NAME" ]]; then
  echo "refuse: company name has leading or trailing whitespace" >&2
  exit 2
fi

log() { printf '%s\n' "$*"; }

refuse_monorepo() {
  if [[ -e "$SUBJECTIVE_ROOT/.git" || -e "$SUBJECTIVE_ROOT/.gitmodules" ]]; then
    echo "refuse: $SUBJECTIVE_ROOT is already the full Subjective checkout. This script only creates a DevAgents API tree and will not change that checkout." >&2
    exit 1
  fi
}

read_company_file() {
  if [[ ! -e "$COMPANY_FILE" ]]; then
    return 0
  fi
  if [[ ! -f "$COMPANY_FILE" ]]; then
    echo "refuse: $COMPANY_FILE exists and is not a file" >&2
    exit 1
  fi
  local existing
  existing="$(head -n 1 "$COMPANY_FILE")"
  if [[ "$existing" != "$COMPANY_NAME" ]]; then
    echo "refuse: $COMPANY_FILE already records '$existing'" >&2
    exit 1
  fi
}

clone_repo() {
  local rel_url="$1"
  local rel_dest="$2"
  local url="$GIT_ORG/$rel_url"
  local dest="$SUBJECTIVE_ROOT/$rel_dest"

  if [[ -d "$dest/.git" || -f "$dest/.git" ]]; then
    log "keep  $dest"
    if [[ -f "$dest/.gitmodules" ]]; then
      log "submodules  $dest"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "dry-run: git -C $dest submodule update --init --recursive"
      else
        git -C "$dest" -c 'safe.directory=*' -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
      fi
    fi
    return 0
  fi
  if [[ -e "$dest" ]]; then
    echo "refuse: $dest exists and is not a git checkout" >&2
    exit 1
  fi
  log "clone $url"
  log "  ->  $dest"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  # Submodule URLs in the API repo are SSH. Rewrite them to HTTPS for this clone
  # so a server with no GitHub key can fetch the public repositories.
  GIT_TERMINAL_PROMPT=0 git -c url.https://github.com/.insteadOf=git@github.com: \
    clone --recurse-submodules "$url" "$dest"
}

install_packages() {
  local packages=(python3 python3-venv python3-pip git ca-certificates curl tar gzip iproute2)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: apt-get install ${packages[*]}"
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "refuse: apt-get is required (Ubuntu or Debian)" >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${packages[@]}"
}

ensure_user() {
  if id "$SETUP_USER" >/dev/null 2>&1; then
    log "keep user $SETUP_USER"
  else
    log "useradd $SETUP_USER"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      useradd --create-home --shell /bin/bash --user-group "$SETUP_USER"
    fi
  fi
  if getent group users >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "dry-run: usermod -aG users $SETUP_USER"
    elif id "$SETUP_USER" >/dev/null 2>&1; then
      usermod -aG users "$SETUP_USER"
    fi
  fi
}

chown_tree() {
  local group="$SETUP_USER"
  if id "$SETUP_USER" >/dev/null 2>&1; then
    group="$(id -gn "$SETUP_USER")"
  fi
  log "chown $SETUP_USER:$group $SUBJECTIVE_ROOT"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  chown -R "$SETUP_USER:$group" "$SUBJECTIVE_ROOT"
  chmod 2775 "$SUBJECTIVE_ROOT"
  install -d -o "$SETUP_USER" -g "$group" -m 700 "/home/$SETUP_USER/.subjective_chat"
  install -d -o "$SETUP_USER" -g "$group" -m 700 "$PROXY_DIR/auths"
  install -d -o "$SETUP_USER" -g "$group" -m 755 "$PROXY_DIR/bin"
}

ensure_python() {
  if [[ -x "$PYTHON_BIN" ]] && "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
    log "python $("$PYTHON_BIN" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    return 0
  fi
  log "install python3.11"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    PYTHON_BIN="python3.11"
    return 0
  fi
  apt-get install -y python3.11 python3.11-venv
  PYTHON_BIN="$(command -v python3.11)"
  if [[ -z "$PYTHON_BIN" ]] || ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
    echo "refuse: Python 3.11 or newer is required" >&2
    exit 1
  fi
  log "python $("$PYTHON_BIN" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
}

install_venv() {
  local py="$API_DIR/.venv/bin/python"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: $PYTHON_BIN -m venv $API_DIR/.venv && pip install -e $API_DIR"
    return 0
  fi
  if [[ ! -x "$py" ]]; then
    sudo -u "$SETUP_USER" -H "$PYTHON_BIN" -m venv "$API_DIR/.venv"
  fi
  if ! sudo -u "$SETUP_USER" -H "$py" -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
    sudo -u "$SETUP_USER" -H "$py" -m pip install -U pip setuptools wheel
    sudo -u "$SETUP_USER" -H "$py" -m pip install -e "$API_DIR" "requests>=2.25.1"
  fi
  log "venv $py"
}

cliproxy_asset() {
  local arch asset
  arch="$(uname -m)"
  case "$arch" in
    x86_64) asset="linux_amd64" ;;
    aarch64|arm64) asset="linux_aarch64" ;;
    *)
      echo "refuse: no CLIProxy release asset for $arch" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$asset"
}

install_cliproxy_binary() {
  if [[ -x "$PROXY_BIN" ]]; then
    log "keep $PROXY_BIN"
    return 0
  fi
  local asset tag version archive url tmp binary group
  asset="$(cliproxy_asset)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: download CLIProxyAPI ${CLIPROXY_VERSION:-latest} ${asset} -> $PROXY_BIN"
    return 0
  fi
  if [[ -n "$CLIPROXY_VERSION" ]]; then
    tag="$CLIPROXY_VERSION"
    [[ "$tag" == v* ]] || tag="v$tag"
  else
    tag="$(curl -fsSL -H "User-Agent: company-setup" \
      https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
  fi
  version="${tag#v}"
  archive="CLIProxyAPI_${version}_${asset}.tar.gz"
  url="https://github.com/router-for-me/CLIProxyAPI/releases/download/${tag}/${archive}"
  tmp="$(mktemp -d)"
  log "download $url"
  # The checksum file names the archive. Saving under that name is what sha256sum -c checks.
  curl -fL --retry 3 -o "$tmp/$archive" "$url"
  curl -fsSL -o "$tmp/checksums.txt" \
    "https://github.com/router-for-me/CLIProxyAPI/releases/download/${tag}/checksums.txt"
  (
    cd "$tmp"
    grep "$archive" checksums.txt | sha256sum -c -
  )
  mkdir -p "$tmp/extract"
  tar -xzf "$tmp/$archive" -C "$tmp/extract"
  binary="$(find "$tmp/extract" -type f \( -name cli-proxy-api -o -name CLIProxyAPI \) -print -quit)"
  if [[ -z "$binary" ]]; then
    echo "refuse: release archive has no cli-proxy-api binary" >&2
    find "$tmp/extract" -type f >&2
    rm -rf "$tmp"
    exit 1
  fi
  install -d -o "$SETUP_USER" -g "$(id -gn "$SETUP_USER")" -m 755 "$PROXY_DIR/bin"
  install -o "$SETUP_USER" -g "$(id -gn "$SETUP_USER")" -m 755 "$binary" "$PROXY_BIN"
  rm -rf "$tmp"
  log "installed $PROXY_BIN ($tag)"
}

write_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    log "keep $ENV_FILE"
    return 0
  fi
  log "write $ENV_FILE"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local key
  key="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  umask 077
  cat >"$ENV_FILE" <<EOF
SUBJECTIVE_CHAT_HOME=/home/${SETUP_USER}/.subjective_chat
SUBJECTIVE_DEVAGENTS_CLIENT_ROOT=${CHAT_DIR}
SUBJECTIVE_DEVAGENTS_SERVE_UI=1
SUBJECTIVE_DEVAGENTS_PUBLIC_API=${PUBLIC_API}
SUBJECTIVE_DEVAGENTS_AUTH_MODE=owner
# This company's Firebase project. Required for sign-in; there is no built-in default.
# Any Firebase account for that project can sign in. The VM is the account boundary.
# FIREBASE_PROJECT_ID=
# FIREBASE_AUTH_DOMAIN=
# FIREBASE_API_KEY=
# FIREBASE_APP_ID=
# SUBJECTIVE_DEVAGENTS_DASHBOARD_URL=
# SUBJECTIVE_DEVAGENTS_PARENT_ORIGINS=
SUBJECTIVE_DEVAGENTS_EXEC_ENABLED=0
SUBJECTIVE_DEVAGENTS_LLM_WORKSPACE=${SUBJECTIVE_ROOT}
SUBJECTIVE_DEVAGENTS_LLM_PROXY_URL=http://127.0.0.1:8317/v1
SUBJECTIVE_DEVAGENTS_LLM_PROXY_API_KEY=${key}
SUBJECTIVE_DEVAGENTS_LLM_MODEL_CLAUDE=${MODEL_CLAUDE}
SUBJECTIVE_DEVAGENTS_LLM_MODEL_CODEX=${MODEL_CODEX}
SUBJECTIVE_DEVAGENTS_LLM_MODEL_GROK=${MODEL_GROK}
SUBJECTIVE_DEVAGENTS_LLM_MODEL_KIMI=${MODEL_KIMI}
PYTHONPATH=${API_DIR}/src:${API_DIR}/libs/dependencies/subjective-abstract-data-source-package:${API_DIR}/libs/dependencies/brainboost_configuration_package:${API_DIR}/libs/dependencies/brainboost_data_source_logger_package
EOF
  chmod 600 "$ENV_FILE"
}

env_value() {
  local key="$1"
  grep -m1 "^${key}=" "$ENV_FILE" | cut -d= -f2-
}

# Rewrite only server.host, management.allow-remote and
# management.disable-control-panel in an existing config. Keys stay as they are.
enforce_proxy_network() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: enforce $PROXY_CONFIG host='${PROXY_HOST}' allow-remote=${PROXY_ALLOW_REMOTE} disable-control-panel=${PROXY_DISABLE_PANEL}"
    return 0
  fi
  local result
  result="$(python3 - "$PROXY_CONFIG" "$PROXY_HOST" "$PROXY_ALLOW_REMOTE" "$PROXY_DISABLE_PANEL" <<'PY'
import pathlib, re, sys
path, host, allow, panel = sys.argv[1:5]
want = {
    "server": {"host": '"%s"' % host},
    "management": {"allow-remote": allow, "disable-control-panel": panel},
}
lines = pathlib.Path(path).read_text().splitlines()
out, section, seen = [], None, {k: set() for k in want}
def flush(sec):
    if sec in want:
        for key, val in want[sec].items():
            if key not in seen[sec]:
                out.append("  %s: %s" % (key, val))
                seen[sec].add(key)
for line in lines:
    top = re.match(r"^([A-Za-z0-9_-]+):\s*(#.*)?$", line)
    if top or (line and not line.startswith((" ", "#"))):
        flush(section)
        section = top.group(1) if top else None
        out.append(line)
        continue
    m = re.match(r"^  ([A-Za-z0-9_-]+):", line)
    if section in want and m and m.group(1) in want[section]:
        key = m.group(1)
        out.append("  %s: %s" % (key, want[section][key]))
        seen[section].add(key)
        continue
    out.append(line)
flush(section)
for sec in want:
    if sec not in [l.rstrip(":") for l in out if re.match(r"^[A-Za-z0-9_-]+:$", l)]:
        out.append(sec + ":")
        for key, val in want[sec].items():
            out.append("  %s: %s" % (key, val))
new = "\n".join(out) + "\n"
old = pathlib.Path(path).read_text()
if new != old:
    pathlib.Path(path).write_text(new)
    print("changed")
else:
    print("same")
PY
)"
  if [[ "$result" == "changed" ]]; then
    PROXY_CONFIG_CHANGED=1
    log "fix  $PROXY_CONFIG host='${PROXY_HOST}' allow-remote=${PROXY_ALLOW_REMOTE} disable-control-panel=${PROXY_DISABLE_PANEL}"
  else
    log "ok   $PROXY_CONFIG network settings"
  fi
}

write_proxy_config() {
  if [[ -f "$PROXY_CONFIG" ]]; then
    log "keep $PROXY_CONFIG"
    enforce_proxy_network
    return 0
  fi
  log "write $PROXY_CONFIG"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local client_key management_key group
  client_key="$(env_value SUBJECTIVE_DEVAGENTS_LLM_PROXY_API_KEY)"
  if [[ -z "$client_key" ]]; then
    echo "refuse: $ENV_FILE has no SUBJECTIVE_DEVAGENTS_LLM_PROXY_API_KEY" >&2
    exit 1
  fi
  management_key="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  umask 077
  cat >"$PROXY_CONFIG" <<EOF
config-version: 8
server:
  host: "${PROXY_HOST}"
  port: 8317
  tls:
    enable: false
management:
  allow-remote: ${PROXY_ALLOW_REMOTE}
  secret-key: "${management_key}"
  disable-control-panel: ${PROXY_DISABLE_PANEL}
access:
  api-keys:
    - "${client_key}"
oauth:
  auth-dir: "${PROXY_DIR}/auths"
EOF
  group="$(id -gn "$SETUP_USER")"
  chown "$SETUP_USER:$group" "$PROXY_CONFIG"
  chmod 600 "$PROXY_CONFIG"
  printf '%s\n' "$management_key" >"$MGMT_KEY_FILE"
  chmod 600 "$MGMT_KEY_FILE"
}

write_runner() {
  if [[ -f "$RUNNER" ]]; then
    log "keep $RUNNER"
    return 0
  fi
  log "write $RUNNER"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  cat >"$RUNNER" <<EOF
#!/bin/bash
set -euo pipefail
args=(
  -m uvicorn subjective_devagents_fastapi.app:app
  --app-dir ${API_DIR}/src
  --host 0.0.0.0
  --port 8080
)
cert=/etc/subjective-devagents-fastapi/tls/fullchain.pem
key=/etc/subjective-devagents-fastapi/tls/privkey.pem
if [[ -f "\$cert" && -f "\$key" ]]; then
  args+=(--ssl-certfile "\$cert" --ssl-keyfile "\$key")
fi
exec ${API_DIR}/.venv/bin/python "\${args[@]}"
EOF
  chown "$SETUP_USER:$(id -gn "$SETUP_USER")" "$RUNNER"
  chmod 755 "$RUNNER"
}

install_unit() {
  local name="$1"
  local marker="$2"
  local body="$3"
  local dest="/etc/systemd/system/${name}"
  if [[ -f "$dest" ]]; then
    if grep -F -q "$marker" "$dest"; then
      log "keep $dest"
      return 0
    fi
    echo "refuse: $dest already exists and does not belong to $SUBJECTIVE_ROOT" >&2
    exit 1
  fi
  log "write $dest"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  printf '%s\n' "$body" >"$dest"
  chmod 644 "$dest"
}

install_units() {
  install_unit "cli-proxy-api.service" "$PROXY_BIN" "[Unit]
Description=CLIProxyAPI (OpenAI-compatible proxy for DevAgents)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SETUP_USER}
Group=$(id -gn "$SETUP_USER" 2>/dev/null || echo "$SETUP_USER")
WorkingDirectory=${PROXY_DIR}
Environment=HOME=/home/${SETUP_USER}
ExecStart=${PROXY_BIN} --config ${PROXY_CONFIG}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillMode=control-group
KillSignal=SIGTERM
UMask=0077
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cli-proxy-api

[Install]
WantedBy=multi-user.target"

  install_unit "subjective-devagents-fastapi.service" "$RUNNER" "[Unit]
Description=Subjective DevAgents FastAPI
Wants=network-online.target cli-proxy-api.service
After=network-online.target cli-proxy-api.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SETUP_USER}
Group=$(id -gn "$SETUP_USER" 2>/dev/null || echo "$SETUP_USER")
WorkingDirectory=${API_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${RUNNER}
Restart=on-failure
RestartSec=5
TimeoutStopSec=45
KillMode=control-group
KillSignal=SIGINT
UMask=0077
StandardOutput=journal
StandardError=journal
SyslogIdentifier=devagents-fastapi

[Install]
WantedBy=multi-user.target"
}

port_open() {
  local port="$1"
  ss -ltn | awk -v p=":${port}" 'NR > 1 && index($4, p) { found = 1 } END { exit !found }'
}

start_unit() {
  local unit="$1"
  local port="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: systemctl enable --now $unit"
    return 0
  fi
  systemctl daemon-reload
  if systemctl is-active --quiet "$unit"; then
    if [[ "$unit" == "cli-proxy-api.service" && "$PROXY_CONFIG_CHANGED" -eq 1 ]]; then
      log "restart $unit (config changed)"
      systemctl restart "$unit"
      return 0
    fi
    log "active $unit"
    return 0
  fi
  if port_open "$port"; then
    echo "refuse: port $port is already in use, not starting $unit" >&2
    ss -ltnp | awk -v p=":${port}" 'NR == 1 || index($4, p)' >&2 || true
    exit 1
  fi
  systemctl enable --now "$unit"
}

wait_http() {
  local url="$1"
  local extra=()
  if [[ $# -gt 1 ]]; then
    extra=("${@:2}")
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if curl -fsS --max-time 2 "${extra[@]}" "$url" >/dev/null 2>&1; then
      log "ok $url"
      return 0
    fi
    sleep 1
  done
  echo "fail: $url did not become ready" >&2
  return 1
}

verify_services() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: curl http://127.0.0.1:8317/v1/models and http://127.0.0.1:8080/healthz"
    return 0
  fi
  local key curlcfg
  key="$(env_value SUBJECTIVE_DEVAGENTS_LLM_PROXY_API_KEY)"
  curlcfg="$(mktemp)"
  chmod 600 "$curlcfg"
  printf 'header = "Authorization: Bearer %s"\n' "$key" >"$curlcfg"
  if ! wait_http "http://127.0.0.1:8317/v1/models" -K "$curlcfg"; then
    rm -f "$curlcfg"
    journalctl -u cli-proxy-api.service -n 40 --no-pager >&2 || true
    exit 1
  fi
  rm -f "$curlcfg"
  local api_url="http://127.0.0.1:8080/healthz" api_extra=()
  if [[ -f "$API_TLS_DIR/fullchain.pem" && -f "$API_TLS_DIR/privkey.pem" ]]; then
    api_url="https://127.0.0.1:8080/healthz"
    api_extra=(-k)
  fi
  if ! wait_http "$api_url" "${api_extra[@]}"; then
    journalctl -u subjective-devagents-fastapi.service -n 40 --no-pager >&2 || true
    exit 1
  fi
}

# Keep SUBJECTIVE_DEVAGENTS_PUBLIC_API empty (same-origin) in an existing env
# file. The old default http://127.0.0.1:8080 made the served page call the
# visitor's own machine.
enforce_public_api() {
  [[ "$DRY_RUN" -eq 1 || ! -f "$ENV_FILE" ]] && return 0
  if grep -q '^SUBJECTIVE_DEVAGENTS_PUBLIC_API=http://127.0.0.1:8080$' "$ENV_FILE"; then
    sed -i 's#^SUBJECTIVE_DEVAGENTS_PUBLIC_API=http://127.0.0.1:8080$#SUBJECTIVE_DEVAGENTS_PUBLIC_API=#' "$ENV_FILE"
    API_ENV_CHANGED=1
    log "fix  $ENV_FILE SUBJECTIVE_DEVAGENTS_PUBLIC_API= (same-origin)"
  fi
}
API_ENV_CHANGED=0

setup_api_tls() {
  if [[ "$API_TLS" != "1" ]]; then
    log "skip API TLS (API_TLS=$API_TLS)"
    return 0
  fi
  local label domains="" zone
  label="$(printf '%s' "$COMPANY_NAME" | tr '[:upper:]' '[:lower:]')"
  for zone in $API_TLS_ZONES; do
    domains+="${domains:+,}${label}-api.${zone}"
  done
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: certbot certonly --standalone -d $domains; install subjective-api-tls.timer"
    return 0
  fi
  apt-get install -y certbot
  mkdir -p "$API_TLS_DIR"
  chmod 755 /etc/subjective-devagents-fastapi
  cat >/usr/local/sbin/subjective-api-tls-deploy.sh <<EOF
#!/bin/bash
# certbot deploy hook: copy the certificate where run-systemd.sh looks, restart the API.
set -euo pipefail
live=/etc/letsencrypt/live/subjective-api
install -d -m 750 -o ${SETUP_USER} -g $(id -gn "$SETUP_USER") ${API_TLS_DIR}
install -m 600 -o ${SETUP_USER} -g $(id -gn "$SETUP_USER") "\$live/fullchain.pem" ${API_TLS_DIR}/fullchain.pem
install -m 600 -o ${SETUP_USER} -g $(id -gn "$SETUP_USER") "\$live/privkey.pem" ${API_TLS_DIR}/privkey.pem
systemctl restart subjective-devagents-fastapi.service
EOF
  chmod 755 /usr/local/sbin/subjective-api-tls-deploy.sh
  cat >/usr/local/sbin/subjective-api-tls.sh <<EOF
#!/bin/bash
# Obtain the API certificate once DNS resolves. Renewal is certbot.timer's job.
set -uo pipefail
if [[ -f /etc/letsencrypt/live/subjective-api/fullchain.pem ]]; then
  [[ -f ${API_TLS_DIR}/fullchain.pem ]] || /usr/local/sbin/subjective-api-tls-deploy.sh
  systemctl disable --now subjective-api-tls.timer >/dev/null 2>&1 || true
  exit 0
fi
certbot certonly --standalone --non-interactive --agree-tos \\
  --register-unsafely-without-email --cert-name subjective-api \\
  --deploy-hook /usr/local/sbin/subjective-api-tls-deploy.sh \\
  -d ${domains}
EOF
  chmod 755 /usr/local/sbin/subjective-api-tls.sh
  cat >/etc/systemd/system/subjective-api-tls.service <<EOF
[Unit]
Description=Obtain Let's Encrypt certificate for the DevAgents API (${domains})
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/subjective-api-tls.sh
EOF
  cat >/etc/systemd/system/subjective-api-tls.timer <<EOF
[Unit]
Description=Retry the DevAgents API certificate until DNS resolves

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if /usr/local/sbin/subjective-api-tls.sh; then
    log "ok   API TLS for $domains"
  else
    log "wait API TLS for $domains (DNS not ready?); subjective-api-tls.timer retries every 15 min"
    systemctl enable --now subjective-api-tls.timer
  fi
}

foreign_unit() {
  local unit="$1"
  local marker="$2"
  local dest="/etc/systemd/system/${unit}"
  if [[ -f "$dest" ]] && ! grep -F -q "$marker" "$dest"; then
    echo "refuse: $dest is already installed for a different tree" >&2
    exit 1
  fi
}

refuse_monorepo
foreign_unit "cli-proxy-api.service" "$PROXY_BIN"
foreign_unit "subjective-devagents-fastapi.service" "$RUNNER"
read_company_file

if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -ne 0 ]]; then
  echo "refuse: run as root so users, /etc, and systemd can be installed" >&2
  exit 1
fi

log "company $COMPANY_NAME"
log "file    $COMPANY_FILE"
log "root    $SUBJECTIVE_ROOT"

install_packages
ensure_python
ensure_user

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: write $COMPANY_NAME to $COMPANY_FILE"
  log "dry-run: mkdir -p $SUBJECTIVE_ROOT"
else
  if [[ ! -e "$COMPANY_FILE" ]]; then
    printf '%s\n' "$COMPANY_NAME" >"$COMPANY_FILE"
    chmod 644 "$COMPANY_FILE"
  fi
  mkdir -p "$SUBJECTIVE_ROOT"
fi

clone_repo "subjective_devagents_fastapi.git" "services/subjective_devagents_fastapi"
clone_repo "CLIProxyAPI.git" "services/CLIProxyAPI"
clone_repo "subjective_chat.git" "clients/desktop/subjective_chat"

chown_tree
install_venv
install_cliproxy_binary
write_env_file
enforce_public_api
write_proxy_config
write_runner
install_units
start_unit "cli-proxy-api.service" 8317
start_unit "subjective-devagents-fastapi.service" 8080
if [[ "$API_ENV_CHANGED" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
  log "restart subjective-devagents-fastapi.service (env changed)"
  systemctl restart subjective-devagents-fastapi.service
fi
verify_services
setup_api_tls

log "done"
log "services: cli-proxy-api.service on ${PROXY_HOST:-0.0.0.0}:8317, subjective-devagents-fastapi.service on :8080"
log "client key: $ENV_FILE (not printed)"
log "management key: $MGMT_KEY_FILE (not printed)"
log "not installed: nginx :8788, port-80 socket, legacy Node :8787, logs service, vendor CLIs"
log "still manual: provider login into $PROXY_DIR/auths"
log "API: https://<company>-api.<zone>:8080 (Let's Encrypt; subjective-api-tls.timer retries until DNS resolves)"
log "public DNS + Cloudflare :8317 rule: provision_server.py (https://<company>-cliproxy.<zone>)"
