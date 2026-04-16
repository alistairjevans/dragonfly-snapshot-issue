# DragonflyDB Snapshot Freeze Reproduction

Reproduces the issue where DragonflyDB freezes during snapshots when a single
hash key holds millions of fields. See [dragonflydb/dragonfly#5625](https://github.com/dragonflydb/dragonfly/issues/5625).

## Steps

### 1. Start DragonflyDB

```bash
docker compose up -d
```

Uses the Dragonfly-native snapshot format (`--df_snapshot_format`) with 2
proactor threads so the freeze is easier to observe (fewer shards = higher
chance the giant key dominates one).

### 2. Populate the giant hash

```bash
gem install redis
ruby populate_hash.rb
```

Creates a mixed dataset of hashes at three tiers:
- **5,000** small hashes with 500 fields each
- **1,000** medium hashes with 10,000 fields each
- **1** large hash with 5,000,000 fields

The large hashes are what trigger the freeze — each one dominates a shard's
serialization time during snapshot.

### 3. Trigger snapshot and measure freeze

```bash
ruby trigger_and_measure.rb
```

This runs a tight set of concurrent writes and triggers `BGSAVE`, then reports latency
statistics. A freeze shows up as a max latency spike in the seconds range.

# Example: 

```
large_hash:0 has 5,000,000 fields
Dataset: 5k small hashes (500 fields), 1k medium (10k fields), 1 large (5M fields)

Collecting baseline for 5s...
Triggering BGSAVE at 12:31:06...
  Saving... 98% (5,940 / 6,001 keys) [12.8s]

  HSET latency over time (log scale, ms)

       10s │                    ███                                                    │    
           │                    │                                                      │    
           │                    │                                                      │    
           │                    │                                                      │    
           │                    │                                        ██            │    
        1s │                    │                                          █           │    
           │                    │                                                      │    
           │                    │                                                      │    
           │                    │                                                      │    
           │                    │                                                     █│    
     100ms │                    │                                                █     │    
           │     █              │                                                 ███  │    
       p99 │┄┄┄┄┄┄┄┄┄┄┄█┄┄┄┄┄┄┄┄│┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄██┄┄┄┄█┄│┄┄┄┄
           │      █             │                                                      │    
      10ms │    █    █          │                                                      │ █  
           │            █       │                                                      │█   
           │  █    █            │                                                      █    
           │██ █      █  ██  █  │                                                      │    
           │        █      ██  █│                                                      │  ██
       1ms │                  █ │                                                      │    
           │                    │                                                      │    
       p50 │────────────────────│──────────────────────────────────────────────────────│────
           │                    │                                                      │    
           │                    │                                                      │    
     0.1ms │                    │                                                      │    
           └────────────────────┴──────────────────────────────────────────────────────┴────
            0.0s              4.8s                9.7s                14.5s                 
                              SAVE                                                   DONE   

            │ BGSAVE start/end   ─ p50 (0.40ms)   ┄ p99 (30.80ms)

            Baseline: first 5.0s before SAVE

============================================================
BGSAVE completed in 13.34s

                        Baseline     During save
  ------------------------------------------------
  Writes:              7528            1769
  Duration:             5.0s           13.3s
  Throughput:         1504/s           133/s  (91% drop)
  ------------------------------------------------
  Median (p50):      0.39 ms         0.73 ms
  P99:               4.30 ms      1165.14 ms
  Max:              41.72 ms     10012.62 ms

Freezes (>22ms): 174
  Longest freeze: 10013 ms
  Total freeze time: 118454 ms
============================================================
```
