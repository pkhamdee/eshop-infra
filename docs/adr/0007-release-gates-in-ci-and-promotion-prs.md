# Release gates run in CI against a temporary copy; deploys are promotion PRs

Until now prod followed the newest `vX.Y.Z` tag automatically, and nothing tested security or performance before an image was pushed. We add a QA environment and gates, and we decide two things a reader might not expect.

**The gates test a temporary copy, before anything is pushed.** On every push to `main` and every release-candidate tag, CI builds the images, starts a throwaway copy of eShop from them (web, api, node-api, PostgreSQL and the mocks; not the sync master or SQL Server, which Locust and ZAP never exercise and which is amd64-only), runs Locust and OWASP ZAP against it (ZAP also signed in as a Customer and as Staff), then scans with Trivy and only then pushes. A failing gate means no image exists, so dev never runs it. We chose this over testing a deployed environment because hosted runners can't reach the cluster on this Mac but can run a temporary copy, and because an image that never passed the gates can never be deployed by mistake. Pull requests run only SAST, the dependency scan, lint, test and build, to stay fast.

**QA and prod move only by merging a promotion PR.** A release candidate (`vX.Y.Z-rc.N`) reaches `eshop-qa` when its QA promotion PR is merged. QA signs it off with a workflow that refuses unless a Playwright run against QA passed for that exact release candidate; sign-off tags `vX.Y.Z` on the same commit, copies the same images (never rebuilt) and opens the prod promotion PR. Merging that PR is the production approval, and rollback is a promotion PR back to an earlier release. We chose PRs over CI deploy approvals (GitHub environments) because a deploy stays a reviewed change in Git, which is what Flux applies, and because GitHub environments can't require two people while a PR rule can: today one person approves; "2 required approvals" is a branch-protection setting once there are two approvers other than the author.

## Consequences

- Prod no longer follows the newest tag; `docs/git-workflow.md` describes promotion PRs instead.
- Each gate is a script in the repo that runs its tool in a container, and the temporary copy is one Compose file, so the gates also run on this Mac and on a future self-managed GitLab (only PR, Release and sign-off steps are GitHub-specific).
- With one maintainer, the merge itself is the approval: GitHub doesn't let an author approve their own PR.
- Beside the image scan, each image's CycloneDX SBOM is made before the push and attached to its digest: a record, not a gate ([ADR 0010](0010-image-sboms-are-unsigned-registry-referrers.md)).
