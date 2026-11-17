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

Check the install after it finishes. This is read-only and exits 0 only when the files, git checkouts, and both services are healthy:

```bash
sudo ./company_verify.sh "Company Name"
```

Omit the name to accept whatever `/company_name` already contains. A service that is down, a checkout that is missing, or a health check that fails makes the script exit 1. No provider login yet is a warning, not a failure.

## Services

| Unit | Listen |
|---|---|
| `cli-proxy-api.service` | `0.0.0.0:8317` |
| `subjective-devagents-fastapi.service` | `0.0.0.0:8080` |

DevAgents is served at `https://<company>-devagents.<zone>:8080` for each zone (`subjectivetechnologies.com` and `worktwins.com`). `company_setup.sh` requests one Let's Encrypt certificate covering those names. The DNS records are created when the VM is provisioned. Until they resolve, `subjective-api-tls.timer` retries the certificate every 15 minutes.

The proxy client key is stored in `/etc/subjective-devagents-fastapi.env` (mode 600) and is not printed. The web dashboard reaches CLIProxy through Cloudflare at `https://<company>-cliproxy.<zone>`. `provision_server.py` creates that DNS record and the Cloudflare rule that forwards it to port 8317. So CLIProxy listens on all interfaces with `management.allow-remote: true` and the control panel on. `/v1` still needs the client key and `/v0/management` the management key. Re-running `company_setup.sh` puts those three settings back if they drifted, and restarts the proxy only when something changed. `CLIPROXY_PUBLIC=0` keeps the old localhost-only mode.

## Company repository folder

The script also creates `/<company>/<company>`, for example `/cardnexia/cardnexia`. The folder name is the company name in lowercase, with anything other than letters, digits and `-` turned into `-`. The company's own repository is cloned there, and the agents write the company's model and code there, for example `/cardnexia/cardnexia/architecture/cardnexia.xmi`. The UML editor opens that file.

The dashboard clones the repository over SSH as root, but the agents run as `subjective`. So the script gives `subjective` read and write access through ACLs, default ACLs included. That covers files created later by root as well. It also adds the folder to the system git `safe.directory`, so root and `subjective` can both run git in it whoever owns the files. Running the script again fixes the permissions on a repository cloned before this step existed. `company_verify.sh` fails if `subjective` cannot write a file there. It warns if the repository or its `.xmi` model is still missing or empty.

## After the services are up

Each machine has its own CLIProxy. Provider subscriptions stay in that machine's `auths/` directory and are not part of these repositories. A chat turn needs a provider login there. The proxy process starts without one. Antigravity login also needs that company's own Google OAuth client in `ANTIGRAVITY_OAUTH_CLIENT_ID` and `ANTIGRAVITY_OAUTH_CLIENT_SECRET` on the proxy service. Claude, Codex, Grok, and Kimi logins use the provider's public client and then store only that user's subscription locally.

Sign-in is a Firebase ID token for this machine's project. Any account that token verifies for is accepted. The virtual machine is the account boundary, so a new VM does not need an owner email or UID. Set `FIREBASE_PROJECT_ID`, `FIREBASE_AUTH_DOMAIN`, `FIREBASE_API_KEY`, and `FIREBASE_APP_ID` in `/etc/subjective-devagents-fastapi.env`. The API does not assume a project when those are empty.

```bash
sudo -u subjective /subjective/services/CLIProxyAPI/bin/cli-proxy-api \
  --config /subjective/services/CLIProxyAPI/config.yaml --claude-login
```

The same binary accepts `--codex-login`, `--xai-login`, and `--kimi-login`.

For HTTPS, put the certificate at `/etc/subjective-devagents-fastapi/tls/fullchain.pem` and the key at `privkey.pem`, then restart `subjective-devagents-fastapi`. The service listens with TLS when both files are present.
