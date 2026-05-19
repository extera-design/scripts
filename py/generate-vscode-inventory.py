#!/usr/bin/env python3
"""Generate task and launch inventory CSVs from VS Code config files.

Outputs (by default, in repository root):
- task_inventory.csv
- launch_inventory.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path
from typing import Any


DEFAULT_TASK_GLOB = "**/.vscode/tasks.json"
DEFAULT_LAUNCH_GLOB = "**/.vscode/launch.json"


def strip_jsonc(text: str) -> str:
    """Remove only full-line // comments from JSONC text.

    This intentionally does not remove inline or block comments to avoid
    corrupting valid string content such as glob patterns containing "/*".
    """
    return re.sub(r"^\s*//.*$", "", text, flags=re.MULTILINE)


def load_jsonc(path: Path) -> dict[str, Any]:
    return json.loads(strip_jsonc(path.read_text(encoding="utf-8")))


def flatten_args(args: Any) -> str:
    if isinstance(args, list):
        return " ".join(str(x) for x in args)
    if args is None:
        return ""
    return str(args)


def derive_project_identifiers(root: Path, task_files: list[Path], launch_files: list[Path]) -> list[str]:
    identifiers: list[str] = []
    seen: set[str] = set()

    for config_path in sorted(set(task_files + launch_files)):
        parent = config_path.parent
        project_path = parent.parent if parent.name == ".vscode" else parent

        candidates: list[str] = []
        try:
            rel_project = project_path.relative_to(root)
            rel_text = rel_project.as_posix()
            if rel_text and rel_text != ".":
                candidates.append(rel_text)
        except ValueError:
            pass

        if project_path.name:
            candidates.append(project_path.name)

        for candidate in candidates:
            key = candidate.lower()
            if key not in seen:
                seen.add(key)
                identifiers.append(candidate)

    return identifiers


def infer_project(text: str, project_identifiers: list[str]) -> str:
    for candidate in project_identifiers:
        if candidate.lower() in text.lower():
            return candidate
    return ""


def classify_runnable_os(item: dict[str, Any]) -> str:
    has_windows = "windows" in item
    has_linux = "linux" in item
    command = str(item.get("command", "")).lower()

    if has_windows and not has_linux:
        return "Windows"
    if has_linux and not has_windows:
        return "Linux"
    if has_windows and has_linux:
        return "Windows; Linux"
    if "wsl" in command:
        return "Windows (WSL)"
    if command in {"cmd.exe", "powershell.exe", "pwsh", "pwsh.exe"}:
        return "Windows"
    return "Windows; Linux; macOS"


def classify_target_os(task: dict[str, Any]) -> str:
    label = str(task.get("label", ""))
    command = str(task.get("command", ""))
    args = flatten_args(task.get("args", []))
    detail = str(task.get("detail", ""))
    windows = task.get("windows", {}) if isinstance(task.get("windows"), dict) else {}
    linux = task.get("linux", {}) if isinstance(task.get("linux"), dict) else {}

    haystack = " ".join(
        [
            label,
            command,
            args,
            detail,
            str(windows.get("command", "")),
            flatten_args(windows.get("args", [])),
            str(linux.get("command", "")),
            flatten_args(linux.get("args", [])),
        ]
    ).lower()

    has_windows = any(token in haystack for token in ["win-x64", ".exe", " windows "]) or label.startswith("Windows ")
    has_linux = any(token in haystack for token in ["linux-x64", " linux ", "cmake", "wsl"]) or label.startswith("Linux ")
    has_al2023 = "amazon linux 2023" in haystack or "glibc 2.34" in haystack

    targets: list[str] = []
    if has_windows:
        targets.append("Windows")
    if has_linux:
        targets.append("Native Linux")
    if has_al2023:
        targets.append("AL2023")

    if targets:
        return "; ".join(dict.fromkeys(targets))

    if "dotnet" in haystack:
        return "Cross-platform (.NET)"
    return "Workspace/Tooling"


def classify_task_type(task: dict[str, Any]) -> str:
    label = str(task.get("label", "")).lower()
    detail = str(task.get("detail", "")).lower()
    command = str(task.get("command", "")).lower()
    text = f"{label} {detail} {command}"

    if "publish github release" in text or "release workflow" in text:
        return "release"
    if any(token in label for token in ["check status", ": start", ": stop", ": restart", ": install", ": uninstall"]):
        return "service-management"
    if "setup" in text:
        return "setup"
    if "help" in text or "build info" in text or " info" in label:
        return "info"
    if "publish" in text or re.search(r"\bnuget push\b", text):
        return "publish"
    if re.search(r"\btest\b", label) or re.search(r"\bdotnet test\b", text):
        return "test"
    if re.search(r"\brun\b", label):
        return "run"
    if re.search(r"\bbuild\b", label) or "yarn build" in text or "cmake --build" in text:
        return "build"
    return "orchestration"


def classify_build_configuration(task: dict[str, Any], task_type: str) -> str:
    if task_type != "build":
        return "N/A"

    text = " ".join(
        [
            str(task.get("label", "")),
            str(task.get("detail", "")),
            str(task.get("command", "")),
            flatten_args(task.get("args", [])),
        ]
    ).lower()

    has_debug = "debug" in text
    has_release = "release" in text
    has_test = "test" in text

    if has_debug and has_release:
        return "Mixed"
    if has_debug:
        return "Debug/development"
    if has_release:
        return "Release/production"
    if has_test:
        return "Test"
    return "Unspecified"


def classify_task_project(task: dict[str, Any], project_identifiers: list[str]) -> str:
    label = str(task.get("label", ""))
    detail = str(task.get("detail", ""))
    command = str(task.get("command", ""))
    args = flatten_args(task.get("args", []))
    depends_on = task.get("dependsOn", [])
    deps_text = " ".join(depends_on) if isinstance(depends_on, list) else str(depends_on)

    candidates: set[str] = set()
    for source in [label, detail, command, args, deps_text]:
        project = infer_project(source, project_identifiers)
        if project:
            candidates.add(project)

    if not candidates:
        return "workspace"
    if len(candidates) > 1:
        return "workspace"
    return next(iter(candidates))


def summarize_task(task: dict[str, Any]) -> str:
    command = str(task.get("command", "")).strip()
    args = flatten_args(task.get("args", [])).strip()
    depends_on = task.get("dependsOn", [])
    depends_text = ", ".join(depends_on) if isinstance(depends_on, list) else str(depends_on) if depends_on else ""

    windows = task.get("windows", {}) if isinstance(task.get("windows"), dict) else {}
    linux = task.get("linux", {}) if isinstance(task.get("linux"), dict) else {}
    windows_cmd = " ".join([str(windows.get("command", "")).strip(), flatten_args(windows.get("args", [])).strip()]).strip()
    linux_cmd = " ".join([str(linux.get("command", "")).strip(), flatten_args(linux.get("args", [])).strip()]).strip()

    options = task.get("options", {}) if isinstance(task.get("options"), dict) else {}
    cwd = str(options.get("cwd", "")).strip()

    parts: list[str] = []
    if command:
        parts.append(f"Runs `{(command + ' ' + args).strip()}`")
    if windows_cmd or linux_cmd:
        os_steps: list[str] = []
        if windows_cmd:
            os_steps.append(f"Windows uses `{windows_cmd}`")
        if linux_cmd:
            os_steps.append(f"Linux uses `{linux_cmd}`")
        parts.append("OS-specific steps: " + "; ".join(os_steps))
    if depends_text:
        parts.append(f"after dependencies [{depends_text}]")
    if cwd:
        parts.append(f"with working directory `{cwd}`")
    if not parts:
        parts.append("Orchestrates dependent tasks without directly executing a shell command")

    return ". ".join(parts) + "."


def classify_launch_runnable_os(cfg: dict[str, Any]) -> str:
    has_windows = "windows" in cfg
    has_linux = "linux" in cfg

    if has_windows and not has_linux:
        return "Windows"
    if has_linux and not has_windows:
        return "Linux"
    if has_windows and has_linux:
        return "Windows; Linux"

    name = str(cfg.get("name", "")).lower()
    runtime = str(cfg.get("runtimeExecutable", "")).lower()
    if name.startswith("windows ") or runtime in {"powershell.exe", "cmd.exe"}:
        return "Windows"
    if name.startswith("linux "):
        return "Linux"
    return "Windows; Linux; macOS"


def classify_launch_project(cfg: dict[str, Any], project_identifiers: list[str]) -> str:
    combined = " ".join(
        [
            str(cfg.get("name", "")),
            str(cfg.get("cwd", "")),
            str(cfg.get("program", "")),
            str(cfg.get("preLaunchTask", "")),
        ]
    )
    project = infer_project(combined, project_identifiers)
    return project or "workspace"


def summarize_launch(cfg: dict[str, Any]) -> str:
    request = str(cfg.get("request", "")).strip()
    runtime = str(cfg.get("runtimeExecutable", "")).strip()
    runtime_args = flatten_args(cfg.get("runtimeArgs", [])).strip()
    program = str(cfg.get("program", "")).strip()
    program_args = flatten_args(cfg.get("args", [])).strip()
    pre_launch = str(cfg.get("preLaunchTask", "")).strip()
    cwd = str(cfg.get("cwd", "")).strip()

    parts: list[str] = []
    if request == "attach":
        parts.append("Attaches a debugger to an already running process")
    else:
        parts.append("Launches a debugger session")

    if runtime:
        parts.append(f"using runtime `{(runtime + ' ' + runtime_args).strip()}`")
    if program:
        parts.append(f"for program `{program}` with args `{program_args}`")
    if pre_launch:
        parts.append(f"after running pre-launch task `{pre_launch}`")
    if cwd:
        parts.append(f"from working directory `{cwd}`")

    return ". ".join(parts) + "."


def collect_tasks(task_files: list[Path]) -> list[dict[str, Any]]:
    all_tasks: list[dict[str, Any]] = []
    for path in task_files:
        if not path.exists():
            continue
        data = load_jsonc(path)
        all_tasks.extend(data.get("tasks", []))

    seen: set[str] = set()
    unique: list[dict[str, Any]] = []
    for task in all_tasks:
        label = str(task.get("label", "")).strip()
        if not label or label in seen:
            continue
        seen.add(label)
        unique.append(task)
    return unique


def collect_launches(launch_files: list[Path]) -> list[dict[str, Any]]:
    all_cfgs: list[dict[str, Any]] = []
    for path in launch_files:
        if not path.exists():
            continue
        data = load_jsonc(path)
        all_cfgs.extend(data.get("configurations", []))

    seen: set[str] = set()
    unique: list[dict[str, Any]] = []
    for cfg in all_cfgs:
        name = str(cfg.get("name", "")).strip()
        if not name or name in seen:
            continue
        seen.add(name)
        unique.append(cfg)
    return unique


def is_task_visible(task: dict[str, Any]) -> bool:
    """Return True if the task appears in the VS Code Run Task picker.

    A task is hidden when its top-level hide property is set to true.
    Some task definitions may also place hide under presentation.
    """
    if bool(task.get("hide", False)):
        return False

    presentation = task.get("presentation", {})
    if isinstance(presentation, dict) and bool(presentation.get("hide", False)):
        return False

    return True


def write_task_csv(tasks: list[dict[str, Any]], output: Path, project_identifiers: list[str]) -> None:
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "task_name",
                "visible_to_user",
                "runnable_os",
                "target_os",
                "task_type",
                "build_configuration",
                "project",
                "detailed_description",
            ]
        )
        for task in tasks:
            task_name = str(task.get("label", ""))
            ttype = classify_task_type(task)
            writer.writerow(
                [
                    task_name,
                    "yes" if is_task_visible(task) else "no",
                    classify_runnable_os(task),
                    classify_target_os(task),
                    ttype,
                    classify_build_configuration(task, ttype),
                    classify_task_project(task, project_identifiers),
                    summarize_task(task),
                ]
            )


def write_launch_csv(launches: list[dict[str, Any]], output: Path, project_identifiers: list[str]) -> None:
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["launch_name", "runnable_os", "project", "detailed_description"])
        for cfg in launches:
            writer.writerow(
                [
                    str(cfg.get("name", "")),
                    classify_launch_runnable_os(cfg),
                    classify_launch_project(cfg, project_identifiers),
                    summarize_launch(cfg),
                ]
            )


def discover_config_files(root: Path, pattern: str) -> list[Path]:
    return sorted(path.resolve() for path in root.glob(pattern) if path.is_file())


def resolve_input_paths(root: Path, default_glob: str) -> list[Path]:
    return discover_config_files(root, default_glob)


def parse_args() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate VS Code task/launch inventory CSV files.",
        add_help=False,
    )
    parser.add_argument(
        "-h",
        "--help",
        action="store_true",
        help="Show detailed help and exit.",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Repository root path (defaults to two levels above this script)",
    )
    parser.add_argument(
        "--task-output",
        type=Path,
        default=Path("task_inventory.csv"),
        help="Task CSV output path (relative to --root unless absolute)",
    )
    parser.add_argument(
        "--launch-output",
        type=Path,
        default=Path("launch_inventory.csv"),
        help="Launch CSV output path (relative to --root unless absolute)",
    )
    return parser


def print_help(parser: argparse.ArgumentParser) -> None:
    print(parser.format_help())
    print(
        "Detailed notes:\n"
        "- Outputs:\n"
        "  - --task-output controls the task CSV path (default: task_inventory.csv).\n"
        "  - --launch-output controls the launch CSV path (default: launch_inventory.csv).\n"
        "- Task configs are auto-discovered from the repository tree using pattern: "
        f"{DEFAULT_TASK_GLOB}\n"
        "- Launch configs are auto-discovered from the repository tree using pattern: "
        f"{DEFAULT_LAUNCH_GLOB}\n"
        "- Project identifiers are derived from discovered .vscode config paths.\n"
        "- If no project matches, \"workspace\" is used.\n"
        "- Output paths are relative to --root unless absolute.\n"
        "\n"
        "Examples:\n"
        "  python3 generate-vscode-inventory.py --root .\n"
        "  python3 generate-vscode-inventory.py --root /repo\n"
        "  python3 generate-vscode-inventory.py --root . "
        "--task-output reports/tasks.csv "
        "--launch-output reports/launches.csv\n"
    )


def resolve_output(root: Path, output: Path) -> Path:
    return output if output.is_absolute() else root / output


def main() -> int:
    parser = parse_args()
    args = parser.parse_args()

    if args.help:
        print_help(parser)
        return 0

    root = args.root.resolve()

    task_files = resolve_input_paths(root, DEFAULT_TASK_GLOB)
    launch_files = resolve_input_paths(root, DEFAULT_LAUNCH_GLOB)
    projects = derive_project_identifiers(root, task_files, launch_files)

    if not task_files and not launch_files:
        raise SystemExit("No task or launch configuration files found. Verify --root.")

    tasks = collect_tasks(task_files)
    launches = collect_launches(launch_files)

    task_output = resolve_output(root, args.task_output)
    launch_output = resolve_output(root, args.launch_output)

    write_task_csv(tasks, task_output, projects)
    write_launch_csv(launches, launch_output, projects)

    print(f"Wrote {len(tasks)} tasks to {task_output}")
    print(f"Wrote {len(launches)} launch configurations to {launch_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
