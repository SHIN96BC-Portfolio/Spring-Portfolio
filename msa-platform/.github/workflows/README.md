# CI/CD Workflows

## 파일 구성

- `build.yml` - 전체 빌드 & 테스트 (매 push, PR)
- `deploy-{service}.yml` - 각 서비스별 배포 (해당 폴더 변경 시만)

## 서비스별 배포 파일

각 서비스마다 `deploy-{service}.yml` 파일이 있어야 합니다.
`paths:` 필터로 해당 서비스 변경 시에만 배포되도록 설정.

예시:
```yaml
paths:
  - 'services/user-service/**'
  - 'libs/**'    # 공통 라이브러리 변경 시도 재배포
```

## TODO

- [ ] 나머지 11개 서비스 deploy-*.yml 파일 추가
- [ ] Docker build + push to GHCR
- [ ] k3s 배포 스크립트
