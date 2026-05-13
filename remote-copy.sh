#!/bin/bash

set -e

#region Configuration
# Defaults (used only when not provided via CLI or environment)
DEFAULT_TARGET_FOLDER="/home/ec2-user/deployment"
DEFAULT_REMOTE_USER="ec2-user"
IS_BINARY=false
IS_EXECUTABLE=false
RESTART_SERVICE=false
NO_CONNECTION_REUSE=false
DEBUG=false

REMOTE_USER="ec2-user"

# Reuse a single authenticated SSH session for all ssh/scp calls in one script run.
SSH_CONNECTION_ARGS=(
  "-o" "ControlMaster=auto"
  "-o" "ControlPersist=5m"
  "-o" "ControlPath=~/.ssh/cm-%C"
)

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

#region Help
print_help() {
  cat <<EOF
Copies files to a remote SSH server (intended for copying to AWS VM but can be used
for any SSH server). Can also optionally restart a service on the remote server after
copying.

Usage:
  ./remote-copy.sh -v <dns-name> [options] <file1> [file2 ...]

Options:
  -v, --dns-name <dns-name>         DNS name of the remote machine where the files will
                                    be copied (overrides REMOTE_DNS_NAME)
  -u, --remote-user <username>      Remote SSH username (overrides REMOTE_USER)
  -k, --ssh-key <path>              Optional flag to provide the path to the SSH private key
                                    for access to the remote machine (overrides SSH_KEY_PATH)
  -t, --target-folder <path>        Target folder on remote machine (overrides TARGET_FOLDER)
  -b, --binary                      Optional flag to indicate the file(s) being copied
                                    are binary (default: false)
  -x, --executable                  Optional flag to set executable permissions on the
                                    copied file(s). Requires the file(s) to be binary
                                    file. It will be ignored if --binary is not set.
                                    (default: false)
  -r, --restart-service <service>   Optional flag to restart a service on the remote
                                    server after copying
  -M, --no-connection-reuse         Disable SSH connection multiplexing. By default, the
                                    script reuses a single authenticated connection for
                                    all ssh/scp calls to minimize password prompts.
                                    Use this flag to create separate connections
                                    (default: false)
  -d, --debug                       Enable verbose output for ssh/scp commands to help
                                    diagnose authentication and key issues
                                    (default: false)
  -h, --help                        Show this help and exit

Mandatory arguments:
  The following options must be provided either via command line or environment
  variables:
    -v, --dns-name <dns-name>       DNS name of the remote machine (can also be set via
                                    the REMOTE_DNS_NAME env variable)

  At least one file to copy must be provided as a positional argument.

Environment variables:
  REMOTE_DNS_NAME, SSH_KEY_PATH, TARGET_FOLDER, REMOTE_USER

Connection reuse:
  - The script enables SSH multiplexing (ControlMaster/ControlPersist) so that
    authentication typically happens once per run, and later ssh/scp commands
    reuse the same connection.

Precedence:
  command line > environment > defaults

Defaults:
  TARGET_FOLDER  = ${DEFAULT_TARGET_FOLDER}
  REMOTE_USER    = ${DEFAULT_REMOTE_USER}

Note:
  - The script assumes the remote server is Linux-based and has 'cat' and 'chmod'
  commands available.
  - When copying text files, the script uses 'cat' over SSH to create the file on the
  remote server, which can be more efficient for small to medium files and avoids
  issues with scp and text file line endings.
  - For binary files, the script uses 'scp' to copy the file directly.
  - If the --executable flag is set for binary files, the script will set executable
  permissions on the remote file after copying.
  - If the --binary flag is not set, the script will identify shell scripts and set
  executable permissions on the remote file after copying.
EOF
}
#endregion

