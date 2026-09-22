# GCP Workstations Vertex AI Emulator

This tool automates the process of launching Google Cloud Workstations, executing containerized machine learning training jobs within them, and automatically spinning down the resources to save costs. It is designed to emulate the execution environment of a Vertex AI Custom Job.

## Overview

While Vertex AI is a fully managed service, GCP Workstations offer fixed hardware (like specific GPUs) that you might need to leverage directly. This orchestrator acts as the "middleman":

1.  Provisions and boots up a specific GCP Workstation.
2.  Waits for SSH readiness.
3.  Mounts your designated Google Cloud Storage (GCS) bucket locally via `gcsfuse`.
4.  Injects Vertex AI standard environment variables (like `AIP_MODEL_DIR`) and launches your Docker container.
5.  Automatically shuts down the workstation when the container finishes running.

## Usage & CLI Arguments

The `workstation_launch.sh` script is completely generic and framework-agnostic. It requires the infrastructure details to be passed as command-line arguments:

```bash
./workstation_launch.sh \
  --bucket my-training-bucket \
  --image us-central1-docker.pkg.dev/PROJECT/REPO/my-image:latest \
  --aip-model-dir gs://my-training-bucket/model_output \
  --name my-workstation-name \
  --project my-gcp-project \
  --region us-central1 \
  --cluster my-cluster-name \
  --config my-workstation-config \
  -- [CONTAINER_ARGS...]
```

### The Pass-Through Mechanism (`--`)

Because this orchestrator is generic, it does not know what hyperparameters your specific model requires. To pass custom arguments to your Python script inside the Docker container, use the double-dash (`--`) separator.

*   Everything **before** the `--` is used by this bash script to set up the Workstation.
*   Everything **after** the `--` is forwarded directly and securely to the end of the `docker run` command.

## Hello World Walkthrough

To verify this infrastructure pipeline works, we will deploy a sample YOLO object detection model.

**Step 1: Build the Sample Model**
Go to the [COCO8 Vertex Model Repository](https://github.com/csbrown-noaa/example_ultralytics_vertex_training) and follow the README instructions to build the Docker image and push it to your Artifact Registry.

**Step 2: Upload a Config**
Create a blank file named `config.yaml` and upload it to your GCS bucket:
```bash
touch config.yaml
gcloud storage cp config.yaml gs://my-training-bucket/config.yaml
```

**Step 3: Run the Orchestrator**
Execute the launch script. Notice how we pass the model-specific hyperparameter arguments (`--config-uri` and `--model`) *after* the double-dash:

```bash
./workstation_launch.sh \
  --bucket my-training-bucket \
  --image us-central1-docker.pkg.dev/YOUR_PROJECT_ID/YOUR_REPO/yolo-vertex-trainer:latest \
  --aip-model-dir gs://my-training-bucket/model_output \
  --name dev-workstation \
  --project YOUR_PROJECT_ID \
  --region us-central1 \
  --cluster workstation-cluster-1 \
  --config nmfs-base-image-xlarge-gpu-base-image \
  -- \
  --config-uri gs://my-training-bucket/config.yaml \
  --model yolov8n.pt
```

## Retrieving Results

Because this pipeline emulates Vertex AI's GCS FUSE mapping, your Docker container writes directly to cloud storage in real-time. 

You never need to SSH into the Workstation to recover your files. When the job finishes, simply navigate to `gs://your-bucket/model_output/` (the path you provided to `--aip-model-dir`) in the Google Cloud Console to view your trained weights, logs, and visualizations.

# Contributing

We would love to have your contributions that improve current functionality, fix bugs, or add new features.  See [the contributing guidelines](CONTRIBUTING.md) for more info.

# Disclaimer

This repository is a scientific product and is not official communication of the National Oceanic and
Atmospheric Administration, or the United States Department of Commerce. All NOAA GitHub project
code is provided on an ‘as is’ basis and the user assumes responsibility for its use. Any claims against the
Department of Commerce or Department of Commerce bureaus stemming from the use of this GitHub
project will be governed by all applicable Federal law. Any reference to specific commercial products,
processes, or services by service mark, trademark, manufacturer, or otherwise, does not constitute or
imply their endorsement, recommendation or favoring by the Department of Commerce. The Department
of Commerce seal and logo, or the seal and logo of a DOC bureau, shall not be used in any manner to
imply endorsement of any commercial product or activity by DOC or the United States Government.
