#!/usr/bin/env bash
# Workstation: extract ztunnel + Debian libs from the official image (for RHEL 9.6 glibc 2.34 hosts).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ZTUNNEL_VERSION:=1.28.6}"
TAG="${ZTUNNEL_VERSION#v}"
IMAGE="${ZTUNNEL_IMAGE:-docker.io/istio/ztunnel:${TAG}}"
OUT_DIR="${OUT_DIR:-${ROOT}/vsi-onboarding}"
OUT_BIN="${OUT_BIN:-${OUT_DIR}/ztunnel}"
OUT_LIBS="${OUT_LIBS:-${OUT_DIR}/ztunnel-libs}"

if ! command -v podman &>/dev/null; then
  echo "ERROR: podman required on the workstation to extract ztunnel" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
rm -rf "${OUT_LIBS}"
mkdir -p "${OUT_LIBS}"

cid="$(podman create --platform linux/amd64 "${IMAGE}")"
trap 'podman rm -f "${cid}" 2>/dev/null || true' EXIT

podman cp "${cid}:/usr/local/bin/ztunnel" "${OUT_BIN}"
chmod 0755 "${OUT_BIN}"

podman export "${cid}" | tar -xf - -C "${OUT_LIBS}" \
  ./usr/lib/x86_64-linux-gnu \
  ./usr/lib64/ld-linux-x86-64.so.2

echo "==> Wrote ${OUT_BIN}"
echo "==> Wrote libs under ${OUT_LIBS}/usr/lib/x86_64-linux-gnu"
