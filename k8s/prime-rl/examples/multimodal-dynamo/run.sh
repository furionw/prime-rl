#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/../.." && pwd)"
NAMESPACE="${NAMESPACE:-qiwa}"
KUBE_CONTEXT="${KUBE_CONTEXT:-nv-prd-dgxc.teleport.sh-dynamo-aws-dev-01}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_SLUG="$(printf '%s' "${RUN_ID}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
RUN_ROOT="${RUN_ROOT:-/data/qiwa/prime-rl-mm/${RUN_ID}}"
DYNAMO_REF="${DYNAMO_REF:-qiwa/generate-vllm-integration}"
PRIME_REPO="${PRIME_REPO:-https://github.com/furionw/prime-rl.git}"
PRIME_REF="${PRIME_REF:-qiwa/dynamo-k8s-mm-test}"
IMAGE_DIGEST="${IMAGE_DIGEST:-sha256:e1c59a9ab1fccc5851ccd69e70d04ab93d1490dcac448a591bf6d4296c2216a3}"
BASE_IMAGE="${BASE_IMAGE:-nvcr.io/nvstaging/ai-dynamo/vllm-runtime:qiwa-dev-vllm-arm64-07-09@${IMAGE_DIGEST}}"
LOCAL_LOG_ROOT="${LOCAL_LOG_ROOT:-${HOME}/workspace/dynamo-tmp/logs/07-09/multimodal-rl-k8s/${RUN_ID}}"
K=(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}")
K_ALL=(kubectl --context "${KUBE_CONTEXT}")

select_node() {
  local best=""
  local best_used=999
  while read -r node; do
    local used
    used="$("${K_ALL[@]}" get pods -A --field-selector="spec.nodeName=${node}" -o json |
      jq '[.items[] | select(.status.phase == "Running" or .status.phase == "Pending") |
        .spec.containers[].resources.requests["nvidia.com/gpu"] // "0" | tonumber] | add // 0')"
    if (( used < best_used )); then
      best="${node}"
      best_used="${used}"
    fi
  done < <("${K_ALL[@]}" get nodes -l nvidia.com/gpu.product=NVIDIA-GB200 -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [[ -z "${best}" || "${best_used}" -gt 1 ]]; then
    echo "No GB200 node currently has three unreserved GPUs" >&2
    return 1
  fi
  echo "${best}"
}

NODE_NAME="${NODE_NAME:-$(select_node)}"
BUILD_JOB="prime-mm-build-${RUN_SLUG}"
BUILD_JOB="${BUILD_JOB//[^a-z0-9-]/-}"

export NAMESPACE RUN_ID RUN_ROOT DYNAMO_REF PRIME_REPO PRIME_REF IMAGE_DIGEST BASE_IMAGE NODE_NAME BUILD_JOB

apply_template() {
  local template="$1"
  local vars='$NAMESPACE $RUN_ID $RUN_ROOT $DYNAMO_REF $PRIME_REPO $PRIME_REF $IMAGE_DIGEST $BASE_IMAGE $NODE_NAME $BUILD_JOB $RENDER_POD $STAGE $RELEASE_NAME $DOWNLOAD_POD $MODEL_NAME'
  envsubst "${vars}" < "${template}" | "${K_ALL[@]}" apply -f -
}

preflight() {
  "${K_ALL[@]}" get namespace "${NAMESPACE}" >/dev/null
  "${K[@]}" get pvc shared-model-cache -o jsonpath='{.status.phase}' | grep -qx Bound
  "${K[@]}" get secret ngc-pull-secret >/dev/null
  "${K_ALL[@]}" get node "${NODE_NAME}" >/dev/null
  mkdir -p "${LOCAL_LOG_ROOT}"
  printf 'run_id=%s\nnode=%s\nrun_root=%s\n' "${RUN_ID}" "${NODE_NAME}" "${RUN_ROOT}" |
    tee "${LOCAL_LOG_ROOT}/run.env"
}

build_overlay() {
  "${K[@]}" delete job "${BUILD_JOB}" --ignore-not-found --wait=true
  apply_template "${HERE}/build-job.yaml"
  local completed=false
  for _ in $(seq 1 360); do
    if [[ "$("${K[@]}" get job "${BUILD_JOB}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)" == 1 ]]; then
      completed=true
      break
    fi
    if [[ "$("${K[@]}" get job "${BUILD_JOB}" -o jsonpath='{.status.failed}' 2>/dev/null || true)" == 1 ]]; then
      "${K[@]}" logs "job/${BUILD_JOB}" --tail=300 | tee "${LOCAL_LOG_ROOT}/build.log"
      return 1
    fi
    sleep 10
  done
  if [[ "${completed}" != true ]]; then
    "${K[@]}" logs "job/${BUILD_JOB}" --tail=300 | tee "${LOCAL_LOG_ROOT}/build.log"
    return 1
  fi
  "${K[@]}" logs "job/${BUILD_JOB}" | tee "${LOCAL_LOG_ROOT}/build.log"
}

model_for_stage() {
  case "$1" in
    smoke) echo "Qwen/Qwen3-VL-2B-Instruct" ;;
    learn) echo "Qwen/Qwen3-VL-4B-Instruct" ;;
    *) echo "Unknown stage: $1" >&2; return 2 ;;
  esac
}

