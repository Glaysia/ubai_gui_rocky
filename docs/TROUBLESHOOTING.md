# Troubleshooting

## The Slurm job starts but Windows cannot connect to 127.0.0.1:13389

Check on Windows:

```powershell
netstat -ano | findstr 13389
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
- Windows OpenSSH Server not running.
- Wrong Windows username.
- Password login disabled or blocked.
- Corporate/school security policy blocks inbound SSH.

Run on Windows:

```powershell
Get-Service sshd
Get-NetFirewallRule -Name UABI-OpenSSH-Server-In-TCP
```

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

Next agent should add forced Xvnc backend if Xorg backend is unstable.

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
