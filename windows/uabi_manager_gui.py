#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import re
import shlex
import shutil
import socket
import subprocess
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk


REPO_ROOT = Path(__file__).resolve().parents[1]
STATE_ROOT = REPO_ROOT / "secrets" / "uabi-ui"
CONFIG_PATH = STATE_ROOT / "config.json"
STATE_PATH = STATE_ROOT / "state.json"
GATE_HOST = "172.16.10.36"
GATE_PORT = "22"
REMOTE_REPO = "~/ubai_gui"
REMOTE_ENV = "config/session.env"
REMOTE_REVERSE_KEY = "$HOME/uabi_gui_secrets/uabi_reverse_to_gate_ed25519"
LOCAL_REVERSE_KEY = STATE_ROOT / "reverse_keys" / "uabi_reverse_to_gate_ed25519"
LOCAL_CONTAINER_SSH_KEY = STATE_ROOT / "container_ssh" / "uabi_container_root_ed25519"
LOCAL_CONTAINER_SSH_PORT = "9922"
CONTAINER_SSH_PORT = "9922"
SPINNER_FRAMES = ("\\", "|", "/", "-")

DEFAULTS = {
    "uabi_user": "harry261",
    "uabi_key": "secrets/gate-node-ssh/keys/id_ed25519",
    "local_rdp_port": "9999",
    "xrdp_port": "33989",
    "xrdp_password": "1q2w3e",
    "partition": "gpu1",
    "time": "02:00:00",
    "cpus": "4",
    "mem": "16G",
    "gpus": "",
}


