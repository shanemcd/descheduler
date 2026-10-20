#!/usr/bin/env bash
# Build and push the tier-aware descheduler image (fork of
# kubernetes-sigs/descheduler at v0.37.0-tlsfix) to the OpenShift
# internal registry (via its default route).
#
# Usage:   ./hack/push-image.sh [tag]   (default tag: v0.37.0-tlsfix)
#
# Requires: oc logged in as cluster-admin (KUBECONFIG pointing at the
# cluster) and podman. The build is a multi-stage vendored Go build (no
# host toolchain needed).
#
# The image lands in the same registry namespace the deployment in
# cxl-memory-expansion/examples/descheduler-deployment.yaml references:
#   image-registry.openshift-image-registry.svc:5000/cxl-observability/descheduler:<tag>
#
# The default route serves the cluster ingress certificate, so the
# podman login/push below use --tls-verify=false. Pushes authenticate
# with a short-lived token of the image-pusher service account (never
# printed).
set -euo pipefail

TAG="${1:-v0.37.0-tlsfix}"
REGISTRY_NS="cxl-observability"
IMAGE="descheduler"

# 1. One-time (idempotent) cluster setup: enable the internal registry
#    with defaultRoute and PVC storage on the default StorageClass.
oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
  -p '{"spec":{"managementState":"Managed","storage":{"pvc":{"claim":null}},"defaultRoute":true}}' >/dev/null

ROUTE="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')"
FULL="${ROUTE}/${REGISTRY_NS}/${IMAGE}:${TAG}"
echo "pushing to ${FULL}"

# 2. Push credentials: image-pusher SA with registry-editor in the
#    registry namespace plus the image-builder cluster role. The
#    service account and grants are shared with the other lab workload
#    images (see memory-tier-exporter/hack/push-image.sh); creating
#    them again is a no-op.
oc create serviceaccount image-pusher -n "${REGISTRY_NS}" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create rolebinding image-pusher-registry-editor -n "${REGISTRY_NS}" \
  --clusterrole=registry-editor --serviceaccount="${REGISTRY_NS}:image-pusher" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create clusterrolebinding image-pusher-image-builder \
  --clusterrole=system:image-builder --serviceaccount="${REGISTRY_NS}:image-pusher" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

# 3. Build and push the image. The Dockerfile's build stage runs
#    `make build.$ARCH`, so ARCH must be passed (upstream CI does);
#    translate uname -m to the Go arch names the Makefile expects.
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
podman build --build-arg ARCH="${ARCH}" --build-arg VERSION="${TAG}" -t "${FULL}" .
printf '%s' "$(oc create token image-pusher -n "${REGISTRY_NS}" --duration=4h)" |
  podman login --tls-verify=false -u image-pusher --password-stdin "${ROUTE}" >/dev/null
podman push --tls-verify=false "${FULL}"
echo "pushed ${FULL}"
