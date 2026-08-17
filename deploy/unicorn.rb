require 'securerandom'
@cur = File.dirname(File.realpath(__FILE__))
@dir = File.realpath(File.join(@cur,".."))

# Scope the restrictive ImageMagick policy to this Unicorn process. Replacing
# /etc/ImageMagick/policy.xml would also affect the other Kagetra environments
# hosted on the same server.
@imagemagick_config = File.join(@dir,"config","imagemagick")
raise "ImageMagick policy is missing" unless File.file?(File.join(@imagemagick_config,"policy.xml"))
ENV["MAGICK_CONFIGURE_PATH"] = @imagemagick_config

worker_processes 4
working_directory @dir

timeout 600

listen "#{@cur}/sock/unicorn.sock", backlog: 64
pid "#{@cur}/pid/unicorn.pid"

stderr_path "#{@cur}/log/unicorn.err.log"
stdout_path "#{@cur}/log/unicorn.out.log"

@session_secret = SecureRandom.base64(48)
before_fork do | server, worker |
  # share session_secret between worker processes
  ENV["RACK_SESSION_SECRET"] = @session_secret
end
