# Image SBOMs are unsigned CycloneDX referrers in the registry; signing waits for verification

Every image the pipeline pushes gets a CycloneDX JSON SBOM, made by Trivy from the same archive the image scan reads (`scripts/gates/sbom.sh`, the `scan` job) and attached to the image's digest in Docker Hub as an **unsigned OCI referrer** (`oras attach`, `scripts/gates/attach-sbom.sh`, the `push` job). The SBOM is a record, not a gate: what an image contains never fails the pipeline, but an image is never pushed if its SBOM couldn't be written. We want SBOMs so that, when a new CVE appears, we can tell which deployed or released images contain the package without pulling or rebuilding anything (`trivy sbom`), and so that each Release carries a record of what it ships.

**Why the registry, keyed by digest.** Candidates and releases are copies by digest in the same repository (ADR 0009), so an SBOM attached once to a `main-<sha>-<ts>` or `release-N.x-…` image also belongs to its `X.Y.Z-rc.N` and `X.Y.Z` tags, with nothing to copy or regenerate. Run artifacts expire after 90 days at most, so they could not serve a release that runs for longer. Where the registry doesn't serve the OCI referrers API, oras falls back to a `sha256-<digest>` tag. No tag filter matches it (Flux's `^main-…$`, `latest-main-image.sh`, `candidate-images.sh`), so nothing deploys or releases it.

**Why unsigned, for now.** A signed attestation (keyless cosign with GitHub's OIDC token) is the obvious alternative, and it is what cluster-side verification would need. But `service-image.yml` would need `id-token: write`, which a reusable workflow gets only if its caller grants it. So every service repository's `ci.yml` would have to change first (expand-then-contract across four repositories), and every signing would be published to the public Rekor log. Without a verifier, a signature protects nothing. Signing and verification are therefore one later decision (pkhamdee/eshop-infra#127), which can switch to `cosign attest --type cyclonedx` without changing how SBOMs are made.

## Consequences

- A re-run that pushes no image (#116) never replaces an existing SBOM. If the registry image has none, the re-run makes it from the registry digest, not from its own rebuild, which may differ.
- Each image, and so each release, is described only by what Trivy detects (OS packages and the language lockfiles in the image). What it can't see, such as a binary copied in by hand, isn't listed.
- Images pushed before this decision have no SBOM until they are rebuilt.
