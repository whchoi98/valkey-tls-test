# Valkey/Redis TLS Connection Storm — 지수 백오프 재시도 구현 가이드
# Valkey/Redis TLS Connection Storm — Exponential Backoff Retry Implementation Guide
#
# 이 문서는 TLS connection storm 벤치마크 결과(results/03-cascading-failure.md)에서
# 검증된 지수 백오프 재시도 패턴의 언어별 구현 예제입니다.
#
# This document provides language-specific implementation examples of the
# exponential backoff retry pattern validated in the TLS connection storm
# benchmark (results/03-cascading-failure.md).
#
# 벤치마크 검증 결과 (Benchmark Validation Results):
#   - 500 pods, 3 retries, exponential backoff → 100% 성공, 증폭 2.3x
#   - 500 pods, 10 retries, no backoff → 100% 성공이지만 670회 불필요한 실패 (서버 부하)
#   - 500 pods, no retry → 9.2% 성공 (서버 보호되지만 가용성 저하)
#
# 핵심 파라미터 (Key Parameters):
#   retries:          3       — 무한 재시도 방지, 증폭 2.3x 이내 유지
#   base backoff:     500ms   — 첫 재시도까지 서버 회복 시간 확보
#   cap:              16s     — 백오프 상한 (500ms → 1s → 2s → ... → 최대 16s)
#   jitter:           0~1s    — Pod 간 재시도 시점 분산, thundering herd 방지
#   retry_on_timeout: False   — 타임아웃 = 서버 과부하 신호, 재시도 시 악화
#   connect_timeout:  5s      — 기본 15s는 리소스 점유가 너무 김


# ==============================================================================
# Python (redis-py)
# ==============================================================================
#
# redis-py >= 4.5.0 에서 Retry, ExponentialBackoff 내장 지원
# redis-py >= 4.5.0 has built-in Retry and ExponentialBackoff support
#
# from redis.cluster import RedisCluster
# from redis.backoff import ExponentialBackoff
# from redis.retry import Retry
#
# # 지수 백오프 재시도 설정
# # Exponential backoff retry configuration
# # base=0.5 → 재시도 간격: 0.5s, 1s, 2s (지수 증가, cap=16s)
# # retries=3 → 최대 3회 재시도 후 예외 발생
# retry = Retry(
#     backoff=ExponentialBackoff(base=0.5, cap=16),
#     retries=3
# )
#
# client = RedisCluster(
#     host="clustercfg.xxx.apn2.cache.amazonaws.com",
#     port=6379,
#     ssl=True,
#     retry=retry,
#     retry_on_timeout=False,       # 타임아웃 시 재시도 안 함 (증폭 방지)
#                                    # Do not retry on timeout (prevents amplification)
#     socket_connect_timeout=5,      # 연결 타임아웃 5초 (기본 15초는 너무 김)
#                                    # Connection timeout 5s (default 15s is too long)
#     socket_timeout=5,              # 응답 타임아웃 5초
#                                    # Response timeout 5s
# )


# ==============================================================================
# Java (Lettuce)
# ==============================================================================
#
# Lettuce는 reconnectDelay로 지수 백오프를 설정
# Lettuce uses reconnectDelay for exponential backoff configuration
#
# ClientResources resources = DefaultClientResources.builder()
#     .reconnectDelay(Delay.exponential(
#         Duration.ofMillis(500),    // base: 첫 재시도 대기 500ms
#                                    // base: first retry wait 500ms
#         Duration.ofSeconds(16),    // cap: 최대 대기 16초
#                                    // cap: maximum wait 16 seconds
#         Duration.ofMillis(100),    // jitter: ±100ms 랜덤 분산
#                                    // jitter: ±100ms random distribution
#         3                          // maxRetries: 최대 3회 재시도
#                                    // maxRetries: maximum 3 retries
#     ))
#     .build();
#
# RedisClusterClient client = RedisClusterClient.create(
#     resources, "rediss://clustercfg.xxx.apn2.cache.amazonaws.com:6379"
# );
#
# client.setOptions(ClusterClientOptions.builder()
#     .socketOptions(SocketOptions.builder()
#         .connectTimeout(Duration.ofSeconds(5))   // 연결 타임아웃 5초
#                                                   // Connection timeout 5s
#         .build())
#     .timeoutOptions(TimeoutOptions.builder()
#         .fixedTimeout(Duration.ofSeconds(5))      // 명령 타임아웃 5초
#                                                   // Command timeout 5s
#         .build())
#     .maxRedirects(3)                              // 클러스터 리다이렉트 최대 3회
#                                                   // Cluster redirect max 3 times
#     .build());


