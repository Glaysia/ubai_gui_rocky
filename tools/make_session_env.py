#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--template", default="config/example.env")
    p.add_argument("--output", default="config/session.env")
    p.add_argument("--windows-target", required=True)
    p.add_argument("--windows-port", default="22")
    p.add_argument("--local-rdp-port", default="13389")
    p.add_argument("--xrdp-user", default="cstuser")
    p.add_argument("--xrdp-password", required=True)
    args = p.parse_args()

    template = Path(args.template).read_text(encoding="utf-8")
    replacements = {
        'export UABI_REVERSE_SSH_TARGET="WINDOWS_USER@WINDOWS_HOST_OR_IP"':
            f'export UABI_REVERSE_SSH_TARGET="{args.windows_target}"',
        'export UABI_REVERSE_SSH_PORT="22"':
            f'export UABI_REVERSE_SSH_PORT="{args.windows_port}"',
        'export UABI_REVERSE_LOCAL_PORT_ON_WINDOWS="13389"':
            f'export UABI_REVERSE_LOCAL_PORT_ON_WINDOWS="{args.local_rdp_port}"',
        'export UABI_XRDP_USER="cstuser"':
            f'export UABI_XRDP_USER="{args.xrdp_user}"',
        'export UABI_XRDP_PASSWORD="CHANGE_ME_LONG_PASSWORD"':
            f'export UABI_XRDP_PASSWORD="{args.xrdp_password}"',
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
