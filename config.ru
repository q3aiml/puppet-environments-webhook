require 'rubygems'
require 'bundler'

Bundler.require

require './puppet-environment-webhook'
run Sinatra::Application
