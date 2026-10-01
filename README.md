# devsecops-demo

**English** | [中文](README.zh-CN.md)

[![release](https://github.com/lai3d/devsecops-demo/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/lai3d/devsecops-demo/actions/workflows/release.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lai3d/devsecops-demo/badge)](https://scorecard.dev/viewer/?uri=github.com/lai3d/devsecops-demo)

A small Go service wrapped in a secure software supply chain: every change is scanned before merge, every release is signed and carries an SBOM, and the cluster admits only images signed by this repository's release workflow. A throwaway cluster on each release proves all of it end to end.

```
pull request ─▶ gitleaks ─▶ semgrep ─▶ zizmor ─▶ go test + govulncheck ─▶ trivy fs ─▶ trivy image
                (secrets)   (SAST)     (workflow    (unit tests, reachable    (deps, IaC,    (built
                                        audit)       Go CVEs)                  secrets)       image)

merge to main ─▶ same gates ─▶ push to GHCR by digest ─▶ cosign sign (keyless, OIDC)
              ─▶ Syft SBOM ─▶ cosign attest ─▶ SLSA provenance ─▶ verify all ─▶ trivy sbom
              ─▶ kind + Cilium ─▶ Kyverno admission tests ─▶ Argo CD deploy ─▶ Tetragon detection
```

## What each gate proves

| Stage | Tool | Fails the build when |
|---|---|---|
| Secrets | gitleaks (full history) | a credential appears in any commit |
| SAST | Semgrep: `p/golang`, `p/dockerfile`, `p/github-actions`, `p/kubernetes` | a rule matches |
| SAST | CodeQL `security-extended` (Go, Actions) | results in the Security tab; runs on PRs, main and weekly |
| Workflow audit | zizmor | a workflow has a medium+ issue: template injection, over-broad permissions, credential persistence |
| SCA | govulncheck | the code **reaches** a known-vulnerable Go function, including the standard library |
| SCA + IaC | Trivy `fs` | HIGH/CRITICAL fixable CVE, or misconfiguration in Dockerfile, Helm chart, Kubernetes YAML or Terraform |
| Image | Trivy `image` | HIGH/CRITICAL fixable CVE in the built image |
| Sign | cosign keyless | — signs with the workflow's GitHub OIDC identity; no key to store or leak |
| SBOM | Syft → cosign attest | — CycloneDX SBOM attached to the image as a signed attestation |
| Provenance | GitHub artifact attestation (SLSA build provenance), pushed to GHCR | — records which workflow, commit and runner built the digest |
| Verify | cosign verify / verify-attestation, `gh attestation verify` | the signature, SBOM attestation or provenance is not from `release.yml` on `main` |
| Admission | Kyverno `ImageValidatingPolicy` + `ValidatingPolicy` | see the admission tests below |
| Deploy | Argo CD | the app is not `Synced/Healthy` on the signed digest |
| Runtime | Tetragon `TracingPolicy` | a read of `/etc/shadow` in a pod is **not** reported |

### Admission tests (`scripts/e2e-admission.sh`)

All run against the `demo` namespace, which enforces Pod Security `restricted` and opts into the supply-chain policies.

| Pod image | Expected |
|---|---|
| `docker.io/library/nginx:latest` | denied: wrong registry, not by digest |
| `ghcr.io/lai3d/devsecops-demo:sha-…` (signed, but by tag) | denied: not by digest |
| `ghcr.io/lai3d/devsecops-demo@sha256:…` (unsigned) | denied: not signed by the release workflow |
| `ghcr.io/lai3d/devsecops-demo@sha256:…` (signed) | admitted |

## Hardening in the repository itself

- Every action is pinned to a full commit SHA; every container image is pinned by digest; Dependabot proposes updates for actions, images, Go modules and Terraform providers.
- Scanners run as digest-pinned containers rather than through third-party actions, keeping fewer third-party actions in the trusted path.
- Workflows default to `permissions: {}`; each job asks for only what it needs, and `id-token: write` exists only on the signing job.
- `actions/checkout` runs with `persist-credentials: false`.
- `main` is protected: changes land only through a pull request with all six CI gates green, admins included; no force pushes.
- No cloud keys are stored anywhere. AWS access, when enabled, is OIDC federation scoped to `main` of this repository (`infra/aws-github-oidc`).

## Runtime hardening (Helm chart)

Deploy by digest · non-root UID 65532 · read-only root filesystem · all capabilities dropped · no privilege escalation · `RuntimeDefault` seccomp · no service account token · default-deny `NetworkPolicy` (ingress on 8080 from the namespace only, no egress) · distroless base image with no shell.

## Layout

```
cmd/server/              Go service (net/http, stdlib only)
Dockerfile               multi-stage, distroless, digest-pinned bases
deploy/helm/             hardened chart
deploy/cluster/          kind config (Cilium CNI) and the enforced namespace
deploy/argocd/           Argo CD repository + Application templates
policies/kyverno/        signature verification, digest + registry restriction
policies/tetragon/       sensitive file access detection
infra/aws-github-oidc/   Terraform: GitHub OIDC provider + main-only role
scripts/                 admission tests
docs/threat-model.md     STRIDE threat model and the controls above
```

## Running it

- **Pull requests** run `ci.yml`.
- **Merging to `main`** runs `release.yml`: the gates again, then publish, sign, attest, and the end-to-end cluster test.
- **AWS federation** (optional): `terraform -chdir=infra/aws-github-oidc apply` with an admin profile, set the repository variable `AWS_ROLE_ARN` to the `role_arn` output, then run the `aws-oidc-check` workflow from `main`.
- **Locally**: `go test ./...`, and `pre-commit install` for the gitleaks hook.

## Notes

- Keyless signing writes an entry to the public Rekor transparency log naming this repository, the workflow and the commit.
- The e2e job pushes a deliberately unsigned image tagged `e2e-unsigned` to the same package, so the signature policy has something to reject.
- Verify a release yourself:
  ```
  cosign verify ghcr.io/lai3d/devsecops-demo@sha256:<digest> \
    --certificate-identity https://github.com/lai3d/devsecops-demo/.github/workflows/release.yml@refs/heads/main \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  gh attestation verify oci://ghcr.io/lai3d/devsecops-demo@sha256:<digest> --repo lai3d/devsecops-demo
  ```

## Threat model

See [docs/threat-model.md](docs/threat-model.md).

## License

[Apache-2.0](LICENSE)
