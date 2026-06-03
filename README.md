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

UABI compute node
  └─ Slurm job
      └─ enroot container, Rocky Linux 9.4
          ├─ XFCE desktop
          ├─ xrdp/xrdp-sesman
          ├─ OpenGL/X11 runtime
          ├─ CST Studio Suite, user-provided
          └─ ssh -p 10022 -R 127.0.0.1:9999:127.0.0.1:3389 WindowsPC
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

- `가상 컴퓨터 켜기`: 로컬 RDP 포워드를 열고 UABI Slurm XRDP job을 제출한다.
- `끄기`: 현재 UABI XRDP job을 `scancel`하고 로컬 포워드를 정리한다.
- `접속하기`: `mstsc.exe`를 `127.0.0.1:<local-rdp-port>`로 실행한다.
- `상태 새로고침`: `squeue`, `scontrol`, `sstat`, job log, 게이트 릴레이 포트 상태를 보여준다.

할당 자원은 GUI에서 partition, time, CPU, memory, GPU 개수를 입력한다.
설정은 `secrets/uabi-ui/config.json`에 저장된다.

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
UABI_XRDP_PORT_IN_CONTAINER="3389"
UABI_SSH_IDENTITY_FILE="/path/on/uabi/uabi_reverse_ed25519"

UABI_XRDP_USER="user"
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
Username: user
Password: 1q2w3e
```

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
  컨테이너 내부에서 user 생성, xrdp 실행, readiness file 생성

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
- Slurm job에서 SSH reverse tunnel 실행
- Windows helper로 프로젝트 전용 OpenSSH 다운로드/설정/시작
- Windows GUI로 Slurm job 제출/취소, RDP 접속, 상태/자원 사용량 확인
- CST 설치 hook placeholder
- 동료 연구실 전달 문서

## 아직 현장 검증이 필요한 것

- UABI 계산노드의 enroot version별 mount option 호환성
- Rocky 9.4 image import 가능 여부
- xrdp backend가 Xorg backend로 안정 동작하는지
- 필요 시 Xvnc backend로 강제해야 하는지
- CST installer silent mode argument
- CST license server port 접근성
- OpenGL renderer가 software rendering인지 GPU rendering인지
- 기관 보안정책상 Windows PC sshd 허용 여부
