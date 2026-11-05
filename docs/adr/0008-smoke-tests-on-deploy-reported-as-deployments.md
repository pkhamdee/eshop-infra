# Smoke tests run on every deploy, report as GitHub Deployments, and sign-off is a PR

Status: accepted. Replaces, in ADR 0007, the hand-started Playwright run against QA and the sign-off workflow.

A deploy to dev, QA or prod now counts as successful only once the Playwright smoke test has passed against it. Every push to `main` starts the test. The pushed change decides what it waits for: a `release-pin` line means that environment at that version, anything else means dev at that commit. The job runs on a runner inside the cluster and waits until the environment actually serves the expected version (`e2e/check-serving.sh`). It then tests, retrying a failed run once, and records the outcome as a GitHub Deployment of that version to that environment, with an email to the maintainer. QA's passing Deployment opens a sign-off PR, and the QA lead signs off by merging it. That merge tags the release, copies the images and opens the prod promotion PR, as the sign-off workflow did.

We decided three things a reader might not expect:

**The runner lives in the cluster and exists only per job.** The environments are reachable only from this Mac, and the repository is public, so a runner that stays registered would accept jobs from anyone's PR. Actions Runner Controller (ARC) starts one runner pod per queued job and removes it afterwards. It reads only the Staff Secrets Flux has already decrypted, so no age key ever enters the cluster. Workflows from outside contributors need approval before they run, because a personal account can't restrict a runner to chosen workflows.

**The trigger is the push, not Flux's own notification.** Flux can skip its "health check passed" event when a promotion changes the tag and the images together, so a test triggered by that event could silently never run. Starting from the push to `main` and waiting for the cluster to serve the expected version always runs, and needs no extra token in the cluster.

**A GitHub Deployment is the record, and sign-off is a merged PR.** Email is only a notification. Sign-off and rollback need a record they can look up: which version passed in which environment, and when. QA's approval was already a merged PR, and making sign-off one too keeps every human decision a reviewed change in Git that one rule can protect.

## Consequences

- Dev is tested after every merge. A newer push cancels a waiting or running dev test, which is reported as superseded rather than failed.
- A release candidate bundles everything on `main` when it is cut, so `scripts/release.sh` refuses unless dev's
  Deployment of that exact `main` commit succeeded. `--force` overrides it, and the tag message records that it did.
- An environment that doesn't serve the expected version within 15 minutes is reported as failed, "not deployed".
- `e2e/run-on-actions.sh` only starts the workflow; it no longer registers a runner on this Mac.
