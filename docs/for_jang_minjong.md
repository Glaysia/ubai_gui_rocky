# 장민종님께 드리는 설명서: UBAI CST GUI PoC

안녕하세요.

이 프로젝트는 UBAI 환경에서 CST Studio Suite를 GUI로 실행하고, 이후 연구 자동화 환경으로 확장할 수 있는지 확인하기 위해 만든 예시 프로젝트입니다. 핵심 목적은 UBAI 계산노드 위에 독립적인 Linux 컨테이너 환경을 만들고, Windows PC에서 원격 데스크톱과 VSCode SSH로 접속할 수 있게 하는 것입니다.

완성된 연구 자동화 플랫폼이라기보다는, UBAI에서 실제로 동작하는 기본 도구들을 묶어 둔 출발점에 가깝습니다. 앞으로 연구 목적에 맞게 커스터마이징하면 환경 구축, 시뮬레이션 실행, 자동화 워크플로 구성에 활용하실 수 있습니다.

## 현재 프로젝트로 할 수 있는 것

- UBAI에서 고성능 계산노드 1대를 Slurm job으로 할당받습니다.
- 할당받은 계산노드 안에서 Rocky Linux 9.4 기반 `enroot` 컨테이너를 실행합니다.
- 컨테이너 안에 XFCE desktop, xrdp, SSH server, OpenGL/X11 실행 환경을 구성합니다.
- Windows 원격 데스크톱으로 `127.0.0.1:9999`에 접속해 GUI 환경을 사용할 수 있습니다.
- VSCode Remote-SSH로 `ssh://root@ubai-container` 또는 `root@localhost:9922`에 접속할 수 있습니다.
- GUI 접속 후 CST 설치, 환경 세팅, 직접 시뮬레이션 실행 같은 작업을 할 수 있습니다.

즉, 고성능 PC 한 대를 빌려 GUI로 접속하고, 그 안에서 연구용 프로그램을 세팅해 직접 실행하는 환경을 목표로 합니다.

## 현재 프로젝트가 자동으로 해주지는 않는 것

다음 범위는 사용 목적에 맞게 직접 확장해야 합니다. 다만 필요한 기반 도구와 작동이 검증된 구성 요소를 이 프로젝트에 넣어 두었기 때문에, 구축 과정에 참고가 될 수 있습니다.

- 여러 계산노드를 동시에 자동 할당받아 여러 컨테이너를 병렬로 띄우는 작업
- GUI 접속 없이 대량 시뮬레이션 데이터셋을 자동 생성하는 runner
- CST 모델 형상 생성, parameter sweep, solver 실행, 결과 추출까지 포함한 완전 자동화 pipeline
- 연구실 license 정책에 맞춘 CST installer와 license server 설정

여러 노드를 사용해 대량 데이터셋을 생성하는 자동화 구조는 별도의 runner로 설계하는 것이 적합합니다. 예시로는 [Glaysia/peetsfea-runner](https://github.com/Glaysia/peetsfea-runner) 같은 구조를 참고할 수 있습니다.

## 자동화 확장 방향

CST Studio Suite는 스크립트 자동화 기능이 잘 갖춰져 있는 편이므로, 환경이 안정화되면 다음과 같은 방향으로 확장할 수 있습니다.

- 수만 개의 형상을 스크립트로 자동 생성
- parameter sweep 수행
- solver 실행 자동화
- 결과 파일 수집 및 전처리
- 학습 또는 분석용 시뮬레이션 데이터셋 생성

현재 프로젝트는 이 자동화 전체를 구현하지는 않습니다. 대신 UBAI에서 컨테이너 기반 실행 환경, GUI 접속, SSH 접속, reverse tunnel, Slurm job 실행이 실제로 맞물리도록 구성해 둔 예시입니다. 이 기반 위에 CST 스크립트 자동화를 붙이면 연구 목적에 맞는 도구로 발전시킬 수 있습니다.

## 접속 방식

Windows GUI를 사용하면 사용자가 직접 관리해야 하는 값은 UBAI 사용자명과 UBAI SSH key 정도로 줄어듭니다. 게이트 노드 주소, relay key, 컨테이너 SSH key는 내부에서 자동 관리합니다.

원격 데스크톱:

```text
mstsc.exe
Computer: 127.0.0.1:9999
Username: root
Password: 설정한 root 비밀번호
```

VSCode Remote-SSH:

```text
ssh://root@ubai-container
```

또는:

```text
ssh://root@localhost:9922
```

## 작업 기록 파일

`docs/ubai_gui.toml`은 이 프로젝트를 만드는 동안 어떤 요청이 있었는지 시간순으로 정리해 둔 기록 파일입니다. 각 항목에는 한국 시간 기준의 요청 시각과 요청 내용이 들어 있습니다.

이 파일은 프로그램 실행에 필요한 설정 파일은 아닙니다. 나중에 프로젝트가 어떤 요구사항을 바탕으로 만들어졌는지 확인하거나, 기능 변경의 배경을 추적할 때 참고하기 위한 문서입니다.

## 참고 사항

- CST 설치 파일은 license 문제로 프로젝트에 포함하지 않습니다.
- CST license server 정보는 연구실 또는 학교 정책에 맞게 별도로 입력해야 합니다.
- GPU 가속 OpenGL 여부는 UBAI 계산노드 환경에 따라 달라질 수 있습니다.
- 이 프로젝트는 여러 job을 극한으로 활용하는 자동화 runner가 아니라, 단일 노드 GUI/SSH 접속 기반의 연구 환경 PoC입니다.

정리하면, 이 프로젝트는 UBAI에서 CST GUI 환경을 현실적으로 띄우고 접속하는 데 필요한 기본 골격입니다. 이후 연구 목적에 맞춰 CST 스크립트 자동화, 대량 데이터 생성, 병렬 job 관리 등을 직접 추가해 나가시면 됩니다.

덧붙여, 이 프로젝트의 코드는 전부 LLM을 이용해 작성했습니다.
