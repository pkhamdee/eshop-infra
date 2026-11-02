# Local setup

Takes a fresh Mac (Apple Silicon) to a Rancher Desktop k3s cluster that Flux manages from this repo, serving `https://eshop.localhost` (`eshop-dev`), `https://qa.eshop.localhost` (`eshop-qa`) and `https://prod.eshop.localhost` (`eshop-prod`).

## 1. Rancher Desktop

1. Install [Rancher Desktop](https://rancherdesktop.io/) (`brew install --cask rancher`).
2. **Preferences → Virtual Machine**: memory **12 GB** (SQL Server under Rosetta needs about 2 GB; the app namespaces and the shared mocks need the rest; once QA runs, a third copy of the apps and PostgreSQL may call for more), 4+ CPUs.
3. **Preferences → Virtual Machine → Emulation**: VZ with **Rosetta** enabled, so `linux/amd64` images (SQL Server) run.
4. **Preferences → Kubernetes**: **enabled**, Traefik **enabled** (it is the Gateway API implementation, ADR-0002).
5. **Preferences → Container Engine**: either works; `dockerd (moby)` is assumed by the commands in this repo.

Check:

```sh
kubectl config use-context rancher-desktop
kubectl get nodes
```

Rancher Desktop forwards host ports 80 and 443 to Traefik, and macOS resolves every `*.localhost` name to `127.0.0.1`, so `https://eshop.localhost`, `https://qa.eshop.localhost` and `https://prod.eshop.localhost` reach the cluster without editing `/etc/hosts`.

### Environments and hostnames

The environments share the one `eshop` Gateway on port 443 and run the same apps with the same paths (`/`, `/api`, `/images`); they are told apart by hostname, so none ever shadows another's routes:

| Environment | Namespace | Follows | URL | Gateway listener |
| --- | --- | --- | --- | --- |
| dev | `eshop-dev` | `main` (`main-<sha>` images) | `https://eshop.localhost` | `https` |
| qa | `eshop-qa` | the release candidate pinned in `clusters/local/qa-release.yaml`: tag `vX.Y.Z-rc.N`'s manifests and its `X.Y.Z-rc.N` images, moved only by a QA promotion PR (docs/git-workflow.md). **Nothing until the first release candidate is promoted** (below) | `https://qa.eshop.localhost` | `https-qa` (accepts routes from `eshop-qa` only) |
| prod | `eshop-prod` | the release pinned in `clusters/local/prod-release.yaml`: tag `vX.Y.Z`'s manifests and its `X.Y.Z` images, moved only by a promotion PR (docs/git-workflow.md) | `https://prod.eshop.localhost` | `https-prod` (accepts routes from `eshop-prod` only) |

Base HTTPRoutes are written for dev; `deploy/apps/qa/kustomization.yaml` and `deploy/apps/prod/kustomization.yaml` patch every HTTPRoute to their hostname and listener. The one certificate `gateway/eshop-localhost-tls` carries all three names, and plain HTTP on any of them redirects to HTTPS. Each environment has its own PostgreSQL (`eshop-db` in its namespace) with its own SOPS-encrypted credentials, its own Staff account, its own share on the mock Samba and its own Enterprise database (`enterprise_<env>`) on the mock SQL Server.

### DOCKER_HOST gotcha

If `docker` commands fail with a context error (for example a stale `rd-ssh` context), point the CLI and Testcontainers at Rancher Desktop's socket directly:

```sh
export DOCKER_HOST=unix://$HOME/.rd/docker.sock
```

## 2. Tools

```sh
brew install flux sops age gh
gh auth login            # needs repo scope; used to bootstrap Flux
```

## 3. age key (SOPS)

Secrets in Git are encrypted with [SOPS](https://github.com/getsops/sops) for the age public key in `.sops.yaml`. The private key lives only on your Mac and in the cluster; **never commit it**.

Use the team's existing key if you have it, placed at `~/.config/sops/age/keys.txt`. Only when starting a new environment, generate one and put its public key into `.sops.yaml` (then re-encrypt every `*.sops.yaml`):

```sh
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Give the cluster the private key, out of band (Flux's Kustomizations reference the secret `flux-system/sops-age`):

```sh
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
grep '^AGE-SECRET-KEY' ~/.config/sops/age/keys.txt |
  kubectl -n flux-system create secret generic sops-age \
    --from-file=age.agekey=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
```

## 4. Bootstrap Flux

```sh
export GITHUB_TOKEN=$(gh auth token)
flux bootstrap github \
  --owner=pkhamdee --repository=modernapp --branch=main --personal \
  --path=clusters/local \
  --components-extra=image-reflector-controller,image-automation-controller \
  --read-write-key
```

Bootstrap installs Flux, commits `clusters/local/flux-system/` to `main` if it changed, and adds a read-write deploy key (image automation commits image tag updates back to Git). Re-running it is safe.

## 5. Check

```sh
flux get kustomizations          # flux-system, infra-controllers, infra-configs, thirdparty, apps-dev, apps-prod: Ready
                                 # infra-runners: Ready once its GitHub token exists ("Cluster runner")
                                 # apps-qa: SUSPENDED True until the first release candidate is promoted to QA
kubectl get gateway -n gateway   # eshop, PROGRAMMED True
curl -k https://eshop.localhost/api/product-categories   # catalog JSON from eshop-api
curl -k https://eshop.localhost                          # eshop-web
curl -kI https://eshop.localhost/images/public/demo-iphone-17.svg   # a Product photo from eshop-node-api
curl -I http://eshop.localhost  # 301 to https
curl -k https://prod.eshop.localhost/api/product-categories   # eshop-prod (the pinned release; own database)
curl -k https://qa.eshop.localhost/api/product-categories     # eshop-qa (the pinned release candidate), once QA runs one
open https://eshop.localhost/thirdparty-mock/sms/inbox   # mock SMS inbox: sign-in codes for any mobile number
open https://eshop.localhost/thirdparty-mock/enterprise/ # mock Enterprise System: pushed Contracts, simulate Payment, cancel
```

**`eshop-prod` runs the pinned release.** Prod runs only the release pinned in `clusters/local/prod-release.yaml` (`scripts/pin-release.sh prod` prints it; docs/git-workflow.md, "Prod promotion"). On a fresh cluster Flux deploys that release, starting from an empty prod database. If the pinned tag or its images were missing, the GitRepository `eshop-release` or `apps-prod` would stay not Ready and `https://prod.eshop.localhost` would serve nothing.

**`eshop-qa` runs the pinned release candidate, from the first one on.** QA is pinned the same way, in `clusters/local/qa-release.yaml` (`scripts/pin-release.sh qa`), and its PostgreSQL keeps its data from one release candidate to the next. A release tag carries its own overlay, and no tag before the first release candidate cut after #74 contains `deploy/apps/qa`, so QA cannot run `v0.2.0`. Until a release candidate is promoted, `apps-qa` is therefore **suspended** (`suspend: true # release-pin-until: qa`) and its pin holds `0.2.0` only as a placeholder; `scripts/pin-release.sh qa` says so. Everything else QA needs is already applied from `main`: namespace `eshop-qa`, the Gateway listeners `https-qa`/`http-qa`, `qa.eshop.localhost` in the certificate (reissued by cert-manager from the same local CA, so nothing new to trust), the thirdparty NetworkPolicies, the `eshopqa` Samba share and the `enterprise_qa` database with login `eshop_sync_qa`. Until then `https://qa.eshop.localhost` answers 404. The first QA promotion PR (`scripts/pin-release.sh qa X.Y.Z-rc.N`) pins the candidate and deletes the suspend line in the same edit; once merged, Flux deploys QA for the first time, starting from an empty database (docs/git-workflow.md, "QA (`eshop-qa`)").

**A cluster that ran the old names** (before #49 and #50) needs a few human steps: see [Moving to eShop](#moving-to-eshop-49-50) below.

The certificate comes from a local CA created by cert-manager. To stop browser warnings, trust the CA once:

```sh
kubectl -n cert-manager get secret eshop-local-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/eshop-local-ca.crt
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/eshop-local-ca.crt
```

Recreating the cluster creates a new CA; remove the old "eShop Local CA" from Keychain Access and trust the new one.

## Moving to eShop (#49, #50)

The rename to eShop (spec #46) moves the environments from `sphone-dev` / `sphone-prod` at `sphone.localhost` /
`prod.sphone.localhost` to `eshop-dev` / `eshop-prod` at `https://eshop.localhost` / `https://prod.eshop.localhost`,
with no redirect from the old names and no data migration. A fresh cluster needs none of this section; a cluster that
ran the old names needs the steps marked **human** (agents don't change the cluster or GitHub settings).

**The move is complete**: prod runs `v0.2.0` in `eshop-prod`, and the temporary entries that kept v0.1.x running
were removed from `main` (#62). Rolling prod back to a v0.1.x release is no longer possible.

### 1. Images on Docker Hub

CI pushes every image to Docker Hub as `docker.io/pkhamdee/<service>` (#63); new Docker Hub repositories are public,
so Flux and the pods pull them without credentials. The v0.1.x images on GHCR are no longer used.

**Human**, once: create a Docker Hub access token with Read & Write (hub.docker.com → Account settings → Personal
access tokens), then give it to CI. `gh secret set` prompts for the token, so it never lands in shell history:

```sh
gh variable set DOCKERHUB_USERNAME --body pkhamdee
gh secret set DOCKERHUB_TOKEN --env release --repo pkhamdee/modernapp   # since #78 a secret of environment release
```

(Since #78 the token is a secret of the `release` environment, not of the repository: [Release
secrets](#release-secrets).) Without them the `push images` job fails at login, and dev shows ImagePullBackOff with `apps-dev` not Ready. If
Docker Hub's default repository privacy was changed to private, make each `pkhamdee/<service>` repository public.

### 2. When #50 is on `main`: dev moves, prod stays on v0.1.1

What Flux does by itself:

- **dev** moves to namespace `eshop-dev` at `https://eshop.localhost`. `infra-controllers` deletes namespace
  `sphone-dev` with everything in it (its database volume too: StorageClass `local-path` deletes it). Dev starts from
  an empty database `eshop` (demo data re-seeded), new SMB account and share `eshopdev` / `eshop-dev` (new password),
  SQL Server login `eshop_sync_dev`, image automation `eshop-dev` (its commits read "eshop-dev: update images").
  `https://sphone.localhost` is no longer served.
- **Gateway and certificate**: the Gateway `eshop` serves both eShop names with the certificate
  `gateway/eshop-localhost-tls`, issued by a **new** local CA `eshop-local-ca` ("eShop Local CA").
- **prod keeps running v0.1.1** in `sphone-prod` at `https://prod.sphone.localhost`, unchanged, until `v0.2.0` is
  out. A release's own manifests name its namespace, Gateway, Secrets, SMB account and SQL login, and v0.1.x still
  used the old ones, so `main` kept temporary entries for it until step 4 (#62).

  The Flux objects that drive prod are renamed (GitRepository and ImagePolicy `eshop-release`, ImageUpdateAutomation
  `eshop-prod`); `apps-prod` keeps its name and re-applies the same v0.1.1. Samba and SQL Server restart once (their
  configuration changed), so prod's image uploads and sync pause for a minute; on that restart the schema also
  sets the Contracts' `source_system` default to `ESHOP` in both Enterprise databases. `https://prod.eshop.localhost`
  answers 404 until `v0.2.0`, and `npm run e2e:prod` targets it, so it is for `v0.2.0` and later. A `v0.1.x` patch
  release would not reach prod any more (its images are still named `sphone-*`; see #49).

**Human**, after Flux has applied it (`flux get kustomizations` all Ready):

```sh
# a. Trust the new CA (both hostnames, and the old prod one, now use it); then delete "S Phone Local CA"
#    in Keychain Access → System.
kubectl -n cert-manager get secret eshop-local-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/eshop-local-ca.crt
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/eshop-local-ca.crt

# b. Empty the dev Enterprise database, before anyone creates a Contract in the new dev: Contract numbers restart,
#    and the push never overwrites a Contract number the Enterprise System already has, so an old row would take
#    over a new Contract's status and Payments. DELETE (not DROP DATABASE), so rowversions keep counting up and the
#    sync master's pull watermark stays valid. Also drops the old dev login.
kubectl -n thirdparty exec deploy/mssql -c mssql -- bash -c \
  '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -d enterprise_dev -Q "DELETE FROM hp.payment; DELETE FROM hp.contract; DROP USER IF EXISTS sphone_sync_dev; DROP LOGIN sphone_sync_dev"'

# c. Leftovers (optional): the old CA's key, and dev's old folder on the Samba volume.
kubectl -n cert-manager delete secret sphone-local-ca --ignore-not-found
kubectl -n thirdparty exec deploy/samba -c samba -- rm -rf /shares/sphone-dev
rm -rf ~/.cache/sphone-e2e-runner    # e2e/run-on-actions.sh now caches in ~/.cache/eshop-e2e-runner
```

If a Kustomization hangs at "Reconciliation in progress" while `sphone-dev` terminates:
`kubectl -n flux-system rollout restart deploy/kustomize-controller`.

### 3. Cut-over at `v0.2.0`: prod moves

**Human**: release as usual ([Releasing](#releasing)), `scripts/release.sh 0.2.0`. Then, by itself: CI builds
`eshop-*:0.2.0`; the ImagePolicy `eshop-release` picks `0.2.0`; the automation commits `eshop-release` → `v0.2.0` and
every `apps-prod` image → `0.2.0` ("eshop-prod: follow the newest release"); `apps-prod` applies v0.2.0's
`deploy/apps/prod` to `eshop-prod` at `https://prod.eshop.localhost` (empty database) and prunes what v0.1.1 had in
`sphone-prod`, including its database and volume. `https://prod.sphone.localhost` stops answering.

**Human**, as soon as `flux get kustomization apps-prod` shows `v0.2.0@…` and before using prod:

```sh
# Empty the prod Enterprise database (same reason and method as dev in step 2b).
kubectl -n thirdparty exec deploy/mssql -c mssql -- bash -c \
  '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -d enterprise_prod -Q "DELETE FROM hp.payment; DELETE FROM hp.contract"'
cd e2e && npm run e2e:prod      # smoke test against https://prod.eshop.localhost
```

### 4. Temporary entries removed (#62)

The temporary v0.1.x entries (namespace `sphone-prod`, Gateway `sphone` and its certificate for
`prod.sphone.localhost`, the `sphoneprod` Samba account and share, the `sphone_sync_prod` login, the old names in the
thirdparty NetworkPolicies and the old image entries in `apps-prod`) are gone from `main`. Flux deletes namespace
`sphone-prod` and the Gateway `sphone`. Rolling prod back to a v0.1.x release is no longer possible.

#### Human: after this is applied

Once `flux get kustomizations` shows the commit removing them Ready, drop the leftovers Flux does not own: the old
SQL Server login, the old certificate's Secret and the old prod folder on the Samba volume.

```sh
kubectl -n thirdparty exec deploy/mssql -c mssql -- bash -c \
  '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -d enterprise_prod -Q "DROP USER IF EXISTS sphone_sync_prod; DROP LOGIN sphone_sync_prod"'
kubectl -n gateway delete secret sphone-localhost-tls --ignore-not-found
kubectl -n thirdparty exec deploy/samba -c samba -- rm -rf /shares/sphone-prod
```

Nothing else is needed: the `flux-system/sops-age` key is the same, and GitHub has no required checks that name the
renamed CI jobs.

## Staff back office (demo account)

The back office is at `https://eshop.localhost/staff` (QA: `https://qa.eshop.localhost/staff`, prod: `https://prod.eshop.localhost/staff`). Each environment has
one demo Staff account; its username and password live **only** in the SOPS-encrypted Secret
`deploy/apps/<env>/eshop-api-staff.sops.yaml` (never in plain text in git). Read them with:

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d deploy/apps/dev/eshop-api-staff.sops.yaml   # or qa, prod
```

eshop-api provisions the account at startup from `Staff__Accounts__0__Username|Password|DisplayName` (stored as a salted
PBKDF2 hash). To change the password: `sops deploy/apps/<env>/eshop-api-staff.sops.yaml`, commit, and once Flux applies
it restart eshop-api (`kubectl -n eshop-<env> rollout restart deploy/eshop-api`); the Secret is the source of truth.
More accounts: add `Staff__Accounts__1__*` env vars from the same kind of Secret.

Running eshop-api locally, give it a Staff account the same way (any password you like, not committed):
`Staff__Accounts__0__Username=staff Staff__Accounts__0__Password=<choose one> dotnet run --project src/Eshop.Api`.
Product photo upload needs eshop-node-api (`npm run dev`, port 8081; `ImageService__BaseUrl` overrides it).

## Auction demo

Staff open `/staff/auctions`, create an Auction (default: next Monday 10:00 to Sunday 20:00 Asia/Bangkok; tick
"กำหนดเวลาเอง" to choose times, e.g. one that is already open for a demo) and add Lots with photos. Visitors browse
`/auction`; a Lot page (`/auction/lots/<id>`) polls the current highest Bid every 3 s. Only Customers who passed ID
Verification may bid, and the only way to pass it is to apply for hire purchase: use a thirdparty-mock ID number ending
`02` (ID Verification passes, Credit Check fails) to make a bidder without taking on a Contract. A Bid must be at least the
starting price, then at least ฿100 above the current highest; Bids before opening or from the closing time on are refused.

## Mock Enterprise System (SQL Server)

The Enterprise System is a real SQL Server 2022 (`mcr.microsoft.com/mssql/server`, amd64 only, so it runs under Rosetta;
about 2 GB of memory and a slow first start) in the `thirdparty` namespace, shared by every environment:
databases `enterprise_dev`, `enterprise_qa` and `enterprise_prod`, fake schema `hp.contract` / `hp.payment`
(`deploy/thirdparty/mssql/enterprise-schema.sql`). The pod's `schema` container creates the databases, applies the
schema and (re)sets the logins on every start. Passwords are in the SOPS Secret
`deploy/thirdparty/mssql/mssql-credentials.sops.yaml` (`sa`, `enterprise_admin` for the admin tool, `eshop_sync_dev` /
`eshop_sync_qa` / `eshop_sync_prod` for eshop-sync-master). Each environment's copy of its sync login is in
`deploy/apps/<env>/eshop-sync-master-enterprise.sops.yaml` and must match.

**Admin tool** (story 62): `https://eshop.localhost/thirdparty-mock/enterprise/` → `dev/`, `qa/` or `prod/` lists the Contracts
eshop-sync-master pushed (newest first) with their Payments, and per Contract: **Simulate Payment** (one Installment by
default; the last one makes it `PAID_OFF`), **Mark overdue / Mark active**, **Cancel Contract**. The same as JSON for
scripts:

```sh
B=https://eshop.localhost/thirdparty-mock/enterprise/dev
curl -k $B/contracts                                                          # Contracts + Payments
curl -k -H 'content-type: application/json' -d '{}' $B/contracts/SP-202610-000001/payments    # {amount?, channel?}
curl -k -H 'content-type: application/json' -d '{"status":"OVERDUE"}' $B/contracts/SP-202610-000001/status
curl -k -H 'content-type: application/json' -d '{"reason":"demo"}' $B/contracts/SP-202610-000001/cancel
```

**eshop-sync-master** (`deploy/apps/base/eshop-sync-master`) runs a sync cycle every 30 s: it pushes Contracts waiting in
`contract_outbox` to `hp.contract` (MERGE on the Contract number, insert only: pushing twice leaves one copy and never
overwrites what the Enterprise System changed), then sets `pushed_at`. From then on the Enterprise System owns the
Contract (ADR-0001). In the same cycle it then pulls what changed there since the last pull: Contract status
(`active | overdue | paid-off | cancelled`, plus `cancelled_at`) into `contracts`, and Payments into `payments` (unique
on the Enterprise `payment_id`). It finds changes by the `row_ver` rowversion watermark, one row per table in
`sync_watermarks`, stored in the same transaction as the copied rows; only committed changes are read
(`row_ver < MIN_ACTIVE_ROWVERSION()`). The Customer's Contract page therefore lags the admin tool by at most one
cycle (≈30 s). A Contract cancelled there stops its Handover (ADR-0004). eShop never computes overdue itself.
Logs: `kubectl -n eshop-dev logs deploy/eshop-sync-master`.

Read-only look at the database (sa password from the Secret, never printed):

```sh
kubectl -n thirdparty exec deploy/mssql -c mssql -- bash -c \
  '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -d enterprise_dev -Q "SELECT contract_no, status, last_updated_at FROM hp.contract"'
```

## End-to-end smoke test (Seam 4)

`e2e/` holds one Playwright browser test of the definition-of-done demo (spec #1), run against a **deployed**
environment, never on every CI run. It runs in full twice, as two Playwright projects in Chromium: **phone**
(Pixel 7 settings at 390×844, touch) and **desktop** (1280×800). Each run:

1. signs a Customer in by SMS (the code is read from the mock inbox `/thirdparty-mock/sms/inbox`), applies for the
   iPhone with an ID card photo (thirdparty-mock ID ending `01`), waits for **Approved** (≤ 60 s) and accepts the Offer
   with a second SMS code;
2. waits until the Contract shows in the mock Enterprise System admin tool (`/thirdparty-mock/enterprise/<env>/`);
3. signs Staff in, records the Down Payment and moves the Handover to handed over; the Customer's Contract shows it;
4. clicks **Simulate Payment** in the admin tool and waits until the Payment shows on the Customer's Contract;
5. separately: a second Customer passes ID Verification (ID ending `02`, Credit Check fails), Staff create an Auction
   with their own times (open now, **closing about two minutes ahead**, so nobody waits for the weekly Sunday close),
   add a Lot with a photo, the Customer bids and, once the Auction closes, has won the Lot.

A third test checks the eShop brand (title, logo, the mock admin tool's heading). After every page the demo opens
in the eShop app, at both sizes, it checks that the page does not scroll sideways and shows no "S Phone",
"Srisawad" or "เอส ลีสซิ่ง" text (`expectPageFits` in `e2e/tests/steps.ts`).

Each test uses its own mobile and ID numbers (ID prefix `3`, plus the worker's digit so tests running side by side
never share a Customer) and its own Auction and Lot (the title names the project), and leaves them behind as demo
data. Two workers run the six tests; it takes about 7–8 minutes. To run one size: `npx playwright test
--project=phone` (or `desktop`).

```sh
cd e2e
npm ci && npx playwright install chromium            # once
npm run e2e                                          # eshop-dev: https://eshop.localhost
E2E_BASE_URL=https://prod.eshop.localhost npm run e2e   # eshop-prod (same as npm run e2e:prod)
npm run e2e:qa                                       # eshop-qa: https://qa.eshop.localhost (once QA runs a release candidate)
npm run report                                       # HTML report of the last run (traces of failures)
```

- **Staff credentials** come from the environment's SOPS Secret (`deploy/apps/<env>/eshop-api-staff.sops.yaml`),
  decrypted at run time by `global-setup.ts` with `sops` and the age key (`SOPS_AGE_KEY_FILE`, default
  `~/.config/sops/age/keys.txt`) into the test process's environment only; it is never printed or written to the
  report. On the cluster's runner (in a pod: `KUBERNETES_SERVICE_HOST` is set) they come instead from the Secret
  `eshop-<env>/eshop-api-staff` that Flux applied, read with `kubectl` as the pod's service account; no age key is
  in the cluster. Or set `STAFF_USERNAME` / `STAFF_PASSWORD` yourself. `E2E_ENV=dev|qa|prod` overrides the environment name
  derived from the host (`qa.` → qa, `prod.` → prod, otherwise dev); it picks the Enterprise database in the admin tool and the Secret.
- The certificate is self-signed; the test accepts it.
- **GitHub Actions**: `e2e/run-on-actions.sh [prod|qa|dev] [version]` (default `prod`, no version) starts
  `.github/workflows/e2e.yml` from `main` and follows the run (the Playwright report is a run artifact). The job
  runs on the runner inside the cluster, which GitHub-hosted runners can't reach ([Cluster runner](#cluster-runner));
  nothing is registered on this machine. It needs `gh` logged in with write access. Starting it from the Actions
  tab works too. In the runner pod, `*.eshop.localhost` goes to Traefik's Service
  (`traefik.kube-system.svc.cluster.local`): Node finds it in `/etc/hosts` (a workflow step), Chromium through a
  host-resolver rule (`e2e/environment.ts`), because Chromium answers `*.localhost` with loopback itself.
  `E2E_GATEWAY_HOST` sets that target anywhere, e.g. `KUBERNETES_SERVICE_HOST=x E2E_GATEWAY_HOST=192.168.64.2 npm run e2e:prod`
  tries the in-cluster mode from the Mac.
- **QA's test of a release candidate** runs by itself when its QA promotion PR is merged; `e2e/run-on-actions.sh qa
  X.Y.Z-rc.N` runs it again. Only such a run's Deployment counts for sign-off, and a pass opens the sign-off PR
  (git-workflow.md, "QA test run" and "Sign-off"). Given a version (required for `qa`, optional `X.Y.Z` for `prod`, none
  for `dev`), the run refuses unless the environment is actually serving it, checked against the cluster by
  `e2e/check-serving.sh <env> <version>` (Flux applied tag `v<version>` to `apps-<env>`, and every Deployment in
  `eshop-<env>` finished rolling out with the `<version>` images), before and again after the test. The script makes
  the check here first, so `e2e/run-on-actions.sh qa 0.3.0-rc.1` while QA serves something else stops at once:
  `eshop-qa is not serving 0.3.0-rc.1: apps-qa applied v0.3.0-rc.2@sha1:...` (while QA has no release yet:
  `... apps-qa is suspended ...`). The run is named `E2E <environment>[ <version>]` (`E2E qa 0.3.0-rc.1`) and its
  summary lists the version, the applied revision and the images. In the job, `kubectl` (installed by the workflow)
  acts as the runner pod's service account.
  For dev the check takes a `main` commit (`e2e/check-serving.sh dev <commit>`, short or full): `apps-dev` applied
  `main@sha1:<commit>` and every Deployment finished rolling out with the images that revision pins. With `--wait`
  it checks again every 10 s until the environment serves, and after 15 min (`--timeout SECONDS`) refuses with
  "not deployed", naming the Kustomization to look at (`flux get kustomization apps-<env>`).
  Tests for the check, with a fake kubectl: `e2e/check-serving.test.sh`; for the script, with a fake gh:
  `e2e/run-on-actions.test.sh` (both run in CI's `repo rules` job).

### Smoke test email

Each smoke test result on GitHub Actions is emailed (`e2e.yml`'s `notify` job, `scripts/notify.sh`): every QA and
prod result, and for dev only a failure and the first pass after one (judged from dev's previous Deployment). The
subject says what happened, e.g. `[eShop] prod v0.3.0: deployed and smoke test passed` or
`[eShop] qa v0.3.1-rc.1: smoke test FAILED` (also `passed on retry`, `NOT DEPLOYED`, and for QA and prod
`NOT TESTED (superseded)` or `NOT TESTED (cancelled)`: docs/git-workflow.md, "QA test run"); the body links the run and
its Playwright report artifact (`playwright-report-<env>`). A prod failure names the last release that passed in prod
and the rollback: `scripts/promotion-pr.sh prod <that version>`, whose PR's commit is
`scripts/pin-release.sh prod <that version>`, then merge it.

It is sent over SMTP with `curl` (`smtps://smtp.gmail.com:465`, TLS required), from a Gmail account to one address.
The password is a secret of the `smoke-test` environment, which only `main` can use; the job reads it without
recording a deployment. **Human**, once, in this order:

1. **The sending account**: a Gmail account for the mails (a separate one, e.g. `eshop.smoke.test@gmail.com`, keeps
   your own account's password out of CI). Turn on 2-Step Verification for it (Google Account → Security).
2. **Its app password**: Google Account → Security → 2-Step Verification → App passwords (or
   <https://myaccount.google.com/apppasswords>); create one named e.g. `eshop smoke test` and copy the 16 letters.
   Gmail refuses the account's normal password over SMTP.
3. **The `smoke-test` environment**: `scripts/protect-main.sh --dry-run`, then `scripts/protect-main.sh`
   ([Protecting main](#protecting-main)); it creates the environment, deployable from `main` only.
4. **The secret and the variables** (`gh secret set` prompts for the value, so it never lands in shell history):

```sh
gh secret set SMTP_PASSWORD --env smoke-test --repo pkhamdee/modernapp           # the app password (step 2)
gh variable set SMTP_USERNAME --body eshop.smoke.test@gmail.com --repo pkhamdee/modernapp   # the sending account
gh variable set NOTIFY_EMAIL --body you@example.com --repo pkhamdee/modernapp    # who gets them (comma-separated)
gh secret list --env smoke-test --repo pkhamdee/modernapp && gh variable list --repo pkhamdee/modernapp
```

Until all three are set, the `notify` job fails on every run, naming what is missing; the smoke test's own job and
its Deployment are unaffected (the Deployment is finished before `notify` starts, and `notify` may only read
Deployments). A run dispatched from another branch can't use the environment, so its `notify` job fails the same way.
To check the setup without waiting for a deploy: `e2e/run-on-actions.sh qa <the version QA serves>` mails the
result. Mails land in the recipient's inbox from the sending account; if not, look in spam and mark it "not spam"
once.

### Cluster runner

The E2E job (`runs-on: eshop-e2e`) runs inside the cluster (ADR 0008). Flux installs Actions Runner Controller
(`deploy/infrastructure/controllers/actions-runner-controller.yaml`, namespace `arc-systems`, watching only
`arc-runners`) and the runner scale set `eshop-e2e` (`deploy/infrastructure/runners`, Kustomization `infra-runners`):
0 runners while idle, at most 1, one runner pod per job, deleted after it. A listener pod in `arc-systems` waits for
queued jobs. The runner pod's service account `eshop-e2e-runner` may only get the Kustomizations `apps-dev`,
`apps-qa`, `apps-prod`, read Deployments, ReplicaSets and Pods in `eshop-dev`, `eshop-qa`, `eshop-prod`, and get each
one's Staff Secret `eshop-api-staff` (`runner-rbac.yaml`). The token below is not given to runner pods (they get a
one-job registration instead).

ARC registers the scale set with a GitHub token, the Secret `arc-runners/eshop-e2e-github`. Until it exists no job
can run: the scale set has no listener, and `infra-runners` may show not Ready. Nothing depends on `infra-runners`,
so the apps deploy as usual meanwhile.

**Human**, once (and again before the token expires), in this order:

1. github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.
   Name `modernapp eshop-e2e runner`; resource owner `pkhamdee`; expiration 90 days (or what you accept);
   **Repository access**: Only select repositories → `pkhamdee/modernapp`; **Repository permissions**:
   Administration **Read and write** (Metadata read-only is added by itself). Nothing else.
2. Put it in a SOPS Secret without it ever touching the disk in plain text: write the file with a placeholder,
   encrypt it, then replace the placeholder in `sops`' editor:

   ```sh
   cat >deploy/infrastructure/runners/eshop-e2e-github.sops.yaml <<'EOF'
   # GitHub token of the eshop-e2e runner scale set (docs/setup.md, "Cluster runner"): a fine-grained token for
   # pkhamdee/modernapp only, Administration read and write. Renew: sops deploy/infrastructure/runners/eshop-e2e-github.sops.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: eshop-e2e-github
     namespace: arc-runners
   type: Opaque
   stringData:
     github_token: placeholder
   EOF
   sops --encrypt --in-place deploy/infrastructure/runners/eshop-e2e-github.sops.yaml
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/infrastructure/runners/eshop-e2e-github.sops.yaml   # paste the token
   ```

3. In `deploy/infrastructure/runners/kustomization.yaml`, uncomment `- eshop-e2e-github.sops.yaml` (only together
   with the file: a listed file that is missing breaks the whole Kustomization). Check with
   `scripts/validate-manifests.sh`, then open a PR with both files and merge it.
4. Check: `flux get kustomization infra-runners` Ready; `kubectl -n arc-systems get pods` shows the controller and
   an `eshop-e2e-...-listener` pod Running; Settings → Actions → Runners lists the scale set `eshop-e2e`. Then a run
   on it: `e2e/run-on-actions.sh prod X.Y.Z` (the release prod serves) passes.
5. Keep Settings → Actions → General → "Approval for running fork pull request workflows from contributors" at
   **Require approval for all external contributors** (it is set; check with
   `gh api repos/pkhamdee/modernapp/actions/permissions/fork-pr-contributor-approval`, `all_external_contributors`).
   The repository is public, and on a personal account a runner can't be limited to chosen workflows: a fork PR
   whose workflow says `runs-on: eshop-e2e` would run in the cluster. Approve a fork's workflow run only after
   reading what it runs.

**Renewal**: create a new token with the same settings, `sops deploy/infrastructure/runners/eshop-e2e-github.sops.yaml`,
replace the value, PR, merge. An expired token shows as listener errors (`kubectl -n arc-systems logs` on the
listener pod) and runs that stay queued.

The local runner of earlier versions is gone; its cache can be deleted: `rm -rf ~/.cache/eshop-e2e-runner`.

## Releasing

Tag-based, per [git-workflow.md](git-workflow.md) ("Releasing"): release candidate → QA → sign-off → prod. Cutting a
candidate is your step: agents can't push release tags.

**Human, once, in this order** (each is described below):

1. **Create the promotion token** ([Promotion token](#promotion-token), steps 1 to 3); don't store it yet.
2. **Protect `main` and create the `release` environment** ([Protecting main](#protecting-main)): run
   `scripts/protect-main.sh`, dry run first. This comes before the secrets because environment secrets need the
   environment to exist. Until step 3 is done, the jobs in that environment still read the repository secrets.
3. **Release secrets** ([Release secrets](#release-secrets)): put `PROMOTION_TOKEN` and `DOCKERHUB_TOKEN` into the
   `release` environment, then delete the repository-level copies.
4. **Cut the first release candidate** (below). On the existing `release/0.x` (it holds v0.2.0), the first candidate
   of 0.3 is `scripts/release.sh 0.3.0-rc.1`: it merges `main` into `release/0.x` first, after showing you the merge.
   Its QA promotion PR also starts `eshop-qa` for the first time.

```sh
# 1. Release candidate: tag v0.3.0-rc.1, push, print the CI run URL. A new minor's first candidate (X.Y.0-rc.1)
#    forks release/<MAJOR>.x from main, or merges main into the existing branch first (refused while the branch has
#    a commit that is not on main); other candidates tag the branch head
scripts/release.sh 0.3.0-rc.1

# 2. Watch CI: test → validate tag → build → temporary copy and gates → scan → push docker.io/pkhamdee/<service>:0.3.0-rc.1
#    → opens the QA promotion PR "eshop-qa: deploy v0.3.0-rc.1" (images with digests, gate results, CI run link)
gh run watch "$(gh run list --workflow ci-release.yml --branch v0.3.0-rc.1 --limit 1 --json databaseId --jq '.[0].databaseId')"
gh pr list --head promote/qa-0.3.0-rc.1

# 3. QA: merging that PR is QA's approval; Flux deploys the candidate to eshop-qa a minute or two later
flux get kustomization apps-qa                        # Applied revision: v0.3.0-rc.1@…
kubectl -n eshop-qa get deploy -o wide               # images :0.3.0-rc.1, all READY

#    That merge also starts QA's smoke test (e2e.yml, run "E2E push <commit>"): a Deployment of v0.3.0-rc.1 to qa
gh api 'repos/pkhamdee/modernapp/deployments?environment=qa&ref=v0.3.0-rc.1' --jq '.[0].id'
gh api "repos/pkhamdee/modernapp/deployments/<id>/statuses" --jq '.[0].state'   # success
#    (to test it again: e2e/run-on-actions.sh qa 0.3.0-rc.1)

# 4. Its pass opens the sign-off PR "Sign off v0.3.0-rc.1", adding releases/0.3.0.md (candidate, digests, the run and
#    its Playwright report). Review it; merging it is the sign-off (the QA lead's step)
gh pr list --head sign-off/0.3.0-rc.1

# 5. The merge runs sign-off.yml: refuses unless main still pins QA to 0.3.0-rc.1 and QA's latest Deployment of it
#    since that pin succeeded; copies the images to 0.3.0 by digest, tags v0.3.0 on the candidate's commit (naming
#    who merged), publishes the GitHub Release and opens the prod promotion PR "eshop-prod: deploy v0.3.0"; merging
#    that is the production approval
gh run watch "$(gh run list --workflow sign-off.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh pr list --head promote/prod-0.3.0

# 6. Post-release smoke test against eshop-prod (locally, or on GitHub Actions)
cd e2e && npm run e2e:prod                            # or: e2e/run-on-actions.sh prod 0.3.0
```

A fix found in QA goes to `release/0.x` **and** `main`, then the next candidate (`scripts/release.sh 0.3.0-rc.2`); a
fix after the release, the next patch's candidate (`scripts/release.sh 0.3.1-rc.1`; git-workflow.md, "Patch release").
`scripts/release.sh X.Y.Z` (no `-rc.N`) refuses: sign-off tags releases.

If the promotion token is missing, CI's `open the QA promotion PR` job fails after the images are pushed and names
the secret; set it and re-run that job, or open the PR yourself with `scripts/promotion-pr.sh qa 0.3.0-rc.1`
(`PROMOTION_PUSH=0` first shows the commit and description without pushing).

Sign-off's refusals fail the `sign-off.yml` run and say what is missing (QA pinned to another candidate or suspended,
no successful QA Deployment of the candidate since its pin, a missing image, `v0.3.0` already released). If it fails
half-way (a registry or GitHub error), re-run the failed job: it skips what is done and finishes. It needs
`PROMOTION_TOKEN` and the same Docker Hub credentials as CI's push job (variable `DOCKERHUB_USERNAME`, `release`
environment secret `DOCKERHUB_TOKEN`, Read & Write). Whoever may merge into `main` may sign off; the tag and the
Release name them (git-workflow.md, "Sign-off"). A stale sign-off PR (QA moved to another candidate, or its test
failed) is closed by the pipeline with a comment.

### Promotion token

CI opens promotion and sign-off PRs (and, with sign-off, pushes the release tag) with a **fine-grained personal access token**,
stored as the secret `PROMOTION_TOKEN` of the `release` environment. Not the workflow's own `GITHUB_TOKEN`: GitHub runs no workflow for a PR
or tag that token creates, so a promotion PR would never get its required checks. Commits and PRs made with it show
you as the actor (the commits themselves are authored by `github-actions[bot]`).

**Human**, once, and again before it expires:

1. github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.
2. Name `modernapp PROMOTION_TOKEN`; resource owner `pkhamdee`; **expiration** 90 days (or what you accept; a calendar
   reminder a week before helps); **Repository access**: Only select repositories → `pkhamdee/modernapp`.
3. **Repository permissions**: Contents **Read and write**, Pull requests **Read and write** (Metadata read-only is
   added by itself). Nothing else; add Workflows read and write only if a promotion ever has to change
   `.github/workflows/`.
4. Give it to CI as a secret of the `release` environment ([Release secrets](#release-secrets); the environment is
   created by `scripts/protect-main.sh`).

**Renewal**: regenerate the token on the same page (or create a new one with the same settings) and run the same
`gh secret set PROMOTION_TOKEN --env release --repo pkhamdee/modernapp`. An expired or revoked token makes the promotion job fail at `git push` or `gh pr create` with an
authentication error; the images are already pushed, so re-run just that job once the secret is updated. The
token must belong to a repository admin or maintainer: only they may create `v*` tags (ruleset "Create release
tags"; git-workflow.md, "Tags"). It pushes only `promote/*` and `sign-off/*` branches and `vX.Y.Z` tags, never
`main`, so `main`'s ruleset needs no bypass for it either: a person merges the promotion and sign-off PRs.

### Protecting main

`main`'s ruleset and the `release` and `smoke-test` environments are code: `scripts/protect-main.sh` (what it sets and why:
git-workflow.md, "Protecting main"). **Human** (a repo admin), once after it lands on `main`, and again whenever it
or the names of ci-release.yml's pull-request jobs change:

```sh
git checkout main && git pull
scripts/protect-main.sh --dry-run    # prints every request it would send; reads only
scripts/protect-main.sh              # creates or updates rulesets "Protect main", "Protect release tags",
                                     # "Create release tags" and environments "release"
                                     # and "smoke-test"
```

Check: Settings → Rules → Rulesets → **Protect main** (Active; bypass: Deploy keys; required checks listed),
**Protect release tags** (no bypass; deletion, update, force-push), **Create release tags** (bypass: Repository
admin and Maintain roles; creation), and
Settings → Environments → **release** (Deployment branches and tags: `main`, tag `v*`) and **smoke-test**
(`main` only; [Smoke test email](#smoke-test-email)). Then:

- `git push origin HEAD:main` from a clone is rejected (`GH013: Repository rule violations`);
- a PR with a failing required check can't be merged;
- Flux's next dev image commit still lands (`git log origin/main --author=fluxcdbot`, or
  `flux get image update`).

**Two approvals later**: `scripts/protect-main.sh --approvals 2` (also dismisses stale approvals and requires the
last push to be approved by someone else). **Emergency**: Settings → Rules → Rulesets → Protect main → Enforcement
status *Disabled*, merge the fix by PR, then run `scripts/protect-main.sh` again to restore it.

### Release secrets

The two release secrets belong to the `release` environment, so only `main` and `v*` tags can use them
(git-workflow.md, "The release environment"): `DOCKERHUB_TOKEN` (CI's `push images` and sign-off) and
`PROMOTION_TOKEN` (CI's `open the QA promotion PR`, the smoke test's `Sign-off PR` and sign-off). **Human**, once, after `scripts/protect-main.sh`
created the environment (`gh secret set` prompts for each value, so it never lands in shell history):

```sh
gh secret set DOCKERHUB_TOKEN --env release --repo pkhamdee/modernapp   # a Docker Hub access token, Read & Write
gh secret set PROMOTION_TOKEN --env release --repo pkhamdee/modernapp   # the fine-grained token (Promotion token)
gh secret list --env release --repo pkhamdee/modernapp                  # both listed
# then remove the repository-level copies, which any workflow on any branch could read:
gh secret delete DOCKERHUB_TOKEN --repo pkhamdee/modernapp
gh secret delete PROMOTION_TOKEN --repo pkhamdee/modernapp              # if it was ever set there
gh secret list --repo pkhamdee/modernapp                                # neither listed
```

The variable `DOCKERHUB_USERNAME` stays a repository variable (not secret). An environment secret overrides a
repository secret of the same name, so the order above never leaves CI without a token. A run from another branch
that reaches one of these jobs fails with "Branch ... is not allowed to deploy to release"; so a release dry run
pushes only from `main` (from another branch `plan` skips the push, with a notice).

## Temporary copy (release gate)

Before CI pushes any image (`main` pushes, release-candidate tags, dry runs; never pull requests), it starts a **temporary
copy** of eShop from the images it has just built and pushes nothing unless the copy becomes healthy (ADR 0007). The
copy is one Compose file, `scripts/gates/temporary-copy/compose.yaml`: eshop-web, eshop-api, eshop-node-api,
PostgreSQL and thirdparty-mock behind a small gateway that routes like the cluster's HTTPRoutes (`/api`, `/images`,
`/thirdparty-mock/`, the rest to eshop-web), on plain HTTP. No sync master and no SQL Server, so the mock Enterprise
admin tool and the Enterprise sync don't work in it. Its data lives only in the containers and goes with `down`.

`up` waits until every part answers its probe, then checks through the gateway that the demo catalog and its photos
are there, that a Customer signs in by SMS code (read from the mock's inbox) and that Staff sign in, and seeds an open
Auction with a Lot (as dev has) through the Staff API (`temporary-copy/ready.mjs`). If anything fails it prints each
part's status and last log lines, writes them to `reports/temporary-copy/`, removes the copy and exits 1.

```sh
export DOCKER_HOST=unix://$HOME/.rd/docker.sock
scripts/gates/temporary-copy.sh build    # the four images from this checkout, as temporary-copy/<service>:local
scripts/gates/temporary-copy.sh up       # ~10 s; then http://localhost:8090 (Staff: staff / temporary-copy-staff)
scripts/gates/temporary-copy.sh down     # stop it and throw its data away

# The images CI built or pushed instead of local ones, e.g. to reproduce a failed gate:
ESHOP_API_IMAGE=docker.io/pkhamdee/eshop-api:main-93392bd scripts/gates/temporary-copy.sh up
#   also ESHOP_WEB_IMAGE, ESHOP_NODE_API_IMAGE, THIRDPARTY_MOCK_IMAGE; the newest main build of one:
scripts/gates/latest-main-image.sh docker.io/pkhamdee/eshop-web
```

Other settings (header of `scripts/gates/temporary-copy.sh`): `TEMPORARY_COPY_PORT` (default 8090),
`TEMPORARY_COPY_TIMEOUT_SECONDS` (180), `TEMPORARY_COPY_KEEP=1` to leave a copy that failed running for a look. The
SMS inbox is at `http://localhost:8090/thirdparty-mock/sms/inbox`. The Staff account, the database password and the
token signing key are throwaway values that exist only in the copy (Staff and the Node image: `temporary-copy/defaults.env`). To run the Playwright demo against it, set
`E2E_BASE_URL=http://localhost:8090 E2E_MOCK_URL=http://localhost:8090 E2E_ENV=dev STAFF_USERNAME=staff
STAFF_PASSWORD=temporary-copy-staff`; its two
Enterprise sync steps can't pass there.

## Repo layout

| Path | What | Flux Kustomization |
| --- | --- | --- |
| `clusters/local/` | Cluster entry point: `flux-system/` (generated by bootstrap) plus the Kustomizations below | `flux-system` |
| `clusters/local/prod-release.yaml` | What `eshop-prod` runs, the **prod pin**: GitRepository `eshop-release` (one release tag) and Kustomization `apps-prod` with that release's `X.Y.Z` images; the `# release-pin: prod` lines change only in a promotion PR (`scripts/pin-release.sh`) | `flux-system` |
| `clusters/local/qa-release.yaml` | What `eshop-qa` runs, the **QA pin**, same shape: GitRepository `eshop-qa` (one release-candidate tag) and Kustomization `apps-qa` with its `X.Y.Z-rc.N` images; the `# release-pin: qa` lines change only in a QA promotion PR. Suspended until the first one | `flux-system` |
| `deploy/infrastructure/controllers/` | Namespaces, Traefik `HelmChartConfig` (Gateway API provider), cert-manager, CloudNativePG operator, Actions Runner Controller | `infra-controllers` |
| `deploy/infrastructure/configs/` | Issuers, the `eshop` Gateway and its certificate, platform secrets | `infra-configs` (after controllers) |
| `deploy/infrastructure/runners/` | The E2E job's runner scale set `eshop-e2e`, its service account's permissions and its GitHub token ([Cluster runner](#cluster-runner)) | `infra-runners` (after controllers; nothing depends on it) |
| `deploy/apps/base/` | One directory per app, environment-neutral | – |
| `deploy/apps/dev/` | `eshop-dev` overlay, follows `main` | `apps-dev` (after configs) |
| `deploy/apps/dev/image-automation.yaml` | Flux image automation: newest `main-<sha>-<ts>` image per service, committed back to `main` | `apps-dev` |
| `deploy/apps/prod/` | `eshop-prod` overlay, applied as it is in the pinned release tag, served at `prod.eshop.localhost` | `apps-prod` (after configs; source `eshop-release`) |
| `deploy/apps/qa/` | `eshop-qa` overlay (a copy of prod's), applied as it is in the pinned release-candidate tag, served at `qa.eshop.localhost` | `apps-qa` (after configs; source `eshop-qa`) |
| `deploy/thirdparty/` | Shared mocks in the `thirdparty` namespace, one folder per component (`thirdparty-mock/`, `samba/`: image share with one share per environment, `mssql/`: mock Enterprise System, ...); thirdparty-mock follows `main` via its own image automation | `thirdparty` (after configs) |
| `services/eshop-api/` | .NET solution: `src/Eshop.Domain`, `src/Eshop.Data` (EF Core, migrations), `src/Eshop.Api`, `src/Eshop.SyncMaster` (eshop-sync-master), `tests/Eshop.Api.Tests` (Seam 1), `tests/Eshop.SyncMaster.Tests` (Seam 2) | – |
| `services/eshop-web/` | React + Vite + TypeScript, served by Caddy | – |
| `services/thirdparty-mock/` | Node 24 + Express (TypeScript run directly): mock SMS (+ inbox page), ID Verification and Credit Check; adjustable delay; mock Enterprise System admin tool | – |
| `services/eshop-node-api/` | Image service: Node 24 + Express + TypeScript (run directly by Node), SMB share via `smbclient` | – |
| `e2e/` | Seam 4: Playwright smoke test of the whole demo against a deployed environment (`npm run e2e`) | – |
| `scripts/` | Repo tasks: `release.sh X.Y.Z-rc.N` cuts a release candidate (human-run); `promotion-pr.sh <env> <version>` opens a promotion PR (CI); `sign-off-pr.sh` opens and closes sign-off PRs (e2e.yml); `sign-off.sh` signs off a candidate when its sign-off PR is merged (sign-off.yml); `protect-main.sh` sets `main`'s ruleset and the `release` environment (admin-run); tests of all of them in `tests/release-scripts.sh`; `lib/` holds what they share, sourced: `versions.sh` (the version grammar: X.Y.Z, X.Y.Z-rc.N, 0.0.0-test.N, and which environment takes which), `repo.sh` (the GitHub repository and image registry, env-overridable), `images.sh` (the image list in PR and Release bodies), `qa.sh` (QA's pin and Deployments, the evidence sign-off reads); `validate-manifests.sh` builds and schema-checks every Flux path (also CI's `repo rules` job) | – |
| `releases/` | One record per release, `X.Y.Z.md`: the signed-off candidate, its image digests, QA's passing run and Deployment. Added by the sign-off PR (`scripts/sign-off-pr.sh`); merging it signs off (git-workflow.md, "Sign-off") | – |
| `scripts/gates/` | Release gates (ADR 0007), one script each, tool from a pinned image, report in `reports/<gate>/`: `sast.sh` (Semgrep), `deps.sh` (Trivy over the lockfiles), `temporary-copy.sh` (the temporary copy, Compose file in `temporary-copy/`; see [Temporary copy](#temporary-copy-release-gate)), `latest-main-image.sh`, `image-scan.sh` (Trivy on built images), `perf.sh` (Locust; load, thresholds and locustfile in `perf/`), `dast.sh` (OWASP ZAP against the copy, signed out and as a Customer and Staff via `dast-session.mjs`; accepted alerts in `dast-rules.conf`). See [Running the gates locally](#running-the-gates-locally) | – |
| `.github/services.json` | Container images CI builds (context, Dockerfile, source paths): changed ones on `main`, all of them on a release-candidate tag | – |

Every Kustomization decrypts SOPS (`*.sops.yaml`) with `flux-system/sops-age` where needed and prunes only what it applied, so other workloads in the cluster are untouched.

## Developing

```sh
# eshop-api + eshop-sync-master (.NET 10). Tests start PostgreSQL (and, for sync-master's Seam-2 tests, SQL Server
# amd64 under Rosetta: enable Rosetta in Rancher Desktop) with Testcontainers.
export DOCKER_HOST=unix://$HOME/.rd/docker.sock
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock   # Rancher Desktop: socket path inside the VM
cd services/eshop-api
dotnet test
dotnet format --verify-no-changes                                   # lint, as CI runs it
dotnet tool restore && dotnet ef migrations add <Name> --project src/Eshop.Data

# Run locally: a PostgreSQL on localhost:5432 (user/password/db eshop), then
docker run -d --name eshop-pg -p 5432:5432 -e POSTGRES_USER=eshop -e POSTGRES_PASSWORD=eshop -e POSTGRES_DB=eshop postgres:18-alpine
dotnet run --project src/Eshop.Api                                  # http://localhost:5080, migrates and seeds
# eshop-sync-master needs a SQL Server on localhost:1433 with enterprise_dev and the schema (appsettings.Development.json):
docker run -d --name enterprise-sql --platform linux/amd64 -p 1433:1433 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=Local_Dev_Passw0rd mcr.microsoft.com/mssql/server:2022-CU27-ubuntu-22.04
#   then create enterprise_dev and run ../../deploy/thirdparty/mssql/enterprise-schema.sql in it (sqlcmd -d enterprise_dev -i ...)
dotnet run --project src/Eshop.SyncMaster                           # pushes every 30 s; probes on http://localhost:5090/healthz/ready

# eshop-web (Node 24)
cd services/eshop-web
npm ci && npm run dev                                               # proxies /api to localhost:5080
npm run lint && npm run build                                       # as CI runs it

# thirdparty-mock (Node 24). eshop-api's Development settings point ThirdParty:BaseUrl at localhost:4000.
cd services/thirdparty-mock
npm ci && npm run dev                                               # http://localhost:4000/sms/inbox
# Enterprise admin tool locally: ENTERPRISE_SQL_SERVER=localhost ENTERPRISE_SQL_USER=sa ENTERPRISE_SQL_PASSWORD=... npm run dev
npm run lint && npm run typecheck
# eshop-node-api (Node 24). Tests use a temporary folder instead of the SMB share.
cd services/eshop-node-api
npm ci && npm run lint && npm test                                  # as CI runs it
npm run dev                                                         # http://localhost:8081, images in ./.local-share
```

### Running the gates locally

The gates in `scripts/gates/` run exactly as CI runs them (jobs `sast` and `deps` in `ci-release.yml`, on every PR,
push and tag). Each needs only git and Docker: it pulls its tool's pinned image, writes its reports to
`reports/<gate>/` (git-ignored; CI uploads them as the `sast-report` and `deps-report` artifacts) and exits non-zero
when the gate fails. Downloads (Semgrep rules, Trivy's database) are cached in `~/.cache/eshop-gates`.

```sh
export DOCKER_HOST=unix://$HOME/.rd/docker.sock
scripts/gates/sast.sh     # Semgrep CE: fails on an ERROR finding; reports/sast/summary.txt lists every finding
scripts/gates/deps.sh     # Trivy over every lockfile: fails on a CRITICAL vulnerability; reports/deps/trivy.txt
```

- **SAST** scans `services`, `e2e`, `scripts`, `.github`, `deploy` and `clusters` (test code included) with the
  semgrep-rules repository at a pinned commit (`RULES_COMMIT` in `sast.sh`). WARNING and INFO findings are reported,
  never blocking. To accept a false positive, add `rule-id | path-glob | reason` to
  `scripts/gates/sast-accepted.txt`; the reason is required, and inline `nosemgrep` comments are ignored. Paths
  skipped inside those folders are in `.semgrepignore`.
- **Dependency scan** reads the npm `package-lock.json` files (dev dependencies included) and eshop-api's NuGet
  `packages.lock.json` files. Those exist because `Directory.Build.props` sets `RestorePackagesWithLockFile`: after
  changing a package in `Directory.Packages.props`, run `dotnet restore` and commit the updated lock files (CI
  restores with `--locked-mode` and fails on a stale one). Every severity is in the report; only CRITICAL fails,
  fixed or not, as in the image scan.
- **Image scan** (`image-scan.sh`, CI: the `scan` job, one per image, artifact `image-scan-report-<service>`) runs
  Trivy on built images from their docker archives, before any is pushed; fails on a CRITICAL finding, fixed or
  not. Reports: `reports/image-scan/<name>.txt` and `.json`.

  ```sh
  scripts/gates/temporary-copy.sh build
  docker save temporary-copy/eshop-api:local -o /tmp/eshop-api.tar && scripts/gates/image-scan.sh /tmp/eshop-api.tar
  ```
- **Temporary copy** (`temporary-copy.sh`, the copy the image gates run against): see
  [Temporary copy](#temporary-copy-release-gate).
- **Performance** (`perf.sh`, CI: the `gate` job, artifact `perf-report`) runs Locust headless from its pinned image
  against a running temporary copy, on the copy's Compose network: about 50 Customers for 60 s over the catalog,
  Products, sign-in by SMS code (each user with its own mobile number), and the Auction and its Lots. It fails when
  the p95 of all requests is over 500 ms or more than 1% of them failed. Staff sign-in is left out on purpose: its
  password check is deliberately slow. The load and the thresholds are in `scripts/gates/perf/locust.conf`; the
  flows in `locustfile.py` beside it. `reports/perf/summary.txt` gives the verdict and the slowest endpoints;
  `locust.html` and `locust_*.csv` the per-endpoint numbers.

  ```sh
  scripts/gates/temporary-copy.sh build && scripts/gates/temporary-copy.sh up
  scripts/gates/perf.sh                              # ~70 s
  LOCUST_RUN_TIME=15s LOCUST_USERS=10 scripts/gates/perf.sh   # any locust.conf value, for one run
  scripts/gates/temporary-copy.sh down
  ```

  With a copy started under another project name (`TEMPORARY_COPY_PROJECT`), run `perf.sh` with the same variable
  so it joins that copy's network; `PERF_NETWORK` and `PERF_HOST` point it anywhere else.
- **DAST** (`dast.sh`, OWASP ZAP, signed out and signed in) runs against a running temporary copy, on its Compose
  network, in the `gate` job after Locust (artifact `dast-report`):

  ```sh
  scripts/gates/temporary-copy.sh up
  scripts/gates/dast.sh       # ~2 min; reports/dast/summary.txt, <scan>.html/json, <scan>-requests.tsv
  scripts/gates/temporary-copy.sh down
  ```

  Four scans: a ZAP **baseline** (spider plus passive rules) of the web app through the gateway, and three ZAP **API
  scans** (ZAP's API-Minimal active rules) of every operation in eshop-api's OpenAPI description, sent through the
  gateway: **signed out**, **as a Customer** and **as Staff**. The description is `/openapi/v1.json` on eshop-api,
  served only when `OpenApi__Enabled=true`, which only the copy's `compose.yaml` sets (the cluster never does, and
  the Gateway routes only `/api`). The sessions are obtained as a Customer or Staff member would, inside the copy only
  (`scripts/gates/dast-session.mjs`): the Customer by SMS code read from thirdparty-mock's inbox, with a fresh mobile
  number per run; Staff with the copy's throwaway account (`TEMPORARY_COPY_STAFF_USERNAME` / `_PASSWORD`, default in
  `scripts/gates/temporary-copy/defaults.env`:
  `staff` / `temporary-copy-staff`). ZAP sends the token as `Authorization: Bearer ...` on every request to the
  gateway. The signed-in scans change the copy's data (they submit, bid, add Branches, retire and reinstate
  Products), which is why they run last, Customer before Staff; tokens are stateless and Staff sign-in has no lockout,
  so a scan can't lose its session.

  The gate fails on any High-risk alert; Medium, Low and Informational ones are in the reports only. It also fails
  when a signed-in scan got **no 2xx answer from an endpoint only its role may use** (`CUSTOMER_ONLY` /
  `STAFF_ONLY` path patterns in `dast.sh`), so a sign-in that silently stopped working can't pass as a clean scan;
  `summary.txt` lists, per role, the role-only endpoints reached with 2xx (from `<scan>-requests.tsv`, every request
  ZAP kept, written by the hook `dast-hook.py`). A sign-in that fails outright (a wrong Staff password) stops the
  gate before the scan. To accept an alert, add its rule to `scripts/gates/dast-rules.conf` (ZAP's tab-separated
  `-c` format: `id IGNORE (name)`, or `id OUTOFSCOPE url-regex` for some URLs) under a `# reason: ...` comment; a
  rule without a reason fails the gate. For a copy started with another `TEMPORARY_COPY_PROJECT`, export the same
  value for `dast.sh`. `DAST_SCANS` picks the scans, e.g. `DAST_SCANS=customer` or `DAST_SCANS='api staff'`.
- To prove a gate still bites, plant a fault locally (a C# `new SqlCommand($"... {input}", ...)`, a lockfile
  entry such as lodash 4.17.4, an `await Task.Delay(800)` in a catalog endpoint, or a response header leaking a
  password hash in eshop-web's `Caddyfile`, `X-Debug-Hash "$2a$10$..."`, for DAST; the same header set in a
  Customer-only handler such as `ListContracts` is caught only by the Customer scan), rebuild that image and restart
  the copy, run the gate, see it fail, and revert. Never commit the plant.

## Troubleshooting

```sh
flux get all -A                             # anything not Ready
flux logs --level=error
flux reconcile kustomization flux-system --with-source
kubectl -n kube-system get job helm-install-traefik   # Traefik config re-applied by k3s
kubectl describe gateway -n gateway eshop
```

**Cluster clock behind after the Mac sleeps (#65).** The Rancher Desktop VM runs no time sync, so when the Mac sleeps
(lid closed, or idle on battery) the VM's clock stays behind by the time it slept. The e2e suite sets Auction times
from the Mac's clock, so it stops at the start with "The cluster's clock is N s behind this machine's". Check and fix:

```sh
date -u; rdctl shell date -u                # should agree to the second
rdctl shutdown && rdctl start               # or quit and reopen Rancher Desktop: the VM boots with the Mac's time
```

Keep the Mac awake for a whole e2e run: lid open, or `caffeinate -dis npm run e2e`.
