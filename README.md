# Valkey TLS Connection Storm Benchmark

Amazon ElastiCache for Valkey 8.2에서 Non-TLS → TLS required 전환 시 connection storm 성능 영향을 정량적으로 측정하고, 세 가지 개선방안의 실효성을 검증하는 벤치마크 프로젝트입니다.

## 배경

Valkey/Redis 클러스터를 Non-TLS에서 TLS required로 전환하면, 모든 클라이언트 연결에 TLS 핸드셰이크가 추가됩니다. 단일 연결에서는 수십~수백 ms 수준이지만, 배포/재시작 등으로 수백 개의 연결이 동시에 수립되는 **connection storm** 상황에서는 서버 측 TLS 처리가 병목이 되어 대량 타임아웃이 발생합니다.

이 프로젝트는 다음을 검증합니다:
1. TLS 전환이 connection storm 성능에 미치는 정량적 영향
2. `transit-encryption-mode: preferred` 전환의 효과
3. Connection Pool + Warm-up의 효과
4. Shard 수 증가(수평 확장)의 효과

## 테스트 환경

| 항목 | 사양 |
|------|------|
| ElastiCache Engine | Valkey 8.2.0 |
| 노드 타입 | cache.r7g.large (2 vCPU, 13.07 GiB) |
| Cluster Mode | Enabled |
| 클라이언트 EC2 | c7g.xlarge (ARM64, 4 vCPU, 8 GiB) |
| 클라이언트 위치 | 동일 VPC Private Subnet (ap-northeast-2) |
| Rust | 1.94.1 |
| redis crate | 0.27 (cluster, tls-rustls) |
| 타임아웃 | 15초 |

### 테스트 클러스터 구성

| 클러스터 | 노드 타입 | Shard | 구성 | TLS 모드 |
|----------|----------|-------|------|----------|
| valkey-nontls-test | r7g.large | 1 | 1M + 1R | Disabled |
| stviztlwuv2jozz | r7g.large | 2 | 2M + 2R | required → preferred |
| valkey-tls-4shard | r7g.large | 4 | 4M + 4R | required |

### 테스트 모드

| 모드 | 동작 | 시뮬레이션 대상 |
|------|------|----------------|
| `storm` | 매 동시접속마다 새 ClusterClient 생성 → 연결 → PING | 배포/재시작 시 connection storm |
| `pool` | 단일 ClusterClient를 warm-up 후 공유, 동시에 get_connection() | Connection pool 사용 패턴 |

---

## 테스트 결과

### 베이스라인: Non-TLS vs TLS Connection Storm

> 가장 기본적인 비교. 동일 조건에서 TLS 유무에 따른 성능 차이 측정.

**Non-TLS Storm (r7g.large, 1 shard)**

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 10ms | 10/10 | 100% | 1,000 c/s |
| 50 | 16ms | 50/50 | 100% | 3,125 c/s |
| 100 | 19ms | 100/100 | 100% | 5,263 c/s |
| 200 | 5.0s | 200/200 | 100% | 40 c/s |
| 500 | 10.0s | 473/500 | 94.6% | 47 c/s |
| 1,000 | 15.0s | 640/1000 | 64.0% | 43 c/s |
| 2,000 | 15.0s | 464/2000 | 23.2% | 31 c/s |

**TLS Storm (r7g.large, 2 shard, required)**

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 129ms | 10/10 | 100% | 78 c/s |
| 50 | 199ms | 50/50 | 100% | 251 c/s |
| 100 | 5.3s | 100/100 | 100% | 19 c/s |
| 200 | 5.4s | 200/200 | 100% | 37 c/s |
| 500 | 15.3s | 151/500 | 30.2% | 10 c/s |
| 1,000 | 15.3s | 578/1000 | 57.8% | 38 c/s |
| 2,000 | 15.1s | 1012/2000 | 50.6% | 67 c/s |

**베이스라인 인사이트:**

- 소규모(10~50 conns): TLS가 Non-TLS 대비 **12~13배 느림** (10ms vs 129ms). 이는 순수 TLS 핸드셰이크 오버헤드
- 100 conns: Non-TLS는 19ms에 완료되지만, TLS는 **5.3초** 소요. 서버 측 TLS 핸드셰이크 처리가 직렬화되면서 병목 발생
- 200 conns: 양쪽 모두 5초대로 수렴. Non-TLS도 서버 측 연결 수락 한계에 도달
- 500+ conns: TLS 성공률 30%로 급락. Non-TLS도 94.6%로 하락하지만 TLS가 3배 더 나쁨
- 피크 처리량: Non-TLS ~5,263 c/s vs TLS ~251 c/s — **약 21배 차이**

