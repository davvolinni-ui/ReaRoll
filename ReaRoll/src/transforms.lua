-- @noindex
local U=require 'src.util'
local Selection=require 'src.selection'
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
  if p.take and reaper.ValidatePtr2(0,p.take,'MediaItem_Take*') then reaper.MIDI_SetAllEvts(p.take,p.raw); reaper.MIDI_Sort(p.take) end
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
  app.transform_preview={kind=kind,take=app.take,raw=raw,originals=originals}; return app.transform_preview
end

local function preview_notes(app,kind,mutate,source_notes)
  local p=start_preview(app,kind,source_notes); if not p then return false end; restore_preview(app,true)
  local notes={}; for _,source in ipairs(p.originals) do local n=app.cache.notes[source.index+1]; if n then notes[#notes+1]=n end end
  mutate(notes,p)
  reaper.MIDI_Sort(app.take); app.cache:invalidate(); app.cache:rebuild(); app:reselect_notes(p.originals); reaper.UpdateArrange(); return true
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
      reaper.MIDI_SetNote(app.take,n.index,nil,nil,nil,nil,nil,nil,U.clamp(math.floor(vel+.5),1,127),true)
    end
  end,targets)
end

function M.preview_quantize(app,ends_too,step,strength)
  step=step or app.settings.grid_qn; strength=U.clamp((strength or 100)/100,0,1)
  return preview_notes(app,'quantize',function(notes)
    for _,n in ipairs(notes) do local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local nsq=sq+(U.snap(sq,step)-sq)*strength; local neq=ends_too and eq+(U.snap(eq,step)-eq)*strength or nsq+(eq-sq); if neq<=nsq then neq=nsq+step end; local ns,ne=fit_note(app,reaper.MIDI_GetPPQPosFromProjQN(app.take,nsq),reaper.MIDI_GetPPQPosFromProjQN(app.take,neq)); reaper.MIDI_SetNote(app.take,n.index,nil,nil,ns,ne,nil,nil,nil,true) end
  end)
end

function M.preview_legato(app,gap_qn,all_pitches)
  gap_qn=math.min(0,gap_qn or 0)
  return preview_notes(app,'legato',function(notes)
    local groups={}; for _,n in ipairs(notes) do local key=all_pitches and 0 or n.pitch; groups[key]=groups[key] or {}; groups[key][#groups[key]+1]=n end
    local delta=reaper.MIDI_GetPPQPosFromProjQN(app.take,gap_qn or 0)-reaper.MIDI_GetPPQPosFromProjQN(app.take,0)
    local _,item_e=item_ppq_bounds(app)
    for _,group in pairs(groups) do table.sort(group,function(a,b)return a.s<b.s end); for i=1,#group-1 do local n,next_note=group[i]; for j=i+1,#group do if group[j].s>n.s then next_note=group[j]; break end end; if next_note then local target=U.clamp(next_note.s+delta,n.s+1,item_e); reaper.MIDI_SetNote(app.take,n.index,nil,nil,nil,target,nil,nil,nil,true) end end end
  end)
end

function M.preview_humanize(app,time_percent,velocity_amount,timing_bias,preserve_chords)
  return preview_notes(app,'humanize',function(notes,p)
    p.random=p.random or {}; local chord_random={}; local maximum=app.settings.grid_qn*((time_percent or 0)/100); local bias=U.clamp((timing_bias or 0)/100,-1,1)
    for i,n in ipairs(notes) do p.random[i]=p.random[i] or {time=math.random()*2-1,velocity=math.random()*2-1}; local key=math.floor(n.s+.5); local r=p.random[i].time; if preserve_chords then chord_random[key]=chord_random[key] or r; r=chord_random[key] end; local delta=(r*(1-math.abs(bias))+bias)*maximum; local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local vel=U.clamp(math.floor(n.vel+p.random[i].velocity*(velocity_amount or 0)+.5),1,127); local ns,ne=fit_note(app,reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+delta),reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+delta+eq-sq)); reaper.MIDI_SetNote(app.take,n.index,nil,nil,ns,ne,nil,nil,vel,true) end
  end)
end

