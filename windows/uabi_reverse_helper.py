#!/usr/bin/env python3
"""
Project-local Windows sshd helper for UABI CST XRDP Runner.

This helper does not use the system-wide Windows sshd service. It keeps a
portable OpenSSH for Windows tree under secrets/, writes a project-local
sshd_config, generates project-local host/client keys, and starts sshd.exe on
a user-selected high port.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys
import urllib.request
import zipfile


DEFAULT_ROOT = Path("secrets/windows-sshd")
DEFAULT_SSH_PORT = 10022
DEFAULT_LOCAL_RDP_PORT = 9999
DEFAULT_RULE_NAME = "UABI-Project-OpenSSH-Server-In-TCP"
GITHUB_LATEST_DOWNLOAD = (
    "https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download"
)


def run(
    argv: list[str],
    *,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        text=True,
        capture_output=capture,
        check=check,
    )


def ps(command: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        ],
        check=check,
    )


def to_config_path(path: Path) -> str:
    return path.resolve().as_posix()


def asset_name() -> str:
    machine = platform.machine().lower()
    if "arm64" in machine or "aarch64" in machine:
        return "OpenSSH-ARM64.zip"
    return "OpenSSH-Win64.zip" if "64" in machine else "OpenSSH-Win32.zip"


def safe_rmtree(path: Path, root: Path) -> None:
    path = path.resolve()
    root = root.resolve()
    if path == root or root not in path.parents:
        raise RuntimeError(f"refusing to delete path outside install root: {path}")
    if path.exists():
        shutil.rmtree(path)


def download_openssh(root: Path, *, force: bool, url: str | None) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    openssh_dir = root / "openssh"
    existing = find_sshd(openssh_dir)
    if existing and not force:
        print(f"[OK] Portable OpenSSH already exists: {existing}")
        return existing

    zip_path = root / "downloads" / asset_name()
    zip_path.parent.mkdir(parents=True, exist_ok=True)

    download_url = url or f"{GITHUB_LATEST_DOWNLOAD}/{asset_name()}"
    print(f"[INFO] Downloading portable OpenSSH from GitHub: {download_url}")
    tmp_zip = zip_path.with_suffix(zip_path.suffix + ".tmp")
    if tmp_zip.exists():
        tmp_zip.unlink()
    with urllib.request.urlopen(download_url, timeout=120) as response:
        tmp_zip.write_bytes(response.read())
    tmp_zip.replace(zip_path)

    if force:
        safe_rmtree(openssh_dir, root)

    print(f"[INFO] Extracting: {zip_path}")
    openssh_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(openssh_dir)

    sshd = find_sshd(openssh_dir)
    if not sshd:
        raise RuntimeError(f"sshd.exe not found after extracting {zip_path}")
    print(f"[OK] Installed portable OpenSSH: {sshd}")
    return sshd


def find_sshd(root: Path) -> Path | None:
    if not root.exists():
        return None
    direct = root / "sshd.exe"
    if direct.exists():
        return direct
    matches = sorted(root.rglob("sshd.exe"))
    return matches[0] if matches else None


def find_sshkeygen(sshd: Path) -> Path:
    keygen = sshd.parent / "ssh-keygen.exe"
    if not keygen.exists():
        raise RuntimeError(f"ssh-keygen.exe not found next to {sshd}")
    return keygen


def restrict_acl(path: Path) -> None:
    if os.name != "nt":
        return
    resolved = str(path.resolve())
    user = os.environ.get("USERNAME")
    if not user:
        return
    computer = os.environ.get("COMPUTERNAME")
    commands = [
        ["icacls", resolved, "/inheritance:r"],
        ["icacls", resolved, "/grant:r", f"{user}:F"],
        ["icacls", resolved, "/grant:r", "NT AUTHORITY\\SYSTEM:F"],
        ["icacls", resolved, "/grant:r", "BUILTIN\\Administrators:F"],
    ]
    if computer:
        commands.append(["icacls", resolved, "/remove:g", f"{computer}\\CodexSandboxUsers"])
    for cmd in commands:
        run(cmd, check=False)


def generate_key(ssh_keygen: Path, path: Path, comment: str) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"[INFO] Generating key: {path}")
    run(
        [
            str(ssh_keygen),
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            comment,
            "-f",
            str(path),
        ],
        check=True,
    )
    restrict_acl(path)


def write_authorized_keys(path: Path, public_key: Path) -> None:
    pub = public_key.read_text(encoding="ascii").strip()
    if not pub:
        raise RuntimeError(f"empty public key: {public_key}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(pub + "\n", encoding="ascii", newline="\n")
    restrict_acl(path)


def write_config(root: Path, sshd: Path, *, port: int, user: str) -> Path:
    runtime = root / "runtime"
    logs = root / "logs"
    runtime.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)

    config = root / "sshd_config"
    host_key = root / "host_keys" / "ssh_host_ed25519_key"
    authorized_keys = root / "authorized_keys"
    pid_file = runtime / "sshd.pid"

    text = f"""# Generated by windows/uabi_reverse_helper.py
