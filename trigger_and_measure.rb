#!/usr/bin/env ruby
# frozen_string_literal: true

# Trigger a BGSAVE and measure how long the server becomes unresponsive.
#
# Runs a tight HSET loop in one thread while triggering BGSAVE in another,
# measuring latency spikes that indicate the event loop is blocked.
# Renders an ASCII time-series chart of write latency with p50/p99 lines.

require "redis"

GRAPH_WIDTH = 80
GRAPH_HEIGHT = 25
BUCKET_COUNT = GRAPH_WIDTH # one column per time bucket

results = [] # [[timestamp, latency_ms], ...]
stop = false
mutex = Mutex.new

HASH_KEYS = %w[small_hash medium_hash large_hash].freeze
SMALL_COUNT = 5_000
MEDIUM_COUNT = 1_000

r_write = Redis.new(host: "localhost", port: 6380)
r_cmd = Redis.new(host: "localhost", port: 6380)
r_write.ping

def fmt(n) = n.to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ",")

# Verify data exists by checking for the first large hash
large_hash_size = r_cmd.hlen("large_hash:0")
puts "large_hash:0 has #{fmt(large_hash_size)} fields"
small_count = r_cmd.exists(*Array.new(10) { |i| "small_hash:#{i}" })
medium_count = r_cmd.exists(*Array.new(10) { |i| "medium_hash:#{i}" })
puts "Dataset: 5k small hashes (500 fields), 1k medium (10k fields), 1 large (5M fields)"

if large_hash_size == 0
  puts "Run populate_hash.rb first!"
  exit 1
end

epoch = Process.clock_gettime(Process::CLOCK_MONOTONIC)

WRITE_THREADS = 10

# Start concurrent write threads — each does HSET to random hash key + field
write_threads = WRITE_THREADS.times.map do |thread_id|
  Thread.new do
    r = Redis.new(host: "localhost", port: 6380)
    rng = Random.new(thread_id)
    counter = 0
    until stop
      # Pick a random hash key across all tiers
      case rng.rand(3)
      when 0 then key = "small_hash:#{rng.rand(SMALL_COUNT)}"
      when 1 then key = "medium_hash:#{rng.rand(MEDIUM_COUNT)}"
      when 2 then key = "large_hash:0"
      end
      field = "field:#{rng.rand(1_000_000)}"
      value = "bench-#{thread_id}-#{counter}-#{"x" * 50}"
      counter += 1

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        r.hset(key, field, value)
        latency = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        mutex.synchronize { results << [t0 - epoch, latency * 1000.0] }
      rescue => e
        latency = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        mutex.synchronize { results << [t0 - epoch, latency * 1000.0] }
      end
      sleep 0.005 # ~200 writes/sec per thread
    end
  end
end

# Collect baseline for 5 seconds
puts "\nCollecting baseline for 5s..."
sleep 5

bgsave_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - epoch
puts "Triggering BGSAVE at #{Time.now.strftime("%H:%M:%S")}..."
r_cmd.bgsave

# Wait for save to start, then finish (DFS-specific fields)
save_detected = false
loop do
  info = r_cmd.info("persistence")
  saving = info["saving"].to_i

  if !save_detected && saving == 1
    save_detected = true
  elsif save_detected && saving == 0
    break
  elsif !save_detected
    # Also check rdb_bgsave_in_progress as fallback
    if info["rdb_bgsave_in_progress"].to_i == 1
      save_detected = true
    end
  end

  if save_detected
    pct = info["current_snapshot_perc"].to_i
    keys_done = info["current_save_keys_processed"].to_i
    keys_total = info["current_save_keys_total"].to_i
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - epoch - bgsave_start
    printf("\r  Saving... %d%% (%s / %s keys) [%.1fs]", pct, fmt(keys_done), fmt(keys_total), elapsed)
  end
  sleep 0.2
end
puts

bgsave_end = Process.clock_gettime(Process::CLOCK_MONOTONIC) - epoch
save_duration = bgsave_end - bgsave_start
sleep 1
stop = true
write_threads.each { |t| t.join(2) }

# Snapshot results
snapshot = mutex.synchronize { results.dup }

if snapshot.empty?
  puts "No writes recorded!"
  exit 1
end

timestamps = snapshot.map { |ts, _| ts }
latencies = snapshot.map { |_, lat| lat }

