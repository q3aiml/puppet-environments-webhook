require 'rubygems'
require 'bundler'

Bundler.require

require './webhook-forwarder'
run Sinatra::Application