Port {port}
ListenAddress 0.0.0.0
HostKey {to_config_path(host_key)}
PidFile {to_config_path(pid_file)}
AuthorizedKeysFile {to_config_path(authorized_keys)}

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
GSSAPIAuthentication no
StrictModes no
PerSourcePenalties no

AllowUsers {user}
AllowTcpForwarding remote
GatewayPorts no
PermitTunnel no
X11Forwarding no
AllowAgentForwarding no
PermitTTY no
PermitUserEnvironment no
PermitEmptyPasswords no

Subsystem sftp internal-sftp
LogLevel VERBOSE
"""
    config.write_text(text, encoding="ascii", newline="\n")
    return config


def pid_path(root: Path) -> Path:
    return root / "runtime" / "project-sshd.pid"


def process_running(pid: int) -> bool:
    result = subprocess.run(
        ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
        text=True,
        capture_output=True,
        check=False,
    )
    return str(pid) in result.stdout


def stop_project_sshd(root: Path) -> None:
    stop_project_sshd_by_command_line(root)
    pid_file = pid_path(root)
    if not pid_file.exists():
        print("[INFO] No project sshd pid file found.")
        return
    pid_text = pid_file.read_text(encoding="ascii").strip()
    if not pid_text.isdigit():
        pid_file.unlink(missing_ok=True)
        print("[WARN] Invalid pid file removed.")
        return
    pid = int(pid_text)
    print(f"[INFO] Stopping project sshd pid={pid}")
    run(["taskkill", "/PID", str(pid), "/T", "/F"], check=False)
    pid_file.unlink(missing_ok=True)


def stop_project_sshd_by_command_line(root: Path) -> None:
    if os.name != "nt":
        return
    marker = str(root.resolve())
    command = rf"""
$marker = "{marker}"
Get-CimInstance Win32_Process |
  Where-Object {{ $_.Name -in @("sshd.exe", "sshd-session.exe") }} |
  Where-Object {{ $_.CommandLine -like "*$marker*" }} |
  ForEach-Object {{
    Stop-Process -Id $_.ProcessId -Force
    Write-Output $_.ProcessId
  }}
