# Redis OSS 7.2 Self-hosted TLS Connection Storm 테스트 결과

## 테스트 환경

| 항목 | 사양 |
|------|------|
| Redis 버전 | Redis OSS 7.2.7 (BUILD_TLS=yes) |
| 서버 인스턴스 | r7g.large (2 vCPU, 16 GiB) × 3대 |
| 클라이언트 인스턴스 | c7g.xlarge (4 vCPU, 8 GiB) |
| 네트워크 | 동일 VPC Private Subnet (ap-northeast-2) |
| TLS | Self-signed CA, tls-auth-clients no |
| redis crate | 0.27 (cluster, tls-rustls, tls-rustls-insecure) |
| 타임아웃 | 15초 |

### 클러스터 구성

| 클러스터 | 노드 | 호스트 | TLS |
|----------|------|--------|-----|
| Non-TLS | 3M + 3R | 1대 (server-1) | Disabled |
| TLS | 3M + 3R | 2대 (server-2, server-3) | Enabled |

## 테스트 결과

### Non-TLS Storm

| Conns | Wall Time | Success | Rate |
|-------|-----------|---------|------|
| 10 | 16ms | 10/10 (100%) | 625 c/s |
| 50 | 89ms | 50/50 (100%) | 562 c/s |
| 100 | 60ms | 100/100 (100%) | 1,667 c/s |
| 200 | 101ms | 200/200 (100%) | 1,980 c/s |
| 500 | 153ms | 500/500 (100%) | 3,268 c/s |
| 1,000 | 229ms | 1,000/1,000 (100%) | 4,367 c/s |
| 2,000 | 415ms | 2,000/2,000 (100%) | 4,819 c/s |

### TLS Storm

| Conns | Wall Time | Success | Rate |
|-------|-----------|---------|------|
| 10 | 113ms | 10/10 (100%) | 88 c/s |
| 50 | 708ms | 50/50 (100%) | 71 c/s |
| 100 | 919ms | 100/100 (100%) | 109 c/s |
| 200 | 2.0s | 200/200 (100%) | 98 c/s |
| 500 | 4.8s | 500/500 (100%) | 105 c/s |
| 1,000 | 8.7s | 1,000/1,000 (100%) | 115 c/s |
| 2,000 | 15.1s | 1,540/2,000 (77%) | 102 c/s |

### TLS Pool

| Conns | Wall Time | Success | Rate |
|-------|-----------|---------|------|
| 10 | 111ms | 10/10 (100%) | 90 c/s |
| 50 | 452ms | 50/50 (100%) | 111 c/s |
| 100 | 916ms | 100/100 (100%) | 109 c/s |
| 200 | 1.8s | 200/200 (100%) | 110 c/s |
| 500 | 4.4s | 500/500 (100%) | 114 c/s |
| 1,000 | 8.7s | 1,000/1,000 (100%) | 114 c/s |
| 2,000 | 15.1s | 1,540/2,000 (77%) | 102 c/s |

## ElastiCache Valkey 8.2 vs Redis OSS 7.2 비교

### 100 동시접속 기준 (핵심 비교)

| 시나리오 | ElastiCache Valkey | Redis OSS | 비교 |
|----------|-------------------|-----------|------|
| Non-TLS Storm | 19ms, 100%, 5,263 c/s | 60ms, 100%, 1,667 c/s | Valkey 3x 빠름 |
| TLS Storm | 5.3s, 100%, 19 c/s | 919ms, 100%, 109 c/s | **Redis OSS 5.8x 빠름** |
| TLS Pool | 292ms, 100%, 342 c/s | 916ms, 100%, 109 c/s | Valkey Pool 3x 빠름 |

### 500 동시접속 기준

| 시나리오 | ElastiCache Valkey | Redis OSS | 비교 |
|----------|-------------------|-----------|------|
| Non-TLS Storm | 성공률 94.6% | 100%, 3,268 c/s | Redis OSS 우수 |
| TLS Storm | 성공률 30.2% | 100%, 105 c/s | **Redis OSS 성공률 우수** |
| TLS Pool | 성공률 36% | 100%, 114 c/s | **Redis OSS 성공률 우수** |

### 2,000 동시접속 기준

| 시나리오 | ElastiCache Valkey | Redis OSS |
|----------|-------------------|-----------|
| Non-TLS Storm | 성공률 23.2% | 100% |
| TLS Storm | 성공률 50.6% | 77% |
| TLS Pool | 성공률 36.1% | 77% |

## 분석

### 1. TLS 오버헤드는 Redis OSS에서도 동일하게 발생

- Non-TLS → TLS 전환 시 **7~15x 성능 저하** (Wall Time 기준)
- 100 동시접속: 60ms → 919ms (15x)
- 이는 ElastiCache Valkey의 19ms → 5.3s (279x)보다는 양호하지만, TLS 핸드셰이크 병목은 동일

### 2. Self-hosted Redis OSS가 TLS Storm에서 더 나은 이유

- ElastiCache는 프록시 레이어(configuration endpoint)를 거치므로 추가 레이턴시 발생
- Self-hosted는 직접 노드 접속으로 프록시 오버헤드 없음
- 하지만 Self-hosted는 운영 부담(HA, 패치, 모니터링)이 큼

### 3. Connection Pool 효과가 Self-hosted에서는 미미

- ElastiCache: Storm 5.3s → Pool 292ms (18x 개선)
- Redis OSS: Storm 919ms → Pool 916ms (**개선 없음**)
- 이유: Self-hosted 클러스터에서는 매 get_connection()마다 새 TLS 핸드셰이크가 발생하는 구조가 동일

### 4. 결론

**TLS connection storm 문제는 Redis OSS에서도 동일하게 발생합니다.**
- 엔진(Valkey vs Redis)의 차이가 아닌, TLS 핸드셰이크 자체의 CPU 비용이 원인
- ElastiCache의 프록시 레이어가 추가 병목을 만들지만, 근본 원인은 동일
- 개선방안(Connection Pool, Staggered Reconnection)은 양쪽 모두에 적용 필요

## 인프라 정보

| 리소스 | ID | IP |
|--------|----|----|
| server-1 (Non-TLS) | i-083ea03e8a15bb568 | 10.11.62.234 |
| server-2 (TLS shard) | i-0922dfe836d701437 | 10.11.35.38 |
| server-3 (TLS shard) | i-0b4afd836fb0046ab | 10.11.88.49 |
| Security Group | sg-010a561677d490581 | - |
