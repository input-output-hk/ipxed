require "http/server"
require "crypto/subtle"

# iPXE Server
class Ipxed
  VERSION = "0.1.0"

  LOG = Log.for("ipxe")

  FILE_MAPPING = {
    "netboot.ipxe" => "netbootIpxeScript",
    "bzImage"      => "kernel",
    "initrd"       => "netbootRamdisk",
  }

  property repos : Array(String)
  property host : String
  property port : Int32
  property token : String
  property period : Int32

  @anonMode : Bool
  @authorizedUntil = Hash(String, Int64).new


  def initialize(@repos, @host, @port, @token, @period)
    if @token == ""
      LOG.warn { "No token given, everyone will have permission to build request." }
      @anonMode = true
    else
      @anonMode = false
    end
    LOG.info { "Period: #{@period}" }
  end

  def run
    server = HTTP::Server.new do |ctx|
      authenticated = false
      params = ctx.request.query_params
      token = params["token"]?.to_s

      # Obtain the real IP of the request track an authenticated time window
      ipPort = ctx.request.remote_address
      xRealIp = ctx.request.headers["X-Real-IP"]?
      ip = Socket::IPAddress.parse("tcp://#{real_ip_port(xRealIp) || ipPort}").address

      if @anonMode == false && Crypto::Subtle.constant_time_compare(token, @token)
        authenticated = true
        @authorizedUntil[ip] = Time.utc.to_unix + @period
      elsif @authorizedUntil.has_key?(ip) && @authorizedUntil[ip] > Time.utc.to_unix
        authenticated = true
      elsif @authorizedUntil.has_key?(ip) && @authorizedUntil[ip] < Time.utc.to_unix
        @authorizedUntil.delete(ip)
      end

      path = URI.decode(ctx.request.path)
      authRemaining = @authorizedUntil.has_key?(ip) ? (@authorizedUntil[ip] - Time.utc.to_unix).to_s : "N/A"
      LOG.info { "Request {anonMode: #{@anonMode}, auth: #{authenticated}, authRemaining: #{authRemaining}, IP: #{ip}, path: #{path}" }

      if @anonMode || authenticated
        # Matches URLs like this:
        # github:owner/repo/nixosConfigurations.foobar/netboot.ipxe
        # path:/some/path/nixosConfigurations.foobar/netboot.ipxe
        case path
        when %r(^/([^:]+:.+?)/([^/]+)/([^/]+)$)
          flake, system, file = $1, $2, $3
          serve(ctx, repos, flake, system, file)
        else
          answer(ctx, HTTP::Status::NOT_FOUND, "Not Found")
        end
      else
        answer(ctx, HTTP::Status::FORBIDDEN, "Forbidden")
      end
    end

    address = server.bind_tcp @host, @port
    LOG.info { "Allowed repositories to build: #{@repos.join(" ")}" }
    LOG.info { "Listening on http://#{address}" }
    server.listen
  end

  def build(flake, system, attr)
    flake_path = "#{flake}##{system}.config.system.build.#{attr}"

    LOG.debug { "Building #{flake_path}..." }

    status = Process.run("nix", error: STDERR, args: [
      "-L", "build", "--option", "tarball-ttl", "0", "--no-link", flake_path,
    ])

    if status.success?
      LOG.debug { "Built #{flake_path}" }
    else
      raise "Failed to build #{flake_path}: #{status.inspect}"
    end
  end

  def out_path(flake, system, attr)
    build(flake, system, attr)

    flake_path = "#{flake}##{system}.config.system.build.#{attr}.outPath"

    LOG.debug { "Evaluating #{flake_path}..." }

    output = IO::Memory.new
    status = Process.run("nix", error: STDERR, output: output, args: ["eval", "--raw", flake_path])

    if status.success?
      LOG.debug { "Evaluated #{flake_path}" }
    else
      raise "Failed to evaluate #{flake_path}: #{status.inspect}"
    end

    output.to_s
  end

  def serve_file(ctx, flake, system, attr, path)
    result = "#{out_path(flake, system, attr)}/#{path}"
    size = File.size(result)
    ctx.response.content_length = size

    LOG.info &.emit("Sending", path: path, size: size.humanize)

    File.open(result) do |io|
      IO.copy(io, ctx.response)
    end
  end

  def serve(ctx, repos, flake, system, file)
    attr = FILE_MAPPING[file]

    LOG.info &.emit("Checking", flake: flake)

    unless repos.any? { |repo| flake.starts_with?(repo) }
      return answer(ctx, HTTP::Status::FORBIDDEN, "This repo is not allowed")
    end

    LOG.info &.emit("Serving", flake: flake, system: system, file: file, attr: attr)

    serve_file(ctx, flake, system, attr, file)
  end

  def answer(ctx, status, body)
    ctx.response.content_type = "text/plain"
    ctx.response.status = status
    ctx.response.print body
    ctx.response.close
  end

  def real_ip_port(header : String) : String
    "#{header}:443"
  end

  def real_ip_port(header : Nil) : Nil
  end
end
