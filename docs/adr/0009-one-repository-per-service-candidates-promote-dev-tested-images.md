# One repository per service; release candidates promote the images dev tested

Status: accepted. Replaces, in ADR 0007, "a release-candidate tag builds every service".

eShop's code moves out of this repository. `eshop-api` (with the sync master, which shares its .NET solution), `eshop-node-api`, `eshop-web` and `thirdparty-mock` each get a repository. This one, renamed `eshop-infra`, keeps what describes and releases the whole system: the Flux manifests, the release and sign-off tooling, the smoke test, the gates, the docs, the glossary and ADRs, and the one issue tracker. eShop is still released as one system: QA and prod run one signed-off set of images, and a version `X.Y.Z` exists only here.

We decided three things a reader might not expect:

**A release candidate is copied, not built.** Each service repository builds, gates and pushes `main-<sha>-<ts>` images on its own `main`. Flux deploys the newest to dev and commits the change here, which starts dev's smoke test (ADR 0008). `scripts/release.sh` cuts `X.Y.Z-rc.N` from a commit here whose dev Deployment succeeded, by copying the digests that commit's dev pins name. We chose this over pushing the same tag to every repository and building there: five tags kept in step can leave a half-built candidate, and a rebuild is not the bytes dev tested.

**The gates live once, here.** Service repositories call one reusable workflow from this public repository to build, run the gates against the temporary copy, scan and push. A service's new image runs there beside the other services' newest `main` images, so every merge must work with the others' `main`. A change across services ships expand-then-contract, never as two PRs that only work together.

**Patches branch in the service repository.** A fix lands on the service's `main` first, then on its `release/N.x`, cut from the commit that built the released image; each `releases/X.Y.Z.md` records every image's source commit. A patch candidate takes the previous release's digests and swaps in only the patched service's.

## Consequences

- Service repositories have no `v*` tags and no issues; their PRs reference `pkhamdee/eshop-infra#N`.
- `scripts/protect-main.sh` protects all five repositories. Each service repository has a `publish` environment (`main` and `release/*` only) holding the Docker Hub secrets. `PROMOTION_TOKEN`, the smoke-test email and the cluster runner stay here, so one runner is enough on a personal account.
- A service PR gets lint, test and the gates, but no smoke test until it reaches dev.
- The repositories are cloned side by side (`scripts/clone-all.sh`), so the service repositories' agent docs point to `../eshop-infra`.
- The move is incremental: promote-by-digest first, here; then one service at a time; the rename last. The system stays releasable after each step.
