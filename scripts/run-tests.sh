#!/bin/bash
# Run all connection storm tests
# Usage: ./scripts/run-tests.sh <nontls_endpoint> <tls_2shard_endpoint> <tls_4shard_endpoint>
set -euo pipefail

NONTLS_EP="${1:?Usage: $0 <nontls_ep> <tls_2shard_ep> <tls_4shard_ep>}"
TLS2_EP="${2:?}"
TLS4_EP="${3:?}"
BIN="./target/release/valkey-conn-storm"
OUT="results/test-$(date +%Y%m%d-%H%M%S).txt"

cargo build --release 2>&1 | tail -3

echo "Results will be saved to $OUT"
{
  echo "Test Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "============================================"

  echo ""
  echo ">>> Baseline: Non-TLS vs TLS Storm <<<"
  $BIN --endpoint "$NONTLS_EP" --mode storm --label "Non-TLS Storm (1 shard)"
  $BIN --endpoint "$TLS2_EP" --tls --mode storm --label "TLS Storm (2 shard, required)"

  echo ""
  echo ">>> Test 1: preferred mode <<<"
  echo "(Run after: aws elasticache modify-replication-group --replication-group-id <id> --transit-encryption-mode preferred --apply-immediately)"
  $BIN --endpoint "$TLS2_EP" --mode storm --label "preferred Non-TLS Storm (2 shard)"
  $BIN --endpoint "$TLS2_EP" --tls --mode storm --label "preferred TLS Storm (2 shard)"

  echo ""
  echo ">>> Test 2: Connection Pool + Warm-up <<<"
  $BIN --endpoint "$NONTLS_EP" --mode pool --label "Non-TLS Pool (1 shard)"
  $BIN --endpoint "$TLS2_EP" --tls --mode pool --label "TLS Pool (2 shard, required)"

  echo ""
  echo ">>> Test 4: Shard Scale-out (4 shard) <<<"
  $BIN --endpoint "$TLS4_EP" --tls --mode storm --label "TLS Storm (4 shard, required)"
  $BIN --endpoint "$TLS4_EP" --tls --mode pool --label "TLS Pool (4 shard, required)"

} 2>&1 | tee "$OUT"

echo ""
echo "Results saved to $OUT"
