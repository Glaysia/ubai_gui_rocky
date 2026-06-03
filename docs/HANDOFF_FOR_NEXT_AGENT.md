# Handoff For Next Agent

This project is a skeleton, not a fully field-validated release.

## User Intent

The user wants a reproducible tool for colleagues who need to run CST Studio Suite on the UBAI HPC environment. The current target is one allocated high-performance node with GUI access, not a multi-node automated simulation farm.

Pain points:

- Installing arbitrary software on Rocky Linux HPC is hard.
- GUI access from compute nodes is not available by default.
- Compute node inbound TCP is blocked.
- The UBAI gate node can accept normal SSH.
- The Windows PC should not run any SSH server.
- RustDesk is too hard to distribute cleanly to non-expert users.

## Current Solution

- Build a Rocky Linux 9.4 enroot image.
- Start XFCE, xrdp, and a container-local sshd inside the Slurm job.
- Open compute node -> gate node SSH reverse tunnels for RDP and container SSH.
- Open Windows PC -> gate node SSH local forwards for the same ports.
- Connect with `mstsc.exe` and VSCode Remote-SSH.

## Important Decisions

### No Windows SSH Server

The Windows PC is only an SSH client. Do not reintroduce a Windows-side SSH server or inbound firewall dependency. The relay path is:

```text
compute node -> gate node <- Windows PC
```

### xrdp, Not RustDesk

xrdp has a simpler mental model for Windows users and works with the built-in Remote Desktop Client.

### No sshfs In This Skeleton

There is sshfs logic in `Glaysia/peetsfea-runner`, but this project intentionally leaves it out. CST GUI/xrdp proof of concept does not require it.

### Backend Assumption

The UBAI gate node may have podman but no enroot. Compute nodes may have enroot but no podman. The GUI therefore defaults XRDP jobs to enroot and should not warn about podman fallback during normal operation.

## Next Tasks

1. Validate xrdp login and desktop startup on each target partition.
2. Keep explicit diagnostics for xrdp, container sshd, compute reachability, and gate relay reachability.
3. Add CST silent install support once the actual installer and license details are known.
4. Test OpenGL renderer and decide whether VirtualGL/TurboVNC is worth adding.
5. Avoid logging passwords or committing secrets.

## Testing Checklist

On Windows:

```powershell
python windows\ubai_manager_gui.py
netstat -ano | findstr 9999
netstat -ano | findstr 9922
mstsc.exe /v:127.0.0.1:9999
ssh root@ubai-container
```

On UBAI:

```bash
squeue -u "$USER"
tail -n 120 ~/ubai_gui/logs/ubai-cst-xrdp-<jobid>.out
nc -vz 127.0.0.1 9999
nc -vz 127.0.0.1 9922
```

If `mstsc` reaches login but the desktop fails, inspect `/var/log/xrdp-sesman.log`, `/work/logs/xrdp-sesman.stderr`, and the forced Xvnc configuration first.
