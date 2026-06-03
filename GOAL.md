# GOAL

이 프로젝트의 목표는 서울시립대학교 UABI 같은 HPC 환경에서, 사용자가 root 권한 없이도 계산노드에서 CST Studio Suite Linux GUI와 solver를 실행할 수 있도록 하는 재현 가능한 skeleton을 제공하는 것이다.

핵심 아이디어는 다음과 같다.

1. 계산노드에서 `enroot`로 Rocky Linux 9.4 userspace를 실행한다.
2. Rocky Linux 9.4는 CST Studio Suite의 공식 Linux 지원군인 RHEL 9.x에 대응되는 RHEL-compatible 환경으로 사용한다.
3. 컨테이너 내부에 desktop environment, OpenGL/X11 runtime, xrdp server, CST 실행 의존성을 설치한다.
4. 계산노드 inbound TCP가 막힌 상황을 가정하고, 계산노드에서 사용자 Windows PC로 SSH reverse tunnel을 생성한다.
5. 사용자는 Windows 기본 Remote Desktop Client, 즉 `mstsc.exe`로 `127.0.0.1:<local-port>`에 접속한다.
6. CST 설치 파일과 license server 값은 기관별로 다르므로, skeleton에서는 hook과 설정 위치만 제공한다.

이 프로젝트는 RustDesk를 사용하지 않는다. RustDesk는 원격지원 도구로서는 편하지만, 보안 경고, direct access, relay, ID server 설정이 초심자에게 어렵다. 동료 연구실 배포 목적에서는 xrdp가 더 설명하기 쉽다.

## Non-goals

현재 skeleton은 다음을 직접 제공하지 않는다.

- CST Studio Suite 설치 파일
- CST license server 정보
- Dassault 공식 지원 보장
- 기관 보안정책 우회
- GPU 가속 OpenGL 보장
- sshfs 기반 외부 저장공간 마운트

sshfs는 의도적으로 제외했다. CST GUI 접속과 실행 가능성 PoC에서는 필수가 아니며, 용량 확장이 필요할 때 별도 layer로 추가한다.

## 최종 사용자 경험

### Windows PC

```powershell
python windows\uabi_reverse_helper.py --port 10022 --local-rdp-port 9999
```

### UABI login node

```bash
cp config/example.env config/session.env
nano config/session.env
./scripts/build_image.sh config/session.env
./scripts/submit_xrdp_job.sh config/session.env
```

### Windows PC

```text
mstsc.exe
Computer: 127.0.0.1:9999
Username: user
Password: 1q2w3e
```

## 성공 판정

1. Slurm job이 계산노드에서 살아 있다.
2. Windows PC에서 `netstat -ano | findstr 9999`로 reverse tunnel listen이 보인다.
3. Windows Remote Desktop에서 `127.0.0.1:9999` 접속이 된다.
4. XFCE desktop이 뜬다.
5. 컨테이너 터미널에서 다음이 된다.

```bash
cat /etc/rocky-release
echo $DISPLAY
glxinfo | grep -E "OpenGL vendor|OpenGL renderer|OpenGL version"
```

6. CST 설치 후 `cst_design_environment` 또는 기관 CST launcher가 실행된다.

## 장기 목표

다른 agent가 이어받을 때의 장기 목표는 다음이다.

1. CST 설치 파일의 silent install 자동화
2. license server variable 자동 주입
3. TurboVNC/VirtualGL backend 선택지 추가
4. sshfs workspace layer 선택 추가
5. Windows PC helper의 GUI화
6. Slurm array/persistent worker mode 추가
7. CST batch solve wrapper 추가
