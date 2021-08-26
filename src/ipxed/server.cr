require "http/server"

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

  def initialize(@repos, @host, @port)
  end

  def run
    server = HTTP::Server.new do |ctx|
      url = URI.decode(ctx.request.resource)

      LOG.info { "Received request for #{url}" }

      # Matches URLs like this:
      # github:owner/repo/nixosConfigurations.foobar/netboot.ipxe
      # path:/some/path/nixosConfigurations.foobar/netboot.ipxe
      case url
      when %r(^/([^:]+:.+?)/([^/]+)/([^/]+)$)
        flake, system, file = $1, $2, $3
        serve(ctx, repos, flake, system, file)
      else
        answer(ctx, HTTP::Status::NOT_FOUND, "Not Found")
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

    status = Process.run("nix", error: STDERR, args: ["-L", "build", "--no-link", flake_path])

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

    unless repos.includes?(flake)
      answer(ctx, HTTP::Status::FORBIDDEN, "This repo is not allowed")
    end

    LOG.info &.emit("Serving", flake: flake, system: system, file: file, attr: attr)

    serve_file(ctx, flake, system, attr, file)
  end

  def answer(ctx, status, body)
    ctx.response.content_type = "text/plain"
    ctx.response.status = status
    ctx.response.print body
  end
end
