# Requirements

## UBAI/HPC

Required:

- Slurm
- outbound SSH from compute node to gate node
- enroot on compute nodes
- enough home or scratch storage for the enroot image
- access to the CST Studio Suite Linux installer
- access from compute node/container to the CST license server

Recommended:

- Rocky Linux or RHEL-compatible host environment
- local scratch space
- at least 4 CPU cores
- at least 16 GB RAM
- at least 2 hours walltime for GUI setup tests

## Windows PC

Required:

- Windows 10 1809 or later, or Windows 11
- Python 3.10 or later
- Windows OpenSSH client: `ssh.exe`, `scp.exe`, `ssh-keygen.exe`
- Remote Desktop Client: `mstsc.exe`
- outbound SSH access to `172.16.10.36:22`

Not required:

- inbound firewall rule
- port forwarding to this PC

## CST

This skeleton does not include CST installer or license information. The user must provide:

- `UBAI_CST_INSTALLER_PATH`
- `UBAI_CST_INSTALL_DIR`
- `UBAI_CST_LICENSE_SERVER`
- any required `LM_LICENSE_FILE`, `CST_LICENSE_FILE`, or vendor-specific environment variables

CST Linux CAD import may not behave exactly like Windows CST. A practical workflow is to prepare complex geometry on Windows CST and use UBAI for GUI verification, solve runs, or automation after the environment is stable.

## Security

- Prefer SSH key login over password login.
- Keep relay ports bound to loopback.
- Do not expose xrdp or container sshd directly.
- Change the XRDP root password per session when sharing the tool.
- Do not commit secrets, private keys, CST license data, or `config/session.env`.
