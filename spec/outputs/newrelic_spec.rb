# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/outputs/newrelic"
require "logstash/event"
require "logstash/timestamp"
require "time"

# TO DO (in order of easiest to hardest):
# + Test batch_timeout
# + Test proxy (oy gevalt)

describe LogStash::Outputs::NewRelic do

  let (:simple_event_contents) { { 'message' => 'hello', 'topic_name' => 'my_topic', 'host' => '172.0.0.1' } }  
  let(:options) { { 'account_id' => "284929",
                      'insert_key' => "BYh7sByiVrkfqcDa2eqVMhjxafkdyuX0" } }
  let(:simple_output) { LogStash::Plugin.lookup("output", "newrelic").new(options) }
                      
  describe "#register" do
    it "should register" do
      output = LogStash::Plugin.lookup("output", "newrelic").new(options)
      expect { output.register }.to_not raise_error
    end
    
    it "should NOT register when batch_events > 1000" do
      options['batch_events'] = 1001
      output = LogStash::Plugin.lookup("output", "newrelic").new(options)
      expect { output.register }.to raise_error(RuntimeError)
    end
  end
  
  describe "#parse_event" do
    it "should convert attribute names" do
      simple_event_contents['accountId'] = '123456'
      simple_event_contents['compare'] = 'backtick that'
      simple_event_contents['test_of_anything_else'] = 'leave this'
      simple_event = LogStash::Event.new(simple_event_contents)
      test_event = simple_output.parse_event(simple_event)
      expect(test_event['accountId_moved']).to eq(simple_event_contents['accountId'])
      expect(test_event['`compare`']).to eq(simple_event_contents['compare'])
      expect(test_event['test_of_anything_else']).to eq(simple_event_contents['test_of_anything_else'])
    end
  end
  
  describe "#receive" do
    it "should send a single event" do
      options['batch'] = false
      output = LogStash::Plugin.lookup("output", "newrelic").new(options)
      output.register
      simple_event = LogStash::Event.new(simple_event_contents)
      expect { output.receive(simple_event) }.to_not raise_error
    end
    
    it "should send multiple events" do
      batch_event_count = 5
      options["batch_events"] = batch_event_count
      output = LogStash::Plugin.lookup("output", "newrelic").new(options)
      output.register
      for i in 0..batch_event_count
        simple_event_contents['iteration'] = i
        simple_event = LogStash::Event.new(simple_event_contents)
        expect { output.receive(simple_event) }.to_not raise_error
      end
    end
  end
end