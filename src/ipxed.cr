require "./ipxed/*"
require "option_parser"

repos = [] of String
host = "0.0.0.0"
port = 7788
age_identity = Path["/run/keys/ipxe_age.key"]
token = if token_file = ENV["IPXED_TOKEN_FILE"]?
          File.read(token_file).strip
        else
          ""
        end

op = OptionParser.new do |parser|
  parser.banner = "Usage: ipxed [FLAGS]"

  parser.on "--allow=ALLOW", "comma separated list of repos to allow builds for (default: #{repos.join(",")})" do |value|
    repos = value.split(",").map(&.strip)
  end

  parser.on "--token=TOKEN", "Secret token to be able to use the API" do |value|
    token = value
  end

  parser.on "--host=HOST", "Host to listen on (default: #{host})" do |value|
    host = value
  end

  parser.on "--port=PORT", "Port to listen on (default: #{port})" do |value|
    port = value.to_i
  end

  parser.on "--age=KEY", "The path to the age identity file (default: #{age_identity})" do |value|
    age_identity = Path[value]
  end

  parser.on "-h", "--help", "Show this help" do
    puts parser
    exit
  end
end

op.parse

Log.setup_from_env

Ipxed.new(
  repos: repos,
  host: host,
  port: port,
  token: token,
  age_identity: age_identity,
).run
