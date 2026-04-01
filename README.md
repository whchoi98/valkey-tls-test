# Valkey TLS Connection Storm Benchmark

Amazon ElastiCache for Valkey 8.2에서 TLS 활성화 시 connection storm 성능 영향을 측정하고, 개선방안의 실효성을 검증하는 벤치마크 도구입니다.

## 배경

Valkey/Redis를 Non-TLS에서 TLS required로 전환하면 TLS 핸드셰이크 오버헤드로 인해 동시 연결 수립 성능이 크게 저하됩니다. 이 프로젝트는 그 영향을 정량적으로 측정하고, 세 가지 개선방안을 실제 테스트합니다.

## 테스트 결과 요약

| 시나리오 | 100 동시접속 | 500 동시접속 |
|----------|-------------|-------------|
| Non-TLS Storm (베이스라인) | 19ms, 100% | 10s, 94.6% |
| TLS Storm 2 shard (기존) | 5.3s, 100% | 15.3s, 30.2% |
| **TLS Pool 2 shard (개선)** | **292ms, 100%** | 15.3s, 36% |
| preferred Non-TLS | 5.1s, 100% | 15s, 1% |
| TLS Storm 4 shard | 5.5s, 100% | 15.4s, 32% |

### 핵심 발견

- **Connection Pool + Warm-up**: 100 동시접속에서 5.3s → 292ms (**18배 개선**), 가장 효과적
- **preferred 모드**: 소규모(10~50)에서 6~8배 빠르나, 500+에서 급격히 악화
- **Shard 증가**: ClusterClient가 모든 shard에 연결하므로 오히려 역효과

## 테스트 모드

| 모드 | 설명 |
|------|------|
| `storm` | 매 연결마다 새 ClusterClient 생성 (connection storm 시뮬레이션) |
| `pool` | 단일 ClusterClient를 warm-up 후 공유 (connection pool 시뮬레이션) |

## 빌드

```bash
# Rust 1.70+ 필요
cargo build --release
```

## 사용법

```bash
# Non-TLS connection storm
./target/release/valkey-conn-storm \
  --endpoint <host>:<port> \
  --mode storm

# TLS connection storm
./target/release/valkey-conn-storm \
  --endpoint <host>:<port> \
  --tls \
  --mode storm

# TLS connection pool (warm-up)
./target/release/valkey-conn-storm \
  --endpoint <host>:<port> \
  --tls \
  --mode pool

# 커스텀 라벨 및 타임아웃
./target/release/valkey-conn-storm \
  --endpoint <host>:<port> \
  --tls \
  --mode pool \
  --timeout 30 \
  --label "TLS Pool r7g.2xlarge 4 shard"
```

### 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `--endpoint` | (필수) | Valkey cluster configuration endpoint (host:port) |
| `--tls` | false | TLS 연결 사용 |
| `--mode` | storm | `storm` (새 클라이언트) 또는 `pool` (공유 클라이언트) |
| `--timeout` | 15 | 연결 타임아웃 (초) |
| `--label` | (자동) | 출력 라벨 |

## 테스트 인프라 구성

### 클러스터 생성

```bash
export SUBNET_GROUP="your-subnet-group"
export SECURITY_GROUP="sg-xxxxxxxxx"
./infra/create-clusters.sh
```

### 전체 테스트 실행

```bash
./scripts/run-tests.sh \
  <nontls-endpoint>:6379 \
  <tls-2shard-endpoint>:6379 \
  <tls-4shard-endpoint>:6379
```

### 정리

```bash
./infra/cleanup-clusters.sh
```

## 테스트 환경

| 항목 | 사양 |
|------|------|
| ElastiCache Engine | Valkey 8.2.0 |
| 노드 타입 | cache.r7g.large |
| Cluster Mode | Enabled |
| 클라이언트 EC2 | c7g.xlarge (ARM64, 4 vCPU) |
| 클라이언트 위치 | 동일 VPC Private Subnet |
| Rust | 1.94.x |
| redis crate | 0.27 (cluster, tls-rustls) |

## 프로젝트 구조

```
valkey-tls-test/
├── Cargo.toml              # Rust 프로젝트 설정
├── src/
│   └── main.rs             # 벤치마크 도구 소스
├── infra/
│   ├── create-clusters.sh  # ElastiCache 클러스터 생성
│   └── cleanup-clusters.sh # 클러스터 정리
├── scripts/
│   └── run-tests.sh        # 전체 테스트 실행
├── results/
│   ├── 01-baseline.md      # 베이스라인 테스트 결과
│   └── 02-improvement-tests.md  # 개선방안 테스트 결과
└── userdata.sh             # EC2 테스트 인스턴스 user-data
```

## 권장사항

1. **Connection Pool + Warm-up** — 코드 변경만으로 즉시 적용, 효과 최대
2. **Staggered Reconnection** — 배포/재시작 시 connection storm 방지 (지터 + 백오프)
3. **preferred 모드** — 소규모 워크로드에 한정, 보안 요건 확인 필요
4. **Shard 증가는 connection storm에 비효과적** — 데이터 분산에만 유효

## 라이선스

MIT
