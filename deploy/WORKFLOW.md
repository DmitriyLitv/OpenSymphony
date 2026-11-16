---
tracker:
  kind: linear
  project_slug: ${LINEAR_PROJECT_SLUG}
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate

polling:
  interval_ms: 15000

workspace:
  root: /workspaces

hooks:
  after_create: |
    if [ -n "${GH_TOKEN:-}" ]; then gh auth setup-git >/dev/null 2>&1 || true; fi
    git clone --branch aigenerated --single-branch "$TARGET_REPOSITORY_URL" .
  before_run: |
    git status --short
  after_run: |
    git status --short
  before_remove: |
    git status --short
  timeout_ms: 120000

agent:
  max_concurrent_agents: 1
  max_turns: 40
  max_retry_backoff_ms: 300000
  stall_timeout_ms: 600000

routing:
  harness: codex_app_server
  model_profile: codex-chatgpt-local-keychain
---

You are working on Linear task `{{ issue.identifier }}`.

Issue title: {{ issue.title }}
Issue state: {{ issue.state }}
Issue URL: {{ issue.url }}

{% if issue.description %}
{{ issue.description }}
{% endif %}

Work in the existing issue workspace and preserve all prior task progress.
Respect parent/child and blocker ordering supplied by OpenSymphony; do not work
around an unmet predecessor. Use `aigenerated` as the target branch.

Implementation and delivery rules:

- Inspect the current workspace and remote state before editing.
- Preserve unrelated commits and remote changes. Before committing, fetch
  `origin/aigenerated` and integrate it without rewriting published history.
- Never force-push.
- Do not create a pull request.
- Do not repair CI automatically and do not wait for GitHub Actions.
- Review the complete diff and run relevant local validation before committing.
- Commit and push only changes that passed that review and validation.
- If implementation or validation fails, do not push partial work. Leave the
  workspace intact and report the failure clearly for operator intervention.

Target branch: `aigenerated`
