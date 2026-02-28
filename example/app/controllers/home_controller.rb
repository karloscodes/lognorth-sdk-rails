class HomeController < ApplicationController
  def index
    LogNorth.log("homepage visited", ua: request.user_agent)
    render plain: "Hello from Rails example"
  end

  def error
    raise "something broke"
  rescue => err
    LogNorth.error("triggered test error", err)
    render plain: "error triggered, check LogNorth", status: 500
  end

  def crash
    raise "unhandled crash!"
  end

  def job
    ExampleJob.perform_later("test-run")
    render plain: "job enqueued"
  end

  def checkout
    LogNorth.log("checkout started", user: "demo@example.com")
    LogNorth.log("validating cart", items: 3, total: 59.99)
    LogNorth.log("payment processed", provider: "stripe", amount: 59.99)
    LogNorth.log("inventory updated", items_reserved: 3)
    LogNorth.log("order confirmed", order_id: "ORD-1234")
    render plain: "checkout complete"
  end
end
