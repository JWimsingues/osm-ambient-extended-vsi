#!/usr/bin/env bash
# Build the three Java microservices and push images to Quay.io.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

: "${QUAY_REGISTRY:=quay.io}"
: "${QUAY_ORG:?Set QUAY_ORG to your Quay organization or username}"
: "${IMAGE_TAG:=latest}"
: "${CONTAINER_CMD:=podman}"

SERVICES=(ms-a ms-b ms-c)

echo "==> Maven build (all modules)"
mvn -q clean package -DskipTests

for svc in "${SERVICES[@]}"; do
  image="${QUAY_REGISTRY}/${QUAY_ORG}/osm-poc-${svc}:${IMAGE_TAG}"
  echo "==> Building ${image}"
  ${CONTAINER_CMD} build -f "${svc}/Containerfile" -t "${image}" "${svc}"
  echo "==> Pushing ${image}"
  ${CONTAINER_CMD} push "${image}"
done

echo "Done. Images pushed:"
for svc in "${SERVICES[@]}"; do
  echo "  ${QUAY_REGISTRY}/${QUAY_ORG}/osm-poc-${svc}:${IMAGE_TAG}"
done
