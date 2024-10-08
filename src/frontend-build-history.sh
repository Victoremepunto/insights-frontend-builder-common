#!/bin/bash

# Don't exit on error
# we need to trap errors to handle cerain conditions
set +e

# Globals
SINGLETAG="single" # used for looking up single build images
Color_Off='\033[0m' # What? I like colors.
Black='\033[0;30m'
Red='\033[0;31m'
Green='\033[0;32m'
Yellow='\033[0;33m'
Blue='\033[0;34m'
Purple='\033[0;35m'
Cyan='\033[0;36m'
White='\033[0;37m'
# we use the same name each time we spin up a container to copy stuff out of
# makes it easier
HISTORY_CONTAINER_NAME="frontend-build-history"
# If no -single images are found we set this to true
# allows us to move into a special mode where we use non-single tagged images
# only used for first time hisotry builds
#SINGLE_IMAGE_FOUND=false
# where we send our full aggregated history to
OUTPUT_DIR=false
# where the current build is located
CURRENT_BUILD_DIR=false
# the quay repo we need to interact with
QUAYREPO=false
# debug mode. turns on verbose output.
DEBUG_MODE=false
# We first check for images tagged -single. If we don't find any we use normal SHA tagged images
# if this is true we will then take those SHA tagged images, retag them SHA-single, and push those back
# up. This is so subsequent builds will find -single images
PUSH_SINGLE_IMAGES=false
# Our default mode is to get images tagged -single
GET_SINGLE_IMAGES=true

QUAY_TOKEN=""
QUAY_USER=""

function quayLogin() {

  if [[ -z "$DOCKER_CONFIG" ]]; then

    DOCKER_CONFIG=$(mktemp -d -p "$HOME" docker_config_XXXXX)
    export DOCKER_CONFIG
  fi

  docker login -u="$QUAY_USER" --password-stdin quay.io <<< "$QUAY_TOKEN"
}

function debugMode() {
  if [ $DEBUG_MODE == true ]; then
    set -x
  fi
}

function validateArgs() {
  if [ -z "$QUAYREPO" ]; then
    printError "Error" "Quay repo is required"
    exit 1
  fi
  if [ -z "$OUTPUT_DIR" ]; then
    printError "Error" "Output directory is required"
    exit 1
  fi
  if [ -z "$CURRENT_BUILD_DIR" ]; then
    printError "Error" "Current build directory is required"
    exit 1
  fi
}

function printSuccess() {
  echo -e "${Blue}HISTORY: ${Green}$1${Color_Off} - $2"
}

function printError() {
   echo -e "${Blue}HISTORY: ${Red}$1${Color_Off} - $2"
}

function getArgs() {
  while getopts ":b:q:o:c:d:p:t:u:" opt; do
    case $opt in
      # quay.io/cloudservices/api-frontend etc
      q )
        QUAYREPO="$OPTARG"
        ;;
      o )
        OUTPUT_DIR="$OPTARG"
        ;;
      c )
        CURRENT_BUILD_DIR="$OPTARG"
        ;;
      d )
        DEBUG_MODE=true
        ;;
      p )
        PUSH_SINGLE_IMAGES="$OPTARG"
        ;;
      t )
        QUAY_TOKEN="$OPTARG"
        ;;
      u )
        QUAY_USER="$OPTARG"
        ;;
      \? )
        echo "Invalid option -$OPTARGV" >&2
        ;;
    esac
  done
}

function remakeHistoryDirectories() {
  rm -rf .history
  mkdir -p .history/{1..6}
}

function getGitHistory() {
  # Get the git history
  git log HEAD~1 --first-parent --oneline --format='format:%h' > .history/git_history
}

