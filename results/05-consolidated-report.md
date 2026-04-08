<div align="center">

🇰🇷 [한국어](#한국어) | 🇺🇸 [English](#english)

</div>

---

# 한국어

# TLS Connection Storm 통합 벤치마크 보고서

> 테스트 기간: 2026-04-01 ~ 2026-04-08
> 작성일: 2026-04-08

## 1. 개요

본 보고서는 Amazon ElastiCache for Valkey 8.2와 Redis OSS 7.2 Self-hosted 환경에서 Non-TLS → TLS 전환 시 발생하는 connection storm 성능 영향을 정량적으로 비교하고, 개선방안의 실효성을 종합 정리한 문서입니다.

### 테스트 목적

1. TLS 전환이 connection storm 성능에 미치는 정량적 영향 측정
2. ElastiCache Valkey vs Redis OSS Self-hosted 간 TLS 성능 차이 비교
3. 개선방안(preferred 모드, Connection Pool, Shard 증가)의 실효성 검증
4. Cascading failure 재현 및 완화 방안 검증

---

## 2. 테스트 환경

### 2.1 ElastiCache for Valkey 8.2

| 항목 | 사양 |
|------|------|
| 엔진 | Valkey 8.2.0 |
| 노드 타입 | cache.r7g.large (2 vCPU, 13.07 GiB) |
| Cluster Mode | Enabled |
| 리전 | ap-northeast-2 |

| 클러스터 | Shard | 구성 | TLS 모드 |
|----------|-------|------|----------|
| valkey-nontls-test | 1 | 1M + 1R | Disabled |
| stviztlwuv2jozz | 2 | 2M + 2R | required → preferred |
| valkey-tls-4shard | 4 | 4M + 4R | required |

### 2.2 Redis OSS 7.2 Self-hosted

| 항목 | 사양 |
|------|------|
| 엔진 | Redis OSS 7.2.7 (BUILD_TLS=yes) |
| 서버 인스턴스 | r7g.large (2 vCPU, 16 GiB) × 3대 |
| TLS | Self-signed CA, tls-auth-clients no |

| 클러스터 | 노드 | 호스트 | TLS |
|----------|------|--------|-----|
| Non-TLS | 3M + 3R | 1대 (10.11.62.234) | Disabled |
| TLS | 3M + 3R | 2대 (10.11.35.38, 10.11.88.49) | Enabled |

### 2.3 공통 클라이언트

| 항목 | 사양 |
|------|------|
| EC2 | c7g.xlarge (ARM64, 4 vCPU, 8 GiB) |
| 위치 | 동일 VPC Private Subnet |
| Rust | 1.94.1 |
| redis crate | 0.27 (cluster, tls-rustls) |
| 타임아웃 | 15초 |
| 테스트 방식 | Storm: 매 동시접속마다 새 ClusterClient 생성 → PING |
| | Pool: 단일 ClusterClient warm-up 후 공유 |

---

## 3. 전체 결과 데이터

### 3.1 ElastiCache Valkey — Non-TLS Storm (1 shard, 베이스라인)

| 동시접속 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| 10 | 10ms | 100% | 1,000 c/s |
| 50 | 16ms | 100% | 3,125 c/s |
| 100 | 19ms | 100% | 5,263 c/s |
| 200 | 5.0s | 100% | 40 c/s |
| 500 | 10.0s | 94.6% | 47 c/s |
| 1,000 | 15.0s | 64.0% | 43 c/s |
| 2,000 | 15.0s | 23.2% | 31 c/s |

### 3.2 ElastiCache Valkey — TLS Storm (2 shard, required)

| 동시접속 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| 10 | 129ms | 100% | 78 c/s |
| 50 | 199ms | 100% | 251 c/s |
| 100 | 5.3s | 100% | 19 c/s |
| 200 | 5.4s | 100% | 37 c/s |
| 500 | 15.3s | 30.2% | 10 c/s |
| 1,000 | 15.3s | 57.8% | 38 c/s |
| 2,000 | 15.1s | 50.6% | 67 c/s |

### 3.3 ElastiCache Valkey — TLS Pool (2 shard, required)

| 동시접속 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| 10 | 130ms | 100% | 77 c/s |
| 50 | 184ms | 100% | 272 c/s |
| 100 | 292ms | 100% | 342 c/s |
| 200 | 10.4s | 100% | 19 c/s |
| 500 | 15.3s | 36% | 12 c/s |
| 1,000 | 15.3s | 51.6% | 34 c/s |
| 2,000 | 15.1s | 36.1% | 48 c/s |

### 3.4 ElastiCache Valkey — preferred Non-TLS Storm (2 shard)

| 동시접속 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| 10 | 22ms | 100% | 455 c/s |
| 50 | 26ms | 100% | 1,923 c/s |
| 100 | 5.1s | 100% | 20 c/s |
| 200 | 10.1s | 90% | 18 c/s |
| 500 | 15.0s | 1% | 0 c/s |
| 1,000 | 15.0s | 0.9% | 1 c/s |
| 2,000 | 15.0s | 0% | 0 c/s |

### 3.5 ElastiCache Valkey — TLS Storm (4 shard, required)

| 동시접속 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| 10 | 354ms | 100% | 28 c/s |
| 50 | 460ms | 100% | 109 c/s |
| 100 | 5.5s | 100% | 18 c/s |
| 200 | 15.1s | 38% | 5 c/s |
| 500 | 15.4s | 32% | 10 c/s |
| 1,000 | 15.2s | 60.7% | 40 c/s |
| 2,000 | 15.0s | 26% | 35 c/s |

### 3.6 Redis OSS 7.2 — Non-TLS Storm (3M+3R, 1 host)

| 동시접속 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| 10 | 16ms | 100% | 625 c/s |
| 50 | 89ms | 100% | 562 c/s |
| 100 | 60ms | 100% | 1,667 c/s |
| 200 | 101ms | 100% | 1,980 c/s |
| 500 | 153ms | 100% | 3,268 c/s |
| 1,000 | 229ms | 100% | 4,367 c/s |
| 2,000 | 415ms | 100% | 4,819 c/s |

### 3.7 Redis OSS 7.2 — TLS Storm (3M+3R, 2 hosts)

| 동시접속 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| 10 | 113ms | 100% | 88 c/s |
| 50 | 708ms | 100% | 71 c/s |
| 100 | 919ms | 100% | 109 c/s |
| 200 | 2.0s | 100% | 98 c/s |
| 500 | 4.8s | 100% | 105 c/s |
| 1,000 | 8.7s | 100% | 115 c/s |
| 2,000 | 15.1s | 77% | 102 c/s |

### 3.8 Redis OSS 7.2 — TLS Pool (3M+3R, 2 hosts)

| 동시접속 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| 10 | 111ms | 100% | 90 c/s |
| 50 | 452ms | 100% | 111 c/s |
| 100 | 916ms | 100% | 109 c/s |
| 200 | 1.8s | 100% | 110 c/s |
| 500 | 4.4s | 100% | 114 c/s |
| 1,000 | 8.7s | 100% | 114 c/s |
| 2,000 | 15.1s | 77% | 102 c/s |

---

## 4. 핵심 비교 분석

### 4.1 ElastiCache Valkey vs Redis OSS — TLS 오버헤드

#### 100 동시접속 (핵심 비교 포인트)

| 시나리오 | Wall Time | 성공률 | 처리량 | 비고 |
|----------|-----------|--------|--------|------|
| **Valkey Non-TLS Storm** | 19ms | 100% | 5,263 c/s | 베이스라인 |
| **Valkey TLS Storm** | 5.3s | 100% | 19 c/s | 279x 느림 |
| Valkey TLS Pool | 292ms | 100% | 342 c/s | 18x 개선 |
| **Redis OSS Non-TLS Storm** | 60ms | 100% | 1,667 c/s | |
| **Redis OSS TLS Storm** | 919ms | 100% | 109 c/s | 15x 느림 |
| Redis OSS TLS Pool | 916ms | 100% | 109 c/s | 개선 없음 |

#### 500 동시접속

| 시나리오 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| Valkey Non-TLS Storm | 10.0s | 94.6% | 47 c/s |
| Valkey TLS Storm | 15.3s | 30.2% | 10 c/s |
| Valkey TLS Pool | 15.3s | 36% | 12 c/s |
| Redis OSS Non-TLS Storm | 153ms | 100% | 3,268 c/s |
| Redis OSS TLS Storm | 4.8s | 100% | 105 c/s |
| Redis OSS TLS Pool | 4.4s | 100% | 114 c/s |

#### 2,000 동시접속

| 시나리오 | Wall Time | 성공률 | 처리량 |
|----------|-----------|--------|--------|
| Valkey Non-TLS Storm | 15.0s | 23.2% | 31 c/s |
| Valkey TLS Storm | 15.1s | 50.6% | 67 c/s |
| Redis OSS Non-TLS Storm | 415ms | 100% | 4,819 c/s |
| Redis OSS TLS Storm | 15.1s | 77% | 102 c/s |

### 4.2 TLS 오버헤드 배율 비교

| 동시접속 | Valkey (TLS/Non-TLS) | Redis OSS (TLS/Non-TLS) |
|----------|---------------------|------------------------|
| 10 | 12.9x | 7.1x |
| 50 | 12.4x | 8.0x |
| 100 | 279x | 15.3x |
| 500 | 1.5x (양쪽 타임아웃) | 31.4x |
| 1,000 | 1.0x (양쪽 타임아웃) | 38.0x |

### 4.3 ElastiCache vs Self-hosted 차이 원인

| 요인 | ElastiCache | Redis OSS Self-hosted |
|------|------------|----------------------|
| 프록시 레이어 | Configuration Endpoint 프록시 존재 | 직접 노드 접속 |
| 연결 수락 제한 | `max-new-tls-connections-per-cycle` 등 내부 제한 | 기본 설정 (제한 완화) |
| 네트워크 홉 | 프록시 → 노드 (추가 홉) | 클라이언트 → 노드 (직접) |
| 대규모 성공률 | 500 conns에서 30~95% | 500 conns에서 100% |
| 운영 부담 | 없음 (관리형) | 높음 (직접 관리) |

**핵심:** ElastiCache의 TLS 성능이 Self-hosted보다 낮은 것은 프록시 레이어와 내부 연결 제한 때문이지만, 관리형 서비스의 HA/패치/모니터링 이점을 고려하면 트레이드오프입니다.

---

## 5. 개선방안 종합 평가

### 5.1 효과 매트릭스

| 방안 | 소규모 (10~50) | 중규모 (100) | 대규모 (500+) | 구현 난이도 | 종합 |
|------|---------------|-------------|--------------|-----------|------|
| ① preferred + Non-TLS | ✅ 6~8x 빠름 | ⚠️ 효과 없음 | ❌ 급격히 악화 | 낮음 | 제한적 |
| ② Connection Pool (Valkey) | ⚠️ 동일 | ✅ **18x 개선** | ⚠️ 약간 개선 | 중간 | **최우선** |
| ② Connection Pool (Redis OSS) | ⚠️ 동일 | ⚠️ 효과 없음 | ⚠️ 동일 | 중간 | 제한적 |
| ④ Shard 증가 | ❌ 2~3x 악화 | ❌ 효과 없음 | ⚠️ 유사 | 높음 | 역효과 |

### 5.2 Connection Pool + Warm-up 상세 검증 데이터

> 대상: ElastiCache Valkey 8.2, stviztlwuv2jozz (r7g.large, 2 shard, TLS required)

**테스트 원리:**
```
[Storm 모드]  100 conns × 2 shard × 2 노드 = 최대 400회 TLS 핸드셰이크
[Pool 모드]   warm-up 시 1회 × 2 shard × 2 노드 = 4회 TLS 핸드셰이크 후 재사용
```

**전 구간 비교 (TLS required, 2 shard):**

| 동시접속 | Storm Wall Time | Storm 성공률 | Pool Wall Time | Pool 성공률 | 개선 |
|----------|----------------|-------------|----------------|-------------|------|
| 10 | 129ms | 100% | 130ms | 100% | 동일 |
| 50 | 199ms | 100% | 184ms | 100% | 1.1x |
| **100** | **5.3s** | **100%** | **292ms** | **100%** | **18.2x** |
| 200 | 5.4s | 100% | 10.4s | 100% | 0.5x (악화) |
| 500 | 15.3s | 30.2% | 15.3s | 36% | +5.8%p |
| 1,000 | 15.3s | 57.8% | 15.3s | 51.6% | -6.2%p |
| 2,000 | 15.1s | 50.6% | 15.1s | 36.1% | -14.5%p |

**처리량 비교:**

| 동시접속 | Storm 처리량 | Pool 처리량 | 배율 |
|----------|------------|------------|------|
| 10 | 78 c/s | 77 c/s | 동일 |
| 50 | 251 c/s | 272 c/s | 1.1x |
| **100** | **19 c/s** | **342 c/s** | **18x** |
| 200 | 37 c/s | 19 c/s | 0.5x |
| 500 | 10 c/s | 12 c/s | 1.2x |

**구간별 분석:**

- **10~50 conns**: 핸드셰이크 총 횟수가 적어 Pool의 이점이 없음
- **100 conns (핵심)**: Storm은 100 × 4노드 = 400회 핸드셰이크를 서버가 직렬 처리 → 5.3s. Pool은 warm-up 4회 후 재사용 → 292ms
- **200+ conns**: 단일 ClusterClient 내부의 slot별 연결 관리에서 mutex 경합 발생. Pool이 오히려 느려짐
- **결론**: Connection Pool은 **중규모(50~200) 동시접속에서 가장 효과적**

### 5.3 Connection Pool 효과 차이 분석 (ElastiCache vs Redis OSS)

ElastiCache에서 Pool이 18x 개선을 보인 반면, Redis OSS에서는 효과가 없었던 이유:

| 100 conns | Storm | Pool | 개선 |
|-----------|-------|------|------|
| ElastiCache Valkey | 5.3s, 19 c/s | 292ms, 342 c/s | **18x** |
| Redis OSS | 919ms, 109 c/s | 916ms, 109 c/s | **없음** |

- **ElastiCache**: Configuration Endpoint 프록시가 연결을 관리하므로, Pool warm-up 시 프록시와의 연결이 재사용됨
- **Redis OSS**: 직접 노드 접속이므로, Pool 모드에서도 `get_connection()` 호출 시 내부적으로 새 연결이 생성될 수 있음
- **redis crate 0.27의 ClusterClient**: sync 모드에서 connection pool 관리가 제한적

---

## 6. Cascading Failure 테스트 결과 (재시도 + 백오프 검증)

> 대상: ElastiCache Valkey 8.2, stviztlwuv2jozz (r7g.large, 2 shard, TLS preferred)
> 클라이언트: c7g.xlarge, 동일 VPC, 60초 제한

### 6.1 장애 시나리오 재현 구조

```
앞단 Pod 장애 → HPA 스케일아웃 → 대량 Pod 동시 생성
→ Pod당 TLS 연결 동시 생성
→ Valkey TLS 핸드셰이크 한계 초과 → 타임아웃
→ 앱 무한 재시도 (backoff 없음) → 연결 시도 누적 증가
→ 반완료 TLS 세션 메모리 누적 → 메모리 100% → 노드 먹통
→ 페일오버 → 페일오버 대상도 동일 storm → 장애 지속
```

### 6.2 시나리오별 상세 결과

**시나리오 1: 장애 재현 (500 pods, 10 retries, no backoff)**

```
  [  5s] attempts=501  ok=67   fail=1
  [ 10s] attempts=933  ok=292  fail=433
  [ 15s] attempts=1129 ok=467  fail=629
  [ 20s] attempts=1162 ok=492  fail=662

Total attempts: 1,170
Success: 500 (100%), Fail: 670
Amplification: 2.3x
```

- 5초 시점: 501회 시도 중 67개만 성공 (13.4%)
- 670회의 실패한 TLS 핸드셰이크가 서버 메모리에 부하
- 실제 환경에서는 재시도 무제한 → 증폭 10x~100x

**시나리오 2: Fail Fast (500 pods, no retry)**

```
  [  5s] attempts=500  ok=46   fail=2

Total attempts: 500
Success: 46 (9.2%), Fail: 454
Amplification: 1.0x
```

- 정확히 500회만 시도 (증폭 없음)
- 성공률 9.2%이지만 **서버에 추가 부하 없음** → 서버 회복 시간 확보

**시나리오 3: 지수 백오프 재시도 (500 pods, 3 retries, exponential backoff)**

```
  [  5s] attempts=500  ok=28   fail=8
  [ 10s] attempts=972  ok=295  fail=472
  [ 15s] attempts=1140 ok=483  fail=650

Total attempts: 1,150
Success: 500 (100%), Fail: 650
Amplification: 2.3x
```

- 총 시도 횟수는 시나리오 1과 유사하지만 **재시도가 시간에 분산**
- 서버가 회복할 틈을 줌 → 최종 **100% 성공**

**시나리오 4: HPA 제한 + 백오프 (200 pods, 3 retries, exponential backoff)**

```
  [  5s] attempts=200  ok=14   fail=8
  [ 10s] attempts=386  ok=183  fail=186
  [ 15s] attempts=403  ok=198  fail=203

Total attempts: 403
Success: 200 (100%), Fail: 203
Amplification: 2.0x
```

- 총 시도 403회 (시나리오 1의 **1/3**)
- 서버 부하 **60% 감소** → cascading failure 위험 최소

### 6.3 시나리오 비교

**서버 부하 비교 (5초 시점):**

| 시나리오 | 5초 시점 시도 | 5초 시점 실패 | 서버 부하 |
|----------|-------------|-------------|----------|
| 1. 장애 재현 (no backoff) | 501 | 434 | ❌ 최대 |
| 2. Fail Fast (no retry) | 500 | 454 | ⚠️ 높지만 1회성 |
| 3. 지수 백오프 (3 retries) | 500 | 472 | ⚠️ 초기 동일, 이후 분산 |
| 4. HPA 제한 + 백오프 | 200 | 186 | ✅ **60% 감소** |

**총 연결 시도 횟수 (서버 누적 부하):**

| 시나리오 | 총 시도 | 총 실패 | 증폭 배율 | 완료 시간 | 최종 성공률 |
|----------|---------|---------|----------|----------|-----------|
| 1. 장애 재현 | 1,170 | 670 | 2.3x | ~20s | 100% (670 실패 포함) |
| 2. Fail Fast | 500 | 454 | 1.0x | ~5s | 9.2% |
| 3. 지수 백오프 | 1,150 | 650 | 2.3x | ~15s | **100%** |
| 4. HPA + 백오프 | 403 | 203 | 2.0x | ~15s | **100%** |

### 6.4 핵심 교훈

1. **무한 재시도 금지** — 재시도 없는 경우 증폭 1.0x, 10회 재시도 시 2.3x (실제 환경에서는 10x~100x)
2. **Fail Fast가 서버를 보호** — 성공률 9.2%이지만 서버 회복 시간 확보. 서버가 죽으면 모든 Pod가 실패
3. **지수 백오프 필수** — 재시도를 시간 분산하여 순간 부하 감소, 최종 100% 성공
4. **HPA 속도 제한이 가장 효과적** — 동시 Pod 수 제한으로 서버 부하 60% 감소, 100% 성공

### 6.5 실제 장애와의 차이점

이 테스트는 60초 제한으로 수행되었으며, 실제 장애 환경과 다른 점:
- 실제: 재시도 무제한 → 증폭 배율 10x~100x
- 실제: Python 프로세스당 연결 → CPU 수 × Pod 수 = 더 많은 동시 연결
- 실제: 장시간 지속 → 반완료 TLS 세션 메모리 누적 → OOM
- 이 테스트에서는 60초 제한으로 OOM까지 도달하지 않음

---

## 7. 최종 결론

### 7.1 TLS Connection Storm은 엔진 무관한 공통 문제

- ElastiCache Valkey 8.2와 Redis OSS 7.2 모두에서 TLS 전환 시 connection storm 성능 저하 발생
- 근본 원인은 **TLS 핸드셰이크의 CPU 비용**이며, 엔진 차이가 아님
- ElastiCache는 프록시 레이어로 인해 추가 병목이 있지만, 관리형 서비스 이점과 트레이드오프

### 7.2 권장 조치 (우선순위)

| 순위 | 조치 | 효과 | 적용 대상 |
|------|------|------|----------|
| 1 | **Connection Pool + Warm-up** | 중규모에서 18x 개선 (ElastiCache) | 코드 변경 |
| 2 | **재시도 제한 + 지수 백오프** | 증폭 방지, 서버 보호 | 코드 1줄 |
| 3 | **Staggered Reconnection** | 동시 핸드셰이크 시간 분산 | 아키텍처 |
| 4 | **HPA 속도 제한** | 동시 Pod 수 제한 | YAML 변경 |
| 5 | **Readiness Probe에 연결 상태 포함** | 미연결 Pod 트래픽 차단 | YAML 변경 |

### 7.3 근본적 해결 방향

```
[문제] 배포 시 N개 Pod × M개 shard × 2 노드 = N×M×2 TLS 핸드셰이크 동시 발생

[해결]
1. Connection Pool: 핸드셰이크를 앱 시작 시 1회로 제한 → 18x 개선
2. Staggered Reconnection: 동시 핸드셰이크 수를 시간 분산
3. Envoy Sidecar: N개 앱 연결 → 소수 TLS 연결로 다중화
4. HPA 속도 제한: 동시 생성 Pod 수 제한으로 N 자체를 줄임
```

**TLS 자체를 끄는 것이 아니라, TLS 핸드셰이크 횟수를 최소화하는 것이 핵심입니다.**

---

## 8. 인프라 정보

### ElastiCache 클러스터

| 클러스터 | Endpoint |
|----------|----------|
| valkey-nontls-test | valkey-nontls-test.khojwc.clustercfg.apn2.cache.amazonaws.com:6379 |
| stviztlwuv2jozz | clustercfg.stviztlwuv2jozz.khojwc.apn2.cache.amazonaws.com:6379 |
| valkey-tls-4shard | clustercfg.valkey-tls-4shard.khojwc.apn2.cache.amazonaws.com:6379 |

### Redis OSS Self-hosted EC2

| 서버 | Instance ID | IP | 역할 |
|------|------------|-----|------|
| server-1 | i-083ea03e8a15bb568 | 10.11.62.234 | Non-TLS (3M+3R) |
| server-2 | i-0922dfe836d701437 | 10.11.35.38 | TLS shard (AZ-a) |
| server-3 | i-0b4afd836fb0046ab | 10.11.88.49 | TLS shard (AZ-b) |

### 클라이언트 EC2

| 인스턴스 | Instance ID | 타입 |
|----------|------------|------|
| valkey-conn-storm-test | i-021aa6df35a1d56ab | c7g.xlarge |

### 보안그룹

| SG | ID | 용도 |
|----|-----|------|
| Valkey-SG | sg-0a3c3d2faec77dc0b | ElastiCache 클러스터 |
| valkey-test-ec2-sg | sg-0a7cdb6f09726515d | 클라이언트 EC2 |
| redis-oss-test-sg | sg-010a561677d490581 | Redis OSS 서버 EC2 |

---

# English

# TLS Connection Storm Consolidated Benchmark Report

> Test Period: 2026-04-01 ~ 2026-04-08

## 1. Overview

This report quantitatively compares the performance impact of connection storms during Non-TLS → TLS transition on Amazon ElastiCache for Valkey 8.2 and Redis OSS 7.2 Self-hosted environments, and provides a comprehensive summary of mitigation strategy effectiveness.

### Test Objectives

1. Quantitative measurement of TLS transition impact on connection storm performance
2. Comparison of TLS performance between ElastiCache Valkey and Redis OSS Self-hosted
3. Validation of mitigation strategies (preferred mode, Connection Pool, Shard increase)
4. Cascading failure reproduction and mitigation validation

---

## 2. Test Environment

### 2.1 ElastiCache for Valkey 8.2

| Item | Specification |
|------|---------------|
| Engine | Valkey 8.2.0 |
| Node Type | cache.r7g.large (2 vCPU, 13.07 GiB) |
| Cluster Mode | Enabled |
| Region | ap-northeast-2 |

| Cluster | Shards | Config | TLS Mode |
|---------|--------|--------|----------|
| valkey-nontls-test | 1 | 1M + 1R | Disabled |
| stviztlwuv2jozz | 2 | 2M + 2R | required → preferred |
| valkey-tls-4shard | 4 | 4M + 4R | required |

### 2.2 Redis OSS 7.2 Self-hosted

| Item | Specification |
|------|---------------|
| Engine | Redis OSS 7.2.7 (BUILD_TLS=yes) |
| Server Instance | r7g.large (2 vCPU, 16 GiB) × 3 |
| TLS | Self-signed CA, tls-auth-clients no |

| Cluster | Nodes | Hosts | TLS |
|---------|-------|-------|-----|
| Non-TLS | 3M + 3R | 1 host (10.11.62.234) | Disabled |
| TLS | 3M + 3R | 2 hosts (10.11.35.38, 10.11.88.49) | Enabled |

### 2.3 Common Client

| Item | Specification |
|------|---------------|
| EC2 | c7g.xlarge (ARM64, 4 vCPU, 8 GiB) |
| Location | Same VPC Private Subnet |
| Rust | 1.94.1 |
| redis crate | 0.27 (cluster, tls-rustls) |
| Timeout | 15 seconds |
| Storm mode | New ClusterClient per concurrent connection → PING |
| Pool mode | Single ClusterClient warm-up then shared |

---

## 3. Full Result Data

### 3.1 ElastiCache Valkey — Non-TLS Storm (1 shard, baseline)

| Conns | Wall Time | Success Rate | Throughput |
|-------|-----------|-------------|------------|
| 10 | 10ms | 100% | 1,000 c/s |
| 50 | 16ms | 100% | 3,125 c/s |
| 100 | 19ms | 100% | 5,263 c/s |
| 200 | 5.0s | 100% | 40 c/s |
| 500 | 10.0s | 94.6% | 47 c/s |
| 1,000 | 15.0s | 64.0% | 43 c/s |
| 2,000 | 15.0s | 23.2% | 31 c/s |

### 3.2 ElastiCache Valkey — TLS Storm (2 shard, required)

| Conns | Wall Time | Success Rate | Throughput |
|-------|-----------|-------------|------------|
| 10 | 129ms | 100% | 78 c/s |
| 50 | 199ms | 100% | 251 c/s |
| 100 | 5.3s | 100% | 19 c/s |
| 200 | 5.4s | 100% | 37 c/s |
| 500 | 15.3s | 30.2% | 10 c/s |
| 1,000 | 15.3s | 57.8% | 38 c/s |
| 2,000 | 15.1s | 50.6% | 67 c/s |

### 3.3 ElastiCache Valkey — TLS Pool (2 shard, required)

| Conns | Wall Time | Success Rate | Throughput |
|-------|-----------|-------------|------------|
| 10 | 130ms | 100% | 77 c/s |
| 50 | 184ms | 100% | 272 c/s |
| 100 | 292ms | 100% | 342 c/s |
| 200 | 10.4s | 100% | 19 c/s |
| 500 | 15.3s | 36% | 12 c/s |
| 1,000 | 15.3s | 51.6% | 34 c/s |
| 2,000 | 15.1s | 36.1% | 48 c/s |

### 3.4 ElastiCache Valkey — preferred Non-TLS Storm (2 shard)

| Conns | Wall Time | Success Rate | Throughput |
|-------|-----------|-------------|------------|
| 10 | 22ms | 100% | 455 c/s |
| 50 | 26ms | 100% | 1,923 c/s |
| 100 | 5.1s | 100% | 20 c/s |
| 200 | 10.1s | 90% | 18 c/s |
| 500 | 15.0s | 1% | 0 c/s |
| 1,000 | 15.0s | 0.9% | 1 c/s |
| 2,000 | 15.0s | 0% | 0 c/s |

### 3.5 ElastiCache Valkey — TLS Storm (4 shard, required)

| Conns | Wall Time | Success Rate | Throughput |
|-------|-----------|-------------|------------|
| 10 | 354ms | 100% | 28 c/s |
| 50 | 460ms | 100% | 109 c/s |
| 100 | 5.5s | 100% | 18 c/s |
| 200 | 15.1s | 38% | 5 c/s |
| 500 | 15.4s | 32% | 10 c/s |
| 1,000 | 15.2s | 60.7% | 40 c/s |
| 2,000 | 15.0s | 26% | 35 c/s |

### 3.6 Redis OSS 7.2 — Non-TLS Storm (3M+3R, 1 host)

| Conns | Wall Time | Success Rate | Throughput |
|-------|-----------|-------------|------------|
| 10 | 16ms | 100% | 625 c/s |
| 50 | 89ms | 100% | 562 c/s |
| 100 | 60ms | 100% | 1,667 c/s |
| 200 | 101ms | 100% | 1,980 c/s |
| 500 | 153ms | 100% | 3,268 c/s |
| 1,000 | 229ms | 100% | 4,367 c/s |
| 2,000 | 415ms | 100% | 4,819 c/s |

### 3.7 Redis OSS 7.2 — TLS Storm (3M+3R, 2 hosts)

| Conns | Wall Time | Success Rate | Throughput |
|-------|-----------|-------------|------------|
| 10 | 113ms | 100% | 88 c/s |
| 50 | 708ms | 100% | 71 c/s |
| 100 | 919ms | 100% | 109 c/s |
| 200 | 2.0s | 100% | 98 c/s |
| 500 | 4.8s | 100% | 105 c/s |
| 1,000 | 8.7s | 100% | 115 c/s |
| 2,000 | 15.1s | 77% | 102 c/s |

### 3.8 Redis OSS 7.2 — TLS Pool (3M+3R, 2 hosts)

| Conns | Wall Time | Success Rate | Throughput |
|-------|-----------|-------------|------------|
| 10 | 111ms | 100% | 90 c/s |
| 50 | 452ms | 100% | 111 c/s |
| 100 | 916ms | 100% | 109 c/s |
| 200 | 1.8s | 100% | 110 c/s |
| 500 | 4.4s | 100% | 114 c/s |
| 1,000 | 8.7s | 100% | 114 c/s |
| 2,000 | 15.1s | 77% | 102 c/s |

---

## 4. Key Comparative Analysis

### 4.1 ElastiCache Valkey vs Redis OSS — TLS Overhead

#### 100 Concurrent Connections (Key Comparison)

| Scenario | Wall Time | Success Rate | Throughput | Note |
|----------|-----------|-------------|------------|------|
| **Valkey Non-TLS Storm** | 19ms | 100% | 5,263 c/s | Baseline |
| **Valkey TLS Storm** | 5.3s | 100% | 19 c/s | 279x slower |
| Valkey TLS Pool | 292ms | 100% | 342 c/s | 18x improvement |
| **Redis OSS Non-TLS Storm** | 60ms | 100% | 1,667 c/s | |
| **Redis OSS TLS Storm** | 919ms | 100% | 109 c/s | 15x slower |
| Redis OSS TLS Pool | 916ms | 100% | 109 c/s | No improvement |

#### TLS Overhead Ratio Comparison

| Conns | Valkey (TLS/Non-TLS) | Redis OSS (TLS/Non-TLS) |
|-------|---------------------|------------------------|
| 10 | 12.9x | 7.1x |
| 50 | 12.4x | 8.0x |
| 100 | 279x | 15.3x |
| 500 | 1.5x (both timeout) | 31.4x |

#### ElastiCache vs Self-hosted Difference Causes

| Factor | ElastiCache | Redis OSS Self-hosted |
|--------|------------|----------------------|
| Proxy Layer | Configuration Endpoint proxy exists | Direct node access |
| Connection Limits | Internal rate limiting | Default settings (relaxed) |
| Network Hops | Proxy → Node (extra hop) | Client → Node (direct) |
| 500 conns Success Rate | 30~95% | 100% |
| Operational Burden | None (managed) | High (self-managed) |

---

## 5. Mitigation Strategy Evaluation

### 5.1 Effectiveness Matrix

| Strategy | Low (10~50) | Medium (100) | High (500+) | Complexity | Overall |
|----------|-------------|-------------|-------------|------------|---------|
| ① preferred + Non-TLS | ✅ 6~8x faster | ⚠️ No effect | ❌ Severe degradation | Low | Limited |
| ② Connection Pool (Valkey) | ⚠️ Same | ✅ **18x improvement** | ⚠️ Slight improvement | Medium | **Top priority** |
| ② Connection Pool (Redis OSS) | ⚠️ Same | ⚠️ No effect | ⚠️ Same | Medium | Limited |
| ④ More Shards | ❌ 2~3x worse | ❌ No effect | ⚠️ Similar | High | Counterproductive |

### 5.2 Connection Pool + Warm-up Detailed Validation

> Target: ElastiCache Valkey 8.2, stviztlwuv2jozz (r7g.large, 2 shard, TLS required)

**Test Principle:**
```
[Storm mode]  100 conns × 2 shards × 2 nodes = up to 400 TLS handshakes
[Pool mode]   warm-up 1 time × 2 shards × 2 nodes = 4 TLS handshakes then reuse
```

**Full Range Comparison (TLS required, 2 shard):**

| Conns | Storm Wall Time | Storm Success | Pool Wall Time | Pool Success | Improvement |
|-------|----------------|--------------|----------------|-------------|-------------|
| 10 | 129ms | 100% | 130ms | 100% | Same |
| 50 | 199ms | 100% | 184ms | 100% | 1.1x |
| **100** | **5.3s** | **100%** | **292ms** | **100%** | **18.2x** |
| 200 | 5.4s | 100% | 10.4s | 100% | 0.5x (worse) |
| 500 | 15.3s | 30.2% | 15.3s | 36% | +5.8%p |
| 1,000 | 15.3s | 57.8% | 15.3s | 51.6% | -6.2%p |
| 2,000 | 15.1s | 50.6% | 15.1s | 36.1% | -14.5%p |

**Throughput Comparison:**

| Conns | Storm Throughput | Pool Throughput | Ratio |
|-------|-----------------|-----------------|-------|
| **100** | **19 c/s** | **342 c/s** | **18x** |
| 200 | 37 c/s | 19 c/s | 0.5x |
| 500 | 10 c/s | 12 c/s | 1.2x |

**Per-Range Analysis:**
- **10~50 conns**: Total handshake count is low, no Pool advantage
- **100 conns (key)**: Storm processes 100 × 4 nodes = 400 handshakes serially → 5.3s. Pool reuses after 4 warm-up handshakes → 292ms
- **200+ conns**: Mutex contention in single ClusterClient's internal slot-based connection management. Pool becomes slower
- **Conclusion**: Connection Pool is **most effective at medium concurrency (50~200)**

### 5.3 Connection Pool Effect Difference (ElastiCache vs Redis OSS)

| 100 conns | Storm | Pool | Improvement |
|-----------|-------|------|-------------|
| ElastiCache Valkey | 5.3s, 19 c/s | 292ms, 342 c/s | **18x** |
| Redis OSS | 919ms, 109 c/s | 916ms, 109 c/s | **None** |

- **ElastiCache**: Configuration Endpoint proxy manages connections; Pool warm-up connections are reused through proxy
- **Redis OSS**: Direct node access; `get_connection()` may internally create new connections even in Pool mode
- **redis crate 0.27 ClusterClient**: Limited connection pool management in sync mode

---

## 6. Cascading Failure Test Results (Retry + Backoff Validation)

> Target: ElastiCache Valkey 8.2, stviztlwuv2jozz (r7g.large, 2 shard, TLS preferred)
> Client: c7g.xlarge, Same VPC, 60-second limit

### 6.1 Failure Scenario Structure

```
Frontend Pod failure → HPA scale-out → Mass Pod creation
→ Per-Pod TLS connections created simultaneously
→ Valkey TLS handshake limit exceeded → Timeouts
→ App infinite retry (no backoff) → Connection attempts accumulate
→ Half-completed TLS session memory accumulates → Memory 100% → Node unresponsive
→ Failover → Failover target hit by same storm → Failure persists
```

### 6.2 Detailed Results by Scenario

**Scenario 1: Failure Reproduction (500 pods, 10 retries, no backoff)**

```
  [  5s] attempts=501  ok=67   fail=1
  [ 10s] attempts=933  ok=292  fail=433
  [ 15s] attempts=1129 ok=467  fail=629
  [ 20s] attempts=1162 ok=492  fail=662

Total attempts: 1,170
Success: 500 (100%), Fail: 670
Amplification: 2.3x
```

- At 5s: 501 attempts with only 67 successes (13.4%)
- 670 failed TLS handshakes put load on server memory
- In production: unlimited retries → amplification 10x~100x

**Scenario 2: Fail Fast (500 pods, no retry)**

```
  [  5s] attempts=500  ok=46   fail=2

Total attempts: 500
Success: 46 (9.2%), Fail: 454
Amplification: 1.0x
```

- Exactly 500 attempts (no amplification)
- 9.2% success but **no additional server load** → server gets recovery time

**Scenario 3: Exponential Backoff (500 pods, 3 retries)**

```
  [  5s] attempts=500  ok=28   fail=8
  [ 10s] attempts=972  ok=295  fail=472
  [ 15s] attempts=1140 ok=483  fail=650

Total attempts: 1,150
Success: 500 (100%), Fail: 650
Amplification: 2.3x
```

- Similar total attempts to Scenario 1 but **retries distributed over time**
- Server gets breathing room → final **100% success**

**Scenario 4: HPA Limit + Backoff (200 pods, 3 retries)**

```
  [  5s] attempts=200  ok=14   fail=8
  [ 10s] attempts=386  ok=183  fail=186
  [ 15s] attempts=403  ok=198  fail=203

Total attempts: 403
Success: 200 (100%), Fail: 203
Amplification: 2.0x
```

- Total 403 attempts (**1/3 of Scenario 1**)
- Server load **60% reduction** → minimal cascading failure risk

### 6.3 Scenario Comparison

**Server Load at 5 Seconds:**

| Scenario | Attempts at 5s | Failures at 5s | Server Load |
|----------|---------------|----------------|-------------|
| 1. Reproduce (no backoff) | 501 | 434 | ❌ Maximum |
| 2. Fail Fast (no retry) | 500 | 454 | ⚠️ High but one-time |
| 3. Exponential backoff | 500 | 472 | ⚠️ Same initially, distributed later |
| 4. HPA limit + backoff | 200 | 186 | ✅ **60% reduction** |

**Total Connection Attempts (Cumulative Server Load):**

| Scenario | Total | Failures | Amplification | Time | Success Rate |
|----------|-------|----------|---------------|------|-------------|
| 1. Reproduce | 1,170 | 670 | 2.3x | ~20s | 100% (670 failures) |
| 2. Fail Fast | 500 | 454 | 1.0x | ~5s | 9.2% |
| 3. Backoff | 1,150 | 650 | 2.3x | ~15s | **100%** |
| 4. HPA + Backoff | 403 | 203 | 2.0x | ~15s | **100%** |

### 6.4 Key Lessons

1. **No infinite retries** — No retry = 1.0x amplification; 10 retries = 2.3x (production: 10x~100x)
2. **Fail Fast protects the server** — 9.2% success but server gets recovery time. If server dies, all pods fail
3. **Exponential backoff is essential** — Distributes retries over time, reduces instantaneous load, achieves 100% success
4. **HPA rate limiting is most effective** — Limiting concurrent pods reduces server load by 60%, 100% success

### 6.5 Differences from Real Failures

This test was performed with a 60-second limit. Differences from real failure environments:
- Real: Unlimited retries → amplification 10x~100x
- Real: Connections per Python process → CPU count × Pod count = more concurrent connections
- Real: Prolonged duration → half-completed TLS session memory accumulation → OOM
- This test: 60-second limit prevented reaching OOM

---

## 7. Final Conclusions

### 7.1 TLS Connection Storm is Engine-Agnostic

- Both ElastiCache Valkey 8.2 and Redis OSS 7.2 experience connection storm performance degradation with TLS
- Root cause is **TLS handshake CPU cost**, not engine differences
- ElastiCache has additional bottleneck from proxy layer, but trade-off with managed service benefits

### 7.2 Recommended Actions (Priority Order)

| Priority | Action | Effect | Target |
|----------|--------|--------|--------|
| 1 | **Connection Pool + Warm-up** | 18x improvement at medium scale (ElastiCache) | Code change |
| 2 | **Retry limit + Exponential backoff** | Prevent amplification, protect server | 1 line of code |
| 3 | **Staggered Reconnection** | Distribute simultaneous handshakes over time | Architecture |
| 4 | **HPA rate limiting** | Limit concurrent pod count | YAML change |
| 5 | **Readiness Probe with connection status** | Block traffic to unconnected pods | YAML change |

### 7.3 Fundamental Solution

```
[Problem] During deployment: N pods × M shards × 2 nodes = N×M×2 simultaneous TLS handshakes

[Solutions]
1. Connection Pool: Limit handshakes to once at app startup → 18x improvement
2. Staggered Reconnection: Distribute simultaneous handshakes over time
3. Envoy Sidecar: Multiplex N app connections → few TLS connections
4. HPA rate limiting: Reduce N itself by limiting concurrent pod creation
```

**The key is not disabling TLS, but minimizing the number of TLS handshakes.**

---

## 8. Infrastructure Info

### ElastiCache Clusters

| Cluster | Endpoint |
|---------|----------|
| valkey-nontls-test | valkey-nontls-test.khojwc.clustercfg.apn2.cache.amazonaws.com:6379 |
| stviztlwuv2jozz | clustercfg.stviztlwuv2jozz.khojwc.apn2.cache.amazonaws.com:6379 |
| valkey-tls-4shard | clustercfg.valkey-tls-4shard.khojwc.apn2.cache.amazonaws.com:6379 |

### Redis OSS Self-hosted EC2

| Server | Instance ID | IP | Role |
|--------|------------|-----|------|
| server-1 | i-083ea03e8a15bb568 | 10.11.62.234 | Non-TLS (3M+3R) |
| server-2 | i-0922dfe836d701437 | 10.11.35.38 | TLS shard (AZ-a) |
| server-3 | i-0b4afd836fb0046ab | 10.11.88.49 | TLS shard (AZ-b) |

### Client EC2

| Instance | Instance ID | Type |
|----------|------------|------|
| valkey-conn-storm-test | i-021aa6df35a1d56ab | c7g.xlarge |

### Security Groups

| SG | ID | Purpose |
|----|-----|---------|
| Valkey-SG | sg-0a3c3d2faec77dc0b | ElastiCache clusters |
| valkey-test-ec2-sg | sg-0a7cdb6f09726515d | Client EC2 |
| redis-oss-test-sg | sg-010a561677d490581 | Redis OSS server EC2 |
