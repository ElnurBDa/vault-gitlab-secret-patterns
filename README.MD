# Vault + GitLab Secret Patterns

A hands-on lab comparing **five ways to deliver secrets** to a deployed app with **GitLab CI/CD** and **OpenBao** (an open-source fork of HashiCorp Vault), backed by a small self-hosted environment on Azure. The same tiny app is deployed five times; the only thing that changes is how its `APP_USERNAME` / `APP_PASSWORD` reaches it — from a plaintext `.env` file all the way to live fetches from OpenBao.

> 📝 **Full write-up:** [Secret Management with OpenBao and GitLab CI/CD](https://elnurbda.com/posts/59-openbao-gitlab)

## What's inside

| Directory | Port | Secret delivery |
|---|---|---|
| [`app-traditional-env`](app-traditional-env) | 80 | GitLab CI variables → `.env` file on prod |
| [`app-better-env`](app-better-env) | 81 | GitLab CI variables → container env (`-e`) |
| [`app-vault-env`](app-vault-env) | 82 | OpenBao, fetched in CI (JWT/OIDC) |
| [`app-vault-agent-env`](app-vault-agent-env) | 83 | OpenBao via a Vault Agent → tmpfs `--env-file` |
| [`app-vault-direct-env`](app-vault-direct-env) | 84 | OpenBao, fetched live by the app on every request |

Infrastructure:

- [`azure_env_setup.sh`](azure_env_setup.sh) — provisions the five Azure VMs (proxy, GitLab, runner, OpenBao, prod)
- The setup guide below — GitLab, GitLab Runner, OpenBao, and the integration wiring

## Setup

The full step-by-step setup follows — work top to bottom, each host builds on the previous one.

## On your machine

```bash
sshuttle -r sre-proxy 10.10.1.0/24
```

`/etc/hosts`
```
10.10.1.5    gitlab.elnurbda.com
10.10.1.8    vault.elnurbda.com
```

## On each node

Install Docker and Compose:
- https://docs.docker.com/engine/install/ubuntu/

`/etc/hosts`
```
10.10.1.4  proxy
10.10.1.5  gitlab gitlab.elnurbda.com
10.10.1.6  gitlab-runner
10.10.1.7  prod
10.10.1.8  secman vault.elnurbda.com
```

---

## GitLab

- https://docs.gitlab.com/install/docker/installation/

`/srv/docker-compose.yml`
```yaml
services:
  gitlab:
    image: gitlab/gitlab-ee:latest
    container_name: gitlab
    restart: always
    hostname: 'gitlab.elnurbda.com'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://gitlab.elnurbda.com'
        gitlab_rails['gitlab_shell_ssh_port'] = 2222
        letsencrypt['enable'] = false
        nginx['redirect_http_to_https'] = true
    ports:
      - '80:80'
      - '443:443'
      - '2222:22'
    volumes:
      - '/srv/gitlab/config:/etc/gitlab'
      - '/srv/gitlab/logs:/var/log/gitlab'
      - '/srv/gitlab/data:/var/opt/gitlab'
    shm_size: '256m'
```

---

## GitLab Runner

- https://docs.gitlab.com/runner/install/linux-repository/

Register using the script provided by GitLab (Admin → Runners).

---

## Vault (OpenBao)

- https://github.com/TheHamkerCat/openbao-docker-compose

### 1. Extract GitLab's self-signed certificate

Run on the `secman` host (needs network access to GitLab):

```bash
openssl s_client -connect gitlab.elnurbda.com:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > /srv/gitlab.pem
```

### 2. Compose file

`/srv/docker-compose.yml`
```yaml
services:
  openbao:
    image: openbao/openbao:2.3.1
    command: ['server', '-config=/openbao/config/bao.conf']
    cap_add:
      - IPC_LOCK
    ports:
      - "0.0.0.0:8200:8200"
      - "0.0.0.0:8201:8201"
    environment:
      - VAULT_ADDR=http://vault.elnurbda.com:8200
    healthcheck:
      interval: 2s
      retries: 10
      start_period: 5s
      test: 'wget --spider http://127.0.0.1:8200/v1/sys/seal-status || exit 1'
      timeout: 10s
    networks:
      - openbao
    volumes:
      - ./config:/openbao/config
      - ./data/openbao_logs:/openbao/logs
      - ./data/openbao_file:/openbao/file
      - ./gitlab.pem:/openbao/config/gitlab.pem   # GitLab CA cert for JWKS validation
    extra_hosts:
      - "gitlab.elnurbda.com:10.10.1.5"           # DNS override — container doesn't use host /etc/hosts
      - "vault.elnurbda.com:10.10.1.8"
volumes:
  pg_data:
  openbao_logs:
  openbao_file:
networks:
  openbao:
```

### 3. Vault config

`/srv/config/bao.conf`
```hcl
storage "raft" {
  path    = "/openbao/file"
  node_id = "node1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

cluster_addr = "http://vault.elnurbda.com:8201"
api_addr     = "http://vault.elnurbda.com:8200"

plugin_directory = "/openbao/plugins"
ui               = true

default_lease_ttl = "168h"   # 7 days
max_lease_ttl     = "720h"   # 30 days
```

---

## GitLab ↔ OpenBao Integration

### OpenBao setup

Two auth methods, because two kinds of client log in: CI jobs use **JWT/OIDC**, prod
workloads (the Vault Agent and the SDK app) use **AppRole**. Each gets a policy scoped to
one app's single path — never a blanket `secret/data/*`. Run after init and unseal:

```bash
# KV v2 for app secrets
docker compose exec openbao bao secrets enable -path=secret kv-v2

# --- JWT auth: trust GitLab's OIDC tokens (CI jobs authenticate this way) ---
# jwks_ca_pem required because GitLab uses a self-signed cert
docker compose exec openbao bao auth enable jwt
docker compose exec openbao bao write auth/jwt/config \
  jwks_url="https://gitlab.elnurbda.com/oauth/discovery/keys" \
  bound_issuer="https://gitlab.elnurbda.com" \
  jwks_ca_pem=@/openbao/config/gitlab.pem

# One policy + one role PER project, each scoped to that project's single path
# (shown for app-vault-env; repeat for the other projects).
cat > /tmp/app-vault-env.hcl << 'EOF'
path "secret/data/app-vault-env/prod" {
  capabilities = ["read"]
}
EOF
docker compose exec -T openbao bao policy write app-vault-env - < /tmp/app-vault-env.hcl

# project_path is the project's GitLab namespace/path (e.g. root/app-vault-env), NOT the
# OS user. bound_audiences is a distinct value, not the GitLab URL. Both must match the
# token exactly or the login 403s.
docker compose exec openbao bao write auth/jwt/role/app-vault-env \
  role_type="jwt" \
  policies="app-vault-env" \
  token_ttl="15m" \
  token_max_ttl="30m" \
  bound_audiences="openbao" \
  bound_claims_type="string" \
  bound_claims.project_path="root/app-vault-env" \
  user_claim="project_path"

# --- AppRole: for prod workloads, one role + scoped policy per app ---
docker compose exec openbao bao auth enable approle

cat > /tmp/app-vault-agent-env.hcl << 'EOF'
path "secret/data/app-vault-agent-env/prod" {
  capabilities = ["read"]
}
EOF
docker compose exec -T openbao bao policy write app-vault-agent-env - < /tmp/app-vault-agent-env.hcl

docker compose exec openbao bao write auth/approle/role/app-vault-agent-env \
  token_policies="app-vault-agent-env" \
  token_ttl="1h" \
  token_max_ttl="4h"

# role-id + a response-wrapped secret-id (the raw value never lands in logs/history)
docker compose exec openbao bao read auth/approle/role/app-vault-agent-env/role-id
docker compose exec openbao bao write -f -wrap-ttl=120s auth/approle/role/app-vault-agent-env/secret-id
```

### GitLab CI variables

Set in **Settings → CI/CD → Variables**:

| Variable | Value | Masked | Protected |
|---|---|---|---|
| `VAULT_ADDR` | `http://vault.elnurbda.com:8200` | | ✓ |
| `VAULT_APPROLE_ROLE_ID` | `<role-id from above>` | | ✓ |
| `VAULT_APPROLE_SECRET_ID` | `<secret-id from above>` | ✓ | ✓ |

`VAULT_ADDR` is all the JWT pipeline (`app-vault-env`) needs — the role name is in the
job, and JWT stores no Vault credential. The `VAULT_APPROLE_*` pair is only for the SDK
app (it logs in with AppRole at runtime).

Infrastructure vars (`SSH_PRIVATE_KEY`, `PROD_HOST`, `PROD_USER`, `PROD_PORT`) stay in GitLab.
App secrets (`APP_USERNAME`, `APP_PASSWORD`, etc.) go into Vault.

### Secrets layout

```bash
# Per-app, per-environment
bao kv put secret/<app-name>/prod \
  APP_USERNAME=... \
  APP_PASSWORD=...
```

### Pipeline integration

Add to `.gitlab-ci.yml`:

```yaml
deploy:
  stage: deploy
  id_tokens:
    VAULT_ID_TOKEN:
      aud: "openbao"   # must match bound_audiences in the JWT role
  before_script:
    - apk add --no-cache curl jq   # the docker:24 runner image is minimal
    # Vault auth via JWT
    - |
      VAULT_TOKEN=$(curl -sf \
        --data "{\"jwt\":\"${VAULT_ID_TOKEN}\",\"role\":\"app-vault-env\"}" \
        ${VAULT_ADDR}/v1/auth/jwt/login | jq -r '.auth.client_token')
      if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then echo "ERROR: Vault auth failed"; exit 1; fi
      export VAULT_TOKEN
    # Read secrets
    - |
      SECRETS=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
        ${VAULT_ADDR}/v1/secret/data/<app-name>/prod)
      export APP_USERNAME=$(echo "$SECRETS" | jq -r '.data.data.APP_USERNAME')
      export APP_PASSWORD=$(echo "$SECRETS" | jq -r '.data.data.APP_PASSWORD')
```

---

## Vault Agent on prod

For apps that don't fetch secrets in CI, run Vault Agent as a systemd service on the prod host.
It authenticates via AppRole, fetches secrets, and renders them to a tmpfs file that the container reads at startup.

```
OpenBao (secman)
      │
      │  AppRole auth
      ▼
Vault Agent (prod, systemd)
      │
      ├── auto-renews token
      └── renders secrets → /run/vault-agent/app.env (tmpfs)
                    │
                    ▼
          docker run --env-file /run/vault-agent/app.env
```

### 1. Install OpenBao binary on prod

```bash
wget https://github.com/openbao/openbao/releases/download/v2.3.1/bao_2.3.1_linux_amd64.deb
dpkg -i bao_2.3.1_linux_amd64.deb
```

### 2. Generate a dedicated AppRole secret-id for prod

Generate one for the agent's own AppRole on secman (response-wrapped):

```bash
docker compose exec openbao bao write -f -wrap-ttl=120s auth/approle/role/app-vault-agent-env/secret-id
```

### 3. Write credentials to disk on prod

```bash
useradd --system --no-create-home --shell /usr/sbin/nologin vault-agent
mkdir -p /etc/vault-agent
echo "<role-id>"   > /etc/vault-agent/role-id
echo "<secret-id>" > /etc/vault-agent/secret-id   # agent deletes this after first read
chown -R vault-agent:vault-agent /etc/vault-agent
chmod 600 /etc/vault-agent/role-id /etc/vault-agent/secret-id
```

### 4. Agent config

`/etc/vault-agent/config.hcl`
```hcl
vault {
  address = "http://vault.elnurbda.com:8200"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault-agent/role-id"
      secret_id_file_path                 = "/etc/vault-agent/secret-id"
      remove_secret_id_file_after_reading = true   # read once, then delete (default)
    }
  }

  sink "file" {
    config = {
      path = "/run/vault-agent/token"
      mode = 0640
    }
  }
}

template {
  contents = <<EOT
{{ with secret "secret/data/app-vault-agent-env/prod" }}
APP_USERNAME={{ .Data.data.APP_USERNAME }}
APP_PASSWORD={{ .Data.data.APP_PASSWORD }}
{{ end }}
EOT
  destination = "/run/vault-agent/app.env"
  perms       = 0640   # not world-readable; the deploy user shares the group
}
```

### 5. tmpfs mount (secrets never hit disk)

Add to `/etc/fstab`:
```
tmpfs /run/vault-agent tmpfs rw,noexec,nosuid,size=10m 0 0
```
```bash
mount /run/vault-agent
# a bare tmpfs mounts root:root, so give the vault-agent user write access:
echo 'd /run/vault-agent 0750 vault-agent vault-agent' > /etc/tmpfiles.d/vault-agent.conf
systemd-tmpfiles --create
```

### 6. systemd unit

`/etc/systemd/system/vault-agent.service`
```ini
[Unit]
Description=Vault Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/bao agent -config=/etc/vault-agent/config.hcl
Restart=on-failure
RestartSec=5
# dedicated user, not root; add it to the docker group only if you wire up a restart hook
User=vault-agent

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now vault-agent
systemctl status vault-agent

# Verify secrets rendered
cat /run/vault-agent/app.env
```

> **Reboot caveat:** the token sink and the rendered `app.env` both live on tmpfs, and the
> `secret-id` is deleted after first read — so a reboot leaves the agent with nothing to
> authenticate with. Re-drop a fresh `secret-id` from provisioning on boot, or set
> `remove_secret_id_file_after_reading = false` and accept it staying on disk.

### 7. Pipeline — no Vault auth needed in CI

```yaml
deploy:
  stage: deploy
  before_script:
    - eval $(ssh-agent -s)
    - echo "$SSH_PRIVATE_KEY" | base64 -d | ssh-add -
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - ssh-keyscan -H $PROD_HOST >> ~/.ssh/known_hosts
  script:
    - scp -P ${PROD_PORT:-22} -r Dockerfile server.js package.json $PROD_USER@$PROD_HOST:~/app-vault-agent-env
    - |
      ssh -p ${PROD_PORT:-22} $PROD_USER@$PROD_HOST bash << 'EOF'
      set -e
      cd ~/app-vault-agent-env
      docker build -t app-vault-agent-env:latest .
      docker rm -f app-vault-agent-env 2>/dev/null || true
      docker run -d \
        --name app-vault-agent-env \
        --restart unless-stopped \
        -p 83:83 \
        --env-file /run/vault-agent/app.env \
        app-vault-agent-env:latest
      docker image prune -f
      docker ps --filter name=app-vault-agent-env
      EOF
```

### Troubleshooting

```bash
# Check agent logs
journalctl -u vault-agent -f

# Common issues:
# "no known secret ID"     → /etc/vault-agent/secret-id missing or empty
# "no such host"           → /etc/hosts missing vault.elnurbda.com entry,
#                            check nsswitch.conf has 'files' before 'dns'
# "permission denied"      → app.env perms not 0640, or the deploy user isn't in the vault-agent group
```

---

## App-side Vault integration (direct SDK)

The app authenticates to Vault on every request and fetches secrets live.
No Vault Agent, no env files — AppRole credentials are injected by CI at `docker run`.

```
GitLab CI
  │  injects VAULT_ROLE_ID + VAULT_SECRET_ID as docker env vars
  ▼
App container (prod)
  │  on every HTTP request:
  │    1. POST /v1/auth/approle/login  → client_token
  │    2. GET  /v1/secret/data/<app>/prod → secrets
  ▼
OpenBao (secman)
```

### Seed the secret

```bash
docker compose exec openbao bao kv put secret/app-vault-direct-env/prod \
  APP_USERNAME=admin-sdk \
  APP_PASSWORD=supersecret
```

### GitLab CI variables

| Variable | Masked | Protected |
|---|---|---|
| `SSH_PRIVATE_KEY` | ✓ | ✓ |
| `PROD_HOST` | | ✓ |
| `PROD_USER` | | ✓ |
| `PROD_PORT` | | |
| `VAULT_APPROLE_ROLE_ID` | ✓ | ✓ |
| `VAULT_APPROLE_SECRET_ID` | ✓ | ✓ |

### Pipeline

`app-vault-direct-env/.gitlab-ci.yml`
```yaml
deploy:
  stage: deploy
  before_script:
    - eval $(ssh-agent -s)
    - echo "$SSH_PRIVATE_KEY" | base64 -d | ssh-add -
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - ssh-keyscan -H $PROD_HOST >> ~/.ssh/known_hosts
  script:
    - scp -P ${PROD_PORT:-22} -r Dockerfile server.js package.json $PROD_USER@$PROD_HOST:~/app-vault-direct-env
    - |
      ssh -p ${PROD_PORT:-22} $PROD_USER@$PROD_HOST bash << EOF
      set -e
      cd ~/app-vault-direct-env
      docker build -t app-vault-direct-env:latest .
      docker rm -f app-vault-direct-env 2>/dev/null || true
      docker run -d \
        --name app-vault-direct-env \
        --restart unless-stopped \
        -p 84:84 \
        --add-host vault.elnurbda.com:10.10.1.8 \
        -e VAULT_ADDR=http://vault.elnurbda.com:8200 \
        -e VAULT_ROLE_ID=${VAULT_APPROLE_ROLE_ID} \
        -e VAULT_SECRET_ID=${VAULT_APPROLE_SECRET_ID} \
        -e VAULT_SECRET_PATH=secret/data/app-vault-direct-env/prod \
        app-vault-direct-env:latest
      docker image prune -f
      docker ps --filter name=app-vault-direct-env
      EOF
```

> **Note:** heredoc uses `<< EOF` (unquoted) so the runner shell expands
> `${VAULT_APPROLE_ROLE_ID}` and `${VAULT_APPROLE_SECRET_ID}` before sending
> over SSH. Using `<< 'EOF'` would pass them as literal strings and the
> container would fail to start with "VAULT_ROLE_ID and VAULT_SECRET_ID are required".

> **Note:** `--add-host vault.elnurbda.com:10.10.1.8` is required because
> Docker containers don't inherit the host's `/etc/hosts`.

> **Note:** the `secret_id` is passed via `docker run -e`, so it shows up in
> `docker inspect` — that's the one credential at rest in this pattern. Bound its TTL and
> rotate it, or hand the container a response-wrapped secret-id it unwraps at boot. The app
> caches the token and secret until the lease nearly expires, so it's not a Vault
> round-trip on every request.

### Troubleshooting

```bash
# Check container logs
docker logs app-vault-direct-env

# Common issues:
# "VAULT_ROLE_ID and VAULT_SECRET_ID are required" → heredoc is quoted (<< 'EOF'),
#                                                     variables not expanded by runner
# "fetch failed"  → container can't reach Vault, add --add-host to docker run
# "403 Forbidden" → wrong role-id/secret-id, or secret path doesn't exist in Vault
```