---

### 개선방안 1: transit-encryption-mode preferred

> TLS 클러스터를 `required` → `preferred`로 전환하면 동일 포트(6379)에서 TLS/Non-TLS 양쪽 연결을 모두 수락합니다. 성능이 중요한 내부 트래픽은 Non-TLS로 연결하여 TLS 오버헤드를 회피하는 전략.

**preferred 모드 — Non-TLS 연결 (storm)**

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 22ms | 10/10 | 100% | 455 c/s |
| 50 | 26ms | 50/50 | 100% | 1,923 c/s |
| 100 | 5.1s | 100/100 | 100% | 20 c/s |
| 200 | 10.1s | 180/200 | 90% | 18 c/s |
| 500 | 15.0s | 5/500 | **1%** | 0 c/s |
| 1,000 | 15.0s | 9/1000 | **0.9%** | 1 c/s |
| 2,000 | 15.0s | 0/2000 | **0%** | 0 c/s |

**preferred 모드 — TLS 연결 (storm, 동일 클러스터)**

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 137ms | 10/10 | 100% | 73 c/s |
| 50 | 218ms | 50/50 | 100% | 229 c/s |
| 100 | 5.3s | 100/100 | 100% | 19 c/s |
| 200 | 5.4s | 200/200 | 100% | 37 c/s |
| 500 | 15.2s | 69/500 | 13.8% | 5 c/s |
| 1,000 | 15.0s | 541/1000 | 54.1% | 36 c/s |
| 2,000 | 15.0s | 1007/2000 | 50.4% | 67 c/s |

**개선방안 1 인사이트:**

- 소규모(10~50 conns): Non-TLS 연결이 **22ms / 26ms**로 순수 Non-TLS 클러스터(10ms / 16ms)에 근접. TLS 대비 **6~8배 빠름**
- 100 conns: 5.1초로 TLS와 유사. preferred 모드에서도 서버 측 연결 수락 처리가 병목
- **500+ conns에서 치명적 문제 발견**: Non-TLS 연결 성공률이 **1% → 0.9% → 0%**로 급락. 순수 Non-TLS 클러스터(94.6%)와 극명한 차이
- **원인 분석**: preferred 모드에서 서버는 새 연결마다 TLS 핸드셰이크 시도 여부를 판별해야 함. 이 판별 과정에서 Non-TLS 연결이 TLS 연결보다 우선순위가 낮거나, 프로토콜 감지 타임아웃이 발생하는 것으로 추정
- **결론**: preferred 모드는 소규모(10~50) 워크로드에서만 유효. 대규모 connection storm에서는 **순수 Non-TLS 클러스터보다 훨씬 나쁜 결과**를 보이므로 주의 필요

---

### 개선방안 2: Connection Pool + Warm-up

> 매번 새 ClusterClient를 생성하는 대신, 단일 ClusterClient를 미리 생성(warm-up)하고 모든 동시 요청이 공유. TLS 핸드셰이크는 초기 warm-up 시에만 발생하고, 이후 요청은 기존 연결을 재사용.

**TLS Pool (r7g.large, 2 shard, required)**

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 130ms | 10/10 | 100% | 77 c/s |
| 50 | 184ms | 50/50 | 100% | 272 c/s |
| 100 | **292ms** | 100/100 | 100% | **342 c/s** |
| 200 | 10.4s | 200/200 | 100% | 19 c/s |
| 500 | 15.3s | 180/500 | 36% | 12 c/s |
| 1,000 | 15.3s | 516/1000 | 51.6% | 34 c/s |
| 2,000 | 15.1s | 722/2000 | 36.1% | 48 c/s |

**Non-TLS Pool (r7g.large, 1 shard) — 참고용**

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 12ms | 10/10 | 100% | 833 c/s |
| 50 | 15ms | 50/50 | 100% | 3,333 c/s |
| 100 | 5.0s | 100/100 | 100% | 20 c/s |
| 200 | 10.0s | 170/200 | 85% | 17 c/s |
| 500 | 15.0s | 343/500 | 68.6% | 23 c/s |
| 1,000 | 15.0s | 809/1000 | 80.9% | 54 c/s |
| 2,000 | 15.0s | 1622/2000 | 81.1% | 108 c/s |

**Pool vs Storm 비교 (TLS required, 2 shard)**

