# DragonflyDB Snapshot Freeze Reproduction

Reproduces the issue where DragonflyDB freezes during snapshots when a single
hash key holds millions of fields. See [dragonflydb/dragonfly#5625](https://github.com/dragonflydb/dragonfly/issues/5625).

## Background

DragonflyDB uses a forkless, per-shard snapshot architecture. Each shard thread
serializes its own data at bucket granularity. Unlike Redis (which forks and
uses copy-on-write), Dragonfly serializes inline on the event loop threads.

When a single key is extremely large, the shard owning that key blocks its
event loop during serialization — freezing all commands routed to that shard.

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

This runs a tight PING loop and triggers `BGSAVE`, then reports latency
statistics. A freeze shows up as a max latency spike in the seconds range.
