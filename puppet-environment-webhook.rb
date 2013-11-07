#!/usr/bin/env ruby
require 'sinatra'
require 'openssl'
require 'json'
require 'shellwords'
require 'faraday'
require 'sinatra/config_file'

set :ENVIRONMENT_BASEDIR, ENV['ENVIRONMENT_BASEDIR'] || '/etc/puppet/environments'
set :PRODUCTION_REPO, ENV['PRODUCTION_REPO']
set :GIT_SSH_USERHOSTNAME, ENV['GIT_SSH_USERHOSTNAME']
set :GITLAB_API_BASE, ENV['GITLAB_API_BASE']
set :GITLAB_PRIVATE_TOKEN, ENV['GITLAB_PRIVATE_TOKEN']
set :BRANCH_MAP, false
set :PUPPET_GROUP, ENV['PUPPET_GROUP'] || "puppet"
set :ENVIRONMENT_MODE, ENV['ENVIRONMENT_MODE'] || 0750

config_file 'puppet-environment-webhook.yaml'

# The git_dir environment variable will override the --git-dir, so we remove it
# to allow us to create new directories cleanly.
ENV.delete('GIT_DIR')

# Ensure that we have the underlying directories, otherwise the later commands
# may fail in somewhat cryptic manners.
unless File.directory? settings.ENVIRONMENT_BASEDIR
  puts %Q{#{settings.ENVIRONMENT_BASEDIR} does not exist, cannot create environment directories.}
  exit 1
end

SHA1_DIGEST = OpenSSL::Digest::Digest.new('sha1')

def get(client, what)
  response = client.get(what)
  return JSON.parse(response.body)
end

GL = Faraday.new(:url => settings.GITLAB_API_BASE) do |f|
  f.headers[:PRIVATE_TOKEN] = settings.GITLAB_PRIVATE_TOKEN
  f.request :url_encoded
  f.response :logger
  f.adapter Faraday.default_adapter
end

def gitlab_fork_full_names(repo_full_name)
  puts "finding forks of #{settings.PRODUCTION_REPO}"

  projects = get(GL, "projects")
  puts "#{projects}"

  projects.select { |p|
    p['forked_from_project'] && p['forked_from_project']['path_with_namespace'] == settings.PRODUCTION_REPO
  }.map { |p|
    p['path_with_namespace']
  }
end

def is_production_fork(repo_full_name)
  forks = gitlab_fork_full_names(repo_full_name)
  is_fork = forks.include?(repo_full_name)
  puts "is fork? #{is_fork}; production forks #{forks}"
  return is_fork
end

def get_environment_name(repo_full_name, branch)
  # check if the branch name is valid
  unless system('git', 'check-ref-format', '--branch', branch)
    puts %Q{branch "#{branch}" is not valid.} 
    halt 401
  end

  if repo_full_name == settings.PRODUCTION_REPO
    if settings.BRANCH_MAP[branch] != nil
      settings.BRANCH_MAP[branch]
    else
      branch
    end
  else
    repo_full_name_underscore = repo_full_name.gsub(/\W/, '_')
    if branch == "master"
      repo_full_name_underscore
    else
      "#{repo_full_name_underscore}_#{branch}"
    end
  end
end

def get_environment_path(environment_name)
  "#{settings.ENVIRONMENT_BASEDIR}/#{environment_name}"
end

def deploy(repo_full_name, branch)
  environment_name = get_environment_name(repo_full_name, branch)
  environment_path = get_environment_path(environment_name)

  if not is_production_fork(repo_full_name)
    halt 401
  end

  # create or update an environment from repo + branch
  if File.directory? environment_path
    puts "updating existing environment #{environment_name} in #{environment_path}"
    Dir.chdir environment_path

    # fetch and reset to handle force push to a branch
    %x{git fetch --all}
    %x{git reset --hard origin/#{branch.shellescape}}
    %x{git clean -dfx}

    if File.exists? "#{environment_path}/.gitmodules"
      %x{git submodule foreach git clean -dfx}
      %x{git submodule update --init --recursive}
    end
  else
    repo_ssh = "#{settings.GIT_SSH_USERHOSTNAME}:#{repo_full_name}"
    puts "creating new environment #{environment_name} in #{environment_path} from #{repo_ssh}"
    %x{git clone --recursive #{repo_ssh.shellescape} #{environment_path.shellescape} --branch #{branch.shellescape}}
  end

  # make sure the puppet user is able to read the environment
  if settings.PUPPET_GROUP
    FileUtils.chown_R nil, settings.PUPPET_GROUP, environment_path
  end
  FileUtils.chmod_R settings.ENVIRONMENT_MODE, environment_path
end

post '/puppet/deploy/:owner/:repo/:branch' do
  deploy("#{params[:owner]}/#{params[:repo]}", params[:branch])
end
