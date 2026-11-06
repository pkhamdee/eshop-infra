# Conventions and gotchas for agents

What the code does not tell you at a glance. Commands, layout and setup live in `docs/setup.md`
("Developing", "Repo layout"); `main`'s protection, releases and promotion to QA and prod in `docs/git-workflow.md`; domain
terms in `GLOSSARY.md`; decisions in `docs/adr/`. This file points there rather than repeating them.

## Local environment

- **Docker**: the user's active docker context `rd-ssh` is broken. Leave the context as it is; point each command
  at Rancher Desktop's socket instead, e.g. `DOCKER_HOST=unix:///Users/pongsak/.rd/docker.sock docker ...`.
- **SOPS** on macOS does not look in `~/.config` by default: decrypting needs
  `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`. The age public key is in `.sops.yaml`.
- **zsh** expands globs and brackets: quote `kubectl -o 'custom-columns=...[0]...'`, `node --test 'test/**/*.test.ts'`
  and anything else with `*`, `?`, `[` or `]`.
- **Shell guard**: compound commands with heredocs, `sh -c`, `source` (also the word in `flux reconcile source git`)
  or long inline Python are often rejected. Write scripts to the scratchpad with the Write tool and run
  `python3 -I <file>`; use `flux reconcile kustomization <name> -n flux-system --with-source` to fetch and apply.
- **Scripted API checks**: macOS `/bin/bash` 3.2 mangles Thai/multibyte JSON inside `"$(curl -d ...)"`; use Python
  `urllib` for anything with Thai text.
- **Shared cluster**: the cluster also runs unrelated workloads: only touch namespaces this repo manages
  (eshop-dev, eshop-qa, eshop-prod, thirdparty, gateway, cert-manager, cnpg-system, arc-systems, arc-runners,
  flux-system).
- **Secrets in output**: decrypt Staff/DB/SMB passwords only inside a script that uses them and never prints them.
  Printing them is blocked for agents and leaks into logs.
- `gh pr create` can fail with "connection reset by peer" after the push succeeded: check
  `gh pr list --head <branch>` before retrying.

## Service repositories

- This repository holds no application code. Each service has its own repository (ADR 0009), cloned beside this one
  (`scripts/clone-all.sh`): `../eshop-api` (eshop-api and eshop-sync-master, .NET; Testcontainers settings and the
  .NET rules are in its `docs/conventions.md`), `../eshop-web`, `../eshop-node-api`, `../thirdparty-mock`. Each
  one's conventions are in its `docs/conventions.md` and its `CLAUDE.md`; work on a service there, in a branch and
  PR of its repository, referencing issues as `pkhamdee/eshop-infra#N`.
- What it builds is decided there (its `.github/workflows/ci.yml`); the gates it runs are this repository's
  `.github/workflows/service-image.yml` and `scripts/gates/`, so a gate change here applies to every service
  repository at its next run. Keep the reusable workflow's PR job names stable: they are the service repositories'
  required checks (`scripts/protect-main.sh`).
- A change across services ships expand-then-contract (git-workflow.md, "Service repositories").

## Deploy and Flux

