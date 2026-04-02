<div align="center">

# Valkey TLS Connection Storm Benchmark

🇰🇷 [한국어](#한국어) | 🇺🇸 [English](#english)

</div>

---

# 한국어

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

## 테스트 결과

상세 결과는 아래 링크를 참조하세요:
- [01. 베이스라인: Non-TLS vs TLS](results/01-baseline.md)
- [02. 개선방안 비교 테스트](results/02-improvement-tests.md)
- [03. Cascading Failure 재현/완화](results/03-cascading-failure.md)

### 종합 비교

#### 소규모 동시접속 (10~50) — Wall Time

| 시나리오 | 10 conns | 50 conns | 평가 |
|----------|----------|----------|------|
| Non-TLS Storm (베이스라인) | 10ms | 16ms | 기준 |
| TLS Storm 2 shard (기존) | 129ms | 199ms | 12~13x 느림 |
| **preferred Non-TLS** | **22ms** | **26ms** | ✅ 기준 대비 2x 수준 |
| TLS Pool 2 shard | 130ms | 184ms | TLS Storm과 유사 |
| TLS Storm 4 shard | 354ms | 460ms | ❌ 가장 느림 |

#### 중규모 동시접속 (100) — 핵심 비교 포인트

| 시나리오 | Wall Time | 성공률 | 처리량 | 평가 |
|----------|-----------|--------|--------|------|
| Non-TLS Storm | 19ms | 100% | 5,263 c/s | 기준 |
| TLS Storm 2 shard | 5.3s | 100% | 19 c/s | 279x 느림 |
| **TLS Pool 2 shard** | **292ms** | **100%** | **342 c/s** | ✅ **18x 개선** |
| preferred Non-TLS | 5.1s | 100% | 20 c/s | TLS Storm과 유사 |
| TLS Storm 4 shard | 5.5s | 100% | 18 c/s | ❌ 개선 없음 |

#### 대규모 동시접속 (500+) — 성공률

| 시나리오 | 500 | 1,000 | 2,000 | 평가 |
|----------|-----|-------|-------|------|
| Non-TLS Storm | 94.6% | 64.0% | 23.2% | 기준 |
| TLS Storm 2 shard | 30.2% | 57.8% | 50.6% | |
| TLS Pool 2 shard | 36% | 51.6% | 36.1% | 약간 개선 |
| preferred Non-TLS | **1%** | **0.9%** | **0%** | ❌ 최악 |
| TLS Storm 4 shard | 32% | 60.7% | 26% | 개선 없음 |

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

**비권장: Shard 증가**
- Connection storm 시나리오에서는 역효과
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

## 프로젝트 구조

```
valkey-tls-test/
├── Cargo.toml
├── src/
│   ├── main.rs                      # 벤치마크 도구 (storm/pool 모드)
│   └── bin/cascade.rs               # Cascading failure 재현/완화 도구
├── infra/
│   ├── create-clusters.sh           # ElastiCache 클러스터 생성
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

---

# English

A benchmark project that quantitatively measures the performance impact of connection storms when transitioning from Non-TLS to TLS required on Amazon ElastiCache for Valkey 8.2, and validates the effectiveness of three mitigation strategies.

## Background

When transitioning a Valkey/Redis cluster from Non-TLS to TLS required, a TLS handshake is added to every client connection. While a single connection only adds tens to hundreds of milliseconds, during **connection storm** scenarios — where hundreds of connections are established simultaneously due to deployments or restarts — server-side TLS processing becomes a bottleneck, causing mass timeouts.

This project validates:
1. Quantitative impact of TLS transition on connection storm performance
2. Effect of `transit-encryption-mode: preferred` transition
3. Effect of Connection Pool + Warm-up
4. Effect of increasing shard count (horizontal scaling)

## Test Environment

| Item | Specification |
|------|---------------|
| ElastiCache Engine | Valkey 8.2.0 |
| Node Type | cache.r7g.large (2 vCPU, 13.07 GiB) |
| Cluster Mode | Enabled |
| Client EC2 | c7g.xlarge (ARM64, 4 vCPU, 8 GiB) |
| Client Location | Same VPC Private Subnet (ap-northeast-2) |
| Rust | 1.94.1 |
| redis crate | 0.27 (cluster, tls-rustls) |
| Timeout | 15 seconds |

### Test Cluster Configuration

| Cluster | Node Type | Shards | Config | TLS Mode |
|---------|----------|--------|--------|----------|
| valkey-nontls-test | r7g.large | 1 | 1M + 1R | Disabled |
| stviztlwuv2jozz | r7g.large | 2 | 2M + 2R | required → preferred |
| valkey-tls-4shard | r7g.large | 4 | 4M + 4R | required |

### Test Modes

| Mode | Behavior | Simulates |
|------|----------|-----------|
| `storm` | Creates new ClusterClient per concurrent connection → connect → PING | Connection storm during deployment/restart |
| `pool` | Single ClusterClient warmed up and shared, concurrent get_connection() | Connection pool usage pattern |

## Test Results

See detailed results:
- [01. Baseline: Non-TLS vs TLS](results/01-baseline.md)
- [02. Mitigation Strategy Comparison](results/02-improvement-tests.md)
- [03. Cascading Failure Reproduction/Mitigation](results/03-cascading-failure.md)

### Overall Comparison

#### Low Concurrency (10~50) — Wall Time

| Scenario | 10 conns | 50 conns | Assessment |
|----------|----------|----------|------------|
| Non-TLS Storm (baseline) | 10ms | 16ms | Baseline |
| TLS Storm 2 shard | 129ms | 199ms | 12~13x slower |
| **preferred Non-TLS** | **22ms** | **26ms** | ✅ ~2x of baseline |
| TLS Pool 2 shard | 130ms | 184ms | Similar to TLS Storm |
| TLS Storm 4 shard | 354ms | 460ms | ❌ Slowest |

#### Medium Concurrency (100) — Key Comparison

| Scenario | Wall Time | Success Rate | Throughput | Assessment |
|----------|-----------|-------------|------------|------------|
| Non-TLS Storm | 19ms | 100% | 5,263 c/s | Baseline |
| TLS Storm 2 shard | 5.3s | 100% | 19 c/s | 279x slower |
| **TLS Pool 2 shard** | **292ms** | **100%** | **342 c/s** | ✅ **18x improvement** |
| preferred Non-TLS | 5.1s | 100% | 20 c/s | Similar to TLS Storm |
| TLS Storm 4 shard | 5.5s | 100% | 18 c/s | ❌ No improvement |

#### High Concurrency (500+) — Success Rate

| Scenario | 500 | 1,000 | 2,000 | Assessment |
|----------|-----|-------|-------|------------|
| Non-TLS Storm | 94.6% | 64.0% | 23.2% | Baseline |
| TLS Storm 2 shard | 30.2% | 57.8% | 50.6% | |
| TLS Pool 2 shard | 36% | 51.6% | 36.1% | Slight improvement |
| preferred Non-TLS | **1%** | **0.9%** | **0%** | ❌ Worst |
| TLS Storm 4 shard | 32% | 60.7% | 26% | No improvement |

## Conclusions

### Mitigation Effectiveness Matrix

| Strategy | Low (10~50) | Medium (100) | High (500+) | Complexity | Overall |
|----------|-------------|-------------|-------------|------------|---------|
| ① preferred + Non-TLS | ✅ 6~8x faster | ⚠️ No effect | ❌ Severe degradation | Low (config change) | Limited |
| ② Connection Pool | ⚠️ Same | ✅ **18x improvement** | ⚠️ Slight improvement | Medium (code change) | **Top priority** |
| ④ More Shards | ❌ 2~3x worse | ❌ No effect | ⚠️ Similar | High (infra change) | Counterproductive |

### Recommendations

**Priority 1: Connection Pool + Warm-up** (Immediate)
- 5.3s → 292ms at 100 concurrent connections (18x improvement)
- Code-only change, no infrastructure modification needed
- Pre-create ClusterClient at app startup, warm up connections before accepting traffic

**Priority 2: Staggered Reconnection** (Architecture)
- Apply jitter + exponential backoff so pods don't reconnect simultaneously during deployments
- Include Valkey connection status in Kubernetes readiness probe
- Adjust maxSurge/maxUnavailable during rolling updates to limit concurrent reconnections

**Priority 3: preferred mode** (Small workloads only)
- Only effective for 10~50 concurrent connection workloads
- Degrades at 500+ concurrent connections — pre-testing required

**Not Recommended: More Shards**
- Counterproductive for connection storm scenarios
- Use only for data throughput distribution

### Fundamental Solution

The key is not disabling TLS, but **minimizing the number of TLS handshakes**:

```
[Problem] During deployment: N pods × M shards × 2 nodes = N×M×2 simultaneous TLS handshakes

[Solutions]
1. Connection Pool: Limit handshakes to once at app startup → 18x improvement
2. Staggered Reconnection: Distribute simultaneous handshakes over time
3. Envoy Sidecar: Multiplex N app connections → few TLS connections
```

## Build & Usage

```bash
# Build (Rust 1.70+ required)
cargo build --release

# Non-TLS connection storm
./target/release/valkey-conn-storm --endpoint <host>:<port> --mode storm

# TLS connection storm
./target/release/valkey-conn-storm --endpoint <host>:<port> --tls --mode storm

# TLS connection pool (warm-up)
./target/release/valkey-conn-storm --endpoint <host>:<port> --tls --mode pool

# Custom label and timeout
./target/release/valkey-conn-storm --endpoint <host>:<port> --tls --mode pool \
  --timeout 30 --label "TLS Pool r7g.2xlarge 4 shard"
```

### CLI Options

| Option | Default | Description |
|--------|---------|-------------|
| `--endpoint` | (required) | Valkey cluster configuration endpoint (host:port) |
| `--tls` | false | Use TLS connection |
| `--mode` | storm | `storm` (new client) or `pool` (shared client) |
| `--timeout` | 15 | Connection timeout (seconds) |
| `--label` | (auto) | Output label |

## Cascading Failure Reproduction & Mitigation

Reproduces real failure scenarios (HPA scale-out → TLS connection storm → infinite retry → memory explosion) and validates mitigation effectiveness.

```bash
# Reproduce failure: 500 pods, 10 retries, no backoff
./target/release/cascade --endpoint <host>:<port> --tls --pods 500 --retries 10 --backoff none

# Mitigate: exponential backoff + retry limit
./target/release/cascade --endpoint <host>:<port> --tls --pods 500 --retries 3 --backoff exponential

# Mitigate: HPA rate limit + backoff
./target/release/cascade --endpoint <host>:<port> --tls --pods 200 --retries 3 --backoff exponential
```

## Infrastructure Setup

```bash
# Create clusters
export SUBNET_GROUP="your-subnet-group"
export SECURITY_GROUP="sg-xxxxxxxxx"
./infra/create-clusters.sh

# Run all tests
./scripts/run-tests.sh <nontls-ep>:6379 <tls-2shard-ep>:6379 <tls-4shard-ep>:6379

# Cleanup
./infra/cleanup-clusters.sh
```

## Project Structure

```
valkey-tls-test/
├── Cargo.toml
├── src/
│   ├── main.rs                      # Benchmark tool (storm/pool modes)
│   └── bin/cascade.rs               # Cascading failure reproduction/mitigation tool
├── infra/
│   ├── create-clusters.sh           # ElastiCache cluster creation
│   └── cleanup-clusters.sh          # Cluster cleanup
├── scripts/
│   └── run-tests.sh                 # Full test automation
├── results/
│   ├── 01-baseline.md               # Non-TLS vs TLS baseline results
│   ├── 02-improvement-tests.md      # Mitigation strategy comparison results
│   └── 03-cascading-failure.md      # Cascading failure reproduction/mitigation results
└── userdata.sh                      # EC2 test instance user-data
```

## License

MIT
