#!/bin/bash
set -ex
exec > /var/log/valkey-test.log 2>&1

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source /root/.cargo/env

# Create project
mkdir -p /opt/valkey-test/src
cd /opt/valkey-test

cat > Cargo.toml << 'CARGO_EOF'
[package]
name = "valkey-conn-storm"
version = "0.1.0"
edition = "2021"

[dependencies]
redis = { version = "0.27", features = ["cluster", "cluster-async", "tokio-rustls-comp", "tls-rustls"] }
tokio = { version = "1", features = ["full"] }
clap = { version = "4", features = ["derive"] }
CARGO_EOF

cat > src/main.rs << 'RUST_EOF'
use clap::Parser;
use redis::cluster::ClusterClient;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::task::JoinSet;

#[derive(Parser)]
struct Args {
    #[arg(long)]
    endpoint: String,
    #[arg(long, default_value_t = false)]
    tls: bool,
    #[arg(long, default_value_t = 10)]
    conns: usize,
    #[arg(long, default_value_t = 5)]
    timeout: u64,
}

fn main() {
    let args = Args::parse();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let levels = [10, 50, 100, 200, 500, 1000, 2000];
    let mode = if args.tls { "TLS" } else { "Non-TLS" };
    println!("\n=== Connection Storm Test ({mode}) ===");
    println!("Endpoint: {}", args.endpoint);
    println!("Timeout: {}s\n", args.timeout);
    println!("{:<12} {:>12} {:>12} {:>12}", "Conns", "Wall Time", "Success", "Rate");
    println!("{}", "-".repeat(52));
    for &n in &levels {
        let (wall_ms, ok, fail) = rt.block_on(run_storm(&args.endpoint, args.tls, n, args.timeout));
        let total = ok + fail;
        let rate = if wall_ms > 0 { ok as f64 / (wall_ms as f64 / 1000.0) } else { 0.0 };
        let wall_str = if wall_ms >= 1000 { format!("{:.1}s", wall_ms as f64 / 1000.0) } else { format!("{}ms", wall_ms) };
        println!("{:<12} {:>12} {:>8}/{:<4} {:>10.0} c/s", n, wall_str, ok, total, rate);
    }
}

async fn run_storm(endpoint: &str, tls: bool, count: usize, timeout_secs: u64) -> (u64, usize, usize) {
    let scheme = if tls { "rediss" } else { "redis" };
    let url = format!("{}://{}", scheme, endpoint);
    let builder = ClusterClient::builder(vec![url.as_str()]).read_from_replicas();
    let client = if tls {
        builder.tls(redis::cluster::TlsMode::Secure).build().expect("build TLS client")
    } else {
        builder.build().expect("build client")
    };
    let ok = Arc::new(AtomicUsize::new(0));
    let fail = Arc::new(AtomicUsize::new(0));
    let mut set = JoinSet::new();
    let start = Instant::now();
    for _ in 0..count {
        let c = client.clone();
        let ok = ok.clone();
        let fail = fail.clone();
        let to = timeout_secs;
        set.spawn(async move {
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(to),
                tokio::task::spawn_blocking(move || {
                    match c.get_connection() {
                        Ok(mut conn) => conn.check_connection(),
                        Err(_) => false,
                    }
                }),
            ).await;
            match result {
                Ok(Ok(true)) => { ok.fetch_add(1, Ordering::Relaxed); }
                _ => { fail.fetch_add(1, Ordering::Relaxed); }
            }
        });
    }
    while set.join_next().await.is_some() {}
    let elapsed = start.elapsed().as_millis() as u64;
    (elapsed, ok.load(Ordering::Relaxed), fail.load(Ordering::Relaxed))
}
RUST_EOF

# Build
cargo build --release 2>&1

NONTLS_EP="valkey-nontls-test.khojwc.clustercfg.apn2.cache.amazonaws.com:6379"
TLS_EP="clustercfg.stviztlwuv2jozz.khojwc.apn2.cache.amazonaws.com:6379"

echo ""
echo "=========================================="
echo "  VALKEY CONNECTION STORM TEST RESULTS"
echo "=========================================="
echo ""

# Non-TLS test
./target/release/valkey-conn-storm --endpoint "$NONTLS_EP" --timeout 15 2>&1

echo ""

# TLS test
./target/release/valkey-conn-storm --endpoint "$TLS_EP" --tls --timeout 15 2>&1

echo ""
echo "=========================================="
echo "  TEST COMPLETE"
echo "=========================================="

# Signal completion
touch /var/log/valkey-test-done
