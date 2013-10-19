module DeaHelpers
  class DeployedJob 
    def remote_file(path)
      remote_exec("cat #{path}")
    end

    def directory_entries(path)
      remote_exec("ruby -e \"puts Dir.entries('#{path}')\"").split("\n")
    end

    def file_exists?(path)
      remote_exec("[ -f '#{path}' ]; echo $?").chomp == "0"
    end

    def remote_exec(cmd)
      Net::SSH.start(host, username, :password => password) do |ssh|
        result = ""

        ssh.open_channel do |ch|
          ch.request_pty do |ch, success|
            raise "could not open pty" unless success

            ch.exec("sudo bash -ic #{Shellwords.escape(cmd)}")

            ch.on_data do |_, data|
              if data =~ /^\[sudo\] password for #{username}:/
                ch.send_data("#{password}\n")
              else
                result << data
              end
            end
          end
        end

        ssh.loop

        return result
      end
    end

    private

    def username
      "vcap"
    end

    def password
      "c1oudc0w"
    end
  end
end