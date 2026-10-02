-- @noindex
local U=require 'src.util'
local Selection=require 'src.selection'
local Notes=require 'src.note_events'
local M={}

local function item_ppq_bounds(app)
  return reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_start_qn),reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)
end

local function fit_note(app,s,e)
  local first,last=item_ppq_bounds(app)
  -- Timing tools should honour the requested note-on movement. If the moved
  -- note would cross an item edge, shorten it at that edge instead of pulling
  -- the note-on back merely to preserve its old duration.
  s=U.clamp(s,first,last-1)
  e=U.clamp(e,s+1,last)
  return s,e
end

local function chosen(app) return Selection.list(app.selection,app.cache:get(false)) end
local function apply(app,name,fn)
  local notes=chosen(app); if #notes==0 then return false end
  app.edit:begin('ReaRoll: '..name,app.take); fn(notes); app.edit:finish(); app.cache:rebuild(); app:reselect_notes(notes); return true
end

function M.reverse(app)
  return apply(app,'reverse phrase',function(notes)
    local first,last=math.huge,-math.huge
    for _,n in ipairs(notes) do first=math.min(first,n.s); last=math.max(last,n.e) end
    for _,n in ipairs(notes) do
      local ns,ne=first+last-n.e,first+last-n.s
      app.edit:set(n.index,app.take,ns,ne,nil,nil); n.s,n.e=ns,ne
    end
  end)
end

function M.invert(app)
  return apply(app,'invert pitches',function(notes)
    local low,high=127,0
    for _,n in ipairs(notes) do low=math.min(low,n.pitch); high=math.max(high,n.pitch) end
    for _,n in ipairs(notes) do
      local pitch=low+high-n.pitch
      app.edit:set(n.index,app.take,nil,nil,pitch,nil); n.pitch=pitch
    end
  end)
end

function M.scale_time(app,factor)
  local notes=chosen(app); if #notes==0 then return false end
  local first,last=math.huge,-math.huge
  for _,n in ipairs(notes) do first=math.min(first,n.s); last=math.max(last,n.e) end
  local limit=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)
  -- Refuse an expansion that would leave notes hidden beyond the item.
  if first+(last-first)*factor>limit+.000001 then return false end
  return apply(app,factor<1 and 'compress phrase' or 'expand phrase',function(selected)
    for _,n in ipairs(selected) do
      local ns,ne=first+(n.s-first)*factor,first+(n.e-first)*factor
      app.edit:set(n.index,app.take,ns,ne,nil,nil); n.s,n.e=ns,ne
    end
  end)
end

function M.quantize(app,ends_too,step,strength)
  return apply(app,ends_too and 'quantize notes' or 'quantize note starts',function(notes)
    step=step or app.settings.grid_qn; strength=U.clamp((strength or 100)/100,0,1)
    for _,n in ipairs(notes) do
      local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local target_sq=U.snap(sq,step); local new_sq=sq+(target_sq-sq)*strength; local target_eq=U.snap(eq,step); local new_eq=ends_too and eq+(target_eq-eq)*strength or (new_sq+(eq-sq))
      if new_eq<=new_sq then new_eq=new_sq+step end
      local ns=reaper.MIDI_GetPPQPosFromProjQN(app.take,new_sq); local ne=reaper.MIDI_GetPPQPosFromProjQN(app.take,new_eq)
      app.edit:set(n.index,app.take,ns,ne,nil,nil); n.s,n.e=ns,ne
    end
  end)
end

