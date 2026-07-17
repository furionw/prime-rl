import tomllib
from pathlib import Path

from prime_rl.configs.inference import InferenceConfig
from prime_rl.configs.rl import RLConfig
from prime_rl.entrypoints.rl import INFERENCE_TOML, write_slurm_script, write_subconfigs


def test_write_subconfigs_preserves_dynamo_disaggregated_deployment(tmp_path: Path):
    config = RLConfig.model_validate(
        {
            "trainer": {},
            "orchestrator": {},
            "inference": {
                "backend": {"type": "dynamo"},
                "deployment": {
                    "type": "disaggregated",
                    "gpus_per_node": 1,
                    "num_prefill_replicas": 1,
                    "num_decode_replicas": 1,
                },
                "enable_expert_parallel": False,
            },
            "deployment": {
                "type": "single_node",
                "gpus_per_node": 3,
                "num_train_gpus": 1,
                "num_infer_gpus": 2,
            },
            "slurm": {},
        }
    )

    write_subconfigs(config, tmp_path)

    with (tmp_path / INFERENCE_TOML).open("rb") as file:
        reloaded = InferenceConfig.model_validate(tomllib.load(file))

    assert reloaded.slurm is None
    assert reloaded.deployment.type == "disaggregated"
    assert reloaded.dynamo_worker_roles == ("prefill", "decode")


def test_write_subconfigs_preserves_dynamo_multi_node_deployment(tmp_path: Path):
    config = RLConfig.model_validate(
        {
            "trainer": {},
            "orchestrator": {},
            "inference": {
                "backend": {"type": "dynamo"},
                "deployment": {"type": "multi_node", "num_nodes": 2, "gpus_per_node": 1},
            },
            "deployment": {
                "type": "multi_node",
                "gpus_per_node": 1,
                "num_train_nodes": 1,
                "num_infer_nodes": 2,
            },
            "slurm": {"project_dir": str(tmp_path)},
        }
    )

    write_subconfigs(config, tmp_path)

    with (tmp_path / INFERENCE_TOML).open("rb") as file:
        reloaded = InferenceConfig.model_validate(tomllib.load(file))

    assert reloaded.slurm is None
    assert reloaded.deployment.type == "multi_node"
    assert reloaded.dynamo_worker_roles == ("agg", "agg")


def test_multi_node_dynamo_slurm_script_launches_frontend_and_node_worker(tmp_path: Path):
    config = RLConfig.model_validate(
        {
            "trainer": {},
            "orchestrator": {},
            "inference": {"backend": {"type": "dynamo"}},
            "deployment": {
                "type": "multi_node",
                "gpus_per_node": 1,
                "num_train_nodes": 1,
                "num_infer_nodes": 1,
            },
            "output_dir": str(tmp_path / "run"),
            "slurm": {"project_dir": str(tmp_path)},
        }
    )
    config_dir = tmp_path / "configs"
    write_subconfigs(config, config_dir)
    script_path = tmp_path / "rl.sbatch"

    write_slurm_script(config, config_dir, script_path)

    script = script_path.read_text()
    assert "export DYN_DISCOVERY_BACKEND=file" in script
    assert "PRIME_RL_DYNAMO_PROCESS=frontend" in script
    assert "PRIME_RL_DYNAMO_PROCESS=worker" in script
    assert 'ADMIN_URLS="$INFER_URLS"' in script
    assert "launch_inference_rank" not in script


def test_multi_node_dynamo_pd_slurm_script_assigns_one_role_per_node(tmp_path: Path):
    config = RLConfig.model_validate(
        {
            "trainer": {},
            "orchestrator": {},
            "inference": {
                "backend": {"type": "dynamo"},
                "deployment": {
                    "type": "disaggregated",
                    "gpus_per_node": 1,
                    "num_prefill_replicas": 1,
                    "num_decode_replicas": 1,
                },
            },
            "deployment": {
                "type": "multi_node",
                "gpus_per_node": 1,
                "num_train_nodes": 1,
                "num_infer_nodes": 2,
            },
            "output_dir": str(tmp_path / "run"),
            "slurm": {"project_dir": str(tmp_path)},
        }
    )
    config_dir = tmp_path / "configs"
    write_subconfigs(config, config_dir)
    script_path = tmp_path / "rl.sbatch"

    write_slurm_script(config, config_dir, script_path)

    script = script_path.read_text()
    assert "#SBATCH --nodes=3" in script
    assert "DYNAMO_ROLE=prefill" in script
    assert "DYNAMO_ROLE=decode" in script
    assert "PRIME_RL_DYNAMO_WORKER_INDEX=$INFER_NODE_RANK" in script
    assert "UCX_NET_DEVICES=$(rdma_ports InfiniBand)" in script
