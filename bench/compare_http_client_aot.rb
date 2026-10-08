#!/usr/bin/env ruby
# Compare Ruby and Spinel clients against the same seeded production app.
require "json"
require "socket"

require_relative "support"
require_relative "http_client"

include BenchmarkSupport

class BenchmarkHTTPClientAOT
  include BenchmarkSupport

  def initialize(options, labels)
    @options = options
    @labels = labels
    @probe_source = File.join(ROOT, "bench/http_client_probe.rb")
    @native_probe = File.join(WORK, "spinel/http_client_probe")
    FileUtils.mkdir_p(File.dirname(@native_probe))
  end

  def compile
    run(@options[:spinel], "--version")
    run(@options[:spinel], @probe_source, "-o", @native_probe)
  rescue StandardError => error
    abort "spinel is required and must compile the probe: #{error.message}"
  end

  def command(side, port, concurrency)
    executable = side == "ruby" ? "ruby" : @native_probe
    [ executable, @probe_source, "--base", "http://127.0.0.1:#{port}",
      "--email", @labels.fetch("emails.david"), "--password", @labels.fetch("passwords.all"),
      "--room", @labels.fetch("rooms.watercooler").to_s, "--before", @labels.fetch("messages.busy_060").to_s,
      "--duration", @options[:duration].to_s, "--concurrency", concurrency.to_s ].tap do |command|
      command.delete_at(1) if side == "native"
    end
  end

  def measure(side, port, concurrency)
    JSON.parse(run(*command(side, port, concurrency))).fetch("results")
  end

  def version
    run(@options[:spinel], "--version").strip
  end
end

def available_cpus(cpu_set)
  available = Dir["/sys/devices/system/cpu/cpu[0-9]*"].map { |path| File.basename(path).delete_prefix("cpu").to_i }
  cpu_set.split(",").flat_map { |part| first, last = part.split("-", 2).map(&:to_i); last ? (first..last).to_a : [ first ] }.all? { |cpu| available.include?(cpu) }
end

options = parse_options("Compare Ruby and Spinel HTTP clients across Campfire page and message workflows.",
  { duration: 2.0, concurrencies: "1,16", client_cpus: "12-15", output: File.join(WORK, "results/spinel-aot"), spinel: "spinel" }, require_seed: false, include_baseline: false)
abort "--seed is required" unless options[:seed]
abort "--duration must be positive" unless options[:duration].positive?
concurrencies = options[:concurrencies].split(",").map { |value| Integer(value) }
abort "--concurrencies must be positive" if concurrencies.empty? || concurrencies.any?(&:negative?) || concurrencies.any?(&:zero?)
labels = JSON.parse(File.read(File.join(options[:seed], "labels.json")))
assets = prepare_assets(options[:image])
work = File.join(WORK, "spinel-aot")
network = "cf-spinel-bench-#{Process.pid}"
redis = "#{network}-redis"
app = "#{network}-app"
benchmark = BenchmarkHTTPClientAOT.new(options, labels)
benchmark.compile
runs = { "ruby" => [], "native" => [] }
order = []

begin
  if available_cpus(options[:client_cpus])
    run("taskset", "-pc", options[:client_cpus], Process.pid.to_s)
  else
    warn "Skipping client CPU pinning; #{options[:client_cpus]} is unavailable"
  end
  run("docker", "network", "create", network)
  redis_port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
  run("docker", "run", "-d", "--name", redis, "--network", network, "-p", "#{redis_port}:6379", "redis:7-alpine")
  redis_deadline = clock + 15
  until Open3.capture3("docker", "exec", redis, "redis-cli", "ping").last.success?
    raise "Redis did not become ready" if clock > redis_deadline
    sleep 0.1
  end
  options[:rounds].times do |iteration|
    sides = iteration.even? ? %w[ruby native] : %w[native ruby]
    order << sides
    sides.each do |side|
      remove_container(app)
      data = File.join(work, "data")
      prepare_storage(options[:seed], File.join(data, "storage"))
      FileUtils.mkdir_p([ File.join(data, "tmp/pids"), File.join(data, "log") ])
      run("docker", "exec", redis, "redis-cli", "FLUSHALL")
      port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
      source = ROOT
      command = [ "docker", "run", "-d", "--name", app, "--entrypoint", "", "--network", network,
        "--add-host", "host.docker.internal:host-gateway" ]
      command.concat [ "--cpuset-cpus", options[:cpus] ] if available_cpus(options[:cpus])
      command.concat [ "-p", "127.0.0.1:#{port}:3000" ]
      command.concat mounts(source => "/rails", File.join(data, "storage") => "/rails/storage",
        File.join(data, "tmp") => "/rails/tmp", File.join(data, "log") => "/rails/log", assets => "/rails/public/assets")
      command.concat environment(RAILS_ENV: "production", SECRET_KEY_BASE: "isolated-benchmark-fixture-key", DISABLE_SSL: true,
        SKIP_TELEMETRY: true, RAILS_LOG_LEVEL: ENV.fetch("RAILS_LOG_LEVEL", "fatal"), WEB_CONCURRENCY: 1, JOB_CONCURRENCY: 1, RAILS_MAX_THREADS: 5,
        REDIS_URL: "redis://host.docker.internal:#{redis_port}/0")
      command.concat [ options[:image], "bundle", "exec", "puma", "-C", "config/puma.rb" ]
      run(*command)
      client = BenchmarkHTTPClient.new("http://127.0.0.1:#{port}")
      deadline = clock + 45
      until client.ready?
        if clock > deadline
          File.write(File.join(work, "server.log"), run("docker", "logs", app))
          raise "server did not become ready; see #{work}/server.log"
        end
        sleep 0.1
      end
      results = {}
      concurrencies.each do |concurrency|
        benchmark.measure(side, port, concurrency).each do |name, result|
          results["#{name}_#{concurrency}"] = result
        end
      end
      data = { "engine" => side, "results" => results }
      runs[side] << data
      write_json(File.join(options[:output], "#{side}-#{iteration + 1}.json"), data)
      puts "#{iteration + 1}/#{options[:rounds]}: #{side}"
    end
  end
rescue StandardError
  logs, = Open3.capture3("docker", "logs", app)
  FileUtils.mkdir_p(work)
  File.write(File.join(work, "server.log"), logs)
  raise
ensure
  remove_container(app)
  remove_container(redis)
  Open3.capture3("docker", "network", "rm", network)
end

summary = {}
runs["ruby"].first.fetch("results").each_key do |name|
  summary[name] = {}
  %w[ruby native].each do |side|
    rows = runs[side].map { |row| row.fetch("results").fetch(name) }
    summary[name][side] = {
      "rps" => median(rows.map { |row| row.fetch("rps") }),
      "p95_ms" => median(rows.map { |row| row.fetch("latency_ms").fetch("p95") })
    }
  end
  summary[name]["speedup"] = summary[name]["native"]["rps"] / summary[name]["ruby"]["rps"]
end

write_json(File.join(options[:output], "summary.json"),
  metadata: { order: order, duration: options[:duration], concurrencies: concurrencies, rounds: options[:rounds],
              spinel: benchmark.version, ruby: run("ruby", "-v").strip, transport: "raw TCP sockets" },
  results: summary)
summary.each do |name, values|
  puts "%s: %.0f -> %.0f rps (%.2fx), p95 %.2f -> %.2f ms" % [
    name, values["ruby"]["rps"], values["native"]["rps"], values["speedup"], values["ruby"]["p95_ms"], values["native"]["p95_ms"]
  ]
end
