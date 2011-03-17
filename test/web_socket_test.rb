class Palmade::SocketIoRack::Base
  attr_reader :sessions
end

class WebSocketTest < Test::Unit::TestCase
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
        ws_conn = MockWebSocketConnection.new

        response = nil
        performed = false

        assert_nothing_raised { performed, response = b.handle_request({}, 'websocket', nil, p) }
        assert(b.sessions.count == 1)

        sid = nil
        b.sessions.each_key { |id| sid = id }
        wst = b.sessions[sid][:transport]
        assert(wst.kind_of?(Palmade::SocketIoRack::Transports::WebSocket), "returned the wrong transport")

        assert(b.sessions[sid][:session].new?, "session for resource was not properly initialize")
        assert(performed, "request was not performed properly")
        assert(response.first == 101, "response did not contain an http 101 protocol change request")

        wst.set_connection(ws_conn)
        wst.connected(ws_conn)

        assert(!b.sessions[sid][:session].new?, "session was not persisted properly")
        assert(!ws_conn.data.empty?, "connected event did not reply with the session id")

        encoded_session_id = b.send(:encode_messages, [ sid ])
        assert(ws_conn.data.first == encoded_session_id, "reply data is different from session_id")

        EM.stop
      end
    end
  end

  def test_resume_connect
    EM.run do
      EM.next_tick do
        p = Palmade::SocketIoRack::Persistence.new(:logger => nil, :store => :redis)

        # Step (1): Let's create a new session
        b = Palmade::SocketIoRack::Base.new
        ws_conn = MockWebSocketConnection.new

        response = nil
        performed = false

        assert_nothing_raised { performed, response = b.handle_request({}, 'websocket', nil, p) }
        assert(b.sessions.count == 1)

        sid = nil
        b.sessions.each_key { |id| sid = id }
        wst = b.sessions[sid][:transport]
        assert(wst.kind_of?(Palmade::SocketIoRack::Transports::WebSocket), "returned the wrong transport")

        wst.set_connection(ws_conn)
        wst.connected(ws_conn)

        session = b.sessions[sid][:session]
        session_id = session.session_id

        session["Hello"] = "World"
        session.push_outbox("Hello")

        session.push_inbox("World")
        session.push_inbox("Go")

        EM.next_tick do
          # the msgs on outbox should be pushed to the websocket connection
          assert(ws_conn.data.size == 2, "outbox msg was not pushed to the connection (original)")
          assert(ws_conn.data.last == "Hello", "pushed msg is wrong (original)")

          session.push_outbox("Yohooo")

          # Step (2): Let's setup a new web socket connection
          b = Palmade::SocketIoRack::Base.new

          to = "/#{session_id}"
          performed, response = b.handle_request({}, 'websocket', to, p)
          assert(b.sessions.count == 1)

          sid = nil
          b.sessions.each_key { |id| sid = id }
          wst = b.sessions[sid][:transport]

          wst.set_connection(ws_conn)
          wst.connected(ws_conn)

          session = b.sessions[sid][:session]
          assert(!session.new?, "was not able to resume the previously generated session")
          assert(session.session_id == session_id, "resumed session has a different session id")
          assert(session["Hello"] == "World", "saved session variable has a different value")
          assert(session.inbox_size == 2, "inbox queue does not contain the previously pushed messages")

          assert(session.pop_inbox == "World", "pushed inbox message is different on resumed session")
          assert(session.pop_inbox == "Go", "pushed inbox message is different on resumed session")

          EM.next_tick do
            # the msgs on outbox should be pushed to the websocket
            # connection
            assert(ws_conn.data.size == 3, "outbox msg was not pushed to the connection (resumed connection)")
            assert(ws_conn.data.last == "Yohooo", "pushed msg is wrong")

            EM.stop
          end
        end
      end
    end
  end

  def test_reply_with_websocket
    EM.run do
      EM.next_tick do
        p = Palmade::SocketIoRack::Persistence.new(:store => :redis)
        b = Palmade::SocketIoRack::Base.new

        response = nil
        performed = false

        performed, response = b.handle_request({}, 'websocket', nil, p)
        assert(b.sessions.count == 1)

        sid = nil
        b.sessions.each_key { |id| sid = id }

        wst = b.sessions[sid][:transport]
        ws_conn = MockWebSocketConnection.new

        wst.set_connection(ws_conn)
        wst.connected(ws_conn)

        session = b.sessions[sid][:session]
        b.reply(sid, "Hello", "World")

        assert(ws_conn.data.size == 2, "outbox queue is empty")
        assert(ws_conn.data[0].kind_of?(String), "outbox item is not a string")
        assert(ws_conn.data[1].kind_of?(String), "outbox item is not a string")

        EM.stop
      end
    end
  end
end
