puppet-environments-webhook
===========================

Forkable dynamic environments for those using webhooks.

It's like http://puppetlabs.com/blog/git-workflow-and-puppet-environments for your githubs.

## Usage

### Configuration

Copy `puppet-environment-webhook.yaml.example` to `puppet-environment-webhook.yaml` and edit settings appropriately, or alternatively use environment variables.

### Running

Install dependencies and run using [bundler](http://bundler.io/) (`gem install bundler`):

    bundle install
    bundle exec rackup

### Triggering

#### curl

    curl -i 'http://host:port/puppet/deploy/:owner/:repo/:branch' --data ''

## Development

During development consider [shotgun](https://github.com/rtomayko/shotgun]) for automatic reloading:

    gem install shotgun
    shotgun ./puppet-environment-webhook.rb
