# Coolify Deployment

This deployment runs the real `opensymphony run` entrypoint on a single Ubuntu
24.04 VPS. GitHub Actions builds OpenSymphony and the existing alpha web client
as separate GHCR images; Coolify pulls the images selected by the deployed Git
commit. The runtime uses the official Codex CLI as the default local harness
and exposes only an authenticated Caddy edge to Coolify's Traefik proxy.

The alpha browser client is an operator preview, not a complete production
control plane. Keep the deployment private, back up its volumes, and retain a
terminal/SSH operations path.

## Architecture and security boundary

```text
Internet
  -> Coolify Traefik (DNS, HTTPS certificate, TLS termination)
  -> web:8080 (Caddy Basic Auth, static /app/*, proxy /api/*)
  -> opensymphony:2468 (private Compose network only)
       -> Rust scheduler and gateway
       -> Codex app-server over local stdio
       -> Linear GraphQL and GitHub/Git over outbound HTTPS or SSH
       -> per-issue workspaces in /workspaces
```

The `opensymphony` service has no published host port. Do not add a Coolify
domain to it. The gateway currently has read and mutation endpoints without a
general HTTP authentication layer, so exposing port 2468 directly would expose
an administrative surface. The `web` service protects `/app/*` and `/api/*`
with HTTPS plus Basic Auth. Only the minimal `/healthz` response is
unauthenticated. Caddy forwards same-origin SSE and WebSocket upgrades, so the
browser does not require CORS or a separate public gateway URL.

The containers do not mount the Docker socket, do not use privileged mode, drop
Linux capabilities, and enable `no-new-privileges`. Codex nevertheless runs
with OpenSymphony's trusted local full-automation profile inside the container
and can read injected credentials and mounted workspaces. Treat this as a
single-operator trusted deployment, not tenant isolation.

The pinned upstream Caddy image gives `/usr/bin/caddy` the
`cap_net_bind_service` file capability so it can bind ports below 1024. The
OpenSymphony web image removes that capability during its build and verifies
that no file capability remains. Caddy listens on unprivileged port `8080`, so
the capability is unnecessary; removing it lets the service retain
`cap_drop: ALL`, `no-new-privileges:true`, and its read-only root filesystem.

Runtime limits reserve at most 2 vCPU and 3 GiB for the orchestrator plus its
Codex child and 0.25 vCPU/128 MiB for Caddy. Bundled DuckDB and the web client
are compiled on GitHub-hosted runners, not on the deployment VPS. The workflow
uses Buildx caches and publishes only full commit-SHA tags.

## Files and persistent volumes

The Compose file declares these named volumes. Coolify owns their concrete
Docker names and shows them as read-only definitions under Persistent Storage.

| Volume | Container path | Purpose |
|---|---|---|
| `opensymphony_config` | `/config` | `config.yaml`, `WORKFLOW.md`, and operator-managed CA files |
| `opensymphony_data` | `/config/.opensymphony` | OpenSymphony repository-local state and future memory data |
| `opensymphony_workspaces` | `/workspaces` | issue checkouts, manifests, logs, and resumable task state |
| `codex_auth` | `/home/opensymphony/.codex` | Codex config, ChatGPT OAuth cache, threads, and login diagnostics |
| `git_config` | `/home/opensymphony/.config` | GitHub CLI and Git helper configuration |
| `ssh_auth` | `/home/opensymphony/.ssh` | SSH keys, config, and known hosts |

The image seeds `/config/config.yaml`, `/config/WORKFLOW.md`, and the Codex
configuration on the first creation of empty named volumes. A later image
upgrade does not overwrite the persistent copies. Back up all six volumes;
persistent storage is not itself a backup.

The seed workflow uses the existing legacy single-repository mode because it
is the smallest supported deployment path. It binds the gateway to
`0.0.0.0:2468` inside the private network, polls one Linear project, clones the
configured target into one workspace per task, selects `codex_app_server`, and
limits scheduling to one active agent. Memory auto-capture is disabled in the
generic seed because `/config` is configuration rather than a checked-out
target repository. Initialize and enable memory only after choosing a durable
repository-specific memory policy.

## 1. Prepare DNS and the VPS

