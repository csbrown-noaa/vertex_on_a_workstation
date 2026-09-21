#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- CLI Argument Parsing ---
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Automates launching a GCP Workstation and running a training job over SSH."
    echo ""
    echo "Options:"
    echo "  -b, --bucket    REQUIRED: GCS bucket for the training job (e.g., my-training-bucket)"
    echo "  -i, --image     REQUIRED: Docker image URI for the training job"
    echo "  -n, --name      Workstation name (default: megamodel_training)"
    echo "  -p, --project   GCP Project ID (default: ggn-nmfs-osi-dev-1)"
    echo "  -r, --region    GCP Region (default: us-central1)"
    echo "  -c, --cluster   Workstation cluster (default: workstation-cluster-1)"
    echo "  -g, --config    Workstation config (default: nmfs-base-image-xlarge-gpu-base-image)"
    echo "  -h, --help      Display this help message and exit"
    exit 1
}

# Default Configuration variables
WORKSTATION_NAME="megamodel_training"
PROJECT="ggn-nmfs-osi-dev-1"
REGION="us-central1"
CLUSTER="workstation-cluster-1"
CONFIG="nmfs-base-image-xlarge-gpu-base-image"
GCS_BUCKET=""
IMAGE_URI=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -b|--bucket) GCS_BUCKET="$2"; shift ;;
        -i|--image) IMAGE_URI="$2"; shift ;;
        -n|--name) WORKSTATION_NAME="$2"; shift ;;
        -p|--project) PROJECT="$2"; shift ;;
        -r|--region) REGION="$2"; shift ;;
        -c|--cluster) CLUSTER="$2"; shift ;;
        -g|--config) CONFIG="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validation
if [[ -z "$GCS_BUCKET" || -z "$IMAGE_URI" ]]; then
    echo "Error: --bucket and --image are required for the remote training script."
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

# Helper function to pipe a local script to the workstation AND pass arguments
gcloud_ssh_script() {
  local script_file="$1"
  shift # Remove the script file from the argument list so "$@" only contains the CLI args
  
  gcloud workstations ssh $WORKSTATION_NAME \
    --project=$PROJECT \
    --region=$REGION \
    --cluster=$CLUSTER \
    --config=$CONFIG \
    --command="bash -s -- $@" < "$script_file"
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

# We call the script over SSH and pass our CLI variables down to it
gcloud_ssh_script "run_training_job.sh" --bucket "$GCS_BUCKET" --image "$IMAGE_URI" --region "$REGION"

# --- Ephemeral Teardown ---
echo "Training job completed. Spinning down workstation to save costs..."
gcloud workstations stop $WORKSTATION_NAME \
  --project=$PROJECT \
  --region=$REGION \
  --cluster=$CLUSTER \
  --config=$CONFIG

echo "Workstation stopped. Pipeline complete."
