#!/usr/bin/env ruby
# frozen_string_literal: true

# Populate hashes of varying sizes to reproduce the DragonflyDB snapshot
# freeze issue.
#
# The issue: when BGSAVE runs, DragonflyDB serializes large keys atomically,
# blocking the event loop for that shard. A single hash with millions of
# fields can freeze the server for seconds.

require "redis"

TIERS = [
  { prefix: "small_hash", count: 5_000, fields: 500 },
  { prefix: "medium_hash", count: 1_000, fields: 10_000 },
  { prefix: "large_hash", count: 1,      fields: 5_000_000 },
].freeze

PIPELINE_BATCH = 10_000

def fmt(n) = n.to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ",")

redis = Redis.new(host: "localhost", port: 6380)
redis.ping
puts "Connected.\n\n"

TIERS.each do |tier|
  prefix = tier[:prefix]
  count = tier[:count]
  fields = tier[:fields]
  total_fields = count * fields

  puts "=== #{prefix}: #{fmt(count)} hashes x #{fmt(fields)} fields (#{fmt(total_fields)} total) ==="
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  count.times do |hash_idx|
    key = "#{prefix}:#{hash_idx}"
    redis.del(key)

    (0...fields).step(PIPELINE_BATCH) do |i|
      batch_end = [i + PIPELINE_BATCH, fields].min

      redis.pipelined do |pipe|
        (i...batch_end).each do |j|
          pipe.hset(key, "field:#{j}", "value-#{j}-#{"x" * 50}")
        end
      end
    end

    # Progress reporting
    if count <= 100
      # For large hashes, report every hash
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      printf("  %s  (%s / %s)  [%.1fs]\n", key, fmt(hash_idx + 1), fmt(count), elapsed)
    elsif (hash_idx + 1) % (count / 20) == 0
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      pct = (hash_idx + 1).to_f / count * 100
      printf("  %5.1f%%  (%s / %s)  [%.1fs]\n", pct, fmt(hash_idx + 1), fmt(count), elapsed)
    end
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  puts "  Done in #{elapsed.round(1)}s\n\n"
end

puts "All tiers populated."
