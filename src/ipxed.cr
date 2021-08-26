require "./ipxed/*"
require "option_parser"

repos = [] of String
host = "0.0.0.0"
port = 7788

op = OptionParser.new do |parser|
  parser.banner = "Usage: ipxed [FLAGS]"

  parser.on "--allow=ALLOW", "comma separated list of repos to allow builds for (default: #{repos.join(",")})" do |value|
    repos = value.split(",").map(&.strip)
  end

  parser.on "--host=HOST", "Host to listen on (default: #{host})" do |value|
    host = value
  end

  parser.on "--port=PORT", "Port to listen on (default: #{port})" do |value|
    port = value.to_i
  end

  parser.on "-h", "--help", "Show this help" do
    puts parser
    exit
  end
end

op.parse

Ipxed.new(
  repos: repos,
  host: host,
  port: port,
).run