sorted = latencies.sort
p50 = sorted[sorted.length / 2]
p99 = sorted[(sorted.length * 0.99).to_i]
max_lat = sorted.last

# --- ASCII time-series chart ---

t_min = timestamps.min
t_max = timestamps.max
t_range = t_max - t_min
t_range = 1.0 if t_range == 0

# Use log scale for y-axis to show both sub-ms baseline and multi-second freezes
lat_floor = 0.1 # 0.1ms floor for log scale
log_min = Math.log10(lat_floor)
log_max = Math.log10([max_lat, lat_floor * 10].max)
log_range = log_max - log_min
log_range = 1.0 if log_range == 0

# Bucket samples by time
buckets = Array.new(BUCKET_COUNT) { [] }
snapshot.each do |ts, lat|
  col = ((ts - t_min) / t_range * (BUCKET_COUNT - 1)).round
  col = col.clamp(0, BUCKET_COUNT - 1)
  buckets[col] << lat
end

# For each column, take the max latency (to show spikes)
col_values = buckets.map { |b| b.empty? ? nil : b.max }

# Map a latency (ms) to a row (0 = bottom, GRAPH_HEIGHT-1 = top)
to_row = ->(lat_ms) do
  clamped = [lat_ms, lat_floor].max
  ((Math.log10(clamped) - log_min) / log_range * (GRAPH_HEIGHT - 1)).round.clamp(0, GRAPH_HEIGHT - 1)
end

# Build the grid
grid = Array.new(GRAPH_HEIGHT) { Array.new(GRAPH_WIDTH, " ") }

# Plot data points
col_values.each_with_index do |val, col|
  next unless val
  row = to_row.call(val)
  grid[row][col] = "\u2588" # full block
end

# Plot p50 and p99 as horizontal lines
p50_row = to_row.call(p50)
p99_row = to_row.call(p99)

GRAPH_WIDTH.times do |col|
  grid[p50_row][col] = "\u2500" if grid[p50_row][col] == " " # light horizontal
  grid[p99_row][col] = "\u2504" if grid[p99_row][col] == " " # dashed horizontal
end

# Plot BGSAVE start/end as vertical markers
bgsave_start_col = ((bgsave_start - t_min) / t_range * (BUCKET_COUNT - 1)).round.clamp(0, BUCKET_COUNT - 1)
bgsave_end_col = ((bgsave_end - t_min) / t_range * (BUCKET_COUNT - 1)).round.clamp(0, BUCKET_COUNT - 1)

GRAPH_HEIGHT.times do |row|
  grid[row][bgsave_start_col] = "\u2502" if grid[row][bgsave_start_col] == " " || grid[row][bgsave_start_col] == "\u2500" || grid[row][bgsave_start_col] == "\u2504"
  grid[row][bgsave_end_col] = "\u2502" if grid[row][bgsave_end_col] == " " || grid[row][bgsave_end_col] == "\u2500" || grid[row][bgsave_end_col] == "\u2504"
end

# Y-axis labels: pick a few log-scale ticks
y_ticks = [0.1, 1, 10, 100, 1000, 10_000, 50_000].select { |v| v >= lat_floor && v <= max_lat * 1.2 }
y_label_width = 10

puts
puts "  HSET latency over time (log scale, ms)"
puts

# Render top to bottom
(GRAPH_HEIGHT - 1).downto(0) do |row|
  # Find if this row matches a y-tick
  label = ""
  y_ticks.each do |tick|
    if to_row.call(tick) == row
      label = if tick >= 1000
                "#{(tick / 1000).to_i}s"
              elsif tick >= 1
                "#{tick.to_i}ms"
              else
                "#{"%.1f" % tick}ms"
              end
      break
    end
  end

  # Check for p50/p99 labels
  if row == p50_row
    label = "p50" if label.empty?
    label += " p50" unless label.include?("p50")
  end
  if row == p99_row
    label = "p99" if label.empty?
    label += " p99" unless label.include?("p99")
  end

  printf("%*s \u2502%s\n", y_label_width, label, grid[row].join)
end

# X-axis
x_axis = "\u2500" * GRAPH_WIDTH
# Place BGSAVE markers on the x-axis line
x_axis[bgsave_start_col] = "\u2534" # bottom T-junction at save start
x_axis[bgsave_end_col] = "\u2534" if bgsave_end_col != bgsave_start_col
printf("%*s \u2514%s\n", y_label_width, "", x_axis)

