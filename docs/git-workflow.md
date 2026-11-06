# Git workflow and releases

How a change gets from a branch to `eshop-dev`, and how a release gets through QA to `eshop-prod`. The reasons are
in [ADR 0007](adr/0007-release-gates-in-ci-and-promotion-prs.md); the one-off human setup is in
[setup.md](setup.md) ("Releasing").

```
issue/* ── PR (required checks) ──► main ── CI: gates, scan, push main-<sha> ──► Flux ──► eshop-dev
                                     │  smoke test of dev at the pushed commit (Deployment) ◄─┘
                                     │
         scripts/release.sh X.Y.Z-rc.N (tag on release/N.x)
                                     ▼
              CI: gates, scan, push X.Y.Z-rc.N ──► QA promotion PR ── merged (QA's approval) ──► eshop-qa
                                                                                                    │
                                        smoke test of QA at vX.Y.Z-rc.N (Deployment) ◄──────────────┘
                                                                     │ success
                       sign-off PR "Sign off vX.Y.Z-rc.N" (adds releases/X.Y.Z.md)
                                                                     │ merged (the QA lead's sign-off)
                    sign-off.yml: tag vX.Y.Z, copy images, GitHub Release, prod promotion PR
                                                                     │
                                        merged (production approval) ──► eshop-prod
                                                 smoke test of prod at vX.Y.Z (Deployment) ◄─┘
```

Nothing deploys because a tag appeared: `eshop-dev` follows `main`, and `eshop-qa` and `eshop-prod` each run exactly
the version pinned in Git, which changes only when a **promotion PR** is merged.