1. Point an `A`/`AAAA` record such as `symphony.example.com` at the Coolify VPS.
2. Confirm inbound TCP 80 and 443 reach Coolify's Traefik proxy.
3. Confirm the VPS has enough free disk for the pulled images, Git workspaces,
   and volume backups. Active repositories may need substantially more space
   than the images themselves.
4. Do not open ports 2468 or 8080 in the VPS firewall. Traefik reaches the
   Compose service on its internal network.

## 2. Create the Coolify resource

Use a Git-based Docker Compose Application, not Docker Compose Empty, so the
deployment follows this fork and branch:

1. In the target Coolify project/environment, select **+ New** and choose the
   Git repository source for `DmitriyLitv/OpenSymphony` (or the connected fork
   URL shown by Coolify).
2. Select the current deployment branch.
3. Under **General -> Build pipeline**, choose **Compose** as the build
   strategy.
4. Set **Base Directory** to `/` and **Docker Compose Location** to
   `/docker-compose.yml`.
5. Save/reload the Compose definition. Confirm Coolify detects services
   `opensymphony` and `web`, six volumes, and both Compose health checks.
6. Keep the existing repository and branch selection. The Compose image tags
   resolve from Coolify's predefined `SOURCE_COMMIT`, so no Coolify build pack
   or Docker build arguments are required.

Coolify's Compose documentation notes that Git-backed Compose Applications use
the repository definition, Compose-owned volumes, and Compose health checks.
Edit this file in Git and redeploy rather than editing only the rendered copy in
Coolify.

### GHCR images and package access

The `container-images` GitHub Actions workflow publishes these exact image
repositories:

- `ghcr.io/dmitriylitv/opensymphony:<full-git-sha>`
- `ghcr.io/dmitriylitv/opensymphony-web:<full-git-sha>`

Both images use the same 40-character source commit tag. The workflow has only
`contents: read` and `packages: write` permissions, authenticates with its
ephemeral repository `GITHUB_TOKEN`, and never needs a stored publishing token.
Buildx cache scopes are separate for the `opensymphony` and `web` targets. A
same-commit concurrency group cancels overlapping runs, and each matrix job
skips a tag that is already present in GHCR.

New GHCR packages are private by default. After the first successful workflow
run, either keep both packages private or explicitly change both package
visibilities under the GitHub account's **Packages -> Package settings**. A
public GHCR image can be pulled anonymously; GitHub warns that changing a
package to public cannot be undone.

For private packages, authenticate the Coolify deployment server under
**Servers -> [server] -> Registries** (or the global **Registries** page) with:

- registry: `ghcr.io`;
- username: the GitHub account that can read both packages;
- password: a GitHub personal access token (classic) with `read:packages`.

Store that token only in Coolify's registry login or the deployment server's
Docker credential store. Never add it to Compose, `.env`, GitHub source files,
or Git history. Authenticate every deployment server that may pull the images.
No registry login is required after both packages are public.

GitHub Actions and Coolify may react to the same push concurrently. Wait for
both `container-images` matrix jobs for the deployed commit to succeed before
clicking **Redeploy**. An earlier automatic attempt can report a missing image
until the immutable tag has been published; retrying afterward uses the same
repository, branch, and commit without a local build.

## 3. Configure environment variables

Copy the keys from `.env.example` into Coolify **Environment Variables**.
Compose marks the first six values below as required, so Coolify will refuse an
empty deployment.

| Variable | Required | Meaning |
|---|---:|---|
| `LINEAR_API_KEY` | yes | Linear personal/OAuth token used by the scheduler |
| `LINEAR_PROJECT_SLUG` | yes | Linear project's `slugId`, not `team/project` |
| `TARGET_REPOSITORY_URL` | yes | credential-free SSH or HTTPS clone URL |
| `OPENSYMPHONY_WEB_USER` | yes | browser Basic Auth username |
| `OPENSYMPHONY_WEB_PASSWORD_HASH` | yes | Caddy password hash, never plaintext |
| `OPENSYMPHONY_WEB_PORT` | no | internal Caddy port, default `8080` |
| `GITHUB_TOKEN` | no | fine-grained token for `gh` and HTTPS Git operations |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | no | commit identity |
| `CODEX_HTTPS_PROXY` | no | HTTP CONNECT proxy URL used for HTTPS egress |
| `CODEX_HTTP_PROXY` | no | optional plain HTTP proxy URL |
| `NO_PROXY` | no | must retain internal service/loopback exclusions |
| `CODEX_CA_CERTIFICATE` | no | PEM path such as `/config/certs/company-ca.pem` |
| `OPENSYMPHONY_IMAGE_TAG` | no | full published commit SHA override for rollback or non-Coolify Compose use; normally leave empty so Coolify supplies `SOURCE_COMMIT` |
| `RUST_LOG` | no | Rust log filter, default `info` |

