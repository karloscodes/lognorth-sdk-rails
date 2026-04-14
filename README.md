# LogNorth Rails SDK

Send errors and logs from Rails to [LogNorth](https://lognorth.com) for monitoring and alerting.

## Installation

```ruby
gem "lognorth", github: "karloscodes/lognorth-sdk-rails"
```

## Rails Setup

Add credentials:

```yaml
# config/credentials.yml.enc
lognorth:
  url: https://your-lognorth-instance.com
  api_key: your_api_key
```

That's it. The gem auto-configures via Railtie.

### Manual Configuration

```ruby
# config/initializers/lognorth.rb
LogNorth.config(
  ENV["LOGNORTH_URL"],
  ENV["LOGNORTH_API_KEY"]
)
```

### Options

```ruby
# config/application.rb
config.lognorth.enabled = Rails.env.production?
config.lognorth.middleware = true        # Log HTTP requests
config.lognorth.error_subscriber = true  # Report exceptions (Rails 7+)

# Paths to skip from request logging. Defaults to Rails' built-in
# health-check endpoint; set to [] to log everything or replace with
# your own list.
config.lognorth.ignored_paths = ["/up", "/healthz"]
```

Default: `["/up"]` (Rails 7.1's auto-generated health check — swamped by
kamal-proxy and load-balancer pings otherwise). Setting `ignored_paths =
[]` disables ignoring entirely. Matching is exact path or `path/…`
prefix, so `/up` also covers `/up/detail`.

## Usage

```ruby
# Log messages (batched, sent every 5s or 10 events)
LogNorth.log("User signed up", { user_id: 123 })

# Report errors (sent immediately)
begin
  risky_operation
rescue => e
  LogNorth.error("Payment failed", e, { order_id: 456 })
  raise
end

# Manual flush (called automatically at exit)
LogNorth.flush
```

## Rack (without Rails)

```ruby
require "lognorth"

LogNorth.config("https://lognorth.example.com", "api_key")
use LogNorth::Middleware
```
