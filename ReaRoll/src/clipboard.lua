-- @noindex
local Selection=require 'src.selection'
local U=require 'src.util'
local Notes=require 'src.note_events'
local Expression=require 'src.expression'
local M={}

local function selected(app) return Selection.list(app.selection,app.cache:get(false)) end
function M.copy(app)
  local notes=selected(app); if #notes==0 then return false end
  local first=math.huge
  for _,n in ipairs(notes) do first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)) end
  local data={}
  local stream=Notes.read(app.take);local has_expression=app.settings.mpe_enabled==true
  local chosen={};for _,n in ipairs(notes)do chosen[n.index]=true end
  local follow
  if stream and app.settings.cc_follows_notes==true then
    local changes={};for _,n in ipairs(notes)do changes[#changes+1]={index=n.index,values={}}end
    local notice;follow,notice=require('src.cc_follow').prepare(stream,changes,app.settings,true)
    if follow==false then app.expression_notice=notice;return false end
  end
  if stream and not app.settings.mpe_enabled then local ok,notice=require('src.shared_slide').require_complete(stream,chosen);if not ok then app.expression_notice=notice;return false end end
  for _,n in ipairs(notes) do
    local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)
    local item={offset=sq-first,length=eq-sq,pitch=n.pitch,vel=n.vel,chan=n.chan,muted=n.muted}
    if stream then
      local source=stream.notes[n.index+1]
      local effective=require('src.slide_links').expression_settings(source,app.settings)
      local owned,notice={}
      if effective then
        local cohort
        if effective.expression_pitch_only then cohort,notice=require('src.slide_links').cohort(stream,source,chosen);if not cohort then app.expression_notice=notice;return false end end
        if follow and follow.voices[source.index].owned then owned=follow.voices[source.index].owned
        else owned,notice=Expression.capture(stream,source,effective,cohort)end
      end
      if not owned then app.expression_notice=notice;return false end
      if owned.sustained and not follow then app.expression_notice='Enable CC follows notes to copy this pedal-held voice with its expression.';return false end
      item.source=source;item.expression={};has_expression=has_expression or #owned>0
      for _,entry in ipairs(owned)do
        local event=entry.event
        item.expression[#item.expression+1]={offset=reaper.MIDI_GetProjQNFromPPQPos(app.take,event.ppq)-sq,flags=event.flags,msg=event.msg,order=event.order,shape=entry.shape and {flags=entry.shape.flags,msg=entry.shape.msg}}
      end
    end
    data[#data+1]=item
  end
  local controllers={}
  for _,entry in ipairs(follow and follow.events or {})do local event=entry.event
    controllers[#controllers+1]={offset=reaper.MIDI_GetProjQNFromPPQPos(app.take,event.ppq)-first,flags=event.flags,msg=event.msg,order=event.order,shape=entry.shape and{flags=entry.shape.flags,msg=entry.shape.msg}}
  end
  if follow and app.settings.mpe_enabled then
    local copied={events={},notes={}}
    for _,entry in ipairs(follow.events)do copied.events[#copied.events+1]=entry.event end
    local ending=require('src.voice_lifetime').index(copied,app.settings)
    for _,item in ipairs(data)do local source=item.source;local voice=follow.voices[source.index]
      if voice.owned and Expression.member(source.chan,app.settings)then
        local span=math.max(1,voice.owned.end_ppq-source.s);local copied_span=ending(source)-source.s
        for _,point in ipairs(item.expression)do point.offset=point.offset*copied_span/span end
        item.expression_span=reaper.MIDI_GetProjQNFromPPQPos(app.take,source.s+copied_span)-reaper.MIDI_GetProjQNFromPPQPos(app.take,source.s)
      end
    end
  end
  app.note_clipboard={notes=data,controllers=controllers,span_start=first,mpe=has_expression,follow=follow~=nil}; return true
end
function M.delete(app,name)
  local notes=selected(app); if #notes==0 then return false end
  app.edit:begin(name or 'ReaRoll: delete notes',app.take); local indices={}; for _,n in ipairs(notes) do indices[#indices+1]=n.index end
  app.edit:delete_indices(app.take,indices); local ok=app.edit:finish();if ok==false then return false end; app.cache:rebuild(); Selection.clear(app.selection); return true
end
function M.cut(app) if not M.copy(app) then return false end; return M.delete(app,'ReaRoll: cut notes') end
function M.bounds(clip)
  local first,last=0,0
  for _,n in ipairs(clip.notes)do first=math.min(first,n.offset);last=math.max(last,n.offset+n.length)
    for _,point in ipairs(n.expression or {})do first=math.min(first,n.offset+point.offset);last=math.max(last,n.offset+point.offset)end
  end
  for _,point in ipairs(clip.controllers or {})do first=math.min(first,point.offset);last=math.max(last,point.offset)end
  return first,last
end
function M.paste_at(app,anchor_qn,name,options)
  local clip=app.note_clipboard; if not clip or #clip.notes==0 then return false end
  local min_start,max_end=M.bounds(clip)
  anchor_qn=U.snap_time(app.settings,anchor_qn,clip.span_start)
  if max_end-min_start>(app.item_end_qn or math.huge)-(app.item_start_qn or 0)then app.expression_notice='The notes and their controllers do not fit inside this MIDI item.';return false end
  anchor_qn=math.max((app.item_start_qn or 0)-min_start,math.min(anchor_qn,(app.item_end_qn or anchor_qn+max_end)-max_end)); local wanted={}
  local planned={}
  if clip.mpe then
    if max_end>(app.item_end_qn or math.huge)-(app.item_start_qn or 0)then app.expression_notice='The complete phrase does not fit in this item.';return false end
    local stream=Notes.read(app.take);local existing=stream and stream.notes or app.cache:get(false)
    local lifetime=stream and require('src.voice_lifetime').index(stream,app.settings)
    local view={events={}}
    for _,event in ipairs(stream and stream.events or {})do view.events[#view.events+1]=event end
    for _,point in ipairs(clip.controllers or {})do view.events[#view.events+1]={ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor_qn+point.offset)+.5),msg=point.msg,order=#(stream and stream.events or {})+1+(point.order or 0)}end
    local ending=require('src.voice_lifetime').index(view,app.settings)
    for _,n in ipairs(clip.notes)do
      local first=reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor_qn+n.offset)
      local last=reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor_qn+n.offset+n.length)
      local plan={s=first,e=last,chan=n.chan,scale=1};planned[n]=plan
      if n.source and n.source.off then plan.off={order=#(stream and stream.events or {})+1+n.source.off.order}end
      if n.expression_span then
        plan.sounding_end=ending(plan)
        if plan.sounding_end==math.huge or plan.sounding_end>reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)then app.expression_notice='The pasted MPE voice needs a sustain release inside this MIDI item.';return false end
        local span=reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor_qn+n.offset+n.expression_span)-first
        plan.scale=(plan.sounding_end-first)/math.max(1,span)
      end
      if n.expression and(#n.expression>0 or app.settings.mpe_enabled and Expression.member(n.chan,app.settings))then
        for _,point in ipairs(n.expression)do local tick=reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor_qn+n.offset+point.offset*plan.scale);first=math.min(first,tick);last=math.max(last,tick)end
        for _,other in ipairs(existing)do if other.chan==n.chan and other.s<=last and(lifetime and lifetime(other)or other.e)>first then app.expression_notice='Paste would share an expression channel with another sounding note. Choose an empty time range.';return false end end
        for _,event in ipairs(stream and stream.events or {})do if Expression.message(event,n.chan)and event.ppq>=first and event.ppq<=last then
          local boundary=false
          if event.ppq==first then for _,other in ipairs(existing)do if other.chan==n.chan and(lifetime and lifetime(other)or other.e)==first then boundary=true;break end end end
          if not boundary then app.expression_notice='Recorded expression already occupies the destination channel. Choose an empty time range.';return false end
        end end
      end
    end
    for n,a in pairs(planned)do for other,b in pairs(planned)do if n~=other and a.chan==b.chan and Expression.member(a.chan,app.settings)and a.s<(b.sounding_end or b.e)and b.s<(a.sounding_end or a.e)then app.expression_notice='The pasted notes would share an MPE voice while sounding.';return false end end end
  end
  if options and options.preview then app.edit:begin_preview(app.take)else app.edit:begin(name or 'ReaRoll: paste notes',app.take)end
  local order_base=#app.edit.active.stream.events+1
  for _,n in ipairs(clip.notes) do
    local sq=anchor_qn+n.offset; local eq=sq+n.length; local s=reaper.MIDI_GetPPQPosFromProjQN(app.take,sq); local e=reaper.MIDI_GetPPQPosFromProjQN(app.take,eq)
    if n.source then
      local a=app.edit.active
      local index=a.stream:insert_fragment(n.source,s,e,n.pitch)
      a.stream:set(index,{selected=true});a.touched[index]=true;a.changed,a.note_changed=true,true
      if clip.follow then local pasted=a.stream.notes[index+1];pasted.on.order,pasted.off.order=order_base+n.source.on.order,order_base+n.source.off.order;pasted.on.original_ppq,pasted.off.original_ppq=pasted.s,pasted.e end
      for point_index,point in ipairs(n.expression or {})do
        local ppq=reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+point.offset*(planned[n]and planned[n].scale or 1))
        local event={ppq=math.floor(ppq+.5),flags=point.flags,msg=point.msg,order=point.offset<0 and(-1000000000+#a.stream.events)or point.offset==0 and (a.stream.notes[index+1].on.order-.5+point_index*.001) or #a.stream.events+1}
        if clip.follow and point.order then event.order=order_base+point.order end
        a.stream.events[#a.stream.events+1]=event
        if point.shape then a.stream.events[#a.stream.events+1]={ppq=event.ppq,flags=point.shape.flags,msg=point.shape.msg,order=event.order+.1}end
      end
    else app.edit:insert(app.take,s,e,n.pitch,n.vel,n.chan,true,n.muted)end
    wanted[#wanted+1]={s=s,e=e,pitch=n.pitch,vel=n.vel,chan=n.chan}
  end
  local a=app.edit.active
  for _,point in ipairs(clip.controllers or {})do
    local ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor_qn+point.offset)+.5)
    local event={ppq=ppq,flags=point.flags,msg=point.msg,order=point.order and order_base+point.order or #a.stream.events+1};a.stream.events[#a.stream.events+1]=event
    if point.shape then a.stream.events[#a.stream.events+1]={ppq=ppq,flags=point.shape.flags,msg=point.shape.msg,order=event.order+.1}end
    a.stream.dirty=true;a.changed=true
  end
  if app.edit:finish()==false then return false end; app.cache:rebuild(); app:reselect_notes(wanted); return true
end
function M.paste(app)
  local qn=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()); return M.paste_at(app,qn,'ReaRoll: paste notes')
end
function M.duplicate(app)
  local notes=selected(app); if #notes==0 then return false end
  local min_qn,max_qn=math.huge,-math.huge
  for _,n in ipairs(notes) do min_qn=math.min(min_qn,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)); max_qn=math.max(max_qn,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)) end
  if not M.copy(app) then return false end
  local first,last=M.bounds(app.note_clipboard)
  return M.paste_at(app,min_qn+math.max(app.settings.grid_qn,max_qn-min_qn,last-first),'ReaRoll: duplicate notes')
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
