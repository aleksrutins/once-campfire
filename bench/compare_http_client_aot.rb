#!/usr/bin/env ruby
require "json"
require "fileutils"
require "open3"
require "optparse"

ROOT = File.expand_path("..", __dir__)
WORK = File.join(ROOT, "tmp/rails-optimization")

options = {
  duration: 2.0,
  concurrencies: "1,16",
  rounds: 6,
  output: File.join(WORK, "results/spinel-aot"),
  spinel: "spinel"
}

parser = OptionParser.new do |parser|
  parser.banner = "Usage: ruby bench/compare_http_client_aot.rb [options]"
  parser.on("--duration SECONDS", Float) { |value| options[:duration] = value }
  parser.on("--concurrencies CSV", String) { |value| options[:concurrencies] = value }
  parser.on("--rounds COUNT", Integer) { |value| options[:rounds] = value }
  parser.on("--output PATH", String) { |value| options[:output] = value }
  parser.on("--spinel PATH", String) { |value| options[:spinel] = value }
  parser.on("-h", "--help") { puts parser; exit }
end

begin
  parser.parse!
rescue OptionParser::ParseError => error
  abort "#{error.message}\n#{parser}"
end

abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
abort "--duration must be positive" unless options[:duration].positive?
abort "--rounds must be even and at least 2" unless options[:rounds] >= 2 && options[:rounds].even?

concurrencies = options[:concurrencies].split(",").map { |value| Integer(value) }
abort "--concurrencies must be positive" if concurrencies.empty? || concurrencies.any?(&:negative?) || concurrencies.any?(&:zero?)

spinel_output = File.join(WORK, "spinel")
probe_source = File.join(ROOT, "bench/http_client_probe.rb")
native_probe = File.join(spinel_output, "http_client_probe")
FileUtils.mkdir_p(spinel_output)
FileUtils.mkdir_p(options[:output])

run = lambda do |*command|
  output, errors, status = Open3.capture3(*command)
  raise "#{command.first} failed (#{status.exitstatus}): #{errors}" unless status.success?
  output
end

begin
  run.call(options[:spinel], "--version")
rescue StandardError
  abort "spinel is required. Install from github.com/matz/spinel or pass --spinel PATH"
end

run.call(options[:spinel], probe_source, "-o", native_probe)

runs = { "ruby" => [], "native" => [] }
order = []
options[:rounds].times do |iteration|
  sides = iteration.even? ? %w[ruby native] : %w[native ruby]
  order << sides
  sides.each do |side|
    command = if side == "ruby"
      [ "ruby", probe_source ]
    else
      [ native_probe ]
    end

    data = {
      "concurrency" => {},
      "elapsed" => 0.0,
      "engine" => nil,
      "ruby_version" => nil
    }

    concurrencies.each do |concurrency|
      result = JSON.parse(run.call(*command, "--duration", options[:duration].to_s, "--concurrency", concurrency.to_s))
      data["concurrency"][concurrency.to_s] = result.fetch("result")
      data["elapsed"] += result.fetch("elapsed")
      data["engine"] = result.fetch("engine")
      data["ruby_version"] = result.fetch("ruby_version")
    end

    runs[side] << data
    File.write(File.join(options[:output], "#{side}-#{iteration + 1}.json"), JSON.pretty_generate(data) + "\n")
    puts "#{iteration + 1}/#{options[:rounds]}: #{side}"
  end
end

median = lambda do |values|
  sorted = values.sort
  middle = sorted.length / 2
  sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end

summary = {
  metadata: {
    order: order,
    duration: options[:duration],
    concurrencies: concurrencies,
    rounds: options[:rounds],
    spinel: run.call(options[:spinel], "--version").strip,
    ruby: run.call("ruby", "-v").strip
  },
  results: {}
}

concurrencies.each do |concurrency|
  key = concurrency.to_s
  ruby_rps = runs["ruby"].map { |row| row.fetch("concurrency").fetch(key).fetch("rps") }
  native_rps = runs["native"].map { |row| row.fetch("concurrency").fetch(key).fetch("rps") }
  ruby_p95 = runs["ruby"].map { |row| row.fetch("concurrency").fetch(key).dig("latency_ms", "p95") }
  native_p95 = runs["native"].map { |row| row.fetch("concurrency").fetch(key).dig("latency_ms", "p95") }

  summary[:results][key] = {
    ruby: { rps: median.call(ruby_rps), p95_ms: median.call(ruby_p95) },
    native: { rps: median.call(native_rps), p95_ms: median.call(native_p95) },
    speedup: median.call(native_rps) / median.call(ruby_rps)
  }
end

File.write(File.join(options[:output], "summary.json"), JSON.pretty_generate(summary) + "\n")
summary[:results].each do |concurrency, values|
  puts "concurrency #{concurrency}: %.0f -> %.0f rps (%.2fx), p95 %.2f -> %.2f ms" % [
    values.dig(:ruby, :rps),
    values.dig(:native, :rps),
    values[:speedup],
    values.dig(:ruby, :p95_ms),
    values.dig(:native, :p95_ms)
  ]
end
