<div align="center">

🇰🇷 [한국어](#한국어) | 🇺🇸 [English](#english)

</div>

---

# 한국어

# 베이스라인 테스트: Non-TLS vs TLS Connection Storm

> 테스트 일시: 2026-04-01 16:52 UTC
> 목적: TLS 전환이 connection storm 성능에 미치는 정량적 영향 측정

## 테스트 환경

| 항목 | Non-TLS 클러스터 | TLS 클러스터 |
|------|-----------------|-------------|
| Replication Group | valkey-nontls-test | stviztlwuv2jozz |
| 인스턴스 타입 | cache.r7g.large (2 vCPU) | cache.r7g.large (2 vCPU) |
| 엔진 | Valkey 8.2.0 | Valkey 8.2.0 |
| Cluster Mode | Enabled, 1 shard | Enabled, 2 shard |
| 구성 | 1 master + 1 replica | 2 master + 2 replica |
| Transit Encryption | Disabled | Required |
| 리전 | ap-northeast-2 | ap-northeast-2 |

### 클라이언트

- EC2: c7g.xlarge (ARM64, 4 vCPU, 8 GiB)
- OS: Amazon Linux 2023
- 위치: 동일 VPC Private Subnet (ap-northeast-2a)
- 테스트 도구: Rust redis crate v0.27 ClusterClient (동기 모드)
- 테스트 방식: 각 동시접속 단위로 독립 ClusterClient 생성 → get_connection() → check_connection() (PING)
- 타임아웃: 15초

---

## 결과

### Non-TLS Storm (r7g.large, 1 shard)

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 10ms | 10/10 | 100% | 1,000 c/s |
| 50 | 16ms | 50/50 | 100% | 3,125 c/s |
| 100 | 19ms | 100/100 | 100% | 5,263 c/s |
| 200 | 5.0s | 200/200 | 100% | 40 c/s |
| 500 | 10.0s | 473/500 | 94.6% | 47 c/s |
| 1,000 | 15.0s | 640/1000 | 64.0% | 43 c/s |
| 2,000 | 15.0s | 464/2000 | 23.2% | 31 c/s |

### TLS Storm (r7g.large, 2 shard, required)

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

### Wall Time 비교

| 동시접속 | Non-TLS | TLS | TLS 오버헤드 |
|----------|---------|-----|-------------|
| 10 | 10ms | 129ms | 12.9x |
| 50 | 16ms | 199ms | 12.4x |
| 100 | 19ms | 5.3s | 279x |
| 200 | 5.0s | 5.4s | 1.08x |
| 500 | 10.0s | 15.3s | 1.53x |

### 성공률 비교

| 동시접속 | Non-TLS | TLS | 차이 |
|----------|---------|-----|------|
| 200 | 100% | 100% | 동일 |
| 500 | 94.6% | 30.2% | -64.4%p |
| 1,000 | 64.0% | 57.8% | -6.2%p |
| 2,000 | 23.2% | 50.6% | +27.4%p |

### 피크 처리량

| 지표 | Non-TLS | TLS | 배율 |
|------|---------|-----|------|
| 최대 처리량 | ~5,263 c/s (100 conns) | ~251 c/s (50 conns) | **~21x** |

---

## 인사이트

1. **TLS 핸드셰이크 순수 오버헤드 (10~50 conns)**
   - TLS가 Non-TLS 대비 약 12~13배 느림
   - 이 구간에서는 서버 측 병목 없이 순수 TLS 핸드셰이크 비용만 반영
   - 단일 TLS 핸드셰이크에 약 10~13ms 소요 (129ms / 10 conns ≈ 13ms/conn)

2. **서버 측 TLS 처리 병목 (100 conns)**
   - Non-TLS는 19ms에 100개 연결 완료 (서버 측 TCP accept가 매우 빠름)
   - TLS는 5.3초 소요 — **279배 차이**
   - 서버가 TLS 핸드셰이크를 직렬 또는 제한된 병렬로 처리하면서 병목 발생
   - Valkey의 `max-new-tls-connections-per-cycle` 파라미터가 낮게 설정되어 있을 가능성

3. **r7g.large 인스턴스 한계 (200+ conns)**
   - 200 conns에서 Non-TLS도 5초 소요 — 서버 측 연결 수락 처리 한계
   - 500+ conns에서 양쪽 모두 타임아웃 발생
   - r7g.large의 2 vCPU로는 대량 동시 연결 처리에 물리적 한계

4. **2,000 conns에서 TLS가 Non-TLS보다 높은 성공률 (50.6% vs 23.2%)**
   - 역설적 결과: TLS가 느리기 때문에 연결이 시간 분산되어 서버 부하가 평탄화
   - Non-TLS는 너무 빨리 몰려서 서버가 한꺼번에 과부하

5. **피크 처리량 21배 차이**
   - Non-TLS: 100 conns에서 5,263 c/s (서버가 여유 있는 구간)
   - TLS: 50 conns에서 251 c/s (이미 핸드셰이크 오버헤드 반영)
   - 실제 운영에서 connection storm이 발생하면 TLS 환경에서 심각한 서비스 영향

---

# English

# Baseline Test: Non-TLS vs TLS Connection Storm

> Test Date: 2026-04-01 16:52 UTC
> Purpose: Quantitative measurement of TLS transition impact on connection storm performance

## Test Environment

| Item | Non-TLS Cluster | TLS Cluster |
|------|----------------|-------------|
| Replication Group | valkey-nontls-test | stviztlwuv2jozz |
| Instance Type | cache.r7g.large (2 vCPU) | cache.r7g.large (2 vCPU) |
| Engine | Valkey 8.2.0 | Valkey 8.2.0 |
| Cluster Mode | Enabled, 1 shard | Enabled, 2 shard |
| Config | 1 master + 1 replica | 2 master + 2 replica |
| Transit Encryption | Disabled | Required |
| Region | ap-northeast-2 | ap-northeast-2 |

### Client

- EC2: c7g.xlarge (ARM64, 4 vCPU, 8 GiB)
- OS: Amazon Linux 2023
- Location: Same VPC Private Subnet (ap-northeast-2a)
- Test Tool: Rust redis crate v0.27 ClusterClient (sync mode)
- Method: Independent ClusterClient per concurrent connection → get_connection() → check_connection() (PING)
- Timeout: 15 seconds

---

## Results

### Non-TLS Storm (r7g.large, 1 shard)

| Concurrency | Wall Time | Success | Rate | Throughput |
|-------------|-----------|---------|------|------------|
| 10 | 10ms | 10/10 | 100% | 1,000 c/s |
| 50 | 16ms | 50/50 | 100% | 3,125 c/s |
| 100 | 19ms | 100/100 | 100% | 5,263 c/s |
| 200 | 5.0s | 200/200 | 100% | 40 c/s |
| 500 | 10.0s | 473/500 | 94.6% | 47 c/s |
| 1,000 | 15.0s | 640/1000 | 64.0% | 43 c/s |
| 2,000 | 15.0s | 464/2000 | 23.2% | 31 c/s |

### TLS Storm (r7g.large, 2 shard, required)

| Concurrency | Wall Time | Success | Rate | Throughput |
|-------------|-----------|---------|------|------------|
| 10 | 129ms | 10/10 | 100% | 78 c/s |
| 50 | 199ms | 50/50 | 100% | 251 c/s |
| 100 | 5.3s | 100/100 | 100% | 19 c/s |
| 200 | 5.4s | 200/200 | 100% | 37 c/s |
| 500 | 15.3s | 151/500 | 30.2% | 10 c/s |
| 1,000 | 15.3s | 578/1000 | 57.8% | 38 c/s |
| 2,000 | 15.1s | 1012/2000 | 50.6% | 67 c/s |

---

## Comparative Analysis

### Wall Time Comparison

| Concurrency | Non-TLS | TLS | TLS Overhead |
|-------------|---------|-----|-------------|
| 10 | 10ms | 129ms | 12.9x |
| 50 | 16ms | 199ms | 12.4x |
| 100 | 19ms | 5.3s | 279x |
| 200 | 5.0s | 5.4s | 1.08x |
| 500 | 10.0s | 15.3s | 1.53x |

### Success Rate Comparison

| Concurrency | Non-TLS | TLS | Difference |
|-------------|---------|-----|------------|
| 200 | 100% | 100% | Same |
| 500 | 94.6% | 30.2% | -64.4%p |
| 1,000 | 64.0% | 57.8% | -6.2%p |
| 2,000 | 23.2% | 50.6% | +27.4%p |

### Peak Throughput

| Metric | Non-TLS | TLS | Ratio |
|--------|---------|-----|-------|
| Max Throughput | ~5,263 c/s (100 conns) | ~251 c/s (50 conns) | **~21x** |

---

## Insights

1. **Pure TLS Handshake Overhead (10~50 conns)**
   - TLS is ~12~13x slower than Non-TLS
   - In this range, only pure TLS handshake cost is reflected without server-side bottleneck
   - Single TLS handshake takes ~10~13ms (129ms / 10 conns ≈ 13ms/conn)

2. **Server-side TLS Processing Bottleneck (100 conns)**
   - Non-TLS completes 100 connections in 19ms (server-side TCP accept is very fast)
   - TLS takes 5.3 seconds — **279x difference**
   - Bottleneck occurs as server processes TLS handshakes serially or with limited parallelism
   - Valkey's `max-new-tls-connections-per-cycle` parameter may be set low

3. **r7g.large Instance Limits (200+ conns)**
   - At 200 conns, even Non-TLS takes 5 seconds — server-side connection acceptance limit
   - At 500+ conns, both sides experience timeouts
   - r7g.large's 2 vCPU has physical limits for mass concurrent connection handling

4. **TLS Higher Success Rate at 2,000 conns (50.6% vs 23.2%)**
   - Paradoxical result: TLS being slower causes connections to be time-distributed, flattening server load
   - Non-TLS connections arrive too fast, overwhelming the server simultaneously

5. **21x Peak Throughput Difference**
   - Non-TLS: 5,263 c/s at 100 conns (server has headroom)
   - TLS: 251 c/s at 50 conns (handshake overhead already reflected)
   - In production, connection storms in TLS environments cause severe service impact
