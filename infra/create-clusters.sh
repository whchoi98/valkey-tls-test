#!/bin/bash
# Create ElastiCache Valkey clusters for TLS performance testing
# Prerequisites: AWS CLI configured, VPC with subnet group and security group
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-2}"
SUBNET_GROUP="${SUBNET_GROUP:?Set SUBNET_GROUP env var}"
SECURITY_GROUP="${SECURITY_GROUP:?Set SECURITY_GROUP env var}"
PARAM_GROUP="default.valkey8.cluster.on"
NODE_TYPE="${NODE_TYPE:-cache.r7g.large}"

echo "=== Creating Non-TLS cluster (1 shard) ==="
aws elasticache create-replication-group \
  --replication-group-id valkey-nontls-test \
  --replication-group-description "Valkey 8.2 Non-TLS test" \
  --engine valkey --engine-version 8.2 \
  --cache-node-type "$NODE_TYPE" \
  --num-node-groups 1 --replicas-per-node-group 1 \
  --cache-subnet-group-name "$SUBNET_GROUP" \
  --security-group-ids "$SECURITY_GROUP" \
  --cache-parameter-group-name "$PARAM_GROUP" \
  --automatic-failover-enabled --multi-az-enabled \
  --no-transit-encryption-enabled --no-at-rest-encryption-enabled \
  --region "$REGION"

echo "=== Creating TLS cluster (2 shard, required) ==="
aws elasticache create-replication-group \
  --replication-group-id valkey-tls-2shard \
  --replication-group-description "Valkey 8.2 TLS 2-shard test" \
  --engine valkey --engine-version 8.2 \
  --cache-node-type "$NODE_TYPE" \
  --num-node-groups 2 --replicas-per-node-group 1 \
  --cache-subnet-group-name "$SUBNET_GROUP" \
  --security-group-ids "$SECURITY_GROUP" \
  --cache-parameter-group-name "$PARAM_GROUP" \
  --automatic-failover-enabled --multi-az-enabled \
  --transit-encryption-enabled --transit-encryption-mode required \
  --at-rest-encryption-enabled \
  --region "$REGION"

echo "=== Creating TLS cluster (4 shard, required) ==="
aws elasticache create-replication-group \
  --replication-group-id valkey-tls-4shard \
  --replication-group-description "Valkey 8.2 TLS 4-shard test" \
  --engine valkey --engine-version 8.2 \
  --cache-node-type "$NODE_TYPE" \
  --num-node-groups 4 --replicas-per-node-group 1 \
  --cache-subnet-group-name "$SUBNET_GROUP" \
  --security-group-ids "$SECURITY_GROUP" \
  --cache-parameter-group-name "$PARAM_GROUP" \
  --automatic-failover-enabled --multi-az-enabled \
  --transit-encryption-enabled --transit-encryption-mode required \
  --at-rest-encryption-enabled \
  --region "$REGION"

echo ""
echo "Clusters creating. Wait ~5-10 minutes for availability."
echo "Check status: aws elasticache describe-replication-groups --region $REGION --query 'ReplicationGroups[*].[ReplicationGroupId,Status]'"
