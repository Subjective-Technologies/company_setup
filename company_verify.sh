#!/usr/bin/env bash
#
# company_verify.sh — check a machine provisioned by company_setup.sh.
#
# Usage:
#   sudo ./company_verify.sh
#   sudo ./company_verify.sh cardnexia
#
# Read-only. Prints one line per check. Exits 0 when every required check
# passes. A missing provider login is a warning: the services can be up
# before anyone has logged Claude, Codex, Grok, or Kimi into CLIProxy.
# Secrets are not printed.

set -u

SUBJECTIVE_ROOT="${SUBJECTIVE_ROOT:-/subjective}"
COMPANY_FILE="${COMPANY_FILE:-/company_name}"
SETUP_USER="${SETUP_USER:-subjective}"
ENV_FILE="${ENV_FILE:-/etc/subjective-devagents-fastapi.env}"
MGMT_KEY_FILE="${MGMT_KEY_FILE:-/etc/cli-proxy-api.management-key}"

API_DIR="${SUBJECTIVE_ROOT}/services/subjective_devagents_fastapi"
PROXY_DIR="${SUBJECTIVE_ROOT}/services/CLIProxyAPI"
CHAT_DIR="${SUBJECTIVE_ROOT}/clients/desktop/subjective_chat"
PROXY_BIN="${PROXY_DIR}/bin/cli-proxy-api"
PROXY_CONFIG="${PROXY_DIR}/config.yaml"
RUNNER="${API_DIR}/run-systemd.sh"
TLS_CERT="/etc/subjective-devagents-fastapi/tls/fullchain.pem"
TLS_KEY="/etc/subjective-devagents-fastapi/tls/privkey.pem"

EXPECTED_COMPANY="${1:-}"
failures=0
warnings=0

