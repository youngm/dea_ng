require "yaml"
require "net/ssh"
require "shellwords"

require_relative "process_helpers"
require_relative "local_ip_finder"
require_relative "deployed_job"

require "dea/config"

module DeaHelpers
  def is_port_open?(ip, port)
    begin
      Timeout::timeout(5) do
        begin
          s = TCPSocket.new(ip, port)
          s.close
          return true
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
          return false
        end
      end
    rescue Timeout::Error
      raise "Timed out attempting to connect to #{ip}:#{port}"
    end

    return false
  end

  def instance_snapshot(instance_id)
    instances_json["instances"].find do |instance|
      instance["instance_id"] == instance_id
    end
  end

  def dea_host
    dea_server.host || raise("unknown dea host")
  end

  def dea_id
    nats.request("dea.status", {
        "limits" => {"mem" => 1, "disk" => 1}
    })["id"]
  end

  def dea_memory
    # Use NATS to locate the only DEA running as part of this integration test.
    response = nats.with_subscription("dea.advertise") do
      nats.publish("dea.locate", {}, :async => true)
    end

    response["available_memory"]
  end

  def dea_pid
    dea_server.pid
  end

  def evacuate_dea
    dea_server.evacuate
    sleep evacuation_delay
  end

  def evacuation_delay
    dea_config["evacuation_delay_secs"]
  end

  def start_file_server
    @file_server_pid = run_cmd("bundle exec ruby spec/bin/file_server.rb", :debug => true)

    wait_until { is_port_open?("127.0.0.1", 10197) }
  end

  def stop_file_server
    graceful_kill(@file_server_pid) if @file_server_pid
  end

  def file_server_address
    "#{fake_file_server.host}:10197"
  end

  def dea_start
    dea_server.start

    Timeout.timeout(10) do
      while true
        begin
          response = nats.request("dea.status", {}, :timeout => 1)
          break if response
        rescue NATS::ConnectError, Timeout::Error
          # Ignore because either NATS is not running, or DEA is not running.
        end
      end
    end
  end

  def dea_stop
    dea_server.stop
  end

  def sha1_url(url)
    `curl --silent #{url} | shasum`.split(/\s/).first
  end

  def wait_until_instance_started(app_id, timeout = 60)
    response = nil
    wait_until(timeout) do
      response = nats.request("dea.find.droplet", {
          "droplet" => app_id,
          "states" => ["RUNNING"]
      }, :timeout => 1)
    end
    response
  end

  def wait_until_instance_gone(app_id, timeout = 60)
    wait_until(timeout) do
      res = nats.request("dea.find.droplet", {
          "droplet" => app_id,
      }, :timeout => 1)

      sleep 1

      !res || res["state"] == "CRASHED"
    end
  end

  def wait_until(timeout = 5, &block)
    Timeout.timeout(timeout) do
      loop { return if block.call }
    end
  end

  def nats
    NatsHelper.new(dea_config)
  end

  def instances_json
    JSON.parse(dea_server.instance_file)
  end

  def fake_file_server
    @fake_file_server ||=
      if ENV["LOCAL_DEA"]
        LocalFileServer.new
      else
        RemoteFileServer.new
      end
  end

  def dea_server
    @dea_server ||=
      if ENV["LOCAL_DEA"]
        LocalDea.new
      else
        RemoteDea.new
      end
  end

  def dea_config
    @dea_config ||= dea_server.config
  end

  class LocalDea
    include ProcessHelpers

    def host
      LocalIPFinder.new.find
    end

    def start
      f = File.new("/tmp/dea.yml", "w")
      f.write(YAML.dump(config))
      f.close

      run_cmd "mkdir -p tmp/logs && bundle exec bin/dea #{f.path} 2>&1 >>tmp/logs/dea.log"
    end

    def stop
      graceful_kill(pid) if pid
    end

    def pid
      File.read(config["pid_filename"]).to_i
    end

    def directory_entries(path)
      Dir.entries(path)
    end

    def config
      @config ||= begin
        config = YAML.load(File.read("config/dea.yml"))
        config["domain"] = LocalIPFinder.new.find.ip_address+".xip.io"
        config
      end
    end

    def instance_file
      File.read File.join(config["base_dir"], "db", "instances.json")
    end

    def evacuate
      stop
    end
  end

  class RemoteDea < DeployedJob
    def host
      "10.244.0.6"
    end

    def start
      remote_exec("monit start dea_next")
    end

    def stop
      remote_exec("monit stop dea_next")
    end

    def pid
      remote_exec("cat #{config["pid_filename"]}").to_i
    end

    def evacuate
      remote_exec("kill -USR2 #{pid}")
    end

    def instance_file
      remote_file(File.join(config["base_dir"], "db", "instances.json"))
    end

    def config
      @config ||= begin
        config_yaml = YAML.load(remote_file("/var/vcap/jobs/dea_next/config/dea.yml"))
        Dea::Config.new(config_yaml).tap(&:validate)
      end
    end
  end

  class LocalFileServer
    def host
      LocalIPFinder.new.find
    end

    def has_droplet?(name)
      File.exists?(file_path(name))
    end

    def remove_droplet(name)
      FileUtils.rm_f(file_path(name))
    end

    def has_buildpack_cache?
      File.exists?(file_path("buildpack_cache.tgz"))
    end

    def remove_buildpack_cache
      FileUtils.rm_f(file_path("buildpack_cache.tgz"))
    end

    private

    def file_path(name)
      File.join(FILE_SERVER_DIR, name)
    end
  end

  class RemoteFileServer < DeployedJob
    def host
      "10.244.0.10"
    end

    def has_droplet?(name)
      file_exists?(file_path(name))
    end

    def remove_droplet(name)
      remote_exec("rm #{file_path(name)}")
    end

    def has_buildpack_cache?
      file_exists?(file_path("buildpack_cache.tgz"))
    end

    def remove_buildpack_cache
      remote_exec("rm #{file_path("buildpack_cache.tgz")}")
    end

    private

    def file_path(name)
      File.join(FILE_SERVER_DIR, name)
    end
  end
end