| 동시접속 | Storm Wall Time | Pool Wall Time | 개선 배율 |
|----------|----------------|----------------|-----------|
| 10 | 129ms | 130ms | 1.0x (동일) |
| 50 | 199ms | 184ms | 1.1x |
| **100** | **5.3s** | **292ms** | **18.2x** |
| 200 | 5.4s | 10.4s | 0.5x (악화) |
| 500 | 15.3s (30.2%) | 15.3s (36%) | +5.8%p |

**개선방안 2 인사이트:**

- **100 동시접속에서 극적 개선**: 5.3s → 292ms (**18배 빠름**). 이 테스트에서 가장 큰 개선 효과
- 개선 원리: Storm 모드에서는 100개의 독립 ClusterClient가 각각 모든 shard에 TLS 핸드셰이크를 수행 (100 × 2 shard × 2 노드 = 최대 400회 핸드셰이크). Pool 모드에서는 warm-up 시 1회만 핸드셰이크하고, 이후 100개 요청은 기존 연결을 재사용
- 10~50 conns: Storm과 Pool의 차이가 거의 없음. 소규모에서는 핸드셰이크 횟수 자체가 적어 병목이 되지 않음
- 200 conns: Pool이 오히려 느림 (10.4s vs 5.4s). 단일 ClusterClient의 내부 connection pool이 200개 동시 요청을 처리하면서 내부 lock contention 발생 추정
- 500+ conns: 양쪽 모두 서버 측 한계로 타임아웃. Pool이 약간 나은 성공률 (36% vs 30.2%)
- **결론**: Connection Pool은 **중규모(100~200) 동시접속에서 가장 효과적**. 대규모에서는 서버 측 한계가 지배적

---

### 개선방안 4: Shard 수 증가 (2 → 4 shard)

> 각 shard가 독립적으로 TLS 핸드셰이크를 처리하므로, shard를 늘리면 TLS 처리 용량이 수평 확장될 것이라는 가설 검증.

**TLS Storm (r7g.large, 4 shard, required)**

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 354ms | 10/10 | 100% | 28 c/s |
| 50 | 460ms | 50/50 | 100% | 109 c/s |
| 100 | 5.5s | 100/100 | 100% | 18 c/s |
| 200 | 15.1s | 76/200 | **38%** | 5 c/s |
| 500 | 15.4s | 160/500 | 32% | 10 c/s |
| 1,000 | 15.2s | 607/1000 | 60.7% | 40 c/s |
| 2,000 | 15.0s | 519/2000 | 26% | 35 c/s |

**TLS Pool (r7g.large, 4 shard, required)**

| 동시접속 | Wall Time | 성공 | 성공률 | 처리량 |
|----------|-----------|------|--------|--------|
| 10 | 304ms | 10/10 | 100% | 33 c/s |
| 50 | 425ms | 50/50 | 100% | 118 c/s |
| 100 | 5.5s | 100/100 | 100% | 18 c/s |
| 200 | 10.7s | 200/200 | 100% | 19 c/s |
| 500 | 15.2s | 19/500 | **3.8%** | 1 c/s |
| 1,000 | 15.2s | 366/1000 | 36.6% | 24 c/s |
| 2,000 | 15.1s | 231/2000 | 11.6% | 15 c/s |

**2 shard vs 4 shard 비교 (TLS Storm)**

| 동시접속 | 2 shard | 4 shard | 변화 |
|----------|---------|---------|------|
| 10 | 129ms | 354ms | **2.7x 느려짐** |
| 50 | 199ms | 460ms | **2.3x 느려짐** |
| 100 | 5.3s, 100% | 5.5s, 100% | 유사 |
| 200 | 5.4s, 100% | 15.1s, **38%** | **대폭 악화** |
| 500 | 30.2% | 32% | 유사 |

**개선방안 4 인사이트:**

- **가설 기각**: Shard 증가가 connection storm 성능을 개선하지 않음. 오히려 악화
- 소규모(10~50 conns): 4 shard가 2 shard보다 **2.3~2.7배 느림**. ClusterClient가 4개 shard × 2 노드(master+replica) = 8개 노드 모두에 TLS 연결을 맺어야 하므로 핸드셰이크 총 횟수가 2배 증가
- 200 conns: 2 shard는 100% 성공하지만, 4 shard는 **38%만 성공**. 클라이언트당 연결 수가 4배(8노드)이므로 서버 측 TLS 처리 한계에 더 빨리 도달
- 4 shard Pool 500 conns: **3.8% 성공**으로 최악의 결과. Pool 모드에서도 warm-up 시 8개 노드에 연결해야 하므로 초기 비용이 높음
- **핵심 원인**: Cluster Mode에서 ClusterClient는 **모든 shard의 모든 노드에 연결**을 시도. shard 증가 = 노드 수 증가 = TLS 핸드셰이크 횟수 증가. 데이터 처리량 분산에는 효과적이지만, 연결 수립 성능에는 역효과

