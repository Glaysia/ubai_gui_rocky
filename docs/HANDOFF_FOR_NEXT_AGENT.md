# Handoff for next agent

This project is a skeleton, not a fully field-validated release.

## User intent

The user wants to provide a reproducible solution for colleagues who need to run CST Studio Suite on a university supercomputing/HPC environment called UABI. Pain points:

- Installing arbitrary software on Rocky Linux HPC is hard.
- GUI access from compute nodes is not available by default.
- Compute node inbound TCP is blocked.
- User quota/storage may be limited, but sshfs is intentionally excluded from this skeleton.
- RustDesk is considered too hard for non-expert users due to modern security prompts and remote-control semantics.

Proposed solution:

- `enroot` on compute node
- `docker://rockylinux:9.4`
- desktop environment plus OpenGL/X11 and CST dependencies
- xrdp server inside container
- sshd on `127.0.0.1:9922` inside container for VSCode Remote-SSH
- SSH reverse tunnel from compute node to Windows PC
- Windows helper script for project-local OpenSSH sshd
- Windows Remote Desktop Client connects to localhost forwarded port
- VSCode Remote-SSH connects to localhost forwarded port

## Important design decisions

### xrdp, not RustDesk

RustDesk was previously used in a separate tarball. It worked conceptually, but it is not ideal for colleagues. xrdp has a simpler mental model for Windows users.

### No sshfs in this skeleton

There is sshfs logic in `Glaysia/peetsfea-runner` around commit `4642e657213a857f907e2d80a9a66ba17c490d4d`. That is a separate AEDT/FEA persistent worker model. This skeleton intentionally leaves sshfs out because CST GUI/xrdp PoC does not require it.

### Windows SSHD is required for default mode

The reverse tunnel default mode assumes:

```text
compute node -> Windows PC project-local sshd
```

If Windows PC is behind NAT and not reachable, this will fail. Add a relay mode later.

## Next implementation tasks

1. Test `enroot import docker://rockylinux:9.4` on UABI login/compute node.
2. Validate package names on Rocky 9.4:
   - `xrdp`
   - `xorgxrdp`
   - `tigervnc-server`
   - `Xfce` group
   - `openmotif` or `motif`
3. xrdp is forced to the Xvnc backend because Xorg backend failed under the rootless container runtime.
4. Container sshd uses root plus GUI-managed public key. Do not enable unauthenticated root SSH.
5. `scripts/submit_xrdp_job.sh` defaults to enroot without checking the submit host. UABI gate has podman but no enroot; compute nodes have enroot but no podman.
6. Add explicit xrdp/sshd diagnostics.
7. Validate Windows helper on Windows 11.
8. Add relay-server mode.
9. CST integration:
   - collect actual CST Linux installer filename
   - identify silent install mode
   - add license server env var mapping
   - add launcher wrapper
10. OpenGL path:
   - identify whether UABI has GPU compute nodes
   - test `glxinfo`
   - optionally add VirtualGL/TurboVNC variant
11. Security:
   - restrict firewall remote address
   - never log xrdp password
   - support SSH key only mode

## Known risks

- xrdp inside enroot may require adjustments because enroot is not a full systemd VM.
- sshd inside enroot may require host key/runtime directory fixes in site images.
- xrdp package defaults may expect runtime directories not present in a container.
- SELinux is likely irrelevant inside enroot but PAM configs can still bite.
- CST GUI may run slowly under software OpenGL.
- Windows PC may not be reachable from compute node due to NAT.
- CST official support may reject Rocky Linux as non-RHEL even though it is RHEL-compatible.

## Testing checklist

On UABI:

```bash
cp config/example.env config/session.env
nano config/session.env
./scripts/build_image.sh config/session.env
./scripts/submit_xrdp_job.sh config/session.env
```

On Windows:

```powershell
python windows\uabi_reverse_helper.py --port 10022 --local-rdp-port 9999
netstat -ano | findstr 9999
netstat -ano | findstr 9922
mstsc.exe
ssh root@uabi-container
```

If `mstsc` reaches login screen but desktop is black:
- xrdp auth works
- session backend is broken
- inspect `/var/log/xrdp-sesman.log`
- keep the forced Xvnc backend and root `.Xclients` path working

If tunnel fails:
- check Windows sshd reachable from UABI
- check firewall
- try `ssh -vvv WINDOWS_USER@WINDOWS_HOST -p 10022`
- verify Windows account password/key auth
- check both reverse ports, 9999 for RDP and 9922 for container SSH
