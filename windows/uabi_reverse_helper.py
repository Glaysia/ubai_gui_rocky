#!/usr/bin/env python3
"""
Windows helper for UABI CST XRDP Runner.

What it does:
- Requests Administrator elevation when needed.
- Installs Windows OpenSSH Server capability if missing.
- Starts sshd service with Manual startup type.
- Creates/enables a Windows Defender Firewall rule for inbound SSH.
- Prints the command shape needed on the UABI side.

This helper does not store passwords and does not modify UABI.
"""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import socket
import subprocess
import sys


DEFAULT_RULE_NAME = "UABI-OpenSSH-Server-In-TCP"


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def relaunch_as_admin() -> None:
    script = str(Path(__file__).resolve())
    args = " ".join([f'"{arg}"' for arg in sys.argv[1:]])
    rc = ctypes.windll.shell32.ShellExecuteW(
        None,
        "runas",
        sys.executable,
        f'"{script}" {args}',
        None,
        1,
    )
    if int(rc) <= 32:
        raise RuntimeError(f"UAC elevation failed, ShellExecuteW returned {rc}")
    sys.exit(0)


def run_ps(command: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        ],
        text=True,
        capture_output=True,
        check=check,
    )


def ps_out(command: str) -> str:
    p = run_ps(command)
    return (p.stdout or "").strip()


def install_openssh_server_if_needed() -> None:
    state = ps_out(
        "(Get-WindowsCapability -Online "
        "| Where-Object Name -like 'OpenSSH.Server*' "
        "| Select-Object -ExpandProperty State)"
    )
    if "Installed" in state:
        print("[OK] OpenSSH Server is already installed.")
        return

    print("[INFO] Installing OpenSSH Server Windows capability...")
    run_ps("Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0")
    print("[OK] OpenSSH Server installed.")


def ensure_sshd_service(port: int) -> None:
    print("[INFO] Setting sshd startup type to Manual...")
    run_ps("Set-Service -Name sshd -StartupType Manual")

    if port != 22:
        config = r"$env:ProgramData\ssh\sshd_config"
        cmd = rf"""
$config = "{config}"
if (!(Test-Path $config)) {{
  New-Item -ItemType Directory -Force -Path (Split-Path $config) | Out-Null
  New-Item -ItemType File -Force -Path $config | Out-Null
}}
$content = Get-Content $config -ErrorAction SilentlyContinue
$content = $content | Where-Object {{ $_ -notmatch '^\s*Port\s+' }}
$content += "Port {port}"
Set-Content -Path $config -Value $content -Encoding ascii
"""
        run_ps(cmd)

    print("[INFO] Starting sshd...")
    run_ps("Start-Service sshd")
    status = ps_out("(Get-Service sshd).Status")
    print(f"[OK] sshd status: {status}")


def ensure_firewall_rule(port: int, rule_name: str, remote_address: str | None) -> None:
    print("[INFO] Creating/enabling Windows Defender Firewall rule...")
    remote = remote_address or "Any"
    command = rf"""
$rule = Get-NetFirewallRule -Name "{rule_name}" -ErrorAction SilentlyContinue
if ($null -eq $rule) {{
    New-NetFirewallRule `
      -Name "{rule_name}" `
      -DisplayName "UABI OpenSSH Server for Reverse Tunnel" `
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
    result = ps_out(command)
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


def print_summary(port: int, local_rdp_port: int) -> None:
    user = os.environ.get("USERNAME", "WINDOWS_USER")
    host = socket.gethostname()
    print()
    print("=== Windows side is ready ===")
    print(f"Windows user candidate: {user}")
    print(f"Windows host candidate: {host}")
    ips = ipv4_candidates()
    if ips:
        print("IPv4 candidates:")
        for ip in ips:
            print(f"  {ip}")
    print()
    print("Put one of these in config/session.env on UABI:")
    print()
    print(f'export UABI_REVERSE_SSH_TARGET="{user}@{host}"')
    print(f'export UABI_REVERSE_SSH_PORT="{port}"')
    print(f'export UABI_REVERSE_LOCAL_PORT_ON_WINDOWS="{local_rdp_port}"')
    print()
    print("After the Slurm job starts, open Windows Remote Desktop:")
    print(f"  mstsc.exe -> 127.0.0.1:{local_rdp_port}")
    print()
    print("If UABI cannot reach this Windows host, use VPN, port forwarding, or a relay server.")


def stop_sshd() -> None:
    print("[INFO] Stopping sshd...")
    run_ps("Stop-Service sshd", check=False)
    print("[OK] Stop-Service sshd requested.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare Windows OpenSSH Server for UABI reverse tunnel.")
    parser.add_argument("--port", type=int, default=22, help="Windows SSH server port. Default: 22")
    parser.add_argument("--local-rdp-port", type=int, default=13389, help="Windows localhost port used by reverse tunnel. Default: 13389")
    parser.add_argument("--rule-name", default=DEFAULT_RULE_NAME, help="Windows Firewall rule name")
    parser.add_argument("--remote-address", default=None, help="Optional UABI/campus source IP or CIDR to restrict inbound SSH")
    parser.add_argument("--stop", action="store_true", help="Stop sshd and exit")
    parser.add_argument("--no-install", action="store_true", help="Do not install OpenSSH Server if missing")
    args = parser.parse_args()

    if not is_admin():
        print("[INFO] Administrator permission is required. Requesting UAC elevation...")
        relaunch_as_admin()

    if args.stop:
        stop_sshd()
        return 0

    if not args.no_install:
        install_openssh_server_if_needed()

    ensure_sshd_service(args.port)
    ensure_firewall_rule(args.port, args.rule_name, args.remote_address)
    print_summary(args.port, args.local_rdp_port)

    print()
    print("Press Enter to leave sshd running and exit.")
    print("Type 'stop' then Enter to stop sshd now.")
    answer = input("> ").strip().lower()
    if answer == "stop":
        stop_sshd()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
