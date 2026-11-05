## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues for pkhamdee/modernapp (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Conventions

Before any step touching secrets or `*.sops.yaml`, release tags, repo settings or a PR merge, read "Human-only steps" in `docs/agents/conventions.md`: many of these are the user's to run, from the exact command you give them. The same file holds the local gotchas (Rancher Docker socket, deploy layout) and where each service's repository and conventions are.

## Git workflow

Tag-based releases: new work lands on `main` only; each minor series has a `release/N.x` branch for fixes; releases are annotated `vX.Y.Z` tags on the release branch. Every fix on a release branch must also land on `main`. See `docs/git-workflow.md`.
