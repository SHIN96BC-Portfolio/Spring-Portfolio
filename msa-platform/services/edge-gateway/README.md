# edge-gateway
외부 요청의 단일 진입점에서 인증과 서비스 라우팅을 담당하는 게이트웨이입니다.

## 책임
- Spring Cloud Gateway 기반 요청 라우팅
- JWT 검증과 요청 접근 제어
- Redis 기반 Rate Limiting

## 담당하지 않는 것 / 서비스 경계
- 사용자 화면용 응답 조합은 `user-bff`가 담당합니다.
- 관리자 GraphQL 조합은 `admin-bff`가 담당합니다.
- 비즈니스 규칙과 데이터 저장은 각 도메인 서비스가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8080` |
| DB | 없음 |
| Gradle 모듈 경로 | `:services:edge-gateway` |

## 주요 연동 및 이벤트
- `msa-auth` 토큰 검증 URL 설정이 있습니다(기본값 `http://localhost:8083/internal/verify-token`).
- Kafka 연결 설정은 있으나 구체적인 발행·구독 이벤트는 현재 코드와 문서에서 확인되지 않아 미정입니다.
- 실제 라우트와 Redis Rate Limiting 설정은 아직 없습니다.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:edge-gateway:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, Actuator, Gateway·인증 클라이언트 의존성과 기본 설정
- 미구현: 실제 서비스 라우트, JWT 필터 적용, Redis Rate Limiting, 운영용 API 정책
