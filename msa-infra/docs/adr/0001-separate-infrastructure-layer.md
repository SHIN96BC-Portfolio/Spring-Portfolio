# ADR-0001: Infrastructure Layer 분리

## Status
Accepted

## Context

Kafka, Redis 같은 공유 인프라를 어느 레포에 둘 것인가?

옵션:
- msa-auth에 포함
- msa-platform에 포함  
- 별도 msa-infra 레포

## Decision

**별도 msa-infra 레포로 분리.**

## Rationale

1. **개념적 명확성**: Kafka는 특정 애플리케이션의 소유가 아니라 여러 시스템의 공유 자원
2. **실무 표준**: 대부분의 조직에서 인프라팀이 별도 관리
3. **일관성**: auth를 OAuth Provider로 분리한 논리와 동일
4. **재사용성**: 다른 프로젝트에서도 동일 인프라 활용 가능

## Trade-offs

- 레포 관리 부담 증가 (3개)
- 초기 셋업 시간 증가
- 로컬 개발 시 여러 프로젝트 동시 실행 필요

## Consequences

### 좋은 점
- 각 애플리케이션의 인프라 종속성 없음
- Kafka 클러스터 업그레이드/관리 독립
- 실무 아키텍처 반영

### 부담
- Docker 네트워크 공유 관리
- 이벤트 스키마 카탈로그 별도 관리

## Alternatives Considered

### 대안 1: msa-auth에 Kafka 포함
- 단점: auth가 인프라 소유 = 개념 어색
- 채택 안 함

### 대안 2: msa-platform에 Kafka 포함
- 단점: OAuth Provider 컨셉 무너짐 (auth가 platform에 종속)
- 채택 안 함
