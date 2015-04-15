# encoding: utf-8
require "json"
require "logstash/outputs/base"
require "logstash/namespace"
require "net/http" # Connectivity back to New Relic Insights
require "net/https" # Connectivity back to New Relic Insights
require "stud/buffer" # For buffering events being sent
require "time"
require "uri"

# This output sends logstash events to New Relic Insights as custom events.
#
# You can learn more about New Relic Insights here:
# https://docs.newrelic.com/docs/insights/new-relic-insights/understanding-insights/new-relic-insights
class LogStash::Outputs::NewRelic < LogStash::Outputs::Base
  include Stud::Buffer

  config_name "newrelic"
  milestone 1

  # Your New Relic account ID. This is the 5 or 6-digit number found in the URL when you are logged into New Relic:
  # https://rpm.newrelic.com/accounts/[account_id]/... 
  config :account_id, :validate => :string, :required => true
  
  # Your Insights Insert Key. You will need to generate one if you haven't already, as described here:
  # https://docs.newrelic.com/docs/insights/new-relic-insights/adding-querying-data/inserting-custom-events-insights-api#register
  config :insert_key, :validate => :string, :required => true
  
  # The name for your event type. Use alphanumeric characters only.
  # If left out, your events will be stored under "logstashEvent".
  config :event_type, :validate => :string, :default => "logstashEvent"
  
  # Should the log events be sent to Insights over https instead of plain http (typically yes).
  config :proto, :validate => :string, :default => "https"
  
  # Proxy info - all optional
  # If using a proxy, only proxy_host is required.
  config :proxy_host, :validate => :string
  # Proxy_port will default to port 80 if left out.
  config :proxy_port, :validate => :number, :default => 80
  # Proxy_user should be left out if connecting to your proxy unauthenticated.
  config :proxy_user, :validate => :string
  # Proxy_password should be left out if connecting to your proxy unauthenticated.
  config :proxy_password, :validate => :password, :default => ""

  # Batch Processing - all optional
  # This plugin uses the New Relic Insights REST API to send data.
  # To make efficient REST API calls, we will buffer a certain number of events before flushing that out to Insights.
  config :batch, :validate => :boolean, :default => true
  # This setting controls how many events will be buffered before sending a batch of events.
  config :batch_events, :validate => :number, :default => 10
  # This setting controls how long the output will wait before sending a batch of a events, 
  # should the minimum specified in batch_events not be met yet.
  config :batch_timeout, :validate => :number, :default => 5

  # New Relic Insights Reserved Words
  # https://docs.newrelic.com/docs/insights/new-relic-insights/adding-querying-data/inserting-custom-events#keywords
  # moved = change "word" to "word_moved"
  # backticks = change "word" to "`word`"
  # If you enter anything else, the "word" will change to the "anything else"
  RESWORDS = {
    "accountId" => "moved",
    "appId" => "moved",
    "timestamp" => "moved",
    "type" => "moved",
    "ago" => "backticks",
    "and" => "backticks",
    "as" => "backticks",
    "auto" => "backticks",
    "begin" => "backticks",
    "begintime" => "backticks",
    "compare" => "backticks",
    "day" => "backticks",
    "days" => "backticks",
    "end" => "backticks",
    "endtime" => "backticks",
    "explain" => "backticks",
    "facet" => "backticks",
    "from" => "backticks",
    "hour" => "backticks",
    "hours" => "backticks",
    "in" => "backticks",
    "is" => "backticks",
    "like" => "backticks",
    "limit" => "backticks",
    "minute" => "backticks",
    "minutes" => "backticks",
    "month" => "backticks",
    "months" => "backticks",
    "not" => "backticks",
    "null" => "backticks",
    "offset" => "backticks",
    "or" => "backticks",
    "second" => "backticks",
    "seconds" => "backticks",
    "select" => "backticks",
    "since" => "backticks",
    "timeseries" => "backticks",
    "until" => "backticks",
    "week" => "backticks",
    "weeks" => "backticks",
    "where" => "backticks",
    "with" => "backticks",
  }

  public
  def register
    # URL to send event over http(s) to the New Relic Insights REST API
    @url = URI.parse("#{@proto}://insights-collector.newrelic.com/v1/accounts/#{@account_id}/events")
    @logger.info("New Relic Insights output initialized.")
    @logger.info("New Relic URL: #{@url}")
    if @batch
      @logger.info("Batch processing of events enabled.")
      if @batch_events > 1000
        raise RuntimeError.new("New Relic Insights only allows a batch_events parameter of 1000 or less")
      end
      buffer_initialize(
      :max_items => @batch_events,
      :max_interval => @batch_timeout,
      :logger => @logger
      )
    end
  end # def register

  public
  def receive(event)
    return unless output?(event)
    if event == LogStash::SHUTDOWN
      finished
      return
    end
    parsed_event = parse_event(event)
    if @batch
      buffer_receive(parsed_event)
    else
      send_to_insights(parsed_event)
    end
  end # def receive

  public
  # Insights REST API handles multiple events the same way as a single event. Score!
  # All we need to do on 'flush' is send the contents of the events buffer.
  def flush(events, teardown=false)
    @logger.debug("Sending batch of #{events.size} events to insights")
    send_to_insights(events)
  end # def flush

  public
  def teardown
    buffer_flush(:final => true)
    finished
  end # def teardown
  
  # Turn event into an Insights-compliant event
  public
  def parse_event(event)
    this_event = event.to_hash
    output_event = Hash.new
    
    # Setting eventType to what's in the config
    output_event['eventType'] = @event_type
    
    # Setting timestamp to what logstash reports
    timestamp_parsed = Time.parse(event.timestamp.to_s)
    output_event['timestamp'] = timestamp_parsed.to_i

    # Search event's attribute names for reserved words, replace with 'compliant' versions
    # Storing 'compliant' key names in "EVENT_KEYS" to minimize time spent doing this
    this_event.each_key do |event_key|
      if RESWORDS.has_key?(event_key)
        @logger.debug("Reserved word found", :reserved_word => event_key)
        if RESWORDS[event_key] == "moved"
          proper_name = event_key + "_moved"
        elsif RESWORDS[event_key] == "backticks"
          proper_name = "`" + event_key + "`"
        else
          proper_name = RESWORDS[event_key]
        end
      else
        proper_name = event_key
      end
      output_event[proper_name] = this_event[event_key]
    end
    return output_event
  end # def parse_event

  # Send event(s) to the NR Insights REST API.
  # Can handle a single event or batched events.
  def send_to_insights(event)
    http = Net::HTTP.new(@url.host, @url.port, @proxy_host, @proxy_port, @proxy_user, @proxy_password.value)
    if @url.scheme == 'https'
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    # Insights uses a POST, requires Content-Type and X-Insert-Key.
    request = Net::HTTP::Post.new(@url.path)
    request['Content-Type'] = "application/json"
    request['X-Insert-Key'] = @insert_key
    request.body = event.to_json
    @logger.debug("Request Body:", :request_body => request.body)

    response = http.request(request)
    if response.is_a?(Net::HTTPSuccess)
      @logger.debug("Event sent to New Relic SUCCEEDED! Response Code:", :response_code => response.code)
    else
      @logger.warn("Event sent to New Relic FAILED. Error:", :error => response.error!)
    end
  end # def send_to_insights
  
end # class LogStash::Outputs::NewRelic