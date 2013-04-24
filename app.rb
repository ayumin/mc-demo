require 'uri'

class App < Sinatra::Base
  MOTHERSHIP = ENV['MOTHERSHIP_APP_NAME'] || 'mc-control'
  #BLACKLIST  = (ENV['MOTHERSHIP_ENV_BLACKLIST'] || 'REDISGREEN_URL,REDISTOGOURL').split(',')
  L2TEMPO  = 'l2tempo'
  L2CRM    = 'l2crm'
  L2AIRSHIP = 'l2airship'
  CONSUMER = 'mc-consumer'

  def heroku
    @heroku ||= Heroku::API.new
  end

  def redis
    @redis ||= begin
      mothership_env_h = heroku.get_config_vars(MOTHERSHIP).body
      redis_url_env_name = mothership_env_h['REDIS_NAME']
      redis_url = mothership_env_h[redis_url_env_name]
      uri   = URI.parse(redis_url)
      Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
    end
  end

  get '/' do
    @mothership_name = MOTHERSHIP
    @mothership_env_h = heroku.get_config_vars(MOTHERSHIP).body
    @mothership_env   = @mothership_env_h.to_a.sort_by!{ |key,_v| key }
    @mothership_procs = heroku.get_ps(MOTHERSHIP).body.to_a
    @monitors      = @mothership_procs.select{ |p| p['process'] =~ /^monitor\./ }
    @monitor_count = @monitors.size
    @warn_monitors = @monitors.size != 1
    @web       = @mothership_procs.select{ |p| p['process'] =~ /^web\./ }
    @web_count = @web.size
    @warn_web  = @web_count == 0
    @devices   = @mothership_procs.select{ |p| p['process'] =~ /uuid_sensor/ }
    @up_devices = @devices.select{ |p| p['state'] =~ /up|start/ }.size
    @device_density = @mothership_env_h['SENSORS'].to_i
    @device_count = @up_devices * @device_density
    @l2tempo_env_h = heroku.get_config_vars(L2TEMPO).body
    @l2tempo_env   = @l2tempo_env_h.to_a.sort_by!{ |key,_v| key }
    @warn_l2tempo  = (@mothership_env_h['TEMPODB_API_KEY'] != @l2tempo_env_h['TEMPODB_API_KEY']) ||
                     (@mothership_env_h['TEMPODB_API_SECRET'] != @l2tempo_env_h['TEMPODB_API_SECRET'])
    @redis_keys = redis.keys.size
    slim :index
  end

  use Rack::Auth::Basic, "Restricted Area" do |username, password|
    username == "heroku" && password == ENV["HTTP_PASSWORD"]
  end

  # MAGIC CONSTANTS!!
  post '/reset' do
    heroku.put_config_vars(MOTHERSHIP, 'SENSORS' => '50', 'PUSH_TOKEN' => params[:pushtoken])
    reset_processes!
    cycle_tempodb!
    reset_redis!
    redirect('/')
  end

  post '/reset/streamed' do
    stream do |out|
      out << "Setting defaults...\n"
      heroku.put_config_vars(MOTHERSHIP, 'SENSORS' => '50', 'PUSH_TOKEN' => params[:pushtoken])
      out << "Resetting processes...\n"
      reset_processes!
      out << "Cycling TempoDB...\n"
      cycle_tempodb!
      out << "Resetting Redis\n"
      reset_redis!
      out << "Demo Ready\n"
    end
  end

  post '/update_tempodb' do
    update_tempodb!
    redirect('/')
  end

  post '/boot' do
    heroku.post_ps_scale(MOTHERSHIP, 'uuid_sensor', 20)
    redirect('/')
  end

  def reset_processes!
    result = []
    result << scale(MOTHERSHIP, 'monitor', 1)
    result << scale(MOTHERSHIP, 'web', 5)
    result << scale(MOTHERSHIP, 'uuid_sensor', 1)
    # result << scale(L2TEMPO, 'web', 5)
    # result << scale(L2CRM,   'web', 2)
    # result << scale(L2AIRSHIP, 'web', 2)
    $stdout.puts result.join("\n")
  end

  def scale(app, process, qty)
    result = heroku.post_ps_scale(app, process, qty)
    "Scale #{app} #{process} to #{result.body}"
  end

  def cycle_tempodb!
    p heroku.delete_addon(L2TEMPO, 'tempodb').body
    p heroku.post_addon(L2TEMPO, 'tempodb:starter').body
    sleep 2
    update_tempodb!
  end

  def update_tempodb!
    tempo_config = heroku.get_config_vars(L2TEMPO).body
    p tempo_config
    heroku.put_config_vars(MOTHERSHIP,
                           'TEMPODB_API_KEY' => tempo_config['TEMPODB_API_KEY'],
                           'TEMPODB_API_SECRET' => tempo_config['TEMPODB_API_SECRET'])
  end

  def reset_redis!
    p 'reset_redis=true'
    p redis.flushall
  end
end
