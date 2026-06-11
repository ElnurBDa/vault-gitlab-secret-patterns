# app-vault-sdk-env

App fetches secrets directly from OpenBao/Vault on every request using AppRole auth.
No env files, no Vault Agent — credentials injected at `docker run` by CI.

## Run locally

```bash
docker build -t app-vault-sdk-env .

docker run -p 84:83 \
  -e VAULT_ADDR=http://vault.elnurbda.com:8200 \
  -e VAULT_ROLE_ID=<role-id> \
  -e VAULT_SECRET_ID=<secret-id> \
  -e VAULT_SECRET_PATH=secret/data/app-vault-sdk-env/prod \
  app-vault-sdk-env
```

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `VAULT_ROLE_ID` | ✅ | — | AppRole role ID |
| `VAULT_SECRET_ID` | ✅ | — | AppRole secret ID |
| `VAULT_ADDR` | | `http://vault.elnurbda.com:8200` | Vault address |
| `VAULT_SECRET_PATH` | | `secret/data/app-vault-sdk-env/prod` | KV v2 path |

## CI variables (GitLab)

| Variable | Masked | Protected |
|---|---|---|
| `SSH_PRIVATE_KEY` | ✅ | ✅ |
| `PROD_HOST` | 10.10.1.7 | |
| `PROD_USER` | elnur | |
| `PROD_PORT` | | |
| `VAULT_APPROLE_ROLE_ID` | | ✅ |
| `VAULT_APPROLE_SECRET_ID` | ✅ | ✅ |

## Seed secret in Vault

```bash
docker compose exec openbao bao kv put secret/app-vault-sdk-env/prod \
  APP_USERNAME=admin-sdk \
  APP_PASSWORD=supersecret
```
