# Setup

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
      - VAULT_DISABLE_MLOCK=true
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

Run after init and unseal:

```bash
# Enable JWT auth
docker compose exec openbao bao auth enable jwt

# Configure GitLab as OIDC provider
# jwks_url confirmed at: https://gitlab.elnurbda.com/oauth/discovery/keys
# jwks_ca_pem required because GitLab uses a self-signed cert
docker compose exec openbao bao write auth/jwt/config \
  jwks_url="https://gitlab.elnurbda.com/oauth/discovery/keys" \
  bound_issuer="https://gitlab.elnurbda.com" \
  jwks_ca_pem=@/openbao/config/gitlab.pem

# Policy
cat > /tmp/ci-read.hcl << 'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
EOF
docker compose exec -T openbao bao policy write ci-read - < /tmp/ci-read.hcl

# JWT role (bound_audiences maps to the aud claim GitLab sets in CI JWTs)
docker compose exec openbao bao write auth/jwt/role/gitlab-ci \
  role_type="jwt" \
  policies="ci-read" \
  token_ttl="1h" \
  token_max_ttl="2h" \
  bound_audiences="https://gitlab.elnurbda.com" \
  bound_claims_type="glob" \
  bound_claims.project_path="*" \
  user_claim="sub"

# Enable AppRole (fallback)
docker compose exec openbao bao auth enable approle

docker compose exec openbao bao write auth/approle/role/gitlab-ci \
  policies="ci-read" \
  token_ttl="1h" \
  token_max_ttl="2h" \
  secret_id_ttl="0"

# Enable KV v2
docker compose exec openbao bao secrets enable -path=secret kv-v2

# Get AppRole credentials (store in GitLab CI variables)
docker compose exec openbao bao read auth/approle/role/gitlab-ci/role-id
docker compose exec openbao bao write -f auth/approle/role/gitlab-ci/secret-id
```

### GitLab CI variables

Set in **Settings → CI/CD → Variables**:

| Variable | Value | Masked | Protected |
|---|---|---|---|
| `VAULT_ADDR` | `http://vault.elnurbda.com:8200` | | ✓ |
| `VAULT_ROLE` | `gitlab-ci` | | |
| `VAULT_APPROLE_ROLE_ID` | `<role-id from above>` | | ✓ |
| `VAULT_APPROLE_SECRET_ID` | `<secret-id from above>` | ✓ | ✓ |

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
      aud: "https://gitlab.elnurbda.com"   # must match bound_audiences in JWT role
  before_script:
    # Vault auth: JWT primary, AppRole fallback
    - |
      echo "==> Attempting JWT auth..."
      VAULT_TOKEN=$(curl -sf \
        --data "{\"jwt\":\"${VAULT_ID_TOKEN}\",\"role\":\"gitlab-ci\"}" \
        ${VAULT_ADDR}/v1/auth/jwt/login \
        | grep -o '"client_token":"[^"]*"' | cut -d'"' -f4) || true

      if [ -z "$VAULT_TOKEN" ]; then
        echo "==> JWT failed, falling back to AppRole..."
        VAULT_TOKEN=$(curl -sf \
          --data "{\"role_id\":\"${VAULT_APPROLE_ROLE_ID}\",\"secret_id\":\"${VAULT_APPROLE_SECRET_ID}\"}" \
          ${VAULT_ADDR}/v1/auth/approle/login \
          | grep -o '"client_token":"[^"]*"' | cut -d'"' -f4)
      fi

      [ -z "$VAULT_TOKEN" ] && echo "ERROR: Vault auth failed" && exit 1
      export VAULT_TOKEN
      echo "==> Vault auth OK"

    # Read secrets
    - |
      SECRETS=$(curl -sf \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        ${VAULT_ADDR}/v1/secret/data/<app-name>/prod)
      export APP_USERNAME=$(echo $SECRETS | grep -o '"APP_USERNAME":"[^"]*"' | cut -d'"' -f4)
      export APP_PASSWORD=$(echo $SECRETS | grep -o '"APP_PASSWORD":"[^"]*"' | cut -d'"' -f4)
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

Don't reuse the CI secret-id. Generate a separate one on secman:

```bash
docker compose exec openbao bao write -f auth/approle/role/gitlab-ci/secret-id
```

### 3. Write credentials to disk on prod

```bash
mkdir -p /etc/vault-agent
echo "<role-id>"   > /etc/vault-agent/role-id
echo "<secret-id>" > /etc/vault-agent/secret-id
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
      remove_secret_id_file_after_reading = false
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
{{ with secret "secret/data/<app-name>/prod" }}
USERNAME={{ .Data.data.APP_USERNAME }}
PASSWORD={{ .Data.data.APP_PASSWORD }}
{{ end }}
EOT
  destination = "/run/vault-agent/app.env"
  perms       = 0644   # world-readable so docker can read it
}
```

### 5. tmpfs mount (secrets never hit disk)

Add to `/etc/fstab`:
```
tmpfs /run/vault-agent tmpfs rw,noexec,nosuid,size=10m 0 0
```
```bash
mount /run/vault-agent
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
User=root

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
# "permission denied"      → app.env perms not 0644, check template perms in config.hcl
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
