# msa-platform Architecture

## 개요

13개 마이크로서비스로 구성된 비즈니스 애플리케이션.

## 헥사고날 아키텍처

각 서비스는 다음 구조:

```
services/{service-name}/src/main/java/com/msaplatform/{name}/
├── {Name}ServiceApplication.java   Main class
│
├── domain/                          도메인 (순수)
│   ├── model/                       도메인 모델
│   ├── event/                       도메인 이벤트
│   ├── exception/                   도메인 예외
│   └── service/                     도메인 서비스 (인터페이스)
│
├── application/                     유스케이스
│   ├── port/
│   │   ├── in/                      인바운드 포트 (UseCase)
│   │   └── out/                     아웃바운드 포트 (Repository IF)
│   └── service/                     유스케이스 구현
│
├── adapter/                         어댑터
│   ├── in/
│   │   ├── web/                     REST 컨트롤러
│   │   └── kafka/                   Kafka 컨슈머
│   └── out/
│       ├── persistence/             JPA 어댑터
│       ├── kafka/                   Kafka 프로듀서
│       └── external/                외부 API
│
├── infrastructure/                  인프라 헬퍼
└── config/                          Spring 설정
```

## 서비스별 역할

### Edge & BFF (3개)

**edge-gateway** (8080)
- Spring Cloud Gateway
- 라우팅, JWT 검증 (common-auth-client)
- Rate Limiting (Redis)

**user-bff** (8081)
- 유저용 REST API
- 여러 서비스 조합

**admin-bff** (8082)
- 관리자용 GraphQL (`/graphql`, 로컬 `/graphiql`)
- 스키마: `src/main/resources/graphql/schema.graphqls`
- content-service 등 도메인 서비스 조합
- DataLoader로 N+1 방지

### Identity 관련 (1개)

**user-service** (8084)
- 프로필, 팔로우 관계
- AccountRegistered 이벤트 구독 → user_profile 자동 생성
- 인플루언서 등급 **표시 스냅샷** (계산은 recommendation-service)

### Core Domain (3개)

**commerce-service** (8085) ⭐
- 상품, 주문, 결제, 재고
- 위시리스트, 장바구니
- **재구매 패턴 분석** (마케팅 알고리즘 핵심)
- Saga Orchestrator ("포인트로 주문하기")

**fashion-service** (8087)
- OOTD, 브랜드, 상품 태깅
- OOTD 좋아요·댓글 (`ootd_like`, `ootd_comment`, BOUNDARY-02)

**social-service** (8088)
- 일반 피드 게시물(`post`)과 좋아요·댓글·공유
- 해시태그 (트렌딩, 연관 태그)
- OOTD 반응은 fashion-service 소유 (이중 구현 금지)

### Cross-Domain (3개)

**point-service** (8086) ⭐
- 마일리지 적립/사용
- Saga Participant

**recommendation-service** (8089) ⭐
- 사용자 행동 이벤트 수집
- 상품/OOTD 추천
- 인플루언서 스코어링
- A/B 테스트

**activity-feed-service** (8090) ⭐
- CQRS Read Model
- MongoDB에 통합 활동 저장
- 모든 도메인 이벤트 구독

### Supporting (3개)

**content-service** (8093)
- CMS: GNB(내비게이션 메뉴), 배너, 정적 페이지(소개/약관), 홈 섹션 구성
- admin-bff(GraphQL)로 관리, user-bff가 홈 화면 구성 시 조회

**notification-service** (8091) ⭐
- 알림 발송 (이메일, 웹훅)
- 마케팅 캠페인 자동화
- 재구매 알림, 가격 인하 알림, 이탈 복구

**media-service** (8092)
- S3 연동
- 이미지 메타데이터
- 썸네일 처리

## 이벤트 흐름

주요 이벤트:
- msa-auth → AccountRegistered → user-service, point-service, notification-service
- commerce → OrderPaid → point-service, notification-service, recommendation-service
- commerce → RepurchaseTimingPredicted → notification-service (재구매 알림)
- commerce → ProductViewed → recommendation-service (추천 데이터)
- 모든 도메인 → activity-feed-service (CQRS)

자세한 이벤트 카탈로그: `../msa-infra/docs/event-catalog.md`

## 공통 라이브러리

7개 공통 라이브러리 제공:

- **common-event**: DomainEvent 기반 클래스
- **common-outbox**: Outbox 패턴
- **common-kafka**: Kafka 표준 설정
- **common-saga**: Saga 추상화
- **common-tracing**: 분산 추적
- **common-web**: REST API 표준
- **common-auth-client**: msa-auth 토큰 검증 ⭐
