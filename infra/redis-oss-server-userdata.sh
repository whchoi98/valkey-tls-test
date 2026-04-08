#!/bin/bash
set -ex
exec > /var/log/redis-oss-setup.log 2>&1

# Install Redis OSS 7.2
dnf install -y gcc make openssl openssl-devel systemd-devel
cd /tmp
curl -fsSL https://download.redis.io/releases/redis-7.2.7.tar.gz -o redis.tar.gz
tar xzf redis.tar.gz
cd redis-7.2.7
make BUILD_TLS=yes -j$(nproc)
make install PREFIX=/usr/local/redis

# Generate TLS certs (shared CA for cluster)
mkdir -p /etc/redis/tls
cd /etc/redis/tls

# CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 -out ca.crt -subj "/CN=Redis-Test-CA"

# Server cert
MYIP=$(TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=$MYIP"
cat > server.ext << EXTEOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
subjectAltName=IP:$MYIP,IP:127.0.0.1
EXTEOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365 -sha256 -extfile server.ext

chmod 600 /etc/redis/tls/*.key

# Create Redis config directory
mkdir -p /var/lib/redis/{nontls-master,nontls-replica,tls-master,tls-replica}

# Write server IP for later use
echo "$MYIP" > /etc/redis/my-ip

# ===== Non-TLS Master (port 6379) =====
cat > /etc/redis/nontls-master.conf << CONF
port 6379
bind 0.0.0.0
cluster-enabled yes
cluster-config-file /var/lib/redis/nontls-master/nodes.conf
cluster-node-timeout 5000
dir /var/lib/redis/nontls-master
protected-mode no
save ""
appendonly no
CONF

# ===== Non-TLS Replica (port 6380) =====
cat > /etc/redis/nontls-replica.conf << CONF
port 6380
bind 0.0.0.0
cluster-enabled yes
cluster-config-file /var/lib/redis/nontls-replica/nodes.conf
cluster-node-timeout 5000
dir /var/lib/redis/nontls-replica
protected-mode no
save ""
appendonly no
CONF

# ===== TLS Master (port 6381) =====
cat > /etc/redis/tls-master.conf << CONF
port 0
tls-port 6381
tls-cert-file /etc/redis/tls/server.crt
tls-key-file /etc/redis/tls/server.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients no
tls-replication yes
tls-cluster yes
bind 0.0.0.0
cluster-enabled yes
cluster-config-file /var/lib/redis/tls-master/nodes.conf
cluster-node-timeout 5000
dir /var/lib/redis/tls-master
protected-mode no
save ""
appendonly no
CONF

# ===== TLS Replica (port 6382) =====
cat > /etc/redis/tls-replica.conf << CONF
port 0
tls-port 6382
tls-cert-file /etc/redis/tls/server.crt
tls-key-file /etc/redis/tls/server.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients no
tls-replication yes
tls-cluster yes
bind 0.0.0.0
cluster-enabled yes
cluster-config-file /var/lib/redis/tls-replica/nodes.conf
cluster-node-timeout 5000
dir /var/lib/redis/tls-replica
protected-mode no
save ""
appendonly no
CONF

# Start all Redis instances
/usr/local/redis/bin/redis-server /etc/redis/nontls-master.conf --daemonize yes
/usr/local/redis/bin/redis-server /etc/redis/nontls-replica.conf --daemonize yes
/usr/local/redis/bin/redis-server /etc/redis/tls-master.conf --daemonize yes
/usr/local/redis/bin/redis-server /etc/redis/tls-replica.conf --daemonize yes

sleep 2
echo "Redis processes:"
/usr/local/redis/bin/redis-cli -p 6379 ping
/usr/local/redis/bin/redis-cli -p 6380 ping
/usr/local/redis/bin/redis-cli --tls --cert /etc/redis/tls/server.crt --key /etc/redis/tls/server.key --cacert /etc/redis/tls/ca.crt -p 6381 ping
/usr/local/redis/bin/redis-cli --tls --cert /etc/redis/tls/server.crt --key /etc/redis/tls/server.key --cacert /etc/redis/tls/ca.crt -p 6382 ping

touch /var/log/redis-oss-setup-done
echo "=== Redis OSS server setup complete. IP: $MYIP ==="
