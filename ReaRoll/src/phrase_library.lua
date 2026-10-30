-- @noindex
local Notes=require 'src.note_events'
local M={section='ReaRoll.Phrases'}
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)if not s or #s%2~=0 or s:find('[^%da-f]')then return nil end;return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<1e8 end
function M.capture(app)
  if not app.take then return nil,'Select a MIDI item.'end
  if reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return nil,'The MIDI item is no longer available.'end
  if app.transform_preview or app.gesture then return nil,'Apply or cancel the current edit first.'end
  local chosen=require('src.selection').list(app.selection,app.cache:get(false))
  if #chosen==0 then return nil,'Select notes to save.'end
  local stream=Notes.read(app.take);if not stream then return nil,'Could not read MIDI.'end
  local first,last=math.huge,-math.huge
  for _,n in ipairs(chosen)do first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s));last=math.max(last,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e))end
  local out={span=last-first,notes={}}
  for _,n in ipairs(chosen)do
    local source=stream.notes[n.index+1];if not source then return nil,'The note selection changed. Select it again.'end
    local note={offset=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)-first,length=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)-reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s),source=source}
    out.notes[#out.notes+1]=note
  end
  return out
end
function M.encode(phrase)
  local out={'RRPHRASE1\t'..string.format('%.17g',phrase.span)}
  for i,n in ipairs(phrase.notes)do
    out[#out+1]=table.concat({'n',string.format('%.17g',n.offset),string.format('%.17g',n.length),n.source.on.flags,n.source.off.flags,hex(n.source.on.msg),hex(n.source.off.msg)},'\t')
    for _,e in ipairs(n.source.notation or {})do out[#out+1]=table.concat({'t',i,e.flags,hex(e.msg)},'\t')end
  end
  return table.concat(out,'\n')
end
function M.decode(raw)
  if type(raw)~='string' or #raw>1000000 then return nil,'Phrase is missing or too large.'end
  local lines={};for line in (raw..'\n'):gmatch('(.-)\n')do lines[#lines+1]=line end
  local span=tonumber(lines[1]:match('^RRPHRASE1\t(.+)$'))
  if not finite(span) or span<=0 then return nil,'Invalid phrase duration.'end
  local out={span=span,notes={}}
  for i=2,#lines do
    local f={};for field in (lines[i]..'\t'):gmatch('(.-)\t')do f[#f+1]=field end
    if f[1]=='n' and #f==7 then
      local offset,length,flags,off_flags=tonumber(f[2]),tonumber(f[3]),tonumber(f[4]),tonumber(f[5])
      local on,off=unhex(f[6]),unhex(f[7])
      if not finite(offset) or offset<0 or not finite(length) or length<=0 or offset+length>span+1e-6 then return nil,'Invalid phrase note timing.'end
      if not flags or flags%1~=0 or flags<0 or flags>255 or not off_flags or off_flags%1~=0 or off_flags<0 or off_flags>255 then return nil,'Invalid note flags.'end
      if not on or not off or #on<3 or #off<3 or on:byte(1)&0xF0~=0x90 or on:byte(3)==0 or on:byte(2)>127 or on:byte(3)>127 then return nil,'Invalid phrase note message.'end
      if off:byte(1)&15~=on:byte(1)&15 or off:byte(2)~=on:byte(2) or off:byte(3)>127 or not (off:byte(1)&0xF0==0x80 or off:byte(1)&0xF0==0x90 and off:byte(3)==0)then return nil,'Invalid note-off pairing.'end
      local source={pitch=on:byte(2),chan=on:byte(1)&15,vel=on:byte(3),selected=flags&1~=0,muted=flags&2~=0,on={flags=flags,msg=on},off={flags=off_flags,msg=off},notation={}}
      out.notes[#out.notes+1]={offset=offset,length=length,source=source}
      if #out.notes>4096 then return nil,'Phrase exceeds 4096 notes.'end
    elseif f[1]=='t' and #f==4 then
      local n=out.notes[tonumber(f[2])];local flags=tonumber(f[3]);local msg=unhex(f[4])
      if not n or not flags or flags%1~=0 or flags<0 or flags>255 or not msg or msg:sub(1,7)~=string.char(0xFF,0x0F)..'NOTE ' then return nil,'Invalid note notation.'end
      n.source.notation[#n.source.notation+1]={flags=flags,msg=msg}
    else return nil,'Malformed phrase entry.'end
  end
  if #out.notes==0 then return nil,'The phrase contains no notes.'end
  return out
end
function M.names()
  local out={};for h in reaper.GetExtState(M.section,'names'):gmatch('[^\n]+')do local name=unhex(h);if name then out[#out+1]=name end end;return out
end
function M.save(name,phrase)
  name=(name or ''):match('^%s*(.-)%s*$');if name=='' or #name>80 then return false,'Enter a phrase name of 1–80 bytes.'end
  local raw=M.encode(phrase);local valid,notice=M.decode(raw);if not valid then return false,notice end
  local names=M.names();local found=false;for _,n in ipairs(names)do if n==name then found=true end end;if not found then names[#names+1]=name end;table.sort(names)
  local encoded={};for _,n in ipairs(names)do encoded[#encoded+1]=hex(n)end
  reaper.SetExtState(M.section,'phrase_'..hex(name),raw,true);reaper.SetExtState(M.section,'names',table.concat(encoded,'\n'),true);return true
end
function M.load(name)return M.decode(reaper.GetExtState(M.section,'phrase_'..hex(name)))end
function M.delete(name)
  local out={};for _,n in ipairs(M.names())do if n~=name then out[#out+1]=hex(n)end end
  reaper.SetExtState(M.section,'names',table.concat(out,'\n'),true);reaper.DeleteExtState(M.section,'phrase_'..hex(name),true)
end
function M.insert(app,phrase,anchor)
  if not app.take or app.transform_preview or app.lane_tool_preview or app.gesture or app.edit.active then return false,'Select a MIDI item and finish the active edit first.'end
  if reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false,'The MIDI item is no longer available.'end
  if not finite(anchor)then return false,'Choose a valid insertion time.'end
  if reaper.GetMediaItemTake_Item and reaper.GetMediaItemInfo_Value then local item=reaper.GetMediaItemTake_Item(app.take);if item and reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'The destination MIDI item is locked.'end end
  if anchor<app.item_start_qn or anchor+phrase.span>app.item_end_qn+1e-8 then return false,'The phrase will not fit here. Move the edit cursor or extend the item.'end
  local notes=app.cache:get(false);local plan={}
  for _,n in ipairs(phrase.notes)do
    local s=reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor+n.offset);local e=reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor+n.offset+n.length)
    s,e=math.floor(s+.5),math.floor(e+.5)
    if e<=s then return false,'A phrase note is shorter than one MIDI tick.'end
    if app.settings.prevent_overlaps then for _,old in ipairs(notes)do if old.chan==n.source.chan and old.pitch==n.source.pitch and old.s<e and old.e>s then return false,'The phrase overlaps existing notes on the same pitch/channel. Choose an empty destination or disable overlap prevention.'end end end
    plan[#plan+1]={source=n.source,s=s,e=e}
  end
  local wanted={};local ok,notice=xpcall(function()
    app.edit:begin('ReaRoll: insert saved phrase',app.take);local a=app.edit.active;a.allow_overlaps=true
    for _,p in ipairs(plan)do local i=a.stream:insert_fragment(p.source,p.s,p.e,p.source.pitch);a.touched[i]=true;a.changed=true;a.note_changed=true;wanted[#wanted+1]={s=p.s,e=p.e,pitch=p.source.pitch,vel=p.source.vel,chan=p.source.chan}end
    app.edit:finish()
  end,debug.traceback)
  if not ok then if app.edit.active then app.edit:cancel()end;return false,notice end
  app.cache:rebuild();app:reselect_notes(wanted);return true
end
return M
