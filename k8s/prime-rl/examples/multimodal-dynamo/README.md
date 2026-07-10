# Multimodal Dynamo RL on Kubernetes

This on-demand integration test builds Dynamo and Prime RL into a shared-PVC
runtime overlay, runs Prime's native Dynamo backend in a two-GPU inference
StatefulSet, and runs one trainer on a second GB200 node. The native
backend launches the Dynamo frontend plus one prefill and one decode process.

The default sequence uses:

- `Qwen/Qwen3-VL-2B-Instruct` for a one-step integration smoke test.
- `Qwen/Qwen3-VL-4B-Instruct` for the existing 15-step color-codeword test.
- Three GPUs total: one trainer, one prefill worker, and one decode worker.
- `qiwa/shared-model-cache` for models, sources, the virtual environment,
  checkpoints, and run artifacts.
- The digest-pinned ARM64 toolchain image configured in `run.sh`.

Before deployment, the driver starts pulling the base image onto the trainer
node while the runtime overlay builds on the inference node. Each stage also
runs an explicit Hugging Face download pod; already-cached model snapshots make
that step a fast offline cache check.

Run the complete sequence from this directory:

```bash
./run.sh all
```

Set `RUN_ID`, `NODE_NAME`, `TRAINER_NODE_NAME`, `DYNAMO_REF`, `PRIME_REPO`, or
`PRIME_REF` to resume or override a specific run. Reusing `RUN_ID` also reuses
the validated runtime overlay when its image and source commit manifest still
match. Individual phases are available as `preflight`, `build`, `smoke`,
`learn`, and `clean`.

For a code-unchanged smoke rerun, reuse `RUN_ID` and run `./run.sh smoke`; this
skips the overlay build. The shared PVC persists the Hugging Face model cache,
uv and pip caches, Cargo registry and target directories, and the validated
runtime overlay. Image layers are node-local, so the prewarm phase may still
take about three minutes on a node that has not pulled the image before. In a
measured warm-node smoke run, the model cache check took less than a second,
the two vLLM workers became ready about 2 minutes 45 seconds after Helm deploy,
16 multimodal rollouts took 40 seconds, and the first trainer step took 55
seconds.

Local logs and rendered manifests are written under
`~/workspace/dynamo-tmp/logs/07-09/multimodal-rl-k8s/<run-id>/`. The driver
collects evidence before uninstalling each Helm release. It preserves the PVC
runtime and model cache.