download_model() {
  local stage="$1"
  MODEL_NAME="$(model_for_stage "${stage}")"
  DOWNLOAD_POD="prime-mm-download-${stage}-${RUN_SLUG}"
  DOWNLOAD_POD="${DOWNLOAD_POD//[^a-z0-9-]/-}"
  export MODEL_NAME DOWNLOAD_POD
  "${K[@]}" delete pod "${DOWNLOAD_POD}" --ignore-not-found --wait=true
  apply_template "${HERE}/download-pod.yaml"
  for _ in $(seq 1 180); do
    local phase
    phase="$("${K[@]}" get pod "${DOWNLOAD_POD}" -o jsonpath='{.status.phase}')"
    if [[ "${phase}" == "Succeeded" ]]; then
      "${K[@]}" logs "${DOWNLOAD_POD}" | tee "${LOCAL_LOG_ROOT}/download-${stage}.log"
      "${K[@]}" delete pod "${DOWNLOAD_POD}" --wait=false >/dev/null
      return 0
    fi
    if [[ "${phase}" == "Failed" ]]; then
      "${K[@]}" logs "${DOWNLOAD_POD}"
      return 1
    fi
    sleep 10
  done
  "${K[@]}" logs "${DOWNLOAD_POD}" --tail=100
  return 1
}

render_stage() {
  local stage="$1"
  STAGE="${stage}"
  RELEASE_NAME="prime-mm-${stage}-${RUN_SLUG}"
  RELEASE_NAME="${RELEASE_NAME//[^a-z0-9-]/-}"
  RENDER_POD="prime-mm-render-${stage}-${RUN_SLUG}"
  RENDER_POD="${RENDER_POD//[^a-z0-9-]/-}"
  export STAGE RELEASE_NAME RENDER_POD

  local out="${LOCAL_LOG_ROOT}/${stage}"
  mkdir -p "${out}"
  "${K[@]}" delete pod "${RENDER_POD}" --ignore-not-found --wait=true
  apply_template "${HERE}/render-pod.yaml"
  "${K[@]}" wait --for=condition=Ready "pod/${RENDER_POD}" --timeout=300s >/dev/null

  local deadline=$(( $(date +%s) + 600 ))
  while (( $(date +%s) < deadline )); do
    if "${K[@]}" logs "${RENDER_POD}" --tail=50 2>/dev/null | grep -Fq RENDER_COMPLETE; then
      break
    fi
    local phase
    phase="$("${K[@]}" get pod "${RENDER_POD}" -o jsonpath='{.status.phase}')"
    if [[ "${phase}" == Failed || "${phase}" == Succeeded ]]; then
      "${K[@]}" logs "${RENDER_POD}" --tail=100
      return 1
    fi
    sleep 5
  done
  "${K[@]}" logs "${RENDER_POD}" | tee "${out}/render.log"
  rm -rf "${out}/render"
  "${K[@]}" cp "${RENDER_POD}:${RUN_ROOT}/render/${stage}" "${out}/render"
  envsubst '$NAMESPACE $IMAGE_DIGEST $RUN_ROOT $STAGE $RELEASE_NAME $NODE_NAME' \
    < "${HERE}/values.yaml" > "${out}/values.yaml"
  "${K[@]}" delete pod "${RENDER_POD}" --wait=false >/dev/null
  printf '%s\n' "${RELEASE_NAME}" > "${out}/release-name"
}

