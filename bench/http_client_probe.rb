#!/usr/bin/env ruby
require "json"
require "optparse"

require_relative "http_client"

options = {
  base: "http://127.0.0.1:3000",
  email: nil,
  password: nil,
  room: nil,
  before: nil,
  duration: 2.0,
  concurrency: 16
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby bench/http_client_probe.rb [options]"
  parser.on("--base URL", String) { |value| options[:base] = value }
  parser.on("--email EMAIL", String) { |value| options[:email] = value }
  parser.on("--password PASSWORD", String) { |value| options[:password] = value }
  parser.on("--room ID", Integer) { |value| options[:room] = Integer(value) }
  parser.on("--before ID", Integer) { |value| options[:before] = Integer(value) }
  parser.on("--duration SECONDS", Float) { |value| options[:duration] = Float(value) }
  parser.on("--concurrency COUNT", Integer) { |value| options[:concurrency] = Integer(value) }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!

abort "--email, --password, --room and --before are required" unless options.values_at(:email, :password, :room, :before).all?
abort "--duration must be positive" unless options[:duration].positive?
abort "--concurrency must be positive" unless options[:concurrency].positive?

client = BenchmarkSocketHTTPClient.new(options[:base])
cookie = client.login(options[:email], options[:password])
room = options[:room]
before = options[:before]
message_body = "message%5Bbody%5D=Spinel+benchmark"
benchmarks = {
  "room" => { method: "GET", path: "/rooms/#{room}" },
  "messages" => { method: "GET", path: "/rooms/#{room}/messages?before=#{before}" },
  "sidebar" => { method: "GET", path: "/users/me/sidebar" },
  "search" => { method: "GET", path: "/searches?q=coffee" },
  "post_message" => { method: "POST", path: "/rooms/#{room}/messages", body: message_body,
                       success_codes: [ "200", "201", "202", "204" ], accept: "text/vnd.turbo-stream.html" }
}

results = {}
benchmarks.each do |name, benchmark|
  results[name] = client.measure(benchmark.fetch(:path), cookie,
    concurrency: options[:concurrency], duration: options[:duration], method: benchmark.fetch(:method),
    body: benchmark[:body], success_codes: benchmark.fetch(:success_codes, [ "200" ]), accept: benchmark[:accept])
end

puts JSON.pretty_generate(
  engine: defined?(RUBY_ENGINE) ? RUBY_ENGINE : "unknown",
  ruby_version: RUBY_VERSION,
  duration: options[:duration],
  concurrency: options[:concurrency],
  results: results
)
