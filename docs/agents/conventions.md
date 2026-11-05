# Conventions and gotchas for agents

What the code does not tell you at a glance. Commands, layout and setup live in `docs/setup.md`
("Developing", "Repo layout"); `main`'s protection, releases and promotion to QA and prod in `docs/git-workflow.md`; domain
terms in `GLOSSARY.md`; decisions in `docs/adr/`. This file points there rather than repeating them.

## Local environment

- **Docker**: the user's active docker context `rd-ssh` is broken. Leave the context as it is; point each command
  at Rancher Desktop's socket instead, e.g. `DOCKER_HOST=unix:///Users/pongsak/.rd/docker.sock docker ...`.
- **Testcontainers** on Rancher Desktop needs both `DOCKER_HOST` (above) and
  `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` (the socket path inside the VM); without the
  override Ryuk fails to start (`docs/setup.md`, "Developing").
- **.NET 10** is at `~/.dotnet`, not on `PATH`: set `DOTNET_ROOT=$HOME/.dotnet` and prepend
  `$HOME/.dotnet:$HOME/.dotnet/tools` to `PATH`. If the shell guard rejects `export` or variables as command
  names, a tiny wrapper script with literal paths (`exec /Users/pongsak/.dotnet/dotnet "$@"`) works.
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

## eshop-api (.NET solution `services/eshop-api`)

Layout:

- `Eshop.Domain` holds the rules and no infrastructure: one folder per area. Reuse the domain rules
  (`Catalog/InstallmentPlan`, `Applications/Eligibility`, `Customers/SmsCode`) instead of re-implementing them.
- `Eshop.Data`: `EshopDbContext`, one `Configurations/<X>Configuration.cs` per entity, snake_case names via
  EFCore.NamingConventions, `Seed/DemoData.cs`.
- `Eshop.Api`: one folder per feature with `<X>Endpoints.cs` exposing `Map<X>Endpoints(this IEndpointRouteBuilder)`,
  wired on the `/api` group in `Program.cs`. Health probes `/healthz/live|ready` sit outside `/api` so the Gateway
  never exposes them.
- `Eshop.SyncMaster` (eshop-sync-master) lives in the same solution and references `Eshop.Data`; it never migrates.
- Package versions only in `Directory.Packages.props` (`<PackageReference>` without `Version`). Warnings are errors,
  including NuGet audit (`NU1903`): a vulnerable transitive package is fixed by pinning a `PackageVersion` plus a
  direct reference (see `System.Security.Cryptography.Pkcs`). Each project has a committed `packages.lock.json`
  (the dependency-scan gate reads it; CI restores with `--locked-mode`): run `dotnet restore` after any package
  change and commit the lock files.
- Gates (`scripts/gates/*.sh`, `docs/setup.md` "Running the gates locally"): a Semgrep ERROR that is a false
  positive goes in `scripts/gates/sast-accepted.txt` with a reason; `nosemgrep` comments are ignored. The ZAP gate
  (`dast.sh`) scans every operation in the OpenAPI description, which eshop-api serves only with
  `OpenApi:Enabled` (set in the temporary copy alone); a High alert to accept goes in `scripts/gates/dast-rules.conf`
  under a `# reason:` line. Every response carries `X-Content-Type-Options: nosniff` (Program.cs). It scans again
  signed in as a Customer and as Staff (`dast-session.mjs`) and fails if either got no 2xx from its role's paths
  (`CUSTOMER_ONLY` / `STAFF_ONLY` in `dast.sh`): a new Customer-only area outside those patterns needs adding there.

Adding an endpoint:

1. Test first in `tests/Eshop.Api.Tests/<Area>/<X>Tests.cs`: `public sealed class XTests(EshopApiFactory api)`,
   `api.CreateClient()` (or a signed-in client, below), `TestContext.Current.CancellationToken`. Assert on HTTP
   responses only; read JSON into private records.
2. Add `Map<X>Endpoints` (a `MapGroup`, private static handlers, `internal sealed record <X>Response` DTOs) and wire
   it in `Program.cs`. Routes and JSON use GLOSSARY names; enums serialise kebab-case.
3. Refusals go through `Refusal.cs` (`Refusal.BadRequest/Conflict/Of`, `Refusal.SmsCode`, extra fields as
   `("key", value)` tuples), giving ProblemDetails with an `error` code. Missing: `TypedResults.NotFound()`.
4. Roles: `group.RequireAuthorization(Roles.Customer|Roles.Staff)` (no token 401, wrong role 403). Current user:
   `user.RequiredCustomerId()`, `user.RequiredStaffUsername()`.