"""
    result = ps(command, check=False)
    for line in result.stdout.splitlines():
        line = line.strip()
        if line:
            print(f"[INFO] Stopped project sshd pid={line}")


def start_project_sshd(
    root: Path,
    sshd: Path,
    config: Path,
    *,
    foreground: bool,
    port: int,
    local_rdp_port: int,
    user: str,
) -> None:
    if not (foreground and os.environ.get("UABI_PROJECT_SSHD_CHILD") == "1"):
        stop_stale_pid(root)
    logs = root / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    args = [str(sshd), "-D", "-e", "-f", str(config.resolve())]
    check = run([str(sshd), "-t", "-f", str(config.resolve())], check=False)
    if check.returncode != 0:
        raise RuntimeError((check.stderr or check.stdout or "").strip())

    if foreground:
        print("[INFO] Starting project sshd in foreground.")
        print("       " + " ".join(args))
        subprocess.run(args, check=False)
        return

    stdout = open(logs / "sshd-wrapper.stdout.log", "a", encoding="utf-8")
    stderr = open(logs / "sshd-wrapper.stderr.log", "a", encoding="utf-8")
    creationflags = 0
    if os.name == "nt":
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP
    wrapper_args = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--root",
        str(root),
        "--port",
        str(port),
        "--local-rdp-port",
        str(local_rdp_port),
        "--user",
        user,
        "--foreground",
    ]
    env = os.environ.copy()
    env["UABI_PROJECT_SSHD_CHILD"] = "1"
    proc = subprocess.Popen(
        wrapper_args,
        stdout=stdout,
        stderr=stderr,
        stdin=subprocess.DEVNULL,
        creationflags=creationflags,
        env=env,
    )
    pid_path(root).parent.mkdir(parents=True, exist_ok=True)
    pid_path(root).write_text(str(proc.pid), encoding="ascii")
    print(f"[OK] Started project sshd wrapper pid={proc.pid}")
    print(f"[INFO] Logs: {logs}")


def stop_stale_pid(root: Path) -> None:
    pid_file = pid_path(root)
    if not pid_file.exists():
        return
    pid_text = pid_file.read_text(encoding="ascii").strip()
    if pid_text.isdigit() and process_running(int(pid_text)):
        raise RuntimeError(f"project sshd already appears to be running: pid={pid_text}")
    pid_file.unlink(missing_ok=True)


def status(root: Path) -> None:
    pid_file = pid_path(root)
    if not pid_file.exists():
        print("[INFO] Project sshd is not running.")
        return
    pid_text = pid_file.read_text(encoding="ascii").strip()
    running = pid_text.isdigit() and process_running(int(pid_text))
    print(f"[INFO] Project sshd pid={pid_text}, running={running}")


def ensure_firewall_rule(port: int, rule_name: str, remote_address: str | None) -> None:
    remote = remote_address or "Any"
    command = rf"""
