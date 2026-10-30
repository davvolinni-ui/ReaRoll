-- @noindex
-- Keep an authored glide's playback setup with its score notes. The toolbar
-- selects the setup for new drawing; changing it never rewrites older voices.
local M={}
local function payload(event)return not event.deleted and event.msg:match('^..NOTE %d+ %d+ REAROLL_GLIDE_SETUP 1 (.*)$')end
function M.range(settings)
 return settings.mpe_enabled and(settings.mpe_pitch_bend_range or 48)or(settings.pitch_bend_range or 2)
end
function M.read(note)
 if note.glide_setup then return note.glide_setup end
 for _,event in ipairs(note.notation or {})do local text=payload(event);if text then
  local mode,range,zone,members=text:match('^([01]) (%d+) ([01]) (%d+)$')
  range,members=tonumber(range),tonumber(members)
  if range and range>=1 and range<=96 and members and members>=1 and members<=15 then
   return {mpe_enabled=mode=='1',mpe_zone=zone=='1'and 'upper'or 'lower',mpe_members=members,pitch_bend_range=range,mpe_pitch_bend_range=range}
  end
 end end
end
function M.get(note,fallback)return M.read(note)or fallback end
function M.same_mode(a,b)
 if(a.mpe_enabled==true)~=(b.mpe_enabled==true)then return false end
 return not a.mpe_enabled or(a.mpe_zone or 'lower')==(b.mpe_zone or 'lower')and(a.mpe_members or 15)==(b.mpe_members or 15)
end
function M.same(a,b)return M.same_mode(a,b)and M.range(a)==M.range(b)end
function M.key(settings)
 return table.concat({settings.mpe_enabled and 1 or 0,M.range(settings),settings.mpe_enabled and(settings.mpe_zone or 'lower')or '',settings.mpe_enabled and(settings.mpe_members or 15)or ''},':')
end
function M.set(stream,note,settings)
 for _,event in ipairs(note.notation or {})do if payload(event)then event.deleted=true end end
 local range=M.range(settings)
 local text=(settings.mpe_enabled and 1 or 0)..' '..range..' '..(settings.mpe_zone=='upper'and 1 or 0)..' '..(settings.mpe_members or 15)
 local event={ppq=note.s,flags=0,msg=string.char(255,15)..'NOTE '..note.chan..' '..note.pitch..' REAROLL_GLIDE_SETUP 1 '..text,order=note.on.order+.015}
 note.notation=note.notation or {};note.notation[#note.notation+1]=event;note.glide_setup=nil
 stream.events[#stream.events+1]=event;stream.dirty=true
end
function M.drawing(notes,base,settings)
 local saved
 if M.same_mode(base,settings)then saved=base
 else for _,note in ipairs(notes)do local setup=M.get(note,base);if M.same_mode(setup,settings)then saved=setup;break end end end
 local out={};for k,v in pairs(settings)do out[k]=v end
 if saved then
  out.mpe_enabled=saved.mpe_enabled==true;out.mpe_zone=saved.mpe_zone or 'lower';out.mpe_members=saved.mpe_members or 15
  out[out.mpe_enabled and 'mpe_pitch_bend_range'or 'pitch_bend_range']=M.range(saved)
 end
 return out,saved~=nil
end
function M.candidates(notes,base,settings)
 local out={};for _,note in ipairs(notes)do if M.same_mode(M.get(note,base),settings)then out[#out+1]=note end end;return out
end
function M.source(notes,base,settings,channel,first)
 local best
 for _,note in ipairs(notes)do if not note.muted and note.chan==channel and note.s<first and note.e>first and M.same_mode(M.get(note,base),settings)and(not best or note.s>best.s)then best=note end end
 return best and M.get(best,base)
end
return M