5. Staff endpoints go under `BackOffice/` as a `Map<X>Administration(this RouteGroupBuilder)` called from
   `BackOfficeEndpoints`, so they inherit the Staff policy; add each to the `TheoryData` in
   `BackOffice/BackOfficeAccessTests.cs`. Validation: `BackOfficeEndpoints.Errors()` +
   `errors.Require(ok, field, thaiMessage)` → `TypedResults.ValidationProblem`.

Rules the code follows:

- **Time** comes only from the injected `TimeProvider` (singleton in `Program.cs`). Timeouts too:
  `new CancellationTokenSource(delay, timeProvider)` so the fake clock fires them. Bangkok dates/times via
  `Eshop.Domain.Bangkok`.
- **First writer wins** (no-tie Bids, Lot edits, payment vs forfeit): one conditional `ExecuteUpdateAsync`
  (`WHERE ... AND <precondition>`) and act on rows affected = 0. A read-then-write loses races; the concurrency
  tests catch it.
- **Contract is owned by the Enterprise System** (ADR-0001): private setters; only sync-master changes status via
  the internal `RefreshFromEnterprise`. Handover data lives beside it (ADR-0004). Active Contracts in queries:
  `db.Contracts.Where(Contract.IsActive)`.
- **Offer status**: always read `StatusAt(now)`; the stored status is updated lazily. Same for `Auction`/`Lot`.
- Contract numbers come from `contract_number_counters` via `INSERT ... ON CONFLICT ... RETURNING` with
  `SqlQuery<int>(...).ToListAsync()`; composing it with `SingleAsync` makes EF wrap the INSERT in a subquery.
- Contract, outbox row and Handover are written in one explicit transaction (`OfferEndpoints.Accept`).

Test harness (Seam 1, `EshopApiFactory`):

- One `[assembly: AssemblyFixture]`: one Postgres container and one host for every test, started in
  `InitializeAsync` to avoid double seeding. All tests share one database: create unique data per test
  (`TestData.NewMobileNumber()`, `NewIdNumber()`, `NewPhoto()`), filter catalog-wide assertions to your own rows,
  never rely on row counts, and create Products through the back-office API rather than the DB.
- Signed-in clients: `api.CreateCustomerClientAsync()`, `api.CreateStaffClientAsync()`. Area helpers are extension
  methods beside the tests (`Applications/Applying.cs`, `Offers/Offering.cs`, `Handovers/HandingOver.cs`,
  `Auctions/Bidding.cs`, `Contracts/EnterpriseSync.cs` for simulating the sync pull). Look there before writing
  setup code.
- Fakes (`tests/.../Fakes/`, swapped with `services.Replace` in `ConfigureWebHost`): `api.Clock`
  (`FakeTimeProvider`, starts 2026-01-05T03:00Z), `api.Sms`, `api.Images`, `api.IdVerification`, `api.CreditCheck`.
  Scripted fakes throw for an unscripted ID number.
- **Moving the clock**: put the test in `[Collection(nameof(ClockMoving))]` (defined in `tests/.../ClockMoving.cs`
  with `DisableParallelization = true`) and only move forward. Keep the explicit name: a collection definition
  without it was seen to run in parallel silently. After advancing past a token lifetime (Customer 7 days, Staff
  12 h) sign in again. Tests that change shared settings (Flat Rate, Term) use
  `[Collection(nameof(ProductCategorySettings))]` and restore in `finally`.
- Filter tests with `dotnet test <proj> --filter "FullyQualifiedName~X"` (vstest runner).

Third-party ports: interface + real adapter in `Eshop.Api/ThirdParty/` (typed `HttpClient`), registered in
`AddThirdParties` against `ThirdParty:BaseUrl`; an in-memory fake in `tests/.../Fakes/` exposed as a property on
`EshopApiFactory`. The image service port is `Images/IImageStore`; store only the image ID in Postgres.

Migrations: `dotnet ef migrations add <Name> --project src/Eshop.Data` (`docs/setup.md`). Only eshop-api applies
them, at startup (`Database:MigrateOnStartup`). Demo data is seeded by `UseSeeding`/`UseAsyncSeeding` into empty
tables only (no `HasData`, so identity sequences stay right). On a model-snapshot conflict after a rebase, or after
a bad `migrations remove`: check out `origin/main`'s `EshopDbContextModelSnapshot.cs`, delete your migration files
and run `migrations add` again.

eshop-sync-master:

- Seam-2 tests (`tests/Eshop.SyncMaster.Tests`, `SyncMasterFactory`) run Postgres and an amd64 SQL Server; CI keeps
  them on x86 (`ubuntu-latest`). Locally SQL Server runs under Rosetta (~20 s start).
- A new pulled Enterprise table follows `Sync/ContractPull`: `row_ver` watermark per table in `sync_watermarks`,
  bounded by `MIN_ACTIVE_ROWVERSION()`, saved in the same transaction under `pg_advisory_xact_lock`. Without the
  lock, overlapping pullers (rolling update, parallel tests) hit duplicate keys.
- Enterprise tables have triggers, so `UPDATE ... OUTPUT` without `INTO` fails; use rows affected. Schema changes go
  in `deploy/thirdparty/mssql/enterprise-schema.sql` (idempotent); the tests run the same file.
- SqlClient needs ICU: SyncMaster sets `InvariantGlobalization=false` and uses the `-chiseled-extra` image.
  eshop-api stays invariant. Npgsql connection strings include `GSS Encryption Mode=Disable` (libgssapi noise on
  chiseled images).

## Node services (`eshop-node-api`, `thirdparty-mock`)

- Node 24 runs `src/*.ts` directly (type stripping): no build step, imports end in `.ts`, `erasableSyntaxOnly`,
  so no enums or parameter properties. `npm run lint` / `typecheck` as in `package.json`.
- eshop-node-api: ports as interfaces (`ImageStore`) with adapters (`folderImageStore`, `smbImageStore`). Tests
  (`node --test`) start the real service on port 0 via `test/harness.ts` and assert on HTTP only;
  `startSmbService()` puts `test/fake-smbclient/` (an ESM script: use `import`) on `PATH`. Extend that fake when the
  adapter sends a new smbclient command.
- SMB goes through the `smbclient` binary because pure-JS SMB libraries need NTLMv1/MD4. Use `ls`, not `allinfo`,
  to test existence: Samba without VSS answers `allinfo` with `NT_STATUS_INVALID_DEVICE_REQUEST`.
- `/internal/images/...` is never routed by the Gateway; through the Gateway that path returns the SPA's
  `index.html` (200 text/html), so check the content type when verifying image privacy.
- thirdparty-mock: one Router per mocked party in `src/<party>.ts`, mounted in `src/app.ts`; ID Verification and
  Credit Check sit behind `simulatedDelay`, SMS does not. HTML links must be relative (served under
  `/thirdparty-mock/`). State is in memory, one replica. Test ID numbers (outcome by last two digits) are in
  `src/testIdNumbers.ts`; the 30-day re-apply wait follows the ID number, so use a fresh prefix per demo run.

## eshop-web (`services/eshop-web`)

- Routes in `src/routes.tsx`; signed-in sections are nested layout routes guarded by `<RequireRole role=.../>`, and
  the back office is its own `/staff` branch with `StaffLayout`. Pages in `src/pages/` (`src/pages/staff/`), API
  types and calls in `src/api/<area>.ts`.
- Fetch only through `src/api/client.ts` (`useApi`, `useReloadableApi`, `apiGet/Post/Put/GetBlob`,
  `problemMessage`): it adds the Bearer token and clears the session on a 401. Format money, dates and Flat Rate
  with `src/format.ts` (Asia/Bangkok).
