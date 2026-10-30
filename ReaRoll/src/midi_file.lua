-- @noindex
-- Standard MIDI File type 0/1 codec. Timing is stored in quarter notes.
local M={}
local function vlq(n)
  assert(n>=0 and n<=0x0FFFFFFF and n%1==0,'MIDI delta exceeds the SMF range')
  local bytes={n&127};n=n>>7
  while n>0 do table.insert(bytes,1,(n&127)|128);n=n>>7 end
  return string.char(table.unpack(bytes))
end
local function read_vlq(raw,pos,last)
  local value=0
  for _=1,4 do assert(pos<=last,'Truncated MIDI variable-length number');local b=raw:byte(pos);pos=pos+1;value=(value<<7)|(b&127);if b<128 then return value,pos end end
  error('MIDI variable-length number exceeds four bytes')
end
function M.decode(raw)
  local ok,result=xpcall(function()
    assert(type(raw)=='string'and #raw<=16777216 and #raw>=14,'Choose a valid MIDI file smaller than 16 MB')
    assert(raw:sub(1,4)=='MThd','Missing MIDI header')
    local size=string.unpack('>I4',raw,5);assert(size>=6 and size+8<=#raw,'Invalid MIDI header length')
    local format,tracks,division=string.unpack('>I2I2I2',raw,9)
    assert((format==0 or format==1)and tracks>0 and tracks<=1024 and(format~=0 or tracks==1),'Only synchronous MIDI file types 0 and 1 are supported')
    assert(division>0 and division<0x8000,'SMPTE-timed MIDI files are not supported; use musical-beat timing')
    local file={format=format,division=division,tracks={},span=0};local pos=9+size;local total=0
    while #file.tracks<tracks do
      assert(pos+7<=#raw,'Missing MIDI track chunk');local kind=raw:sub(pos,pos+3);local bytes=string.unpack('>I4',raw,pos+4);pos=pos+8
      local ending=pos+bytes-1;assert(ending<=#raw,'Truncated MIDI track')
      if kind=='MTrk'then
        local track={events={},name='Track '..(#file.tracks+1),span=0};local tick,running=0,nil
        while pos<=ending do
          local delta;delta,pos=read_vlq(raw,pos,ending);tick=tick+delta;assert(tick<=2147483647,'MIDI track is too long')
          assert(pos<=ending,'Missing MIDI event');local status=raw:byte(pos)
          if status<128 then assert(running,'Running status has no preceding channel status');status=running else pos=pos+1 end
          local message
          if status<0xF0 then
            assert(status>=0x80,'Invalid MIDI status');running=status
            local count=(status>>4==12 or status>>4==13)and 1 or 2
            assert(pos+count-1<=ending,'Truncated channel event')
            local body=raw:sub(pos,pos+count-1);for i=1,#body do assert(body:byte(i)<128,'Invalid MIDI data byte')end
            message=string.char(status)..body;pos=pos+count
          elseif status==0xFF then
            running=nil;assert(pos<=ending,'Missing MIDI meta type');local meta=raw:byte(pos);pos=pos+1
            local length;length,pos=read_vlq(raw,pos,ending);assert(pos+length-1<=ending,'Truncated MIDI meta event')
            local body=raw:sub(pos,pos+length-1);pos=pos+length
            if meta==3 then track.name=body end
            if meta==0x2F then assert(length==0,'Invalid end-of-track event');track.span=tick/division;pos=ending+1;break end
            message=string.char(255,meta)..body
          elseif status==0xF0 or status==0xF7 then
            running=nil;local length;length,pos=read_vlq(raw,pos,ending);assert(pos+length-1<=ending,'Truncated SysEx')
            local body=raw:sub(pos,pos+length-1);pos=pos+length
            assert(status==0xF0 and body:byte(-1)==0xF7,'Split or escaped SysEx is not supported; use complete SysEx messages')
            message=string.char(status)..body
          else error('Unsupported system status in MIDI file')end
          total=total+1;assert(total<=500000,'MIDI file contains too many events')
          track.events[#track.events+1]={q=tick/division,msg=message,order=#track.events+1};track.span=tick/division
        end
        file.tracks[#file.tracks+1]=track;file.span=math.max(file.span,track.span)
      end
      pos=ending+1
    end
    return file
  end,function(err)return tostring(err)end)
  if not ok then return nil,result end;return result
end
function M.encode(events,span,division)
  division=division or 960
  local ok,result=xpcall(function()
    assert(type(division)=='number'and division%1==0 and division>0 and division<32768,'Invalid MIDI resolution')
    local sorted={}
    for i,event in ipairs(events)do assert(type(event.q)=='number'and event.q==event.q and event.q>=0 and event.q<1e7,'Invalid event time');sorted[#sorted+1]={tick=math.floor(event.q*division+.5),msg=event.msg,order=event.order or i}end
    table.sort(sorted,function(a,b)if a.tick~=b.tick then return a.tick<b.tick end;return a.order<b.order end)
    local chunks,last={},0
    for _,event in ipairs(sorted)do
      local msg=event.msg;assert(type(msg)=='string'and #msg>0,'Empty MIDI message');local status=msg:byte(1);local payload
      if status>=0x80 and status<0xF0 then
        local count=(status>>4==12 or status>>4==13)and 2 or 3;assert(#msg==count,'Invalid channel message size')
        for i=2,#msg do assert(msg:byte(i)<128,'Invalid MIDI data byte')end;payload=msg
      elseif status==255 then assert(#msg>=2,'Invalid meta message');if msg:byte(2)~=0x2F then payload=msg:sub(1,2)..vlq(#msg-2)..msg:sub(3)end
      elseif status==0xF0 then assert(msg:byte(-1)==0xF7,'Incomplete SysEx');payload=string.char(0xF0)..vlq(#msg-1)..msg:sub(2)
      else error('Unsupported MIDI message for file export')end
      if payload then chunks[#chunks+1]=vlq(event.tick-last)..payload;last=event.tick end
    end
    local ending=math.max(last,math.floor((span or 0)*division+.5));chunks[#chunks+1]=vlq(ending-last)..string.char(255,47,0)
    local body=table.concat(chunks);assert(#body<=16777216,'Export exceeds 16 MB')
    return 'MThd'..string.pack('>I4I2I2I2',6,0,1,division)..'MTrk'..string.pack('>I4',#body)..body
  end,function(err)return tostring(err)end)
  if not ok then return nil,result end;return result
end
return M
