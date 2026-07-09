# Multimodal Dynamo RL on Kubernetes

This on-demand integration test builds Dynamo and Prime RL into a shared-PVC
runtime overlay, runs Prime's native Dynamo backend in a two-GPU inference
StatefulSet, and runs one trainer on the same four-GPU GB200 node. The native
backend launches the Dynamo frontend plus one prefill and one decode process.

The default sequence uses:

- `Qwen/Qwen3-VL-2B-Instruct` for a one-step integration smoke test.
- `Qwen/Qwen3-VL-4B-Instruct` for the existing 15-step color-codeword test.
- Three GPUs total: one trainer, one prefill worker, and one decode worker.
- `qiwa/shared-model-cache` for models, sources, the virtual environment,
  checkpoints, and run artifacts.
- The digest-pinned ARM64 toolchain image configured in `run.sh`.

Run the complete sequence from this directory:

```bash
./run.sh all
```

Set `RUN_ID`, `NODE_NAME`, `TRAINER_NODE_NAME`, `DYNAMO_REF`, `PRIME_REPO`, or
`PRIME_REF` to resume or override a specific run. Individual phases are available as `preflight`,
`build`, `smoke`, `learn`, and `clean`.

Local logs and rendered manifests are written under
`~/workspace/dynamo-tmp/logs/07-09/multimodal-rl-k8s/<run-id>/`. The driver
collects evidence before uninstalling each Helm release. It preserves the PVC
runtime and model cache.
