# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub's private vulnerability reporting:
[Report a vulnerability](https://github.com/lai3d/devsecops-demo/security/advisories/new) (Security tab → Report a vulnerability).
Do not open a public issue for a security problem.

Include what you found, how to reproduce it, and what an attacker could do with it.

## What is in scope

- The Go service in `cmd/server`
- The release pipeline: a way to get an unsigned or wrongly signed image admitted, to make `release.yml` sign something it should not, or to escalate a workflow token
- The Kyverno and Tetragon policies, the Helm chart, and the Terraform in `infra/`

Findings in upstream tools (Kyverno, Tetragon, cosign, Argo CD, Trivy and so on) belong with those projects.

## What to expect

This is a single-maintainer demonstration project, maintained on a best-effort basis.

- Acknowledgement: within 7 days
- Assessment and a fix or mitigation plan: within 30 days of acknowledgement for confirmed issues
- Disclosure: coordinated with the reporter, through a GitHub security advisory once a fix is released

## Supported versions

Only the latest image built from `main` is supported. Verify any image before trusting it; see "Verify a release yourself" in the [README](README.md#notes).
