class Palmade::SocketIoRack::Base
  attr_reader :sessions
end

class XhrPollingTest < Test::Unit::TestCase
  def setup
    gem 'eventmachine', '>= 0.12.10'
    require 'eventmachine'
  end

  def logger
    @logger ||= Logger.new(STDOUT)
  end

  def test_new_connect
    EM.run do
      EM.next_tick do
        p = Palmade::SocketIoRack::Persistence.new(:store => :redis)
        b = Palmade::SocketIoRack::Base.new

        env = MockWebRequest.new("REQUEST_METHOD" => "GET") do |result|
          assert(result.first == 200, "not an HTTP 200 response")
          assert(result.last.size == 3, "final response is of wrong size")
        end

        response = nil
        performed = false
        assert_nothing_raised { performed, response = b.handle_request(env, 'xhr-polling', nil, p) }
        assert(b.sessions.count == 1)

        sid = nil
        b.sessions.each_key { |id| sid = id }
        xpt = b.sessions[sid][:transport]
        assert(xpt.kind_of?(Palmade::SocketIoRack::Transports::XhrPolling), "returned the wrong transport")

        assert(performed, "original request not performed")
        assert(response.first == -1, "response is not an async response")

        session_id = b.sessions[sid][:session].session_id
        assert(session_id.kind_of?(String), "wrong session id value")

        b.reply sid, "Hello", "World"
        b.reply sid, "More", "Hello", "World"

        EM.next_tick do
          assert(!xpt.connected?, "xpt was not disconnected")
          b.reply sid, "This", "is", "for", "something", "later"

          env = MockWebRequest.new("REQUEST_METHOD" => "GET") do |result|
            assert(result.first == 200, "not an HTTP 200 response")
            assert(result.last.size == 2, "final response is of wrong size")

            EM.next_tick do
              assert(!xpt.connected?, "xpt was not disconnected (resume)")
              EM.stop
            end
          end

          to = "/#{session_id}"
          response = nil
          performed = false
          assert_nothing_raised { performed, response = b.handle_request(env, 'xhr-polling', to, p) }

          assert(performed, "resumed request not performed")
          assert(response.first == -1, "response is not async (resume)")

          b.reply sid, "This", "is", "a", "reply", "from", "the", "resumed", "sessions"
        end
      end
    end
  end
end
