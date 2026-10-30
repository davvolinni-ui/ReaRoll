-- @noindex
-- Incoming voice links travel with the destination in the saved overlap score.
local M={}
local function tag(e)return not e.deleted and e.msg:match('^..NOTE %d+ %d+ REAROLL_GLIDE 1 (.*)$')end
function M.get(note)
 if note.glide_channels then local out={};for _,ch in ipairs(note.glide_channels)do out[#out+1]=ch end;return out end
 for _,e in ipairs(note.notation or {})do local text=tag(e);if text then
  local out,seen={},{};if text=='-'then return out end
  if not text:match('^%d[%d,]*$')then return nil end
  for value in text:gmatch('%d+')do local ch=tonumber(value);if ch>15 then return nil end;if not seen[ch]then seen[ch]=true;out[#out+1]=ch end end
  return out
 end end
end
function M.set(stream,note,channels)
 for _,e in ipairs(note.notation or {})do if tag(e)then e.deleted=true end end
 local values,seen={},{};for _,ch in ipairs(channels)do if not seen[ch]then values[#values+1]=ch;seen[ch]=true end end;table.sort(values)
 if #values>0 and not seen[note.chan]then stream:set(note.index,{chan=values[1]})end
 local msg=string.char(255,15)..'NOTE '..note.chan..' '..note.pitch..' REAROLL_GLIDE 1 '..(#values>0 and table.concat(values,',')or '-')
 local e={ppq=note.s,flags=0,msg=msg,order=(note.on and note.on.order or #stream.events)+.01}
 stream.events[#stream.events+1]=e;note.notation=note.notation or {};note.notation[#note.notation+1]=e;note.glide_channels=nil;stream.dirty=true
end
function M.expand(notes,settings)
 local sorted={};for _,n in ipairs(notes)do sorted[#sorted+1]=n end
 table.sort(sorted,function(a,b)if a.s~=b.s then return a.s<b.s end;return(a.index or 0)<(b.index or 0)end)
 local out={}
 for _,note in ipairs(sorted)do
  local linked=M.get(note);local added=false
  if linked and not note.muted then for _,ch in ipairs(linked)do
   local sounding=false
   for i=#out,1,-1 do local source=out[i];if not source.muted and source.chan==ch and source.s<note.s and source.e>note.s then sounding=true;break end end
   local setup=require('src.glide_setup').get(note,settings)
   if sounding and setup.mpe_enabled and require('src.expression').member(ch,setup)then
    local virtual={};for k,v in pairs(note)do virtual[k]=v end;virtual.chan=ch;virtual.logical=note
    out[#out+1]=virtual;added=true
   end
  end end
  if not added then out[#out+1]=note end
 end
 return out
end
local function incoming(stream,note,settings)
 local linked=M.get(note);if linked then return linked end
 for _,source in ipairs(M.expand(stream.notes,settings))do if source.chan==note.chan and not source.muted and source.s<note.s and source.e>note.s then return {note.chan}end end
 return {}
end
local function detach(app,stream,note,channel,settings)
 local remaining={};for _,ch in ipairs(incoming(stream,note,settings))do if ch~=channel then remaining[#remaining+1]=ch end end
 if #remaining==0 then
  local free,notice=require('src.mpe_assign').new_channel(stream,note.s,note.e,settings)
  if free==nil then return false,notice end
  app.edit:set_properties(app.take,note.index,{chan=free})
 end
 M.set(stream,note,remaining);return true
end
function M.change(app,source_index,target_index,old_target_index,raw,disconnect,voice_channel)
 if app.gesture or app.edit.active or app.expression_direct_gesture then return false,'Finish the current edit first.'end
 if reaper.ValidatePtr2 and not reaper.ValidatePtr2(0,app.take,'MediaItem_Take*')then return false,'The MIDI item is unavailable.'end
 if reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(app.take),'C_LOCK')~=0 then return false,'Unlock this item before changing glide links.'end
 local ok,current=reaper.MIDI_GetAllEvts(app.take,'');if not ok or raw and current~=raw then return false,'MIDI changed during the link drag. Its changes were preserved.'end
 local selected={};for _,n in ipairs(app.cache:get(false))do if app.selection.ids[n.id]then selected[n.index]=true end end
 app.edit:begin(disconnect and 'ReaRoll: unlink glide'or 'ReaRoll: connect glide voices',app.take)
 local stream=app.edit.active.stream;local settings=stream.overlap_config
 local source,target=stream.notes[source_index+1],stream.notes[target_index+1]
 if source and settings then settings=require('src.glide_setup').get(source,settings)end
 local function fail(notice)app.edit:cancel();return false,notice end
 if not settings or not settings.mpe_enabled or not source or not target or source==target then return fail('Choose two notes in an MPE Glide item.')end
 if not require('src.glide_setup').same_mode(settings,require('src.glide_setup').get(target,stream.overlap_config))then return fail('Connect notes drawn in the same glide mode; the other notes keep their existing setup.')end
 if not(source.s<target.s and source.e>target.s and target.e>source.s)then return fail('Overlap the source and destination notes to connect them.')end
 local channels=voice_channel~=nil and{voice_channel}or M.get(source);if not channels or #channels==0 then channels={source.chan}end
 for _,channel in ipairs(channels)do
  if not require('src.expression').member(channel,settings)then return fail('The source needs an MPE member voice.')end
  if disconnect then local good,notice=detach(app,stream,target,channel,settings);if not good then return fail(notice)end
  else
   -- A voice can converge with others, but cannot fork into two pitches at
   -- one onset. Preserve a replaced destination as an independent note.
   for _,other in ipairs(stream.notes)do if other~=target and(other.s==target.s or other.index==old_target_index)then
    for _,ch in ipairs(incoming(stream,other,settings))do if ch==channel then local good,notice=detach(app,stream,other,channel,settings);if not good then return fail(notice)end;break end end
   end end
   local values=incoming(stream,target,settings);values[#values+1]=channel;M.set(stream,target,values)
  end
 end
 app.edit:touch();app.edit.active.note_changed=true;local committed=app.edit:finish();app.cache:invalidate();app.cc_cache:invalidate();app.expression_direct_cache=nil
 if committed~=false then app.cache:rebuild();app.selection.ids={};for _,n in ipairs(app.cache:get(false))do if selected[n.index]then app.selection.ids[n.id]=true end end end
 return committed~=false,app.expression_notice
end
return M
