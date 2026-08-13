# opslab — how the whole thing works

Seven repositories, seven containers, five networks. This document explains every
edge in the system: what talks to what, why, and what breaks if you remove it.

Read it once end to end. Then use the "Things to break on purpose" section at the
bottom, because you will not really understand a boundary until you have watched
it fail.

---

## 1. The seven repositories

| Repository | Produces | Knows about |
|---|---|---|
| `opslab-shared` | nothing — actions and assets only | nothing |
| `opslab-base` | `ghcr.io/OWNER/opslab-base` | opslab-shared, and the 3 app repos it notifies |
| `opslab-fleet-shell` | `ghcr.io/OWNER/opslab-fleet-shell` | opslab-shared, opslab-platform |
| `opslab-dispatch-lab` | `ghcr.io/OWNER/opslab-dispatch-lab` | same |
| `opslab-triage-bench` | `ghcr.io/OWNER/opslab-triage-bench` | same |
| `opslab-api` | `ghcr.io/OWNER/opslab-api` | opslab-shared, opslab-platform |
| `opslab-platform` | `ghcr.io/OWNER/opslab-platform` (gateway) + the compose stack | everything, and the server |

The important asymmetry: **`opslab-shared` knows about nobody, `opslab-platform`
knows about everybody.** Dependencies point in one direction. Nothing in the
middle needs to know where it gets deployed, and nothing at the edges needs to
know how images get built.

### Why an app repo is only four files

`opslab-fleet-shell` contains `site/index.html`, `site/app.css`, `site/app.js`,
and a four-line Dockerfile. It has no nginx config, no fonts, no colour
definitions, no build steps, and no scan policy.

All of that is inherited: the design system and nginx config come down through
`FROM opslab-base`, and the build and scan steps come in through
`uses: OWNER/opslab-shared/.github/workflows/app-pipeline.yml@v1`.

That means a change to the scan severity is one edit in one file, and all four
image repos pick it up on their next build. That property is the whole reason to
split the repos. A monorepo gives you the same result more easily; the split
gives you practice at making a change propagate across boundaries you do not
control, which is the harder and more valuable skill.

---

## 2. How a change travels — the CI graph

```
  you edit a colour in opslab-shared/assets/tokens.css
            │
            │  git tag -f v1 && git push -f origin v1
            ▼
  ┌─────────────────────┐
  │   opslab-shared     │   composite actions + design tokens + fonts
  └──────────┬──────────┘   (no images, nothing runs)
             │
             │  A. consumed at build time by:  actions/checkout ref: v1
             │  B. consumed as workflow logic: uses: ...@v1
             ▼
  ┌─────────────────────┐
  │    opslab-base      │  FROM nginx-unprivileged
  │                     │  + shared/ assets, + nginx.conf, + headers
  └──────────┬──────────┘  push → ghcr.io/OWNER/opslab-base
             │
             │  needs: build-and-push          ◄── the ordering rule
             │  repository_dispatch(base-image-updated, digest)
             │
      ┌──────┼──────┬───────────────┐
      ▼      ▼      ▼               │
 ┌─────────┐ ┌──────────┐ ┌────────────────┐      ┌────────────┐
 │  fleet  │ │ dispatch │ │  triage-bench  │      │ opslab-api │
 │  shell  │ │   lab    │ │                │      │            │
 └────┬────┘ └────┬─────┘ └───────┬────────┘      └─────┬──────┘
      │           │               │                     │
      │  each: FROM opslab-base@<that exact digest>      │
      │        build → scan → cosign sign → push GHCR    │
      │           │               │                     │
      │  needs: build             │                     │
      │  repository_dispatch(app-image-updated, digest)  │
      └───────────┴───────┬───────┴─────────────────────-┘
                          ▼
              ┌──────────────────────┐
              │   opslab-platform    │
              │  1. cosign verify    │  reject anything unsigned
              │  2. pin digest in    │  images.env, committed to git
              │     images.env       │
              │  3. deploy to server │  self-hosted runner, health-gated
              └──────────────────────┘
```

### The three edges worth understanding

