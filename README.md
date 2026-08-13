# opslab-platform

The only repository that knows the server exists. It holds the gateway image,
the compose stack, the database schema, the egress proxy, and the digest pins.

## Files

```
images.env                  what is deployed. Rewritten by CI, committed to git.
deploy/docker-compose.yml   seven containers, five networks
deploy/gateway.nginx.conf   path routing
db/init/                    schema, applied on first start only
proxy/                      tinyproxy and the one-line allowlist
landing/                    the index page
```

## Deploying

Automatic: any app repo publishing an image dispatches `app-image-updated` here.
This repo verifies the cosign signature, rewrites the digest in `images.env`,
commits it, and deploys via a self-hosted runner on the server.

Manual:

```bash
cd /opt/opslab && git pull --ff-only
set -a; . ./images.env; set +a
docker compose -f deploy/docker-compose.yml up -d
```

`images.env` is authoritative. Editing it on the server does nothing lasting —
the next deploy pulls over it. Change the pin here, in git.

## First run

```bash
mkdir -p secrets
head -c 32 /dev/urandom | base64 | tr -d '\n=+/' > secrets/db_password
chmod 600 secrets/db_password
```

The stack binds `127.0.0.1:8088`. Reach it with
`ssh -L 8088:127.0.0.1:8088 you@server`, or put Caddy in front for real TLS.