function M.preview_arpeggiate(app,direction,gate,octaves,swing)
  local p=start_preview(app,'arp'); if not p then return false end; restore_preview(app,true)
  local notes={}; for _,source in ipairs(p.originals) do notes[#notes+1]=source end
  local lo,hi=math.huge,-math.huge; local pitches,seen={},{ }
  for _,n in ipairs(notes) do lo=math.min(lo,n.s); hi=math.max(hi,n.e); local key=n.pitch..':'..(n.chan or 0); if not seen[key] then seen[key]=true; pitches[#pitches+1]=n end end
  table.sort(pitches,function(a,b) if a.pitch==b.pitch then return (a.chan or 0)<(b.chan or 0) end; return a.pitch<b.pitch end)
  local expanded={}; for octave=0,U.clamp(math.floor(octaves or 1),1,4)-1 do for _,source in ipairs(pitches) do if source.pitch+octave*12<=127 then expanded[#expanded+1]={pitch=source.pitch+octave*12,vel=source.vel,chan=source.chan or 0,muted=source.muted} end end end; pitches=expanded
  if #pitches==0 then return false end
  local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,lo); local ending=math.min(app.item_end_qn,reaper.MIDI_GetProjQNFromPPQPos(app.take,hi)); local step=app.settings.grid_qn; local count=math.min(4096,math.ceil((ending-q)/step)); local wanted={}
  local indices={}; for _,n in ipairs(notes) do indices[#indices+1]=n.index end; table.sort(indices,function(a,b)return a>b end); for _,index in ipairs(indices) do reaper.MIDI_DeleteNote(app.take,index) end
  for i=0,count-1 do local index=i%#pitches+1; if direction=='down' then index=#pitches-index+1 elseif direction=='updown' and #pitches>1 then local phase=i%(2*#pitches-2); index=phase<#pitches and phase+1 or 2*#pitches-1-phase end; local source=pitches[index]; local sq=q+i*step+(i%2==1 and step*U.clamp(swing or 0,0,.75) or 0); local eq=math.min(ending,sq+step*U.clamp(gate or .85,.1,1)); if eq>sq then local s,e=reaper.MIDI_GetPPQPosFromProjQN(app.take,sq),reaper.MIDI_GetPPQPosFromProjQN(app.take,eq); reaper.MIDI_InsertNote(app.take,true,source.muted,s,e,source.chan,source.pitch,source.vel,true); wanted[#wanted+1]={s=s,e=e,pitch=source.pitch,vel=source.vel} end end
  reaper.MIDI_Sort(app.take); app.cache:invalidate(); app.cache:rebuild(); app:reselect_notes(wanted); reaper.UpdateArrange(); return true
end

function M.preview_strum(app,direction)
  local p=start_preview(app,'strum'); if not p then return false end; restore_preview(app,true)
  local notes={}; for _,source in ipairs(p.originals) do local n=app.cache.notes[source.index+1]; if n then notes[#notes+1]=n end end
  local function bucket(n) return math.floor(n.s+.5) end
  table.sort(notes,function(a,b) local ag,bg=bucket(a),bucket(b); if ag~=bg then return ag<bg end; if a.pitch~=b.pitch then if direction>0 then return a.pitch<b.pitch else return a.pitch>b.pitch end end; return a.index<b.index end)
  local group,position=nil,0; local wanted={}
  for _,n in ipairs(notes) do local current=bucket(n); if current~=group then group=current; position=0 end
    local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e); local shift=position*app.settings.strum_qn
    local ns,ne=fit_note(app,reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+shift),reaper.MIDI_GetPPQPosFromProjQN(app.take,eq+shift)); reaper.MIDI_SetNote(app.take,n.index,nil,nil,ns,ne,nil,nil,nil,true)
    wanted[#wanted+1]={s=ns,e=ne,pitch=n.pitch,vel=n.vel}; position=position+1
  end
  reaper.MIDI_Sort(app.take); app.cache:invalidate(); app.cache:rebuild(); app:reselect_notes(wanted); reaper.UpdateArrange(); return true
end

local function flam_timing(app,n)
  local delay=math.max(0,app.settings.flam_qn or 0)
  local sq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s); local eq=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)
  local second_s=reaper.MIDI_GetPPQPosFromProjQN(app.take,sq+delay)
  -- When the delayed hit lands inside the source note, split the available
  -- duration at that hit. Two full-length same-pitch notes would overlap and
  -- produce ambiguous MIDI note-off pairing.
  if second_s<n.e then return math.max(n.s+1,second_s),second_s,n.e end
  local _,item_e=item_ppq_bounds(app); local shifted_e=reaper.MIDI_GetPPQPosFromProjQN(app.take,eq+delay)
  if second_s>=item_e then return n.e,nil,nil end
  return n.e,second_s,math.min(item_e,shifted_e)
end

function M.preview_flam(app)
  local p=start_preview(app,'flam'); if not p then return false end; restore_preview(app,true); local wanted={}
  for _,n in ipairs(p.originals) do
    local first_e,s,e=flam_timing(app,n); reaper.MIDI_SetNote(app.take,n.index,nil,nil,nil,first_e,nil,nil,nil,true)
    wanted[#wanted+1]={s=n.s,e=first_e,pitch=n.pitch,vel=n.vel}; if s then local vel=U.clamp(math.floor(n.vel*.72+.5),1,127)
    reaper.MIDI_InsertNote(app.take,true,n.muted,s,e,n.chan,n.pitch,vel,true); wanted[#wanted+1]={s=s,e=e,pitch=n.pitch,vel=vel} end
  end
  reaper.MIDI_Sort(app.take); app.cache:invalidate(); app.cache:rebuild(); app:reselect_notes(wanted); reaper.UpdateArrange(); return true
end

function M.commit_preview(app)
  local p=app.transform_preview; if not p then return false end
  local ok,result=reaper.MIDI_GetAllEvts(app.take,''); if not ok then return false end
  local wanted={}; for _,n in ipairs(Selection.list(app.selection,app.cache:get(false))) do wanted[#wanted+1]={s=n.s,e=n.e,pitch=n.pitch,vel=n.vel} end
  local names={strum='strum',flam='flam',quantize='quantize notes',legato='legato',humanize='humanize',arp='arpeggiate selection',velocity='edit velocity'}
  local name=names[p.kind] or p.kind; restore_preview(app,false)
  app.edit:begin('ReaRoll: '..name,app.take); reaper.MIDI_SetAllEvts(app.take,result); app.edit:touch(); app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted); return true
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

function M.arpeggiate(app,direction,gate,octaves,swing)
  return replace_selection(app,'arpeggiate selection',function(notes)
    local lo,hi=math.huge,-math.huge; local pitches,seen={},{}
    for _,n in ipairs(notes) do
      lo=math.min(lo,n.s); hi=math.max(hi,n.e)
      local key=n.pitch..':'..n.chan
      if not seen[key] then seen[key]=true; pitches[#pitches+1]=n end
    end
    table.sort(pitches,function(a,b) if a.pitch==b.pitch then return a.chan<b.chan end; return a.pitch<b.pitch end)
    local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,lo)
    local ending=math.min(app.item_end_qn,reaper.MIDI_GetProjQNFromPPQPos(app.take,hi))
    local step=app.settings.grid_qn; local count=math.ceil((ending-q)/step)
    if count>4096 then app.transform_notice='Choose a coarser grid or a shorter selection.'; return nil end
    local expanded={}; octaves=U.clamp(math.floor(octaves or 1),1,4)
    for octave=0,octaves-1 do for _,source in ipairs(pitches) do
      local pitch=source.pitch+octave*12
      if pitch<=127 then expanded[#expanded+1]={pitch=pitch,vel=source.vel,chan=source.chan,muted=source.muted} end
    end end
    pitches=expanded
    local out={}; local n=#pitches; swing=U.clamp(swing or 0,0,.75)
    for i=0,count-1 do
      local index=i%n+1
      if direction=='down' then index=n-index+1
      elseif direction=='updown' and n>1 then local phase=i%(2*n-2); index=phase<n and phase+1 or 2*n-1-phase end
      local source=pitches[index]; local sq=q+i*step+(i%2==1 and step*swing or 0)
      local eq=math.min(ending,sq+step*U.clamp(gate or .85,.1,1))
      if eq>sq then out[#out+1]={s=reaper.MIDI_GetPPQPosFromProjQN(app.take,sq),e=reaper.MIDI_GetPPQPosFromProjQN(app.take,eq),pitch=source.pitch,vel=source.vel,chan=source.chan,muted=source.muted} end
    end
    return out
  end)
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
