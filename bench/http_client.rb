require "cgi"
require "net/http"
require "socket"

class BenchmarkHTTPClient
  def initialize(base)
    @base = URI(base)
  end

  def ready?
    connection.start { |http| http.get("/up").code == "200" }
  rescue IOError, SystemCallError, Timeout::Error, SocketError
    false
  end

  def login(labels)
    cookies = {}
    connection.start do |http|
      response = http.get("/session/new", "Accept-Encoding" => "identity")
      raise "sign-in page: HTTP #{response.code}" unless response.code == "200"
      merge_cookies(cookies, response)
      token = response.body[/<meta name="csrf-token" content="([^"]*)"/, 1]
      raise "sign-in page has no CSRF token" unless token
      request = Net::HTTP::Post.new("/session")
      request["Cookie"] = cookie_header(cookies)
      request["Origin"] = @base.to_s
      request["Sec-Fetch-Site"] = "same-origin"
      request.set_form_data(email_address: labels.fetch("emails.david"), password: labels.fetch("passwords.all"),
        authenticity_token: CGI.unescapeHTML(token))
      response = http.request(request)
      merge_cookies(cookies, response)
      raise "login failed: HTTP #{response.code}" unless response.code == "302" && cookies.key?("session_token")
    end
    cookie_header(cookies)
  end

  def measure(path, cookie, concurrency:, duration:)
    start = clock
    deadline = start + duration
    workers = Array.new(concurrency) do
      Thread.new do
        result = { latencies: [], statuses: Hash.new(0), bytes: 0, errors: 0 }
        while clock < deadline
          begin
            connection.start do |http|
              while clock < deadline
                requested = clock
                response = http.get(path, "Cookie" => cookie, "Accept-Encoding" => "identity")
                result[:latencies] << (clock - requested) * 1000
                result[:statuses][response.code] += 1
                result[:bytes] += response.body.bytesize
              end
            end
          rescue IOError, SystemCallError, Timeout::Error, SocketError, Net::HTTPBadResponse
            result[:errors] += 1
            sleep 0.01
          end
        end
        result
      end
    end
    samples = workers.map(&:value)
    elapsed = clock - start
    latencies = samples.flat_map { |sample| sample[:latencies] }.sort
    statuses = Hash.new(0)
    samples.each { |sample| sample[:statuses].each { |status, count| statuses[status] += count } }
    errors = samples.sum { |sample| sample[:errors] }
    raise "#{path}: HTTP statuses #{statuses}, #{errors} transport errors" unless errors.zero? && statuses.keys == [ "200" ]
    { path: path, conc: concurrency, gzip: false, secs: elapsed, rps: latencies.size / elapsed,
      ok: latencies.size, statuses: statuses, errors: errors,
      avg_bytes: samples.sum { |sample| sample[:bytes] } / latencies.size,
      latency_ms: { p50: percentile(latencies, 0.50), p95: percentile(latencies, 0.95), p99: percentile(latencies, 0.99) } }
  end

  private
    def connection
      Net::HTTP.new(@base.host, @base.port, nil).tap do |http|
        http.open_timeout = 1
        http.read_timeout = 5
        http.write_timeout = 5
        http.max_retries = 0
      end
    end

    def merge_cookies(cookies, response)
      response.get_fields("set-cookie").to_a.each do |header|
        name, value = header.split(";", 2).first.split("=", 2)
        cookies[name] = value
      end
    end

    def cookie_header(cookies)
      cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
    end

    def percentile(values, fraction)
      values[(values.size * fraction).ceil - 1]
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end

class BenchmarkSocketHTTPClient
  def initialize(base)
    @base = URI(base)
  end

  def login(email, password)
    response = request("GET", "/session/new")
    token = response[:body][/<meta name="csrf-token" content="([^"]*)"/, 1]
    raise "sign-in page has no CSRF token" unless token
    cookie = response[:cookies].join("; ")
    form = URI.encode_www_form(email_address: email, password: password, authenticity_token: CGI.unescapeHTML(token))
    response = request("POST", "/session", cookie, form, "application/x-www-form-urlencoded")
    raise "login failed: HTTP #{response[:status]}" unless response[:status] == "302"
    ([ cookie ] + response[:cookies]).reject(&:empty?).join("; ")
  end

  def measure(path, cookie, concurrency:, duration:, method: "GET", body: nil, success_codes: [ "200" ], accept: nil)
    start = clock
    deadline = start + duration
    workers = Array.new(concurrency) do
      Thread.new do
        result = { latencies: [], statuses: Hash.new(0), bytes: 0, errors: 0, failures: [] }
        while clock < deadline
          begin
            requested = clock
            response = request(method, path, cookie, body, nil, accept)
            result[:latencies] << (clock - requested) * 1000
            result[:statuses][response[:status]] += 1
            result[:bytes] += response[:body].bytesize
            result[:failures] << "#{response[:status]}: #{response[:body][0, 200]}" unless success_codes.include?(response[:status])
          rescue IOError, SystemCallError, Timeout::Error, SocketError
            result[:errors] += 1
            sleep 0.01
          end
        end
        result
      end
    end
    samples = workers.map(&:value)
    elapsed = clock - start
    latencies = samples.flat_map { |sample| sample[:latencies] }.sort
    statuses = Hash.new(0)
    samples.each { |sample| sample[:statuses].each { |status, count| statuses[status] += count } }
    errors = samples.sum { |sample| sample[:errors] }
    failures = samples.flat_map { |sample| sample[:failures] }.uniq
    raise "#{path}: HTTP statuses #{statuses}, #{errors} transport errors#{": #{failures.join('; ')}" unless failures.empty?}" unless errors.zero? && (statuses.keys - success_codes).empty?
    { path: path, conc: concurrency, gzip: false, secs: elapsed, rps: latencies.size / elapsed,
      ok: latencies.size, statuses: statuses, errors: errors,
      avg_bytes: samples.sum { |sample| sample[:bytes] } / latencies.size,
      latency_ms: { p50: percentile(latencies, 0.50), p95: percentile(latencies, 0.95), p99: percentile(latencies, 0.99) } }
  end

  private
    def request(method, path, cookie = nil, body = nil, content_type = nil, accept = nil)
      socket = TCPSocket.new(@base.host, @base.port)
      headers = [ "#{method} #{path} HTTP/1.1", "Host: #{@base.host}", "Connection: close" ]
      headers << "Cookie: #{cookie}" if cookie
      headers << "Accept: #{accept}" if accept
      if body
        headers << "Content-Type: #{content_type || 'application/x-www-form-urlencoded'}"
        headers << "Content-Length: #{body.bytesize}"
      end
      socket.write((headers + [ "", body.to_s, "" ]).join("\r\n"))
      response = socket.read
      head, body = response.split("\r\n\r\n", 2)
      lines = head.to_s.split("\r\n")
      cookies = lines.select { |line| line.downcase.start_with?("set-cookie:") }
        .map { |line| line.split(":", 2).last.split(";", 2).first.strip }
      { status: lines.first.to_s.split(" ", 3)[1], body: body.to_s, cookies: cookies }
    ensure
      socket&.close
    end

    def percentile(values, fraction)
      values[(values.size * fraction).ceil - 1]
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
