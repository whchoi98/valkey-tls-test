#!/bin/bash
# Cleanup all test clusters
set -euo pipefail
REGION="${AWS_REGION:-ap-northeast-2}"

for ID in valkey-nontls-test valkey-tls-2shard valkey-tls-4shard; do
  echo "Deleting $ID..."
  aws elasticache delete-replication-group \
    --replication-group-id "$ID" \
    --no-retain-primary-cluster \
    --region "$REGION" 2>/dev/null || echo "  $ID not found, skipping"
done

echo "Done. Clusters will be deleted in a few minutes."
