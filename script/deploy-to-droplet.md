# Deploy custom image to campfire-1

## Automatic (preferred)

Merges to `main` build `ghcr.io/getbacklit/campfire:main` and then SSH to the droplet to pull and restart the container. That happens in `.github/workflows/publish-image.yml` (`deploy` job).

One-time GitHub Actions secrets on `getbacklit/campfire`:

| Secret | Purpose |
| --- | --- |
| `CAMPFIRE_DEPLOY_HOST` | Droplet IP or hostname (`164.92.95.83`) |
| `CAMPFIRE_DEPLOY_USER` | SSH user (`root`) |
| `CAMPFIRE_DEPLOY_SSH_KEY` | Full private key PEM with access to that host |
| `CAMPFIRE_DEPLOY_SSH_KEY_PASSPHRASE` | Passphrase for that private key, if it has one |
| `CAMPFIRE_GHCR_USERNAME` | GitHub user or org that can read the package |
| `CAMPFIRE_GHCR_READ_TOKEN` | PAT / fine-grained token with `read:packages` |

Prefer a dedicated Actions deploy key with no passphrase when you can. If you reuse a personal key that is passphrase-protected, set `CAMPFIRE_DEPLOY_SSH_KEY_PASSPHRASE`.

The deploy reuses `/root/campfire.env` and the `campfire-data` volume. Do not put app secrets in GitHub Actions; leave them on the droplet.

Prerequisites on the host: `once auto-update` off, volume `campfire-data`, env file `/root/campfire.env`.

## Manual fallback

```bash
# On campfire-1 as root, after GHCR publish
IMAGE=ghcr.io/getbacklit/campfire:main
docker pull "$IMAGE"

docker stop campfire && docker rm campfire

docker run -d --name campfire --restart unless-stopped \
  --publish 80:80 --publish 443:443 \
  --volume campfire-data:/rails/storage \
  --env-file /root/campfire.env \
  "$IMAGE"
```

`/root/campfire.env` should include existing `SECRET_KEY_BASE`, `VAPID_*`, `TLS_DOMAIN`, plus `OIDC_*` and `BACKLIT_PROVISIONING_TOKEN`.
