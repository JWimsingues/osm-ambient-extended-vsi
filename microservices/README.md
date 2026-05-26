# Microservices (Java / OpenJDK 21)

Three minimal Java HTTP services for the OSM ambient PoC. Images use [Red Hat OpenJDK](https://catalog.redhat.com/software/containers/ubi9/openjdk-21/618bdb57384eaa4163298ae0) on UBI 9.

## Services

| Directory | Role | Default downstream |
|---|---|---|
| `ms-a` | Chain entry; calls B | `MS_B_URL` |
| `ms-b` | Middle tier; calls C | `MS_C_URL` |
| `ms-c` | Edge on VSI; calls A | `MS_A_URL` |

## Build locally

```bash
mvn clean package -DskipTests
```

## Build and push to Quay

```bash
export QUAY_ORG=your-org
export IMAGE_TAG=latest
./build-and-push.sh
```

Requires `podman` (or set `CONTAINER_CMD=docker`) and Quay credentials (`podman login quay.io`).

## Log format

Set `LOG_FORMAT=json` (default in OpenShift Deployments) for IBM Cloud Logs:

```json
{"timestamp":"...","level":"INFO","logtype":"osm-poc-app","service":"ms-a","traceId":"abc-123","action":"CALL_B","message":"ms-a is calling ms-b"}
```

Text mode (`LOG_FORMAT=text`) prints human-readable lines to stdout.

Pass `X-Trace-Id` on requests to correlate across all three services.

## Endpoints

| Service | Path | Description |
|---|---|---|
| All | `GET /health` | Liveness |
| All | `GET /api/info` | Metadata |
| ms-a | `GET /api/run-chain` | A→B→C→A |
| ms-a | `GET /api/call-b` | A→B only |
| ms-b | `GET /api/handle-from-a` | Called by A; forwards to C |
| ms-c | `GET /api/handle-from-b` | Called by B; forwards to A |
| ms-c | `GET /api/call-a` | Manual C→A from VSI |
