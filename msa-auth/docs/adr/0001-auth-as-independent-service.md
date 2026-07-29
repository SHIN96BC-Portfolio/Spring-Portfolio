# ADR-0001: auth를 독립 서비스로 분리

## Status
Accepted

## Context

auth-service를 msa-platform 안에 둘 것인가, 별도 레포로 분리할 것인가?

## Decision

**별도 레포 msa-auth로 분리.**

## Rationale

1. **OAuth Provider 컨셉**: auth는 여러 서비스가 공유하는 Identity Provider
2. **재사용성**: 다른 프로젝트에서도 활용 가능
3. **배포 독립성**: 인증 서비스는 안정성 중요, 별도 주기
4. **개념적 명확성**: auth는 msa-platform 소유가 아닌 독립 시스템

## Trade-offs

- 레포 관리 부담 증가
- 초기 셋업 시간 증가
- msa-platform과 이벤트 스키마 동기화 필요

## Consequences

### 좋은 점
- Auth0/Keycloak 같은 포지셔닝 가능
- 다른 프로젝트에서 재사용
- msa-platform의 auth 종속 제거

### 부담
- 로컬 개발 시 여러 레포 동시 실행
- 이벤트 스키마 문서로 동기화