function M.legato(app,gap_qn,all_pitches)
  gap_qn=math.min(0,gap_qn or 0)
  return apply(app,'legato',function(notes)
    local by_pitch={}
    for _,n in ipairs(notes) do local key=all_pitches and 0 or n.pitch; by_pitch[key]=by_pitch[key] or {}; by_pitch[key][#by_pitch[key]+1]=n end
    for _,group in pairs(by_pitch) do
      table.sort(group,function(a,b)return a.s<b.s end)
      for i=1,#group-1 do local n,next_note=group[i]; for j=i+1,#group do if group[j].s>n.s then next_note=group[j]; break end end; if next_note then local target=next_note.s+reaper.MIDI_GetPPQPosFromProjQN(app.take,(gap_qn or 0))-reaper.MIDI_GetPPQPosFromProjQN(app.take,0); target=math.max(n.s+1,target); app.edit:set(n.index,app.take,nil,target,nil,nil); n.e=target end end
    end
  end)
end

function M.transpose(app,semitones)
  return apply(app,(semitones>0 and 'transpose up' or 'transpose down'),function(notes)
    for _,n in ipairs(notes) do local pitch=U.clamp(n.pitch+semitones,0,127); app.edit:set(n.index,app.take,nil,nil,pitch,nil); n.pitch=pitch end
  end)
end

function M.transpose_scale(app,degrees)
  local scale=app.music.scales[app.settings.scale_name] or app.music.scales.Major
  local root=app.settings.scale_root
  local allowed={}
  for octave=-2,12 do for _,interval in ipairs(scale) do
    local pitch=root+octave*12+interval
    if pitch>=0 and pitch<=127 then allowed[#allowed+1]=pitch end
  end end
  table.sort(allowed)
  return apply(app,(degrees>0 and 'scale degree up' or 'scale degree down'),function(notes)
    for _,n in ipairs(notes) do
      local closest=1
      for i,p in ipairs(allowed) do if math.abs(p-n.pitch)<math.abs(allowed[closest]-n.pitch) then closest=i end end
      local pitch=allowed[U.clamp(closest+degrees,1,#allowed)]
      app.edit:set(n.index,app.take,nil,nil,pitch,nil); n.pitch=pitch
    end
  end)
end

function M.strum(app,direction)
  return apply(app,direction>0 and 'strum low to high' or 'strum high to low',function(notes)
    -- A fuzzy equality comparison (abs(a.s-b.s)<.5) is not transitive and can
    -- make Lua's quicksort fail with "invalid order function for sorting".
    -- Quantize only the grouping key, then use deterministic tie-breakers.
    local function bucket(n) return math.floor(n.s+.5) end
    table.sort(notes,function(a,b)
      local ag,bg=bucket(a),bucket(b)
      if ag~=bg then return ag<bg end
      if a.pitch~=b.pitch then
        if direction>0 then return a.pitch<b.pitch else return a.pitch>b.pitch end
      end
      if a.s~=b.s then return a.s<b.s end
      if (a.chan or 0)~=(b.chan or 0) then return (a.chan or 0)<(b.chan or 0) end
      return (a.index or 0)<(b.index or 0)
    end)
    local group_bucket=nil; local position=0
    for _,n in ipairs(notes) do
      local current=bucket(n)
      if group_bucket~=current then group_bucket=current; position=0 end
      local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local shift=position*app.settings.strum_qn
      local ns=reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+shift); local ne=reaper.MIDI_GetPPQPosFromProjQN(app.take,eq+shift)
      app.edit:set(n.index,app.take,ns,ne,nil,nil); n.s,n.e=ns,ne; position=position+1
    end
  end)
end

local function restore_preview(app,keep)
  local p=app.transform_preview; if not p then return false end
  if p.take and reaper.ValidatePtr2(0,p.take,'MediaItem_Take*') then reaper.MIDI_SetAllEvts(p.take,p.raw); reaper.MIDI_Sort(p.take); Notes.set_pairing_state(p.take,p.pairing_state) end
  app.cache:invalidate(); app.cache:rebuild(); app.cc_cache:invalidate(); app:reselect_notes(p.originals)
  if not keep then app.transform_preview=nil end
  reaper.UpdateArrange(); return true
end

function M.cancel_preview(app) return restore_preview(app,false) end

local function start_preview(app,kind,source_notes)
  if app.transform_preview and (app.transform_preview.kind~=kind or app.transform_preview.take~=app.take) then restore_preview(app,false) end
  if app.transform_preview then return app.transform_preview end
  local notes=source_notes or chosen(app); if #notes==0 or not app.take then return nil end
  local ok,raw=reaper.MIDI_GetAllEvts(app.take,''); if not ok then return nil end
  local originals={}; for _,n in ipairs(notes) do originals[#originals+1]={index=n.index,s=n.s,e=n.e,pitch=n.pitch,vel=n.vel,chan=n.chan,muted=n.muted} end
  app.transform_preview={kind=kind,take=app.take,raw=raw,pairing_state=Notes.get_pairing_state(app.take),originals=originals}; return app.transform_preview
end

local function preview_notes(app,kind,mutate,source_notes)
  local p=start_preview(app,kind,source_notes); if not p then return false end; restore_preview(app,true)
  local notes={}; for _,source in ipairs(p.originals) do local n=app.cache.notes[source.index+1]; if n then notes[#notes+1]=n end end
  app.edit:begin_preview(app.take)
  mutate(notes,p)
  app.edit:finish(); app.cache:rebuild(); app:reselect_notes(p.originals); reaper.UpdateArrange(); return true
end

function M.preview_velocity(app,mode,value,amount,pivot,first,last)
  local targets=chosen(app)
  if #targets==0 and app.lane_time_selection then for _,n in ipairs(app.cache:get(false)) do local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); if q>=app.lane_time_selection.start_qn and q<=app.lane_time_selection.end_qn then targets[#targets+1]=n end end end
  return preview_notes(app,'velocity',function(notes)
    local lo,hi=math.huge,-math.huge; for _,n in ipairs(notes) do lo=math.min(lo,n.s); hi=math.max(hi,n.s) end
    for _,n in ipairs(notes) do local vel
      if mode=='set' then vel=value
      elseif mode=='scale' then vel=(pivot or 96)+(n.vel-(pivot or 96))*(amount or 1)
      else local t=hi>lo and (n.s-lo)/(hi-lo) or 0; vel=(first or 60)+((last or 110)-(first or 60))*t end
      app.edit:set(n.index,app.take,nil,nil,nil,U.clamp(math.floor(vel+.5),1,127))
    end
  end,targets)
end

function M.preview_quantize(app,ends_too,step,strength)
  step=step or app.settings.grid_qn; strength=U.clamp((strength or 100)/100,0,1)
  return preview_notes(app,'quantize',function(notes)
    for _,n in ipairs(notes) do local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local nsq=sq+(U.snap(sq,step)-sq)*strength; local neq=ends_too and eq+(U.snap(eq,step)-eq)*strength or nsq+(eq-sq); if neq<=nsq then neq=nsq+step end; local ns,ne=fit_note(app,reaper.MIDI_GetPPQPosFromProjQN(app.take,nsq),reaper.MIDI_GetPPQPosFromProjQN(app.take,neq)); app.edit:set(n.index,app.take,ns,ne,nil,nil) end
  end)
end

function M.scale_pitch(music,root,scale,pitch,direction)
  if music.contains(root,scale,pitch) then return pitch end
  if direction and direction~=0 then
    for distance=1,127 do
      local target=pitch+distance*direction
      if target<0 or target>127 then break end
      if music.contains(root,scale,target) then return target end
    end
  end
  return music.snap(root,scale,pitch)
end

function M.preview_scale_quantize(app,direction)
  return preview_notes(app,'scale_quantize',function(notes)
    for _,n in ipairs(notes) do
      local pitch=M.scale_pitch(app.music,app.settings.scale_root,app.settings.scale_name,n.pitch,direction)
      app.edit:set(n.index,app.take,nil,nil,pitch,nil)
    end
  end)
end

function M.preview_pitch(app,amount,in_scale)
  local allowed={}
  if in_scale then
    for pitch=0,127 do if app.music.contains(app.settings.scale_root,app.settings.scale_name,pitch) then allowed[#allowed+1]=pitch end end
  end
  return preview_notes(app,'pitch',function(notes)
    for _,n in ipairs(notes) do
      local pitch=U.clamp(n.pitch+amount,0,127)
      if in_scale then
        local closest=1
        for index,value in ipairs(allowed) do if math.abs(value-n.pitch)<math.abs(allowed[closest]-n.pitch) then closest=index end end
        pitch=allowed[U.clamp(closest+amount,1,#allowed)]
      end
      app.edit:set(n.index,app.take,nil,nil,pitch,nil)
    end
  end)
end

function M.preview_legato(app,gap_qn,all_pitches)
  gap_qn=math.min(0,gap_qn or 0)
  return preview_notes(app,'legato',function(notes)
    local groups={}; for _,n in ipairs(notes) do local key=all_pitches and 0 or n.pitch; groups[key]=groups[key] or {}; groups[key][#groups[key]+1]=n end
    local delta=reaper.MIDI_GetPPQPosFromProjQN(app.take,gap_qn or 0)-reaper.MIDI_GetPPQPosFromProjQN(app.take,0)
    local _,item_e=item_ppq_bounds(app)
    for _,group in pairs(groups) do table.sort(group,function(a,b)return a.s<b.s end); for i=1,#group-1 do local n,next_note=group[i]; for j=i+1,#group do if group[j].s>n.s then next_note=group[j]; break end end; if next_note then local target=U.clamp(next_note.s+delta,n.s+1,item_e); app.edit:set(n.index,app.take,nil,target,nil,nil) end end end
  end)
end

function M.preview_humanize(app,time_percent,velocity_amount,timing_bias,preserve_chords)
  return preview_notes(app,'humanize',function(notes,p)
    p.random=p.random or {}; local chord_random={}; local maximum=app.settings.grid_qn*((time_percent or 0)/100); local bias=U.clamp((timing_bias or 0)/100,-1,1)
    for i,n in ipairs(notes) do p.random[i]=p.random[i] or {time=math.random()*2-1,velocity=math.random()*2-1}; local key=math.floor(n.s+.5); local r=p.random[i].time; if preserve_chords then chord_random[key]=chord_random[key] or r; r=chord_random[key] end; local delta=(r*(1-math.abs(bias))+bias)*maximum; local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local vel=U.clamp(math.floor(n.vel+p.random[i].velocity*(velocity_amount or 0)+.5),1,127); local ns,ne=fit_note(app,reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+delta),reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+delta+eq-sq)); app.edit:set(n.index,app.take,ns,ne,nil,vel) end
  end)
end

function M.preview_arpeggiate(app,direction,gate,octaves,swing,options)
  local p=start_preview(app,'arp'); if not p then return false end; restore_preview(app,true)
  local notes={}
  for _,n in ipairs(p.originals) do notes[#notes+1]={s=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s),e=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e),pitch=n.pitch,vel=n.vel,chan=n.chan,muted=n.muted} end
  local o={}; for k,v in pairs(options or {}) do o[k]=v end
  o.pattern=direction; o.gate=gate; o.octaves=octaves; o.swing=swing
  o.rate=o.rate or app.settings.grid_qn; o.first=app.item_start_qn; o.last=app.item_end_qn
  local generated,notice=require('src.arpeggiator').generate(notes,o)
  if generated and #generated==0 then notice='No hits at this rate and rhythm. Enable rhythm steps, choose Straight, or select longer chords.'; generated=nil end
  app.transform_notice=notice
  p.invalid=not generated
  p.generated_count=generated and #generated or 0
  if not generated then return false end
  app.edit:begin_preview(app.take)
  local indices={}; for _,n in ipairs(p.originals) do indices[#indices+1]=n.index end
  app.edit:delete_indices(app.take,indices)
  local wanted={}
  for _,n in ipairs(generated) do
    local ns,ne=reaper.MIDI_GetPPQPosFromProjQN(app.take,n.s),reaper.MIDI_GetPPQPosFromProjQN(app.take,n.e)
    app.edit:insert(app.take,ns,ne,n.pitch,n.vel,n.chan,true,n.muted)
    wanted[#wanted+1]={s=ns,e=ne,pitch=n.pitch,vel=n.vel}
  end
  app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted); reaper.UpdateArrange(); return true
end

function M.preview_strum(app,direction)
  local p=start_preview(app,'strum'); if not p then return false end; restore_preview(app,true)
  local notes={}; for _,source in ipairs(p.originals) do local n=app.cache.notes[source.index+1]; if n then notes[#notes+1]=n end end
  local function bucket(n) return math.floor(n.s+.5) end
  table.sort(notes,function(a,b) local ag,bg=bucket(a),bucket(b); if ag~=bg then return ag<bg end; if a.pitch~=b.pitch then if direction>0 then return a.pitch<b.pitch else return a.pitch>b.pitch end end; return a.index<b.index end)
  local group,position=nil,0; local wanted={}
  app.edit:begin_preview(app.take)
  for _,n in ipairs(notes) do local current=bucket(n); if current~=group then group=current; position=0 end
    local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local shift=position*app.settings.strum_qn
    local ns,ne=fit_note(app,reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+shift),reaper.MIDI_GetPPQPosFromProjQN(app.take,eq+shift)); app.edit:set(n.index,app.take,ns,ne,nil,nil)
    wanted[#wanted+1]={s=ns,e=ne,pitch=n.pitch,vel=n.vel}; position=position+1
  end
  app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted); reaper.UpdateArrange(); return true
end

local function flam_timing(app,n)
  local delay=math.max(0,app.settings.flam_qn or 0)
  local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)
  local second_s=reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+delay)
  local _,item_e=item_ppq_bounds(app); local shifted_e=reaper.MIDI_GetPPQPosFromProjQN(app.take,eq+delay)
  if second_s>=item_e then return n.e,nil,nil end
  if app.settings.prevent_overlaps and second_s<n.e then
    -- With overlap prevention enabled, split the source duration at the
    -- delayed hit so this flam's same-pitch notes remain adjacent.
    return math.max(n.s+1,second_s),second_s,n.e
  end
  -- With prevention disabled, retain the source note and give the delayed hit
  -- its full shifted duration, even when that overlaps the first hit.
  return n.e,second_s,math.min(item_e,shifted_e)
end

function M.preview_flam(app)
  local p=start_preview(app,'flam'); if not p then return false end; restore_preview(app,true); local wanted={}
  app.edit:begin_preview(app.take)
  for _,n in ipairs(p.originals) do
    local first_e,s,e=flam_timing(app,n); app.edit:set(n.index,app.take,nil,first_e,nil,nil)
    wanted[#wanted+1]={s=n.s,e=first_e,pitch=n.pitch,vel=n.vel}; if s then local vel=U.clamp(math.floor(n.vel*.72+.5),1,127)
    app.edit:insert(app.take,s,e,n.pitch,vel,n.chan,true,n.muted); wanted[#wanted+1]={s=s,e=e,pitch=n.pitch,vel=vel} end
  end
  app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted); reaper.UpdateArrange(); return true
end

function M.commit_preview(app)
  local p=app.transform_preview; if not p then return false end
  local ok,result=reaper.MIDI_GetAllEvts(app.take,''); if not ok then return false end
  local pairing_state=Notes.get_pairing_state(app.take)
  local wanted={}; for _,n in ipairs(Selection.list(app.selection,app.cache:get(false))) do wanted[#wanted+1]={s=n.s,e=n.e,pitch=n.pitch,vel=n.vel} end
  local names={strum='strum',flam='flam',quantize='quantize notes',scale_quantize='quantize notes to scale',pitch='transpose notes',legato='legato',humanize='humanize',arp='arpeggiate selection',velocity='edit velocity'}
  local name=names[p.kind] or p.kind; restore_preview(app,false)
  app.edit:begin('ReaRoll: '..name,app.take); reaper.MIDI_SetAllEvts(app.take,result); Notes.set_pairing_state(app.take,pairing_state); app.edit:touch(); app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted); return true
end

function M.flam(app)
  local notes=chosen(app); if #notes==0 then return false end
  app.edit:begin('ReaRoll: flam',app.take); local wanted={}
  for _,n in ipairs(notes) do
    local first_e,s,e=flam_timing(app,n); if first_e~=n.e then app.edit:set(n.index,app.take,nil,first_e,nil,nil); n.e=first_e end
    wanted[#wanted+1]={s=n.s,e=first_e,pitch=n.pitch,vel=n.vel}
    if s then local vel=U.clamp(math.floor(n.vel*.72+.5),1,127)
    app.edit:insert(app.take,s,e,n.pitch,vel,n.chan,true,n.muted); wanted[#wanted+1]={s=s,e=e,pitch=n.pitch,vel=vel} end
  end
  app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted); return true
end

function M.humanize(app,time_percent,velocity_amount,timing_bias,preserve_chords)
  return apply(app,'humanize',function(notes)
    local max_qn=app.settings.grid_qn*((time_percent or app.settings.human_time)/100); local velocity=velocity_amount or app.settings.human_velocity; local bias=U.clamp((timing_bias or 0)/100,-1,1); local chord_delta={}
    for _,n in ipairs(notes) do
      local key=math.floor(n.s+.5); local random=(math.random()*2-1); local delta=(preserve_chords and chord_delta[key] or nil) or ((random*(1-math.abs(bias))+bias)*max_qn); if preserve_chords then chord_delta[key]=delta end; local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)
      local ns=reaper.MIDI_GetPPQPosFromProjQN(app.take,math.max(app.item_start_qn,sq+delta)); local duration=eq-sq; local ne=reaper.MIDI_GetPPQPosFromProjQN(app.take,math.max(app.item_start_qn,sq+delta)+duration)
      local vel=U.clamp(n.vel+math.random(-velocity,velocity),1,127)
      app.edit:set(n.index,app.take,ns,ne,nil,vel); n.s,n.e,n.vel=ns,ne,vel
    end
  end)
end

local function replace_selection(app,name,build)
  local notes=chosen(app); if #notes==0 then return false end
  local replacements=build(notes); if not replacements or #replacements==0 then return false end
  app.edit:begin('ReaRoll: '..name,app.take); local indices={}; for _,n in ipairs(notes) do indices[#indices+1]=n.index end; app.edit:delete_indices(app.take,indices)
  local wanted={}
  for _,n in ipairs(replacements) do app.edit:insert(app.take,n.s,n.e,n.pitch,n.vel,n.chan,true,n.muted); wanted[#wanted+1]={s=n.s,e=n.e,pitch=n.pitch,vel=n.vel} end
  app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted); return true
end

function M.chop(app)
  local step=app.settings.grid_qn
  return replace_selection(app,'chop notes to grid',function(notes)
    local out={}
    for _,n in ipairs(notes) do
      local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local q=sq
      while q<eq-.000001 do local next_q=math.min(eq,q+step); out[#out+1]={s=reaper.MIDI_GetPPQPosFromProjQN(app.take,q),e=reaper.MIDI_GetPPQPosFromProjQN(app.take,next_q),pitch=n.pitch,vel=n.vel,chan=n.chan,muted=n.muted}; q=next_q end
    end
    return out
  end)
end

function M.velocity_ramp(app,first,last)
  return apply(app,'shape velocity',function(notes)
    local lo,hi=math.huge,-math.huge
    for _,n in ipairs(notes) do lo=math.min(lo,n.s); hi=math.max(hi,n.s) end
    for _,n in ipairs(notes) do
      local t=hi>lo and (n.s-lo)/(hi-lo) or 0
      local vel=U.clamp(math.floor(first+(last-first)*t+.5),1,127)
      app.edit:set(n.index,app.take,nil,nil,nil,vel); n.vel=vel
    end
  end)
end

function M.velocity_compress(app,amount,pivot)
  return apply(app,'compress velocity',function(notes)
    for _,n in ipairs(notes) do
      local vel=U.clamp(math.floor((pivot or 96)+(n.vel-(pivot or 96))*amount+.5),1,127)
      app.edit:set(n.index,app.take,nil,nil,nil,vel); n.vel=vel
    end
  end)
end

function M.randomize(app,time_percent,velocity_amount)
  return apply(app,'randomize notes',function(notes)
    local maximum=app.settings.grid_qn*(time_percent/100)
    local item_s=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_start_qn)
    local item_e=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)
    for _,n in ipairs(notes) do
      local length=n.e-n.s; local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)
      local start=U.clamp(reaper.MIDI_GetPPQPosFromProjQN(app.take,q+(math.random()*2-1)*maximum),item_s,item_e-length)
      local vel=U.clamp(n.vel+math.random(-velocity_amount,velocity_amount),1,127)
      app.edit:set(n.index,app.take,start,start+length,nil,vel); n.s,n.e,n.vel=start,start+length,vel
    end
  end)
end

function M.arpeggiate(app,direction,gate,octaves,swing,options)
  if not M.preview_arpeggiate(app,direction,gate,octaves,swing,options) then M.cancel_preview(app); return false end
  return M.commit_preview(app)
end

function M.glue(app)
  return replace_selection(app,'glue notes',function(notes)
    table.sort(notes,function(a,b) if a.pitch~=b.pitch then return a.pitch<b.pitch end; if a.chan~=b.chan then return a.chan<b.chan end; return a.s<b.s end)
    local out={}
    for _,n in ipairs(notes) do
      local last=out[#out]
      if last and last.pitch==n.pitch and last.chan==n.chan and n.s<=last.e+.5 then last.e=math.max(last.e,n.e)
      else out[#out+1]={s=n.s,e=n.e,pitch=n.pitch,vel=n.vel,chan=n.chan,muted=n.muted} end
    end
    return out
  end)
end

return M