usage() {
  cat <<'EOF'
Usage: company_verify.sh [company_name]

Check the DevAgents API and CLIProxy install. Run as root. Pass a company
name to require that /company_name contains that exact name.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

ok() { printf 'ok   %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "refuse: run as root so mode-600 files and service state can be read" >&2
  exit 1
fi

mode_of() { stat -c '%a' "$1" 2>/dev/null || echo missing; }
owner_of() { stat -c '%U' "$1" 2>/dev/null || echo missing; }

env_value() {
  local key="$1"
  grep -m1 "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

check_company() {
  if [[ ! -f "$COMPANY_FILE" ]]; then
    fail "company file missing: $COMPANY_FILE"
    return
  fi
  local name
  name="$(head -n 1 "$COMPANY_FILE")"
  if [[ -z "$name" || "$name" == *"/"* || "$name" == *$'\n'* ]]; then
    fail "company file is empty or not a single name"
    return
  fi
  if [[ -n "$EXPECTED_COMPANY" && "$name" != "$EXPECTED_COMPANY" ]]; then
    fail "company file says '$name', expected '$EXPECTED_COMPANY'"
    return
  fi
  ok "company $name"
}

check_user() {
  if id "$SETUP_USER" >/dev/null 2>&1; then
    ok "user $SETUP_USER ($(getent passwd "$SETUP_USER" | cut -d: -f6))"
  else
    fail "user $SETUP_USER does not exist"
  fi
  local home="/home/$SETUP_USER/.subjective_chat"
  if [[ -d "$home" ]]; then
    ok "chat home $home"
  else
    fail "chat home missing: $home"
  fi
}

# Repos are owned by the service user. Root must opt in or git refuses them.
git_as_root() {
  git -c 'safe.directory=*' -C "$1" "${@:2}"
}

check_git_repo() {
  local dest="$1"
  local label="$2"
  if [[ ! -d "$dest" ]]; then
    fail "$label missing: $dest"
    return
  fi
  if [[ ! -d "$dest/.git" && ! -f "$dest/.git" ]]; then
    fail "$label is not a git checkout: $dest"
    return
  fi
  local sha err
  if ! err="$(git_as_root "$dest" rev-parse --verify HEAD 2>&1)"; then
    fail "$label git: ${err//$'\n'/ }"
    return
  fi
  sha="$err"
  if ! git_as_root "$dest" cat-file -e "$sha" 2>/dev/null; then
    fail "$label object database is missing $sha"
    return
  fi
  ok "$label ${sha:0:12} $dest"
}

check_submodules() {
  if [[ ! -f "$API_DIR/.gitmodules" ]]; then
    fail "API submodules file missing: $API_DIR/.gitmodules"
    return
  fi
  local status
  if ! status="$(git_as_root "$API_DIR" submodule status --recursive 2>&1)"; then
    fail "API submodule status: ${status//$'\n'/ }"
    return
  fi
  local missing=0 line path count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    count=$((count + 1))
    case "$line" in
      -*)
        missing=1
        path="${line#* }"
        fail "API submodule not checked out: $path"
        ;;
    esac
  done <<<"$status"
  if [[ "$count" -eq 0 ]]; then
    fail "API submodule list is empty"
    return
  fi
  if [[ "$missing" -eq 0 ]]; then
    ok "API submodules checked out ($count)"
  fi
}

check_venv() {
  local py="$API_DIR/.venv/bin/python"
  if [[ ! -x "$py" ]]; then
    fail "API virtualenv missing: $py"
    return
  fi
  if sudo -u "$SETUP_USER" -H "$py" -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
    ok "API virtualenv imports fastapi and uvicorn"
  else
    fail "API virtualenv cannot import fastapi and uvicorn"
  fi
}

check_proxy_binary() {
  if [[ ! -x "$PROXY_BIN" ]]; then
    fail "CLIProxy binary missing: $PROXY_BIN"
    return
  fi
  local magic
  magic="$(od -An -t x1 -N 4 "$PROXY_BIN" | tr -d ' \n')"
  if [[ "$magic" != "7f454c46" ]]; then
    fail "CLIProxy binary is not an ELF executable"
    return
  fi
  if [[ "$(owner_of "$PROXY_BIN")" != "$SETUP_USER" ]]; then
    fail "CLIProxy binary owner is $(owner_of "$PROXY_BIN"), expected $SETUP_USER"
    return
  fi
  ok "CLIProxy binary $PROXY_BIN"
}

check_secret_file() {
  local path="$1"
  local label="$2"
  local expect_owner="$3"
  if [[ ! -f "$path" ]]; then
    fail "$label missing: $path"
    return
  fi
  local mode owner
  mode="$(mode_of "$path")"
  owner="$(owner_of "$path")"
  if [[ "$mode" != "600" ]]; then
    fail "$label mode is $mode, expected 600"
  else
    ok "$label mode 600"
  fi
  if [[ "$owner" != "$expect_owner" ]]; then
    fail "$label owner is $owner, expected $expect_owner"
  else
    ok "$label owner $owner"
  fi
  if [[ ! -s "$path" ]]; then
    fail "$label is empty"
  fi
}

check_env_contract() {
  local key value
  for key in \
    SUBJECTIVE_CHAT_HOME \
    SUBJECTIVE_DEVAGENTS_CLIENT_ROOT \
    SUBJECTIVE_DEVAGENTS_LLM_WORKSPACE \
    SUBJECTIVE_DEVAGENTS_LLM_PROXY_URL \
    SUBJECTIVE_DEVAGENTS_LLM_PROXY_API_KEY \
    SUBJECTIVE_DEVAGENTS_LLM_MODEL_CLAUDE \
    SUBJECTIVE_DEVAGENTS_LLM_MODEL_CODEX \
    SUBJECTIVE_DEVAGENTS_LLM_MODEL_GROK \
    SUBJECTIVE_DEVAGENTS_LLM_MODEL_KIMI
  do
    value="$(env_value "$key")"
    if [[ -z "$value" ]]; then
      fail "env $key is unset"
    else
      ok "env $key is set"
    fi
  done
  value="$(env_value SUBJECTIVE_DEVAGENTS_LLM_PROXY_URL)"
  if [[ "$value" != "http://127.0.0.1:8317/v1" ]]; then
    fail "proxy URL is '$value', expected http://127.0.0.1:8317/v1"
  else
    ok "proxy URL points at localhost:8317"
  fi
  value="$(env_value SUBJECTIVE_DEVAGENTS_LLM_WORKSPACE)"
  if [[ "$value" != "$SUBJECTIVE_ROOT" || ! -d "$value" ]]; then
    fail "workspace is not $SUBJECTIVE_ROOT"
  else
    ok "workspace $value"
  fi
  value="$(env_value SUBJECTIVE_DEVAGENTS_CLIENT_ROOT)"
  if [[ "$value" != "$CHAT_DIR" || ! -d "$value" ]]; then
    fail "client root is not $CHAT_DIR"
  else
    ok "client root $value"
  fi
}

check_key_agreement() {
  local key
  key="$(env_value SUBJECTIVE_DEVAGENTS_LLM_PROXY_API_KEY)"
  if [[ -z "$key" || ! -f "$PROXY_CONFIG" ]]; then
    fail "cannot compare proxy client key with config"
    return
  fi
  if python3 - "$PROXY_CONFIG" "$key" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
key = sys.argv[2]
sys.exit(0 if key and key in text else 1)
PY
  then
    ok "proxy config contains the API client key"
  else
    fail "proxy config does not contain the API client key"
  fi
}

check_unit() {
  local unit="$1"
  local marker="$2"
  local unit_path="/etc/systemd/system/$unit"
  if [[ ! -f "$unit_path" ]]; then
    fail "unit file missing: $unit_path"
    return
  fi
  if ! grep -F -q "$marker" "$unit_path"; then
    fail "$unit does not reference $marker"
  else
    ok "$unit references its program"
  fi
  if systemctl is-enabled --quiet "$unit"; then
    ok "$unit enabled"
  else
    fail "$unit is not enabled"
  fi
  if systemctl is-active --quiet "$unit"; then
    local user pid
    user="$(systemctl show -p User --value "$unit")"
    pid="$(systemctl show -p MainPID --value "$unit")"
    if [[ "$user" == "$SETUP_USER" && "$pid" != "0" ]]; then
      ok "$unit active pid $pid user $user"
    else
      fail "$unit active but user='$user' pid='$pid'"
    fi
  else
    fail "$unit is not active"
  fi
}

check_listeners() {
  local rows
  rows="$(ss -ltn 'sport = :8317' | awk 'NR > 1 { print $4 }')"
  if [[ -z "$rows" ]]; then
    fail "nothing is listening on port 8317"
  elif grep -Eq '(^|[^0-9])(\*|0\.0\.0\.0|\[::\]):8317$' <<<"$rows"; then
    fail "CLIProxy is listening outside localhost: $rows"
  elif grep -q '127.0.0.1:8317' <<<"$rows"; then
    ok "CLIProxy listens on 127.0.0.1:8317"
  else
    fail "CLIProxy listener is unexpected: $rows"
  fi
  if ss -ltn 'sport = :8080' | awk 'NR > 1 { found = 1 } END { exit !found }'; then
    ok "DevAgents API listens on port 8080"
  else
    fail "nothing is listening on port 8080"
  fi
}

api_base() {
  if [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]]; then
    printf '%s\n' "https://127.0.0.1:8080"
  else
    printf '%s\n' "http://127.0.0.1:8080"
  fi
}

check_http() {
  local base curl_tls=()
  base="$(api_base)"
  if [[ "$base" == https:* ]]; then
    curl_tls=(-k)
    ok "API TLS files present; checking $base"
  else
    ok "API has no TLS files; checking $base"
  fi
  local body
  if body="$(curl -fsS --max-time 5 "${curl_tls[@]}" "$base/healthz" 2>/dev/null)" && grep -q '"ok"[[:space:]]*:[[:space:]]*true' <<<"$body"; then
    ok "API /healthz ok"
  else
    fail "API /healthz did not return ok"
  fi

  local code key curlcfg
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8317/v1/models || true)"
  if [[ "$code" == "401" ]]; then
    ok "CLIProxy rejects a request with no key"
  else
    fail "CLIProxy /v1/models without a key returned $code, expected 401"
  fi
  key="$(env_value SUBJECTIVE_DEVAGENTS_LLM_PROXY_API_KEY)"
  if [[ -z "$key" ]]; then
    fail "cannot call CLIProxy with the client key"
    return
  fi
  curlcfg="$(mktemp)"
  chmod 600 "$curlcfg"
  printf 'header = "Authorization: Bearer %s"\n' "$key" >"$curlcfg"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -K "$curlcfg" http://127.0.0.1:8317/v1/models || true)"
  rm -f "$curlcfg"
  if [[ "$code" == "200" ]]; then
    ok "CLIProxy /v1/models accepts the client key"
  else
    fail "CLIProxy /v1/models with the client key returned $code, expected 200"
  fi
}

