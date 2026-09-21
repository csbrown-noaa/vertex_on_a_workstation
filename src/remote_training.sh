#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e 

# --- CLI Argument Parsing ---
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Executes a Vertex AI style training job via Docker on a GCP Workstation."
    echo ""
    echo "Options:"
    echo "  -b, --bucket    REQUIRED: GCS bucket name for FUSE mount (e.g., my-training-bucket)"
    echo "  -i, --image     REQUIRED: Docker image URI to pull and run"
    echo "  -r, --region    GCP Region for Artifact Registry auth (default: us-central1)"
    echo "  -h, --help      Display this help message and exit"
    exit 1
}

# Default values
REGION="us-central1"
GCS_BUCKET=""
IMAGE_URI=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -b|--bucket) GCS_BUCKET="$2"; shift ;;
        -i|--image) IMAGE_URI="$2"; shift ;;
        -r|--region) REGION="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$GCS_BUCKET" \vert{}\vert{} -z "$IMAGE_URI" ]]; then
    echo "Error: Missing required arguments."
    usage
fi

# --- Job Execution ---

echo "Authenticating Workstation Docker with Artifact Registry in ${REGION}..."
gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet

echo "Pulling Docker image ($IMAGE_URI)..."
docker pull $IMAGE_URI

echo "Checking for gcsfuse..."
if ! command -v gcsfuse &> /dev/null; then
    echo "Installing gcsfuse on the Workstation host..."
    export GCSFUSE_REPO=gcsfuse-`lsb_release -c -s`
    echo "deb https://packages.cloud.google.com/apt $GCSFUSE_REPO main" | sudo tee /etc/apt/sources.list.d/gcsfuse.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    sudo apt-get update
    sudo apt-get install -y gcsfuse
fi

# --- GCS FUSE Setup ---
LOCAL_MOUNT="/tmp/gcs_mount"
mkdir -p $LOCAL_MOUNT

# Clean up any hanging mounts from previous failed runs
fusermount -u $LOCAL_MOUNT 2>/dev/null || true

echo "Mounting gs://$GCS_BUCKET to host at$LOCAL_MOUNT..."
# Mount the bucket directly to the temp folder
gcsfuse $GCS_BUCKET$LOCAL_MOUNT

# --- Docker Run (The "Vertex AI" Emulator) ---
echo "Starting Docker container..."

# We bind mount the local FUSE folder to the EXACT path Vertex AI uses: /gcs/BUCKET_NAME
# This ensures that when utils.py converts gs://... to /gcs/..., it works seamlessly.
docker run --rm --gpus all \
    --shm-size=8g \
    -v $LOCAL_MOUNT:/gcs/$GCS_BUCKET \
    -e AIP_MODEL_DIR=gs://$GCS_BUCKET/model_output \
    $IMAGE_URI \
    --config-uri gs://$GCS_BUCKET/config.yaml \
    --model yolov8n.pt

# --- Cleanup ---
echo "Docker container finished. Unmounting FUSE..."
fusermount -u $LOCAL_MOUNT

echo "Remote training execution successful!"