Generate the web password hash locally without placing plaintext in Git:

```bash
docker run --rm -it caddy:2.10.2-alpine caddy hash-password
```

Paste only the resulting hash into Coolify. Because Caddy hashes contain `$`,
mark the variable as **Literal** in Coolify. For a local `.env` file, enclose
the hash in single quotes. Do not set `OPENAI_API_KEY`; the included Codex
configuration forces ChatGPT login and file-backed credential storage.

For a CONNECT proxy, a typical value is
`CODEX_HTTPS_PROXY=http://proxy.example:3128`. The Compose file maps it to the
standard `HTTPS_PROXY` variable inherited by Codex. If the proxy re-signs TLS,
put its verified root bundle in the configuration volume and set
`CODEX_CA_CERTIFICATE`; official Codex documentation applies that bundle to
login, HTTPS, and secure WebSocket connections.

## 4. Configure the domain and HTTPS

1. Open the resource's **Domains** page and select **Add domain**.
2. Choose only the `web` service.
3. Select HTTPS, enter `symphony.example.com`, and explicitly select internal
   port `8080` (or the value of `OPENSYMPHONY_WEB_PORT`).
4. Enable HTTP-to-HTTPS redirect and let Coolify/Traefik issue the certificate.
5. Do not configure a domain for `opensymphony` and do not add a Compose
   `ports:` mapping.
6. Redeploy after saving the domain.

Coolify's domain port is the internal container port; it does not publish that
port directly on the VPS. The public URL remains normal HTTPS.

## 5. Configure GitHub repository access

The safest default for one private target repository is a repository-scoped
SSH deploy key with write access:

1. Deploy the stack once and open a terminal for the `opensymphony` service.
2. Run `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C opensymphony-vps`.
3. Display `~/.ssh/id_ed25519.pub` and add it under the target GitHub
   repository's **Settings -> Deploy keys**, enabling write access.
4. Verify GitHub's published SSH host fingerprints through a trusted channel,
   then populate `~/.ssh/known_hosts` and set it to mode `600`.
5. Use an SSH `TARGET_REPOSITORY_URL`, for example
   `git@github.com:owner/repository.git`.
6. Verify with `ssh -T git@github.com` and
   `git ls-remote "$TARGET_REPOSITORY_URL" refs/heads/aigenerated`.

The `aigenerated` branch must already exist. The seed workflow intentionally
does not create it from an arbitrary base.

If the workflow needs GitHub API operations or HTTPS Git instead, set a
least-privilege fine-grained `GITHUB_TOKEN`. The same value is exposed as
`GH_TOKEN`, and the workspace hook asks `gh auth setup-git` to install the
credential helper. An environment token is visible to agent-run processes, so
scope it to the single repository and rotate it regularly. Never put a token in
`TARGET_REPOSITORY_URL`, the image, `WORKFLOW.md`, or Git history.

## 6. Deploy and authenticate Codex

Deploy the resource and wait for both Compose services to become healthy. The
orchestrator can start before Codex is logged in, but keep all Linear issues out
of active states until authentication is complete.

In the `opensymphony` service terminal, run:

```bash
codex --version
codex app-server --help
codex login --device-auth
codex login status
```

Open the displayed URL on a trusted device, sign in with the intended ChatGPT
account/workspace, and enter the one-time code. Device-code login may need to be
enabled in personal ChatGPT security settings or by the workspace
administrator. Never paste the device code into tickets, logs, or chat.