The branching model is the **tag-based release workflow**: one maintenance branch per major series, annotated tags
for release candidates and releases. Source: [Git Workflow for Release Management: Branches vs
Tags](https://pkhamdee.blog/2026/05/29/git-workflow-for-release-management-branches-vs-tags/) (Workflow B). This
repo's integration branch is **`main`** (read every `master` in the article as `main`).

## The one rule

**Every fix that lands on a `release/N.x` branch must also land on `main`.** If it doesn't, the next release
regresses. Check this in review before merging any fix to a release branch. `scripts/release.sh` enforces it when a
new minor's first candidate brings `main` into the release branch ([Releasing](#releasing)).

```bash
git cherry -v origin/main origin/release/0.x   # "+" = on the release branch but not on main (by patch-id)
git log main --oneline --grep "<subject>"       # cherry-picked commits get new hashes: search by subject
```

## Branches

| Branch | Purpose | Lifetime |
|---|---|---|
| `main` | Integration branch; the only place new work lands. Deployed to `eshop-dev`, never to prod directly. Protected ([Protecting main](#protecting-main)) | Permanent |
| `release/N.x` | One per major series (e.g. `release/0.x`): its release candidates and releases are tagged here. Fixes only, between minors | Kept while the series is supported |
| `issue/*`, `feature/*` | One task, merged into `main` by PR | Deleted after merge |
| `promote/qa-X.Y.Z-rc.N`, `promote/prod-X.Y.Z` | A promotion PR's branch: one commit changing a pin | Deleted after merge |
| `sign-off/X.Y.Z-rc.N` | A sign-off PR's branch: one commit adding the release's record `releases/X.Y.Z.md` ([Sign-off](#5-sign-off)) | Deleted after merge, or when the PR is closed as stale |

## Tags

- `vMAJOR.MINOR.PATCH-rc.N`: a **release candidate**, e.g. `v0.3.0-rc.1`. Cut by a person with `scripts/release.sh`.
- `vMAJOR.MINOR.PATCH`: a **release**, e.g. `v0.3.0`. Made only by **sign-off** (merging the candidate's sign-off
  PR runs `sign-off.yml`), on the signed-off candidate's own commit. `scripts/release.sh X.Y.Z` refuses.
- Always **annotated**, always on a `release/N.x` branch; CI rejects anything else (`scripts/check-release-tag.sh`).
- Never moved or deleted. A bad candidate is followed by the next `rc.N`, a bad release by the next patch.

Two tag rulesets, kept as code in `scripts/protect-main.sh` (Settings → Rules → Rulesets):

- **"Protect release tags"** blocks deleting, moving and force-pushing any `v*` tag, with no bypass: QA and prod are
  pinned to a tag, so a moved tag would change what Flux deploys without a promotion PR.
- **"Create release tags"** lets only repository admins and maintainers create `v*` tags (its bypass actors are the
  repository roles admin and maintain). A pushed tag runs CI in the `release` environment, so anyone else could
  otherwise reach its secrets by pushing a tag. `scripts/release.sh` (run by a maintainer) and sign-off (pushing with
  `PROMOTION_TOKEN`, a maintainer's token) create them. It is a ruleset of its own because a bypass actor bypasses
  every rule of its ruleset: in "Protect release tags" it would also let maintainers move and delete tags.

## Protecting main

`main` is protected by the branch ruleset **"Protect main"**, kept as code in `scripts/protect-main.sh` and applied by
a maintainer (docs/setup.md, "Releasing"). Run it again after changing it; it updates the ruleset in place.

- **Pull requests only.** Nobody pushes to `main` directly, force-pushes or deletes it, admins included.
- **Required checks**: every job `ci-release.yml` runs on a pull request, by its name, from GitHub Actions:
  `SAST (Semgrep, fail on ERROR)`, `dependency scan (Trivy, fail on critical)` and
  `repo rules (manifests, workflows, scripts, e2e)`. The script reads them from the workflow (jobs with no `needs:`
  and no `if:`). The temporary copy, gates, scan and push never run on a pull request, so they can't be required;
  they guard the push instead (a failure means no image). A PR doesn't have to be up to date with `main` first.
  **Renaming or adding a PR job changes the checks: run `scripts/protect-main.sh` again** after it merges, or PRs
  wait for a check that never comes (or skip the new one).
- **Service repositories** get the same ruleset with no bypass, requiring the PR jobs of their own CI
  ([Service repositories](#service-repositories)); the same script sets them.
- **Who merges**: anyone with write access, which is only maintainers. With 0 required approvals, merging is the
  approval: GitHub doesn't let an author approve their own PR, and with one maintainer that is the only possible
  rule.
- **Flux's dev image commits** still go straight to `main`: Flux pushes over SSH with the deploy key
  `flux-system-main-flux-system-./clusters/local`, and the ruleset lets **deploy keys** (the repo has only that one)
  bypass it. Those commits touch only `deploy/**` and `clusters/**`, which CI ignores. Adding another deploy key
  with write access would also bypass `main`'s protection: don't.
- **Promotion PRs** go through the same rules; they run every required check because `pull_request` has no path
  filter, and they are opened with `PROMOTION_TOKEN` (a PR opened with the workflow's own token would run none).

**Switching on 2 approvals**, once there are two approvers other than the author:

```bash
scripts/protect-main.sh --dry-run --approvals 2 && scripts/protect-main.sh --approvals 2
```

This also dismisses approvals when new commits are pushed and requires the last push to be approved by someone
other than its pusher. Nothing else changes: promotion PRs then need two approvals too, so QA's and the production
approver's decisions become two-person decisions. A promotion PR opened by CI shows the token's owner as author, who
then can't approve it.

**In an emergency** (CI itself broken, and a fix must land): an admin sets the ruleset's enforcement to *Disabled*
(Settings → Rules → Rulesets → Protect main), merges the fix by PR, and immediately runs `scripts/protect-main.sh`
to put it back. There is deliberately no standing admin bypass: it would let the only maintainer skip failing checks.

### The `release` environment

The jobs that hold release secrets run in the GitHub environment **`release`**: `ci-release.yml`'s `push` (Docker
Hub token) and `promote-qa` (`PROMOTION_TOKEN`), `sign-off.yml` (both) and `e2e.yml`'s `sign-off-pr`
(`PROMOTION_TOKEN`). `scripts/protect-main.sh` makes it
deployable only from the branch `main` and from `v*` tags, and the secrets `DOCKERHUB_TOKEN` and `PROMOTION_TOKEN`
live in it, not in the repository (docs/setup.md, "Release secrets"). So a workflow file changed on another branch and
dispatched from there can't reach them; the job fails at "Branch ... is not allowed to deploy to release". A release
dry run therefore pushes only when dispatched from `main`.

What stays open: anyone who can push a `v*` tag can run the workflow as it is in the tagged commit with these
secrets. Only maintainers have write access, and pushing release tags is a maintainer's step.

## Day to day: `main` → `eshop-dev`

```bash
git checkout -b issue/<n>-<name> origin/main
# work, commit, push, open a PR into main; merge once every required check is green
```

This repository holds no application code: every service is built in its own repository
([Service repositories](#service-repositories)). `ci-release.yml` on a pull request (to `main` or `release/*`) runs
the SAST gate (Semgrep, fails on ERROR) and the dependency scan (Trivy over the lockfiles, fails on critical) over
this repository, and the repo rules (manifests, workflows, ShellCheck, the release-script tests, the Enterprise
schema). Reports are kept as artifacts; each gate also runs locally (docs/setup.md, "Running the gates locally").

A service's images come from its repository's `main`: the shared gates build them, run them in a **temporary copy**
of eShop, scan and push them as `docker.io/pkhamdee/<service>:main-<sha>` and `main-<sha>-<unix-ts>` (ADR 0007, ADR
0009). Flux's image automation (`deploy/apps/dev/image-automation.yaml`) then picks the newest `main-<sha>-<ts>` tag,
commits it to `main` here and deploys it to `eshop-dev` (`https://eshop.localhost`). It never takes release-candidate
or release tags. A version's images are pushed once: the push job refuses when any `<service>:<version>` already
exists (`scripts/check-new-images.sh`), so a re-run of an old candidate's CI can't replace images QA tested.

`ci-release.yml`'s build, gate and scan jobs remain for a service built here (an entry of `.github/services.json`
with no `repository`); there is none, so on `main` they don't run, and its manual runs (a rebuild, or a release dry
run with `version` = `0.0.0-test.N`) build nothing.

### Dev's smoke test

Every push to `main`, Flux's image-update commits included, starts the **E2E smoke test** (`.github/workflows/e2e.yml`,
[ADR 0008](adr/0008-smoke-tests-on-deploy-reported-as-deployments.md)) for `eshop-dev` at the pushed commit, on the
runner inside the cluster; nobody dispatches it. The run:

1. records a GitHub **Deployment** of that commit to `dev`, in progress (`scripts/deployment.sh`; Code → Deployments,
   or `gh api repos/pkhamdee/eshop-infra/deployments?environment=dev`);
2. waits until `eshop-dev` serves the commit (`e2e/check-serving.sh --wait dev <commit>`: `apps-dev` applied
   `main@sha1:<commit>` and every Deployment rolled out from it), for up to 15 minutes, else fails as "not deployed";
3. runs Playwright against `https://eshop.localhost`, retrying a failed test once (a pass on the retry passes, and the
   run summary names the test; the Playwright report keeps the first failure), then checks dev still serves the
   commit;
4. marks the Deployment success or failure, linked to the run and `https://eshop.localhost`.

Only the newest dev deploy is tested: a newer push cancels a run still waiting or testing, and its Deployment becomes
inactive, "superseded" (not failed). A code change is tested twice: at the merge commit, still on the previous
images, and at Flux's image-update commit once CI has pushed the new ones, which supersedes the first run if it is
still going. The run is named `E2E push <commit>`. What a push tests is decided by `scripts/smoke-targets.sh`.

## Service repositories

eShop's services are moving into repositories of their own (ADR 0009): **`pkhamdee/eshop-api`**
(eshop-api and eshop-sync-master), **`pkhamdee/eshop-web`**, **`pkhamdee/eshop-node-api`** and
**`pkhamdee/thirdparty-mock`**. This
repository keeps everything that describes and releases the whole system, and the one issue tracker: a service
repository has no issues and no `v*` tags, and its PRs reference `pkhamdee/eshop-infra#N`. Clone them beside this one
with `scripts/clone-all.sh` (docs/setup.md, "Service repositories").

A service repository's CI (`.github/workflows/ci.yml`) runs its own lint and tests, then calls this repository's
**shared gates**, `.github/workflows/service-image.yml`:

- on a pull request: SAST and the dependency scan of that repository. Its required checks are its lint job and
  `image / SAST (Semgrep, fail on ERROR)`, `image / dependency scan (Trivy, fail on critical)` (`scripts/protect-main.sh`);
- on a push to its `main`: the same pipeline as here: `build` → `gate` (the temporary copy, the new image beside the
  other services' newest `main-<sha>-<ts>` images, then Locust and ZAP) → `scan` → `push` as
  `docker.io/pkhamdee/<service>:main-<sha>` and `main-<sha>-<ts>`, where `<sha>` is the service repository's commit
  (also in the image's `org.opencontainers.image.revision` label). A failure anywhere means nothing is pushed, and
  a tag that already exists is never pushed again (`scripts/gates/tags-to-push.sh`): a second run of the same commit
  leaves the image dev tested in place. Each pushed digest then gets its CycloneDX SBOM as a registry referrer
  (`scripts/gates/attach-sbom.sh`, [ADR 0010](adr/0010-image-sboms-are-unsigned-registry-referrers.md)); a second run
  only fills in one that is missing;
- on a push to its `release/N.x`: the same, pushed as `release-N.x-<sha>-<ts>` (a patch's image, never deployed to
  dev; the next patch candidate takes it, [Patch release](#patch-release-also-hotfixes)).

The push uses the repository's environment **`publish`** (`main` and `release/*` only), which holds
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`; the calling job must pass `secrets: inherit`, or the called workflow
sees them empty (its Semgrep finding is accepted in the service repository's `sast-accepted.txt`). From there it is the same road as every other image: Flux's image
automation deploys the newest `main-<sha>-<ts>` to `eshop-dev` and commits the pin here, which starts
[dev's smoke test](#devs-smoke-test) on that commit. So a service PR gets lint, tests and the gates, but no smoke test
until it reaches dev. A release candidate copies every service's dev-tested digest, wherever it was built
([1. Cut a release candidate](#1-cut-a-release-candidate)); `.github/services.json` names each service's
`repository`, and this repository's CI never builds those.

**Changes across services ship expand-then-contract.** Every merge to a service's `main` runs in the temporary copy
beside the other services' `main`, and dev runs whatever was merged last: never write two PRs that only work
together. First make the provider accept both the old and the new shape (expand), then move the consumers, then drop
the old shape (contract), each step a merge that works on its own.

## Releasing

A release goes **release candidate → QA promotion → QA test run → sign-off → prod promotion**, each a separate,
recorded decision. Before the first one, the human setup in docs/setup.md ("Releasing") must be done.

### 1. Cut a release candidate

A **human step** (agents can't push release tags):

```bash
scripts/release.sh 0.3.0-rc.1
```

It shows what it will do, asks for confirmation, pushes an annotated `v0.3.0-rc.1` and prints the tag's CI run.
Which commit it tags:

- **A new minor's first candidate** (`X.Y.0-rc.1`):
  - no `release/N.x` yet (a new major): it forks the branch from `origin/main` and tags it;
  - `release/N.x` exists (it holds the previous minor): it first **merges `origin/main` into it**, a merge commit
    whose tree is exactly `main`'s ("Merge main into release/0.x for v0.3.0-rc.1", parents the branch head and
    `main`), pushes the branch and tags the merge. It refuses unless every commit on the branch since its last merge
    from `main` is already on `main` by patch-id (`git cherry`), so no release-branch fix is dropped. (v0.2.0 was
    made the same way by hand, in `f613dcb`.)
- **Any other candidate** (`X.Y.Z-rc.N` with N > 1, or Z > 0): the head of `release/N.x` as it is. A fix found in QA
  lands on `release/N.x` **and** `main` (the one rule), then `scripts/release.sh X.Y.Z-rc.<N+1>`.

**Only from a `main` commit that passed on dev.** A candidate that brings in `origin/main` (a new `release/N.x`, or
the merge above) bundles everything on it, so before asking it looks up dev's latest Deployment of exactly that
commit ([Dev's smoke test](#devs-smoke-test), [ADR 0008](adr/0008-smoke-tests-on-deploy-reported-as-deployments.md)):

- **success**: it goes on;
- **in progress** (or queued, pending): it refuses, saying dev's smoke test is still running: wait, then run it again;
- **failure**, **inactive** (superseded by a newer push) or **no Deployment**: it refuses, saying which, why and the
  run's link. Fix `main`, or wait for its newest commit to pass on dev.

`scripts/release.sh --force X.Y.0-rc.1` skips that refusal and records it in the tag message ("Cut with --force:
dev's Deployment of `<commit>` was failure (`<run>`)."), so the override stays visible on the tag. Any other candidate
tags the branch head, brings in nothing from `main` and is not checked.

It refuses plain `X.Y.Z` (sign-off tags releases), a candidate whose tag exists, a version already released (cut the
next one), and a commit with a GitHub skip-ci marker (`[skip ci]`, `[ci skip]`, …): GitHub skips every push workflow
on such a commit, tag pushes included, so the tag would never build (that is how `v0.1.0` was lost). For the same
reason Flux's commit templates carry no marker (CI ignores `deploy/**` and `clusters/**` pushes instead), and CI's
`repo rules` job fails if one comes back.

### 2. CI makes its images and opens the QA promotion PR

For a `vX.Y.Z-rc.N` tag CI lints and tests and validates the tag (annotated, on `release/N.x`). It then makes
`docker.io/pkhamdee/<service>:X.Y.Z-rc.N` for every service in `.github/services.json`, **copying by digest** what
already passed rather than rebuilding it (`scripts/candidate-images.sh`,
[ADR 0009](adr/0009-one-repository-per-service-candidates-promote-dev-tested-images.md)):

- **A candidate that brings in `main`** (a new `release/N.x`, or the merge above): every image is the one that `main`
  commit's dev pins name (`deploy/apps/dev`, and `deploy/thirdparty` for thirdparty-mock), which is what dev's smoke
  test passed. Nothing is built, so the gates and the image scan don't run again: each image passed them when it was
  built on `main`. QA gets the exact bytes dev tested, and the SBOM attached to that digest when it was pushed
  ([ADR 0010](adr/0010-image-sboms-are-unsigned-registry-referrers.md)).
- **Any other candidate** (the branch head: a patch): each service takes the newest patch image its repository
  built on `release/N.x`, `release-N.x-<sha>-<ts>`, made after the previous `v*` tag on the branch (`<ts>`, its
  commit's time, later than the tag's); a service with none is copied from that previous version's image. An older
  patch image belongs to an earlier minor's patches and is never taken. Each patch image passed the shared gates when
  its repository built it ([Patch release](#patch-release-also-hotfixes)).

A pin or an image it can't resolve fails the run: nothing untested is filled in. Every copy is checked against its
source digest, and no `X.Y.Z-rc.N` image is ever overwritten. Only then its `promote-qa` job runs `scripts/promotion-pr.sh qa X.Y.Z-rc.N`: a branch `promote/qa-X.Y.Z-rc.N` from
`main` whose only commit is the pin edit, and a PR **`eshop-qa: deploy vX.Y.Z-rc.N`** listing the candidate's
commit, its images with digests, each gate's result and the CI run (whose artifacts are the gate reports).

A copied image's gates ran when it was built, not in this run, so the PR also lists, per image, **the CI run that
pushed it and that run's Locust (`perf-report`) and ZAP (`dast-report`) reports** (`scripts/gate-reports.sh`). The
run is found from the image's `org.opencontainers.image.revision` label and its service's `repository` in
`.github/services.json`: that commit's first run whose push job succeeded (a run that failed a gate pushed nothing; a
later run of the commit pushes nothing either). A patch image links its `release/N.x` build, and an image carried over
from an earlier release the run that first built it. What can't be found (no label, no such run, a report missing or
expired: GitHub keeps artifacts 90 days by default) is said on that image's line, and the promotion goes on.

**Merging it is QA's approval**; nothing reaches QA otherwise. A newer candidate's PR supersedes an unmerged older
one: close the old one. Without `PROMOTION_TOKEN` the job fails after the push and says so; set the secret and re-run
the job, or open the PR yourself with the same script.

### 3. QA (`eshop-qa`)

`eshop-qa` (`https://qa.eshop.localhost`) runs one release candidate, pinned by the lines ending in
`# release-pin: qa` in `clusters/local/qa-release.yaml` (GitRepository `eshop-qa`'s `spec.ref`, Kustomization
`apps-qa`'s `spec.images`): the manifests in `deploy/apps/qa` **as they are in tag `vX.Y.Z-rc.N`**, with the
`X.Y.Z-rc.N` images. Its PostgreSQL keeps its data from one candidate to the next, as prod's does. Flux applies a
merged pin within a minute or two (`flux reconcile kustomization flux-system --with-source` hurries it).

**No release yet.** `deploy/apps/qa` first appears in the first candidate cut after #74 landed, so QA can't run
`v0.2.0` or earlier. Until the first QA promotion, `apps-qa` is suspended by a line ending in
`# release-pin-until: qa`, and the pin holds `0.2.0` as a placeholder. The first QA promotion PR deletes that line
in the same edit, so merging it deploys QA for the first time.

What QA runs: `scripts/pin-release.sh qa` (what Git asks for), `e2e/check-serving.sh qa X.Y.Z-rc.N` (whether the
cluster serves it), `flux get kustomization apps-qa`, `kubectl -n eshop-qa get deploy -o wide`.

### 4. QA test run

**Merging the QA promotion PR starts QA's smoke test automatically**: the push to `main` changes the
`# release-pin: qa` lines, so the E2E smoke test (`.github/workflows/e2e.yml`, run `E2E push <commit>`) tests
`eshop-qa` at the newly pinned candidate instead of dev, as [Dev's smoke test](#devs-smoke-test) describes. It records
a Deployment of **`vX.Y.Z-rc.N`** to `qa` (`gh api 'repos/pkhamdee/eshop-infra/deployments?environment=qa'`) that ends
success or failure; a success marks QA's previous successful Deployment inactive ("replaced by vX.Y.Z-rc.N"), so the
active one is what QA runs. A push changing only pins doesn't test dev; a push moving both pins tests both
environments.

**QA and prod runs are never cancelled or dropped**: every promotion's (or rollback's) target is tested, or reported
as not tested. They have no concurrency group, since GitHub keeps only the newest of several runs waiting in one and
would drop the rest unreported, so two runs of one environment can overlap: rc.1's promotion still waiting for the
runner when rc.2's is merged, say. `scripts/smoke-result.sh` sorts them out against `main`'s pin, read afresh:

- before waiting, a run whose version is no longer the environment's pin on `main` stops; it ends **superseded**;
- a run that fails or is cancelled after the pin moved on (not deployed, or redeployed during the test as Flux
  replaced its version) also ends **superseded**: that failure says nothing about its version;
- otherwise the run is tested as usual, and a pass always stands: the environment served the target before and
  after the test.

A superseded run's Deployment ends inactive ("superseded: eshop-qa is pinned to … on main now, not …"), and its email
says **NOT TESTED** and why; the newer version's own run reports on it. A run cancelled by hand ends inactive,
"cancelled", and is emailed the same way, as is a target whose job left no result at all (cancelled while queued, or
its runner died): never "FAILED". Dev's superseded and cancelled runs send nothing.

**Only `main`'s runs count.** `scripts/deployment.sh` records a Deployment only in a run on `main`, and writes the
run's ref into its payload (`workflow_ref`, `run_url`, `run_id`, `run_attempt`); sign-off and `scripts/release.sh`
read only Deployments whose `workflow_ref` is `refs/heads/main` (`scripts/lib/deployments.sh`). A copy of `e2e.yml`
dispatched from another branch still tests, but records nothing.

To test QA again (a flaky failure, a fix to the test), start the same workflow **through CI** from `main`. The
cluster is on this Mac, so the job runs on the runner inside the cluster (scale set `eshop-e2e`, docs/setup.md
"Cluster runner"); the script starts the workflow and follows it:

```bash
e2e/run-on-actions.sh qa X.Y.Z-rc.N      # workflow "E2E smoke test", environment qa, version X.Y.Z-rc.N
```

The run waits (up to 15 minutes, then fails) until QA is serving exactly that candidate, asked of the cluster
(`e2e/check-serving.sh --wait`: `apps-qa` not suspended and Ready, applied revision `vX.Y.Z-rc.N@sha1:…`, every
Deployment in `eshop-qa` rolled out with `X.Y.Z-rc.N` images), and checks again after the test. Like the automatic
run, it retries a failed test once and records a Deployment of `vX.Y.Z-rc.N` to `qa`. It is named
**`E2E qa X.Y.Z-rc.N`**, and its summary records the version, revision, images and the test code's commit.

The same works for prod (`e2e/run-on-actions.sh prod X.Y.Z`, run `E2E prod X.Y.Z`); without a version it tests
prod's pin on `main` (`e2e/run-on-actions.sh`) or dev at `main`'s head (`e2e/run-on-actions.sh dev`).

What counts for sign-off is QA's **latest Deployment of the candidate created since `main` last changed QA's pin**
(`<pinned-at>`, UTC: the commit on `main`, on its first-parent line, that last changed a `# release-pin: qa` line).
An older one tested an earlier deployment: rc.1 → rc.2 → rc.1 needs a new test of rc.1, which the last promotion's
merge starts anyway.

```bash
gh api 'repos/pkhamdee/eshop-infra/deployments?environment=qa&ref=vX.Y.Z-rc.N' --jq '.[] | "\(.id) \(.created_at)"'
gh api repos/pkhamdee/eshop-infra/deployments/<id>/statuses --jq '.[0] | "\(.state) \(.description) \(.log_url)"'
```

### 5. Sign-off

**Signing off is merging the sign-off PR**, as QA's and prod's approvals are merging promotion PRs
([ADR 0008](adr/0008-smoke-tests-on-deploy-reported-as-deployments.md)). Nobody starts a workflow.

**The sign-off PR.** When a run on `main` tested QA, `e2e.yml`'s last job (`Sign-off PR`, `scripts/sign-off-pr.sh`,
with `PROMOTION_TOKEN` so the PR gets its checks) looks at QA afresh: the candidate `main` pins it to, and QA's latest
Deployment of it since that pin. If that succeeded and `vX.Y.Z` isn't released, it opens **"Sign off vX.Y.Z-rc.N"**
from branch `sign-off/X.Y.Z-rc.N`, whose one commit adds the release's record **`releases/X.Y.Z.md`**:

- ``Candidate: `vX.Y.Z-rc.N` `` (the line sign-off reads) and its commit;
- the candidate's images with digests (what `X.Y.Z` will be);
- under "Gates", each image's CI run and its Locust and ZAP reports, as in the QA promotion PR
  ([2.](#2-ci-makes-its-images-and-opens-the-qa-promotion-pr), `scripts/gate-reports.sh`);
- the passing run, its Playwright report (artifact `playwright-report-qa`), and the QA Deployment (id, created at).

One PR per candidate: running it again finds the PR up to date and pushes nothing; a later pass of the same
candidate updates its record. It also **closes stale sign-off PRs** with a comment saying why: any for another
candidate once QA's pin moves (or apps-qa is suspended), and the candidate's own when QA's latest test of it failed.
A new pass opens it again. The QA lead reviews the record (and the report) and merges the PR: that merge is the
sign-off, and Git keeps the record of what was signed off on which evidence.

**The merge.** A push to `main` that adds or changes a `releases/*.md` runs `.github/workflows/sign-off.yml`, which only
supplies tokens and tools; the decisions are `scripts/sign-off.sh <before> <after>`. Who signed off is whoever merged
the PR that brought the push in. It **refuses, changing nothing**, and fails the run (the step's error says why),
unless:

- the push adds or changes one record, naming a candidate of its version whose tag exists, and a merged PR brought
  it in;
- whoever merged that PR is a **maintainer** (repo role admin or maintain), as the old dispatched sign-off required:
  anyone with write access can merge a PR, but only a maintainer's merge signs off;
- `main` pins `eshop-qa` to exactly that candidate, not suspended;
- QA's latest Deployment of it, created since `main` last changed QA's pin by a run on `main`, succeeded (none,
  still running, or failed refuses; a Deployment recorded by a run from another branch never counts);
- every candidate image exists, and no `X.Y.Z` image exists with another digest;
- `vX.Y.Z` doesn't exist, unless an earlier sign-off of this same candidate made it.

Then it copies each image to `docker.io/pkhamdee/<service>:X.Y.Z` **by digest** (never rebuilt), tags **`vX.Y.Z`** on
the candidate's commit ("Signed off from vX.Y.Z-rc.N by @<merger>, merging <PR>"; CI's `plan` skips a plain release
tag: nothing is built), publishes the **GitHub Release** (images, candidate, QA Deployment and run, who signed off in
which PR, the record) and opens the **prod promotion PR** `eshop-prod: deploy vX.Y.Z`. Each step is skipped or
updated when already done, so a sign-off that failed half-way is finished by re-running the failed job.

A refused sign-off leaves the record on `main` and no release. Put right what it names (wait for or re-run QA's test,
or promote the candidate again), then re-run the job; or let the next candidate's sign-off PR replace the record
(it changes `releases/X.Y.Z.md`, which runs sign-off again). A record merged by a non-maintainer is refused on every
re-run: revert its merge (a PR), and the next QA run on `main` opens the sign-off PR again for a maintainer to merge.

### 6. Prod promotion

`eshop-prod` (`https://prod.eshop.localhost`) runs one release, pinned like QA by the lines ending in
`# release-pin: prod` in `clusters/local/prod-release.yaml`:

| Line | Object | Means |
|---|---|---|
| `semver: "X.Y.Z" # release-pin: prod` | GitRepository `eshop-release`, `spec.ref` | the source at tag `vX.Y.Z` (an exact version selects exactly that tag) |
| `newTag: "X.Y.Z" # release-pin: prod` (one per service) | Kustomization `apps-prod`, `spec.images` | the `X.Y.Z` images |

**Merging the prod promotion PR is the production approval.** Flux then applies `deploy/apps/prod` as it is in tag
`vX.Y.Z` with the `X.Y.Z` images. Pushing a tag never changes prod, and changes on `main` reach prod only once they are
released and promoted. The merge starts prod's smoke test automatically, as for QA ([step 4](#4-qa-test-run)): it
waits until `eshop-prod` serves `X.Y.Z`, tests it and records a Deployment of **`vX.Y.Z`** to `prod`, which on
success marks prod's previous successful one inactive. To test again by hand: `e2e/run-on-actions.sh prod X.Y.Z`
(recorded too), or `cd e2e && npm run e2e:prod` (nothing recorded).

```bash
scripts/pin-release.sh prod                     # the pinned release, from Git
flux get kustomization apps-prod                # Applied revision: vX.Y.Z@sha1:...
kubectl -n eshop-prod get deploy -o wide        # images :X.Y.Z
```

### Promotion and rollback

A promotion PR changes **only the pin**, the same edit for CI or a person, for QA or prod:

```bash
git checkout -b promote/prod-X.Y.Z origin/main
scripts/pin-release.sh prod X.Y.Z               # rewrites every `# release-pin: prod` line
git commit -am "eshop-prod: deploy vX.Y.Z"      # push, open a PR into main
# or, with the PR description CI and sign-off write: scripts/promotion-pr.sh prod X.Y.Z (PROMOTION_PUSH=0 to preview)
```

`scripts/pin-release.sh <env> <version>` accepts only an exact `X.Y.Z` or `X.Y.Z-rc.N`, rewrites every line ending in
`# release-pin: <env>` in `clusters/local/*.yaml`, deletes any `# release-pin-until: <env>` line and prints the new
pin; without a version it prints the current one. CI's `repo rules` job checks every pin (`scripts/validate-manifests.sh`),
so a hand edit that misses a line fails the PR. Before promoting by hand, check that tag `vX.Y.Z` and every
`docker.io/pkhamdee/<service>:X.Y.Z` image exist: a missing tag leaves `eshop-release` not Ready and prod on its
previous release; a missing image leaves that Deployment's new pod in `ImagePullBackOff` while the old one serves.

**Rollback** is a promotion PR back to an earlier release, reviewed and merged the same way:

```bash
git checkout -b promote/prod-0.2.0 origin/main
scripts/pin-release.sh prod 0.2.0
git commit -am "eshop-prod: roll back to v0.2.0"   # push, open a PR into main, merge it
```

Its merge is smoke-tested like any promotion: a Deployment of `v0.2.0` to `prod`, whose success marks the rolled-back
release's Deployment inactive.

It moves manifests and images back but **never the data**: eshop-api migrates the database forwards on start-up and
nothing migrates it back. A rollback is safe only when the earlier release works with the schema the later one left:
no migration between them removed, renamed or retyped anything the earlier release uses
(in `../eshop-api`, between the commits `releases/EARLIER.md` and `releases/LATER.md` name as eshop-api's "built
from": `git diff <earlier> <later> -- src/Eshop.Data/Migrations`). Otherwise roll forward: fix on the
release branch, cut the next patch's candidate and promote it.

A tag carries **its own overlay**: an environment can be pinned only to a version whose tag contains that
environment's overlay (prod: `v0.2.0` or later; QA: the first candidate after #74 or later). Releases before `v0.2.0`
used the old names and can't be rolled back to (docs/setup.md, "Moving to eShop"). A fix to an overlay reaches the
environment with the next release that contains it.

### Things to know

- **Any release can be promoted**, in any order: a patch on an older series reaches prod only if someone promotes it.
- **Prod-only changes** (`deploy/apps/prod`) are released like code: land on `main` (and the release branch for a
  patch), cut a candidate, promote.
- **Adding a service** to releases: an entry in `.github/services.json` and its lint/test job in `plan.needs` (then
  re-run `scripts/protect-main.sh`: the new job is a required check). To run it in prod and QA, add it to
  `deploy/apps/prod` and `deploy/apps/qa`, and an `images:` entry to `apps-prod` / `apps-qa` whose `newTag` line ends
  in `# release-pin: prod` / `# release-pin: qa` (holding the current pin). It can land before a release that
  contains the service: an `images:` entry that matches no Deployment changes nothing.

## Patch release (also hotfixes)

There is no separate hotfix process: an urgent fix takes this route.

A fix to a service lands in **that service's repository**, first on its `main` (the one rule), then on its
`release/N.x`, cut from the commit that built the released image (`releases/X.Y.Z.md` names it: "built from
`<sha>`"):

```bash
# in ../eshop-api (any service repository); the first patch of the line creates its release/0.x:
git push origin <sha from releases/0.5.0.md>:refs/heads/release/0.x   # a maintainer, once per release line
git checkout -b fix-<n> origin/release/0.x   # fix, PR into release/0.x; the same fix, PR into main
#   the merge into release/0.x runs the shared gates and pushes eshop-api:release-0.x-<sha>-<ts>
# then here: the candidate tags this repository's release/0.x head (as it is, or with a manifest fix on it)
scripts/release.sh 0.5.1-rc.1                # CI swaps in each service's newest release-0.x image since v0.5.0
```

```
service fix ──► <service> release/0.x ──► release-0.x-<sha>-<ts> image
                 └── same fix ──► <service> main
scripts/release.sh 0.5.1-rc.1 ──► CI copies v0.5.0's images, swapping in the patch ──► QA ──► sign-off ──► prod
```

A fix to this repository (a manifest, a release script) goes the same way here: a PR into `release/0.x` and one into
`main`. The candidate's sign-off record lists every image with the commit it was built from.

A **new major** (`1.0.0-rc.1`) forks `release/1.x` from `main`; older `release/N.x` branches stay for patches while
supported.

## Auditing

```bash
git tag -l "v*" --sort=-v:refname          # releases and candidates, highest version first
git log v0.2.0..v0.3.0 --oneline           # what changed between two releases
git show v0.3.0                            # tag message ("Signed off from v0.3.0-rc.N by @<merger>, merging <PR>")
git cherry -v origin/main origin/release/0.x   # release-branch commits not on main ("+")
gh release view v0.3.0                     # images with digests, QA Deployment and run, who signed off
oras discover --artifact-type application/vnd.cyclonedx+json docker.io/pkhamdee/eshop-api:0.3.0   # an image's SBOM (ADR 0010)
git log --oneline -- releases/             # every sign-off record (releases/X.Y.Z.md: candidate, digests, evidence)
git log --oneline -- clusters/local/prod-release.yaml   # every prod promotion and rollback
```

## Why tags rather than branches

| | Branches (Workflow A) | Tags (this project) |
|---|---|---|
| Build triggered by | Branch name | Tag name |
| Release snapshot | `release/1.0`, `release/1.0.1` branches | `v1.0.0`, `v1.0.1` tags |
| Patches per series | Accumulate on `staging/1.x` | Same `release/N.x` branch, multiple tags |
| Immutability | Convention | Tag points at exactly one commit (enforced by the tag ruleset) |
| Audit | Diff release branches | `git log v1.0.1..v1.0.2` |
| Branch count | More | Fewer, cleaner history |
