-- @noindex
local Music=require 'src.music'
local Map=require 'src.instrument_map'
local M={key='P_EXT:ReaRollChordTrack'}
local function finite(n)return type(n)=='number'and n==n and n>=0 and n<1e7 end
function M.new()return {enabled=false,chords={}}end
function M.pitches(entry,register)
  local root=register and math.floor(register/12)*12+entry.root%12 or entry.root
  return Music.chord_pitches({chord_name=entry.quality,chord_inversion=entry.inversion,chord_diatonic=false},root)
end
function M.label(entry)return Music.chord_label(M.pitches(entry),entry.root)end
function M.validate(data)
  if type(data)~='table'or type(data.chords)~='table'or #data.chords>512 then return false end
  local sorted={}
  for _,a in ipairs(data.chords)do
    if not finite(a.start_qn)or not finite(a.end_qn)or a.end_qn<=a.start_qn or type(a.root)~='number'or a.root%1~=0 or a.root<0 or a.root>127 or not Music.chords[a.quality]or type(a.inversion)~='number'or a.inversion%1~=0 or a.inversion<0 or a.inversion>=#Music.chords[a.quality]then return false end
    sorted[#sorted+1]=a
  end
  table.sort(sorted,function(a,b)return a.start_qn<b.start_qn end)
  for i=2,#sorted do if sorted[i].start_qn<sorted[i-1].end_qn-1e-9 then return false end end
  return true
end
function M.encode(data)
  assert(M.validate(data),'Invalid chord track')
  local out={'RRCHORD1\t'..(data.enabled and 1 or 0)}
  for _,a in ipairs(data.chords)do out[#out+1]=string.format('%.17g\t%.17g\t%d\t%s\t%d',a.start_qn,a.end_qn,a.root,a.quality,a.inversion)end
  return table.concat(out,'\n')
end
function M.decode(raw)
  if raw==nil or raw==''then return M.new()end
  if type(raw)~='string'or #raw>100000 then return nil,'Chord track data is too large.'end
  local header=raw:match('^RRCHORD1\t([01])');if not header then return nil,'Unknown chord track format.'end
  local data={enabled=header=='1',chords={}};local first=true
  for line in (raw..'\n'):gmatch('(.-)\n')do
    if first then if line~='RRCHORD1\t'..header then return nil,'Invalid chord track header.'end;first=false
    else local a,b,r,q,i=line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$')
      if not a then return nil,'Malformed chord entry.'end
      data.chords[#data.chords+1]={start_qn=tonumber(a),end_qn=tonumber(b),root=tonumber(r),quality=q,inversion=tonumber(i)}
    end
  end
  if not M.validate(data)then return nil,'Use valid chords with non-overlapping positive time ranges.'end
  return data
end
function M.copy(data)return assert(M.decode(M.encode(data)))end
function M.refresh(app,force)
  local track=Map.track(app);local now=reaper.time_precise()
  if not force and track==app.chord_track_source and now<(app.next_chord_poll or 0)then return end
  app.next_chord_poll=now+.2
  local raw='';if track then local ok,value=reaper.GetSetMediaTrackInfo_String(track,M.key,'',false);if ok then raw=value end end
  if force or track~=app.chord_track_source or raw~=app.chord_track_raw then
    local data,notice=M.decode(raw);app.chord_track=data or M.new();app.chord_track_notice=notice;app.chord_track_source=track;app.chord_track_raw=raw;app.chord_track_draft=nil;app.chord_sequence_preview=nil;app.chord_insert_review=nil
  end
end
function M.save(app,data)
  local track=Map.track(app)
  if not track or not M.validate(data)then return false,'Select a track and enter valid, non-overlapping chords.'end
  if app.gesture or app.edit and app.edit.active or app.transform_preview then return false,'Finish the active edit first.'end
  local raw=M.encode(data);local _,before=reaper.GetSetMediaTrackInfo_String(track,M.key,'',false)
  if raw==before then return true end
  reaper.Undo_BeginBlock2(0);local ok=reaper.GetSetMediaTrackInfo_String(track,M.key,raw,true)
  reaper.Undo_EndBlock2(0,'ReaRoll: chord track',ok and 1 or 0)
  if not ok then return false,'Could not save the chord track.'end
  app.chord_track=data;app.chord_track_source=track;app.chord_track_raw=raw;return true
end
function M.at(app,q)
  if app.chord_track_source~=Map.track(app)then M.refresh(app,true)end
  local data=app.chord_track
  if data and data.enabled then for _,a in ipairs(data.chords)do if q>=a.start_qn and q<a.end_qn then return a end end end
end
function M.capture(app)
  if not app.take or app.multi_edit_mode then return nil,'Select notes in one active item.'end
  local selected=require('src.selection').list(app.selection,app.cache:get(false));local groups={}
  for _,n in ipairs(selected)do local group=groups[n.s]or {notes={},ending=n.e};groups[n.s]=group;group.notes[#group.notes+1]=n.pitch;group.ending=math.min(group.ending,n.e)end
  local data={enabled=true,chords={}}
  for ppq,group in pairs(groups)do
    table.sort(group.notes);local pcs={};for _,p in ipairs(group.notes)do pcs[p%12]=true end
    local found
    for _,candidate in ipairs(group.notes)do
      for _,quality in ipairs(Music.chord_order)do
        local expected={};for _,interval in ipairs(Music.chords[quality])do expected[(candidate+interval)%12]=true end
        local same=true;for pc=0,11 do if (pcs[pc]or false)~=(expected[pc]or false)then same=false;break end end
        if same then
          local root=candidate;while root>group.notes[1]do root=root-12 end
          local inversion=0;for i,interval in ipairs(Music.chords[quality])do if (root+interval)%12==group.notes[1]%12 then inversion=i-1;break end end
          found={start_qn=reaper.MIDI_GetProjQNFromPPQPos(app.take,ppq),end_qn=reaper.MIDI_GetProjQNFromPPQPos(app.take,group.ending),root=root<0 and root%12 or root,quality=quality,inversion=inversion};break
        end
      end
      if found then break end
    end
    if not found then return nil,'Some selected onsets do not match a supported chord. Select complete chords with aligned starts.'end
    data.chords[#data.chords+1]=found
  end
  table.sort(data.chords,function(a,b)return a.start_qn<b.start_qn end)
  if #data.chords==0 or not M.validate(data)then return nil,'Select complete non-overlapping chords with aligned starts.'end
  return data
end
function M.plan(app,data)
  if not app.take then return nil,'Select an active MIDI item first.'end
  if not M.validate(data)then return nil,'Invalid chord progression.'end
  local channel=app.settings.channel or 0;local velocity=app.settings.default_velocity or app.settings.velocity or 96
  local plan={};local existing=app.cache:get(false)
  for _,a in ipairs(data.chords)do
    if a.start_qn<app.item_start_qn-1e-8 or a.end_qn>app.item_end_qn+1e-8 then return nil,'The chord progression extends outside the active MIDI item.'end
    local s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,a.start_qn)+.5)
    local e=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,a.end_qn)+.5)
    if e<=s then return nil,'A chord is shorter than one MIDI tick.'end
    for _,pitch in ipairs(M.pitches(a))do
      if app.settings.prevent_overlaps then for _,n in ipairs(existing)do if n.chan==channel and n.pitch==pitch and n.s<e and n.e>s then return nil,'A chord overlaps existing notes on the drawing channel. Choose an empty range or disable overlap prevention.'end end end
      plan[#plan+1]={s=s,e=e,pitch=pitch,chan=channel,vel=velocity}
    end
  end
  return plan
end
function M.insert(app,data)
  if not app.take or app.multi_edit_mode or app.edit.active or app.gesture or app.transform_preview or app.lane_tool_preview then return false,'Select one active MIDI item and finish the current edit.'end
  if reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false,'The source item is no longer available.'end
  local item=reaper.GetMediaItemTake_Item and reaper.GetMediaItemTake_Item(app.take)
  if item and reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'Unlock the item first.'end
  local plan,notice=M.plan(app,data);if not plan then return false,notice end
  if #plan==0 then return false,'Add chords before inserting a progression.'end
  local ok,err=xpcall(function()
    app.edit:begin('ReaRoll: insert chord progression',app.take);app.edit.active.allow_overlaps=true
    for _,n in ipairs(plan)do assert(app.edit:insert(app.take,n.s,n.e,n.pitch,n.vel,n.chan,true,false))end
    assert(app.edit:finish()~=false)
  end,debug.traceback)
  if not ok then if app.edit.active then app.edit:cancel()end;return false,err end
  app.cache:rebuild();app:reselect_notes(plan);return true
end
function M.draw(app,d,v,y,height)
  local data=app.chord_track;if not data or not data.enabled then return end
  local I,c,T=app.ImGui,app.ctx,app.theme
  I.DrawList_PushClipRect(d,v.x,y,v.x+v.w,y+height,true)
  for index,a in ipairs(data.chords)do
    local left,right=math.max(v.x,v:x_from_qn(a.start_qn)),math.min(v.x+v.w,v:x_from_qn(a.end_qn))
    if right>left then
      I.DrawList_AddRectFilled(d,left,y,right,y+height,(T.note&0xFFFFFF00)|75)
      I.DrawList_AddLine(d,left,y,left,y+height,T.selected_edge)
      I.DrawList_PushClipRect(d,left,y,right,y+height,true);I.DrawList_AddText(d,left+4,y,T.text,M.label(a));I.DrawList_PopClipRect(d)
      local mx,my=I.GetMousePos(c)
      if mx>=left and mx<right and my>=y and my<y+height then I.SetTooltip(c,M.label(a)..' / '..a.start_qn..'–'..a.end_qn..' beats')
      end
    end
  end
  I.DrawList_PopClipRect(d)
end
return M
