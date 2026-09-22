#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- CLI Argument Parsing ---
usage() {
    echo "Usage: $0 [OPTIONS] -- [CONTAINER_ARGS...]"
    echo "Automates launching a GCP Workstation and running a training job over SSH."
    echo ""
    echo "Options:"
    echo "  -b, --bucket         REQUIRED: GCS bucket for the training job (e.g., my-training-bucket)"
    echo "  -i, --image          REQUIRED: Docker image URI for the training job"
    echo "  -a, --aip-model-dir  REQUIRED: Vertex AI model directory URI (e.g., gs://my-bucket/model_output)"
    echo "  -n, --name           REQUIRED: Workstation name"
    echo "  -p, --project        REQUIRED: GCP Project ID"
    echo "  -r, --region         REQUIRED: GCP Region"
    echo "  -c, --cluster        REQUIRED: Workstation cluster"
    echo "  -g, --config         REQUIRED: Workstation config"
    echo "  -h, --help           Display this help message and exit"
    echo ""
    echo "Container Arguments:"
    echo "  Any arguments placed after a double dash (--) will be passed directly"
    echo "  to the Docker container."
    exit 1
}

# Initialize variables to empty strings (no defaults)
WORKSTATION_NAME=""
PROJECT=""
REGION=""
CLUSTER=""
CONFIG=""
GCS_BUCKET=""
IMAGE_URI=""
AIP_MODEL_DIR=""
CONTAINER_ARGS=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -b|--bucket) GCS_BUCKET="$2"; shift ;;
        -i|--image) IMAGE_URI="$2"; shift ;;
        -a|--aip-model-dir) AIP_MODEL_DIR="$2"; shift ;;
        -n|--name) WORKSTATION_NAME="$2"; shift ;;
        -p|--project) PROJECT="$2"; shift ;;
        -r|--region) REGION="$2"; shift ;;
        -c|--cluster) CLUSTER="$2"; shift ;;
        -g|--config) CONFIG="$2"; shift ;;
        -h|--help) usage ;;
        --) shift; CONTAINER_ARGS=("$@"); break ;;
        -*) echo "Unknown parameter passed: $1"; usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validation: Ensure all arguments are provided
if [[ -z "$GCS_BUCKET" || -z "$IMAGE_URI" || -z "$AIP_MODEL_DIR" || -z "$WORKSTATION_NAME" || -z "$PROJECT" || -z "$REGION" || -z "$CLUSTER" || -z "$CONFIG" ]]; then
    echo "Error: Missing required arguments. All options must be specified."
    usage
fi

# Create the workstation (if it doesn't exist)
gcloud workstations create $WORKSTATION_NAME \
  --project=$PROJECT \
  --region=$REGION \
  --cluster=$CLUSTER \
  --config=$CONFIG 2>/dev/null || echo "Workstation already exists."

# Update the workstation to increase the persistent disk size
gcloud workstations update $WORKSTATION_NAME \
  --project=$PROJECT \
  --region=$REGION \
  --cluster=$CLUSTER \
  --config=$CONFIG \
  --pd-disk-size=2048

# Start the workstation
echo "Starting workstation $WORKSTATION_NAME..."
gcloud workstations start $WORKSTATION_NAME \
  --project=$PROJECT \
  --region=$REGION \
  --cluster=$CLUSTER \
  --config=$CONFIG

# Helper function to run SSH commands succinctly
gcloud_ssh() {
  local cmd="$1"
  gcloud workstations ssh $WORKSTATION_NAME \
    --project=$PROJECT \
    --region=$REGION \
    --cluster=$CLUSTER \
    --config=$CONFIG \
    --command="$cmd"
}

# Helper function to pipe a local script to the workstation AND pass arguments securely
gcloud_ssh_script() {
  local script_file="$1"
  shift # Remove the script file from the argument list
  
  # Safely escape arguments (preserves spaces inside string variables over the SSH hop)
  local escaped_args=$(printf '%q ' "$@")
  
  gcloud workstations ssh $WORKSTATION_NAME \
    --project=$PROJECT \
    --region=$REGION \
    --cluster=$CLUSTER \
    --config=$CONFIG \
    --command="bash -s -- $escaped_args" < "$script_file"
}

# --- Wait for Readiness ---
echo "Waiting for workstation to become available..."

# Wait loop to ensure the workstation is ready for SSH connections
MAX_RETRIES=40
RETRY_INTERVAL=15
count=0

while [ $count -lt $MAX_RETRIES ]; do
  if gcloud_ssh "echo 'Ready'" > /dev/null 2>&1; then
      echo "Workstation is up and ready for SSH!"
      break
  fi
  
  echo "Still waiting... (Attempt $((count + 1)) of $MAX_RETRIES)"
  sleep $RETRY_INTERVAL
  count=$((count + 1))
done

if [ $count -eq $MAX_RETRIES ]; do
  echo "Error: Timed out waiting for workstation to become available."
  exit 1
fi

# --- Run the "Vertex" Job ---
echo "Workstation ready. Launching training job over SSH..."

# Call the script over SSH, passing workstation args AND appending container args after the --
gcloud_ssh_script "run_training_job.sh" \
    --bucket "$GCS_BUCKET" \
    --image "$IMAGE_URI" \
    --region "$REGION" \
    --aip-model-dir "$AIP_MODEL_DIR" \
    -- "${CONTAINER_ARGS[@]}"

# --- Ephemeral Teardown ---
echo "Training job completed. Spinning down workstation to save costs..."
gcloud workstations stop $WORKSTATION_NAME \
  --project=$PROJECT \
  --region=$REGION \
  --cluster=$CLUSTER \
  --config=$CONFIG

echo "Workstation stopped. Pipeline complete."
