# LogNorth Rails SDK

Send errors and logs from Rails to [LogNorth](https://lognorth.com) for monitoring and alerting.

## Installation

```ruby
gem "lognorth", github: "karloscodes/lognorth-sdk-ruby"
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