The resulting `auth.json` is stored under `CODEX_HOME=/home/opensymphony/.codex`
in the `codex_auth` volume. Active ChatGPT sessions normally refresh during use
and survive container replacement. If readiness later reports logged out or
expired, rerun `codex login --device-auth`; use `codex logout` first only when
switching accounts or deliberately revoking the cached session. No paid API key
fallback is configured or required.

## 7. Linear and workflow configuration

The seed workflow polls the project identified by `LINEAR_PROJECT_SLUG` and
treats `Todo`, `In Progress`, and `Rework` as active. `Done`, `Closed`, and the
common canceled spellings are terminal. Change the persistent
`/config/WORKFLOW.md` only if the Linear workflow uses different state names.

OpenSymphony reads Linear directly. Ensure the token can read the project,
issues, relations, comments, and state transitions required by the existing
workflow. Agent-side Linear writes still use repository-provided GraphQL helper
assets; the scheduler does not depend on those writes succeeding.

Before activating a real issue, verify the target repository is already
bootstrapped for OpenSymphony (at minimum its relevant `AGENTS.md`, workflow
instructions, and agent-side Linear/Git skills). The generic container workflow
does not run `opensymphony init` against production repositories automatically.

## 8. Verify the deployment

From the `opensymphony` service terminal:

```bash
curl --fail http://127.0.0.1:2468/healthz
curl --fail http://127.0.0.1:2468/api/v1/capabilities
curl --fail http://127.0.0.1:2468/api/v1/model-settings
codex login status
git ls-remote "$TARGET_REPOSITORY_URL" refs/heads/aigenerated
```

From an external machine:

```bash
curl --fail https://symphony.example.com/healthz
curl --fail --user 'operator' https://symphony.example.com/api/v1/capabilities
```

Then open `https://symphony.example.com/app/`, authenticate, and check:

- the dashboard loads without mixed-content or CORS errors;
- live events remain connected through HTTPS (SSE/WebSocket requests use the
  same `wss://`/HTTPS origin through Caddy and Traefik);
- model settings report the Codex CLI installed, app-server available, and
  ChatGPT login ready;
- the expected Linear project/task graph is visible.

Finally, create or move one disposable Linear task into an active state. Confirm
that exactly one workspace appears in `/workspaces`, Codex starts in that
workspace, progress appears in the browser, and no second task starts while it
is active. Move the test task to a terminal state or cancel it after the smoke
test.

## 9. SuperTask readiness and explicit gaps

The existing scheduler already provides hierarchy-aware scheduling: parents
wait for children, required issue dependencies block dispatch, one workspace is
reused per issue, and runtime failure/retry state appears in control-plane
snapshots. The seed sets `agent.max_concurrent_agents: 1`, so at most one coding
task is active for this single target repository. Workspaces and Codex thread
bindings persist, preserving progress across ordinary restarts.

The seed prompt prepares the requested Git policy:

- target branch `aigenerated`;
- fetch and integrate remote changes without rewriting history;
- never force-push;
- no automatic PR creation;
- no automatic CI repair and no waiting for GitHub Actions;
- review and validate the complete diff before commit/push;
- do not push partial failed work.

These are prompt-level controls, not a Git authorization firewall. Use a
branch-protection/ruleset and a repository-scoped credential for enforcement.

Do not claim the following as implemented by this deployment configuration:

- The generic legacy config does not expose the strict central
  `scheduler.retry.max_attempts` setting. It uses bounded backoff but can retry
  an issue that remains active. For a future production SuperTask rollout,
  migrate to the documented central configuration and set a finite retry count,
  or move failed issues out of active states until an operator intervenes.
- OpenSymphony does not currently assign independently authenticated
  implementer and reviewer roles inside one Codex task. Model them as separate
  dependency-ordered Linear child tasks if independent responsibility is
  required; otherwise the seed performs only same-agent diff review.
- The alpha web client does not implement every TUI/CLI recovery or
  administration flow. Use the CLI and logs for missing operations.
- The browser Basic Auth layer is one shared operator credential, not per-user
  authorization, audit identity, or RBAC.
- The deployment does not create `aigenerated`, repair target repository
  instructions, create PRs, merge branches, or wait for GitHub Actions.

## 10. Restart, update, backup, and troubleshooting

### Restart

