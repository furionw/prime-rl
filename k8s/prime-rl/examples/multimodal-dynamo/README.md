# Multimodal Dynamo RL on Kubernetes

This on-demand integration test builds Dynamo and Prime RL into a shared-PVC
runtime overlay, runs Prime's native Dynamo backend in a two-GPU inference
StatefulSet, and runs one trainer on a second GB200 node. The native
backend launches the Dynamo frontend plus one prefill and one decode process.

The default sequence uses:

- `Qwen/Qwen3-VL-2B-Instruct` for a one-step integration smoke test.
- `Qwen/Qwen3.5-2B` for a second one-step integration smoke test, available
  through the `qwen35` phase.
- `Qwen/Qwen3-VL-4B-Instruct` for the existing 15-step color-codeword test.
- Three GPUs total: one trainer, one prefill worker, and one decode worker.
- `qiwa/shared-model-cache` for models, sources, the virtual environment,
  checkpoints, and run artifacts.
- The digest-pinned ARM64 toolchain image configured in `run.sh`.

Before deployment, each stage runs an explicit Hugging Face download pod;
already-cached model snapshots make that step a fast offline cache check. After
model download and config rendering, the driver refreshes auto-selected nodes
and immediately deploys the actual GPU-requesting pods. Kubernetes therefore
reserves their GPUs before any node-local image pull begins.

Run the complete sequence from this directory:

```bash
./run.sh all
```

Set `RUN_ID`, `NODE_NAME`, `TRAINER_NODE_NAME`, `DYNAMO_REF`, `PRIME_REPO`, or
`PRIME_REF` to resume or override a specific run. Reusing `RUN_ID` also reuses
the validated runtime overlay when its image and source commit manifest still
match. Individual phases are available as `preflight`, `build`, `smoke`,
`qwen35`, `learn`, and `clean`.

Run the two small-model checks in order with:

```bash
./run.sh smoke
./run.sh qwen35
```

Each stage clears only its own prior output directory before rendering, so a
reused `RUN_ID` cannot satisfy the trainer from an older rollout batch. The
runtime overlay and model cache remain intact.

For a code-unchanged smoke rerun, reuse `RUN_ID` and run `./run.sh smoke`; this
skips the overlay build. The shared PVC persists the Hugging Face model cache,
uv and pip caches, Cargo registry and target directories, and the validated
runtime overlay. Image layers are node-local, so pod startup may still take
about three minutes on a node that has not pulled the image before; the pod's
GPU request remains reserved during that pull. In a measured warm-node smoke
run, the model cache check took less than a second, the two vLLM workers became
ready about 2 minutes 45 seconds after Helm deploy, 16 multimodal rollouts took
40 seconds, and the first trainer step took 55 seconds.

Local logs and rendered manifests are written under
`~/workspace/dynamo-tmp/logs/07-09/multimodal-rl-k8s/<run-id>/`. The driver
collects evidence before uninstalling each Helm release. It preserves the PVC
runtime and model cache.
