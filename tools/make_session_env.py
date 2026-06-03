#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--template", default="config/example.env")
    p.add_argument("--output", default="config/session.env")
    p.add_argument("--gate-target", required=True, help="SSH target for the UBAI gate node, for example user@172.16.10.36")
    p.add_argument("--gate-port", default="22")
    p.add_argument("--local-rdp-port", default="9999")
    p.add_argument("--local-ssh-port", default="9922")
    p.add_argument("--container-ssh-port", default="9922")
    p.add_argument("--container-ssh-public-key", default="")
    p.add_argument("--xrdp-password", default="1q2w3e")
    args = p.parse_args()

    template = Path(args.template).read_text(encoding="utf-8")
    replacements = {
        'export UBAI_REVERSE_SSH_TARGET="UBAI_USER@172.16.10.36"':
            f'export UBAI_REVERSE_SSH_TARGET="{args.gate_target}"',
        'export UBAI_REVERSE_SSH_PORT="22"':
            f'export UBAI_REVERSE_SSH_PORT="{args.gate_port}"',
        'export UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS="9999"':
            f'export UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS="{args.local_rdp_port}"',
        'export UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS="9922"':
            f'export UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS="{args.local_ssh_port}"',
        'export UBAI_CONTAINER_SSH_PORT="9922"':
            f'export UBAI_CONTAINER_SSH_PORT="{args.container_ssh_port}"',
        'export UBAI_CONTAINER_SSH_PUBLIC_KEY=""':
            f'export UBAI_CONTAINER_SSH_PUBLIC_KEY="{args.container_ssh_public_key}"',
        'export UBAI_XRDP_PASSWORD="1q2w3e"':
            f'export UBAI_XRDP_PASSWORD="{args.xrdp_password}"',
    }
    out = template
    for k, v in replacements.items():
        out = out.replace(k, v)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(out, encoding="utf-8")
    print(f"[OK] wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
