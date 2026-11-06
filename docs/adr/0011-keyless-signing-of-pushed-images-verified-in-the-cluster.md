# Images are signed keyless by the pipeline that pushed them, and the cluster runs only those

Anyone holding the Docker Hub token could push `docker.io/pkhamdee/<service>:main-<anything>-<ts>`, and Flux would deploy it to `eshop-dev` within minutes. We want the cluster to run only eShop images that `eshop-infra`'s pipeline built and gated. So `service-image.yml`'s `push` job signs **each digest it just pushed** with keyless cosign (`scripts/gates/sign-images.sh`). The signature's identity is the run's GitHub OIDC token: workflow `pkhamdee/eshop-infra/.github/workflows/service-image.yml@refs/heads/main`, source repository one of the four service repositories, ref `main` or `release/*`. The signature is logged in the public Rekor log. Sigstore's policy-controller in the cluster admits a `pkhamdee/*` image only with that signature (pkhamdee/eshop-infra#127). A stolen Docker Hub token can push, but it can't produce that identity.

**Why keyless.** A key pair would mean a private key in every service repository's `publish` environment, to store, rotate and leak; whoever holds it can sign anything. Keyless has no key at all. It costs an `id-token: write` grant in each caller's `ci.yml` (a called workflow gets nothing its caller didn't grant) and public Rekor entries, which reveal nothing the public images don't.

**Why only what this run pushed.** A re-run that skips an existing tag (#116) signs nothing, even if that image is unsigned. Signing whatever a tag names would vouch for an image someone else pushed, which is exactly the attack. The SBOM re-run path makes an SBOM from the registry image (ADR 0010), but an SBOM only describes; a signature vouches. The cost: if signing fails after a push, the image stays unsigned for good, and the fix is a new commit. Likewise there is **no backfill**: images pushed before signing stay unsigned, and each namespace switches from warn to enforce only once everything it runs is signed. Once prod enforces, rolling back to a release from before signing means switching prod back to warn first.

**Why the classic signature format, with cosign v2.** cosign v3 always writes the newer Sigstore bundle (as an OCI referrer). policy-controller 0.15.1, the newest, verifies the classic `sha256-<digest>.sig` tag, and its bundle support is still an open issue (sigstore/policy-controller#1406). So we sign with cosign v2.6.5, whose default is the classic format. We'll move to cosign v3 once policy-controller verifies bundles.

## Considered options

- **Sign SBOM attestations too** (`cosign attest --type cyclonedx`): deferred. Signing images is what stops a foreign image from running. An unsigned SBOM (ADR 0010) can be replaced by someone with the Docker Hub token, but it can't make the cluster run anything. Revisit if someone outside eShop starts relying on the SBOMs.
- **Kyverno** instead of policy-controller: it can do the same, but it's a general policy engine; policy-controller does this one job, with less to run on a laptop cluster.

## Consequences

- Candidate and release tags are copies by digest in the same repository, so they carry the signature with nothing to copy.
- `ci-release.yml` builds nothing today and its identity isn't trusted; if it ever builds, it must sign the same way and be added to the policy.
- Verifying an image by hand: `cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity https://github.com/pkhamdee/eshop-infra/.github/workflows/service-image.yml@refs/heads/main <image>@<digest>`.
