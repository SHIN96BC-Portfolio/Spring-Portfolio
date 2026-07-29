# media-service
이미지 저장과 메타데이터, 썸네일 처리를 담당하는 미디어 서비스입니다.

## 책임
- S3 객체 저장 연동
- 이미지 메타데이터 관리
- 썸네일 처리

## 담당하지 않는 것 / 서비스 경계
- 게시물·OOTD·상품 등 미디어를 참조하는 도메인 데이터는 각 서비스가 소유합니다.
- CMS 배너와 정적 콘텐츠 구성은 `content-service`가 담당합니다.
- 미디어를 사용하는 화면 응답 조합은 BFF가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8092` |
| DB | PostgreSQL `postgres-media` (`mediadb`, 로컬 `5440`) |
| Gradle 모듈 경로 | `:services:media-service` |

## 주요 연동 및 이벤트
- 설계 문서상 S3 연동 대상입니다.
- S3 버킷·API와 구체적인 발행·구독 이벤트는 현재 문서와 코드에서 확인되지 않아 미정입니다.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:media-service:bootRun
```

## 미디어 attach 계약 (MEDIA-01)

소비 서비스는 **URL만** 저장하면 참조 중인 asset 을 삭제·정리할 수 없습니다.

1. 업로드 완료(`status=READY`) 후 **usage 등록**: `POST /internal/media/{assetId}/usage`  
   `{ usageType, resourceId }` → `media_usage` INSERT (`released_at` NULL).
2. 도메인 DB에 **`media_asset_id` + `public_url` 스냅샷** 저장  
   (social `post_image`, fashion `ootd_image`, content `banner`, user `avatar_media_asset_id`).
3. detach 시 usage **`released_at`** 설정 후 로컬 행 삭제/갱신.

DB 보장:

- `READY` 가 아닌 asset 에 usage 등록 불가 (트리거).
- 활성 usage 가 있으면 asset `status=DELETED` 불가 (트리거).
- `media_asset`: `status` ↔ `deleted_at` CHECK.

`usage_type`: `OOTD`, `POST`, `AVATAR`, `PRODUCT`, `BRAND_LOGO`, `BANNER`.

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka 기본 설정, `media_asset`, `media_usage`, `outbox_events`, `processed_events` 테이블 migration
- 미구현: 미디어 Entity·Repository·API와 비즈니스 로직, S3 어댑터, 업로드·썸네일 처리
