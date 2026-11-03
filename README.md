# company_setup

Provision a blank Ubuntu VPS with the DevAgents API and CLIProxy.

Clone this repository on the new server and run `company_setup.sh` as root. The script writes the company name to `/company_name`, creates `/subjective`, clones only the repositories those two services need, and starts them under systemd.

## Requirements

- Ubuntu 22.04, 24.04, or newer
- Root
- No GitHub account on the server. This repository, the DevAgents API, CLIProxy, the chat UI, and the API submodules are public and are cloned over HTTPS.

## Run

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/Subjective-Technologies/company_setup.git
cd company_setup
sudo ./company_setup.sh "Company Name"
```

Preview the plan without changing the machine:

```bash
sudo ./company_setup.sh --dry-run "Company Name"
```

Running it again keeps existing checkouts, the generated key, and unit files that already belong to this tree.

## Services

| Unit | Listen |
|---|---|
| `cli-proxy-api.service` | `127.0.0.1:8317` |
| `subjective-devagents-fastapi.service` | `0.0.0.0:8080` |

The proxy client key is stored in `/etc/subjective-devagents-fastapi.env` (mode 600) and is not printed. CLIProxy accepts connections from this machine only.

## After the services are up

A chat turn needs a provider login in `auths/`. The proxy process starts without one.

```bash
sudo -u subjective /subjective/services/CLIProxyAPI/bin/cli-proxy-api \
  --config /subjective/services/CLIProxyAPI/config.yaml --claude-login
```

The same binary accepts `--codex-login`, `--xai-login`, and `--kimi-login`.

For HTTPS, put the certificate at `/etc/subjective-devagents-fastapi/tls/fullchain.pem` and the key at `privkey.pem`, then restart `subjective-devagents-fastapi`. The service listens with TLS when both files are present.
