class ExampleJob < ApplicationJob
  queue_as :default

  def perform(name)
    LogNorth.log("processing example job", name: name)
    sleep 0.1
    LogNorth.log("example job done", name: name)
  end
end
