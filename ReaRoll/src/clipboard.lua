-- @noindex
local Selection=require 'src.selection'
local U=require 'src.util'
local M={}

local function selected(app) return Selection.list(app.selection,app.cache:get(false)) end
function M.copy(app)
  local notes=selected(app); if #notes==0 then return false end
  local first=math.huge
  for _,n in ipairs(notes) do first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)) end
  local data={}
  for _,n in ipairs(notes) do
    local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)
    data[#data+1]={offset=sq-first,length=eq-sq,pitch=n.pitch,vel=n.vel,chan=n.chan,muted=n.muted}
  end
  app.note_clipboard={notes=data,span_start=first}; return true
end
function M.delete(app,name)
  local notes=selected(app); if #notes==0 then return false end
  app.edit:begin(name or 'ReaRoll: delete notes',app.take); local indices={}; for _,n in ipairs(notes) do indices[#indices+1]=n.index end
  app.edit:delete_indices(app.take,indices); app.edit:finish(); app.cache:rebuild(); Selection.clear(app.selection); return true
end
function M.cut(app) if not M.copy(app) then return false end; return M.delete(app,'ReaRoll: cut notes') end
function M.paste_at(app,anchor_qn,name)
  local clip=app.note_clipboard; if not clip or #clip.notes==0 then return false end
  local max_end=0; for _,n in ipairs(clip.notes) do max_end=math.max(max_end,n.offset+n.length) end
  anchor_qn=U.snap_time(app.settings,anchor_qn,clip.span_start)
  anchor_qn=math.max(app.item_start_qn or 0,math.min(anchor_qn,(app.item_end_qn or anchor_qn+max_end)-max_end)); local wanted={}
  app.edit:begin(name or 'ReaRoll: paste notes',app.take)
  for _,n in ipairs(clip.notes) do
    local sq=anchor_qn+n.offset; local eq=sq+n.length; local s=reaper.MIDI_GetPPQPosFromProjQN(app.take,sq); local e=reaper.MIDI_GetPPQPosFromProjQN(app.take,eq)
    app.edit:insert(app.take,s,e,n.pitch,n.vel,n.chan,true,n.muted); wanted[#wanted+1]={s=s,e=e,pitch=n.pitch,vel=n.vel}
  end
  app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted); return true
end
function M.paste(app)
  local qn=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()); return M.paste_at(app,qn,'ReaRoll: paste notes')
end
function M.duplicate(app)
  local notes=selected(app); if #notes==0 then return false end
  local min_qn,max_qn=math.huge,-math.huge
  for _,n in ipairs(notes) do min_qn=math.min(min_qn,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)); max_qn=math.max(max_qn,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)) end
  if not M.copy(app) then return false end; return M.paste_at(app,min_qn+math.max(app.settings.grid_qn,max_qn-min_qn),'ReaRoll: duplicate notes')
end

local function cc_matches(def,e,channel)
  return e.selected and (e.chan or 0)==channel and ((def.pitch and e.chanmsg==0xE0) or (def.status and e.chanmsg==def.status) or (def.cc~=nil and e.chanmsg==0xB0 and e.msg2==def.cc))
end
local function lane_matches(def,e,channel)
  return (e.chan or 0)==channel and ((def.pitch and e.chanmsg==0xE0) or (def.status and e.chanmsg==def.status) or (def.cc~=nil and e.chanmsg==0xB0 and e.msg2==def.cc))
end
local function cc_value(def,e) return def.pitch and ((e.msg3<<7)|e.msg2) or (def.status and e.msg2 or e.msg3) end
function M.chase_cc(app,def)
  if not def or not reaper.StuffMIDIMessage then return false end
  local channel=app.settings.channel or 0; local time
  if reaper.GetPlayState and (reaper.GetPlayState()&1)==1 and reaper.GetPlayPosition then time=reaper.GetPlayPosition()
  elseif reaper.GetCursorPosition then time=reaper.GetCursorPosition() end
  local ppq=time and reaper.MIDI_GetPPQPosFromProjQN(app.take,reaper.TimeMap2_timeToQN(0,time)) or -math.huge; local found
  for _,e in ipairs(app.cc_cache:get(false)) do if lane_matches(def,e,channel) and e.ppq<=ppq and (not found or e.ppq>found.ppq) then found=e end end
  local status=(def.pitch and 0xE0 or def.status or 0xB0)|channel; local msg2,msg3
  if def.pitch then local value=found and cc_value(def,found) or 8192; msg2,msg3=value&0x7F,(value>>7)&0x7F
  elseif def.status then msg2,msg3=found and cc_value(def,found) or 0,0
  else
    local defaults={[7]=100,[8]=64,[10]=64,[11]=127}; local value=found and found.msg3 or defaults[def.cc] or 0
    msg2,msg3=def.cc,value
  end
  reaper.StuffMIDIMessage(0,status,msg2,msg3); return true
