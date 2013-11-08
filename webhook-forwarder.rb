#!/usr/bin/env ruby
require 'sinatra'
require 'sinatra/config_file'
require 'faraday'
require 'json'

parallel = true
begin
  require 'typhoeus'
  require 'typhoeus/adapters/faraday'
rescue LoadError
  parallel = false
  puts "typhoeus not found; requests will be serialized instead of in parallel"
end

set :FORWARD_TO, ENV['FORWARD_TO'] && ENV['FORWARD_TO'].split(' ')
set :EXPOSE_ERRORS, ENV['EXPOSE_ERRORS'] || false

config_file 'webhook_forwarder.yaml'

if not settings.FORWARD_TO
  puts "no forwarders configured"
  exit 1
end

F = Faraday.new() do |faraday|
  if parallel
    faraday.adapter :typhoeus
  else
    faraday.adapter Faraday.default_adapter
  end
end

post '/*' do
  results = nil
  F.in_parallel do
    results = Hash[settings.FORWARD_TO.map { |uri|
      puts "forwarding #{request.url} -> #{uri}#{request.path_info}"

      begin
        result = F.post do |post|
          post.url "#{uri}#{request.path_info}"
          post.params = request.GET
          post.body = request.body.read
        end
      rescue Faraday::Error::ConnectionFailed => e
        result = e
      end

      [uri, result]
    }]
  end

  if results.any? { |uri, result| result.is_a?(Exception) or not result.success? }
    results = Hash[results.map { |uri, result|
      if result.is_a?(Exception)
        [uri, {
          :error => result
        }]
      else
        [uri, {
          :status => result.status,
          :body => result.body
        }]
      end
    }]

    puts "FAILED: #{results.to_json}"

    if settings.EXPOSE_ERRORS
      return [502, results.to_json]
    else
      return 502
    end
  end

  204 # success, nothing to return
end
