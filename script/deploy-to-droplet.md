# Deploy custom image to campfire-1

Prerequisites: `once auto-update off`, volume `campfire-data`, secrets from `~/.config/once/config.json`.

```bash
# On your machine after GHCR publish
IMAGE=ghcr.io/getbacklit/campfire:backlit-integration

# On campfire-1 as root
docker pull "$IMAGE"

# Capture current run flags (do not print secrets to chat logs)
docker inspect campfire --format '{{json .Config.Env}}' > /root/campfire-env.json
docker inspect campfire --format '{{range .Mounts}}{{.Name}} {{.Destination}}{{end}}'

once stop
# or: docker stop campfire && docker rm campfire

docker run -d --name campfire --restart unless-stopped \
  --publish 80:80 --publish 443:443 \
  --volume campfire-data:/rails/storage \
  --env-file /root/campfire.env \
  "$IMAGE"

# /root/campfire.env should include existing SECRET_KEY_BASE, VAPID_*, TLS_DOMAIN,
# plus OIDC_* and BACKLIT_PROVISIONING_TOKEN when ready.
```

Cutover (archive existing rooms) happens after SSO + archive UI land, not on first custom-image boot.
