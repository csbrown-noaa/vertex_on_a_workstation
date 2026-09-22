#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e 

# --- CLI Argument Parsing ---
usage() {
    echo "Usage: $0 [OPTIONS] -- [CONTAINER_ARGS...]"
    echo "Executes a Vertex AI style training job via Docker on a GCP Workstation."
    echo ""
    echo "Options:"
    echo "  -b, --bucket         REQUIRED: GCS bucket name for FUSE mount (e.g., my-training-bucket)"
    echo "  -i, --image          REQUIRED: Docker image URI to pull and run"
    echo "  -r, --region         REQUIRED: GCP Region for Artifact Registry auth"
    echo "  -a, --aip-model-dir  REQUIRED: Vertex AI model directory URI (e.g., gs://my-bucket/model_output)"
    echo "  -h, --help           Display this help message and exit"
    echo ""
    echo "Container Arguments:"
    echo "  Any arguments placed after a double dash (--) will be passed directly"
    echo "  to the Docker container as command-line arguments."
    exit 1
}

# Initialize variables to empty strings (no defaults)
REGION=""
GCS_BUCKET=""
IMAGE_URI=""
AIP_MODEL_DIR=""
CONTAINER_ARGS=()

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -b|--bucket) GCS_BUCKET="$2"; shift ;;
        -i|--image) IMAGE_URI="$2"; shift ;;
        -r|--region) REGION="$2"; shift ;;
        -a|--aip-model-dir) AIP_MODEL_DIR="$2"; shift ;;
        -h|--help) usage ;;
        --) shift; CONTAINER_ARGS=("$@"); break ;;
        -*) echo "Unknown parameter passed: $1"; usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$GCS_BUCKET" \vert{}\vert{} -z "$IMAGE_URI" || -z "$REGION" \vert{}\vert{} -z "$AIP_MODEL_DIR" ]]; then
    echo "Error: Missing required arguments. All options must be specified."
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
# The CONTAINER_ARGS array safely expands to any arguments the user passed after '--'
docker run --rm --gpus all \
    --shm-size=8g \
    -v $LOCAL_MOUNT:/gcs/$GCS_BUCKET \
    -e AIP_MODEL_DIR="$AIP_MODEL_DIR" \
    $IMAGE_URI \
    "${CONTAINER_ARGS[@]}"

# --- Cleanup ---
echo "Docker container finished. Unmounting FUSE..."
fusermount -u $LOCAL_MOUNT

echo "Remote training execution successful!"
