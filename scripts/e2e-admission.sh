#!/usr/bin/env bash
# Admission tests for the "demo" namespace. Each case submits a Pod with a
# server-side dry run, so nothing is scheduled; the API server still runs
# Pod Security and the Kyverno webhooks.
#
# Requires: IMAGE, IMAGE_DIGEST (signed), UNSIGNED_DIGEST (pushed, unsigned).
set -euo pipefail

: "${IMAGE:?}" "${IMAGE_DIGEST:?}" "${UNSIGNED_DIGEST:?}"

pod() {
  # A Pod that satisfies Pod Security "restricted", so any denial comes from
  # the supply-chain policies.
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: admission-test
  namespace: demo
spec:
  automountServiceAccountToken: false
  imagePullSecrets: [{name: ghcr-pull}]
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: c
      image: $1
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
EOF
}

expect_denied() { # name image expected-message
  local out
  if out=$(pod "$2" | kubectl apply --dry-run=server -f - 2>&1); then
    echo "FAIL  $1: admitted, expected denial"; return 1
  fi
  if ! grep -q "$3" <<<"$out"; then
    echo "FAIL  $1: denied for the wrong reason:"; echo "$out"; return 1
  fi
  echo "PASS  $1: denied ($3)"
}

expect_admitted() { # name image
  local out
  if ! out=$(pod "$2" | kubectl apply --dry-run=server -f - 2>&1); then
    echo "FAIL  $1: denied, expected admission:"; echo "$out"; return 1
  fi
  echo "PASS  $1: admitted"
}

# Policies take a few seconds to register their webhooks after apply.
for _ in $(seq 30); do
  if ! pod "docker.io/library/nginx:latest" | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

fail=0
expect_denied   "other registry"      "docker.io/library/nginx:latest"   "referenced by digest" || fail=1
expect_denied   "tag, not digest"     "$IMAGE:sha-${GITHUB_SHA:-latest}" "referenced by digest" || fail=1
expect_denied   "unsigned digest"     "$IMAGE@$UNSIGNED_DIGEST"          "not signed"           || fail=1
expect_admitted "signed digest"       "$IMAGE@$IMAGE_DIGEST"                                    || fail=1
exit "$fail"
