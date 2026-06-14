```bash
# Build
docker build -t env-debug .

# Run with .env file
docker run --env-file .env -p 80:80 env-debug

# Or inline
docker run -e APP_USERNAME=admin -e APP_PASSWORD=secret -p 80:80 env-debug
```

Variables
| Variable | Example | Masked |
|---|---|---|
| `SSH_PRIVATE_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----...` | ✅ |
| `PROD_HOST` | `10.10.1.7` | |
| `PROD_USER` | `elnur` | |
| `PROD_PORT` | `22` | |
| `VAULT_ADDR` | `http://vault.elnurbda.com:8200` | |

The JWT role (`app-vault-env`) is named in the pipeline, and the JWT login stores no Vault
credential — so this scenario needs no role-id / secret-id CI variables.