Use Coolify **Restart** for runtime-only environment changes. Docker sends the
termination signal through `tini`; Compose allows two minutes for graceful
scheduler and child-process shutdown before forcing termination. Avoid deleting
containers manually while a Git push is in progress.

### Update

1. Back up the six named volumes.
2. Push or select the desired commit on the branch already configured in
   Coolify.
3. Wait for both `container-images` jobs for that exact commit to succeed. Do
   not infer image success from the source push alone.
4. If the packages are private, verify the deployment server's GHCR registry
   login, then redeploy the Git-backed Compose application.
5. Confirm the deployment pulled both `<full-git-sha>` tags. Named volumes
   preserve configuration, ChatGPT login, and workspaces.
6. Re-run the health, Codex status, gateway, and one-task smoke checks.

The Codex CLI version remains pinned by `CODEX_CLI_VERSION` in `Dockerfile`.
Changing it requires a source commit and a successful GitHub Actions image
build; it is no longer a Coolify build argument. The persisted `/config` and
Codex `config.toml` are not replaced automatically; merge intentional template
changes by hand.

### Troubleshooting

- **Image pull says manifest unknown:** verify both `container-images` jobs for
  Coolify's deployed `SOURCE_COMMIT` succeeded, then redeploy after publication.
- **Image pull is denied:** either make both GHCR packages public or configure
  the deployment server's GHCR login with a package-readable account and a
  classic token scoped to `read:packages`.
- **`web` is unhealthy:** inspect the Caddy logs, verify the required username
  and literal password hash, and confirm port 8080 matches the Coolify domain.
- **`exec /usr/bin/caddy: operation not permitted`:** this indicates an older
  web image that still has Caddy's upstream `cap_net_bind_service` file
  capability while Compose drops all runtime capabilities. Confirm the
  `container-images` web job succeeded for the deployed full commit SHA, then
  redeploy that immutable image. Do not add `NET_BIND_SERVICE` or remove the
  existing container security settings; Caddy listens on port 8080 and the
  current image strips the unused file capability at build time.
- **Domain says no available server:** confirm both services are healthy,
  Caddy listens on `0.0.0.0`, and the domain targets `web` on the configured
  internal port.
- **401 loop:** regenerate the Caddy hash and save it as a literal value; do not
  use a plaintext password in `OPENSYMPHONY_WEB_PASSWORD_HASH`.
- **Codex not ready:** run `codex --version`, `codex app-server --help`, and
  `codex login status`; inspect `~/.codex/log/codex-login.log` when present and
  repeat device authentication.
- **Proxy login fails:** verify `HTTPS_PROXY`, `NO_PROXY`, DNS, and the custom CA
  path inside the container. Test with `curl` before retrying login.
- **Git clone fails:** verify the `aigenerated` branch exists, SSH host keys are
  trusted, the deploy key has repository access, and `git ls-remote` succeeds.
- **Linear is empty/unauthorized:** verify `LINEAR_PROJECT_SLUG`, token scope,
  project membership, and active-state spelling.
- **Task retries unexpectedly:** move it out of active states, inspect the run
  detail and retained workspace, fix the cause, then deliberately reactivate it.
- **Configuration changes disappear:** edit files in the mounted `/config`
  volume, not an image path or ephemeral replacement container.

Useful internal diagnostics:

```bash
ps aux
df -h
du -sh /workspaces /config/.opensymphony ~/.codex
curl --fail http://127.0.0.1:2468/api/v1/dashboard/snapshot
```

Never paste `auth.json`, private SSH keys, Linear tokens, GitHub tokens, proxy
credentials, or full environment dumps into support tickets.

## Reference documentation

- [Coolify Docker Compose applications](https://coolify.io/docs/applications/builds/docker-compose)
- [Coolify Docker registries](https://coolify.io/docs/applications/builds/docker-registries)
- [GitHub Container registry](https://docs.github.com/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [GitHub package visibility](https://docs.github.com/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
- [Coolify domains](https://coolify.io/docs/core/networking/domains)
- [Coolify persistent storage](https://coolify.io/docs/applications/configuration/persistent-storage)
- [OpenAI Codex authentication](https://developers.openai.com/codex/auth)
- [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