def load_json(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def save_json(path: Path, data: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def load_config() -> dict[str, str]:
    data = load_json(CONFIG_PATH)
    if "uabi_user" not in data and "gate_user" in data:
        data["uabi_user"] = data["gate_user"]
    if "uabi_key" not in data and "gate_key" in data:
        data["uabi_key"] = data["gate_key"]
    return data


def repo_relative(path_text: str) -> Path:
    path = Path(path_text)
    if path.is_absolute():
        return path
    return REPO_ROOT / path


def remote_cd_expr(path_text: str) -> str:
    if path_text.startswith("~/"):
        return '"$HOME/' + path_text[2:].replace('"', '\\"') + '"'
    return shlex.quote(path_text)


def env_export(name: str, value: str, *, allow_home: bool = False) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    if not allow_home:
        escaped = escaped.replace("$", "\\$")
    return f'export {name}="{escaped}"'


def ssh_target(values: dict[str, str]) -> str:
    return f'{values["uabi_user"]}@{GATE_HOST}'


def local_port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def find_ssh_keygen() -> str:
    for candidate in (
        shutil.which("ssh-keygen.exe"),
        shutil.which("ssh-keygen"),
        str(REPO_ROOT / "secrets" / "windows-sshd" / "openssh" / "OpenSSH-Win64" / "ssh-keygen.exe"),
    ):
        if candidate and Path(candidate).exists():
            return candidate
    raise RuntimeError("ssh-keygen을 찾을 수 없습니다.")


def restrict_private_key(path: Path) -> None:
    if os.name != "nt":
        return
    user = os.environ.get("USERNAME")
    if not user:
        return
    commands = [
        ["icacls", str(path), "/inheritance:r"],
        ["icacls", str(path), "/grant:r", f"{user}:F"],
        ["icacls", str(path), "/grant:r", "NT AUTHORITY\\SYSTEM:F"],
        ["icacls", str(path), "/grant:r", "BUILTIN\\Administrators:F"],
    ]
    for command in commands:
        subprocess.run(command, text=True, capture_output=True, check=False)


def append_managed_block(path: Path, begin: str, end: str, block: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    old = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = old.splitlines()
    new_lines: list[str] = []
    skipping = False
    for line in lines:
        if line.strip() == begin:
            skipping = True
            continue
        if line.strip() == end:
            skipping = False
            continue
        if not skipping:
            new_lines.append(line)
    managed_lines = block.strip("\n").splitlines()
    if new_lines:
        managed_lines.append("")
        managed_lines.extend(new_lines)
    path.write_text("\n".join(managed_lines).rstrip() + "\n", encoding="utf-8")


class UabiManager(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("UABI 계산노드 컨테이너 관리자")
        self.geometry("980x720")
        self.minsize(860, 620)

        saved = DEFAULTS.copy()
        saved.update({key: value for key, value in load_config().items() if key in DEFAULTS})
        self.vars = {key: tk.StringVar(value=value) for key, value in saved.items()}
        self.operation_state = "대기 중"
        self.connectable = False
        self.remote_relay_ok = False
        self.connectivity_check_running = False
        self.spinner_index = 0
        self.status_var = tk.StringVar(value="대기 중(접속 불가능)")
        self.connection_var = tk.StringVar(value="\\ 대기 중(접속 불가능)")
        self.job_var = tk.StringVar(value=load_json(STATE_PATH).get("job_id", ""))
        self.worker: threading.Thread | None = None
        self.stop_requested = threading.Event()
        self.messages: queue.Queue[tuple[str, str]] = queue.Queue()

        self._build_ui()
        self.after(100, self._drain_messages)
        self.after(250, self._tick_connection_indicator)

    def _build_ui(self) -> None:
        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)

        gate = ttk.LabelFrame(self, text="UABI 접속")
        gate.grid(row=0, column=0, padx=12, pady=(12, 6), sticky="ew")
        for col in range(6):
            gate.columnconfigure(col, weight=1)

        ttk.Label(gate, text="고정 게이트").grid(row=0, column=0, padx=6, pady=6, sticky="w")
        ttk.Label(gate, text=f"{GATE_HOST}:{GATE_PORT}").grid(row=0, column=1, padx=6, pady=6, sticky="w")
        self._entry(gate, "UABI user", "uabi_user", 0, 2, width=16)
        self._entry(gate, "UABI SSH key", "uabi_key", 1, 0, colspan=5)
        ttk.Button(gate, text="찾기", command=self._choose_key).grid(row=1, column=5, padx=6, pady=6, sticky="ew")

        res = ttk.LabelFrame(self, text="할당 자원 / root 접속 비밀번호")
        res.grid(row=1, column=0, padx=12, pady=6, sticky="ew")
        for col in range(8):
            res.columnconfigure(col, weight=1)

        self._entry(res, "Partition", "partition", 0, 0, width=12)
        self._entry(res, "Time", "time", 0, 2, width=12)
        self._entry(res, "CPU", "cpus", 0, 4, width=8)
        self._entry(res, "Memory", "mem", 0, 6, width=10)
        self._entry(res, "GPU", "gpus", 1, 0, width=8)
        self._entry(res, "Local RDP", "local_rdp_port", 1, 2, width=8)
        self._entry(res, "XRDP port", "xrdp_port", 1, 4, width=8)
        ttk.Label(res, text="XRDP user").grid(row=1, column=6, padx=6, pady=6, sticky="w")
        ttk.Label(res, text="root").grid(row=1, column=7, padx=6, pady=6, sticky="w")
        self._entry(res, "Root password", "xrdp_password", 2, 0, colspan=3, show="*")

        actions = ttk.Frame(self)
        actions.grid(row=2, column=0, padx=12, pady=6, sticky="ew")
        actions.columnconfigure(8, weight=1)
        ttk.Button(actions, text="컨테이너 켜기", command=self.start_vm).grid(row=0, column=0, padx=(0, 6))
        ttk.Button(actions, text="컨테이너 끄기", command=self.stop_vm).grid(row=0, column=1, padx=6)
        ttk.Button(actions, text="접속하기", command=self.connect_rdp).grid(row=0, column=2, padx=6)
        ttk.Button(actions, text="상태 새로고침", command=self.refresh_status).grid(row=0, column=3, padx=6)
        ttk.Label(actions, text="상태:").grid(row=0, column=4, padx=(16, 4))
        ttk.Label(actions, textvariable=self.status_var).grid(row=0, column=5, sticky="w")
        ttk.Label(actions, text="Job:").grid(row=0, column=6, padx=(16, 4))
        ttk.Label(actions, textvariable=self.job_var).grid(row=0, column=7, sticky="w")

        output_frame = ttk.LabelFrame(self, text="상태 / 자원 사용량")
        output_frame.grid(row=3, column=0, padx=12, pady=(6, 12), sticky="nsew")
        output_frame.columnconfigure(0, weight=1)
        output_frame.rowconfigure(0, weight=1)
        self.output = tk.Text(output_frame, wrap="word", height=20)
        self.output.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(output_frame, orient="vertical", command=self.output.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.output.configure(yscrollcommand=scroll.set)
        ttk.Label(output_frame, textvariable=self.connection_var).grid(row=1, column=0, columnspan=2, sticky="ew", padx=6, pady=(4, 6))

    def _entry(
        self,
        parent: ttk.Frame,
        label: str,
        key: str,
        row: int,
        column: int,
        *,
        colspan: int = 1,
        width: int | None = None,
        show: str | None = None,
    ) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=column, padx=6, pady=6, sticky="w")
        entry = ttk.Entry(parent, textvariable=self.vars[key], width=width, show=show)
        entry.grid(row=row, column=column + 1, columnspan=colspan, padx=6, pady=6, sticky="ew")

    def _choose_key(self) -> None:
        path = filedialog.askopenfilename(initialdir=str(REPO_ROOT / "secrets"))
        if path:
            try:
                self.vars["uabi_key"].set(str(Path(path).resolve().relative_to(REPO_ROOT)))
            except ValueError:
                self.vars["uabi_key"].set(path)

    def values(self) -> dict[str, str]:
        return {key: var.get().strip() for key, var in self.vars.items()}

    def save_config(self) -> None:
        self.write_config()
        self.log(f"[OK] 입력값 반영: {CONFIG_PATH}")

    def write_config(self) -> None:
        save_json(CONFIG_PATH, self.values())

    def save_state(self, **updates: str) -> None:
        state = load_json(STATE_PATH)
        state.update({k: v for k, v in updates.items() if v is not None})
        save_json(STATE_PATH, state)
        if "job_id" in updates:
            self.messages.put(("job", updates["job_id"]))

    def log(self, text: str) -> None:
        self.output.insert("end", text.rstrip() + "\n")
        self.output.see("end")

    def post_log(self, text: str) -> None:
        self.messages.put(("log", text))

    def post_status(self, text: str) -> None:
        self.messages.put(("status", text))

    def _drain_messages(self) -> None:
        while True:
            try:
                kind, text = self.messages.get_nowait()
            except queue.Empty:
                break
            if kind == "log":
                self.log(text)
            elif kind == "status":
                self.operation_state = text
                self._set_connection_text()
            elif kind == "job":
                self.job_var.set(text)
        self.after(100, self._drain_messages)

    def _tick_connection_indicator(self) -> None:
        if not self.connectable:
            self.spinner_index = (self.spinner_index + 1) % len(SPINNER_FRAMES)
        self._set_connection_text()
        if not self.connectivity_check_running:
            values = self.values()
            threading.Thread(target=self._check_connectivity_once, args=(values,), daemon=True).start()
        self.after(1000, self._tick_connection_indicator)

    def _set_connection_text(self) -> None:
        state = "접속 가능" if self.connectable else "접속 불가능"
        label = f"{self.operation_state}({state})"
        self.status_var.set(label)
        marker = "OK" if self.connectable else SPINNER_FRAMES[self.spinner_index]
        self.connection_var.set(f"{marker} {label}")

    def _check_connectivity_once(self, values: dict[str, str]) -> None:
        self.connectivity_check_running = True
        try:
            local_ok = local_port_open(int(values["local_rdp_port"]))
            remote_ok = False
            if local_ok:
                port = shlex.quote(values["local_rdp_port"])
                script = f"""
port={port}
if command -v nc >/dev/null 2>&1; then
  nc -z 127.0.0.1 "$port"
else
  timeout 3 bash -lc ":</dev/tcp/127.0.0.1/$port"
fi
"""
                result = self.run_remote(values, script, timeout=12)
                remote_ok = result.returncode == 0
            self.remote_relay_ok = remote_ok
            self.connectable = local_ok and remote_ok
        except Exception:
            self.connectable = False
        finally:
            self.connectivity_check_running = False

    def run_task(self, name: str, fn, *, allow_parallel: bool = False) -> None:
        if self.worker and self.worker.is_alive():
            if not allow_parallel:
                messagebox.showinfo("작업 진행 중", "이미 다른 작업이 실행 중입니다.")
                return

        def wrapper() -> None:
            self.post_status(name)
            try:
                next_status = fn()
            except Exception as exc:  # GUI boundary
                self.post_log(f"[ERROR] {exc}")
                self.post_status("오류")
            else:
                self.post_status(next_status if isinstance(next_status, str) else "대기 중")

        worker = threading.Thread(target=wrapper, daemon=True)
        if not allow_parallel:
            self.worker = worker
        worker.start()

    def ssh_base(self, values: dict[str, str]) -> list[str]:
        key = repo_relative(values["uabi_key"])
        return [
            "ssh.exe",
            "-i",
            str(key),
            "-p",
            GATE_PORT,
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "StrictHostKeyChecking=accept-new",
        ]

    def scp_base(self, values: dict[str, str]) -> list[str]:
        key = repo_relative(values["uabi_key"])
        return [
            "scp.exe",
            "-i",
            str(key),
            "-P",
            GATE_PORT,
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "StrictHostKeyChecking=accept-new",
        ]

    def run_remote(self, values: dict[str, str], script: str, *, timeout: int = 120) -> subprocess.CompletedProcess[str]:
        command = self.ssh_base(values) + [ssh_target(values), f"bash -lc {shlex.quote(script)}"]
        return subprocess.run(
            command,
            cwd=REPO_ROOT,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def ensure_reverse_key(self, values: dict[str, str]) -> None:
        LOCAL_REVERSE_KEY.parent.mkdir(parents=True, exist_ok=True)
        public_key = Path(str(LOCAL_REVERSE_KEY) + ".pub")
        if not LOCAL_REVERSE_KEY.exists() or not public_key.exists():
            keygen = find_ssh_keygen()
            if LOCAL_REVERSE_KEY.exists():
                LOCAL_REVERSE_KEY.unlink()
            if public_key.exists():
                public_key.unlink()
            self.post_log("[INFO] 내부 reverse tunnel key 생성 중...")
            subprocess.run(
                [
                    keygen,
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-C",
                    f"uabi-ui-reverse {values['uabi_user']}@{GATE_HOST}",
                    "-f",
                    str(LOCAL_REVERSE_KEY),
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=True,
            )
        restrict_private_key(LOCAL_REVERSE_KEY)

        setup = """
set -euo pipefail
mkdir -p "$HOME/.ssh" "$HOME/uabi_gui_secrets"
chmod 700 "$HOME/.ssh" "$HOME/uabi_gui_secrets"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
"""
        result = self.run_remote(values, setup, timeout=30)
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout or "reverse key remote setup failed").strip())

        target_dir = f"{ssh_target(values)}:~/uabi_gui_secrets/"
        upload = subprocess.run(
            self.scp_base(values) + [str(LOCAL_REVERSE_KEY), str(public_key), target_dir],
            cwd=REPO_ROOT,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=60,
            check=False,
        )
        if upload.returncode != 0:
            raise RuntimeError((upload.stderr or upload.stdout or "reverse key upload failed").strip())

        install = """
set -euo pipefail
priv="$HOME/uabi_gui_secrets/uabi_reverse_to_gate_ed25519"
pub="$HOME/uabi_gui_secrets/uabi_reverse_to_gate_ed25519.pub"
chmod 600 "$priv"
chmod 644 "$pub"
pub_line=$(cat "$pub")
if ! grep -qxF "$pub_line" "$HOME/.ssh/authorized_keys"; then
  printf '%s\\n' "$pub_line" >> "$HOME/.ssh/authorized_keys"
fi
chmod 600 "$HOME/.ssh/authorized_keys"
echo "[OK] 내부 reverse tunnel key 준비 완료"
"""
        result = self.run_remote(values, install, timeout=30)
        output = ((result.stdout or "") + (result.stderr or "")).strip()
        if output:
            self.post_log(output)
        if result.returncode != 0:
            raise RuntimeError("reverse key install failed")

    def ensure_container_ssh_key(self) -> str:
        LOCAL_CONTAINER_SSH_KEY.parent.mkdir(parents=True, exist_ok=True)
        public_key = Path(str(LOCAL_CONTAINER_SSH_KEY) + ".pub")
        if not LOCAL_CONTAINER_SSH_KEY.exists() or not public_key.exists():
            keygen = find_ssh_keygen()
            LOCAL_CONTAINER_SSH_KEY.unlink(missing_ok=True)
            public_key.unlink(missing_ok=True)
            self.post_log("[INFO] 내부 VSCode SSH key 생성 중...")
            subprocess.run(
                [
                    keygen,
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-C",
                    "uabi-container-root",
                    "-f",
                    str(LOCAL_CONTAINER_SSH_KEY),
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=True,
            )
        restrict_private_key(LOCAL_CONTAINER_SSH_KEY)
        self.write_vscode_ssh_config()
        return public_key.read_text(encoding="utf-8").strip()

    def write_vscode_ssh_config(self) -> None:
        identity = LOCAL_CONTAINER_SSH_KEY.resolve().as_posix()
        known_hosts = "NUL" if os.name == "nt" else "/dev/null"
        begin = "# >>> UABI managed container SSH"
        end = "# <<< UABI managed container SSH"
        block = f"""
{begin}
Host uabi-container
  HostName 127.0.0.1
  Port {LOCAL_CONTAINER_SSH_PORT}
  User root
  IdentityFile {identity}
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile {known_hosts}

Host localhost
  IdentityFile {identity}
{end}
"""
        append_managed_block(Path.home() / ".ssh" / "config", begin, end, block)
        self.post_log("[OK] VSCode SSH alias 준비: ssh://root@uabi-container")
        self.post_log(f"[INFO] localhost:{LOCAL_CONTAINER_SSH_PORT}에도 내부 key가 자동 적용됩니다.")

    def start_local_forward(self, values: dict[str, str]) -> None:
        rdp_port = int(values["local_rdp_port"])
        ssh_port = int(LOCAL_CONTAINER_SSH_PORT)
        if local_port_open(rdp_port) and local_port_open(ssh_port):
            self.post_log(f"[OK] 로컬 포워드가 이미 열려 있습니다: RDP 127.0.0.1:{rdp_port}, SSH 127.0.0.1:{ssh_port}")
            return
        self.stop_local_forward(values)

        STATE_ROOT.mkdir(parents=True, exist_ok=True)
        logs = STATE_ROOT / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        stdout = open(logs / "local-forward.stdout.log", "a", encoding="utf-8")
        stderr = open(logs / "local-forward.stderr.log", "a", encoding="utf-8")
        command = (
            self.ssh_base(values)
            + [
                "-o",
                "ExitOnForwardFailure=yes",
                "-o",
                "ServerAliveInterval=30",
                "-o",
                "ServerAliveCountMax=3",
                "-N",
                "-T",
                "-L",
                f"127.0.0.1:{rdp_port}:127.0.0.1:{rdp_port}",
                "-L",
                f"127.0.0.1:{ssh_port}:127.0.0.1:{ssh_port}",
                ssh_target(values),
            ]
        )
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
        proc = subprocess.Popen(
            command,
            cwd=REPO_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            creationflags=creationflags,
        )
        self.save_state(local_forward_pid=str(proc.pid))
        for _ in range(20):
            if local_port_open(rdp_port) and local_port_open(ssh_port):
                self.post_log(f"[OK] 로컬 포워드 시작: RDP 127.0.0.1:{rdp_port}, SSH 127.0.0.1:{ssh_port}, pid={proc.pid}")
                return
            proc.poll()
            if proc.returncode is not None:
                raise RuntimeError(f"local forward exited early: rc={proc.returncode}")
            threading.Event().wait(0.5)
        raise RuntimeError("local forward did not open within 10 seconds")

    def start_vm(self) -> None:
        self.stop_requested.clear()
        self.run_task("켜는 중", self._start_vm)

    def _start_vm(self) -> None:
        values = self.values()
        self.write_config()
        self.post_log(f"[OK] 입력값 반영: {CONFIG_PATH}")
        self.ensure_reverse_key(values)
        container_ssh_public_key = self.ensure_container_ssh_key()
        self.start_local_forward(values)
        self.cancel_remote_jobs(values)
        self.wait_remote_clear(values)
        if self.stop_requested.is_set():
            self.post_log("[INFO] 컨테이너 끄기 요청으로 새 job 제출을 중단했습니다.")
            return "꺼짐"

        env_lines = [
            env_export("UABI_SLURM_PARTITION", values["partition"]),
            env_export("UABI_SLURM_TIME", values["time"]),
            env_export("UABI_SLURM_CPUS_PER_TASK", values["cpus"]),
            env_export("UABI_SLURM_MEM", values["mem"]),
            env_export("UABI_SLURM_GPUS", values["gpus"]),
            env_export("UABI_CONTAINER_BACKEND", "enroot"),
            env_export("UABI_XRDP_PASSWORD", values["xrdp_password"]),
            env_export("UABI_XRDP_PORT_IN_CONTAINER", values["xrdp_port"]),
            env_export("UABI_CONTAINER_SSH_PORT", CONTAINER_SSH_PORT),
            env_export("UABI_CONTAINER_SSH_PUBLIC_KEY", container_ssh_public_key),
            env_export("UABI_REVERSE_SSH_TARGET", ssh_target(values)),
            env_export("UABI_REVERSE_SSH_PORT", GATE_PORT),
            env_export("UABI_REVERSE_LOCAL_PORT_ON_WINDOWS", values["local_rdp_port"]),
            env_export("UABI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS", LOCAL_CONTAINER_SSH_PORT),
            env_export("UABI_REVERSE_BIND_HOST", "127.0.0.1"),
            env_export("UABI_SSH_IDENTITY_FILE", REMOTE_REVERSE_KEY, allow_home=True),
        ]
        exports = "\n".join(env_lines)
        script = f"""
set -euo pipefail
cd {remote_cd_expr(REMOTE_REPO)}
base_env={shlex.quote(REMOTE_ENV)}
ui_env=config/ui-session.env
if [ ! -f "$base_env" ]; then
  echo "[ERROR] env file not found: $base_env" >&2
  exit 2
fi
cp "$base_env" "$ui_env"
cat >> "$ui_env" <<'UABI_UI_ENV'

# Appended by windows/uabi_manager_gui.py
{exports}
UABI_UI_ENV
out=$(./scripts/submit_xrdp_job.sh "$ui_env" 2>&1)
printf '%s\\n' "$out"
job=$(printf '%s\\n' "$out" | awk '/Submitted batch job/ {{print $4; exit}}')
if [ -n "$job" ]; then
  echo "UABI_UI_JOB_ID=$job"
fi
"""
        self.post_log("[INFO] Slurm job 제출 중...")
        result = self.run_remote(values, script, timeout=120)
        output = (result.stdout or "") + (result.stderr or "")
        self.post_log(output.rstrip() or f"[INFO] ssh rc={result.returncode}")
        if result.returncode != 0:
            raise RuntimeError(f"remote submit failed: rc={result.returncode}")
        match = re.search(r"UABI_UI_JOB_ID=(\d+)", output)
        if match:
            job_id = match.group(1)
            self.save_state(job_id=job_id)
            self.messages.put(("job", job_id))
            self.post_log(f"[OK] Job submitted: {job_id}")
            self._wait_until_ready(values, job_id)
            if self.stop_requested.is_set():
                return "꺼짐"
            return "켜짐"
        else:
            self.post_log("[WARN] job id를 찾지 못했습니다. 상태 새로고침으로 확인하세요.")
            return "대기 중"

    def _wait_until_ready(self, values: dict[str, str], job_id: str) -> None:
        script = f"""
set -euo pipefail
cd {remote_cd_expr(REMOTE_REPO)}
job={shlex.quote(job_id)}
for i in $(seq 1 90); do
  if grep -q "Reverse tunnel established" "logs/uabi-cst-xrdp-${{job}}.out" 2>/dev/null; then
    echo "[OK] Reverse tunnel established for job $job"
    exit 0
  fi
  if grep -q "\\[ERROR\\]" "logs/uabi-cst-xrdp-${{job}}.out" 2>/dev/null; then
    tail -n 80 "logs/uabi-cst-xrdp-${{job}}.out"
    exit 2
  fi
  sleep 5
done
squeue -j "$job" || true
tail -n 80 "logs/uabi-cst-xrdp-${{job}}.out" 2>/dev/null || true
exit 3
"""
        self.post_log("[INFO] XRDP/reverse tunnel 준비 대기 중...")
        result = self.run_remote(values, script, timeout=520)
        output = (result.stdout or "") + (result.stderr or "")
        self.post_log(output.rstrip())
        if result.returncode != 0:
            self.post_log(f"[WARN] 준비 대기 종료 rc={result.returncode}. 상태 새로고침으로 확인하세요.")

    def stop_vm(self) -> None:
        self.stop_requested.set()
        self.run_task("끄는 중", self._stop_vm, allow_parallel=True)

    def _stop_vm(self) -> None:
        values = self.values()
        state = load_json(STATE_PATH)
        job_id = state.get("job_id", "").strip()
        self.cancel_remote_jobs(values, preferred_job_id=job_id)
        self.stop_local_forward(values)
        self.save_state(job_id="")
        self.messages.put(("job", ""))
        return "꺼짐"

    def cancel_remote_jobs(self, values: dict[str, str], preferred_job_id: str = "") -> None:
        script = f"""
set -euo pipefail
preferred={shlex.quote(preferred_job_id)}
ids=""
if [ -n "$preferred" ]; then
  ids="$preferred"
fi
extra=$(squeue -h -u "$USER" -o "%i %j" | awk '$2 ~ /^uabi-cst/ {{print $1}}')
for id in $extra; do
  case " $ids " in
    *" $id "*) ;;
    *) ids="$ids $id" ;;
  esac
done
ids=$(printf '%s\\n' "$ids" | xargs 2>/dev/null || true)
if [ -z "$ids" ]; then
  echo "[INFO] 실행 중인 UABI XRDP job이 없습니다."
else
  echo "[INFO] scancel $ids"
  scancel $ids 2>/dev/null || true
fi
"""
        result = self.run_remote(values, script, timeout=60)
        output = ((result.stdout or "") + (result.stderr or "")).strip()
        if output:
            self.post_log(output)
        if result.returncode != 0:
            self.post_log(f"[WARN] scancel command rc={result.returncode}")

    def wait_remote_clear(self, values: dict[str, str]) -> None:
        script = f"""
set +e
rdp_port={shlex.quote(values["local_rdp_port"])}
ssh_port={shlex.quote(LOCAL_CONTAINER_SSH_PORT)}
for i in $(seq 1 30); do
  jobs=$(squeue -h -u "$USER" -o "%i %j" | awk '$2 ~ /^uabi-cst/ {{print $1}}')
  nc -z 127.0.0.1 "$rdp_port" >/dev/null 2>&1
  rdp_open=$?
  nc -z 127.0.0.1 "$ssh_port" >/dev/null 2>&1
  ssh_open=$?
  if [ -z "$jobs" ] && [ "$rdp_open" -ne 0 ] && [ "$ssh_open" -ne 0 ]; then
    echo "[OK] 기존 UABI XRDP job/relay 정리 완료"
    exit 0
  fi
  echo "[INFO] 기존 job/relay 정리 대기 중: jobs=${{jobs:-none}}, gate_rdp_open=$([ "$rdp_open" -eq 0 ] && echo yes || echo no), gate_ssh_open=$([ "$ssh_open" -eq 0 ] && echo yes || echo no)"
  sleep 2
done
echo "[WARN] 기존 job/relay 정리 확인 시간이 초과됐습니다. 계속 진행합니다."
"""
        result = self.run_remote(values, script, timeout=90)
        output = ((result.stdout or "") + (result.stderr or "")).strip()
        if output:
            self.post_log(output)

    def stop_local_forward(self, values: dict[str, str]) -> None:
        rdp_port = values["local_rdp_port"]
        ssh_port = LOCAL_CONTAINER_SSH_PORT
        command = rf"""
$patterns = @(
  "127.0.0.1:{rdp_port}:127.0.0.1:{rdp_port}",
  "127.0.0.1:{ssh_port}:127.0.0.1:{ssh_port}"
)
Get-CimInstance Win32_Process |
  Where-Object {{
    $cmd = $_.CommandLine
    $_.Name -eq "ssh.exe" -and ($patterns | Where-Object {{ $cmd -like "*$_*" }})
  }} |
  ForEach-Object {{
    Stop-Process -Id $_.ProcessId -Force
    Write-Output $_.ProcessId
  }}
"""
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        stopped = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if stopped:
            self.post_log(f"[OK] 로컬 포워드 종료 pid={', '.join(stopped)}")
        else:
            self.post_log("[INFO] 종료할 로컬 포워드가 없습니다.")

    def connect_rdp(self) -> None:
        values = self.values()
        port = values["local_rdp_port"]
        user = "root"
        password = values["xrdp_password"]
        subprocess.run(["cmdkey", "/generic:TERMSRV/127.0.0.1", f"/user:{user}", f"/pass:{password}"], check=False)
        subprocess.run(["cmdkey", f"/generic:TERMSRV/127.0.0.1:{port}", f"/user:{user}", f"/pass:{password}"], check=False)
        subprocess.Popen(["mstsc.exe", f"/v:127.0.0.1:{port}"], cwd=REPO_ROOT)
        self.log(f"[OK] mstsc.exe 실행: 127.0.0.1:{port}")

    def refresh_status(self) -> None:
        self.run_task("상태 확인 중", self._refresh_status)

    def _refresh_status(self) -> None:
        values = self.values()
        state = load_json(STATE_PATH)
        job_id = state.get("job_id", "").strip()
        script = f"""
set +e
cd {remote_cd_expr(REMOTE_REPO)}
job={shlex.quote(job_id)}
echo "--- Slurm jobs"
squeue -u "$USER" -o "%.18i|%.9P|%.32j|%.2t|%.10M|%.6D|%.8C|%.12m|%R"
if [ -z "$job" ] || ! squeue -h -j "$job" >/dev/null 2>&1; then
  job=$(squeue -h -u "$USER" -o "%i %j" | awk '$2 ~ /^uabi-cst/ {{print $1; exit}}')
fi
echo "--- Selected job"
echo "${{job:-none}}"
if [ -n "$job" ]; then
  echo "--- scontrol"
  scontrol show job "$job" | tr ' ' '\\n' | grep -E '^(JobId|JobName|JobState|RunTime|TimeLimit|NodeList|NumNodes|NumCPUs|MinMemory|ReqTRES|AllocTRES)='
  echo "--- sstat"
  sstat -j "$job.batch" --format=JobID,AveCPU,AveRSS,MaxRSS -P 2>/dev/null || true
  echo "--- Job log"
  tail -n 80 "logs/uabi-cst-xrdp-${{job}}.out" 2>/dev/null || true
fi
echo "--- Gate relay port"
(nc -vz 127.0.0.1 {shlex.quote(values["local_rdp_port"])} || true) 2>&1
echo "--- Gate container SSH port"
(nc -vz 127.0.0.1 {shlex.quote(LOCAL_CONTAINER_SSH_PORT)} || true) 2>&1
"""
        result = self.run_remote(values, script, timeout=90)
        output = (result.stdout or "") + (result.stderr or "")
        self.post_log(output.rstrip() or f"[INFO] ssh rc={result.returncode}")
        if result.returncode != 0:
            self.post_log(f"[WARN] status command rc={result.returncode}")
        if local_port_open(int(values["local_rdp_port"])):
            self.post_log(f"[OK] Windows local RDP port open: 127.0.0.1:{values['local_rdp_port']}")
        else:
            self.post_log(f"[WARN] Windows local RDP port closed: 127.0.0.1:{values['local_rdp_port']}")
        if local_port_open(int(LOCAL_CONTAINER_SSH_PORT)):
            self.post_log(f"[OK] Windows local SSH port open: 127.0.0.1:{LOCAL_CONTAINER_SSH_PORT}")
        else:
            self.post_log(f"[WARN] Windows local SSH port closed: 127.0.0.1:{LOCAL_CONTAINER_SSH_PORT}")


def main() -> int:
    app = UabiManager()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
