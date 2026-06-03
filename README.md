# uabi-cst-xrdp-runner

UABI/HPC 계산노드에서 `enroot + Rocky Linux 9.4 + xrdp`로 CST Studio Suite GUI 실행 환경을 만드는 skeleton project이다.

이 프로젝트는 다음 문제를 해결하려고 한다.

- UABI/Rocky Linux 환경에서 사용자가 직접 패키지를 설치하기 어려움
- 계산노드에서 GUI 사용이 어려움
- 계산노드 inbound TCP가 막혀 있음
- 동료 연구실 구성원이 RustDesk 같은 원격지원 도구를 어려워함
- CST Studio Suite는 RHEL 9.x 계열 Linux가 더 적합함

## Architecture

```text
Windows PC
  ├─ project-local OpenSSH sshd.exe, not Windows sshd service
  └─ mstsc.exe → 127.0.0.1:9999
  └─ VSCode Remote-SSH → root@localhost:9922

UABI compute node
  └─ Slurm job
      └─ enroot container, Rocky Linux 9.4
          ├─ XFCE desktop
          ├─ xrdp/xrdp-sesman
          ├─ sshd on 127.0.0.1:9922
          ├─ OpenGL/X11 runtime
          ├─ CST Studio Suite, user-provided
          └─ ssh -p 10022 -R 127.0.0.1:9999:127.0.0.1:3389 WindowsPC
          └─ ssh -p 10022 -R 127.0.0.1:9922:127.0.0.1:9922 WindowsPC
```

## Quick start

### 1. Windows PC 준비

일반 PowerShell에서 실행한다. Windows 시스템 `sshd` 서비스는 사용하지 않는다.

```powershell
python windows\uabi_reverse_helper.py --port 10022 --local-rdp-port 9999
```

프로젝트 로컬 OpenSSH가 없으면 GitHub의 PowerShell/Win32-OpenSSH 릴리스에서 내려받는다.
다시 내려받아 덮어쓰려면 `--force-install`을 붙인다. 출력되는 Windows username,
hostname, IP, UABI-side private key 경로를 기록한다.

GUI로 실행하려면 다음을 사용한다.

```powershell
python windows\uabi_manager_gui.py
```

GUI에서는 다음을 할 수 있다.

- `컨테이너 켜기`: 로컬 RDP 포워드를 열고 UABI Slurm XRDP job을 제출한다.
- `컨테이너 끄기`: 현재 UABI XRDP job을 `scancel`하고 로컬 포워드를 정리한다.
- `접속하기`: `mstsc.exe`를 `127.0.0.1:<local-rdp-port>`로 실행한다.
- `상태 새로고침`: `squeue`, `scontrol`, `sstat`, job log, 게이트 릴레이 포트 상태를 보여준다.

GUI에서 사용자가 직접 넣는 접속 정보는 UABI 사용자명과 UABI 로그인 SSH key뿐이다.
게이트 주소 `172.16.10.36:22`, reverse tunnel key, 컨테이너 root SSH key는 GUI가 내부에서 자동 관리한다.
할당 자원은 partition, time, CPU, memory, GPU 개수를 입력한다.
하단 상태줄은 `켜는 중(접속 불가능)`처럼 현재 RDP 접속 가능 여부를 명시한다.

### 2. UABI에서 설정 파일 작성

```bash
cp config/example.env config/session.env
nano config/session.env
```

최소 수정 항목:

```bash
UABI_IMAGE="$HOME/runtime/enroot/uabi-cst-rocky94-xrdp.sqsh"

UABI_REVERSE_SSH_TARGET="WINDOWS_USER@WINDOWS_HOST_OR_IP"
UABI_REVERSE_SSH_PORT="10022"
UABI_REVERSE_LOCAL_PORT_ON_WINDOWS="9999"
UABI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS="9922"
UABI_XRDP_PORT_IN_CONTAINER="3389"
UABI_CONTAINER_SSH_PORT="9922"
UABI_SSH_IDENTITY_FILE=""

UABI_XRDP_PASSWORD="1q2w3e"

UABI_CST_INSTALLER_PATH=""
UABI_CST_LICENSE_SERVER=""
```

