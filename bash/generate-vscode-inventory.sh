#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/../py/generate-vscode-inventory.py"

print_help() {
	cat <<'EOF'
Usage:
  generate-vscode-inventory.sh [options] [-- <python-args>]

Description:
  Wrapper around generate-vscode-inventory.py that injects repository-specific
	defaults and forwards arguments.

Options:
  -r, --root PATH   Root path of the repository.
                    Default: current directory.
  -h, --help        Show this help message and exit.

Behavior:
	- Resolves Python script path relative to this shell script location.
	- If config files are not explicitly provided, Python auto-discovers
		.vscode/tasks.json and .vscode/launch.json under --root.
  - Forwards any extra arguments to the Python script.

Forwarded Python arguments (accepted by generate-vscode-inventory.py):
	-h, --help                Show Python script help and exit.
	--task-output PATH        Output CSV for tasks.
	                          Default: task_inventory.csv (relative to --root).
	--launch-output PATH      Output CSV for launch configurations.
	                          Default: launch_inventory.csv (relative to --root).

Examples:
  ./generate-vscode-inventory.sh
  ./generate-vscode-inventory.sh --root /path/to/repo
	./generate-vscode-inventory.sh -r . --task-output reports/tasks.csv --launch-output reports/launches.csv
	./generate-vscode-inventory.sh -- --help
EOF
}

REPO_ROOT="$(pwd -P)"
FORWARDED_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		-r|--root)
			if [[ $# -lt 2 ]]; then
				echo "Error: --root requires a path argument." >&2
				exit 2
			fi
			REPO_ROOT="$2"
			shift 2
			;;
		-h|--help)
			print_help
			exit 0
			;;
		--)
			shift
			FORWARDED_ARGS+=("$@")
			break
			;;
		*)
			FORWARDED_ARGS+=("$1")
			shift
			;;
	esac
done

if [[ ! -d "$REPO_ROOT" ]]; then
	echo "Error: root path does not exist: $REPO_ROOT" >&2
	exit 2
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"

if [[ ! -f "$PYTHON_SCRIPT" ]]; then
	echo "Error: Python script not found: $PYTHON_SCRIPT" >&2
	exit 2
fi

python3 "$PYTHON_SCRIPT" \
	--root "${REPO_ROOT}" \
	"${FORWARDED_ARGS[@]}"