function getBuildImages() {
  # We count the number of images found to make sure we don't go over 6
  local HISTORY_FOUND_IMAGES=0
  # We track the history found backwards, from 6 down, because we need to build
  # history cumulative from the oldest to the newest
  local HISTORY_DEPTH=6
  local SINGLE_IMAGE=""
  local ITERATIONS=0
  local IMAGE_TEXT="Single-build"
  # Get the single build images
  for REF in $(cat .history/git_history); do
    if [ $ITERATIONS -eq 12 ]; then
      printError "Exiting image search after 12 iterations." ""
      break
    fi
    ITERATIONS=$((ITERATIONS+1))
    # A "single image" is an images with its tag postpended with "-single"
    # these images contain only a single build of the frontend
    # example: quay.io/cloudservices/api-frontend:7b1b1b1-single
    SINGLE_IMAGE=$QUAYREPO:$REF-$SINGLETAG
    IMAGE_TEXT="Single-build"

    printSuccess "Pulling single-build image" $SINGLE_IMAGE
    # Pull the image
    docker pull $SINGLE_IMAGE >/dev/null 2>&1
    # if the image is not found trying falling back to a non-single tagged build
    if [ $? -ne 0 ]; then
      SINGLE_IMAGE=$QUAYREPO:$REF
      IMAGE_TEXT="Fallback build"
      printError "Image not found. Trying build not tagged single." $SINGLE_IMAGE
      docker pull $SINGLE_IMAGE >/dev/null 2>&1
      if [ $? -ne 0 ]; then
        printError "Fallback build not found. Skipping." $SINGLE_IMAGE
        continue
      fi
    fi
    printSuccess "$IMAGE_TEXT image found" $SINGLE_IMAGE
    # Increment FOUND_IMAGES
    HISTORY_FOUND_IMAGES=$((HISTORY_FOUND_IMAGES+1))
    # Run the image
    docker rm -f $HISTORY_CONTAINER_NAME >/dev/null 2>&1
    docker run -d --name $HISTORY_CONTAINER_NAME $SINGLE_IMAGE >/dev/null 2>&1
    # If the run fails log out and move to next
    if [ $? -ne 0 ]; then
      printError "Failed to run image" $SINGLE_IMAGE
      continue
    fi
    printSuccess "Running $IMAGE_TEXT image" $SINGLE_IMAGE
    # Copy the files out of the docker container into the history level directory
    docker cp $HISTORY_CONTAINER_NAME:/opt/app-root/src/dist/. .history/$HISTORY_DEPTH >/dev/null 2>&1
    # if this fails try build
    # This block handles a corner case. Some apps (one app actually, just chrome)
    # may use the build directory instead of the dist directory.
    # we assume dist, because that's the standard, but if we don't find it we try build
    # if a build copy works then we change the output dir to build so thaat we end up with 
    # history in the finaly container
    if [ $? -ne 0 ]; then
      printError "Couldn't find dist on image, trying build..." $SINGLE_IMAGE
      docker cp $HISTORY_CONTAINER_NAME:/opt/app-root/src/build/. .history/$HISTORY_DEPTH >/dev/null 2>&1
      # If the copy fails log out and move to next
      if [ $? -ne 0 ]; then
        printError "Failed to copy files from image" $SINGLE_IMAGE
        continue
      fi
      # Set the current build dir to build instead of dist
      CURRENT_BUILD_DIR="build"
    fi
    printSuccess "Copied files from $IMAGE_TEXT image" $SINGLE_IMAGE
    # Stop the image
    docker stop $HISTORY_CONTAINER_NAME >/dev/null 2>&1
    # delete the container
    docker rm -f $HISTORY_CONTAINER_NAME >/dev/null 2>&1
    # if we've found 6 images we're done
    if [ $HISTORY_FOUND_IMAGES -eq 6 ]; then
      printSuccess "Found 6 images, stopping history search" $SINGLE_IMAGE
      break
    fi
    #Decrement history depth
    HISTORY_DEPTH=$((HISTORY_DEPTH-1))
  done
}

directory_exists_and_not_empty() {
  [[ -d "$1" ]] && [[ -n $(ls -A "$1") ]]
}

copyHistoryIntoOutputDir() {
  # Copy the files from the history level directories into the build directory
  for i in {6..1}; do
    if directory_exists_and_not_empty ".history/$i"; then
      if ! cp -rf .history/$i/* $OUTPUT_DIR; then
        printError "Failed to copy files from history level: " $i
        return 1
      fi
      printSuccess "Copied files from history level: " $i
    else
      printError "No history files on level $i, skipping."
    fi
  done
}

function copyCurrentBuildIntoOutputDir() {
  # Copy the original build into the output directory
  cp -rf $CURRENT_BUILD_DIR/* $OUTPUT_DIR
  if [ $? -ne 0 ]; then
    printError "Failed to copy files from current build dir" $CURRENT_BUILD_DIR
    return
  fi
  printSuccess "Copied files from current build dir" $CURRENT_BUILD_DIR
}

function copyOutputDirectoryIntoCurrentBuild() {
  # Copy the output directory into the current build directory
  cp -rf $OUTPUT_DIR/* $CURRENT_BUILD_DIR
  if [ $? -ne 0 ]; then
    printError "Failed to copy files from output dir" $OUTPUT_DIR
    return
  fi
  printSuccess "Copied files from output dir" $OUTPUT_DIR
}

function deleteBuildContainer() {
  # Delete the build container
  if ! docker rm -f "$HISTORY_CONTAINER_NAME"; then
    printError "Failed to delete build container" $HISTORY_CONTAINER_NAME
    return
  fi
  printSuccess "Deleted build container" $HISTORY_CONTAINER_NAME
}

running_in_ci() {
  [[ "$CI" == "true" ]]
}

function main() {
  getArgs $@
  validateArgs
  debugMode
  deleteBuildContainer
  remakeHistoryDirectories
  getGitHistory
  if running_in_ci; then
    quayLogin
  fi
  getBuildImages
  if ! copyHistoryIntoOutputDir; then
    printError "Error copying History into output dir!"
    return 1
  fi
  copyCurrentBuildIntoOutputDir
  copyOutputDirectoryIntoCurrentBuild
  printSuccess "History build complete" "Files available at $CURRENT_BUILD_DIR"
  deleteBuildContainer
}

main $@