# frozen_string_literal: true

# Copyright (c) 2019 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

STDOUT.sync = true

require 'geocoder'
require 'glogin'
require 'glogin/codec'
require 'haml'
require 'json'
require 'pgtk'
require 'pgtk/pool'
require 'raven'
require 'sinatra'
require 'sinatra/cookies'
require 'time'
require 'yaml'
require_relative 'version'

if ENV['RACK_ENV'] != 'test'
  require 'rack/ssl'
  use Rack::SSL
end

configure do
  Haml::Options.defaults[:format] = :xhtml
  config = {
    'github' => {
      'client_id' => '?',
      'client_secret' => '?',
      'encryption_secret' => ''
    },
    'pgsql' => {
      'host' => 'localhost',
      'port' => 0,
      'user' => 'test',
      'dbname' => 'test',
      'password' => 'test'
    },
    'sentry' => ''
  }
  config = YAML.safe_load(File.open(File.join(File.dirname(__FILE__), 'config.yml'))) unless ENV['RACK_ENV'] == 'test'
  if ENV['RACK_ENV'] != 'test'
    Raven.configure do |c|
      c.dsn = config['sentry']
      c.release = Rsk::VERSION
    end
  end
  set :dump_errors, false
  set :show_exceptions, false
  set :config, config
  set :logging, true
  set :server_settings, timeout: 25
  set :glogin, GLogin::Auth.new(
    config['github']['client_id'],
    config['github']['client_secret'],
    'https://www.0rsk.com/github-callback'
  )
  cfg = File.exist?('target/pgsql-config.yml') ? YAML.load_file('target/pgsql-config.yml') : config
  set :pgsql, Pgtk::Pool.new(
    host: cfg['pgsql']['host'],
    port: cfg['pgsql']['port'],
    dbname: cfg['pgsql']['dbname'],
    user: cfg['pgsql']['user'],
    password: cfg['pgsql']['password']
  ).start(4)
end

before '/*' do
  @locals = {
    ver: Rsk::VERSION,
    login_link: settings.glogin.login_uri,
    request_ip: request.ip
  }
  cookies[:glogin] = params[:glogin] if params[:glogin]
  if cookies[:glogin]
    begin
      @locals[:user] = GLogin::Cookie::Closed.new(
        cookies[:glogin],
        settings.config['github']['encryption_secret'],
        context
      ).to_user
    rescue OpenSSL::Cipher::CipherError => _
      cookies.delete(:glogin)
    end
  end
  if params[:auth]
    @locals[:user] = {
      login: settings.codec.decrypt(Hex::ToText.new(params[:auth]).to_s)
    }
  end
end

get '/github-callback' do
  cookies[:glogin] = GLogin::Cookie::Open.new(
    settings.glogin.user(params[:code]),
    settings.config['github']['encryption_secret'],
    context
  ).to_s
  flash('/', 'You have been logged in')
end

get '/logout' do
  cookies.delete(:glogin)
  flash('/', 'You have been logged out')
end

get '/hello' do
  haml :hello, layout: :layout, locals: merged(
    title: '/'
  )
end

get '/' do
  haml :index, layout: :layout, locals: merged(
    title: '/',
    ranked: ranked.fetch(offset: 0, limit: 10)
  )
end

get '/add' do
  haml :add, layout: :layout, locals: merged(
    title: '/add'
  )
end

post '/do-add' do
  cid = params[:cid] || causes.add(params[:cause])
  rid = params[:rid] || (risks.add(params[:risk]) if params[:risk])
  eid = params[:eid] || (effects.add(params[:effect]) if params[:effect])
  pid = params[:pid] || (plans.add(params[:plan]) if params[:plan])
  links.add("C#{cid}", "R#{rid}") if cid && rid
  links.add("R#{rid}", "E#{eid}") if rid && eid
  links.add("C#{eid}", "P#{pid}") if pid && cid && !rid && !eid
  links.add("R#{eid}", "P#{pid}") if pid && rid && !eid
  links.add("E#{eid}", "P#{pid}") if pid && eid
  risks.probability(rid, params[:probability].to_i) if rid && params[:probability]
  effects.impact(eid, params[:impact].to_i) if eid && params[:impact]
  flash('/', 'Thanks')
end

get '/robots.txt' do
  content_type 'text/plain'
  "User-agent: *\nDisallow: /"
end

get '/version' do
  content_type 'text/plain'
  Rsk::VERSION
end

not_found do
  status 404
  content_type 'text/html', charset: 'utf-8'
  haml :not_found, layout: :layout, locals: merged(
    title: request.url
  )
end

error do
  status 503
  e = env['sinatra.error']
  if e.is_a?(UserError)
    flash('/', e.message, color: 'darkred')
  else
    Raven.capture_exception(e)
    haml(
      :error,
      layout: :layout,
      locals: merged(
        title: 'error',
        error: "#{e.message}\n\t#{e.backtrace.join("\n\t")}"
      )
    )
  end
end

def context
  "#{request.ip} #{request.user_agent} #{Rsk::VERSION} #{Time.now.strftime('%Y/%m')}"
end

def merged(hash)
  out = @locals.merge(hash)
  out[:local_assigns] = out
  if cookies[:flash_msg]
    out[:flash_msg] = cookies[:flash_msg]
    cookies.delete(:flash_msg)
  end
  out[:flash_color] = cookies[:flash_color] || 'darkgreen'
  cookies.delete(:flash_color)
  out
end

def flash(uri, msg, color: 'darkgreen')
  cookies[:flash_msg] = msg
  cookies[:flash_color] = color
  redirect uri
end

def current_user
  redirect '/hello' unless @locals[:user]
  @locals[:user][:login].downcase
end

def current_project
  @cookies['0rsk-project']
end

def ranked(project: current_project)
  require_relative 'objects/ranked'
  Rsk::Ranked.new(settings.pgsql, project)
end

def causes(project: current_project)
  require_relative 'objects/causes'
  Rsk::Causes.new(settings.pgsql, project)
end

def risks(project: current_project)
  require_relative 'objects/risks'
  Rsk::Risks.new(settings.pgsql, project)
end

def effects(project: current_project)
  require_relative 'objects/effects'
  Rsk::Effects.new(settings.pgsql, project)
end

def plans(project: current_project)
  require_relative 'objects/plans'
  Rsk::Plans.new(settings.pgsql, project)
end
