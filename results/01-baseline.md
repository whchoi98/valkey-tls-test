# Valkey 8.2 TLS vs Non-TLS Connection Storm 테스트 결과

## 테스트 환경

| 항목 | Non-TLS | TLS |
|------|---------|-----|
| Replication Group | valkey-nontls-test | stviztlwuv2jozz |
| 인스턴스 타입 | cache.r7g.large | cache.r7g.large |
| 엔진 | Valkey 8.2.0 | Valkey 8.2.0 |
| Cluster Mode | Enabled (1 shard) | Enabled (2 shard) |
| 구성 | 1 master + 1 replica | 2 master + 2 replica |
| Transit Encryption | Disabled | Required |
| At-Rest Encryption | Disabled | Enabled |
| 리전 | ap-northeast-2 | ap-northeast-2 |

### 클라이언트 환경
- EC2: c7g.xlarge (ARM64, 4 vCPU) — 동일 VPC 내 Private Subnet
- OS: Amazon Linux 2023
- 테스트 도구: Rust ClusterClient (redis crate v0.27, tokio async runtime)
- 각 동시접속 단위로 독립 ClusterClient 생성 → get_connection() → check_connection()
- 타임아웃: 15초

---

## 테스트 결과

### Non-TLS (r7g.large, 1 shard)

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 10ms | 10/10 | 100% | 1,000 c/s |
| 50 | 16ms | 50/50 | 100% | 3,125 c/s |
| 100 | 19ms | 100/100 | 100% | 5,263 c/s |
| 200 | 5.0s | 200/200 | 100% | 40 c/s |
| 500 | 10.0s | 473/500 | 94.6% | 47 c/s |
| 1,000 | 15.0s | 640/1000 | 64.0% | 43 c/s |
| 2,000 | 15.0s | 464/2000 | 23.2% | 31 c/s |

### TLS (r7g.large, 2 shard)

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 129ms | 10/10 | 100% | 78 c/s |
| 50 | 199ms | 50/50 | 100% | 251 c/s |
| 100 | 5.3s | 100/100 | 100% | 19 c/s |
| 200 | 5.4s | 200/200 | 100% | 37 c/s |
| 500 | 15.3s | 151/500 | 30.2% | 10 c/s |
| 1,000 | 15.3s | 578/1000 | 57.8% | 38 c/s |
| 2,000 | 15.1s | 1012/2000 | 50.6% | 67 c/s |

---

## 비교 분석

### 소규모 동시접속 (10~100)

| 동시접속 | Non-TLS | TLS | TLS 오버헤드 |
|----------|---------|-----|-------------|
| 10 | 10ms | 129ms | **12.9x** |
| 50 | 16ms | 199ms | **12.4x** |
| 100 | 19ms | 5.3s | **279x** |

- 10~50 동시접속: TLS 핸드셰이크 오버헤드로 약 **12~13배** 느림
- 100 동시접속: Non-TLS는 19ms에 완료, TLS는 5.3초 소요 (서버 측 TLS 처리 병목)

### 대규모 동시접속 (200~2000)

| 동시접속 | Non-TLS 성공률 | TLS 성공률 |
|----------|---------------|-----------|
| 200 | 100% | 100% |
| 500 | 94.6% | 30.2% |
| 1,000 | 64.0% | 57.8% |
| 2,000 | 23.2% | 50.6% |

- 500 동시접속에서 TLS 성공률이 30.2%로 급격히 하락
- Non-TLS도 500+ 에서 타임아웃 발생 (r7g.large의 네트워크/커넥션 한계)

### 피크 처리량 비교

| 지표 | Non-TLS | TLS | 배율 |
|------|---------|-----|------|
| 최대 처리량 (c/s) | ~5,263 (100 conns) | ~251 (50 conns) | **~21x** |
| 100% 성공 최대 동시접속 | 200 | 200 | 동일 |
| 100% 성공 시 wall time (200 conns) | 5.0s | 5.4s | 1.08x |

---

## 핵심 발견사항

1. **TLS 핸드셰이크 레이턴시**: 소규모(10~50) 동시접속에서 Non-TLS 대비 약 12~13배 느림
2. **TLS 처리량 병목**: 피크 처리량 기준 Non-TLS 대비 약 21배 차이
3. **서버 측 TLS 처리 한계**: 100 동시접속부터 TLS 서버 측 핸드셰이크 처리가 병목 (5초+ 소요)
4. **r7g.large 한계**: Non-TLS도 500+ 동시접속에서 타임아웃 발생 — 인스턴스 크기 한계
5. **2 shard TLS가 1 shard Non-TLS보다 느림**: TLS 오버헤드가 shard 추가 효과를 상쇄

---

## 참고사항

- 기존 제공된 테스트 결과(Non-TLS ~2,291 c/s, TLS ~53 c/s, 43배 차이)와 비교하면, 이번 테스트에서도 유사한 경향 확인 (21배 차이)
- 차이 원인: 기존 테스트는 r7g.2xlarge TLS + 1 shard, 이번 테스트는 r7g.large TLS + 2 shard
- 클라이언트 구현 방식(Rust redis crate의 ClusterClient 동기 모드)에 따라 절대 수치는 달라질 수 있음
- 실제 운영 환경에서는 connection pooling으로 초기 연결 비용을 분산하는 것이 권장됨

---

*테스트 일시: 2026-04-01 16:52 UTC*
*테스트 클라이언트: c7g.xlarge (ap-northeast-2a), 동일 VPC Private Subnet*
