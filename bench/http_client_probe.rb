#!/usr/bin/env ruby
require "json"
require "optparse"
require "socket"

require_relative "http_client"

options = {
  duration: 2.0,
  concurrency: 16,
  path: "/bench",
  body_bytes: 128,
  server_threads: 4
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby bench/http_client_probe.rb [options]"
  parser.on("--duration SECONDS", Float) { |value| options[:duration] = value }
  parser.on("--concurrency COUNT", Integer) { |value| options[:concurrency] = value }
  parser.on("--path PATH", String) { |value| options[:path] = value }
  parser.on("--body-bytes COUNT", Integer) { |value| options[:body_bytes] = value }
  parser.on("--server-threads COUNT", Integer) { |value| options[:server_threads] = value }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!

abort "--duration must be positive" unless options[:duration].positive?
abort "--concurrency must be positive" unless options[:concurrency].positive?
abort "--body-bytes must be positive" unless options[:body_bytes].positive?
abort "--server-threads must be positive" unless options[:server_threads].positive?

body = "x" * options[:body_bytes]
response = [
  "HTTP/1.1 200 OK\r\n",
  "Content-Type: text/plain\r\n",
  "Content-Length: #{body.bytesize}\r\n",
  "Connection: close\r\n",
  "\r\n",
  body
].join

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
running = true
workers = Array.new(options[:server_threads]) do
  Thread.new do
    Thread.current.report_on_exception = false
    while running
      begin
        socket = server.accept_nonblock
      rescue IO::WaitReadable
        begin
          IO.select([ server ], nil, nil, 0.05)
        rescue Errno::EBADF, IOError
          break
        end
        next
      rescue Errno::EBADF, IOError
        break
      end

      begin
        request = +""
        until request.include?("\r\n\r\n")
          chunk = socket.readpartial(1024)
          request << chunk
        end
        socket.write(response)
      rescue EOFError
      ensure
        socket.close
      end
    end
  end
end

client = BenchmarkHTTPClient.new("http://127.0.0.1:#{port}")
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = client.measure(options[:path], "", concurrency: options[:concurrency], duration: options[:duration])
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

running = false
server.close
workers.each(&:value)

output = {
  engine: defined?(RUBY_ENGINE) ? RUBY_ENGINE : "unknown",
  ruby_version: RUBY_VERSION,
  duration: options[:duration],
  concurrency: options[:concurrency],
  elapsed: elapsed,
  result: result
}
puts JSON.pretty_generate(output)