#region Parsing arguments
parse_arguments() {
  ARG_HELP=false
  ARG_VM_DNS_NAME=""
  ARG_SSH_KEY_PATH=""
  ARG_TARGET_FOLDER=""
  ARG_REMOTE_USER=""
  FILES_TO_COPY=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        ARG_HELP=true
        shift
        ;;
      -v|--dns-name)
        if [[ -z "${2:-}" ]]; then
          error "Missing value for $1"
          print_help >&2
          exit 1
        fi
        ARG_VM_DNS_NAME="$2"
        shift 2
        ;;
      -u|--remote-user)
        if [[ -z "${2:-}" ]]; then
          error "Missing value for $1"
          print_help >&2
          exit 1
        fi
        ARG_REMOTE_USER="$2"
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
      -b|--binary)
        IS_BINARY=true
        shift
        ;;
      -x|--executable)
        IS_EXECUTABLE=true
        shift
        ;;
      -r|--restart-service)
        if [[ -z "${2:-}" ]]; then
          error "Missing value for $1"
          print_help >&2
          exit 1
        fi
        RESTART_SERVICE=true
        RESTART_SERVICE_NAME="$2"
        shift 2
        ;;
      -M|--no-connection-reuse)
        NO_CONNECTION_REUSE=true
        shift
        ;;
      -d|--debug)
        DEBUG=true
        shift
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
  if [[ "$ARG_HELP" == true ]]; then
    print_help
    exit 0
  fi

  # Parameter with fallback to environment variable, mandatory one of them must be set
  if [[ -n "$ARG_VM_DNS_NAME" ]]; then
    REMOTE_DNS_NAME="$ARG_VM_DNS_NAME"
  elif [[ -z "${REMOTE_DNS_NAME:-}" ]]; then
    print_help >&2
    exit 1
  fi

  # Parameter with fallback to environment variable, mandatory one of them must be set
  if [[ -n "$ARG_SSH_KEY_PATH" ]]; then
    SSH_KEY_PATH="$ARG_SSH_KEY_PATH"
  fi
  if [[ -z "${SSH_KEY_PATH:-}" ]]; then
    SSH_KEY_ARGS=()
  else
    SSH_KEY_ARGS=("-i" "$SSH_KEY_PATH")
  fi

  # Build SSH_ARGS with conditional connection reuse and debug settings
  SSH_ARGS=()
  if [[ "$NO_CONNECTION_REUSE" == false ]]; then
    SSH_ARGS+=("${SSH_CONNECTION_ARGS[@]}")
  fi
  SSH_ARGS+=("${SSH_KEY_ARGS[@]}")
  if [[ "$DEBUG" == true ]]; then
    SSH_ARGS+=("-v")
  fi

  # Optional parameter with fallback to environment variable and then default value
  if [[ -n "$ARG_TARGET_FOLDER" ]]; then
    TARGET_FOLDER="$ARG_TARGET_FOLDER"
  elif [[ -z "${TARGET_FOLDER:-}" ]]; then
    TARGET_FOLDER="$DEFAULT_TARGET_FOLDER"
  fi

  # Optional parameter with fallback to environment variable and then default value
  if [[ -n "$ARG_REMOTE_USER" ]]; then
    REMOTE_USER="$ARG_REMOTE_USER"
  elif [[ -z "${REMOTE_USER:-}" ]]; then
    REMOTE_USER="$DEFAULT_REMOTE_USER"
  fi

  # Check if at least one file is provided
  if [[ ${#FILES_TO_COPY[@]} -eq 0 ]]; then
    error "No files provided to copy."
    print_help >&2
    exit 1
  fi
}
#endregion

#region Copy functions
copy_text_files() {
  log "Copying files to $REMOTE_USER@$REMOTE_DNS_NAME:$TARGET_FOLDER"
  # Copy files to VM
  for file_to_copy in "${FILES_TO_COPY[@]}"; do
    ssh "${SSH_ARGS[@]}" "$REMOTE_USER"@"$REMOTE_DNS_NAME" "cat > $TARGET_FOLDER/$file_to_copy" < "$file_to_copy"
    # Check if the file is a shell script
    if [[ "$(file -b --mime-type -z "$file_to_copy")" == "text/x-shellscript" ]]; then
        ssh "${SSH_ARGS[@]}" "$REMOTE_USER"@"$REMOTE_DNS_NAME" "chmod +x $TARGET_FOLDER/$file_to_copy"
    fi
    log "Copied file: $file_to_copy"
  done
  success "All files copied successfully to $REMOTE_DNS_NAME"
}

copy_binary_files() {
  log "Copying binary files to $REMOTE_USER@$REMOTE_DNS_NAME:$TARGET_FOLDER"
  for file_to_copy in "${FILES_TO_COPY[@]}"; do
    scp "${SSH_ARGS[@]}" "$file_to_copy" "$REMOTE_USER"@"$REMOTE_DNS_NAME":"$TARGET_FOLDER/"
    if [[ "$IS_EXECUTABLE" == true ]]; then
      ssh "${SSH_ARGS[@]}" "$REMOTE_USER"@"$REMOTE_DNS_NAME" "chmod +x $TARGET_FOLDER/$(basename "$file_to_copy")"
    fi
    log "Copied binary file: $file_to_copy"
  done
  success "All binary files copied successfully to $REMOTE_DNS_NAME"
}

stop_service_if_running() {
  if ssh "${SSH_ARGS[@]}" "$REMOTE_USER"@"$REMOTE_DNS_NAME" "systemctl is-active --quiet $RESTART_SERVICE_NAME"; then
    log "Stopping service $RESTART_SERVICE_NAME on remote server..."
    ssh "${SSH_ARGS[@]}" "$REMOTE_USER"@"$REMOTE_DNS_NAME" "sudo systemctl stop $RESTART_SERVICE_NAME"
    log "Service $RESTART_SERVICE_NAME stopped"
  else
    log "Service $RESTART_SERVICE_NAME is not running, no need to stop"
  fi
}

start_service() {
  log "Starting service $RESTART_SERVICE_NAME on remote server..."
  ssh "${SSH_ARGS[@]}" "$REMOTE_USER"@"$REMOTE_DNS_NAME" "sudo systemctl start $RESTART_SERVICE_NAME"
  log "Service $RESTART_SERVICE_NAME started"
}
#endregion

#region Main function
main() {
  parse_arguments "$@"

  title "Starting file copy to remote machine: $REMOTE_DNS_NAME"

  ssh "${SSH_ARGS[@]}" "$REMOTE_USER"@"$REMOTE_DNS_NAME" "mkdir -p $TARGET_FOLDER"
  if [[ "$IS_BINARY" == true ]]; then
    if [[ "$RESTART_SERVICE" == true ]]; then
        stop_service_if_running
    fi
    copy_binary_files

    if [[ "$RESTART_SERVICE" == true ]]; then
        start_service
    fi
  else
    copy_text_files
  fi
}
#endregion

main "$@"