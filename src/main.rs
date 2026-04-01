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
    #[arg(long, default_value_t = 15)]
    timeout: u64,
    /// Test mode: storm (new client per conn), pool (shared client)
    #[arg(long, default_value = "storm")]
    mode: String,
    /// Label for output
    #[arg(long, default_value = "")]
    label: String,
}

fn main() {
    let args = Args::parse();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let levels = [10, 50, 100, 200, 500, 1000, 2000];
    let tls_str = if args.tls { "TLS" } else { "Non-TLS" };
    let label = if args.label.is_empty() { format!("{} {}", tls_str, args.mode) } else { args.label.clone() };
    println!("\n=== {} ===", label);
    println!("Endpoint: {}", args.endpoint);
    println!("Mode: {}, Timeout: {}s\n", args.mode, args.timeout);
    println!("{:<12} {:>12} {:>14} {:>10}", "Conns", "Wall Time", "Success", "Rate");
    println!("{}", "-".repeat(52));
    for &n in &levels {
        let (wall_ms, ok, total) = if args.mode == "pool" {
            rt.block_on(run_pool(&args.endpoint, args.tls, n, args.timeout))
        } else {
            rt.block_on(run_storm(&args.endpoint, args.tls, n, args.timeout))
        };
        let rate = if wall_ms > 0 { ok as f64 / (wall_ms as f64 / 1000.0) } else { 0.0 };
        let wall_str = if wall_ms >= 1000 { format!("{:.1}s", wall_ms as f64 / 1000.0) } else { format!("{}ms", wall_ms) };
        let _pct = if total > 0 { ok as f64 / total as f64 * 100.0 } else { 0.0 };
        println!("{:<12} {:>12} {:>6}/{:<6} {:>8.0} c/s", n, wall_str, ok, total, rate);
    }
}

async fn run_storm(endpoint: &str, tls: bool, count: usize, timeout_secs: u64) -> (u64, usize, usize) {
    let scheme = if tls { "rediss" } else { "redis" };
    let url = format!("{}://{}", scheme, endpoint);
    let ok = Arc::new(AtomicUsize::new(0));
    let fail = Arc::new(AtomicUsize::new(0));
    let mut set = JoinSet::new();
    let start = Instant::now();
    for _ in 0..count {
        let url = url.clone();
        let ok = ok.clone();
        let fail = fail.clone();
        let is_tls = tls;
        set.spawn(async move {
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(timeout_secs),
                tokio::task::spawn_blocking(move || {
                    let builder = ClusterClient::builder(vec![url.as_str()]).read_from_replicas();
                    let client = if is_tls {
                        builder.tls(redis::cluster::TlsMode::Secure).build()
                    } else {
                        builder.build()
                    };
                    match client {
                        Ok(c) => c.get_connection().map(|mut conn| conn.check_connection()).unwrap_or(false),
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
    let s = ok.load(Ordering::Relaxed);
    let f = fail.load(Ordering::Relaxed);
    (elapsed, s, s + f)
}

async fn run_pool(endpoint: &str, tls: bool, count: usize, timeout_secs: u64) -> (u64, usize, usize) {
    let scheme = if tls { "rediss" } else { "redis" };
    let url = format!("{}://{}", scheme, endpoint);
    let builder = ClusterClient::builder(vec![url.as_str()]).read_from_replicas();
    let client = if tls {
        builder.tls(redis::cluster::TlsMode::Secure).build().expect("build")
    } else {
        builder.build().expect("build")
    };
    // Warm-up: establish initial connection
    let _ = client.get_connection();
    let client = Arc::new(client);
    let ok = Arc::new(AtomicUsize::new(0));
    let fail = Arc::new(AtomicUsize::new(0));
    let mut set = JoinSet::new();
    let start = Instant::now();
    for _ in 0..count {
        let c = client.clone();
        let ok = ok.clone();
        let fail = fail.clone();
        set.spawn(async move {
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(timeout_secs),
                tokio::task::spawn_blocking(move || {
                    c.get_connection().map(|mut conn| conn.check_connection()).unwrap_or(false)
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
    let s = ok.load(Ordering::Relaxed);
    let f = fail.load(Ordering::Relaxed);
    (elapsed, s, s + f)
}