check_provider_logins() {
  local count
  if [[ ! -d "$PROXY_DIR/auths" ]]; then
    warn "CLIProxy auth directory missing: $PROXY_DIR/auths"
    return
  fi
  count="$(find "$PROXY_DIR/auths" -maxdepth 1 -type f -name '*.json' | wc -l)"
  if [[ "$count" -eq 0 ]]; then
    warn "no provider logins in $PROXY_DIR/auths; the proxy is up and a chat turn still needs one"
  else
    ok "provider login files: $count"
  fi
}

check_company
check_user
check_git_repo "$API_DIR" "DevAgents API"
check_git_repo "$PROXY_DIR" "CLIProxy"
check_git_repo "$CHAT_DIR" "chat UI"
check_submodules
check_venv
check_proxy_binary
check_secret_file "$ENV_FILE" "API env" root
check_secret_file "$PROXY_CONFIG" "CLIProxy config" "$SETUP_USER"
check_secret_file "$MGMT_KEY_FILE" "CLIProxy management key" root
check_env_contract
check_key_agreement
if [[ -x "$RUNNER" ]]; then
  ok "API runner $RUNNER"
else
  fail "API runner missing: $RUNNER"
fi
check_unit "cli-proxy-api.service" "$PROXY_BIN"
check_unit "subjective-devagents-fastapi.service" "$RUNNER"
check_listeners
check_http
check_provider_logins

echo
if [[ "$failures" -eq 0 ]]; then
  printf 'passed (%s warning(s))\n' "$warnings"
  exit 0
fi
printf 'failed %s check(s), %s warning(s)\n' "$failures" "$warnings"
exit 1