- Thai copy, mobile-first, plain CSS in one file (`src/index.css`), 44 px touch targets, visible `:focus-visible`.
- Breakpoints are defined once, in the comment at the top of `src/index.css`: phone (base, 360 px and up), tablet
  `min-width: 768px`, wide `min-width: 1024px`, desktop `min-width: 1280px`. Use only these widths in media
  queries and name the breakpoint in a comment. Customer content sits in `.frame` (centred, max 1200 px); the
  header shows a menu button below 768 px and a top bar from 768 px (`AppLayout.tsx`). Staff screens
  (`StaffLayout.tsx`) have a sidebar from 1280 px and a slide-out menu behind a button below it. Both menus use
  `layout/useMenu.ts` for open/closed state, Escape-to-close from anywhere and focus back on the button (pass it
  the nav's ref to also move focus to its first link on opening, as Staff does); reuse it for any new menu.
- Lists of rows (Staff lists, including an Auction's Lots, and a Contract's Installments and Payments) use `components/ResponsiveList.tsx`, not
  per-page markup: give it `label`, `columns` (`{ label, cell, align?, block? }`, the first one names the row),
  `rows`, `rowKey`, and optionally `rowLink` / `dimmed` / `summary` (a total line: a table footer row, or a line
  after the cards). It renders a `<table>` from 1280 px and a list of cards
  (each value beside its column label) below, never both. Forms and action buttons inside a row go in a
  `block: true` column (as the Staff Lot actions and closed-Lot settlement do).
- Customer forms (sign-in, SMS code, Apply, Offer) and short personal screens (Application, Account, Contracts)
  sit in `.column-narrow` (~480 px, centred, at every size); a Contract in `.column-wide` (960 px). e2e checks a
  form with `expectFormColumn(field)` and the 360 px phone with `expectFitsNarrowestPhone(page)`.
- Staff sign-in is a `.column-narrow` card too. Other Staff forms (Product, Lot, new Auction) are `.staff-form`
  cards (full width on a phone, at most 760 px) and put two related fields in a `.staff-field-pair` (stacked on a
  phone, side by side from 768 px). e2e runs a Staff session at 360 px with `atNarrowestPhone(page)` and checks
  pairs with `placement(first, second)`.
- e2e: Customer sections are reached with `navigateTo(page, 'สินค้า' | 'ประมูล' | 'บัญชีของฉัน' | 'เข้าสู่ระบบ')`
  in `e2e/tests/steps.ts` (menu on phone, top bar on desktop), Staff sections with `navigateStaffTo(page, …)`
  (slide-out menu on phone, sidebar on desktop); `isPhone()` tells the projects apart. `expectResponsiveList`
  checks a list is a table on desktop and labelled cards on phone.
- Card lists (catalog Products, Auction Lots) use `ul.card-grid` (1 / 2 / 3 / 4 columns at phone / tablet / wide /
  desktop). Product and Lot pages use `.detail-layout` with `.detail-media` (photo) and `.detail-panel`: stacked
  below 1024 px, side by side from it. e2e checks layouts by position, not class: `gridColumns(list)` and
  `placement(photo, panel)` (`'beside' | 'below' | 'overlapping'`) in `e2e/tests/steps.ts`; `cardsAcross(list)` reads columns from
  the first card's width when a grid holds fewer cards than columns (an Auction with one Lot). The Lot page
  (`.lot-detail`) puts its bidding panel before the photos in the page, so it is on screen unscrolled on a phone;
  from 1024 px the photos sit left of it. That is fine for focus order only while the photo area holds nothing
  focusable.
- The image drops all capabilities: Caddy's file capability is removed with `setcap -r` and it listens on 8080.
- Service worker (ADR 0006, #59): hand-written `src/pwa/sw.js`, built to `/sw.js` by the `serviceWorker()` plugin in
  `vite.config.ts` (it injects the build's file list and a content hash), registered in production builds only.
  It pre-caches built static files and `public/offline.html` and never intercepts `/api/*`, `/images/*` or
  `/thirdparty-mock/*`; don't add runtime caching of API responses. Anything in `public/` is pre-cached, so keep
  it small. `vite dev` has no worker; test it with `vite build && vite preview` or the image.

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
- keeping "Require approval for all external contributors" for fork PR workflows (Settings → Actions → General): a
  public repository's fork PR could otherwise run on the cluster's runner;
- creating or renewing secrets: `PROMOTION_TOKEN` and `DOCKERHUB_TOKEN` are secrets of the `release` environment
  (`gh secret set <NAME> --env release`; `docs/setup.md`, "Release secrets"), not repo secrets;
- the smoke test's email settings (`docs/setup.md`, "Smoke test email"): the Gmail sending account and its app
  password, secret `SMTP_PASSWORD` of the `smoke-test` environment (`gh secret set SMTP_PASSWORD --env smoke-test`)
  and repository variables `SMTP_USERNAME` and `NOTIFY_EMAIL` (`gh variable set`). Agents never set them and never
  send a real email: `scripts/notify.sh` is tested with a fake `curl` in `scripts/tests/release-scripts.sh`;
- applying `scripts/protect-main.sh` (main's ruleset, the `v*` tag rulesets, the `release` and `smoke-test` environments) or changing any repo setting;
  give the user `scripts/protect-main.sh --dry-run` first. Test `scripts/release.sh`, `scripts/check-release-tag.sh`,
  `scripts/pin-release.sh`, `scripts/promotion-pr.sh`, `scripts/sign-off-pr.sh`, `scripts/sign-off.sh`, `scripts/check-new-images.sh`, `scripts/smoke-targets.sh`, `scripts/smoke-result.sh`, `scripts/deployment.sh`, `scripts/notify.sh` and `scripts/protect-main.sh` with
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
