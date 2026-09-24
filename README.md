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
config.lognorth.enabled = true           # Default: on everywhere except development and test
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

### Client errors are not errors

An exception that Rails answers with a 4xx is the request's fault, not the app's:
`ActiveRecord::RecordNotFound` (404), `ActionController::InvalidAuthenticityToken`
(422), `ActionController::ParameterMissing` (400). The SDK logs the request with
that status and does not report an error, so these never become issues or alerts.

Rails decides the status from `config.action_dispatch.rescue_responses`, and the SDK
asks the same map. To report one of them as an error, map it to a 5xx:

```ruby
config.action_dispatch.rescue_responses["ActiveRecord::RecordNotFound"] = :internal_server_error
```

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
