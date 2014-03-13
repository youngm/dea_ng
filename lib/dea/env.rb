# coding: UTF-8

require "steno"
require "steno/core_ext"
require "yajl"

require "dea/staging/staging_task"

require "dea/starting/database_uri_generator"
require "dea/staging/env"
require "dea/starting/env"
require "dea/env_exporter"
require "dea/env_strategy_chooser"

module Dea
  class Env
    WHITELIST_SERVICE_KEYS = %W[name label tags plan plan_option credentials syslog_drain_url].freeze

    attr_reader :strategy_env

    def initialize(message, instance_or_staging_task, env_exporter = EnvExporter, env_strategy_chooser = EnvStrategyChooser.new(message, instance_or_staging_task))
      @env_exporter = env_exporter
      @strategy_env = env_strategy_chooser.strategy
    end

    def message
      strategy_env.message
    end

    def exported_system_environment_variables
      to_export(system_environment_variables)
    end

    def exported_user_environment_variables
      to_export(user_environment_variables)
    end

    def exported_environment_variables
      to_export(system_environment_variables + user_environment_variables)
    end

    private

    def user_environment_variables
      translate_env(message.env)
    end

    def system_environment_variables
      env = [
        ["VCAP_APPLICATION",  Yajl::Encoder.encode(vcap_application)],
        ["VCAP_SERVICES",     Yajl::Encoder.encode(vcap_services)],
        ["MEMORY_LIMIT", "#{message.mem_limit}m"]
      ]
      env << ["DATABASE_URL", DatabaseUriGenerator.new(message.services).database_uri] if message.services.any?

      env + strategy_env.system_environment_variables
    end

    def vcap_services
      @vcap_services ||=
        begin
          services_hash = Hash.new { |h, k| h[k] = [] }

          message.services.each do |service|
            service_hash = {}
            WHITELIST_SERVICE_KEYS.each do |key|
              service_hash[key] = service[key] if service[key]
            end

            services_hash[service["label"]] << service_hash
          end

          services_hash
        end
    end

    def vcap_application
      @vcap_application ||=
        begin
          hash = strategy_env.vcap_application

          hash["limits"] = message.limits
          hash["application_version"] = message.version
          hash["application_name"] = message.name
          hash["application_uris"] = message.uris
          # Translate keys for backwards compatibility
          hash["version"] = hash["application_version"]
          hash["name"] = hash["application_name"]
          hash["uris"] = hash["application_uris"]
          hash["users"] = hash["application_users"]

          hash
        end
    end

    def translate_env(env)
      env ? env.map { |e| e.split("=", 2) } : []
    end

    def to_export(env)
      @env_exporter.new(env).export
    end
  end
end
