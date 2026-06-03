# Troubleshooting

## The Slurm job starts but Windows cannot connect to 127.0.0.1:9999

Check on Windows:

```powershell
netstat -ano | findstr 9999
netstat -ano | findstr 9922
```

If nothing is listening, the SSH reverse tunnel did not establish.

On UABI, inspect Slurm logs and try:

```bash
ssh -vvv -p "$UABI_REVERSE_SSH_PORT" "$UABI_REVERSE_SSH_TARGET"
```

## SSH from UABI to Windows fails

Common causes:

- Windows PC is behind NAT.
- Windows firewall rule not created.
- Project-local Windows OpenSSH sshd is not running.
- Wrong Windows username.
- Password login disabled or blocked.
- Corporate/school security policy blocks inbound SSH.

Run on Windows:

```powershell
python windows\uabi_reverse_helper.py --status
Get-Process sshd
```

## VSCode cannot connect to root@localhost:9922

The container starts an internal `sshd` on `127.0.0.1:9922`. The Slurm job reverse-forwards that port to the gate, and the Windows GUI opens the local forward to `127.0.0.1:9922`.

Check Windows:

```powershell
Test-NetConnection 127.0.0.1 -Port 9922
ssh -vvv root@localhost -p 9922
```

The GUI writes a managed `Host uabi-container` block to `%USERPROFILE%\.ssh\config`. Prefer this VSCode Remote-SSH target:

```text
ssh://root@uabi-container
```

No unauthenticated root SSH is opened. The GUI creates an internal key, adds it to the container root `authorized_keys`, and configures the local SSH client to use it. If key auth fails, use the same root password as XRDP.

## xrdp login works but desktop is black

This usually means xrdp auth worked but session startup failed.

Check container logs:

```text
/work/logs/xrdp.stderr
/work/logs/xrdp-sesman.stderr
/var/log/xrdp.log
/var/log/xrdp-sesman.log
```

Try inside container:

```bash
which startxfce4
cat ~/.Xclients
```

xrdp is configured to use the Xvnc backend. If login succeeds but the desktop does not open, inspect the job-local xrdp and sesman logs first.

## CST GUI opens but 3D view is slow

Check OpenGL:

```bash
glxinfo | grep -E "OpenGL vendor|OpenGL renderer|OpenGL version"
```

If renderer contains `llvmpipe`, the GUI is using CPU software rendering. That may still be usable for setup but slow for heavy 3D interaction.

## CST cannot get license

Check license server reachability from compute node/container:

```bash
nc -vz LICENSE_HOST 27000
```

Exact port depends on the CST/Dassault license configuration.