deploy_stage() {
  local stage="$1"
  local out="${LOCAL_LOG_ROOT}/${stage}"
  local release
  release="$(<"${out}/release-name")"
  helm upgrade --install "${release}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    -f "${out}/values.yaml"

  "${K[@]}" wait --for=condition=Ready "pod/${release}-inference-0" --timeout=1800s
  "${K[@]}" wait --for=condition=Ready "pod/${release}-trainer-0" --timeout=1800s
  "${K[@]}" wait --for=condition=Ready "pod/${release}-orchestrator-0" --timeout=300s
}

wait_stage() {
  local stage="$1"
  local out="${LOCAL_LOG_ROOT}/${stage}"
  local release
  local timeout
  release="$(<"${out}/release-name")"
  timeout=3600
  [[ "${stage}" == learn ]] && timeout=10800
  local deadline=$(( $(date +%s) + timeout ))

  while (( $(date +%s) < deadline )); do
    local logs
    logs="$("${K[@]}" logs "${release}-orchestrator-0" --tail=120 2>&1 || true)"
    if grep -Fq 'RL_ORCHESTRATOR_EXIT=0' <<<"${logs}"; then
      return 0
    fi
    if grep -Eq 'RL_ORCHESTRATOR_EXIT=[1-9]' <<<"${logs}"; then
      printf '%s\n' "${logs}" >&2
      return 1
    fi
    sleep 30
  done
  "${K[@]}" logs "${release}-orchestrator-0" --tail=300
  return 1
}

collect_stage() {
  local stage="$1"
  local out="${LOCAL_LOG_ROOT}/${stage}"
  local release
  release="$(<"${out}/release-name")"
  "${K[@]}" get pods -l "app.kubernetes.io/instance=${release}" -o wide > "${out}/pods.txt"
  for role in inference trainer orchestrator; do
    "${K[@]}" logs "${release}-${role}-0" > "${out}/${role}.log" 2>&1 || true
  done
  "${K[@]}" exec "${release}-inference-0" -- \
    curl -fsS http://127.0.0.1:8000/metrics \
    > "${out}/frontend-metrics.prom" || true
  "${K[@]}" exec "${release}-trainer-0" -- \
    find "${RUN_ROOT}/outputs/${stage}" -maxdepth 4 -type f -printf '%p %s bytes\n' \
    > "${out}/output-files.txt" || true
}

clean_stage() {
  local stage="$1"
  local out="${LOCAL_LOG_ROOT}/${stage}"
  [[ -f "${out}/release-name" ]] || return 0
  local release
  release="$(<"${out}/release-name")"
  helm uninstall "${release}" --namespace "${NAMESPACE}" || true
}

run_stage() {
  local stage="$1"
  download_model "${stage}"
  render_stage "${stage}"
  deploy_stage "${stage}"
  if ! wait_stage "${stage}"; then
    collect_stage "${stage}"
    return 1
  fi
  collect_stage "${stage}"
  clean_stage "${stage}"
}

all() {
  preflight
  build_overlay
  run_stage smoke
  run_stage learn
  "${K[@]}" delete job "${BUILD_JOB}" --ignore-not-found --wait=false
}

case "${1:-all}" in
  preflight) preflight ;;
  build) preflight; build_overlay ;;
  smoke) preflight; run_stage smoke ;;
  learn) preflight; run_stage learn ;;
  clean) clean_stage smoke; clean_stage learn ;;
  all) all ;;
  *) echo "usage: $0 {preflight|build|smoke|learn|clean|all}" >&2; exit 2 ;;
esac
