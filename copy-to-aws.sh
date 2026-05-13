a#!/bin/bash

set -e

#region Configuration
# Defaults (used only when not provided via CLI or environment)
DEFAULT_VM_DNS_NAME="ec2-18-116-69-17.us-east-2.compute.amazonaws.com"
DEFAULT_SSH_KEY_PATH="~/.ssh/Neumann_v1.0_API.pem"
DEFAULT_TARGET_FOLDER="/home/ec2-user/deployment"

VM_USER="ec2-user"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
#endregion

#region Logging functions

new_line() {
  echo "" >&2
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_help() {
  cat <<EOF
Usage:
  ./copy-to-aws.sh [options] <file1> [file2 ...]

Options:
  -v, --vm-dns-name <dns-name>      DNS name of the AWS VM where the files will
                                    be copied (overrides VM_DNS_NAME)
  -k, --ssh-key <path>              Path to SSH private key that provides
                                    access to the AWS VM (overrides SSH_KEY_PATH)
  -t, --target-folder <path>        Target folder on VM (overrides TARGET_FOLDER)
  -h, --help                        Show this help and exit

Environment variables:
  VM_DNS_NAME, SSH_KEY_PATH, TARGET_FOLDER

Precedence:
  command line > environment > defaults

Defaults:
  VM_DNS_NAME    = ${DEFAULT_VM_DNS_NAME}
  SSH_KEY_PATH   = ${DEFAULT_SSH_KEY_PATH}
  TARGET_FOLDER  = ${DEFAULT_TARGET_FOLDER}
EOF
}

parse_arguments() {
  ARG_HELP=false
  ARG_VM_DNS_NAME=""
  ARG_SSH_KEY_PATH=""
  ARG_TARGET_FOLDER=""
  FILES_TO_COPY=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        ARG_HELP=true
        shift
        ;;
      -v|--vm-dns-name)
        if [[ -z "${2:-}" ]]; then
          error "Missing value for $1"
          print_help >&2
          exit 1
        fi
        ARG_VM_DNS_NAME="$2"
        shift 2
        ;;
      -k|--ssh-key)
        if [[ -z "${2:-}" ]]; then
          error "Missing value for $1"
          print_help >&2
          exit 1
        fi
        ARG_SSH_KEY_PATH="$2"
        shift 2
        ;;
      -t|--target-folder)
        if [[ -z "${2:-}" ]]; then
          error "Missing value for $1"
          print_help >&2
          exit 1
        fi
        ARG_TARGET_FOLDER="$2"
        shift 2
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          FILES_TO_COPY+=("$1")
          shift
        done
        ;;
      -*)
        error "Unknown option: $1"
        print_help >&2
        exit 1
        ;;
      *)
        FILES_TO_COPY+=("$1")
        shift
        ;;
    esac
  done
}

title() {
  new_line
  log "=== $1 ==="
  new_line
}

debug() {
    if [[ $DEBUG == false ]]; then
        return
    fi
    echo -e "${CYAN}[DEBUG]${NC} $1" >&2
}
#endregion

#region Main function
main() {
  parse_arguments "$@"

  if [[ "$ARG_HELP" == true ]]; then
    print_help
    exit 0
  fi

  if [[ -n "$ARG_VM_DNS_NAME" ]]; then
    VM_DNS_NAME="$ARG_VM_DNS_NAME"
  elif [[ -z "${VM_DNS_NAME:-}" ]]; then
    VM_DNS_NAME="$DEFAULT_VM_DNS_NAME"
  fi

  if [[ -n "$ARG_SSH_KEY_PATH" ]]; then
    SSH_KEY_PATH="$ARG_SSH_KEY_PATH"
  elif [[ -z "${SSH_KEY_PATH:-}" ]]; then
    SSH_KEY_PATH="$DEFAULT_SSH_KEY_PATH"
  fi

  if [[ -n "$ARG_TARGET_FOLDER" ]]; then
    TARGET_FOLDER="$ARG_TARGET_FOLDER"
  elif [[ -z "${TARGET_FOLDER:-}" ]]; then
    TARGET_FOLDER="$DEFAULT_TARGET_FOLDER"
  fi

  title "Starting file copy to AWS VM: $VM_DNS_NAME"

  # Check if at least one file is provided
  if [[ ${#FILES_TO_COPY[@]} -eq 0 ]]; then
    error "No files provided to copy."
    print_help >&2
    exit 1
  fi

  ssh -i "$SSH_KEY_PATH" "$VM_USER"@"$VM_DNS_NAME" "mkdir -p $TARGET_FOLDER"
  
  log "Copying files to $VM_USER@$VM_DNS_NAME:$TARGET_FOLDER"
  # Copy files to VM
  for file_to_copy in "${FILES_TO_COPY[@]}"; do
    ssh -i "$SSH_KEY_PATH" "$VM_USER"@"$VM_DNS_NAME" "cat > $TARGET_FOLDER/$file_to_copy" < "$file_to_copy"
    # Check if the file is a shell script
    if [[ "$(file -b --mime-type -z "$file_to_copy")" == "text/x-shellscript" ]]; then
        ssh -i "$SSH_KEY_PATH" "$VM_USER"@"$VM_DNS_NAME" "chmod +x $TARGET_FOLDER/$file_to_copy"
    fi
    log "Copied file: $file_to_copy"
  done
  success "All files copied successfully to $VM_DNS_NAME"
}
#endregion

main "$@"