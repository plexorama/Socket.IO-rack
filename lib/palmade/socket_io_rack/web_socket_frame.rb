#
# WebSockets hybi-10 framing support (Sec-WebSockets-Version: 8)
# see http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-10#section-4
#
# Author:: plexorama@gmail.com
# 
module Palmade::SocketIoRack
 class WebSocketFrame

  attr_accessor :maskBytes, :frameHeader, :config, :protocolError, :frameTooLarge, :parseState, :closeStatus, :parseState
  attr_accessor :fin, :rsv1, :rsv2, :rsv3, :mask, :opcode, :length, :binaryPayload, :dropReason, :maskPos

  def initialize( )

    self.maskBytes = []
    self.frameHeader = []
    self.protocolError = false
    self.frameTooLarge = false
    self.parseState = :decode_header
    self.closeStatus = -1
  end

  def applyMask( buffer, offset, len)
    to = offset + length
    for i in offset..to-1
      buffer[i] = (buffer[i].ord ^ self.maskBytes[self.maskPos].ord).chr 
      self.maskPos = (self.maskPos + 1) & 3
    end
  end

  def flag(val, mask)
    mask == value(val, mask)
  end

  def value(val, mask)
    val & mask
  end
  
  def frame(payload, nullMask=true)
   maskKey = 0
   headerLength = 2
   data = nil
   outputPos = 0
   firstByte = 0x00
   secondByte =0x00

   firstByte |= 0x80 if self.fin
   firstByte |= 0x40 if self.rsv1
   firstByte |= 0x20 if self.rsv2
   firstByte |= 0x10 if self.rsv3
   secondByte |= 0x80 if self.mask
   firstByte |= (self.opcode & 0x0f)
   self.binaryPayload = payload

   if self.opcode == 0x08
     self.length = 2
     self.length += self.binaryPayload.size if self.binaryPayload
     data = Array.new( 2, 0 ) 
     data[0..1] = [self.closeStatus].pack("n").split //
     data.push *self.binaryPayload if self.length > 2

   elsif self.binaryPayload
     data = self.binaryPayload
     self.length = data.size
   else
     self.length = 0
   end

   if self.length <= 125
     secondByte |= (self.length & 0x7F)
   elsif (self.length > 125 && self.length <= 0xffff)
     secondByte |= 126
   elsif self.lengt > 0xFFFF
     secondByte |= 127
   end
   
   if !nullMask
     maskKey = (rand * 0xFFFFFFFF).to_i
   else
     maskKey = 0x0
   end

   self.maskBytes = [maskKey].pack("N").split(//)
   self.maskPos = 0

   #p [ firstByte, secondByte, self.length, maskKey ]
   output = [ firstByte.chr, secondByte.chr, *packLength(self.length), *packMask(maskKey), ]

   # push data if not alredy pushed in packMask
   if self.mask
     output.push *applyMask(data, 0, data.size) 
   else
     output.push *data
   end
   output.join
  end

  def packLength(len)
    #p ["packLength", len ]
    if len > 125 && len <= 0xFFFF
      [len].pack( "n").split //
    elsif len > 0xFFFF
      [len].reverse.pack("Q").split //
    else
      []
    end
  end

  def packMask( m )
    if self.mask
      self.maskBytes
    else
      []
    end
  end

  def process(buffer)

    if self.parseState == :decode_header
      if buffer.size >= 2
        self.frameHeader = buffer.slice!(0,2)
        firstByte = self.frameHeader[0].ord
        secondByte = self.frameHeader[1].ord
        self.fin = flag(firstByte, 0x80) 
        self.rsv1 = flag(firstByte, 0x40)
        self.rsv2 = flag(firstByte, 0x20)
        self.rsv3 = flag(firstByte, 0x10)
        self.mask = flag(secondByte, 0x80)
        self.opcode = value(firstByte, 0x0F)
        self.length = value(secondByte, 0x7F)

        if self.opcode > 0x08 then
          if self.length > 125 then
            self.protocolError = true
            self.dropReason = "Illegal control frame longer than 125 bytes."
	    return true
          end

          if !self.fin then
  	    self.protocolError = true
  	    self.dropReason = "Control frames must not be fragmented."
	    return true
          end
        end
      end

      if self.length == 126 then
	self.parseState = :waiting_for_16bit_length
      elsif self.length == 127 then
        self.parseState = :waiting_for_64bit_length
      else
        self.parseState = :waiting_for_mask_key
      end
    end 

    if self.parseState == :waiting_for_16bit_length
      if buffer.size >= 2
        len = buffer.slice!(0,2)
        self.frameHeader.push *len
	self.length = len.join.unpack("n")[0]
	self.parseState = :waiting_for_mask_key
      end
    elsif self.parseState == :waiting_for_64bit_length
      if buffer.size >= 8
        len = buffer.slice!(0,8)
	self.frameHeader.push *len
	self.length = len.join.reverse.unpack("Q")[0]
	self.parseState = :waiting_for_mask_key
      end
    end

    if self.parseState == :waiting_for_mask_key
      if self.mask
        if buffer.size >= 4
          self.maskBytes = buffer.slice!(0, 4)

	  #p ["self.maskBytes", self.maskBytes ]
	  self.maskPos = 0
	  self.parseState = :waiting_for_payload
	end
      else
        self.parseState = :waiting_for_payload
      end
    end
    
    if self.parseState == :waiting_for_payload
      if self.length == 0
        self.binaryPayload = []
	self.parseState = :complete
	return true
      end

      #p [buffer.size, self.length]
      if buffer.size >= self.length
        self.binaryPayload = buffer.slice!(0, self.length )
	if self.mask
          #p [ "applying mask", self.maskBytes ]
	  applyMask( self.binaryPayload, 0, self.length )
	end

        #p ["self.opcode", self.opcode.chr]
	if self.opcode == 0x08
	  self.closeStatus = self.binaryPayload.slice!(0,2).join.unpack "n"
	end
          
	self.parseState = :complete
	return true
      end
    end
    
    false
  end
 end
end
