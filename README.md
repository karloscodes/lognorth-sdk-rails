# LogNorth Rails SDK

Send errors and logs from Rails to [LogNorth](https://lognorth.com) for monitoring and alerting.

## Installation

```ruby
gem "lognorth"
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
# Log messages (batched, sent after 5s or at 10 events)
LogNorth.log("User signed up", { user_id: 123 })

# Report errors (sent at once)
begin
  risky_operation
rescue => e
  LogNorth.error("Payment failed", e, { order_id: 456 })
  raise
end

# Manual flush (called automatically at exit)
LogNorth.flush
```

## Batching and delivery

Logging calls never block and never raise. They add the event to a queue in memory.
One background thread sends the queue, one request at a time.

- The thread sends when the queue holds 10 events, when you report an error, or 5 seconds after the first event.
- A request holds at most 500 events and 1 MB of JSON.
- The queue holds at most 10,000 events or 10 MB of JSON.
- The SDK trims an event to at most 64 KB before it enters the queue. It marks a trimmed event with `context.truncated = true`.

When a send fails, the SDK keeps the events and tries again later. Events keep their order.

- On a network error, a timeout, or a 5xx, it waits 1 second, then 2, then 4, up to 60.
- On a 429 or 503, it waits as long as the `Retry-After` header says.
- On a 401, 403, or 404, it waits 60 seconds, then up to 5 minutes. It writes one line to stderr, so you can fix the url or the key.
- On a 413 or other 4xx, it splits the batch in two and sends again. It drops a single event the server still refuses.

When the queue is full, the SDK drops the oldest event that is not an error. It keeps errors longest.
After the next successful send, it logs `LogNorth client dropped N events` with the counts.

At exit (including SIGTERM and SIGINT), the SDK sends what is left in the queue for up to 5 seconds.
It writes the number of events it could not send to stderr.

## Rack (without Rails)

```ruby
require "lognorth"

LogNorth.config("https://lognorth.example.com", "api_key")
use LogNorth::Middleware
```
