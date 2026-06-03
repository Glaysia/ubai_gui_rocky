# Security notes

## Recommended default

- Use SSH key authentication for the project-local Windows OpenSSH Server.
- Restrict Windows firewall `RemoteAddress` to UABI or campus egress IP if known.
- Use `127.0.0.1` for reverse tunnel bind host.
- Do not expose xrdp directly on a public interface.
- Do not expose the container sshd directly on a public interface.
- Do not commit `config/session.env`.
- Run the project-local `sshd.exe`; do not depend on the Windows system sshd service.

## Why bind reverse port to 127.0.0.1?

The Slurm job uses:

```bash
-R 127.0.0.1:9999:127.0.0.1:3389
-R 127.0.0.1:9922:127.0.0.1:9922
```

This means the RDP and container SSH endpoints are only visible from the Windows PC itself, not from the whole network.

## Passwords

`UABI_XRDP_PASSWORD` is currently passed by environment variable. For a productionized version, replace this with one of:

- prompt at job submission
- temporary file with strict permissions
- generated random password printed only to user
- SSH-tunneled one-time secret exchange

## Container SSH

The container opens `sshd` on `127.0.0.1:9922` only. The Windows GUI generates an internal key under `secrets/uabi-ui/container_ssh`, injects the public key into root `authorized_keys`, and writes a managed `Host uabi-container` block to the user's SSH config.

Do not enable unauthenticated root SSH. The tunnel is encrypted, but authentication still prevents any local process with access to `localhost:9922` from getting a root shell inside the job.

## Windows sshd

The Windows helper starts a project-local OpenSSH `sshd.exe` with a dedicated
config under `secrets/windows-sshd`. It does not use `Start-Service sshd` and
does not modify the Windows system sshd service.

Stop sshd:

```powershell
python windows\uabi_reverse_helper.py --stop
```
