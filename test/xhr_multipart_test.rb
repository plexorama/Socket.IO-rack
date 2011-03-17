class Palmade::SocketIoRack::Base
  attr_reader :sessions
end

class XhrMultipartTest < Test::Unit::TestCase
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

        drb_klass = Palmade::SocketIoRack::Transports::XhrMultipart::DeferredResponseBody

        stop = false
        env = nil
        xpt = nil
        sid = nil
        next_request = nil

        env = MockWebRequest.new("REQUEST_METHOD" => "GET") do |result|
          assert(result.first == 200, "not an HTTP 200 response")

          EM.next_tick do
            assert(xpt.headers_sent?, "initial header was not sent")

            assert(env.data.size == 2, "initial header response is not right")
            assert(env.data.first == "--socketio\n", "could not see first multipart boundary")

            b.reply(sid, "Yet another reply")
            assert(env.data.size == 3, "additional reply was not sent to the connection")

            xpt.maxed_outbound_timer
            assert(!xpt.connected?, "did not disconnect")

            EM.next_tick(next_request)
          end
        end

        response = nil
        performed = false
        assert_nothing_raised { performed, response = b.handle_request(env, 'xhr-multipart', nil, p) }
        assert(b.sessions.count == 1)

        b.sessions.each_key { |id| sid = id }
        xpt = b.sessions[sid][:transport]
        assert(xpt.kind_of?(Palmade::SocketIoRack::Transports::XhrMultipart), "returned the wrong transport")

        assert(performed, "original request not performed")
        assert(response.first == -1, "response is not an async response")

        session_id = b.sessions[sid][:session].session_id
        assert(session_id.kind_of?(String), "wrong session id value")

        next_request = lambda do
          env = MockWebRequest.new("REQUEST_METHOD" => "GET") do |result|
            assert(result.first == 200, "not an HTTP 200 response")

            EM.next_tick do
              assert(xpt.headers_sent?, "initial header was not sent")

              assert(env.data.size == 1, "initial header response is not right")
              assert(env.data.first == "--socketio\n", "could not see first multipart boundary")

              b.reply(sid, "More replies")
              assert(env.data.size == 2, "additional reply was not sent to the connection")

              xpt.maxed_outbound_timer
              assert(!xpt.connected?, "did not disconnect")

              EM.stop
            end
          end

          response = nil
          performed = false
          to = "/#{session_id}"
          assert_nothing_raised { performed, response = b.handle_request(env, 'xhr-multipart', to, p) }
          assert(b.sessions.count == 1)

          sid = nil
          b.sessions.each_key { |id| sid = id }
          xpt = b.sessions[sid][:transport]
          assert(xpt.kind_of?(Palmade::SocketIoRack::Transports::XhrMultipart), "returned the wrong transport")

          assert(performed, "original request not performed")
          assert(response.first == -1, "response is not an async response")
        end
      end
    end
  end
end