# Time labels on x-axis
time_labels = [0, 0.25, 0.5, 0.75, 1.0].map do |frac|
  t = t_min + t_range * frac
  ["%.1fs" % t, (frac * GRAPH_WIDTH).to_i]
end
padded = " " * GRAPH_WIDTH
time_labels.each do |label, pos|
  pos = [pos - label.length / 2, 0].max
  padded[pos, label.length] = label if pos + label.length <= GRAPH_WIDTH
end
printf("%*s  %s\n", y_label_width, "", padded)

# BGSAVE marker labels below x-axis
marker_line = " " * GRAPH_WIDTH
save_label = "SAVE"
end_label = "DONE"
start_pos = [bgsave_start_col - save_label.length / 2, 0].max
end_pos = [bgsave_end_col - end_label.length / 2, 0].max
# Avoid overlap
if (end_pos - start_pos).abs < save_label.length + 1 && bgsave_end_col != bgsave_start_col
  end_pos = start_pos + save_label.length + 1
end
marker_line[start_pos, save_label.length] = save_label if start_pos + save_label.length <= GRAPH_WIDTH
marker_line[end_pos, end_label.length] = end_label if bgsave_end_col != bgsave_start_col && end_pos + end_label.length <= GRAPH_WIDTH
printf("%*s  %s\n", y_label_width, "", marker_line)

# Legend
puts
printf("%*s  \u2502 BGSAVE start/end   \u2500 p50 (%.2fms)   \u2504 p99 (%.2fms)\n", y_label_width, "", p50, p99)
puts
printf("%*s  Baseline: first %.1fs before SAVE\n", y_label_width, "", bgsave_start)

# --- Summary stats ---

# Split results into baseline vs during-save
baseline_samples = snapshot.select { |ts, _| ts < bgsave_start }.map { |_, lat| lat }
save_samples = snapshot.select { |ts, _| ts >= bgsave_start && ts <= bgsave_end }.map { |_, lat| lat }

baseline_sorted = baseline_samples.sort
save_sorted = save_samples.sort

baseline_p50 = baseline_sorted.empty? ? 0 : baseline_sorted[baseline_sorted.length / 2]
baseline_p99 = baseline_sorted.empty? ? 0 : baseline_sorted[(baseline_sorted.length * 0.99).to_i]
baseline_max = baseline_sorted.empty? ? 0 : baseline_sorted.last

save_p50 = save_sorted.empty? ? 0 : save_sorted[save_sorted.length / 2]
save_p99 = save_sorted.empty? ? 0 : save_sorted[(save_sorted.length * 0.99).to_i]
save_max = save_sorted.empty? ? 0 : save_sorted.last

freeze_threshold = [baseline_p99 * 5, 0.05].max
freezes = save_samples.select { |lat| lat > freeze_threshold }

baseline_duration = bgsave_start
baseline_throughput = baseline_samples.length / baseline_duration
save_throughput = save_duration > 0 ? save_samples.length / save_duration : 0
throughput_drop = baseline_throughput > 0 ? ((1 - save_throughput / baseline_throughput) * 100) : 0

puts
puts "=" * 60
puts "BGSAVE completed in #{save_duration.round(2)}s"
puts
puts "                        Baseline     During save"
puts "  ------------------------------------------------"
printf("  Writes:          %8d        %8d\n", baseline_samples.length, save_samples.length)
printf("  Duration:        %8.1fs       %8.1fs\n", baseline_duration, save_duration)
printf("  Throughput:      %7.0f/s       %7.0f/s  (%.0f%% drop)\n", baseline_throughput, save_throughput, throughput_drop)
puts "  ------------------------------------------------"
printf("  Median (p50):  %8.2f ms     %8.2f ms\n", baseline_p50, save_p50)
printf("  P99:           %8.2f ms     %8.2f ms\n", baseline_p99, save_p99)
printf("  Max:           %8.2f ms     %8.2f ms\n", baseline_max, save_max)
puts
puts "Freezes (>#{freeze_threshold.round(0)}ms): #{freezes.length}"
if freezes.any?
  puts "  Longest freeze: #{freezes.max.round(0)} ms"
  puts "  Total freeze time: #{freezes.sum.round(0)} ms"
end
puts "=" * 60

if max_lat > 1000
  puts "\n*** FREEZE DETECTED: server blocked for #{max_lat.round(0)}ms during snapshot ***"
else
  puts "\nNo significant freeze detected."
end
