# 장민종님께 드리는 설명서: UABI 환경에서 CST Studio Suite 사용 PoC

안녕하세요.  
UABI 환경에서 CST Studio Suite를 사용할 수 있는지에 대한 질문에 대해, 현재 가능한 기술적 해결 방향을 정리했습니다.

## 요약

UABI 계산노드에서 CST Studio Suite를 직접 설치하기 어렵고 GUI도 바로 열기 어렵지만, `enroot` 컨테이너를 사용하면 독립적인 Linux userspace를 구성할 수 있습니다.

제안하는 방식은 다음과 같습니다.

```text
UABI 계산노드
→ enroot 컨테이너 실행
→ Rocky Linux 9.4 환경 구성
→ xrdp server 실행
→ 컨테이너 내부 sshd 실행
→ 사용자 Windows PC로 SSH reverse tunnel 생성
→ Windows 기본 원격 데스크톱으로 접속
→ VSCode Remote-SSH로 컨테이너 쉘 접속
→ CST Studio Suite GUI 또는 solver 실행
```

## 왜 Rocky Linux 9.4인가요?

CST Studio Suite의 Linux 지원 환경은 RHEL 계열과 잘 맞습니다.  
UABI 호스트도 Rocky Linux 계열이므로, 컨테이너 내부를 `rockylinux:9.4`로 맞추면 설치 의존성과 실행 환경을 통제하기 쉽습니다.

즉, 사용자는 UABI 전체 시스템을 바꾸지 않고도 자기 작업용 CST 실행 환경을 컨테이너 안에 만들 수 있습니다.

## 왜 xrdp인가요?

처음 쓰는 연구원에게 RustDesk 같은 원격지원 도구는 설정이 복잡할 수 있습니다.  
반면 xrdp는 Windows 기본 원격 데스크톱 클라이언트로 접속할 수 있습니다.

Windows에서 실행:

```text
mstsc.exe
```

접속 주소:

```text
127.0.0.1:9999
```

이런 식으로 안내할 수 있어 사용자가 이해하기 쉽습니다.

## 왜 SSH reverse tunnel이 필요한가요?

UABI 계산노드는 보통 외부에서 직접 접속할 수 있는 TCP port를 열 수 없습니다.  
그래서 계산노드가 사용자 PC 쪽으로 먼저 SSH 연결을 열고, 그 안에 RDP 통신을 태웁니다.

구조는 다음과 같습니다.

```text
Windows PC 127.0.0.1:9999
← SSH reverse tunnel
← UABI 계산노드 컨테이너 127.0.0.1:3389
← xrdp desktop

Windows PC 127.0.0.1:9922
← SSH reverse tunnel
← UABI 계산노드 컨테이너 127.0.0.1:9922
← container sshd
```

사용자는 계산노드의 실제 IP나 방화벽을 몰라도 됩니다.

## 사용자가 해야 하는 것

### 1. Windows PC에서 helper 실행

```powershell
python windows\uabi_reverse_helper.py --port 10022 --local-rdp-port 9999
```

이 스크립트는 다음을 자동으로 처리합니다.

- OpenSSH Server 설치 여부 확인
- sshd 실행
- Windows 방화벽 rule 생성
- UABI 설정에 넣을 주소 후보 출력

단, Windows 관리자 권한이 필요합니다.

### 2. UABI에서 설정 파일 작성

```bash
cp config/example.env config/session.env
nano config/session.env
```

중요한 항목:

```bash
UABI_REVERSE_SSH_TARGET="Windows사용자명@Windows주소"
UABI_REVERSE_SSH_PORT="10022"
UABI_REVERSE_LOCAL_PORT_ON_WINDOWS="9999"
UABI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS="9922"

UABI_XRDP_PASSWORD="1q2w3e"
```

### 3. 이미지 빌드

```bash
./scripts/build_image.sh config/session.env
```

### 4. Slurm job 제출

```bash
./scripts/submit_xrdp_job.sh config/session.env
```

### 5. Windows에서 원격 데스크톱 접속

```text
mstsc.exe
→ 127.0.0.1:9999
```

로그인:

```text
username: root
password: 1q2w3e
```

### 6. VSCode로 컨테이너 SSH 접속

GUI를 통해 실행하면 Windows의 SSH 설정에 내부 전용 key가 자동 등록됩니다.
VSCode Remote-SSH에서는 다음 주소를 사용할 수 있습니다.

```text
ssh://root@uabi-container
```

포트 자체는 Windows 로컬 `127.0.0.1:9922`입니다. `ssh://root@localhost:9922`로도 같은 컨테이너 sshd에 연결됩니다.
보안을 위해 무인증 root SSH는 열지 않고, GUI가 자동 생성한 key를 컨테이너 root `authorized_keys`에 넣습니다. 사용자가 key 파일을 직접 관리할 필요는 없습니다.

## CST 설치에 대해

이 skeleton에는 CST Studio Suite 설치 파일이 포함되어 있지 않습니다.  
CST 설치 파일과 license server 정보는 학교 또는 연구실 라이선스 정책에 따라 별도로 지정해야 합니다.

설정 위치:

```text
config/session.env
image/install_cst_placeholder.sh
```

CST GUI 접속 환경이 먼저 안정적으로 작동하는지 확인한 뒤, CST 설치 자동화를 붙이는 순서가 좋습니다.

## 주의할 점

1. Windows PC가 UABI 계산노드에서 SSH 접속 가능한 위치에 있어야 합니다.
   - 학교 내부망
   - VPN
   - 포트포워딩
   - relay server 중 하나가 필요할 수 있습니다.

2. CST GUI는 OpenGL을 사용합니다.
   - GPU 가속이 없으면 software rendering으로 느릴 수 있습니다.
   - 그래도 설치 확인, 간단한 모델 확인은 가능할 수 있습니다.

3. CST Linux 버전은 Windows 버전과 CAD import 기능이 완전히 같지 않을 수 있습니다.
   - 복잡한 geometry 준비는 Windows에서 하고,
   - UABI에서는 solve 중심으로 쓰는 방식이 현실적입니다.

4. SSH key 사용을 권장합니다.
   - password login보다 안전하고 자동화가 쉽습니다.

## 현재 skeleton의 상태

이미 구현된 것:

- Rocky Linux 9.4 enroot 이미지 빌드
- desktop environment와 xrdp 설치
- 컨테이너 내부 sshd 9922 실행
- Slurm job에서 xrdp 컨테이너 실행
- Slurm job에서 RDP 9999와 SSH 9922 reverse tunnel 실행
- Windows helper로 sshd와 방화벽 준비
- CST 설치 hook 위치 제공

현장에서 추가 확인할 것:

- UABI 계산노드에서 `rockylinux:9.4` import 가능 여부
- xrdp 접속 안정성
- VSCode Remote-SSH 접속 안정성
- CST installer silent install 옵션
- license server 접속 가능 여부
- OpenGL renderer 상태
