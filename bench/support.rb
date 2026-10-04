require "fileutils"
require "json"
require "open3"
require "optparse"

module BenchmarkSupport
  ROOT = File.expand_path("..", __dir__)
  WORK = File.join(ROOT, "tmp/rails-optimization")

  def parse_options(description, defaults)
    options = { baseline: nil, seed: nil, image: "campfire-reference:app", cpus: "8-11", rounds: 2 }.merge(defaults)
    parser = OptionParser.new do |parser|
      parser.banner = "Usage: ruby #{$PROGRAM_NAME} --baseline PATH --seed PATH [options]\n#{description}"
      options.each do |name, default|
        type = case default
        when Integer then Integer
        when Float then Float
        else String
        end
        parser.on("--#{name.to_s.tr('_', '-')} VALUE", type) { |value| options[name] = value }
      end
      parser.on("-h", "--help") { puts parser; exit }
    end
    parser.parse!
    raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
    raise OptionParser::MissingArgument, "--baseline and --seed are required" unless options[:baseline] && options[:seed]
    raise OptionParser::InvalidArgument, "--rounds must be even and at least 2" unless options[:rounds] >= 2 && options[:rounds].even?
    %i[baseline seed output].each { |name| options[name] = File.expand_path(options.fetch(name)) }
    options
  rescue OptionParser::ParseError => error
    abort "#{error.message}\n#{parser}"
  end

  def run(*command, input: nil)
    output, errors, status = Open3.capture3(*command, stdin_data: input, binmode: true)
    raise "#{command.first} failed (#{status.exitstatus}): #{errors}" unless status.success?
    output
  end

  def remove_container(name)
    Open3.capture3("docker", "rm", "-f", name)
  end

  def prepare_storage(seed, destination)
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination)
    FileUtils.cp_r(File.join(seed, "db"), File.join(destination, "db"))
    FileUtils.cp_r(File.join(seed, "storage"), File.join(destination, "files"))
  end

  def prepare_assets(image)
    assets = File.join(WORK, "runtime/assets")
    FileUtils.mkdir_p(assets)
    if Dir.empty?(assets)
      archive = run("docker", "run", "--rm", "--entrypoint", "", image,
        "tar", "-C", "/rails/public/assets", "-cf", "-", ".")
      run("tar", "-xf", "-", "-C", assets, input: archive)
    end
    assets
  end

  def mounts(paths)
    paths.flat_map { |host, target| [ "-v", "#{host}:#{target}" ] }
  end

  def environment(values)
    values.flat_map { |name, value| [ "-e", "#{name}=#{value}" ] }
  end

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data) + "\n")
  end

  def median(values)
    values = values.sort
    middle = values.length / 2
    values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
  end

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