$rule = Get-NetFirewallRule -Name "{rule_name}" -ErrorAction SilentlyContinue
if ($null -eq $rule) {{
    New-NetFirewallRule `
      -Name "{rule_name}" `
      -DisplayName "UABI Project OpenSSH Server for Reverse Tunnel" `
      -Enabled True `
      -Direction Inbound `
      -Protocol TCP `
      -Action Allow `
      -LocalPort {port} `
      -RemoteAddress "{remote}" `
      -Profile Any | Out-Null
    Write-Output "created"
}} else {{
    Set-NetFirewallRule -Name "{rule_name}" -Enabled True -Profile Any | Out-Null
    $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule
    Set-NetFirewallPortFilter -InputObject $portFilter -Protocol TCP -LocalPort {port} | Out-Null
    $addrFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule
    Set-NetFirewallAddressFilter -InputObject $addrFilter -RemoteAddress "{remote}" | Out-Null
    Write-Output "updated"
}}
"""
    result = ps(command, check=True).stdout.strip()
    print(f"[OK] Firewall rule {result}: {rule_name}, port={port}, remote={remote}")


def ipv4_candidates() -> list[str]:
    out: list[str] = []
    hostname = socket.gethostname()
    try:
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in out:
                out.append(ip)
    except OSError:
        pass
    return out


def print_summary(root: Path, *, port: int, local_rdp_port: int, user: str) -> None:
    host = socket.gethostname()
    client_key = root / "client_keys" / "uabi_reverse_ed25519"
    print()
    print("=== Project-local Windows sshd is ready ===")
    print(f"Windows user: {user}")
    print(f"Windows hostname: {host}")
    print(f"Project sshd port: {port}")
    print(f"Windows localhost RDP tunnel port: {local_rdp_port}")
    ips = ipv4_candidates()
    if ips:
        print("IPv4 candidates:")
        for ip in ips:
            print(f"  {ip}")
    print()
    print("Copy this private key to UABI and chmod 600 it:")
    print(f"  {client_key.resolve()}")
    print()
    print("Put these values in config/session.env on UABI:")
    print()
    print(f'export UABI_REVERSE_SSH_TARGET="{user}@WINDOWS_HOST_OR_IP"')
    print(f'export UABI_REVERSE_SSH_PORT="{port}"')
    print(f'export UABI_REVERSE_LOCAL_PORT_ON_WINDOWS="{local_rdp_port}"')
    print('export UABI_SSH_IDENTITY_FILE="/path/on/uabi/to/uabi_reverse_ed25519"')
    print()
    print("After the Slurm job starts, open Windows Remote Desktop:")
    print(f"  mstsc.exe -> 127.0.0.1:{local_rdp_port}")


def prepare(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    root = args.root.resolve()
    sshd = download_openssh(root, force=args.force_install, url=args.download_url)
    ssh_keygen = find_sshkeygen(sshd)

    host_key = root / "host_keys" / "ssh_host_ed25519_key"
    generate_key(ssh_keygen, host_key, f"uabi-project-sshd-host {socket.gethostname()}")

    if args.client_public_key:
        public_key = Path(args.client_public_key).resolve()
        if not public_key.exists():
            raise FileNotFoundError(public_key)
    else:
        client_key = root / "client_keys" / "uabi_reverse_ed25519"
        generate_key(
            ssh_keygen,
            client_key,
            f"uabi-reverse-client {socket.gethostname()}",
        )
        public_key = client_key.with_suffix(client_key.suffix + ".pub")

    write_authorized_keys(root / "authorized_keys", public_key)
    config = write_config(root, sshd, port=args.port, user=args.user)
    return root, sshd, config


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run a project-local OpenSSH sshd for UABI reverse tunnels.",
    )
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="Project-local sshd state directory.")
    parser.add_argument("--port", type=int, default=DEFAULT_SSH_PORT, help="Project sshd listen port. Default: 10022")
    parser.add_argument("--local-rdp-port", type=int, default=DEFAULT_LOCAL_RDP_PORT, help="Windows localhost RDP tunnel port. Default: 9999")
    parser.add_argument("--user", default=os.environ.get("USERNAME", "WINDOWS_USER"), help="Windows user allowed to authenticate.")
    parser.add_argument("--download-url", default=None, help="Override portable OpenSSH ZIP URL.")
    parser.add_argument("--force-install", action="store_true", help="Delete and re-download portable OpenSSH from GitHub.")
    parser.add_argument("--client-public-key", default=None, help="Public key allowed for UABI -> Windows reverse SSH.")
    parser.add_argument("--prepare-only", action="store_true", help="Download/generate config and keys, but do not start sshd.")
    parser.add_argument("--foreground", action="store_true", help="Run sshd in foreground for debugging.")
    parser.add_argument("--stop", action="store_true", help="Stop the project-local sshd using its pid file.")
    parser.add_argument("--status", action="store_true", help="Show project-local sshd status.")
    parser.add_argument("--add-firewall-rule", action="store_true", help="Create/update a Windows Defender Firewall rule for this port.")
    parser.add_argument("--rule-name", default=DEFAULT_RULE_NAME, help="Windows Firewall rule name.")
    parser.add_argument("--remote-address", default=None, help="Optional UABI/campus source IP or CIDR for the firewall rule.")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    args.root = args.root.resolve()

    if args.stop:
        stop_project_sshd(args.root)
        return 0

    if args.status:
        status(args.root)
        return 0

    root, sshd, config = prepare(args)

    if args.add_firewall_rule:
        ensure_firewall_rule(args.port, args.rule_name, args.remote_address)

    if not args.prepare_only:
        start_project_sshd(
            root,
            sshd,
            config,
            foreground=args.foreground,
            port=args.port,
            local_rdp_port=args.local_rdp_port,
            user=args.user,
        )

    print_summary(root, port=args.port, local_rdp_port=args.local_rdp_port, user=args.user)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
