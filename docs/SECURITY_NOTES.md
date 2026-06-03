# Security Notes

## Recommended Default

- Do not run an SSH server on the Windows PC.
- Use only outbound SSH client connections from Windows to the UBAI gate node.
- Bind gate relay ports to `127.0.0.1`.
- Do not expose xrdp directly on a public interface.
- Do not expose the container sshd directly on a public interface.
- Do not commit `config/session.env` or files under `secrets/`.

## Tunnel Model

The Slurm job opens reverse ports on the gate node:

```bash
-R 127.0.0.1:9999:127.0.0.1:3389
-R 127.0.0.1:9922:127.0.0.1:9922
```

The Windows GUI then opens local forwards from this PC to the same gate ports:

```powershell
ssh.exe -L 127.0.0.1:9999:127.0.0.1:9999 user@172.16.10.36
ssh.exe -L 127.0.0.1:9922:127.0.0.1:9922 user@172.16.10.36
```

This keeps both RDP and container SSH bound to loopback on each machine.

## Passwords

`UBAI_XRDP_PASSWORD` is passed by environment variable for this proof of concept. For production use, replace it with one of:

- prompt at job submission
- temporary file with strict permissions
- generated one-time password shown only to the user
- SSH-tunneled one-time secret exchange

## Container SSH

The container opens `sshd` on `127.0.0.1:9922` only. The Windows GUI generates an internal key under `secrets/ubai-ui/container_ssh`, injects the public key into root `authorized_keys`, and writes a managed `Host ubai-container` block to the user's SSH config.

Do not enable unauthenticated root SSH. The connection is encrypted, but authentication still prevents any local process with access to `localhost:9922` from getting a root shell inside the job.
