# UBAI 로그인 키 위치

다른 PC나 새 checkout에서 테스트할 때는 이 폴더에 아래 두 파일만 직접 넣으면 됩니다.

```text
secrets/original_key/key.pem
secrets/original_key/username
```

- `key.pem`: UBAI 게이트 노드(`172.16.10.36:22`)에 로그인할 때 사용하는 개인 SSH key입니다.
- `username`: UBAI 사용자명을 한 줄로 적는 파일입니다. 예: `harry261`

Windows GUI는 시작할 때 이 두 파일을 기본 접속 정보로 읽습니다. SSH 실행 직전에는 `key.pem` 권한을 자동으로 좁혀 Windows OpenSSH의 `UNPROTECTED PRIVATE KEY FILE` 오류가 나지 않도록 보정합니다.

주의:

- `key.pem`과 `username`은 git에 커밋하지 마세요.
- 이 repository는 이 폴더의 `README.md`만 추적하도록 설정되어 있습니다.
- 키 파일 이름은 반드시 `key.pem`으로 두는 것을 권장합니다.
