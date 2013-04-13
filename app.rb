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
    @up_devices = @devices.select{ |p| p['state'] =~ /up|restart/ }.size
    @device_density = @mothership_env_h['SENSORS'].to_i
    @device_count = @up_devices * @device_density
    @l2tempo_env_h = heroku.get_config_vars(L2TEMPO).body
    @l2tempo_env   = @l2tempo_env_h.to_a.sort_by!{ |key,_v| key }
    @warn_l2tempo  = (@mothership_env_h['TEMPODB_API_KEY'] != @l2tempo_env_h['TEMPODB_API_KEY']) ||
                     (@mothership_env_h['TEMPODB_API_SECRET'] != @l2tempo_env_h['TEMPODB_API_SECRET'])

    slim :index
  end

  # MAGIC CONSTANTS!!
  post '/reset' do
    heroku.put_config_vars(MOTHERSHIP, 'SENSORS' => '50')
    reset_processes!
    cycle_tempodb!
    redirect('/')
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
    result << scale(L2TEMPO, 'web', 5)
    result << scale(L2CRM,   'web', 2)
    result << scale(L2AIRSHIP, 'web', 2)
    $stdout.puts result.join("\n")
  end

  def scale(app, process, qty)
    result = heroku.post_ps_scale(app, process, qty)
    "Scale #{app} #{process} to #{result.body}"
  end

  def cycle_tempodb!
    p heroku.delete_addon(L2TEMPO, 'tempodb').body
    p heroku.post_addon(L2TEMPO, 'tempodb:starter').body
    sleep 5
    update_tempodb!
  end

  def update_tempodb!
    tempo_config = heroku.get_config_vars(L2TEMPO).body
    p tempo_config
    heroku.put_config_vars(MOTHERSHIP,
                           'TEMPODB_API_KEY' => tempo_config['TEMPODB_API_KEY'],
                           'TEMPODB_API_SECRET' => tempo_config['TEMPODB_API_SECRET'])
  end
end
