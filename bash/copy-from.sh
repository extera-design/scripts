#!/bin/bash

set -eo pipefail

#region Configuration
# Defaults (used only when not provided via CLI or environment)
DEFAULT_TARGET_FOLDER="."
DEFAULT_REMOTE_USER="ec2-user"
IS_BINARY=false
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
Copies files from a remote SSH server to a local folder (the reverse of copy-to.sh).
Intended for retrieving files from AWS VMs or any SSH server.

Usage:
  ./copy-from.sh -v <dns-name> [options] <remote-file1> [remote-file2 ...]

Options:
  -v, --dns-name <dns-name>         DNS name of the remote machine to copy from
                                    (overrides REMOTE_DNS_NAME)
  -u, --remote-user <username>      Remote SSH username (overrides REMOTE_USER)
  -k, --ssh-key <path>              Optional path to the SSH private key for remote
                                    access (overrides SSH_KEY_PATH)
  -t, --target-folder <path>        Local folder where files will be saved
                                    (overrides TARGET_FOLDER)
  -b, --binary                      Treat the file(s) as binary; uses scp instead
                                    of cat (default: false)
  -M, --no-connection-reuse         Disable SSH connection multiplexing. By default,
                                    the script reuses a single authenticated connection
                                    for all ssh/scp calls to minimize password prompts.
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

  At least one remote file path to copy must be provided as a positional argument.
  Remote file paths support wildcard patterns (e.g., /path/*.sh, /path/config*.json)
  which are expanded on the remote server.

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
  - The script assumes the remote server is Linux-based and has 'cat' available.
  - For text files (default), the script reads the file via 'cat' over SSH. Any
    carriage returns (\r) in the source are stripped so local files always use
    LF line endings.
  - For binary files (-b), the script uses 'scp' to copy the file directly.
  - Shell scripts (.sh, .bash) are automatically made executable locally after copying.
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

  # Mandatory: DNS name
  if [[ -n "$ARG_VM_DNS_NAME" ]]; then
    REMOTE_DNS_NAME="$ARG_VM_DNS_NAME"
  elif [[ -z "${REMOTE_DNS_NAME:-}" ]]; then
    error "DNS name is required. Use -v/--dns-name or set REMOTE_DNS_NAME."
    print_help >&2
    exit 1
  fi

  # Optional: SSH key
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

  # Optional: local target folder
  if [[ -n "$ARG_TARGET_FOLDER" ]]; then
    TARGET_FOLDER="$ARG_TARGET_FOLDER"
  elif [[ -z "${TARGET_FOLDER:-}" ]]; then
    TARGET_FOLDER="$DEFAULT_TARGET_FOLDER"
  fi

  # Optional: remote user
  if [[ -n "$ARG_REMOTE_USER" ]]; then
    REMOTE_USER="$ARG_REMOTE_USER"
  elif [[ -z "${REMOTE_USER:-}" ]]; then
    REMOTE_USER="$DEFAULT_REMOTE_USER"
  fi

  # At least one file required
  if [[ ${#FILES_TO_COPY[@]} -eq 0 ]]; then
    error "No remote files provided to copy."
    print_help >&2
    exit 1
  fi
}
#endregion

#region Wildcard expansion
expand_remote_wildcards() {
  local pattern="$1"

  if [[ "$pattern" == *[\*\?\[]* ]]; then
    debug "Expanding wildcard pattern on remote: $pattern"
    # Pass the pattern unquoted so the remote shell expands it
    ssh "${SSH_ARGS[@]}" "$REMOTE_USER@$REMOTE_DNS_NAME" "ls -1 $pattern 2>/dev/null"
  else
    echo "$pattern"
  fi
}
#endregion

#region Copy functions
copy_text_files() {
  log "Copying files from $REMOTE_USER@$REMOTE_DNS_NAME to $TARGET_FOLDER"
  for remote_file in "${RESOLVED_FILES[@]}"; do
    local basename
    basename=$(basename "$remote_file")
    local local_path="$TARGET_FOLDER/$basename"

    # Read via cat on the remote; strip \r to ensure LF line endings locally
    ssh "${SSH_ARGS[@]}" "$REMOTE_USER@$REMOTE_DNS_NAME" "cat '$remote_file'" | tr -d '\r' > "$local_path"

    # Auto-chmod shell scripts
    if [[ "$basename" == *.sh || "$basename" == *.bash ]]; then
      chmod +x "$local_path"
      debug "Set executable: $local_path"
    fi

    log "Copied: $remote_file"
  done
  success "All files copied successfully from $REMOTE_DNS_NAME"
}

copy_binary_files() {
  log "Copying binary files from $REMOTE_USER@$REMOTE_DNS_NAME to $TARGET_FOLDER"
  for remote_file in "${RESOLVED_FILES[@]}"; do
    scp "${SSH_ARGS[@]}" "$REMOTE_USER@$REMOTE_DNS_NAME:'$remote_file'" "$TARGET_FOLDER/"
    log "Copied binary: $remote_file"
  done
  success "All binary files copied successfully from $REMOTE_DNS_NAME"
}
#endregion

#region Main function
main() {
  parse_arguments "$@"

  title "Starting file copy from remote machine: $REMOTE_DNS_NAME"

  # Expand wildcards and build the resolved file list
  RESOLVED_FILES=()
  for pattern in "${FILES_TO_COPY[@]}"; do
    while IFS= read -r resolved_file; do
      [[ -n "$resolved_file" ]] && RESOLVED_FILES+=("$resolved_file")
    done < <(expand_remote_wildcards "$pattern")
  done

  if [[ ${#RESOLVED_FILES[@]} -eq 0 ]]; then
    error "No remote files matched the provided patterns."
    exit 1
  fi

  log "Found ${#RESOLVED_FILES[@]} file(s) to copy"

  # Create local target directory
  mkdir -p "$TARGET_FOLDER"

  if [[ "$IS_BINARY" == true ]]; then
    copy_binary_files
  else
    copy_text_files
  fi
}
#endregion

main "$@"
