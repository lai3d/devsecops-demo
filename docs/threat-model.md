# Threat model

Scope: the path from a commit to a running pod. The service itself is a trivial HTTP endpoint with no data, so the assets worth protecting are the **build and release path** and the **cluster's trust decision**.

## Data flow

```
developer ──commit──▶ GitHub repo ──PR──▶ ci.yml (GitHub-hosted runner)
                                   └─merge─▶ release.yml ──push──▶ GHCR (image + signature + SBOM)
                                                │ OIDC token                    │
                                                ▼                               ▼
                                     Fulcio / Rekor (Sigstore)        Kyverno (admission) ◀── Argo CD ◀── repo
                                                                                │
                                                                         pod in "demo" ──▶ Tetragon (runtime events)
```

Trust boundaries: developer machine → GitHub; GitHub runner → registry and Sigstore; registry → cluster; cluster API → workloads.

## STRIDE

| Threat | Example | Controls in this repo | Residual risk / next step |
|---|---|---|---|
| **S**poofing | An attacker pushes an image to GHCR under this name and gets it deployed | Kyverno admits only images signed with the identity `release.yml@refs/heads/main` from `token.actions.githubusercontent.com` | A compromised `main` can still produce a validly signed image: branch protection and required reviews are the control |
| **S**poofing | A workflow in a fork or another branch assumes the AWS role | Trust policy pins `aud` and `sub = repo:lai3d/devsecops-demo:ref:refs/heads/main` | — |
| **T**ampering | Image changed in the registry after signing | Deploy by digest only; signature is bound to the digest | — |
| **T**ampering | A compromised third-party action or scanner image | Actions pinned by SHA, images by digest, Dependabot for updates; scanners run as containers, not actions; zizmor audits workflows | Pinned code can still be malicious; review Dependabot diffs |
| **T**ampering | Malicious dependency | govulncheck + Trivy on every PR; SBOM attached to each release and rescanned | Zero-days are not in any database |
| **R**epudiation | "Who built this image?" | Rekor entry ties the signature to repository, workflow, commit and run; Argo CD records which revision deployed | — |
| **I**nformation disclosure | Secret committed to Git | gitleaks over full history in CI, pre-commit hook locally | Rotate on any hit; history rewrite is not enough |
| **I**nformation disclosure | Long-lived cloud keys stolen from CI | No stored cloud keys; OIDC with one-hour sessions | — |
| **I**nformation disclosure | Pod reads node or cluster credentials | No service account token mounted; non-root; read-only filesystem; Tetragon reports reads of credential files | Tetragon reports; it is not configured to kill. Enforcement (`Sigkill` action) is a next step |
| **D**enial of service | Slowloris against the service | Server read/write/idle timeouts, header size limit; resource limits on the pod | No rate limiting; not in scope for the demo |
| **E**levation of privilege | Container escape via capabilities or root | Pod Security `restricted` enforced by the API server; capabilities dropped; no privilege escalation; seccomp `RuntimeDefault`; distroless image with no shell | — |
| **E**levation of privilege | Workflow token abused to push or write | `permissions: {}` by default; per-job least privilege; `id-token: write` only on the signing job; `persist-credentials: false` | — |

## Not covered

- Branch protection and required reviews: repository settings rather than code. Enable them before relying on the signature identity.
- SLSA build provenance: GitHub artifact attestations need a public repository on this plan. Add `actions/attest-build-provenance` once public.
- DAST: the service exposes two endpoints with no input; a ZAP baseline scan becomes worthwhile once there is real surface.
