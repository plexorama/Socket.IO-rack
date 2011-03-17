# -*- encoding: utf-8 -*-

module Palmade::SocketIoRack
  class Base
    DEFAULT_OPTIONS = { }

    Cxhrpolling = "xhr-polling".freeze
    Cwebsocket = "websocket".freeze
    Cxhrmultipart = "xhr-multipart".freeze

    Cmframe = "~m~".freeze
    Chframe = "~h~".freeze
    Cjframe = "~j~".freeze

    def initialize(options = { })
      @options = DEFAULT_OPTIONS.merge(options)
      @sessions = {}
    end

    def handle_request(env, transport_class, transport_options, persistence)
      case transport_class
      when Cwebsocket
        transport = Transports::WebSocket.new self
      when Cxhrpolling
        transport = Transports::XhrPolling.new self
      when Cxhrmultipart
        transport = Transports::XhrMultipart.new self
      else
        raise "Unsupported transport #{transport_class}"
      end
      transport.handle_request env, transport_options, persistence
    end

    def initialize_session!(transport, sess)
      @sessions[sess.session_id] = {:session => sess, :transport => transport}
    end

    def on_message(sid, msg); end # do nothing
    def on_connect(sid); end # do nothing
    def on_resume_connection(sid); end # do nothing
    def on_close(sid); end # do nothing
    def on_disconnected(sid); end # do nothing
    def on_heartbeat(sid, cycle_count); end # do nothing

    def fire_connect(sid)
      on_connect sid
      reply sid, sid

      @sessions[sid][:session].persist!
    end

    def fire_resume_connection(sid)
      on_resume_connection sid

      @sessions[sid][:session].renew!
    end

    def fire_message(sid, data)
      msgs = decode_messages data
      msgs.each do |msg|
        case msg[0,3]
        when Chframe
          hb = msg[3..-1]

          # puts "Got HB: #{hb}"
          session = @sessions[sid][:session]
          if session['heartbeat'] == hb
            # just got heartbeat
            session.delete 'heartbeat'
          else
            # TODO: Add support for wrong heartbeat message
          end
        else
          on_message sid, msg
        end
      end

      @sessions[sid][:session].renew!
    end

    def fire_close(sid)
      on_close sid
    end

    def fire_disconnected(sid)
      on_disconnected sid

      # let's remove the reference to the transport, to allow the
      # garbase collector to reclaim it
      @sessions[sid][:transport] = nil
    end

    def fire_heartbeat(sid, cycle_count)
      on_heartbeat sid, cycle_count

      session = @sessions[sid][:session]
      unless session.include?('heartbeat')
        hb = Time.now.to_s
        session['heartbeat'] = hb

        # puts "Sending HB: #{hb}"
        reply sid, "#{Chframe}#{hb}"
      else
        # TODO: Add support for handling if a previously sent
        # heartbeat did not get a reply
      end
    end

    def reply(sid, *msgs)
      if connected?(sid)
        @sessions[sid][:transport].send_data encode_messages(msgs.to_a.flatten)
      else
        deferred_reply sid, *msgs
      end
    end

    def deferred_reply(sid, *msgs)
      @sessions[sid][:session].push_outbox encode_messages(msgs.to_a.flatten)
    end

    def connected?(sid)
      transport = @sessions[sid][:transport]
      !transport.nil? && transport.connected?
    end

    protected

    def decode_messages(data)
      msgs = [ ]
      data = data.dup.force_encoding('UTF-8') if RUBY_VERSION >= "1.9"

      loop do
        case data.slice!(0,3)
        when '~m~'
          size, data = data.split('~m~', 2)
          size = size.to_i

          case data[0,3]
          when '~j~'
            msgs.push Yajl::Parser.parse(data[3, size - 3])
          when '~h~'
            # let's have our caller process the message
            msgs.push data[0, size]
          else
            msgs.push data[0, size]
          end

          # let's slize the message
          data.slice!(0, size)
        when nil, ''
          break
        else
          raise "Unsupported frame type #{data[0,3]}"
        end
      end

      msgs
    end

    def encode_messages(msgs)
      data = ""
      msgs.each do |msg|
        case msg
        when String
          # as-is
        else
          msg = "~j~#{Yajl::Encoder.encode(msg)}"
        end

        msg_len = msg.length
        data += "~m~#{msg_len}~m~#{msg}"
      end
      data
    end
  end
end
