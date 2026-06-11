```bash
# Build
docker build -t env-debug .

# Run with .env file
docker run --env-file .env -p 80:80 env-debug

# Or inline
docker run -e USERNAME=admin -e PASSWORD=secret -p 80:80 env-debug
```

Variables
| Variable | Example | Masked |
|---|---|---|
| `SSH_PRIVATE_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----...` | ✅ |
| `PROD_HOST` | `10.10.1.7` | |
| `PROD_USER` | `elnur` | |
| `PROD_PORT` | `22` | |
| `VAULT_ADDR` | `http://vault.elnurbda.com:8200` | | ✓ |
| `VAULT_ROLE` | `gitlab-ci` | | |
| `VAULT_APPROLE_ROLE_ID` | `e3163580-30dd-c1d4-e019-9d0dfae4ff6c` | | ✓ |
| `VAULT_APPROLE_SECRET_ID` | `69827ac3-0018-497c-a924-f6425962c4e4` | ✓ | ✓ |

