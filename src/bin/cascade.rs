use clap::Parser;
use redis::cluster::ClusterClient;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::task::JoinSet;

#[derive(Parser)]
struct Args {
    #[arg(long)]
    endpoint: String,
    #[arg(long, default_value_t = false)]
    tls: bool,
    #[arg(long, default_value_t = 100)]
    pods: usize,
    #[arg(long, default_value_t = 0)]
    retries: usize,
    #[arg(long, default_value_t = 60)]
    duration: u64,
    #[arg(long, default_value_t = 5)]
    timeout: u64,
    /// Backoff: none, exponential
    #[arg(long, default_value = "none")]
    backoff: String,
    #[arg(long, default_value = "")]
    label: String,
}

fn main() {
    let args = Args::parse();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let label = if args.label.is_empty() {
        format!("pods={} retries={} backoff={}", args.pods, args.retries, args.backoff)
    } else { args.label.clone() };
    println!("\n=== Cascade Test: {} ===", label);
    println!("Endpoint: {}, TLS: {}", args.endpoint, args.tls);
    println!("Duration: {}s, Timeout: {}s\n", args.duration, args.timeout);
    rt.block_on(run(&args));
}

async fn run(args: &Args) {
    let scheme = if args.tls { "rediss" } else { "redis" };
    let url = format!("{}://{}", scheme, args.endpoint);
    let ok = Arc::new(AtomicUsize::new(0));
    let fail = Arc::new(AtomicUsize::new(0));
    let attempts = Arc::new(AtomicUsize::new(0));
    let deadline = Instant::now() + Duration::from_secs(args.duration);
    let mut set = JoinSet::new();

    let ok2 = ok.clone(); let fail2 = fail.clone(); let att2 = attempts.clone();
    let dur = args.duration;
    tokio::spawn(async move {
        let start = Instant::now();
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            let e = start.elapsed().as_secs();
            println!("  [{:>3}s] attempts={} ok={} fail={}",
                e, att2.load(Ordering::Relaxed), ok2.load(Ordering::Relaxed), fail2.load(Ordering::Relaxed));
            if e >= dur { break; }
        }
    });

    for _ in 0..args.pods {
        let url = url.clone();
        let is_tls = args.tls;
        let max_retries = args.retries;
        let to = args.timeout;
        let ok = ok.clone(); let fail = fail.clone(); let attempts = attempts.clone();
        let use_backoff = args.backoff == "exponential";
        set.spawn(async move {
            let mut retry = 0;
            loop {
                if Instant::now() >= deadline { break; }
                attempts.fetch_add(1, Ordering::Relaxed);
                let u = url.clone();
                let result = tokio::time::timeout(
                    Duration::from_secs(to),
                    tokio::task::spawn_blocking(move || {
                        let builder = ClusterClient::builder(vec![u.as_str()]).read_from_replicas();
                        let client = if is_tls {
                            builder.tls(redis::cluster::TlsMode::Secure).build()
                        } else { builder.build() };
                        match client {
                            Ok(c) => c.get_connection().map(|mut conn| conn.check_connection()).unwrap_or(false),
                            Err(_) => false,
                        }
                    }),
                ).await;
                match result {
                    Ok(Ok(true)) => { ok.fetch_add(1, Ordering::Relaxed); break; }
                    _ => {
                        fail.fetch_add(1, Ordering::Relaxed);
                        if retry >= max_retries { break; }
                        retry += 1;
                        if use_backoff {
                            let base = Duration::from_millis(500 * (1u64 << retry.min(5)));
                            let jitter = Duration::from_millis(rand::random::<u64>() % 1000);
                            tokio::time::sleep(base + jitter).await;
                        }
                    }
                }
            }
        });
    }
    while set.join_next().await.is_some() {}
    let o = ok.load(Ordering::Relaxed);
    let f = fail.load(Ordering::Relaxed);
    let a = attempts.load(Ordering::Relaxed);
    println!("\n--- Result ---");
    println!("Total attempts: {}", a);
    println!("Success: {} ({:.1}%), Fail: {}", o, o as f64 / args.pods as f64 * 100.0, f);
    println!("Amplification: {:.1}x (total_attempts / pods)", a as f64 / args.pods as f64);
}
