desc "Install/run directory server"
namespace :dir_server do

  desc "Run log_server/n directory server"
  task :run do
    system "go/bin/runner -conf config/dea.yml"
  end

  desc "Install directory server"
  task :install do
    result = system "PATH=$PATH:/usr/local/go/bin go install runner"
    raise "Installation failed" unless result
  end
end