**`needs:` before every dispatch.** In `opslab-base`, the `fan-out` job declares
`needs: build-and-push`. Remove it and both jobs start at once — the dispatch
fires while the push is still uploading layers, the three app repos wake up and
pull `opslab-base`, and the registry serves them the *previous* image. They build
successfully, they pass every scan, and they are wrong. Nothing fails. This is
the single most valuable bug in the whole system and it is exactly what Dispatch
Lab simulates.

**A GitHub App, not a PAT.** `GITHUB_TOKEN` is scoped to the repository that
generated it, so it physically cannot dispatch to another repo. The options are a
personal access token or a GitHub App. The App wins because it mints a
short-lived installation token per run — there is no expiry date for you to miss
at 3am, and it carries an app identity rather than your personal one. If you ever
leave the account, nothing silently stops working.

**Digest, never tag.** When `opslab-base` dispatches, it sends the sha256 digest
in the payload, and the app build uses `FROM opslab-base@sha256:...`. A tag is a
pointer that can move between the moment CI reads it and the moment the build
pulls it. A digest is the content. `images.env` in `opslab-platform` is committed
to git, so the answer to "what is running in production" is a file in a
repository rather than an SSH session.

---

## 3. How the running system talks — the runtime graph

```
   your laptop
       │  ssh -L 8088:127.0.0.1:8088
       ▼
   ┌────────────────────────────────────────────── the server ──┐
   │  127.0.0.1:8088                                            │
   │       │                                                    │
   │  ┌────▼─────┐   network: edge + app                        │
   │  │ gateway  │   serves the landing page                    │
   │  └────┬─────┘   routes by path prefix                      │
   │       │                                                    │
   │       ├── /fleet-shell/   ──►  fleet-shell:8080   ┐        │
   │       ├── /dispatch-lab/  ──►  dispatch-lab:8080  │ app    │
   │       ├── /triage-bench/  ──►  triage-bench:8080  │ net    │
   │       └── /api/           ──►  api:8000           ┘        │
   │                                 │                          │
   │                                 ├── data net ──► db:5432   │
   │                                 │                (internal)│
   │                                 └── egress net ─► proxy    │
   │                                                     │      │
   └─────────────────────────────────────────────────────┼──────┘
                                                         ▼ wan
                                              cveawg.mitre.org  (allowlist: 1 host)
```

### Network segmentation, and why it is topology rather than policy

Five networks. Three of them are `internal: true`, which means Docker attaches no
gateway — packets have nowhere to go.

- **`edge`** — only the gateway. The only port bound on the host, and bound to
  `127.0.0.1`, so nothing is reachable from the network until you deliberately
  put something in front of it.
- **`app`** — gateway plus the four services. The three sandbox containers can
  reach each other here, which they never do; you could tighten this further with
  per-service networks if you want the exercise.
- **`data`** — `api` and `db` only. **The database has no route to the internet
  and no route to the gateway.** There is no firewall rule to misconfigure,
  because there is no path.
- **`egress`** — `api` and `proxy` only. The API cannot reach the internet
  directly either.
- **`wan`** — the proxy alone. It is the single container in the system with a
  default route.

So the full egress story is: **`api` → `proxy` → one allowlisted hostname.**
Everything else is unreachable by construction.

### The path-prefix trick

Each app container thinks it lives at `/`. The gateway does:

```nginx
location /fleet-shell/ { proxy_pass http://fleet-shell:8080/; }
```

The **trailing slash on `proxy_pass`** strips the prefix. A request for
`/fleet-shell/shared/tokens.css` arrives at the app container as
`/shared/tokens.css`. Drop that slash and the app receives
`/fleet-shell/shared/tokens.css`, finds nothing, and returns 404 for every asset
while the HTML itself loads fine. That failure mode — page renders unstyled,
no server errors — is worth causing once so you recognise it instantly later.

### Where credentials live

The database password is a **file**, mounted at `/run/secrets/db_password`.
Postgres reads `POSTGRES_PASSWORD_FILE`; the API reads `DB_PASSWORD_FILE` and
falls back to an env var only for local development.

The reason: environment variables appear in `docker inspect`, in `/proc/<pid>/environ`,
in crash dumps, and in any log line that dumps config. A file appears in none of
those. It is the same secret either way — the difference is entirely in how many
places it leaks from.

