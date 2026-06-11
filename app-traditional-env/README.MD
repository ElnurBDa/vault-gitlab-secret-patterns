```bash
# Build
docker build -t env-debug .

# Run with .env file
docker run --env-file .env -p 80:80 env-debug

# Or inline
docker run -e USERNAME=admin -e PASSWORD=secret -p 80:80 env-debug
```

`.env`
```env
USERNAME=admin
PASSWORD=secret123
```

Variables
| Variable | Example | Masked |
|---|---|---|
| `SSH_PRIVATE_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----...` | ✅ |
| `PROD_HOST` | `10.10.1.7` | |
| `PROD_USER` | `elnur` | |
| `PROD_PORT` | `22` | |
| `APP_USERNAME` | `admin` | ✅ |
| `APP_PASSWORD` | `secret123` | ✅ |