end
function M.copy_cc(app,def)
  if not def then return false end; local selected={}; local first=math.huge
  for _,e in ipairs(app.cc_cache:get(false)) do if cc_matches(def,e,app.settings.channel or 0) then selected[#selected+1]=e; first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(app.take,e.ppq)) end end
  if #selected==0 then return false end; local points={}; local last=first
  for _,e in ipairs(selected) do local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,e.ppq); last=math.max(last,q); points[#points+1]={offset=q-first,value=cc_value(def,e),chan=e.chan or 0,muted=e.muted} end
  app.cc_clipboard={def={cc=def.cc,pitch=def.pitch,status=def.status,label=def.label},points=points,span=last-first,span_start=first}; return true
end
function M.delete_cc(app,def,name)
  local indices={}; for _,e in ipairs(app.cc_cache:get(false)) do if cc_matches(def,e,app.settings.channel or 0) then indices[#indices+1]=e.index end end
  if #indices==0 then return false end; app.edit:begin(name or 'ReaRoll: delete controller points',app.take); app.edit:delete_cc_indices(app.take,indices); app.edit:finish(); app.cc_cache:rebuild(); M.chase_cc(app,def); return true
end
function M.select_all_cc(app,def,selected)
  if not def then return false end; local changed=false
  for _,e in ipairs(app.cc_cache:get(false)) do local matches=(e.chan or 0)==(app.settings.channel or 0) and ((def.pitch and e.chanmsg==0xE0) or (def.status and e.chanmsg==def.status) or (def.cc~=nil and e.chanmsg==0xB0 and e.msg2==def.cc)); if matches then reaper.MIDI_SetCC(app.take,e.index,selected~=false,nil,nil,nil,nil,nil,nil,true); changed=true end end
  if changed then reaper.MIDI_Sort(app.take); app.cc_cache:invalidate(); app.cc_cache:rebuild() end; return changed
end
function M.cut_cc(app,def) if not M.copy_cc(app,def) then return false end; return M.delete_cc(app,def,'ReaRoll: cut controller points') end
function M.paste_cc_at(app,anchor_qn,name)
  local clip=app.cc_clipboard; if not clip or #clip.points==0 then return false end
  anchor_qn=U.snap_time(app.settings,anchor_qn,clip.span_start)
  local maximum=clip.span or 0; anchor_qn=math.max(app.item_start_qn,math.min(anchor_qn,app.item_end_qn-maximum)); app.edit:begin(name or 'ReaRoll: paste controller points',app.take)
  for _,p in ipairs(clip.points) do local ppq=reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor_qn+p.offset); local d=clip.def; if d.pitch then app.edit:insert_pitch(app.take,ppq,p.chan,p.value) elseif d.status then app.edit:insert_message(app.take,ppq,p.chan,d.status,p.value) else app.edit:insert_cc(app.take,ppq,p.chan,d.cc,p.value) end end
  app.edit:finish(); app.cc_cache:rebuild(); return true
end
function M.paste_cc(app) return M.paste_cc_at(app,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()),'ReaRoll: paste controller points') end
function M.duplicate_cc(app,def)
  if not M.copy_cc(app,def) then return false end; local first=math.huge
  for _,e in ipairs(app.cc_cache:get(false)) do if cc_matches(def,e,app.settings.channel or 0) then first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(app.take,e.ppq)) end end
  return M.paste_cc_at(app,first+math.max(app.settings.grid_qn,app.cc_clipboard.span or 0),'ReaRoll: duplicate controller points')
end
return M
