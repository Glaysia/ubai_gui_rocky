# GOAL

이 프로젝트의 목표는 UBAI 같은 HPC 환경에서 사용자가 root 권한 없이 계산노드 컨테이너 안에 CST Studio Suite Linux GUI 실행 환경을 만들고, Windows PC에서 RDP와 VSCode SSH로 접속할 수 있게 하는 것이다.

## 핵심 구조

1. 계산노드에서 `enroot`로 Rocky Linux 9.4 userspace를 실행한다.
2. 컨테이너 안에 XFCE, OpenGL/X11 runtime, xrdp, container sshd, CST 실행 보조 도구를 준비한다.
3. 계산노드는 inbound TCP가 막혀 있으므로 계산노드에서 게이트 노드로 SSH reverse tunnel을 연다.
4. Windows PC는 게이트 노드로 SSH local forward만 연다.
5. Windows PC에는 SSH server를 열지 않는다. PC는 게이트 노드로 나가는 SSH client 연결만 사용한다.
6. 사용자는 `mstsc.exe`로 `127.0.0.1:9999`에 접속한다.
7. 사용자는 VSCode Remote-SSH로 `root@localhost:9922` 또는 `root@ubai-container`에 접속할 수 있다.
8. CST installer와 license server 값은 기관별로 다르므로 skeleton에서는 hook과 설정 위치만 제공한다.

## Non-Goals

현재 skeleton은 다음을 직접 제공하지 않는다.

- CST Studio Suite installer 파일
- CST license server 정보
- 기관 보안정책 우회
- GPU 가속 OpenGL 보장
- 여러 계산노드를 자동으로 할당해 대량 데이터셋을 생성하는 runner
- sshfs 기반 영구 workspace layer

## 최종 사용자 경험

Windows PC:

```powershell
python windows\ubai_manager_gui.py
```

GUI에서 UBAI 사용자명, UBAI SSH key, root 비밀번호, 할당 자원을 넣고 `컨테이너 켜기`를 누른다.

접속:

```text
RDP:    mstsc.exe -> 127.0.0.1:9999
User:   root
Pass:   GUI에서 지정한 root 비밀번호

VSCode: ssh://root@ubai-container
또는:   ssh://root@localhost:9922
```

## 성공 판정

1. Slurm job이 계산노드에서 살아 있다.
2. 게이트 노드 loopback에 RDP/SSH reverse relay port가 열린다.
3. Windows PC loopback에 RDP/SSH local forward port가 열린다.
4. Windows Remote Desktop에서 `127.0.0.1:9999` 접속이 된다.
5. VSCode Remote-SSH에서 `root@ubai-container` 또는 `root@localhost:9922` 접속이 된다.
6. XFCE desktop이 열린다.
7. 컨테이너 터미널에서 다음이 동작한다.

```bash
cat /etc/rocky-release
echo "$DISPLAY"
glxinfo | grep -E "OpenGL vendor|OpenGL renderer|OpenGL version"
firefox --version
```

## 장기 목표

이 아래는 지금 당장 구현할 필요가 없다.

1. CST silent install 자동화
2. license server variable 자동 주입
3. TurboVNC/VirtualGL backend 선택지 추가
4. Slurm array/persistent worker mode 추가
5. CST batch solve wrapper 추가
