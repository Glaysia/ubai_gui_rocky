# Security notes

## Recommended default

- Use SSH key authentication for Windows OpenSSH Server.
- Restrict Windows firewall `RemoteAddress` to UABI or campus egress IP if known.
- Use `127.0.0.1` for reverse tunnel bind host.
- Do not expose xrdp directly on a public interface.
- Do not commit `config/session.env`.

## Why bind reverse port to 127.0.0.1?

The Slurm job uses:

```bash
-R 127.0.0.1:13389:127.0.0.1:3389
```

This means the RDP endpoint is only visible from the Windows PC itself, not from the whole network.

## Passwords

`UABI_XRDP_PASSWORD` is currently passed by environment variable. For a productionized version, replace this with one of:

- prompt at job submission
- temporary file with strict permissions
- generated random password printed only to user
- SSH-tunneled one-time secret exchange

## Windows sshd

The Windows helper sets `sshd` startup type to Manual, not Automatic. This is intentional. Users should start it only when needed.

Stop sshd:

```powershell
python windows\uabi_reverse_helper.py --stop
```

or:

```powershell
Stop-Service sshd
```
