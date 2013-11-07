#!/usr/bin/env ruby
require 'sinatra'
require 'openssl'
require 'json'
require 'shellwords'
require 'faraday'

# Set this to where you want to keep your environments.
# /etc/puppet/environments is a reasonable default.
ENVIRONMENT_BASEDIR = "/etc/puppet/environments"

# The full name of the original, production puppet repo on the git server.
# Environments will be created for branches in this repo and any of its forks.
PRODUCTION_REPO = "puppeteers/prod-puppet"

# user@hostname of the git server for SSH access
GIT_SSH_USERHOSTNAME = "git@ourgitlab.example.com"

# GitLab v3 API URL base
GITLAB_API_BASE = 'https://outgitlab.example.com/api/v3/'

# GitLab private token
GITLAB_PRIVATE_TOKEN = 'YOUR_TOKEN_HERE'

# Mapping of branches to directories for PRODUCTION_REPO (forks are not mapped).
BRANCH_MAP = {
  # This will clone/pull the master branch into the development puppet environment
  # "master" => "development",
}

# Set this to a group the puppet user is a member of
PUPPET_GROUP = "puppet"

# Set this to the octal mode the environment should have
ENVIRONMENT_MODE = 0750

# The git_dir environment variable will override the --git-dir, so we remove it
# to allow us to create new directories cleanly.
ENV.delete('GIT_DIR')

# Ensure that we have the underlying directories, otherwise the later commands
# may fail in somewhat cryptic manners.
unless File.directory? ENVIRONMENT_BASEDIR
  puts %Q{#{ENVIRONMENT_BASEDIR} does not exist, cannot create environment directories.}
  exit 1
end

SHA1_DIGEST = OpenSSL::Digest::Digest.new('sha1')

def get(client, what)
  response = client.get(what)
  return JSON.parse(response.body)
end

GL = Faraday.new(:url => GITLAB_API_BASE) do |f|
  f.headers[:PRIVATE_TOKEN] = GITLAB_PRIVATE_TOKEN
  f.request :url_encoded
  f.response :logger
  f.adapter Faraday.default_adapter
end

def gitlab_fork_full_names(repo_full_name)
  puts "finding forks of #{PRODUCTION_REPO}"

  projects = get(GL, "projects")
  puts "#{projects}"

  projects.select { |p|
    p['forked_from_project'] && p['forked_from_project']['path_with_namespace'] == PRODUCTION_REPO
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

  if repo_full_name == PRODUCTION_REPO
    if BRANCH_MAP[branch] != nil
      BRANCH_MAP[branch]
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
  "#{ENVIRONMENT_BASEDIR}/#{environment_name}"
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
    repo_ssh = "#{GIT_SSH_USERHOSTNAME}:#{repo_full_name}"
    puts "creating new environment #{environment_name} in #{environment_path} from #{repo_ssh}"
    %x{git clone --recursive #{repo_ssh.shellescape} #{environment_path.shellescape} --branch #{branch.shellescape}}
  end

  # make sure the puppet user is able to read the environment
  if PUPPET_GROUP
    FileUtils.chown_R nil, PUPPET_GROUP, environment_path
  end
  FileUtils.chmod_R ENVIRONMENT_MODE, environment_path
end

post '/puppet/deploy/:owner/:repo/:branch' do
  deploy("#{params[:owner]}/#{params[:repo]}", params[:branch])
end
