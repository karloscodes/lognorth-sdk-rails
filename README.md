# lognorth-sdk-rails

[![CI](https://github.com/karloscodes/lognorth-sdk-rails/actions/workflows/ci.yml/badge.svg)](https://github.com/karloscodes/lognorth-sdk-rails/actions/workflows/ci.yml) [![Gem Version](https://img.shields.io/gem/v/lognorth)](https://rubygems.org/gems/lognorth) [![License](https://img.shields.io/github/license/karloscodes/lognorth-sdk-rails)](LICENSE)

Sends errors, logs, and request events from Rails and Rack apps to LogNorth.

[LogNorth](https://lognorth.com) monitors your app and alerts you when it fails. See the [LogNorth Rails docs](https://lognorth.com/docs/integrations/rails/).

## Install

```sh
bundle add lognorth
```

## Use

With credentials set (see [Configuration](#configuration)), Rails sends request events, reported exceptions, and job events on its own. Call the SDK to send your own events:

```ruby
LogNorth.log("User signed up", { user_id: 123 })

begin
  risky_operation
rescue => e
  LogNorth.error("Payment failed", e, { order_id: 456 })
  raise
end

LogNorth.flush # sends the queue now, for up to 5 seconds
```

### Who hit the error, and in which release

The SDK reads `Current.user` when your app defines it, as the Rails authentication generator does. Otherwise, set the user yourself. Use an ID, not an email:

```ruby
class ApplicationController < ActionController::Base
  before_action { LogNorth.user = current_user&.id }
end
```

The request event and its errors carry the user.

Errors also carry the release. See [Configuration](#configuration) for how the release is set.

## Middleware

The middleware logs each request as one event. The event has the method, path, status, duration, controller, action, and route (`/users/:id`, Rails 7.1 and later). LogNorth groups requests into endpoints by the route. It also sets an `X-Trace-ID` response header. It reuses an incoming `X-Trace-ID` request header when one is set.

Requests that match no route are not logged. A 5xx request also carries its user agent, and it sends the queue at once.

### Client errors are not errors

An exception that Rails answers with a 4xx is the request's fault, not the app's. Examples are `ActiveRecord::RecordNotFound` (404), `ActionController::InvalidAuthenticityToken` (422), and `ActionController::ParameterMissing` (400). The SDK logs the request with that status. It does not report an error, so these never become issues or alerts.

Rails sets the status in `config.action_dispatch.rescue_responses`. The SDK reads the same map. To report one of them as an error, map it to a 5xx:

```ruby
config.action_dispatch.rescue_responses["ActiveRecord::RecordNotFound"] = :internal_server_error
```

### Without Rails

Use the middleware in any Rack app:

```ruby
require "lognorth"

LogNorth.config("https://lognorth.example.com", "api_key")
use LogNorth::Middleware
```

## How it works

### Batching

Logging calls never wait for the network. Each call adds the event to a queue in memory. One background thread sends the queue, one request at a time.

- The thread sends when the queue holds 10 events, when you report an error, or 5 seconds after the first queued event.
- A request holds at most 500 events and 1 MB of JSON.
- The queue holds at most 10,000 events or 10 MB of JSON.
- A message over 1,000 characters is cut. A long string in the context is cut.
- An event still over 64 KB keeps only its essential context keys. The SDK sets `context.truncated` to `true` on any cut event.

### Failed sends

The SDK keeps the events and sends them again later. Events keep their order.

- A network error, a timeout, a 408, or a 5xx waits 1, 2, 4 seconds, and so on, up to 60 seconds. Each wait varies by up to 20%.
- A 429 or 503 waits as long as the `Retry-After` header says, from 1 to 300 seconds. Without the header, the SDK uses the normal wait.
- A 401, 403, 404, or other unexpected status waits 60 seconds, then 120, then 240, up to 300 seconds. It writes a line to stderr when delivery starts failing. Check the URL and the API key.
- Another 4xx, such as 400, 413, or 422, splits the batch in two and sends each half. A single event that the server still refuses is dropped.

When the queue is full, the SDK drops the oldest event that is not an error. After the next successful send, it logs `LogNorth client dropped N events`. The context holds the counts of dropped events and dropped errors.

### Exit

At exit, the SDK sends the queue for up to 5 seconds. Ruby runs this exit hook on SIGTERM and SIGINT too, unless the app traps them. The SDK writes the number of unsent events to stderr.

### Errors and jobs

- `Rails.error` reports go to LogNorth. Each event adds `handled`, `severity`, and `source` to the context.
- With `config.lognorth.active_job` on, each job logs `<Job> completed` or `<Job> failed`. A job carries the trace ID of the request that enqueued it.

## Configuration

The SDK reads the URL and API key from Rails credentials:

```yaml
# config/credentials.yml.enc
lognorth:
  url: https://your-lognorth-instance.com
  api_key: your_api_key
```

Without a URL and an API key, the SDK logs a warning at boot and sends nothing.

Rails sets the environment name for you. Set `release:` yourself, or let the SDK read it from the environment. To configure the SDK by hand, call `LogNorth.config` in an initializer:

```ruby
# config/initializers/lognorth.rb
LogNorth.config(
  ENV["LOGNORTH_URL"],
  ENV["LOGNORTH_API_KEY"],
  environment: "production", # optional
  release: "1.2.3"           # optional
)
```

When no `release:` is set, the SDK reads the first of these variables that is set: `LOGNORTH_RELEASE`, `GIT_SHA`, `GIT_COMMIT`, `SOURCE_COMMIT`, `KAMAL_VERSION`, `RENDER_GIT_COMMIT`, `HEROKU_SLUG_COMMIT`, `SOURCE_VERSION`, `RAILWAY_GIT_COMMIT_SHA`, `VERCEL_GIT_COMMIT_SHA`. When a release is set, the SDK logs `Release <version> started` once, when it configures.

Options, in `config/application.rb`:

```ruby
config.lognorth.enabled = true           # Default: on, except in development and test
config.lognorth.middleware = true        # Request events
config.lognorth.error_subscriber = true  # Rails.error reports (Rails 7.0+)
config.lognorth.active_job = true        # Job events

# Requests to skip. Default: Rails' health check, which load balancers call often.
# Set [] to log everything.
config.lognorth.ignored_paths = ["/up"]
```

An ignored path matches the exact path, or the path followed by `/`. So `/up` also skips `/up/detail`.

## Development

```sh
bundle install
bundle exec rake test
```

## License

MIT. See [LICENSE](LICENSE).
