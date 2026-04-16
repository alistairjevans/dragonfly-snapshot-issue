# DragonflyDB Snapshot Freeze Reproduction

Reproduces the issue where DragonflyDB freezes during snapshots when a single
hash key holds millions of fields. See [dragonflydb/dragonfly#5625](https://github.com/dragonflydb/dragonfly/issues/5625).

## Steps

### 1. Start DragonflyDB

```bash
docker compose up -d
```

Uses the Dragonfly-native snapshot format (`--df_snapshot_format`) with 14
proactor threads; still locks up ~all threads.

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
 alistair@Alistairs-MacBook-Pro  ~/scratch/dragonfly-snapshot-issue   main ±  ruby trigger_and_measure.rb
large_hash:0 has 5,000,000 fields
Dataset: 5k small hashes (500 fields), 1k medium (10k fields), 1 large (5M fields)

Collecting baseline for 5s...
Triggering BGSAVE at 15:29:49...
  Saving... 100% (6,001 / 6,001 keys) [14.4s]

  HSET latency over time (log scale, ms)

       10s │                   ██                                                      │    
           │                   │                                                       │    
           │                   │                                                       │    
           │                   │                                     ██                │    
           │                   │                                                       │    
        1s │                   │                                                       │    
           │                   │                                                       │    
           │                   │                                                       │    
           │                   │                                                  █    │    
           │                   │                                                      █│    
     100ms │                   │                                                █  █   │    
           │                   │                                               █ █  ██ █    
       p99 │┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│┄┄┄┄
           │                   │                                                       │    
      10ms │█                  │                                                       │    
           │ █ ██              │                                                       │  ██
           │  █  ██   █  █     │                                                       │ █  
           │        ██  █     █│                                                       │    
           │       █   █  ████ │                                                       │█   
       1ms │                   │                                                       │    
           │                   │                                                       │    
       p50 │───────────────────│───────────────────────────────────────────────────────│────
           │                   │                                                       │    
           │                   │                                                       │    
     0.1ms │                   │                                                       │    
           └───────────────────┴───────────────────────────────────────────────────────┴────
            0.0s              5.2s                10.3s               15.5s                 
                             SAVE                                                    DONE   

            │ BGSAVE start/end   ─ p50 (0.41ms)   ┄ p99 (36.36ms)

            Baseline: first 5.0s before SAVE

============================================================
BGSAVE completed in 14.64s

                        Baseline     During save
  ------------------------------------------------
  Writes:              7743            1620
  Duration:             5.0s           14.6s
  Throughput:         1547/s           111/s  (93% drop)
  ------------------------------------------------
  Median (p50):      0.40 ms         0.69 ms
  P99:               3.74 ms      2475.75 ms
  Max:              13.64 ms     10011.86 ms

Freezes (>19ms): 231
  Longest freeze: 10012 ms
  Total freeze time: 133362 ms
============================================================

*** FREEZE DETECTED: server blocked for 10012ms during snapshot ***
```
