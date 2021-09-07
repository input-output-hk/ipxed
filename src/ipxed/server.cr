require "http/server"
require "crypto/subtle"
require "json"
require "uuid"

# iPXE Server
class Ipxed
  VERSION = "0.1.0"

  LOG = Log.for("iPXEd")

  FILE_MAPPING = {
    "netboot.ipxe" => "netbootIpxeScript",
    "bzImage"      => "kernel",
    "initrd"       => "netbootRamdisk",
  }

  property repos : Array(String)
  property host : String
  property port : Int32
  property token : String

  def initialize(@repos, @host, @port, @token, age_identity)
    if @token == ""
      LOG.warn { "No token given, everyone will have permission to build request." }
    end

    @ssh_provider = SshProvider.new(age_identity)
  end

  def run
    server = HTTP::Server.new do |ctx|
      params = ctx.request.query_params
      path = URI.decode(ctx.request.path)

      LOG.info { "Received request for #{path}" }

      # iPXE can also set params in the body
      if body = ctx.request.body
        URI::Params.parse(body.gets_to_end).each do |key, value|
          params[key] = value.strip if value.strip != ""
        end
      end

      LOG.info { "Received request for #{path}" }
      LOG.debug { "Params: #{params.inspect}" }

      case path
      when %r(^/ssh_key/?$)
        if uuid = parse_uuid(ctx, params)
          @ssh_provider.query(uuid) do |ssh_key|
            if ssh_key
              answer(ctx, HTTP::Status::OK, ssh_key)
            else
              answer(ctx, HTTP::Status::NOT_FOUND, "Not Found")
            end
          end
        end
      when %r(^/([^:]+:.+?)/([^/]+)/([^/]+)$)
        if uuid = parse_uuid(ctx, params)
          token = params["token"]?.to_s

          if Crypto::Subtle.constant_time_compare(token, @token)
            # Matches URLs like this:
            # github:owner/repo/nixosConfigurations.foobar/netboot.ipxe
            # path:/some/path/nixosConfigurations.foobar/netboot.ipxe
            flake, hostname, file = $1, $2, $3
            serve(ctx, uuid, repos, flake, hostname, file)
          else
            LOG.info { "Token doesn't match: #{path}" }
            answer(ctx, HTTP::Status::FORBIDDEN, "Forbidden")
          end
        end
      else
        LOG.info { "Not Found: #{path}" }
        answer(ctx, HTTP::Status::NOT_FOUND, "Not Found")
      end
    end

    address = server.bind_tcp @host, @port
    LOG.info { "Allowed repositories to build: #{@repos.join(" ")}" }
    LOG.info { "Listening on http://#{address}" }
    server.listen
  end

  def parse_uuid(ctx, params)
    UUID.new(params["uuid"]?.to_s)
  rescue e : ArgumentError
    answer(ctx, HTTP::Status::UNPROCESSABLE_ENTITY, e.to_s)
    nil
  end

  def build(flake, hostname, attr)
    flake_path = "#{flake}##{hostname}.config.system.build.#{attr}"

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

  def out_path(flake, hostname, attr, path)
    flake_path = "#{flake}##{hostname}.config.system.build.#{attr}.outPath"

    LOG.debug { "Evaluating #{flake_path}..." }

    output = IO::Memory.new
    status = Process.run(
      "nix",
      error: STDERR,
      output: output,
      args: [
        "eval",
        "#{flake}#deploy",
        "--impure",
        "--json",
        "--option", "tarball-ttl", "0",
        "--apply", %(
          (deploy:
            with builtins;
            let
              inherit (deploy.nodes.#{hostname}.profiles.system.path.base.config.system) build;
              attrs = [ "netbootIpxeScript" "kernel" "netbootRamdisk" ];
            in listToAttrs (map (name:
              let path = build.${name}.outPath;
              in {
                inherit name;
                value = seq (pathExists path) path;
              }) attrs))
      ),
      ]
    )

    if status.success?
      LOG.debug { "Evaluated #{flake_path}" }
    else
      raise "Failed to evaluate #{flake_path}: #{status.inspect}"
    end

    parsed = JSON.parse(output.to_s)

    "#{parsed[attr]}/#{path}"
  end

  def serve_file(ctx, flake, hostname, attr, path)
    result = out_path(flake, hostname, attr, path)
    size = File.size(result)
    ctx.response.content_length = size

    LOG.info &.emit("Sending", path: path, size: size.humanize)

    File.open(result) do |io|
      IO.copy(io, ctx.response)
    end
  end

  KEY_ROOT = Path.new("/home/manveru/github/input-output-hk/moe-ops/encrypted/ssh")

  def serve(ctx, uuid, repos, flake, hostname, file)
    attr = FILE_MAPPING[file]

    LOG.info &.emit("Checking", flake: flake)

    unless repos.any? { |repo| flake.starts_with?(repo) }
      return answer(ctx, HTTP::Status::FORBIDDEN, "This repo is not allowed")
    end

    @ssh_provider.allow(uuid, KEY_ROOT / "#{hostname}.age")

    LOG.info &.emit("Serving", flake: flake, hostname: hostname, file: file, attr: attr)

    serve_file(ctx, flake, hostname, attr, file)
  end

  def answer(ctx, status, body)
    ctx.response.content_type = "text/plain"
    ctx.response.status = status
    ctx.response.print body
    ctx.response.close
  end

  class SshProvider
    struct Entry
      property created_at : Time
      property key : Path
      property age_identity : Path

      def initialize(@key, @age_identity)
        @created_at = Time.utc
      end

      def decrypt
        mem = IO::Memory.new
        status = Process.run(
          "age",
          args: ["--decrypt", "--identity", age_identity.to_s, key.to_s],
          output: mem,
          error: STDERR,
        )
        mem.to_s
      end
    end

    TIMEOUT = 5.minutes

    def initialize(@age_identity : Path)
      @allowed_uuids = Hash(UUID, Entry).new
      @chan = Channel(Action).new
      spawn { run }
    end

    alias Action = Allow | Query

    struct Allow
      property uuid : UUID
      property key : Path

      def initialize(@uuid, @key); end
    end

    struct Query
      property uuid : UUID
      property callback : Channel(String?)

      def initialize(@uuid, @callback); end
    end

    private def run
      loop do
        clean

        select
        when action = @chan.receive
          pp! action
          case action
          in Allow
            @allowed_uuids[action.uuid] = Entry.new(action.key, @age_identity)
          in Query
            action.callback.send(ssh_key(action.uuid))
          end
        when timeout 10.seconds
        end
      end
    end

    private def ssh_key(uuid) : String?
      return unless entry = @allowed_uuids[uuid]?

      entry.decrypt
    ensure
      @allowed_uuids.delete uuid
    end

    private def clean
      cutoff = Time.utc - TIMEOUT
      old = @allowed_uuids.select do |uuid, entry|
        entry.created_at < cutoff
      end
      old.each do |uuid, entry|
        LOG.info { "expiring #{uuid} #{entry.inspect}" }
        @allowed_uuids.delete uuid
      end
    end

    def allow(uuid : UUID, key : Path)
      @chan.send Allow.new(uuid, key)
    end

    def query(uuid : UUID, &block : Proc(String?, Nil))
      res = Channel(String?).new
      @chan.send Query.new(uuid, res)
      yield res.receive
    end
  end
end
