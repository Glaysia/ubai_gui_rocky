# ubai-cst-xrdp-runner

UBAI/HPC 계산노드에서 `enroot + Rocky Linux 9.4 + xrdp`로 CST Studio Suite GUI 실행 환경을 띄우는 skeleton project이다.

## Architecture

```text
Windows PC
  ├─ ssh.exe -L 127.0.0.1:9999:127.0.0.1:9999 gate
  ├─ ssh.exe -L 127.0.0.1:9922:127.0.0.1:9922 gate
  ├─ mstsc.exe -> 127.0.0.1:9999
  └─ VSCode Remote-SSH -> root@localhost:9922 or root@ubai-container

UBAI gate node
  ├─ normal SSH on 172.16.10.36:22
  └─ loopback relay ports 127.0.0.1:9999 and 127.0.0.1:9922

UBAI compute node
  └─ Slurm job
      └─ enroot container, Rocky Linux 9.4
          ├─ XFCE desktop
          ├─ xrdp/xrdp-sesman on 127.0.0.1:3389
          ├─ container sshd on 127.0.0.1:9922
          ├─ Firefox
          └─ ssh -p 22 -R gate:9999:container:3389 gate
             ssh -p 22 -R gate:9922:container:9922 gate
```

이 PC에는 SSH 서버를 열지 않는다. PC는 게이트 노드로 나가는 SSH client 연결만 사용한다.

## Windows GUI

```powershell
python windows\ubai_manager_gui.py
```

GUI에서 사용자가 직접 넣는 값은 UBAI 사용자명과 UBAI 로그인 SSH key, root 비밀번호, 할당 자원 정도이다. 게이트 주소는 `172.16.10.36:22`로 고정되어 있고, 게이트 릴레이 key와 컨테이너 SSH key는 내부에서 자동 관리된다.

처음 실행하거나 다른 PC에서 테스트할 때는 다음 두 파일을 준비하면 된다.

```text
secrets\original_key\key.pem
secrets\original_key\username
```

`key.pem`에는 UBAI 게이트 노드 로그인용 개인 SSH key를 넣고, `username`에는 UBAI 사용자명을 한 줄로 적는다. GUI는 이 두 파일을 기본 접속 정보로 사용한다. Windows OpenSSH가 private key 권한을 문제 삼는 경우가 많으므로, GUI는 접속 직전에 `key.pem` 권한을 자동으로 좁혀 `UNPROTECTED PRIVATE KEY FILE` 오류를 방지한다.

실제 key와 username 파일은 git에 커밋하지 않는다. 폴더 위치를 헷갈리지 않도록 `secrets\original_key\README.md`만 repository에 남긴다.

주요 버튼:

- `컨테이너 켜기`: PC -> 게이트 local forward를 열고, Slurm XRDP job을 제출한다.
- `컨테이너 끄기`: UBAI XRDP/build job을 `scancel`하고 local forward를 정리한다.
- `접속하기`: `mstsc.exe`를 `127.0.0.1:<local-rdp-port>`로 실행한다.
- `상태 새로고침`: Slurm 상태, job log, 게이트 릴레이 포트, 로컬 포트 상태를 확인한다.

상태 줄은 `켜는 중(접속 불가능)`처럼 현재 접속 가능 여부를 명시하고, 접속 전에는 `\ | / -` spinner를 표시한다.

## VSCode SSH

컨테이너 안에는 자동으로 SSH server가 `127.0.0.1:9922`로 열린다. GUI는 `%USERPROFILE%\.ssh\config`에 다음 alias를 자동 등록한다.

```text
ssh://root@ubai-container
```

다음 주소도 같은 컨테이너로 연결된다.

```text
ssh://root@localhost:9922
```

무인증 root SSH는 열지 않는다. GUI가 내부 전용 key를 생성하고 root `authorized_keys`에 주입하므로 사용자가 reverse key나 container key를 직접 관리할 필요가 없다. key 인증이 실패하면 XRDP root 비밀번호를 fallback으로 사용할 수 있다.

## Container Home

컨테이너 안의 `/root`는 UBAI 홈 디렉토리 아래의 다음 경로에 마운트된다.

```text
~/runtime/container-root-home
```

Slurm job은 실행 시 이 디렉토리를 만들고, 편하게 접근할 수 있도록 다음 심볼릭 링크도 만든다.

```text
~/container-home -> ~/runtime/container-root-home
```

따라서 XRDP나 VSCode에서 `/root`에 저장한 파일은 job을 껐다 켜도 `~/container-home`에서 다시 확인할 수 있다.

## Manual Flow

GUI 없이 직접 실행할 때:

```bash
cp config/example.env config/session.env
nano config/session.env
./scripts/build_image.sh config/session.env
./scripts/submit_xrdp_job.sh config/session.env
```

중요 기본값:

```bash
export UBAI_REVERSE_SSH_TARGET="UBAI_USER@172.16.10.36"
export UBAI_REVERSE_SSH_PORT="22"
export UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS="9999"
export UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS="9922"
export UBAI_XRDP_PASSWORD="1q2w3e"
```

## Project Layout

```text
windows/ubai_manager_gui.py
  Windows GUI. PC SSH server 없이 게이트 local forward와 Slurm job을 관리한다.

config/example.env
  기본 세션 설정 예시.

scripts/build_image.sh
  enroot 또는 podman image build wrapper.

scripts/submit_xrdp_job.sh
  Slurm job 제출 wrapper. 기본 backend는 enroot이다.

slurm/ubai_cst_xrdp.sbatch
  계산노드 enroot XRDP job template.

container/start_xrdp_container.sh
  컨테이너 내부 root 비밀번호 설정, xrdp 실행, 9922 sshd 실행, readiness 확인.

image/build_rocky94_xrdp_image.sh
  Rocky Linux 9.4 enroot image 생성. Firefox 포함.
```

## Notes

- 게이트 노드에는 podman이 있고 enroot가 없을 수 있다.
- 계산노드에는 enroot가 있고 podman이 없을 수 있다.
- 그래서 XRDP job은 기본적으로 enroot를 사용하며, podman fallback 경고를 띄우지 않는다.
- CST installer와 license server 정보는 repo에 포함하지 않는다.
