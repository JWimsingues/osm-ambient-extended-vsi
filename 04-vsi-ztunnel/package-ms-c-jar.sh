#!/usr/bin/env bash
# Workstation: build fat JAR for native ms-c on the VSI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MS_ROOT="${ROOT}/../microservices"
OUT_DIR="${OUT_DIR:-${ROOT}/vsi-onboarding}"
JAR_NAME="${JAR_NAME:-ms-c-1.0.0-SNAPSHOT.jar}"

if ! command -v mvn &>/dev/null; then
  echo "ERROR: mvn required to build ms-c JAR" >&2
  exit 1
fi

mvn -q -f "${MS_ROOT}/pom.xml" package -pl ms-c -am
install -d -m 0755 "${OUT_DIR}"
install -m 0644 "${MS_ROOT}/ms-c/target/${JAR_NAME}" "${OUT_DIR}/${JAR_NAME}"
echo "==> Wrote ${OUT_DIR}/${JAR_NAME}"