- **Check manifests before pushing**: `DOCKER_HOST=unix://$HOME/.rd/docker.sock scripts/validate-manifests.sh` (kustomize build + kubeconform, as CI does). Pushes touching only `deploy/**` or `clusters/**` run no CI, so a broken manifest is otherwise found only when Flux fails to apply it.
- **Adding a service**: base folder `deploy/apps/base/<svc>/` (Deployment, Service, an HTTPRoute if the Gateway routes it, `network-policy.yaml`),
  an entry in `.github/services.json`, a lint/test job in `ci-release.yml` listed in `plan.needs` (it becomes a
  required check of `main` once a maintainer re-runs `scripts/protect-main.sh`); if Locust or ZAP
  should reach it, a service in `scripts/gates/temporary-copy/compose.yaml` (and the `gate` job's image list). Dev: see the
  header of `deploy/apps/dev/image-automation.yaml`. Prod: see the header of `deploy/apps/prod/kustomization.yaml`
  and `docs/git-workflow.md` ("Adding a service"). Prod has no image automation: it is pinned to one release in
  `clusters/local/prod-release.yaml` and moves only by a promotion PR (`scripts/pin-release.sh prod X.Y.Z`).
  Never rename `eshop-release` or `apps-prod`: Flux would delete and recreate them, and deleting `apps-prod`
  prunes everything it applied, prod's PostgreSQL Cluster (its data) included.
- **QA** (`eshop-qa`, `qa.eshop.localhost`) has the same shape: overlay `deploy/apps/qa` (a copy of prod's; keep the
  two in step), pin `clusters/local/qa-release.yaml` (GitRepository `eshop-qa`, Kustomization `apps-qa`, lines
  `# release-pin: qa`, release candidates `X.Y.Z-rc.N`). Until the first release candidate is promoted, `apps-qa`
  is suspended by a line ending in `# release-pin-until: qa`, which `scripts/pin-release.sh qa <version>` deletes:
  no tag before then contains `deploy/apps/qa`. Same naming rule: never rename `eshop-qa` or `apps-qa`.
- Base Deployments use untagged `docker.io/pkhamdee/<svc>`; tags are set only by the setter markers
  (`# {"$imagepolicy": "<ns>:<policy>:tag"}`) that Flux rewrites (dev, thirdparty), or by the release pin
  (`# release-pin: <env>` lines, changed only with `scripts/pin-release.sh`). Leave the tag values to Flux and the
  script.
- Flux image-automation commits touch only `deploy/**` and `clusters/**`, which CI ignores (`paths-ignore`); a commit
  mixing code with those paths still runs CI.
- Base HTTPRoutes are dev-shaped (`eshop.localhost`, `sectionName: https`, one parentRef); the prod overlay patches
  every HTTPRoute. Keep prod hostnames out of base.
- **NetworkPolicies** (default deny in eshop-dev, eshop-qa, eshop-prod, thirdparty; enforced by k3s' kube-router): each call
  needs both ends, caller egress and callee ingress. Egress names the container port number (e.g. 8080), not the
  Service port. Gateway = `kube-system` namespace + `app.kubernetes.io/name: traefik`; same-namespace callers by
  podSelector only (keeps environments apart); thirdparty callees list callers by namespace `In [eshop-dev,
  eshop-qa, eshop-prod]`. Copy `deploy/apps/base/eshop-api/network-policy.yaml`.
- **Secrets**: one SOPS file per env, `deploy/apps/{dev,qa,prod}/<name>.sops.yaml`, listed in that overlay's
  resources; `.sops.yaml` encrypts only `data`/`stringData`. Pairs that must match: each env's
  `eshop-node-api-smb` with `deploy/thirdparty/samba/samba-accounts.sops.yaml`, and each env's
  `eshop-sync-master-enterprise` with `deploy/thirdparty/mssql/mssql-credentials.sops.yaml`.
- Images whose binary carries a file capability (Caddy, `sqlservr`) fail with "operation not permitted" under
  `drop: [ALL]`: remove the capability in the image (as eshop-web does) or add `NET_BIND_SERVICE` back (as mssql
  does).
- Trivy fails CI on any CRITICAL, fixed or not (`scripts/gates/deps.sh`, `scripts/gates/image-scan.sh`). For an
  unfixable one add a `.trivyignore` at the repo root (CVE, reason, date): both gates run Trivy there.
- An ImagePolicy with no matching tag stays not Ready and blocks a `wait: true` Kustomization: a new service's image
  must exist before its policy is applied.
- **Cluster runner** (`deploy/infrastructure/runners`, `docs/setup.md` "Cluster runner"): the E2E job runs in a pod
  of ARC's scale set `eshop-e2e`, as service account `eshop-e2e-runner`. Anything new the job reads from the cluster
  needs a rule in `runner-rbac.yaml` (Secrets only by name). In the pod, Chromium resolves every `*.localhost` to
  the pod itself and ignores `/etc/hosts`: hostnames reach Traefik through `--host-resolver-rules`
  (`e2e/playwright.config.ts`), Node through `/etc/hosts` (`e2e.yml`). The ARC charts (controller and scale set)
  share one pinned version; change both together. The runner image `ghcr.io/actions/actions-runner:X.Y.Z` is pinned
  and Flux keeps it current (`deploy/infrastructure/runners/image-automation.yaml`, commits "runners: update
  images"): leave the tag to Flux; to hold a version, set it and remove the `$imagepolicy` marker. `.github/actionlint.yaml` lists the `eshop-e2e` label.

## thirdparty

- `deploy/thirdparty` (Flux Kustomization `thirdparty`, namespace `thirdparty`) holds mocks shared by every env:
  thirdparty-mock, Samba (one share per env), SQL Server (one database per env). It follows `main` with its own image
  automation, independent of releases.
- thirdparty-mock is routed only on `https://eshop.localhost/thirdparty-mock/`, never on `qa.` or `prod.eshop.localhost`;
  QA's and prod's SMS inbox and Enterprise admin (`.../enterprise/qa/`, `.../enterprise/prod/`) are reached there too (`e2e/environment.ts`).
- SQL Server is amd64-only and runs under Rosetta with no nodeSelector. Its `schema` sidecar re-applies the schema
  on every start; changing a file in its ConfigMap generator restarts the pod.

## Human-only steps

Agents are denied these; ask the user, giving the exact command:

- creating Kubernetes Secrets that contain key material, or decrypting and printing credentials;
- restarting Flux controllers (e.g. `kubectl -n flux-system rollout restart deploy/kustomize-controller` when
  Kustomizations hang at "Reconciliation in progress");
- making a new GHCR package public (the `gh` token has no packages scope);
- pushing release branches and tags, and dispatching the release workflow (`docs/git-workflow.md`, "Releasing");
  `scripts/release.sh X.Y.Z-rc.N` is how a release candidate is cut, and the release tag `vX.Y.Z` comes only from
  sign-off: **merging the sign-off PR** "Sign off vX.Y.Z-rc.N" (the QA lead's step; agents never merge, approve or
  close it, nor push `sign-off/*` branches or `releases/*.md` to bring one about). The pipeline opens and closes
  those PRs (`scripts/sign-off-pr.sh`, from `e2e.yml`) and acts on the merge (`scripts/sign-off.sh`, from
  `sign-off.yml`), both tested with fake `gh`/`crane` in `scripts/tests/release-scripts.sh`. There is no sign-off
  workflow to dispatch;
- creating or renewing the cluster runner's GitHub token (`deploy/infrastructure/runners/eshop-e2e-github.sops.yaml`,
  a fine-grained token with Administration read and write; `docs/setup.md`, "Cluster runner") and listing it in that
  folder's `kustomization.yaml`: agents never write that file, not even with a placeholder;
- creating a service repository on GitHub and pushing it, and its `publish` secrets `DOCKERHUB_USERNAME` and
  `DOCKERHUB_TOKEN` (`docs/setup.md`, "Service repositories"): agents prepare the clone beside this one and give
  the commands;
- keeping "Require approval for all external contributors" for fork PR workflows (Settings → Actions → General): a
  public repository's fork PR could otherwise run on the cluster's runner;
- creating or renewing secrets: `PROMOTION_TOKEN` and `DOCKERHUB_TOKEN` are secrets of the `release` environment
  (`gh secret set <NAME> --env release`; `docs/setup.md`, "Release secrets"), not repo secrets;
- the smoke test's email settings (`docs/setup.md`, "Smoke test email"): the Gmail sending account and its app
  password, secret `SMTP_PASSWORD` of the `smoke-test` environment (`gh secret set SMTP_PASSWORD --env smoke-test`)
  and repository variables `SMTP_USERNAME` and `NOTIFY_EMAIL` (`gh variable set`). Agents never set them and never
  send a real email: `scripts/notify.sh` is tested with a fake `curl` in `scripts/tests/release-scripts.sh`;
- applying `scripts/protect-main.sh` (main's ruleset, the `v*` tag rulesets, the `release` and `smoke-test` environments, and each service repository's ruleset, `publish` environment and issues) or changing any repo setting;
  give the user `scripts/protect-main.sh --dry-run` first. Test `scripts/release.sh`, `scripts/check-release-tag.sh`,
  `scripts/pin-release.sh`, `scripts/candidate-images.sh`, `scripts/promotion-pr.sh`, `scripts/sign-off-pr.sh`, `scripts/sign-off.sh`, `scripts/check-new-images.sh`, `scripts/smoke-targets.sh`, `scripts/smoke-result.sh`, `scripts/deployment.sh`, `scripts/notify.sh`, `scripts/protect-main.sh`, `scripts/clone-all.sh` and `scripts/check-enterprise-schema.sh` with
  `scripts/tests/release-scripts.sh` (throwaway local repos, fake `gh`), never against GitHub.

`main` is protected (`docs/git-workflow.md`, "Protecting main"): agents never push to it; every change is a PR whose
required checks (the jobs `ci-release.yml` runs on a pull request, by `name:`) must pass. Renaming or adding such a
job changes the required checks: say so in the PR, since a maintainer must re-run `scripts/protect-main.sh`. Jobs
that need `DOCKERHUB_TOKEN` or `PROMOTION_TOKEN` must declare `environment: release`; that environment deploys only
from `main` and `v*` tags, so those jobs fail on any other branch (a release dry run from another branch skips them: `plan`'s `push` output).
`scripts/release.sh X.Y.0-rc.1` on an existing `release/N.x` merges `origin/main` into it first and refuses while the
branch has commits not on `main` by patch-id (`git cherry`).

Release and e2e scripts share `scripts/lib/` (sourced): the version and environment grammar is `versions.sh`
(`is_candidate`, `env_takes qa|prod <version>`, `is_env`, `is_commit`, `is_target <env> <target>`, ...), the
repository and image registry `repo.sh` (`REPO`, `IMAGE_REGISTRY`, `gh_read`), the pins at a commit `pins.sh`
(`pin_at <rev> [--suspended] <env>`), the smoke test's Deployments `deployments.sh` (`deployments_of`,
`latest_status`, `outcome_of`, `run_ended`; only those recorded by a run on main). Use them rather than a new regex,
a literal `pkhamdee/...`, another `git archive` of the pins or another walk of the Deployments API. Whether an
environment is still suspended is `pin_at <rev> --suspended <env>` (`scripts/pin-release.sh --suspended <env>` on
the working tree; exit 0 suspended, 1 not, 2 no pin), not a grep for the marker.

`gh pr merge <n> --squash --delete-branch` works for agents only as a standalone command, not inside a compound one.