### 3. enroot image build

```bash
./scripts/build_image.sh config/session.env
```

### 4. Slurm job 제출

```bash
./scripts/submit_xrdp_job.sh config/session.env
```

### 5. Windows에서 접속

```text
mstsc.exe
Computer: 127.0.0.1:9999
Username: root
Password: 1q2w3e
```

VSCode Remote-SSH도 동시에 열린다. GUI로 컨테이너를 켜면 `%USERPROFILE%\.ssh\config`에 `uabi-container` alias와 내부 전용 key가 자동 등록된다.

```text
ssh://root@uabi-container
```

로 접속하는 것을 권장한다. `ssh://root@localhost:9922`도 같은 포트로 연결된다. 인증은 암호화된 터널 위에서 다시 OpenSSH가 처리하며, 무인증 root SSH는 열지 않는다. 대신 GUI가 생성한 내부 key를 root `authorized_keys`에 자동 주입하므로 사용자가 key 파일을 직접 관리할 필요가 없다. key 인증이 실패하면 root 비밀번호 `UABI_XRDP_PASSWORD`를 fallback으로 사용할 수 있다.

## CST 설치

CST 설치 파일은 라이선스 문제로 repo에 포함하지 않는다. 설치 자동화 hook은 다음 파일에 있다.

```text
image/install_cst_placeholder.sh
```

먼저 xrdp desktop이 정상 접속되는지 확인한 뒤 CST 설치를 붙인다.

## Project layout

```text
config/example.env
  사용자 설정 예시

image/build_rocky94_xrdp_image.sh
  Rocky Linux 9.4 enroot image 생성

image/install_cst_placeholder.sh
  CST 설치 hook. 실제 기관 설치 파일에 맞춰 수정

container/start_xrdp_container.sh
  컨테이너 내부 root 비밀번호 설정, Xvnc 기반 xrdp 실행, 9922 sshd 실행, readiness file 생성

slurm/uabi_cst_xrdp.sbatch
  Slurm job template

scripts/build_image.sh
  env file을 읽어 image build 실행

scripts/submit_xrdp_job.sh
  env file을 Slurm job에 넘겨 제출

windows/uabi_reverse_helper.py
  프로젝트 전용 portable OpenSSH sshd 준비 helper

windows/uabi_manager_gui.py
  Windows에서 UABI XRDP Slurm job을 켜고 끄고 접속하는 GUI

docs/for_jang_minjong.md
  장민종님에게 전달할 친절 설명서

docs/HANDOFF_FOR_NEXT_AGENT.md
  다른 agent가 이어받기 위한 구현 메모
```

## 현재 구현된 것

- Rocky Linux 9.4 기반 enroot image build script
- EPEL 활성화
- XFCE/xrdp/tigervnc/OpenGL/X11 주요 dependency 설치
- CST dependency 후보 패키지 설치
- xrdp manual foreground startup
- Slurm job에서 enroot container 실행
- Slurm job에서 RDP 9999와 container SSH 9922 reverse tunnel 실행
- Windows helper로 프로젝트 전용 OpenSSH 다운로드/설정/시작
- Windows GUI로 Slurm job 제출/취소, RDP 접속, 상태/자원 사용량 확인
- Windows GUI로 reverse tunnel key와 VSCode용 container SSH key 자동 관리
- CST 설치 hook placeholder
- 동료 연구실 전달 문서

## 아직 현장 검증이 필요한 것

- UABI 계산노드의 enroot version별 mount option 호환성
- Rocky 9.4 image import 가능 여부
- xrdp는 rootless 컨테이너 호환성을 위해 Xvnc backend로 강제한다.
- Slurm job submit은 기본적으로 enroot backend를 사용한다. 게이트 노드에 enroot가 없어도 계산노드에는 enroot가 있으므로 submit host에서 podman fallback을 자동 선택하지 않는다.
- CST installer silent mode argument
- CST license server port 접근성
- OpenGL renderer가 software rendering인지 GPU rendering인지
- 기관 보안정책상 Windows PC sshd 허용 여부
