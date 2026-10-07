#!/usr/bin/env ruby
require "json"
require_relative "support"
require_relative "http_client"

include BenchmarkSupport

class BenchmarkHTTPClientAOT
  include BenchmarkSupport

  def initialize(options)
    @options = options
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

  def command(side)
    side == "before" ? [ "ruby", @probe_source ] : [ @native_probe ]
  end

  def measure(side, concurrency)
    result = JSON.parse(run(*command(side), "--duration", @options[:duration].to_s,
      "--concurrency", concurrency.to_s))
    result.fetch("result")
  end

  def version
    run(@options[:spinel], "--version").strip
  end
end

options = parse_options("Compare Ruby and Spinel HTTP client throughput.", {
  duration: 2.0, concurrencies: "1,16", rounds: 6,
  output: File.join(WORK, "results/spinel-aot"), spinel: "spinel"
}, require_seed: false)
abort "--duration must be positive" unless options[:duration].positive?
concurrencies = options[:concurrencies].split(",").map { |value| Integer(value) }
abort "--concurrencies must be positive" if concurrencies.empty? || concurrencies.any?(&:negative?) || concurrencies.any?(&:zero?)

benchmark = BenchmarkHTTPClientAOT.new(options)
benchmark.compile
runs = { "before" => [], "after" => [] }
order = []
options[:rounds].times do |iteration|
  sides = iteration.even? ? %w[before after] : %w[after before]
  order << sides
  sides.each do |side|
    data = { "concurrency" => {}, "engine" => side == "before" ? "ruby" : "spinel" }
    concurrencies.each { |concurrency| data["concurrency"][concurrency.to_s] = benchmark.measure(side, concurrency) }
    runs[side] << data
    write_json(File.join(options[:output], "#{side}-#{iteration + 1}.json"), data)
    puts "#{iteration + 1}/#{options[:rounds]}: #{side}"
  end
end

summary = {}
concurrencies.each do |concurrency|
  key = concurrency.to_s
  values = runs.transform_values { |rows| rows.map { |row| row.fetch("concurrency").fetch(key) } }
  summary[key] = values.transform_values do |rows|
    { "rps" => median(rows.map { |row| row.fetch("rps") }),
      "p95_ms" => median(rows.map { |row| row.fetch("latency_ms").fetch("p95") }) }
  end
  summary[key]["speedup"] = summary[key]["after"]["rps"] / summary[key]["before"]["rps"]
end

metadata = {
  order: order, duration: options[:duration], concurrencies: concurrencies, rounds: options[:rounds],
  spinel: benchmark.version, ruby: run("ruby", "-v").strip,
  transport: "raw TCP sockets"
}
write_json(File.join(options[:output], "summary.json"), metadata: metadata, results: summary)
summary.each do |concurrency, values|
  puts "concurrency #{concurrency}: %.0f -> %.0f rps (%.2fx), p95 %.2f -> %.2f ms" % [
    values["before"]["rps"], values["after"]["rps"], values["speedup"],
    values["before"]["p95_ms"], values["after"]["p95_ms"]
  ]
end