---

## 종합 비교

### 소규모 동시접속 (10~50) — Wall Time

| 시나리오 | 10 conns | 50 conns | 평가 |
|----------|----------|----------|------|
| Non-TLS Storm (베이스라인) | 10ms | 16ms | 기준 |
| TLS Storm 2 shard (기존) | 129ms | 199ms | 12~13x 느림 |
| **preferred Non-TLS** | **22ms** | **26ms** | ✅ 기준 대비 2x 수준 |
| TLS Pool 2 shard | 130ms | 184ms | TLS Storm과 유사 |
| TLS Storm 4 shard | 354ms | 460ms | ❌ 가장 느림 |

### 중규모 동시접속 (100) — 핵심 비교 포인트

| 시나리오 | Wall Time | 성공률 | 처리량 | 평가 |
|----------|-----------|--------|--------|------|
| Non-TLS Storm | 19ms | 100% | 5,263 c/s | 기준 |
| TLS Storm 2 shard | 5.3s | 100% | 19 c/s | 279x 느림 |
| **TLS Pool 2 shard** | **292ms** | **100%** | **342 c/s** | ✅ **18x 개선** |
| preferred Non-TLS | 5.1s | 100% | 20 c/s | TLS Storm과 유사 |
| TLS Storm 4 shard | 5.5s | 100% | 18 c/s | ❌ 개선 없음 |

### 대규모 동시접속 (500+) — 성공률

| 시나리오 | 500 | 1,000 | 2,000 | 평가 |
|----------|-----|-------|-------|------|
| Non-TLS Storm | 94.6% | 64.0% | 23.2% | 기준 |
| TLS Storm 2 shard | 30.2% | 57.8% | 50.6% | |
| TLS Pool 2 shard | 36% | 51.6% | 36.1% | 약간 개선 |
| preferred Non-TLS | **1%** | **0.9%** | **0%** | ❌ 최악 |
| TLS Storm 4 shard | 32% | 60.7% | 26% | 개선 없음 |

---

## 결론

### 개선방안 효과 매트릭스

| 방안 | 소규모 (10~50) | 중규모 (100) | 대규모 (500+) | 구현 난이도 | 종합 |
|------|---------------|-------------|--------------|-----------|------|
| ① preferred + Non-TLS | ✅ 6~8x 빠름 | ⚠️ 효과 없음 | ❌ 급격히 악화 | 낮음 (설정 변경) | 제한적 |
| ② Connection Pool | ⚠️ 동일 | ✅ **18x 개선** | ⚠️ 약간 개선 | 중간 (코드 변경) | **최우선** |
| ④ Shard 증가 | ❌ 2~3x 악화 | ❌ 효과 없음 | ⚠️ 유사 | 높음 (인프라 변경) | 역효과 |

### 권장사항

**1순위: Connection Pool + Warm-up** (즉시 적용)
- 100 동시접속에서 5.3s → 292ms (18배 개선)
- 코드 변경만으로 적용 가능, 인프라 변경 불필요
- 애플리케이션 시작 시 ClusterClient를 미리 생성하고 warm-up 연결 수립 후 트래픽 수신

**2순위: Staggered Reconnection** (아키텍처 개선)
- 배포/재시작 시 모든 Pod가 동시에 연결하지 않도록 지터(jitter) + 지수 백오프 적용
- Kubernetes readiness probe에 Valkey 연결 상태 포함
- Rolling update 시 maxSurge/maxUnavailable 조정으로 동시 재연결 수 제한

**3순위: preferred 모드** (소규모 워크로드에 한정)
- 10~50 동시접속 수준의 워크로드에서만 유효
- 500+ 동시접속에서는 오히려 악화되므로 반드시 사전 테스트 필요
- 보안 요건이 "TLS 지원" 수준이면 고려 가능

**비권장: Shard 증가**
- Connection storm 시나리오에서는 역효과
- ClusterClient가 모든 shard에 연결하므로 shard 수 × 핸드셰이크 횟수 증가
- 데이터 처리량 분산 목적으로만 사용

### 근본적 해결 방향