# ==============================================================================
# Java (Jedis)
# ==============================================================================
#
# Jedis는 maxAttempts로 재시도 횟수를 설정하지만 백오프가 내장되어 있지 않음
# 별도 래퍼로 지수 백오프를 구현해야 함
#
# Jedis uses maxAttempts for retry count but has no built-in backoff
# A separate wrapper is needed for exponential backoff
#
# // --- 커넥션 풀 + 클러스터 클라이언트 설정 ---
# // --- Connection pool + cluster client setup ---
# GenericObjectPoolConfig<Connection> poolConfig = new GenericObjectPoolConfig<>();
# poolConfig.setMaxTotal(20);                       // 노드당 최대 연결 수
#                                                    // Max connections per node
# poolConfig.setMaxWait(Duration.ofSeconds(5));      // 풀에서 연결 대기 최대 5초
#                                                    // Max wait for pool connection 5s
#
# JedisCluster client = new JedisCluster(
#     Set.of(new HostAndPort("clustercfg.xxx.apn2.cache.amazonaws.com", 6379)),
#     5000,    // connectionTimeout: 연결 타임아웃 5초 / Connection timeout 5s
#     5000,    // soTimeout: 소켓 타임아웃 5초 / Socket timeout 5s
#     3,       // maxAttempts: 최대 3회 시도 / Max 3 attempts
#     null,    // password
#     null,    // clientName
#     poolConfig,
#     true     // ssl: TLS 활성화 / Enable TLS
# );
#
# // --- 지수 백오프 래퍼 ---
# // --- Exponential backoff wrapper ---
# // Jedis 내장 재시도에는 백오프가 없으므로 래퍼로 구현
# // Jedis built-in retry has no backoff, so implement via wrapper
# public <T> T executeWithBackoff(Supplier<T> command) {
#     int retries = 3;
#     for (int i = 0; i <= retries; i++) {
#         try {
#             return command.get();
#         } catch (JedisConnectionException e) {
#             if (i == retries) throw e;
#             // 지수 백오프: 500ms × 2^i + 랜덤 jitter (0~1000ms)
#             // Exponential backoff: 500ms × 2^i + random jitter (0~1000ms)
#             long delay = (long)(500 * Math.pow(2, i) + Math.random() * 1000);
#             Thread.sleep(Math.min(delay, 16000));  // cap 16초 / cap 16s
#         }
#     }
#     throw new RuntimeException("unreachable");
# }
#
# // 사용 예 / Usage example
# String value = executeWithBackoff(() -> client.get("key"));


# ==============================================================================
# Go (go-redis)
# ==============================================================================
#
# go-redis v9는 MinRetryBackoff/MaxRetryBackoff로 지수 백오프 내장 지원
# go-redis v9 has built-in exponential backoff via MinRetryBackoff/MaxRetryBackoff
#
# client := redis.NewClusterClient(&redis.ClusterOptions{
#     Addrs:           []string{"clustercfg.xxx.apn2.cache.amazonaws.com:6379"},
#     TLSConfig:       &tls.Config{},
#     DialTimeout:     5 * time.Second,           // 연결 타임아웃 5초
#                                                  // Connection timeout 5s
#     ReadTimeout:     5 * time.Second,            // 읽기 타임아웃 5초
#                                                  // Read timeout 5s
#     WriteTimeout:    5 * time.Second,            // 쓰기 타임아웃 5초
#                                                  // Write timeout 5s
#     MaxRetries:      3,                          // 최대 3회 재시도
#                                                  // Max 3 retries
#     MinRetryBackoff: 500 * time.Millisecond,     // 백오프 시작: 500ms
#                                                  // Backoff base: 500ms
#     MaxRetryBackoff: 16 * time.Second,           // 백오프 상한: 16초
#                                                  // Backoff cap: 16s
#     PoolSize:        20,                         // 연결 풀 크기
#                                                  // Connection pool size
# })