### Why every container is read-only

`read_only: true`, `cap_drop: ALL`, `no-new-privileges`, and a memory limit on
all seven. nginx needs three writable paths, so those are tmpfs mounts sized in
megabytes. If an attacker gets code execution in one of these containers they
cannot write a binary to disk, cannot escalate through a setuid file, and cannot
persist across a restart.

`db` is the one exception. Postgres's entrypoint starts as root to fix ownership
on the data directory and then drops privileges itself, so it needs five
capabilities back: `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID`. Know
this before you try to lock it down, or you will spend an evening on a container
that will not boot.

---

## 4. Where state lives

| State | Where | Survives |
|---|---|---|
| Sandbox run history | postgres, `runs` table | `pgdata` volume — survives restarts and redeploys |
| CVE lookups | postgres, `cve_cache` | same |
| Which images are deployed | `images.env` in git | everything; it is the source of truth |
| Database password | `secrets/db_password` on the server | never in git, never in an image |
| Build provenance | image labels + cosign signature in GHCR | permanent |

Note what is *not* here: nothing important lives in a container filesystem. You
can `docker compose down` and delete every image, and the only thing you lose is
the time it takes to pull them again.

---

## 5. Bringing it up the first time

Order matters, because nothing can build until the base image exists.

1. `./bootstrap.sh YOUR-USERNAME` — creates and pushes all seven repos
2. Create the GitHub App, install it on all seven, set `OPSLAB_APP_ID` and
   `OPSLAB_APP_KEY` in each
3. `gh workflow run build.yml --repo YOUR-USERNAME/opslab-base`
4. Wait. When it finishes, the three app repos fire automatically
5. `gh workflow run build.yml --repo YOUR-USERNAME/opslab-api`
6. On the server: clone `opslab-platform` to `/opt/opslab`, generate
   `secrets/db_password`, `docker compose up -d`
7. Register a self-hosted runner on `opslab-platform` with the label `opslab` so
   future deploys are automatic

If step 3 fails on `opslab-shared@v1` not existing, the bootstrap script did not
finish tagging. Re-run: `cd opslab-shared && git tag -f v1 && git push -f origin v1`.

---

## 6. Things to break on purpose

Each of these teaches something a document cannot. Do them in a scratch branch.

**Remove `needs: build-and-push` from `opslab-base`'s fan-out job.** Push a
change to `tokens.css`, tag it, rebuild the base. Watch the app builds succeed
while shipping the old base layer. Then check the image labels to prove it.

**Delete the line in `proxy/filter`, restart the proxy.** Call
`/api/cve/CVE-2024-3094` on a CVE you have not looked up before. Watch where the
error surfaces — the API returns 502 with the proxy's refusal, not a timeout,
because the proxy answers immediately. Compare that to what happens if you
instead take the `proxy` container off the `wan` network: now you get a hang.
Two very different failure signatures for the same intent.

**Drop the trailing slash from one `proxy_pass` in the gateway.** Reload. The
page loads, every asset 404s, and no error log tells you why.

**Take `cap_add` off the `db` service.** Watch it fail to start, read the actual
error, then put it back. Now you know the difference between "hardened" and
"broken" for that image specifically.

**Change `images.env` by hand on the server, then trigger a deploy.** Watch your
change get overwritten by `git pull --ff-only`. The repo wins. That is the
intended behaviour and it is why nobody needs to ask what is running.

**Point an app repo's `FROM` at `:latest` instead of the dispatched digest.**
Rebuild the base twice quickly. Observe that you can no longer say with certainty
which base any given app image was built on.

---

## 7. What this is missing, deliberately

No TLS — put Caddy in front when you want it, and the gateway keeps its current
config unchanged. No authentication — every sandbox is read-only and the API
stores nothing sensitive. No log aggregation — add a gelf driver and a collector
container when you want to practice that. No backups of `pgdata` — worth adding
as an exercise, since a `pg_dump` sidecar on a timer is a good small project.

Each of those is a reasonable next thing to build. None of them is required for
the system to be correct as it stands.
