# REQUIREMENTS

## UABI/HPC 측 요구사항

필수:

- 계산노드에서 `enroot` 사용 가능
- 계산노드에서 outbound SSH 가능
- Docker/OCI image import 가능, 또는 login node에서 사전 import 가능
- Slurm 사용 가능
- 사용자 home 또는 scratch에 enroot image 저장 공간 확보
- CST Studio Suite Linux 설치 파일 접근 가능
- CST license server에 계산노드에서 접속 가능

권장:

- Rocky Linux host 또는 RHEL-compatible host
- 충분한 local scratch
- 최소 4 CPU cores
- 최소 16 GB RAM
- GUI 테스트는 2시간 이상 walltime 권장
- CST solver는 모델 크기에 맞춰 별도 walltime, memory 요청

## Windows PC 측 요구사항

필수:

- Windows 10 1809 이상 또는 Windows 11
- Python 3.10 이상 권장
- 관리자 권한으로 helper 실행 가능
- GitHub PowerShell/Win32-OpenSSH 릴리스 다운로드 가능, 또는 프로젝트 로컬 OpenSSH 준비 가능
- UABI 계산노드에서 Windows PC의 SSH 포트로 접속 가능해야 함
  - 같은 학교망
  - VPN
  - 포트포워딩
  - 또는 별도 relay server

권장:

- Windows Defender Firewall rule을 자동 생성할 수 있는 권한
- Remote Desktop Client, `mstsc.exe`
- 고정 IP 또는 접속 가능한 hostname

## CST 관련 요구사항

이 skeleton은 CST 설치 파일과 license를 포함하지 않는다.

사용자가 채워야 할 값:

- `UABI_CST_INSTALLER_PATH`
- `UABI_CST_INSTALL_DIR`
- `UABI_CST_LICENSE_SERVER`
- 필요 시 `LM_LICENSE_FILE`, `CST_LICENSE_FILE`, vendor-specific 환경변수

CST Linux의 CAD import 기능은 Windows와 완전히 같지 않을 수 있다. 복잡한 CAD import와 geometry preparation은 Windows CST에서 수행하고, UABI에서는 solve 또는 간단한 GUI 확인 위주로 쓰는 workflow를 권장한다.

## 보안 요구사항

동료 연구실 배포 시 권장 사항:

- SSH password login보다 key login 권장
- Windows helper가 만든 firewall rule은 필요할 때만 enable
- `RemoteAddress` 제한 가능하면 반드시 제한
- xrdp password는 세션마다 바꾸기
- Slurm 로그에 민감한 password가 남지 않게 주의
- CST license 관련 정보는 repo에 commit하지 않기
