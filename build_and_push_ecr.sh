#!/bin/bash
set -eo pipefail

# --- Configuration ---
DOCKER_REGISTRY="654366648792.dkr.ecr.eu-west-1.amazonaws.com"
AWS_REGION="eu-west-1"

APP_VERSION_ARG=${1} # Semantic version from command line argument
if [ -z "$APP_VERSION_ARG" ]; then
  echo "Usage: $0 <app-version>"
  echo "Example: $0 1.0.1"
  # Attempt to get from git tag if no argument given
  APP_VERSION_ARG=$(git describe --tags --abbrev=0 2>/dev/null)
  if [ -z "$APP_VERSION_ARG" ]; then
    echo "No version argument provided and no git tag found. Defaulting APP_VERSION to 1.0.0."
    APP_VERSION_ARG="1.0.0"
  else
    echo "Using APP_VERSION from git tag: $APP_VERSION_ARG"
  fi
fi
export APP_VERSION="$APP_VERSION_ARG"


GIT_COMMIT_SHA_RAW=$(git rev-parse --short HEAD 2>/dev/null)
if [ -z "$GIT_COMMIT_SHA_RAW" ] || [ "$?" -ne 0 ]; then
  echo "WARN: Could not determine Git SHA. Using 'unknown'."
  export GIT_COMMIT_SHA="unknown"
else
  export GIT_COMMIT_SHA="$GIT_COMMIT_SHA_RAW"
fi

if git diff --stat --quiet; then
  :
else
  if [ "$GIT_COMMIT_SHA" != "unknown" ]; then
    echo "WARN: You have uncommitted changes. Appending -dirty to GIT_COMMIT_SHA."
    export GIT_COMMIT_SHA="${GIT_COMMIT_SHA}-dirty"
  else
    export GIT_COMMIT_SHA="unknown-dirty"
  fi
fi

# Image names (without registry and tag, as used in compose image field)
BACKEND_IMAGE_BASENAME="devlake-backend-custom"
FRONTEND_IMAGE_BASENAME="devlake-frontend-custom"

# Full image paths with the primary version tag (this is what compose will build)
PRIMARY_BACKEND_IMAGE="${DOCKER_REGISTRY}/${BACKEND_IMAGE_BASENAME}:${APP_VERSION}"
PRIMARY_FRONTEND_IMAGE="${DOCKER_REGISTRY}/${FRONTEND_IMAGE_BASENAME}:${APP_VERSION}"

# Tags for 'latest' and git SHA
LATEST_BACKEND_TAG="${DOCKER_REGISTRY}/${BACKEND_IMAGE_BASENAME}:latest"
LATEST_FRONTEND_TAG="${DOCKER_REGISTRY}/${FRONTEND_IMAGE_BASENAME}:latest"
SHA_BACKEND_TAG="${DOCKER_REGISTRY}/${BACKEND_IMAGE_BASENAME}:${GIT_COMMIT_SHA}"
SHA_FRONTEND_TAG="${DOCKER_REGISTRY}/${FRONTEND_IMAGE_BASENAME}:${GIT_COMMIT_SHA}"

# Export DOCKER_REGISTRY for docker-compose to use
export DOCKER_REGISTRY

echo "--- Configuration ---"
echo "DOCKER_REGISTRY:          ${DOCKER_REGISTRY}"
echo "APP_VERSION (for TAG arg):  ${APP_VERSION}"
echo "GIT_COMMIT_SHA (for SHA arg): ${GIT_COMMIT_SHA}"
echo "Primary Backend Image:    ${PRIMARY_BACKEND_IMAGE}"
echo "Primary Frontend Image:   ${PRIMARY_FRONTEND_IMAGE}"
echo "---"

echo "--- Authenticating to ECR ---"
if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI (aws) could not be found. Please install and configure it."
    exit 1
fi
if ! aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${DOCKER_REGISTRY}"; then
    echo "ERROR: ECR authentication failed."
    exit 1
fi
echo "ECR authentication complete."

echo "--- Building Docker images via docker-compose ---"
# docker-compose build will use DOCKER_REGISTRY and APP_VERSION from environment
# to name the images as defined in the 'image:' fields of docker-compose.prod.yml
#
if ! docker-compose -f docker-compose.prod.yml build --no-cache; then
    echo "ERROR: Docker compose build failed."
    exit 1
fi

echo "--- Images present after build (check for primary tags): ---"
docker images "${DOCKER_REGISTRY}/${BACKEND_IMAGE_BASENAME}"
docker images "${DOCKER_REGISTRY}/${FRONTEND_IMAGE_BASENAME}"
echo "------------------------------------------------------------"

echo "--- Tagging images ---"
if docker image inspect "${PRIMARY_BACKEND_IMAGE}" &> /dev/null; then
    echo "Tagging ${PRIMARY_BACKEND_IMAGE} to ${LATEST_BACKEND_TAG}"
    docker tag "${PRIMARY_BACKEND_IMAGE}" "${LATEST_BACKEND_TAG}"
    echo "Tagging ${PRIMARY_BACKEND_IMAGE} to ${SHA_BACKEND_TAG}"
    docker tag "${PRIMARY_BACKEND_IMAGE}" "${SHA_BACKEND_TAG}"
else
    echo "WARN: Source image ${PRIMARY_BACKEND_IMAGE} not found for tagging backend."
fi

if docker image inspect "${PRIMARY_FRONTEND_IMAGE}" &> /dev/null; then
    echo "Tagging ${PRIMARY_FRONTEND_IMAGE} to ${LATEST_FRONTEND_TAG}"
    docker tag "${PRIMARY_FRONTEND_IMAGE}" "${LATEST_FRONTEND_TAG}"
    echo "Tagging ${PRIMARY_FRONTEND_IMAGE} to ${SHA_FRONTEND_TAG}"
    docker tag "${PRIMARY_FRONTEND_IMAGE}" "${SHA_FRONTEND_TAG}"
else
    echo "WARN: Source image ${PRIMARY_FRONTEND_IMAGE} not found for tagging frontend."
fi

echo "--- Pushing images to ECR ---"
if docker image inspect "${PRIMARY_BACKEND_IMAGE}" &> /dev/null; then
    echo "Pushing ${PRIMARY_BACKEND_IMAGE}"
    docker push "${PRIMARY_BACKEND_IMAGE}"
    echo "Pushing ${LATEST_BACKEND_TAG}"
    docker push "${LATEST_BACKEND_TAG}"
    echo "Pushing ${SHA_BACKEND_TAG}"
    docker push "${SHA_BACKEND_TAG}"
else
    echo "WARN: Image ${PRIMARY_BACKEND_IMAGE} not found, skipping push for backend."
fi

if docker image inspect "${PRIMARY_FRONTEND_IMAGE}" &> /dev/null; then
    echo "Pushing ${PRIMARY_FRONTEND_IMAGE}"
    docker push "${PRIMARY_FRONTEND_IMAGE}"
    echo "Pushing ${LATEST_FRONTEND_TAG}"
    docker push "${LATEST_FRONTEND_TAG}"
    echo "Pushing ${SHA_FRONTEND_TAG}"
    docker push "${SHA_FRONTEND_TAG}"
else
    echo "WARN: Image ${PRIMARY_FRONTEND_IMAGE} not found, skipping push for frontend."
fi

echo "--- Build and Push Complete ---"