TLS 자체를 끄는 것이 아니라, **TLS 핸드셰이크 횟수를 최소화**하는 것이 핵심:

```
[문제] 배포 시 N개 Pod × M개 shard × 2 노드 = N×M×2 TLS 핸드셰이크 동시 발생

[해결]
1. Connection Pool: 핸드셰이크를 앱 시작 시 1회로 제한
2. Staggered Reconnection: 동시 핸드셰이크 수를 시간 분산
3. Envoy Sidecar: N개 앱 연결 → 소수 TLS 연결로 다중화
```

---

## 빌드 및 사용법

```bash
# 빌드 (Rust 1.70+ 필요)
cargo build --release

# Non-TLS connection storm
./target/release/valkey-conn-storm --endpoint <host>:<port> --mode storm

# TLS connection storm
./target/release/valkey-conn-storm --endpoint <host>:<port> --tls --mode storm

# TLS connection pool (warm-up)
./target/release/valkey-conn-storm --endpoint <host>:<port> --tls --mode pool

# 커스텀 라벨 및 타임아웃
./target/release/valkey-conn-storm --endpoint <host>:<port> --tls --mode pool \
  --timeout 30 --label "TLS Pool r7g.2xlarge 4 shard"
```

### CLI 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `--endpoint` | (필수) | Valkey cluster configuration endpoint (host:port) |
| `--tls` | false | TLS 연결 사용 |
| `--mode` | storm | `storm` (새 클라이언트) 또는 `pool` (공유 클라이언트) |
| `--timeout` | 15 | 연결 타임아웃 (초) |
| `--label` | (자동) | 출력 라벨 |

## 인프라 구성

```bash
# 클러스터 생성
export SUBNET_GROUP="your-subnet-group"
export SECURITY_GROUP="sg-xxxxxxxxx"
./infra/create-clusters.sh

# 전체 테스트 실행
./scripts/run-tests.sh <nontls-ep>:6379 <tls-2shard-ep>:6379 <tls-4shard-ep>:6379

# 정리
./infra/cleanup-clusters.sh
```

## Cascading Failure 재현 및 완화 테스트

실제 장애 시나리오(HPA 스케일아웃 → TLS connection storm → 무한 재시도 → 메모리 폭주)를 재현하고, 완화 방안의 효과를 검증합니다.

```bash
# 장애 재현: 500 pods, 10회 재시도, 백오프 없음
./target/release/cascade --endpoint <host>:<port> --tls --pods 500 --retries 10 --backoff none

# 완화: 지수 백오프 + 재시도 제한
./target/release/cascade --endpoint <host>:<port> --tls --pods 500 --retries 3 --backoff exponential

# 완화: HPA 속도 제한 + 백오프
./target/release/cascade --endpoint <host>:<port> --tls --pods 200 --retries 3 --backoff exponential
```

### 결과 요약

| 시나리오 | 총 시도 | 성공률 | 증폭 배율 | 서버 부하 |
|----------|---------|--------|----------|----------|
| 장애 재현 (500 pods, 10 retries, no backoff) | 1,170 | 100% | 2.3x | ❌ 최대 |
| Fail fast (500 pods, no retry) | 500 | 9.2% | 1.0x | ⚠️ 1회성 |
| 백오프 (500 pods, 3 retries, exp backoff) | 1,150 | 100% | 2.3x | ⚠️ 시간 분산 |
| **HPA 제한 + 백오프 (200 pods, 3 retries)** | **403** | **100%** | **2.0x** | ✅ **65% 감소** |

상세 결과: [results/03-cascading-failure.md](results/03-cascading-failure.md)

## 프로젝트 구조

```
valkey-tls-test/
├── Cargo.toml                       # Rust 프로젝트 설정
├── src/
│   ├── main.rs                      # 벤치마크 도구 (storm/pool 모드)
│   └── bin/cascade.rs               # Cascading failure 재현/완화 도구
├── infra/
│   ├── create-clusters.sh           # ElastiCache 클러스터 생성 (Non-TLS, TLS 2/4 shard)
│   └── cleanup-clusters.sh          # 클러스터 정리
├── scripts/
│   └── run-tests.sh                 # 전체 테스트 자동 실행
├── results/
│   ├── 01-baseline.md               # Non-TLS vs TLS 베이스라인 결과
│   ├── 02-improvement-tests.md      # 개선방안 비교 테스트 결과
│   └── 03-cascading-failure.md      # Cascading failure 재현/완화 결과
└── userdata.sh                      # EC2 테스트 인스턴스 user-data
```

## 라이선스

MIT
