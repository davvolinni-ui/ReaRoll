-- @noindex
local U=require 'src.util'; local Selection=require 'src.selection'; local C={}
local Controls=require 'src.ui.controls'
local LaneTools=require 'src.ui.lane_tools'
local Grid=require 'src.grid'
local Shortcuts=require 'src.shortcuts'

local function positive(value,fallback)
  if type(value)~='number' or value~=value or value<=0 then return fallback or 1 end
  return value
end

local function crisp_x(value) return math.floor(value)+.5 end

local function displayed_measure(qn,fallback)
  if reaper.format_timestr_pos then
    local value=reaper.format_timestr_pos(reaper.TimeMap2_QNToTime(0,qn),'',2)
    local measure=value and value:match('^%s*([+-]?%d+)')
    if measure then return measure end
  end
  return tostring((fallback or 0)+1)
end

local function median3(values)
  local count=#values
  if count==0 then return 0 elseif count==1 then return values[1] elseif count==2 then return (values[1]+values[2])*.5 end
  local a,b,c=values[1],values[2],values[3]
  return math.max(math.min(a,b),math.min(math.max(a,b),c))
end

local function playhead_position(app)
  local playing=(reaper.GetPlayState()&1)~=0
  if not playing then app.playhead_clock=nil; return reaper.GetCursorPosition() end
  local raw=reaper.GetPlayPosition(); if not app.settings.playhead_smooth then app.playhead_clock=nil; return raw end
  local now=reaper.time_precise(); local rate=reaper.Master_GetPlayRate and reaper.Master_GetPlayRate(0) or 1
  local clock=app.playhead_clock
  if not clock then clock={position=raw,velocity=rate,wall=now,last_raw=raw,errors={},error_index=1,last_output=raw,phase_error=0}; app.playhead_clock=clock; return raw end
  local dt=U.clamp(now-clock.wall,.0001,.05)
  local predicted=clock.position+clock.velocity*dt
  local error=raw-predicted
  local fresh=math.abs(raw-clock.last_raw)>.0000001
  if raw<clock.last_raw-.01 or math.abs(error)>.075 then
    -- Seeks and loop wraps are intentional discontinuities, not jitter.
    clock.position,clock.velocity,clock.errors,clock.error_index,clock.last_output,clock.phase_error=raw,rate,{},1,raw,0
    predicted=raw
  elseif fresh then
    -- REAPER's block edges can alternate around the continuous trajectory.
    -- Filter that phase noise, but never move position directly toward it.
    clock.errors[clock.error_index]=error
    clock.error_index=clock.error_index%3+1
    local measured_error=median3(clock.errors)
    if math.abs(measured_error)<.0025 then measured_error=0 end
    clock.phase_error=clock.phase_error*.78+measured_error*.22
  end
  -- A slow phase-locked velocity trim catches genuine drift without creating
  -- the uneven per-frame distances caused by positional correction steps.
  local target_velocity=rate+U.clamp(clock.phase_error*1.35,-.03,.03)
  local follow=1-math.exp(-dt*7)
  clock.velocity=clock.velocity+(target_velocity-clock.velocity)*follow
  clock.position=predicted
  -- Normal playback must never twitch backward because of a phase correction.
  if rate>=0 and raw>=clock.last_raw-.01 then clock.position=math.max(clock.position,clock.last_output or clock.position) end
  clock.wall,clock.last_raw=now,raw
  clock.last_output=clock.position
  return clock.last_output
end

local function alpha_color(color,opacity)
  return (color&0xFFFFFF00)|U.clamp(math.floor(255*opacity+.5),0,255)
end

local function hsv_color(h,s,v,opacity)
  h=h%1; local i=math.floor(h*6); local f=h*6-i; local p=v*(1-s); local q=v*(1-f*s); local t=v*(1-(1-f)*s)
  local rgb=({{v,t,p},{q,v,p},{p,v,t},{p,q,v},{t,p,v},{v,p,q}})[i%6+1]
  return (math.floor(rgb[1]*255)<<24)|(math.floor(rgb[2]*255)<<16)|(math.floor(rgb[3]*255)<<8)|math.floor(255*opacity)
end

local function playhead_visual(app,v)
  local s=app.settings; local time=playhead_position(app); local qn=reaper.TimeMap2_timeToQN(0,time); local x=v:x_from_qn(qn)
  if x<v.x or x>v.x+v.w then return nil end
  local width=U.clamp(s.playhead_width or 2,1,6); local opacity=U.clamp(s.playhead_opacity or .92,.05,1); local glow=s.playhead_glow or 0
  local pulse=s.playhead_pulse or 0
  if pulse>0 and (reaper.GetPlayState()&1)~=0 then
    local _,bar_qn=reaper.TimeMap_QNToMeasures(0,qn)
    local _,denom=reaper.TimeMap_GetTimeSigAtTime(0,time); local beat_step=4/(denom or 4)
    local phase=((qn-bar_qn)/beat_step)%1; local hit=math.exp(-phase*8)
    local rest=1-pulse*.55
    opacity=opacity*(rest+(1-rest)*hit)
    width=width*(1+pulse*.95*hit)
    glow=math.min(1,glow*(.55+.45*hit)+pulse*.42*hit)
  end
  local color=s.playhead_color
  if s.playhead_cycle then color=hsv_color(time*(s.playhead_cycle_speed or .18),.88,1,1) end
  return {x=x,qn=qn,time=time,width=width,opacity=opacity,glow=glow,trail=s.playhead_trail or 0,color=color,wave=s.playhead_wave and (s.playhead_wave_amount or .45) or 0,rainbow=s.playhead_rainbow,sparks=s.playhead_sparks and (s.playhead_spark_amount or .45) or 0,matrix=s.playhead_matrix and (s.playhead_matrix_amount or .55) or 0,scan=s.playhead_scan and (s.playhead_scan_amount or .55) or 0,scan_direction=s.playhead_scan_direction or 'down',shadow=s.playhead_shadow or 0}
end

local function draw_led_line(I,d,p,y0,bottom,x,color,width,opacity,stable)
  local segments=(p.wave>0 or p.rainbow) and 30 or 1; local height=(bottom-y0)/segments
  for i=0,segments-1 do
    local ya,yb=y0+i*height,y0+(i+1)*height
    local function wave_at(y) return not stable and p.wave>0 and math.sin(y*.032+p.time*4.5)*p.wave*7 or 0 end
    local col=p.rainbow and color~=0x000000FF and hsv_color(i/segments+p.time*.12,.88,1,opacity) or alpha_color(color,opacity)
    I.DrawList_AddLine(d,x+wave_at(ya),ya,x+wave_at(yb),yb,col,width)
  end
end

local function draw_playhead_pass(app,d,p,y0,bottom,front)
  if not p then return end; local I=app.ImGui
  if not front then
    if p.shadow>0 then draw_led_line(I,d,p,y0,bottom,p.x+4,0x000000FF,p.width+6*p.shadow,p.opacity*p.shadow*.55) end
    if p.trail>0 then for step=10,1,-1 do local amount=p.trail*(1-step/11)^1.25; draw_led_line(I,d,p,y0,bottom,p.x-step*2.5,p.color,math.max(1,p.width*.72),p.opacity*amount*.68) end end
    if p.glow>0 then draw_led_line(I,d,p,y0,bottom,p.x,p.color,p.width+14*p.glow,p.opacity*p.glow*.16); draw_led_line(I,d,p,y0,bottom,p.x,p.color,p.width+6*p.glow,p.opacity*p.glow*.38) end
  else
    -- Animated FX may move around the transport, but the bright core remains
    -- straight so its timing position is always visually unambiguous.
    draw_led_line(I,d,p,y0,bottom,p.x,p.color,p.width,p.opacity,true)
    if p.scan>0 then
      local height=bottom-y0
      local travel=(p.time*.42)%1
      if p.scan_direction=='up' then travel=1-travel
      elseif p.scan_direction=='pingpong' then travel=1-math.abs(travel*2-1) end
      local center=y0+travel*height
      local reach=18+height*(.035+.075*p.scan)
      local parts=12
      for i=-parts,parts do
        local distance=math.abs(i)/parts
        local y=center+i*reach/parts
        if y>=y0 and y<=bottom then
          local strength=(1-distance)^2*p.scan
          local scan_width=p.width+2+8*strength
          I.DrawList_AddLine(d,p.x,y-reach/parts*.72,p.x,y+reach/parts*.72,alpha_color(p.color,p.opacity*strength),scan_width)
        end
      end
    end
    if p.sparks>0 then
      local height=bottom-y0; local reach=24+92*p.sparks
      for i=1,10 do
        local age=(p.time*(.58+i*.017)+i*.618033)%1; local yseed=(math.sin(i*91.733)*43758.5453)%1
        local y=y0+(yseed*.82+.09)*height; local drift=math.sin(i*17.31+age*8)*12*p.sparks
        local life=(1-age)^1.7; local sx=p.x-age*reach+drift
        I.DrawList_AddCircleFilled(d,sx,y,1+p.sparks*1.8,alpha_color(p.color,p.opacity*life*.90))
      end
    end
    if p.matrix>0 then
      local height=bottom-y0
      local columns=math.floor(7+15*p.matrix)
      local reach=18+72*p.matrix
      for column=1,columns do
        local seed=(math.sin(column*73.17)*19471.37)%1
        local x=p.x-4-seed*reach
        local speed=.32+((column*37)%11)/22
        local head=((p.time*speed+seed)%1)*height
        local cells=2+math.floor(3*p.matrix+((column*13)%3))
        for cell=0,cells-1 do
          local y=y0+(head-cell*(5+4*p.matrix))%height
          local fade=(1-cell/(cells+.5))^1.7
          local width=1.2+2.2*p.matrix*fade
          I.DrawList_AddLine(d,x,y,x,y+2+3*p.matrix,alpha_color(p.color,p.opacity*fade*(.18+.55*p.matrix)),width)
        end
      end
    end
  end
end

local function note_rect(v,n,row_h)
  local y=v:y_from_pitch(n.pitch); if not y then return nil end
  return v:x_from_ppq(n.s),y,v:x_from_ppq(n.e),y+row_h
end
local function hit_note(v,notes,mx,my,row_h,channel)
  if not U.contains(mx,my,v.x,v.y,v.x+v.w,v.y+v.h) then return end
  for i=#notes,1,-1 do local n=notes[i]; local x1,y1,x2,y2=note_rect(v,n,row_h)
    if channel==nil or (n.chan or 0)==channel then
    if x1 and U.contains(mx,my,x1-3,y1,x2+3,y2) then
      local zone=math.min(12,math.max(4,(x2-x1)*.3))
      local left_hot=x1>=v.x and mx<=x1+zone
      local right_hot=x2<=v.x+v.w and mx>=x2-zone
      -- Short notes can put both handles under the pointer. Pick the nearest
      -- edge so their right handle remains usable instead of always losing to
      -- the left-edge check.
      if left_hot and right_hot then return n,math.abs(mx-x1)<math.abs(mx-x2) and 'left' or 'right' end
      if left_hot then return n,'left' end
      if right_hot then return n,'right' end
      return n,nil
    end
    end
  end
end
local function hit_note_inside(inside_item,v,notes,mx,my,row_h,channel)
  -- Keep hit_note's second return value. Routing this through an and/or
  -- expression collapses Lua's multiple returns and silently loses the edge.
  if inside_item then return hit_note(v,notes,mx,my,row_h,channel) end
end
local function selected_or_one(app,n)
  if not Selection.has(app.selection,n.id) then Selection.set_only(app.selection,n.id) end
  return Selection.list(app.selection,app.cache:get(true))
end
local function snapshot(notes)
  local out={} for _,n in ipairs(notes) do out[#out+1]={note=n,index=n.index,s=n.s,e=n.e,pitch=n.pitch,vel=n.vel} end return out
end
local reselect
local function divide_selection(app,direction)
  local chosen=Selection.list(app.selection,app.cache:get(true)); if #chosen==0 then return false end
  table.sort(chosen,function(a,b) if a.chan~=b.chan then return a.chan<b.chan elseif a.pitch~=b.pitch then return a.pitch<b.pitch else return a.s<b.s end end)
  local runs={}
  for _,n in ipairs(chosen) do local run=runs[#runs]; local previous=run and run[#run]
    if not previous or previous.chan~=n.chan or previous.pitch~=n.pitch or math.abs(previous.e-n.s)>1 then run={}; runs[#runs+1]=run end
    run[#run+1]=n
  end
  local plans,indices={},{ }
  for _,run in ipairs(runs) do
    local count=math.max(1,#run+(direction>0 and 1 or -1)); local first,last=run[1],run[#run]
    if count~=#run then plans[#plans+1]={s=first.s,e=last.e,count=count,pitch=first.pitch,vel=first.vel,chan=first.chan,muted=first.muted}; for _,n in ipairs(run) do indices[#indices+1]=n.index end end
  end
  if #plans==0 then return false end
  app.edit:begin('ReaRoll: divide selected notes',app.take); app.edit:delete_indices(app.take,indices); local wanted={}
  for _,p in ipairs(plans) do for i=1,p.count do local s=p.s+(p.e-p.s)*(i-1)/p.count; local e=p.s+(p.e-p.s)*i/p.count
    app.edit:insert(app.take,s,e,p.pitch,p.vel,p.chan,true,p.muted); wanted[#wanted+1]={s=s,e=e,pitch=p.pitch,vel=p.vel}
  end end
  app.edit:finish(); app.cache:rebuild(); reselect(app,wanted); return true
end
local function glue_key(ppq,pitch,chan)return string.format('%.3f:%d:%d',ppq,pitch,chan or 0) end
local function glue_boundaries(notes,channel)
  local groups,out={},{ }
  for _,n in ipairs(notes) do if channel==nil or (n.chan or 0)==channel then local key=(n.chan or 0)..':'..n.pitch; groups[key]=groups[key] or {}; groups[key][#groups[key]+1]=n end end
  for _,group in pairs(groups) do table.sort(group,function(a,b)return a.s<b.s end); for i=1,#group-1 do local a,b=group[i],group[i+1]
    if math.abs(a.e-b.s)<=1 then out[#out+1]={ppq=(a.e+b.s)*.5,pitch=a.pitch,chan=a.chan or 0,left=a,right=b} end
  end end
  return out
end
local function point_segment_distance(px,py,x1,y1,x2,y2)
  local dx,dy=x2-x1,y2-y1; local length=dx*dx+dy*dy; local t=length>0 and U.clamp(((px-x1)*dx+(py-y1)*dy)/length,0,1) or 0
  local x,y=x1+t*dx,y1+t*dy; return math.sqrt((px-x)^2+(py-y)^2)
end
local function collect_glue_seams(v,notes,g,mx,my,row_h,channel)
  local x1,y1=g.last_x or mx,g.last_y or my
  local dx,dy=mx-x1,my-y1; local distance=math.sqrt(dx*dx+dy*dy)
  if distance>=2 and g.motion_dx and dx*g.motion_dx+dy*g.motion_dy<0 then g.last_candidate=nil end
  if distance>=2 then g.motion_dx,g.motion_dy=dx/distance,dy/distance end
  local encountered={}
  for _,b in ipairs(glue_boundaries(notes,channel)) do local x,y=v:x_from_ppq(b.ppq),v:y_from_pitch(b.pitch)
    if y and point_segment_distance(x,y+row_h*.5,x1,y1,mx,my)<=8 then encountered[#encountered+1]={key=glue_key(b.ppq,b.pitch,b.chan),boundary=b,x=x,y=y} end
  end
  table.sort(encountered,function(a,b) return (a.x-x1)^2+(a.y-y1)^2<(b.x-x1)^2+(b.y-y1)^2 end)
  for _,entry in ipairs(encountered) do
    if entry.key~=g.last_candidate then g.seams[entry.key]=not g.seams[entry.key] or nil; g.last_candidate=entry.key end
  end
  if #encountered==0 then g.last_candidate=nil end
  g.last_x,g.last_y=mx,my
end
local function slice_key(note,ppq)return string.format('%d:%.3f',note.index,ppq) end
local function collect_slice_marks(app,v,notes,g,mx,my,mods)
  local x1,y1=g.last_x or mx,g.last_y or my; local dx,dy=mx-x1,my-y1
  local distance=math.sqrt(dx*dx+dy*dy)
  if distance>=2 and g.motion_dx then
    local dot=dx*g.motion_dx+dy*g.motion_dy
    -- Let the first mark encountered after reversing toggle normally. This
    -- retracts the newest crossed cut without deleting an un-crossed history
    -- entry, which previously produced holes after undo/redo passes.
    if dot<0 then g.last_candidate=nil end
  end
  if distance>=2 then g.motion_dx,g.motion_dy=dx/distance,dy/distance end
  local steps=math.max(1,math.ceil(math.max(math.abs(dx),math.abs(dy))/3)); local encountered={}
  for step=0,steps do
    local t=step/steps; local px,py=x1+dx*t,y1+dy*t
    for _,n in ipairs(notes) do
      local nx1,ny1,nx2,ny2=note_rect(v,n,app.settings.row_height)
      if nx1 and U.contains(px,py,nx1,ny1,nx2,ny2) then
        local q=v:qn_from_x(px)
        if not mods.alt and U.snap_mode(app.settings)~='off' then q=U.snap_time(app.settings,q,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)) end
        local ppq=reaper.MIDI_GetPPQPosFromProjQN(app.take,q)
        if ppq>n.s+1 and ppq<n.e-1 then encountered[#encountered+1]={key=slice_key(n,ppq),note=n,ppq=ppq} end
      end
    end
  end
  for _,mark in ipairs(encountered) do
    if mark.key~=g.last_candidate then
      if g.slices[mark.key] then g.slices[mark.key]=nil else g.slices[mark.key]=mark end
      g.last_candidate=mark.key
    end
  end
  if #encountered==0 then g.last_candidate=nil end
  g.last_x,g.last_y=mx,my
end
local function apply_glue(app,g)
  local notes=app.cache:get(true); local groups={}
  for _,n in ipairs(notes) do local key=(n.chan or 0)..':'..n.pitch; groups[key]=groups[key] or {}; groups[key][#groups[key]+1]=n end
  local chains={}
  for _,group in pairs(groups) do table.sort(group,function(a,b)return a.s<b.s end); local chain={group[1]}
    for i=2,#group do local previous,n=group[i-1],group[i]; local seam=math.abs(previous.e-n.s)<=1 and g.seams[glue_key((previous.e+n.s)*.5,n.pitch,n.chan)]
      if seam then chain[#chain+1]=n else if #chain>1 then chains[#chains+1]=chain end; chain={n} end
    end
    if #chain>1 then chains[#chains+1]=chain end
  end
  if #chains==0 then return end
  local indices,plans={},{ }; for _,chain in ipairs(chains) do local first,last=chain[1],chain[#chain]; plans[#plans+1]={s=first.s,e=last.e,pitch=first.pitch,vel=first.vel,chan=first.chan,muted=first.muted}; for _,n in ipairs(chain) do indices[#indices+1]=n.index end end
  app.edit:begin('ReaRoll: glue notes',app.take); app.edit:delete_indices(app.take,indices); local wanted={}
  for _,p in ipairs(plans) do app.edit:insert(app.take,p.s,p.e,p.pitch,p.vel,p.chan,true,p.muted); wanted[#wanted+1]={s=p.s,e=p.e,pitch=p.pitch,vel=p.vel} end
  app.edit:finish(); app.cache:rebuild(); reselect(app,wanted)
end
reselect=function(app,wanted)
  Selection.clear(app.selection); local used={}
  for _,w in ipairs(wanted) do
    local best,bestd
    for _,n in ipairs(app.cache.notes) do if not used[n] and n.pitch==w.pitch and n.vel==w.vel then local d=math.abs(n.s-w.s)+math.abs(n.e-w.e); if not bestd or d<bestd then best,bestd=n,d end end end
    if best then used[best]=true; Selection.add(app.selection,best.id) end
  end
end

local function chord_pitches(app,root)
  local s=app.settings
  if s.chord_diatonic and s.scale_enabled then
    return app.music.diatonic_chord(s.scale_root,s.scale_name,root,s.chord_size,s.chord_inversion)
  end
  local pitches={}
  for _,interval in ipairs(app.music.chords[s.chord_name] or app.music.chords.Major) do pitches[#pitches+1]=U.clamp(root+interval,0,127) end
  local inversion=math.max(0,math.min(#pitches-1,math.floor(s.chord_inversion or 0)))
  for i=1,inversion do pitches[i]=U.clamp(pitches[i]+12,0,127) end
  table.sort(pitches)
  return pitches
end

local function cursor_qn(app,v,mx)
  local q=U.snap_time(app.settings,v:qn_from_x(mx))
  return math.max(0,q)
end

local function source_timeline_bounds(app)
  local first,last=app.item_start_qn,app.item_end_qn
  if not app.settings.ghost_enabled then return first,last end
  local active_item=app.take and reaper.GetMediaItemTake_Item(app.take); local active_track=active_item and reaper.GetMediaItemTrack(active_item)
  if active_track then
    for i=0,reaper.CountTrackMediaItems(active_track)-1 do
      local item=reaper.GetTrackMediaItem(active_track,i); local take=item and reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        local position=reaper.GetMediaItemInfo_Value(item,'D_POSITION'); local ending=position+reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
        first=math.min(first,reaper.TimeMap2_timeToQN(0,position)); last=math.max(last,reaper.TimeMap2_timeToQN(0,ending))
      end
    end
  end
  if not app.source_visibility then return first,last end
  for track_index=0,reaper.CountTracks(0)-1 do
    local track=reaper.GetTrack(0,track_index); local guid=reaper.GetTrackGUID and reaper.GetTrackGUID(track); local key=guid and guid~='' and guid or tostring(track)
    if app.source_visibility[key]==true then
      for item_index=0,reaper.CountTrackMediaItems(track)-1 do
        local item=reaper.GetTrackMediaItem(track,item_index); local take=reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
          local position=reaper.GetMediaItemInfo_Value(item,'D_POSITION'); local ending=position+reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
          first=math.min(first,reaper.TimeMap2_timeToQN(0,position)); last=math.max(last,reaper.TimeMap2_timeToQN(0,ending))
        end
      end
    end
  end
  return first,last
end

local function draw_background(app,d,v,x0,y0,key_w,ruler_h,grid_h,hover_pitch)
  local I,c,T,s=app.ImGui,app.ctx,app.theme,app.settings; local rows=v:rows()
  I.DrawList_AddRectFilled(d,x0,y0,x0+key_w+v.w,y0+ruler_h+grid_h,T.bg)
  I.DrawList_AddRectFilledMultiColor(d,v.x,y0,v.x+v.w,y0+ruler_h,T.ruler_top,T.ruler_top,T.ruler,T.ruler)
  I.DrawList_AddLine(d,v.x,y0+ruler_h-1,v.x+v.w,y0+ruler_h-1,T.bar,1)
  local white_keys,black_keys={},{ }
  for r=0,rows-1 do
    local p=v:pitch_at_row(r); local y=v.y+r*s.row_height; local black=U.is_black(p)
    local row_color=p%12==0 and T.c_row or (black and T.row_alt or T.row)
    if s.scale_enabled and app.music.contains(s.scale_root,s.scale_name,p) then row_color=(p-s.scale_root)%12==0 and T.root_row or T.scale_row end
    I.DrawList_AddRectFilled(d,v.x,y,v.x+v.w,math.min(y+s.row_height,v.y+v.h),row_color)
    local key={pitch=p,top=y,bottom=math.min(y+s.row_height,v.y+v.h),center=y+s.row_height*.5,black=black}
    if black then black_keys[#black_keys+1]=key else white_keys[#white_keys+1]=key end
    I.DrawList_AddLine(d,v.x,y+s.row_height,v.x+v.w,y+s.row_height,black and T.grid_soft or T.grid)
  end

  local item_x1,item_x2=v:x_from_qn(app.item_start_qn),v:x_from_qn(app.item_end_qn)
  local shade=T.outside_item or 0x090D12A8; local edge=T.item_edge or T.accent
  local left=U.clamp(item_x1,v.x,v.x+v.w); local right=U.clamp(item_x2,v.x,v.x+v.w)
  if left>v.x then I.DrawList_AddRectFilled(d,v.x,v.y,left,v.y+v.h,shade) end
  if right<v.x+v.w then I.DrawList_AddRectFilled(d,right,v.y,v.x+v.w,v.y+v.h,shade) end
  if item_x1>=v.x and item_x1<=v.x+v.w then I.DrawList_AddLine(d,item_x1,y0,item_x1,v.y+v.h,edge,2.4) end
  if item_x2>=v.x and item_x2<=v.x+v.w then I.DrawList_AddLine(d,item_x2,y0,item_x2,v.y+v.h,edge,2.4) end

  if v.fold then
    -- Fold mode is an arbitrary pitch list, so preserve one honest key per row.
    for _,key in ipairs(white_keys) do
      local color=key.pitch%12==0 and T.c_key or T.white_key
      local top_color=key.pitch%12==0 and T.c_key_top or T.white_key_top
      I.DrawList_AddRectFilledMultiColor(d,x0,key.top,v.x-1,key.bottom,top_color,top_color,color,color)
      I.DrawList_AddLine(d,x0,key.bottom,v.x-1,key.bottom,T.key_border)
    end
  else
    -- White keys own the space halfway to the next visible white-key centre.
    -- Accidentals are then laid over those bodies, like a physical keyboard.
    for i,key in ipairs(white_keys) do
      key.top=i==1 and v.y or (white_keys[i-1].center+key.center)*.5
      key.bottom=i==#white_keys and v.y+v.h or (key.center+white_keys[i+1].center)*.5
      local color=key.pitch%12==0 and T.c_key or T.white_key
      local top_color=key.pitch%12==0 and T.c_key_top or T.white_key_top
      I.DrawList_AddRectFilledMultiColor(d,x0,key.top,v.x-1,key.bottom,top_color,top_color,color,color)
      I.DrawList_AddLine(d,x0,key.bottom,v.x-1,key.bottom,T.key_border)
    end
  end

  -- A highlighted white key remains behind the raised accidentals.
  if hover_pitch and not U.is_black(hover_pitch) then
    for _,key in ipairs(white_keys) do
      if key.pitch==hover_pitch then
        I.DrawList_AddRectFilled(d,x0,key.top,v.x-1,key.bottom,T.key_hover)
        I.DrawList_AddRect(d,x0,key.top,v.x-1,key.bottom,T.selected_edge,0,I.DrawFlags_None,1)
        break
      end
    end
  end
  -- White-key selection belongs below the raised black keys.
  if app.key_mapping_mode and app.key_map_selection then
    for _,key in ipairs(white_keys) do if app.key_map_selection[key.pitch] then I.DrawList_AddRect(d,x0,key.top,v.x-1,key.bottom,T.selected_edge,0,I.DrawFlags_None,2) end end
  end

  for _,key in ipairs(black_keys) do
    local top,bottom
    if v.fold then top,bottom=key.top,key.bottom
    else
      local half=math.max(2,s.row_height*.43)
      top,bottom=math.max(v.y,key.center-half),math.min(v.y+v.h,key.center+half)
    end
    local right=x0+key_w*.64
    local right_corners=I.DrawFlags_RoundCornersRight or I.DrawFlags_None
    I.DrawList_AddRectFilled(d,x0,top,right,bottom,T.black_key,2,right_corners)
    I.DrawList_AddLine(d,x0+1,top+1,right-2,top+1,T.black_key_top,1)
    I.DrawList_AddRect(d,x0,top,right,bottom,T.key_border,2,right_corners,1)
    key.top,key.bottom,key.right=top,bottom,right
  end
  -- Black-key hover belongs above the black-key layer itself.
  if hover_pitch and U.is_black(hover_pitch) then
    for _,key in ipairs(black_keys) do
      if key.pitch==hover_pitch then
        local right_corners=I.DrawFlags_RoundCornersRight or I.DrawFlags_None
        I.DrawList_AddRectFilled(d,x0,key.top,key.right,key.bottom,T.key_hover,2,right_corners)
        I.DrawList_AddRect(d,x0,key.top,key.right,key.bottom,T.selected_edge,2,right_corners,1)
        break
      end
    end
  end

  -- Pitch maps color only a compact section of each key. Note bodies retain
  -- their channel colors and the piano's black/white geometry stays legible.
  for _,keys in ipairs({white_keys,black_keys}) do
    for _,key in ipairs(keys) do
      local right=key.right or v.x-1; local color=app.key_colors and app.key_colors[key.pitch]
      if color then
        local strip=math.max(6,math.min(10,(right-x0)*.18))
        I.DrawList_AddRectFilled(d,right-strip,key.top+1,right,key.bottom-1,color,key.black and 2 or 0)
      end
      if key.black and app.key_mapping_mode and app.key_map_selection and app.key_map_selection[key.pitch] then
        I.DrawList_AddRect(d,x0,key.top,right,key.bottom,T.selected_edge,key.black and 2 or 0,I.DrawFlags_None,2)
      end
    end
  end

  for _,key in ipairs(white_keys) do
    local custom=app.note_label and app:note_label(key.pitch) or nil
    if (custom or v.fold or key.pitch%12==0) and s.row_height>=11 then
      local label=custom or U.pitch_name(key.pitch); if #label>12 then label=label:sub(1,12) end
      local tw,th=I.CalcTextSize(c,label); th=th or math.min(s.row_height,key.bottom-key.top)
      I.DrawList_AddText(d,v.x-tw-4,(key.top+key.bottom-th)*.5,T.black_key,label)
    end
  end
  -- Keep the visual grid useful at every zoom level without changing the
  -- user's actual snap resolution. Dense divisions progressively coalesce.
  local visual_grid=s.grid_qn
  while visual_grid*v.px_per_qn<8 and visual_grid<4 do visual_grid=visual_grid*2 end
  -- Ask REAPER for actual measure boundaries so time-signature changes and
  -- project offsets do not produce misleading ruler numbers.
  local finish=s.start_qn+s.visible_qn; local measure,bar_qn,bar_end=reaper.TimeMap_QNToMeasures(0,s.start_qn)
  local guard=0
  while bar_qn<=finish and guard<512 do
    local x=crisp_x(v:x_from_qn(bar_qn))
    local _,denom=reaper.TimeMap_GetTimeSigAtTime(0,reaper.TimeMap2_QNToTime(0,bar_qn)); local beat_step=4/(denom or 4)
    local beat_number=0
    for q=bar_qn,bar_end-beat_step*.25,beat_step do
      if beat_number%2==1 then local left,right=math.max(v.x,v:x_from_qn(q)),math.min(v.x+v.w,v:x_from_qn(math.min(bar_end,q+beat_step))); if right>left then I.DrawList_AddRectFilled(d,left,v.y,right,v.y+v.h,T.beat_shade) end end
      beat_number=beat_number+1
    end
    if x>=v.x-1 and x<=v.x+v.w then I.DrawList_AddLine(d,x,y0,x,v.y+v.h,T.bar,1.6); I.DrawList_AddText(d,x+7,y0+3,T.ruler_text,displayed_measure(bar_qn,measure)) end
    if visual_grid*v.px_per_qn>=8 then
      for q=bar_qn+visual_grid,bar_end-.000001,visual_grid do
        local beat_index=(q-bar_qn)/beat_step
        if math.abs(beat_index-math.floor(beat_index+.5))>.00001 then
          local sx=crisp_x(v:x_from_qn(q))
          if sx>=v.x and sx<=v.x+v.w then I.DrawList_AddLine(d,sx,v.y,sx,v.y+v.h,T.grid_soft) end
        end
      end
    end
    if beat_step*v.px_per_qn>=10 then
      for q=bar_qn+beat_step,bar_end-beat_step*.25,beat_step do local bx=crisp_x(v:x_from_qn(q)); if bx>=v.x and bx<=v.x+v.w then I.DrawList_AddLine(d,bx,y0,bx,v.y+v.h,T.beat) end end
    end
    local next_measure,next_start,next_end=reaper.TimeMap_QNToMeasures(0,bar_end+.000001)
    if next_start<=bar_qn then break end
    measure,bar_qn,bar_end=next_measure,next_start,next_end; guard=guard+1
  end
end

local function marquee_hits(g,x1,y1,x2,y2)
  if not g or g.kind~='marquee' then return false end
  local ax,bx=math.min(g.x1,g.x2),math.max(g.x1,g.x2)
  local ay,by=math.min(g.y1,g.y2),math.max(g.y1,g.y2)
  return x2>=ax and x1<=bx and y2>=ay and y1<=by
end

local function update_marquee_world(g,v,mx,my)
  if not g or g.kind~='marquee' then return end
  g.qn2=v:qn_from_x(mx); g.pitch2=v:pitch_from_y(my)
end

local function marquee_note_hit(g,v,n)
  if g.qn1==nil or g.qn2==nil or g.pitch1==nil or g.pitch2==nil then
    local nx1,ny1,nx2,ny2=note_rect(v,n,v.s.row_height)
    return nx1 and marquee_hits(g,nx1,ny1,nx2,ny2)
  end
  local nq1,nq2=math.min(g.qn1,g.qn2),math.max(g.qn1,g.qn2)
  local p1,p2=math.min(g.pitch1,g.pitch2),math.max(g.pitch1,g.pitch2)
  local ns=v.s.start_qn+(n.s-v.ppq0)/v.ppq_per_qn
  local ne=v.s.start_qn+(n.e-v.ppq0)/v.ppq_per_qn
  return ne>=nq1 and ns<=nq2 and n.pitch>=p1 and n.pitch<=p2
end

local function with_alpha(color,alpha) return (color&0xFFFFFF00)|alpha end
local function lighten_color(color,amount)
  amount=U.clamp(amount,0,1)
  local r=(color>>24)&0xFF; local g=(color>>16)&0xFF; local b=(color>>8)&0xFF; local a=color&0xFF
  r=math.floor(r+(255-r)*amount+.5); g=math.floor(g+(255-g)*amount+.5); b=math.floor(b+(255-b)*amount+.5)
  return (r<<24)|(g<<16)|(b<<8)|a
end
local function color_luminance(color)
  return ((color>>24)&0xFF)*.299+((color>>16)&0xFF)*.587+((color>>8)&0xFF)*.114
end
local function contrast_color(color,background,minimum)
  local result=color; local bg=color_luminance(background)
  for _=1,8 do
    if math.abs(color_luminance(result)-bg)>=minimum then break end
    result=bg<145 and lighten_color(result,.22) or U.color_scale(result,.72)
  end
  return result
end
local function lane_graph_color(color,background)
  return contrast_color(color,background,color_luminance(background)>=145 and 92 or 68)
end
local function note_row_background(app,pitch)
  local T,s=app.theme,app.settings; local black=U.is_black(pitch)
  local color=pitch%12==0 and T.c_row or (black and T.row_alt or T.row)
  if s.scale_enabled and app.music.contains(s.scale_root,s.scale_name,pitch) then color=(pitch-s.scale_root)%12==0 and T.root_row or T.scale_row end
  return color
end
local function note_display_color(color,background,ghost)
  local light=color_luminance(background)>=145
  return contrast_color(color,background,ghost and (light and 44 or 36) or (light and 58 or 48))
end
local function live_overlap_shape(app,n)
  local g=app.gesture
  if not app.settings.prevent_overlaps or not g or not g.items or (g.kind~='move' and g.kind~='resize' and g.kind~='stretch') then return n end
  for _,a in ipairs(g.items) do if a.index==n.index then return n end end
  local s,e=n.s,n.e
  for _,a in ipairs(g.items) do local winner=a.note
    if winner and (winner.chan or 0)==(n.chan or 0) and winner.pitch==n.pitch and e>winner.s and s<winner.e then
      if s<winner.s then e=math.min(e,winner.s)
      elseif e>winner.e then s=math.max(s,winner.e)
      else return nil end
    end
  end
  if e<=s then return nil end
  return {s=s,e=e,pitch=n.pitch}
end
local function live_note_rect(app,v,n,row_h)
  local live=live_overlap_shape(app,n)
  if live then return note_rect(v,live,row_h) end
end
local function lane_graph_fill(color,background)
  return (color&0xFFFFFF00)|(color_luminance(background)>=145 and 0x58 or 0x38)
end
local function overlapping_channels(notes,target)
  local seen,out={},{}
  for _,n in ipairs(notes) do
    local channel=n.chan or 0
    if n~=target and channel~=(target.chan or 0) and n.pitch==target.pitch and n.e>target.s and n.s<target.e and not seen[channel] then seen[channel]=true; out[#out+1]=channel end
  end
  table.sort(out); return out
end

local function draw_notes(app,d,v,notes,hover,play_ppq)
  local I,T,s=app.ImGui,app.theme,app.settings
  local active_item=app.take and reaper.GetMediaItemTake_Item(app.take); local active_track=active_item and reaper.GetMediaItemTrack(active_item)
  local track_col=U.track_color(active_track,T.note)
  local ordered={}
  -- Reference channels sit behind the active editing channel so coincident
  -- notes never obscure the layer the tools will affect.
  for _,n in ipairs(notes) do if (n.chan or 0)~=(s.channel or 0) then ordered[#ordered+1]=n end end
  for _,n in ipairs(notes) do if (n.chan or 0)==(s.channel or 0) then ordered[#ordered+1]=n end end
  for _,n in ipairs(ordered) do
    local x1,y1,x2,y2=live_note_rect(app,v,n,s.row_height)
    local sel=Selection.has(app.selection,n.id)
    if x1 and marquee_hits(app.gesture,x1,y1,x2,y2) then sel=true end
    if x1 then
    local row_background=note_row_background(app,n.pitch); local channel_col=track_col
    local active=(n.chan or 0)==(s.channel or 0); local velocity_col=note_display_color(U.color_scale(channel_col,.72+.28*(n.vel/127)),row_background,false); local col=n.muted and T.muted or (hover==n and U.color_scale(velocity_col,1.18) or velocity_col)
    local playback_intensity,playback_progress,sustain_breathe=0,nil,0
    if play_ppq and not n.muted then
      local release=math.max(1,v.ppq_per_qn*.055)
      if play_ppq>=n.s and play_ppq<n.e then
        local attack=math.max(1,v.ppq_per_qn*.045)
        playback_progress=(play_ppq-n.s)/math.max(1,n.e-n.s)
        local musical_qn=play_ppq/math.max(1,v.ppq_per_qn)
        sustain_breathe=.5+.5*math.sin(musical_qn*math.pi)
        playback_intensity=.50+.16*sustain_breathe+.34*math.exp(-(play_ppq-n.s)/attack)
      elseif play_ppq>=n.e and play_ppq<n.e+release then playback_intensity=.34*(1-(play_ppq-n.e)/release) end
      if playback_intensity>0 then
        col=lighten_color(velocity_col,.10+.18*sustain_breathe+.16*math.max(0,playback_intensity-.66))
      end
    end
    if not active and not sel then col=with_alpha(col,0x70) end
    local left,right,top,bottom=x1+1,x2-1,y1+1,y2-2
    if right-left>=2 and bottom-top>=2 then
      I.DrawList_AddRectFilled(d,left+1,top+2,right+1,bottom+2,T.shadow,3)
      if playback_intensity>0 then
        local glow=U.color_scale(velocity_col,1.30)
        I.DrawList_AddRect(d,left-3,top-3,right+3,bottom+3,with_alpha(glow,math.floor(34*playback_intensity)),5,I.DrawFlags_None,3)
        I.DrawList_AddRect(d,left-1,top-1,right+1,bottom+1,with_alpha(glow,math.floor(120*playback_intensity)),4,I.DrawFlags_None,2)
      end
      I.DrawList_AddRectFilled(d,left,top,right,bottom,col,3)
      if right-left>=6 then
        I.DrawList_AddRectFilledMultiColor(d,left+1,top+1,right-1,bottom-1,U.color_scale(col,1.10),U.color_scale(col,1.10),U.color_scale(col,.88),U.color_scale(col,.88))
      end
      if playback_progress then
        local breath_col=lighten_color(velocity_col,.55)
        local breath_alpha=math.floor(10+48*sustain_breathe)
        I.DrawList_AddRectFilled(d,left+1,top+1,right-1,bottom-1,with_alpha(breath_col,breath_alpha),3)
        I.DrawList_AddRect(d,left-1,top-1,right+1,bottom+1,with_alpha(breath_col,math.floor(45+85*sustain_breathe)),4,I.DrawFlags_None,1.5)
      end
      if playback_progress then
        local sheen_x=left+playback_progress*(right-left); local sheen_w=math.min(14,math.max(5,(right-left)*.12)); local sheen=U.color_scale(velocity_col,1.45)
        local a0=with_alpha(sheen,0); local a1=with_alpha(sheen,math.floor(92*playback_intensity))
        local sx1=math.max(left,sheen_x-sheen_w); local sx2=math.min(right,sheen_x+sheen_w)
        if sheen_x>sx1 then I.DrawList_AddRectFilledMultiColor(d,sx1,top+1,sheen_x,bottom-1,a0,a1,a1,a0) end
        if sx2>sheen_x then I.DrawList_AddRectFilledMultiColor(d,sheen_x,top+1,sx2,bottom-1,a1,a0,a0,a1) end
      end
      local body_luminance=color_luminance(col)
      I.DrawList_AddRect(d,left,top,right,bottom,T.note_border,3,I.DrawFlags_None,1)
      I.DrawList_AddLine(d,left+2,top+1,right-3,top+1,T.note_highlight,1)
      I.DrawList_AddLine(d,left+3,top+2,left+3,bottom-2,sel and T.selected_edge or T.resize,1.5)
      I.DrawList_AddLine(d,right-3,top+2,right-3,bottom-2,sel and T.selected_edge or T.resize,1.5)
      if sel then I.DrawList_AddRect(d,left-1,top-1,right+1,bottom+1,T.selected_edge,3,I.DrawFlags_None,2) end
      if active then
        local stacked=overlapping_channels(notes,n); local marker_x=left+3
        for _,channel in ipairs(stacked) do
          local marker_right=math.min(right-2,marker_x+5); if marker_right>marker_x then I.DrawList_AddRectFilled(d,marker_x,bottom-3,marker_right,bottom,T.channel_colors[channel+1] or T.note,1) end
          marker_x=marker_x+7
        end
      end
      if right-left>=28 and bottom-top>=11 then
        local label=U.pitch_name(n.pitch); if right-left>=62 then label=label..'  v'..tostring(n.vel) end
        local text_col=body_luminance>130 and 0x101820FF or 0xF0F3F7FF
        I.DrawList_AddText(d,left+4,top+1,sel and T.selected_text or text_col,label)
      end
    end end
  end
end

local function draw_ghost_notes(app,d,v,mx,my)
  if not app.settings.ghost_enabled then return nil end
  local I,T,s=app.ImGui,app.theme,app.settings
  local hit,best_area=nil,math.huge
  for _,n in ipairs(app.ghost:get(app.take,s.ghost_mode,app.gesture~=nil,app.source_visibility,app.source_revision)) do
    if n.e_qn>=s.start_qn and n.s_qn<=s.start_qn+s.visible_qn and v:is_pitch_visible(n.pitch) then
      local x1,x2=v:x_from_qn(n.s_qn),v:x_from_qn(n.e_qn); local y1=v:y_from_pitch(n.pitch); local y2=y1+s.row_height
      local background=note_row_background(app,n.pitch); local color=note_display_color(n.color or T.note,background,true)
      I.DrawList_AddRectFilled(d,x1+2,y1+2,x2-2,y2-3,(color&0xFFFFFF00)|0x42,2)
      I.DrawList_AddRect(d,x1+2,y1+2,x2-2,y2-3,(color&0xFFFFFF00)|0xA0,2,I.DrawFlags_None,1)
      if U.contains(mx,my,x1+1,y1+1,x2-1,y2-2) then local area=(x2-x1)*(y2-y1); if area<best_area then hit,best_area=n,area end end
    end
  end
  return hit
end

local function draw_placement_preview(app,d,v,mx,my,hover)
  local I,T,s=app.ImGui,app.theme,app.settings
  local length=Grid.note_length(s)
  if app.gesture or hover or s.mode=='slice' or s.mode=='glue' or mx<v.x or mx>v.x+v.w or my<v.y or my>v.y+v.h then return end
  local raw_q=v:qn_from_x(mx); local q=U.snap_time(s,raw_q)
  q=U.clamp(q,app.item_start_qn,math.max(app.item_start_qn,(app.item_end_qn or q+length)-length))
  local hover_pitch=v:pitch_from_y(my); local root=hover_pitch; if s.scale_enabled and s.scale_snap then root=app.music.snap(s.scale_root,s.scale_name,root) end
  local pitches=s.mode=='chord' and chord_pitches(app,root) or {root}
  local x1,x2=math.max(v.x,v:x_from_qn(q)),math.min(v.x+v.w,v:x_from_qn(q+length))
  local channel_col=s.uniform_note_color and T.note or (T.channel_colors[(s.channel or 0)+1] or T.note); local velocity_col=U.color_scale(channel_col,.72+.28*(s.velocity/127))
  local preview_fill=(velocity_col&0xFFFFFF00)|0x66; local preview_edge=(U.color_scale(velocity_col,1.18)&0xFFFFFF00)|0xCC
  for _,pitch in ipairs(pitches) do if v:is_pitch_visible(pitch) then local y=v:y_from_pitch(pitch); I.DrawList_AddRectFilled(d,x1+1,y+1,x2-1,y+s.row_height-2,preview_fill,3); I.DrawList_AddRect(d,x1+1,y+1,x2-1,y+s.row_height-2,preview_edge,3,I.DrawFlags_None,1) end end
  if s.mode=='chord' then
    local anchor_present=false; for _,pitch in ipairs(pitches) do if pitch==hover_pitch then anchor_present=true; break end end
    if not anchor_present and v:is_pitch_visible(hover_pitch) then
      -- Inversions can move every sounding note away from the pointer pitch.
      -- Keep a hollow note under the mouse to show the non-inserted anchor.
      local anchor_y=v:y_from_pitch(hover_pitch)
      I.DrawList_AddRect(d,x1+1,anchor_y+1,x2-1,anchor_y+s.row_height-2,T.hint,3,I.DrawFlags_None,1.5)
    end
  end
  I.DrawList_AddText(d,U.clamp(mx+12,v.x,v.x+v.w-110),U.clamp(my+10,v.y,v.y+v.h-18),T.preview_text,U.pitch_name(root)..'  Vel '..tostring(s.velocity)..'  Ch '..tostring((s.channel or 0)+1))
end

local function draw_selection_bounds(app,d,v,notes,mx,my,all_notes)
  if (all_notes and #notes or Selection.count(app.selection))<2 then return false end
  local I,T,s=app.ImGui,app.theme,app.settings; local x1,y1,x2,y2=math.huge,math.huge,-math.huge,-math.huge; local found=false
  for _,n in ipairs(notes) do if all_notes or Selection.has(app.selection,n.id) then local nx1,ny1,nx2,ny2=note_rect(v,n,s.row_height); if nx1 then x1,y1,x2,y2=math.min(x1,nx1),math.min(y1,ny1),math.max(x2,nx2),math.max(y2,ny2); found=true end end end
  if not found then return false end
  x1,x2=U.clamp(x1,v.x,v.x+v.w),U.clamp(x2,v.x,v.x+v.w); y1,y2=U.clamp(y1,v.y,v.y+v.h),U.clamp(y2,v.y,v.y+v.h)
  I.DrawList_AddRect(d,x1-2,y1-2,x2+2,y2+2,T.selection_box,3,I.DrawFlags_None,1)
  local hx,hy=U.clamp(x2+2,v.x+6,v.x+v.w-6),U.clamp(y1-5,v.y+5,v.y+v.h-5); I.DrawList_AddCircleFilled(d,hx,hy,5,T.selection_handle); I.DrawList_AddCircle(d,hx,hy,6,T.selected_edge,0,1)
  return (mx-hx)^2+(my-hy)^2<=64
end

local function keyboard_shortcuts(app,take,notes)
  local I,c=app.ImGui,app.ctx; if not I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows) then return end
  if I.IsAnyItemActive(c) or app.gesture then return end
  local mods=U.mods(I,c)
  if Shortcuts.pressed(app,'undo',mods) then
    if app.lane_tool_preview then LaneTools.cancel(app) end
    if app.transform_preview then app.transforms.cancel_preview(app) end
    if app.property_wheel then app:flush_property_wheel(true) elseif app.edit.active then app.edit:finish() end
    reaper.Undo_DoUndo2(0)
    app.cache:invalidate(); app.cc_cache:invalidate(); Selection.clear(app.selection); return
  end
  if Shortcuts.pressed(app,'redo',mods) then if app.lane_tool_preview then LaneTools.cancel(app) end; if app.transform_preview then app.transforms.cancel_preview(app) end; if app.property_wheel then app:flush_property_wheel(true) elseif app.edit.active then app.edit:finish() end; reaper.Undo_DoRedo2(0); app.cache:invalidate(); app.cc_cache:invalidate(); Selection.clear(app.selection); return end
  if Shortcuts.pressed(app,'select_all',mods) then if app.controller_selection_active then app.clipboard.select_all_cc(app,app.controller_lane,true) else for _,n in ipairs(app.cache:get(false)) do Selection.add(app.selection,n.id) end end end
  if Shortcuts.pressed(app,'deselect',mods) then if app.controller_selection_active then app.clipboard.select_all_cc(app,app.controller_lane,false) else Selection.clear(app.selection) end; app.lane_time_selection=nil; app.controller_selection_active=false end
  if Shortcuts.pressed(app,'cancel',mods) then if app.controller_selection_active then app.clipboard.select_all_cc(app,app.controller_lane,false) else Selection.clear(app.selection) end; app.lane_time_selection=nil; app.controller_selection_active=false end
  if Shortcuts.pressed(app,'delete',mods) then
    if app.controller_selection_active then app.clipboard.delete_cc(app,app.controller_lane) else local list=Selection.list(app.selection,app.cache:get(false)); if #list>0 then app.edit:begin('ReaRoll: delete notes',take); local ids={}; for _,n in ipairs(list) do ids[#ids+1]=n.index end; app.edit:delete_indices(take,ids); app.edit:finish(); Selection.clear(app.selection) end end
  end
  if Shortcuts.pressed(app,'copy',mods) then if app.controller_selection_active then app.clipboard.copy_cc(app,app.controller_lane) else app.clipboard.copy(app) end end
  if Shortcuts.pressed(app,'cut',mods) then if app.controller_selection_active then app.clipboard.cut_cc(app,app.controller_lane) else app.clipboard.cut(app) end end
  if Shortcuts.pressed(app,'paste',mods) then if app.controller_selection_active and app.cc_clipboard then app.clipboard.paste_cc(app) else app.clipboard.paste(app) end end
  if Shortcuts.pressed(app,'duplicate',mods) then if app.controller_selection_active then app.clipboard.duplicate_cc(app,app.controller_lane) else app.clipboard.duplicate(app) end end
  local duplicate_up=Shortcuts.pressed(app,'duplicate_octave_up',mods); local duplicate_down=Shortcuts.pressed(app,'duplicate_octave_down',mods)
  if duplicate_up or duplicate_down then
    local direction=duplicate_up and 12 or -12
    local chosen=Selection.list(app.selection,app.cache:get(false)); if #chosen>0 then
      app.edit:begin('ReaRoll: duplicate octave',take); local wanted={}
      for _,n in ipairs(chosen) do local pitch=U.clamp(n.pitch+direction,0,127); app.edit:insert(take,n.s,n.e,pitch,n.vel,n.chan,true,n.muted); wanted[#wanted+1]={s=n.s,e=n.e,pitch=pitch,vel=n.vel} end
      app.edit:finish(); app.cache:rebuild(); reselect(app,wanted)
    end
  end
  if Shortcuts.pressed(app,'quantize',mods) then app.transforms.quantize(app,false) end
  if Shortcuts.pressed(app,'legato',mods) then app.transforms.legato(app) end
  if Shortcuts.pressed(app,'snap',mods) then local mode=U.snap_mode(app.settings); app.settings.snap_mode=mode=='off' and 'absolute' or mode=='absolute' and 'relative' or 'off'; app.settings.snap_enabled=app.settings.snap_mode~='off' end
  if Shortcuts.pressed(app,'fit_width',mods) then app:fit_time() end
  if Shortcuts.pressed(app,'fit_height',mods) then app:fit_pitches() end
  if Shortcuts.pressed(app,'fit_selection',mods) then app:fit_selection() end
  if Shortcuts.pressed(app,'zoom_in',mods) then app:zoom_time(.82,app.viewport.x+app.viewport.w*.5) end
  if Shortcuts.pressed(app,'zoom_out',mods) then app:zoom_time(1.22,app.viewport.x+app.viewport.w*.5) end
  for action,mode in pairs({tool_smart='smart',tool_paint='paint',tool_select='select',tool_slice='slice',tool_mute='mute',tool_chord='chord'}) do if Shortcuts.pressed(app,action,mods) then app.settings.mode=mode end end
  local qn_delta,pitch_delta=0,0
  local resize_delta,velocity_delta=0,0
  if Shortcuts.pressed(app,'nudge_left',mods) then qn_delta=-app.settings.grid_qn elseif Shortcuts.pressed(app,'nudge_right',mods) then qn_delta=app.settings.grid_qn
  elseif Shortcuts.pressed(app,'pitch_up',mods) then pitch_delta=1 elseif Shortcuts.pressed(app,'pitch_down',mods) then pitch_delta=-1
  elseif Shortcuts.pressed(app,'length_shorter',mods) then resize_delta=-app.settings.grid_qn elseif Shortcuts.pressed(app,'length_longer',mods) then resize_delta=app.settings.grid_qn
  elseif Shortcuts.pressed(app,'octave_up',mods) then pitch_delta=12 elseif Shortcuts.pressed(app,'octave_down',mods) then pitch_delta=-12
  elseif Shortcuts.pressed(app,'velocity_up',mods) then velocity_delta=10 elseif Shortcuts.pressed(app,'velocity_down',mods) then velocity_delta=-10 end
  if qn_delta~=0 or pitch_delta~=0 then
    local chosen=Selection.list(app.selection,app.cache:get(false))
    if #chosen>0 then
      app.edit:begin('ReaRoll: nudge notes',take); local ppq_delta=qn_delta~=0 and qn_delta*((reaper.MIDI_GetPPQPosFromProjQN(take,app.settings.start_qn+1)-reaper.MIDI_GetPPQPosFromProjQN(take,app.settings.start_qn))) or 0; local wanted={}
      for _,n in ipairs(chosen) do local p=U.clamp(n.pitch+pitch_delta,0,127); app.edit:set(n.index,take,n.s+ppq_delta,n.e+ppq_delta,p,nil); wanted[#wanted+1]={s=n.s+ppq_delta,e=n.e+ppq_delta,pitch=p,vel=n.vel} end
      app.edit:finish(); app.cache:rebuild(); reselect(app,wanted)
    end
  end
  if resize_delta~=0 or velocity_delta~=0 then
    local chosen=Selection.list(app.selection,app.cache:get(false)); if #chosen>0 then
      local ppq_grid=(reaper.MIDI_GetPPQPosFromProjQN(take,app.settings.start_qn+1)-reaper.MIDI_GetPPQPosFromProjQN(take,app.settings.start_qn))*resize_delta
      app.edit:begin(resize_delta~=0 and 'ReaRoll: resize notes' or 'ReaRoll: adjust velocity',take); local wanted={}
      for _,n in ipairs(chosen) do local ending=resize_delta~=0 and math.max(n.s+1,n.e+ppq_grid) or n.e; local vel=velocity_delta~=0 and U.clamp(n.vel+velocity_delta,1,127) or n.vel; app.edit:set(n.index,take,nil,ending,nil,vel); wanted[#wanted+1]={s=n.s,e=ending,pitch=n.pitch,vel=vel} end
      app.edit:finish(); app.cache:rebuild(); reselect(app,wanted)
    end
  end
  if Shortcuts.pressed(app,'play',mods) then reaper.Main_OnCommand(40044,0) end
  for slot=1,4 do if Shortcuts.pressed(app,'reaper_action_'..slot,mods) then
    local command=tostring(app.settings['reaper_action_'..slot] or '')
    local id=tonumber(command) or (command~='' and reaper.NamedCommandLookup(command) or 0)
    if id and id~=0 then reaper.Main_OnCommand(id,0) else app.transform_notice='REAPER action slot '..slot..' is not configured.' end
  end end
end

local function delete_selected(app)
  local list=Selection.list(app.selection,app.cache:get(false)); if #list==0 then return false end
  app.edit:begin('ReaRoll: delete notes',app.take); local ids={}
  for _,n in ipairs(list) do ids[#ids+1]=n.index end
  app.edit:delete_indices(app.take,ids); app.edit:finish(); Selection.clear(app.selection); app.cache:rebuild(); return true
end

local function mute_selected(app,target)
  local list=Selection.list(app.selection,app.cache:get(false)); if #list==0 then return false end
  app.edit:begin(target and 'ReaRoll: mute notes' or 'ReaRoll: unmute notes',app.take)
  for _,n in ipairs(list) do app.edit:set_muted(app.take,n.index,target) end
  app.edit:finish(); app.cache:rebuild(); return true
end

local function note_context(app)
  local I,c=app.ImGui,app.ctx
  if I.BeginPopup(c,'##note_context') then
    local count=Selection.count(app.selection); I.TextDisabled(c,string.format('%d note%s',count,count==1 and '' or 's')); I.Separator(c)
    if I.MenuItem(c,'Duplicate') then app.clipboard.duplicate(app) end
    if I.MenuItem(c,'Mute') then mute_selected(app,true) end
    if I.MenuItem(c,'Unmute') then mute_selected(app,false) end
    if I.MenuItem(c,'Delete') then delete_selected(app) end
    I.Separator(c)
    if I.MenuItem(c,'Fit selection') then app:fit_selection() end
    I.EndPopup(c)
  end
end

local function note_properties(app)
  local I,c=app.ImGui,app.ctx
  if I.BeginPopup(c,'##note_properties') then
    local count=Selection.count(app.selection); I.Text(c,string.format('%d selected note%s',count,count==1 and '' or 's')); I.Separator(c)
    local changed; changed,app.property_velocity=I.SliderInt(c,'Velocity',app.property_velocity or 100,1,127)
    changed,app.property_channel=I.SliderInt(c,'MIDI channel',app.property_channel or 1,1,16)
    changed,app.property_muted=I.Checkbox(c,'Muted',app.property_muted or false)
    if I.Button(c,'Apply',100,0) then
      local chosen=Selection.list(app.selection,app.cache:get(false)); if #chosen>0 then app.edit:begin('ReaRoll: note properties',app.take); local wanted={}
        for _,n in ipairs(chosen) do local channel=(app.property_channel or 1)-1; reaper.MIDI_SetNote(app.take,n.index,nil,app.property_muted,nil,nil,channel,nil,app.property_velocity,true); app.edit:touch(); app.edit:track_note(n.index,{muted=app.property_muted,chan=channel,vel=app.property_velocity}); wanted[#wanted+1]={s=n.s,e=n.e,pitch=n.pitch,vel=app.property_velocity} end
        app.edit:finish(); app.cache:rebuild(); app:reselect_notes(wanted)
      end; I.CloseCurrentPopup(c)
    end
    I.SameLine(c); if I.Button(c,'Cancel',100,0) then I.CloseCurrentPopup(c) end
    I.EndPopup(c)
  end
end

local function draw_scrollbars(app,d,v,gx,gy,grid_h,vy,lane_h,hbar_h,vbar_w,mx,my)
  local I,c,T,s=app.ImGui,app.ctx,app.theme,app.settings
  local function arrow(id,x1,y1,x2,y2,direction,action)
    local hot=U.contains(mx,my,x1,y1,x2,y2); local pressed=hot and I.IsMouseDown(c,I.MouseButton_Left)
    local icon_color=pressed and (T.selected_edge or T.text) or hot and T.accent or U.color_scale(T.accent,.72)
    I.DrawList_AddRectFilled(d,x1+1,y1+1,x2-1,y2-1,T.scrollbar_track,4)
    local cx,cy=(x1+x2)*.5,(y1+y2)*.5; local size=math.max(4,math.min(x2-x1,y2-y1)*.3)
    if direction=='left' then I.DrawList_AddTriangleFilled(d,cx-size,cy,cx+size,cy-size,cx+size,cy+size,icon_color)
    elseif direction=='right' then I.DrawList_AddTriangleFilled(d,cx+size,cy,cx-size,cy-size,cx-size,cy+size,icon_color)
    elseif direction=='up' then I.DrawList_AddTriangleFilled(d,cx,cy-size,cx-size,cy+size,cx+size,cy+size,icon_color)
    elseif direction=='down' then I.DrawList_AddTriangleFilled(d,cx,cy+size,cx-size,cy-size,cx+size,cy-size,icon_color)
    else local tw,th=I.CalcTextSize(c,direction); I.DrawList_AddText(d,cx-tw*.5,cy-(th or 10)*.5,T.text,direction) end
    I.SetCursorScreenPos(c,x1,y1); I.InvisibleButton(c,id,x2-x1,y2-y1)
    local now=reaper.time_precise()
    if I.IsItemActivated(c) then action(); app.nav_repeat={id=id,next_time=now+.32} end
    if I.IsItemActive(c) and I.IsMouseDown(c,I.MouseButton_Left) and app.nav_repeat and app.nav_repeat.id==id and now>=app.nav_repeat.next_time then action(); app.nav_repeat.next_time=now+.055 end
    if I.IsMouseReleased(c,I.MouseButton_Left) and app.nav_repeat and app.nav_repeat.id==id then app.nav_repeat=nil end
    if I.IsItemHovered(c) then local wheel=I.GetMouseWheel(c); if wheel~=0 then action(wheel) end end
  end
  local htrack_y=vy+lane_h; local button_w=hbar_h; local zoom_w=86
  local hleft_x1,hleft_x2=gx,gx+button_w; local hright_x2=gx+v.w-zoom_w; local hright_x1=hright_x2-button_w
  local htrack_x1,htrack_x2=hleft_x2,hright_x1
  local content_start=v.min_qn or app.item_start_qn; local content_end=math.max(v.timeline_end or app.item_end_qn or content_start,content_start+.001)
  local content_span=content_end-content_start; local visible=math.min(s.visible_qn,content_span)
  local hthumb_w=math.max(28,(htrack_x2-htrack_x1)*(visible/content_span)); local htravel=math.max(0,(htrack_x2-htrack_x1)-hthumb_w)
  local max_start=math.max(content_start,content_end-visible); local hrange=math.max(.001,max_start-content_start)
  local hratio=U.clamp((s.start_qn-content_start)/hrange,0,1); local hthumb_x=htrack_x1+hratio*htravel
  I.DrawList_AddRectFilled(d,htrack_x1,htrack_y,htrack_x2,htrack_y+hbar_h,T.scrollbar_track,4)
  local hhot=U.contains(mx,my,hthumb_x,htrack_y,hthumb_x+hthumb_w,htrack_y+hbar_h)
  I.DrawList_AddRectFilled(d,hthumb_x+1,htrack_y+2,hthumb_x+hthumb_w-1,htrack_y+hbar_h-2,hhot and T.scrollbar_hover or T.scrollbar_thumb,4)
  I.SetCursorScreenPos(c,htrack_x1,htrack_y); I.InvisibleButton(c,'##timeline_scrollbar',htrack_x2-htrack_x1,hbar_h)
  if I.IsItemActivated(c) then app.hscroll_grab=hhot and mx-hthumb_x or hthumb_w*.5 end
  if I.IsItemActive(c) and I.IsMouseDown(c,I.MouseButton_Left) and htravel>0 then
    local ratio=U.clamp((mx-htrack_x1-(app.hscroll_grab or hthumb_w*.5))/htravel,0,1); s.start_qn=content_start+ratio*(max_start-content_start)
  end
  if I.IsItemHovered(c) then local wheel=I.GetMouseWheel(c); if wheel~=0 then v:pan(wheel*50,0) end end
  arrow('##timeline_left',hleft_x1,htrack_y,hleft_x2,htrack_y+hbar_h,'left',function(wheel) v:pan((wheel or 1)*50,0) end)
  arrow('##timeline_right',hright_x1,htrack_y,hright_x2,htrack_y+hbar_h,'right',function(wheel) v:pan(-(wheel or 1)*50,0) end)

  local hz_x1,hz_x2=hright_x2,gx+v.w; local minus_w=button_w; local plus_w=button_w
  arrow('##time_zoom_out',hz_x1,htrack_y,hz_x1+minus_w,htrack_y+hbar_h,'-',function(wheel) app:zoom_time(wheel and (wheel>0 and .88 or 1.14) or 1.2,v.x+v.w*.5) end)
  arrow('##time_zoom_in',hz_x2-plus_w,htrack_y,hz_x2,htrack_y+hbar_h,'+',function(wheel) app:zoom_time(wheel and (wheel>0 and .88 or 1.14) or .82,v.x+v.w*.5) end)
  local hz_track1,hz_track2=hz_x1+minus_w+3,hz_x2-plus_w-3; local hz_range=math.max(1,hz_track2-hz_track1)
  local hz_ratio=U.clamp(math.log((s.visible_qn or 8)/(1/16))/math.log(256/(1/16)),0,1); local hz_thumb=hz_track1+hz_ratio*hz_range
  I.DrawList_AddLine(d,hz_track1,htrack_y+hbar_h*.5,hz_track2,htrack_y+hbar_h*.5,T.scrollbar_thumb,2); I.DrawList_AddCircleFilled(d,hz_thumb,htrack_y+hbar_h*.5,4,T.accent)
  I.SetCursorScreenPos(c,hz_track1,htrack_y); I.InvisibleButton(c,'##time_zoom_bar',hz_range,hbar_h)
  if I.IsItemActive(c) then local ratio=U.clamp((mx-hz_track1)/hz_range,0,1); local wanted=(1/16)*((256/(1/16))^ratio); app:zoom_time(wanted/s.visible_qn,v.x+v.w*.5) end
  if I.IsItemHovered(c) then local wheel=I.GetMouseWheel(c); if wheel~=0 then app:zoom_time(wheel>0 and .88 or 1.14,v.x+v.w*.5) end end

  local vtrack_x=gx+v.w+2; local column=vbar_w; local vtrack_y1,vtrack_y2=gy+column,gy+grid_h-column
  local total=v.fold and #v.fold or 128; local rows=math.min(total,v:rows()); local vtrack_h=vtrack_y2-vtrack_y1; local vthumb_h=math.max(28,vtrack_h*(rows/math.max(1,total))); local vtravel=math.max(0,vtrack_h-vthumb_h)
  local max_low=math.max(0,total-rows); local current=v.fold and (s.fold_offset or 0) or s.low_pitch; local vratio=max_low>0 and U.clamp((max_low-current)/max_low,0,1) or 0; local vthumb_y=vtrack_y1+vratio*vtravel
  I.DrawList_AddRectFilled(d,vtrack_x,vtrack_y1,vtrack_x+vbar_w,vtrack_y2,T.scrollbar_track,4)
  local vhot=U.contains(mx,my,vtrack_x,vthumb_y,vtrack_x+vbar_w,vthumb_y+vthumb_h)
  I.DrawList_AddRectFilled(d,vtrack_x+2,vthumb_y+1,vtrack_x+vbar_w-2,vthumb_y+vthumb_h-1,vhot and T.scrollbar_hover or T.scrollbar_thumb,4)
  I.SetCursorScreenPos(c,vtrack_x,vtrack_y1); I.InvisibleButton(c,'##pitch_scrollbar',vbar_w,vtrack_h)
  if I.IsItemActivated(c) then app.vscroll_grab=vhot and my-vthumb_y or vthumb_h*.5 end
  if I.IsItemActive(c) and I.IsMouseDown(c,I.MouseButton_Left) and vtravel>0 then
    local ratio=U.clamp((my-vtrack_y1-(app.vscroll_grab or vthumb_h*.5))/vtravel,0,1); local value=U.clamp(math.floor(max_low*(1-ratio)+.5),0,max_low); if v.fold then s.fold_offset=value else s.low_pitch=value end
  end
  if I.IsItemHovered(c) then local wheel=I.GetMouseWheel(c); if wheel~=0 then v:scroll_pitch(wheel*3) end end
  arrow('##pitch_up',vtrack_x,gy,vtrack_x+column,gy+column,'up',function(wheel) v:scroll_pitch((wheel or 1)*3) end)
  arrow('##pitch_down',vtrack_x,gy+grid_h-column,vtrack_x+column,gy+grid_h,'down',function(wheel) v:scroll_pitch(-(wheel or 1)*3) end)

  -- Studio One-style compact height-zoom grip. It occupies only the bottom
  -- corner instead of turning the complete right edge into a second slider.
  local bx1,by1,bx2,by2=vtrack_x,htrack_y,vtrack_x+column,htrack_y+hbar_h
  local bhot=U.contains(mx,my,bx1,by1,bx2,by2); local bpressed=bhot and I.IsMouseDown(c,I.MouseButton_Left)
  local box_icon_color=bpressed and (T.selected_edge or T.text) or bhot and T.accent or U.color_scale(T.accent,.72)
  I.DrawList_AddRectFilled(d,bx1+1,by1+1,bx2-1,by2-1,T.scrollbar_track,4)
  I.DrawList_AddRect(d,bx1+4,by1+3,bx2-4,by2-3,box_icon_color,2,I.DrawFlags_None,1.5)
  local grip_x=(bx1+bx2)*.5; for offset=-3,3,3 do I.DrawList_AddLine(d,grip_x-3,by1+hbar_h*.5+offset,grip_x+3,by1+hbar_h*.5+offset,box_icon_color,1) end
  I.SetCursorScreenPos(c,bx1,by1); I.InvisibleButton(c,'##pitch_zoom_grip',column,hbar_h)
  local popup_h,popup_w=104,30; local px2=bx2; local px1=px2-popup_w; local py2=by1-6; local py1=py2-popup_h
  local sx=(px1+px2)*.5; local sy1,sy2=py1+10,py2-10
  if I.IsItemActivated(c) then
    local ratio=U.clamp((s.row_height-8)/24,0,1); local thumb_y=sy2-ratio*(sy2-sy1)
    local js_x,js_y=nil,nil; if reaper.JS_Mouse_GetPosition then js_x,js_y=reaper.JS_Mouse_GetPosition() end
    app.pitch_zoom_drag={sy1=sy1,sy2=sy2,mouse_y=my,thumb_y=thumb_y,row_height=s.row_height,js_x=js_x,js_y=js_y}
  end
  if I.IsItemActive(c) and app.pitch_zoom_drag then
    local drag=app.pitch_zoom_drag; local delta=drag.mouse_y-my
    if drag.js_y and reaper.JS_Mouse_GetPosition and reaper.JS_Mouse_SetPosition then
      local _,js_y=reaper.JS_Mouse_GetPosition(); delta=drag.js_y-js_y
      if math.abs(delta)>.01 then reaper.JS_Mouse_SetPosition(drag.js_x,drag.js_y) end
    end
    if math.abs(delta)>.01 then drag.row_height=U.clamp(drag.row_height+delta*.18,8,32); v:zoom_pitch(drag.row_height/s.row_height,v.y+v.h*.5); drag.mouse_y=my end
    if I.MouseCursor_None then I.SetMouseCursor(c,I.MouseCursor_None) end
    I.DrawList_AddRectFilled(d,px1,py1,px2,py2,T.panel,6)
    I.DrawList_AddRect(d,px1,py1,px2,py2,T.grid,6,I.DrawFlags_None,1)
    local current_ratio=U.clamp((s.row_height-8)/24,0,1); local thumb_y=sy2-current_ratio*(sy2-sy1)
    I.DrawList_AddLine(d,sx,sy1,sx,sy2,T.scrollbar_thumb,3)
    I.DrawList_AddCircleFilled(d,sx,thumb_y,5,T.selected_edge or T.accent)
  end
  if I.IsMouseReleased(c,I.MouseButton_Left) then app.pitch_zoom_drag=nil end
  if I.IsItemHovered(c) then local wheel=I.GetMouseWheel(c); if wheel~=0 then v:zoom_pitch(wheel>0 and 1.12 or .89,v.y+v.h*.5) end; I.SetTooltip(c,'Drag vertically or use the wheel to zoom note height') end
end

local cc_names={[0]='Bank Select MSB',[1]='Mod Wheel',[2]='Breath',[3]='Controller 3',[4]='Foot Controller',[5]='Portamento Time',[6]='Data Entry MSB',[7]='Channel Volume',[8]='Balance',[9]='Controller 9',[10]='Pan',[11]='Expression',[12]='Effect Control 1',[13]='Effect Control 2',[16]='General Purpose 1',[17]='General Purpose 2',[18]='General Purpose 3',[19]='General Purpose 4',[32]='Bank Select LSB',[38]='Data Entry LSB',[64]='Sustain',[65]='Portamento',[66]='Sostenuto',[67]='Soft Pedal',[68]='Legato Footswitch',[69]='Hold 2',[70]='Sound Variation',[71]='Resonance',[72]='Release Time',[73]='Attack Time',[74]='Brightness',[75]='Decay Time',[76]='Vibrato Rate',[77]='Vibrato Depth',[78]='Vibrato Delay',[79]='Sound Controller 10',[80]='General Purpose 5',[81]='General Purpose 6',[82]='General Purpose 7',[83]='General Purpose 8',[84]='Portamento Control',[91]='Reverb Send',[92]='Tremolo Depth',[93]='Chorus Send',[94]='Celeste Depth',[95]='Phaser Depth',[96]='Data Increment',[97]='Data Decrement',[98]='NRPN LSB',[99]='NRPN MSB',[100]='RPN LSB',[101]='RPN MSB',[120]='All Sound Off',[121]='Reset Controllers',[122]='Local Control',[123]='All Notes Off',[124]='Omni Off',[125]='Omni On',[126]='Mono Mode',[127]='Poly Mode'}
local lane_defs={velocity={label='Note-on Velocity',short='VEL'},cc={label='Other MIDI CC...',short='CC'},pitch={label='Pitch Bend',short='PB',pitch=true},pressure={label='Channel Aftertouch (Pressure)',short='AT',status=0xD0},program={label='Program Change',short='PC',status=0xC0,discrete=true}}
local cc_short={[1]='Mod',[7]='Volume',[10]='Pan',[11]='Expr',[64]='Sustain',[74]='Bright',[91]='Reverb',[93]='Chorus'}
local lane_order={'velocity','pitch','pressure','program','cc1','cc2','cc4','cc7','cc10','cc11','cc64','cc65','cc66','cc67','cc71','cc72','cc73','cc74','cc91','cc93','cc'}
local function cc_traits(cc)
  return (cc==8 or cc==10) and 64 or nil,cc>=64 and cc<=69,cc>=96 and cc<=101,cc>=120
end
local function lane_definition(s)
  local def=lane_defs[s.lane_target]
  local named=type(s.lane_target)=='string' and s.lane_target:match('^cc(%d+)$')
  if named then local cc=tonumber(named); local center,switch,discrete,protected=cc_traits(cc); return {label=(cc_names[cc] or 'Controller')..' (CC '..cc..')',short=cc_short[cc] or ('CC '..cc),cc=cc,center=center,switch=switch,discrete=discrete,protected=protected} end
  if def==lane_defs.cc then local cc=U.clamp(math.floor(s.cc_number or 1),0,127); local center,switch,discrete,protected=cc_traits(cc); return {label=(cc_names[cc] or 'Controller')..' (CC '..cc..')',short=cc_short[cc] or ('CC '..cc),cc=cc,center=center,switch=switch,discrete=discrete,protected=protected} end
  return def
end

local function lane_matches_event(lane,event,channel)
  if not event or event.chan~=channel then return false end
  return lane.pitch and event.chanmsg==0xE0
    or lane.status and event.chanmsg==lane.status
    or lane.cc~=nil and event.chanmsg==0xB0 and event.msg2==lane.cc
end

local function adjust_note_property(app,note,wheel)
  local lane=lane_definition(app.settings); local delta=wheel>0 and 1 or -1; local notes=selected_or_one(app,note); local wanted={}
  if lane.protected or lane.discrete then app.transform_notice='Discrete and channel-mode messages are edited only in their lane.'; return false end
  if app.property_wheel and app.property_wheel.key~=lane.label then app:flush_property_wheel(true) end
  if not app.edit.active then app.edit:begin('ReaRoll: adjust '..lane.label,app.take) end
  if app.settings.lane_target=='velocity' then
    for _,n in ipairs(notes) do local vel=U.clamp(n.vel+delta,1,127); app.edit:set(n.index,app.take,nil,nil,nil,vel); wanted[#wanted+1]={s=n.s,e=n.e,pitch=n.pitch,vel=vel} end
  else
    for _,n in ipairs(notes) do
      local found=nil
      for _,e in ipairs(app.cc_cache:get(true)) do local match=lane.pitch and e.chanmsg==0xE0 or lane.status and e.chanmsg==lane.status or (e.chanmsg==0xB0 and e.msg2==lane.cc); if match and e.chan==n.chan and math.abs(e.ppq-n.s)<.5 then found=e; break end end
      local base=lane.pitch and (found and ((found.msg3<<7)|found.msg2) or 8192) or (found and (lane.status and found.msg2 or found.msg3) or lane.center or 0)
      local step=lane.pitch and math.max(1,math.floor(8192/math.max(1,app.settings.pitch_bend_range)/100+.5)) or 1; local value=U.clamp(base+delta*step,0,lane.pitch and 16383 or 127)
      if found then if lane.pitch then app.edit:set_pitch(app.take,found.index,n.s,value) elseif lane.status then app.edit:set_message(app.take,found.index,n.s,value) else app.edit:set_cc(app.take,found.index,n.s,value) end
      elseif lane.pitch then app.edit:insert_pitch(app.take,n.s,n.chan,value) elseif lane.status then app.edit:insert_message(app.take,n.s,n.chan,lane.status,value) else app.edit:insert_cc(app.take,n.s,n.chan,lane.cc,value) end
      wanted[#wanted+1]={s=n.s,e=n.e,pitch=n.pitch,vel=n.vel}
    end
  end
  app.cache:rebuild(); app.cc_cache:rebuild(); app:reselect_notes(wanted); app.property_wheel={key=lane.label,deadline=reaper.time_precise()+.32,wanted=wanted}; return true
end

local function draw_cc_events(app,d,v,vy,lane_h,def)
  local I,T,s=app.ImGui,app.theme,app.settings; local events,prior={}
  local active_item=app.take and reaper.GetMediaItemTake_Item(app.take)
  local graph_color=lane_graph_color(U.track_color(active_item and reaper.GetMediaItemTrack(active_item),T.note),T.lane_bg or T.row)
  local item_s=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_start_qn)
  local item_e=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)
  for _,e in ipairs(app.cc_cache:get(app.gesture~=nil)) do
    local matches=def.pitch and e.chanmsg==0xE0 or def.status and e.chanmsg==def.status or (e.chanmsg==0xB0 and e.msg2==def.cc)
    if matches and e.chan==s.channel and e.ppq>=item_s and e.ppq<=item_e and e.ppq<=v.ppq1 then
      if e.ppq<v.ppq0 then if not prior or e.ppq>prior.ppq then prior=e end else events[#events+1]=e end
    end
  end
  if prior then events[#events+1]=prior end
  local center_y=def.pitch and vy+lane_h*.5 or def.center and (vy+lane_h-(def.center/127)*(lane_h-7)-3) or nil
  if center_y then I.DrawList_AddLine(d,v.x,center_y,v.x+v.w,center_y,T.beat,1) end
  table.sort(events,function(a,b)return a.ppq<b.ppq end); local lastx,lasty
  for _,e in ipairs(events) do
    local value,max_value=def.pitch and ((e.msg3<<7)|e.msg2) or (def.status and e.msg2 or e.msg3),def.pitch and 16383 or 127
    local x=math.max(v.x,v:x_from_ppq(e.ppq)); local y=vy+lane_h-(value/max_value)*(lane_h-7)-3
    if lastx and not def.discrete then
      if def.pitch then
        local fill=lane_graph_fill(graph_color,T.lane_bg or T.row)
        if (lasty-center_y)*(y-center_y)>=0 then I.DrawList_AddQuadFilled(d,lastx,lasty,x,y,x,center_y,lastx,center_y,fill)
        else
          local cross=lastx+(x-lastx)*(center_y-lasty)/(y-lasty)
          I.DrawList_AddTriangleFilled(d,lastx,lasty,cross,center_y,lastx,center_y,fill)
          I.DrawList_AddTriangleFilled(d,cross,center_y,x,y,x,center_y,fill)
        end
        I.DrawList_AddLine(d,lastx,lasty,x,y,graph_color,1.5)
      else
        -- Ordinary MIDI CC/aftertouch values are held until the next event;
        -- a stepped line reflects that sample-and-hold behavior accurately.
        local fill=lane_graph_fill(graph_color,T.lane_bg or T.row)
        I.DrawList_AddRectFilled(d,lastx,math.min(lasty,center_y or vy+lane_h-2),x,math.max(lasty,center_y or vy+lane_h-2),fill)
        I.DrawList_AddLine(d,lastx,lasty,x,lasty,graph_color,1.5)
        I.DrawList_AddLine(d,x,lasty,x,y,graph_color,1.5)
      end
    end
    if def.pitch or def.discrete or not lastx then I.DrawList_AddLine(d,x,center_y or vy+lane_h-2,x,y,graph_color,2) end
    I.DrawList_AddCircleFilled(d,x,y,e.selected and 4 or 3,graph_color)
    if e.selected then I.DrawList_AddCircle(d,x,y,5,T.selected_edge,0,2) end
    lastx,lasty=x,y
  end
  if lastx and not def.discrete then
    local ending=math.min(v.x+v.w,v:x_from_ppq(item_e)); local fill=lane_graph_fill(graph_color,T.lane_bg or T.row)
    if ending>lastx then I.DrawList_AddRectFilled(d,lastx,math.min(lasty,center_y or vy+lane_h-2),ending,math.max(lasty,center_y or vy+lane_h-2),fill); I.DrawList_AddLine(d,lastx,lasty,ending,lasty,graph_color,1.5) end
  end
end

local draw_lane_beat_shading
local function draw_lane_preview(app,d,v,notes,top,height,target)
  local I,T,s=app.ImGui,app.theme,app.settings; local def=lane_definition({lane_target=target,cc_number=s.cc_number})
  I.DrawList_AddRectFilled(d,v.x,top,v.x+v.w,top+height,T.panel)
  draw_lane_beat_shading(app,d,v,top,height)
  I.DrawList_PushClipRect(d,v.x,top,v.x+v.w,top+height,true)
  if def.cc or def.pitch or def.status then draw_cc_events(app,d,v,top,height,def) else
    for _,n in ipairs(notes) do local x=v:x_from_ppq(n.s); if x>=v.x and x<=v.x+v.w then
      local y=top+height-(n.vel/127)*(height-6)-2; local col=Selection.has(app.selection,n.id) and T.selected or T.velocity
      I.DrawList_AddLine(d,x,top+height-1,x,y,col,1.5); I.DrawList_AddCircleFilled(d,x,y,2.5,col)
    end end
  end
  I.DrawList_PopClipRect(d); return def
end

local function controller_value_label(settings,lane,value)
  if lane.pitch then
    local delta=value-8192
    local semitones=delta/(delta>=0 and 8191 or 8192)*math.max(1,settings.pitch_bend_range or 2)
    if math.abs(semitones)<.005 then semitones=0 end
    return string.format('%+.2f st',semitones)
  end
  if lane.switch then return value>=64 and 'On' or 'Off' end
  if lane.center then if value==lane.center then return 'Center' elseif value<lane.center then return 'L '..tostring(lane.center-value) else return 'R '..tostring(value-lane.center) end end
  if lane.status==0xC0 then return 'Program '..tostring(value+1) end
  return string.format('%s  %d',lane.short or 'Value',value)
end

local function draw_controller_gesture_value(app,d,lane,g,mx,my,gx,vy,lane_h,vw)
  if not g or (g.kind~='cc' and g.kind~='cc_move') then return end
  local max_value=lane.pitch and 16383 or 127
  local value=U.clamp(math.floor((g.bottom-my)/g.height*max_value+.5),0,max_value)
  if g.kind=='cc_move' then value=U.clamp(g.anchor_value+(value-g.anchor_value),0,max_value) end
  if lane.switch then value=value>=64 and 127 or 0 end
  local text=controller_value_label(app.settings,lane,value)
  local tw,th=app.ImGui.CalcTextSize(app.ctx,text); local pad=5
  local bx=U.clamp(mx+13,gx+4,gx+vw-tw-pad*2-4)
  local by=U.clamp(my-th-15,vy+4,vy+lane_h-th-pad*2-4)
  app.ImGui.DrawList_AddRectFilled(d,bx,by,bx+tw+pad*2,by+th+pad*2,app.theme.panel2,5)
  app.ImGui.DrawList_AddRect(d,bx,by,bx+tw+pad*2,by+th+pad*2,app.theme.accent,5,app.ImGui.DrawFlags_None,1)
  app.ImGui.DrawList_AddText(d,bx+pad,by+pad,app.theme.text,text)
end

local function draw_lane_title(app,d,x,y,text,right)
  local I,c,T=app.ImGui,app.ctx,app.theme; local tw,th=I.CalcTextSize(c,text); th=th or 14
  if x+tw+10>right then return end
  I.DrawList_AddRectFilled(d,x-4,y-2,x+tw+5,y+th+2,(T.panel&0xFFFFFF00)|0xD8,3)
  I.DrawList_AddText(d,x,y,T.hint,text)
end

local function draw_lane_title_right(app,d,y,text,left,right)
  local tw=app.ImGui.CalcTextSize(app.ctx,text)
  local x=right-tw-7
  if x<left then return end
  draw_lane_title(app,d,x,y,text,right)
end

draw_lane_beat_shading=function(app,d,v,top,height)
  local finish=app.settings.start_qn+app.settings.visible_qn; local _,bar_qn,bar_end=reaper.TimeMap_QNToMeasures(0,app.settings.start_qn); local guard=0
  while bar_qn<=finish and guard<512 do
    local _,denom=reaper.TimeMap_GetTimeSigAtTime(0,reaper.TimeMap2_QNToTime(0,bar_qn)); local beat=4/(denom or 4); local index=0
    for q=bar_qn,bar_end-beat*.25,beat do if index%2==1 then local left,right=math.max(v.x,v:x_from_qn(q)),math.min(v.x+v.w,v:x_from_qn(math.min(bar_end,q+beat))); if right>left then app.ImGui.DrawList_AddRectFilled(d,left,top,right,top+height,app.theme.lane_beat_shade or app.theme.beat_shade) end end; index=index+1 end
    local _,next_start,next_end=reaper.TimeMap_QNToMeasures(0,bar_end+.000001); if next_start<=bar_qn then break end; bar_qn,bar_end=next_start,next_end; guard=guard+1
  end
end

local function draw_lane_meter_lines(app,d,v,top,height)
  local finish=app.settings.start_qn+app.settings.visible_qn
  local _,bar_qn,bar_end=reaper.TimeMap_QNToMeasures(0,app.settings.start_qn); local guard=0
  while bar_qn<=finish and guard<512 do
    local bar_x=crisp_x(v:x_from_qn(bar_qn))
    if bar_x>=v.x and bar_x<=v.x+v.w then app.ImGui.DrawList_AddLine(d,bar_x,top,bar_x,top+height,app.theme.bar,1.5) end
    local _,denom=reaper.TimeMap_GetTimeSigAtTime(0,reaper.TimeMap2_QNToTime(0,bar_qn)); local beat=4/(denom or 4)
    for q=bar_qn+beat,bar_end-beat*.25,beat do
      local x=crisp_x(v:x_from_qn(q))
      if x>=v.x and x<=v.x+v.w then app.ImGui.DrawList_AddLine(d,x,top,x,top+height,app.theme.beat) end
    end
    local _,next_start,next_end=reaper.TimeMap_QNToMeasures(0,bar_end+.000001)
    if next_start<=bar_qn then break end
    bar_qn,bar_end=next_start,next_end; guard=guard+1
  end
end

local function velocity_handle(v,n,top,height)
  return v:x_from_ppq(n.s),top+height-(n.vel/127)*(height-8)-3
end

local function velocity_cap(v,n,notes,channel)
  local x=v:x_from_ppq(n.s); local next_x=math.huge
  for _,other in ipairs(notes) do
    if other~=n and (other.chan or 0)==channel and other.s>n.s then next_x=math.min(next_x,v:x_from_ppq(other.s)) end
  end
  -- Keep the cap useful in sparse passages, but stop before the next onset so
  -- it cannot masquerade as note duration or cover the following handle.
  local length=next_x<math.huge and U.clamp(next_x-x-4,8,38) or 28
  return x,x+length
end

local function pick_velocity_handle(app,v,notes,mx,my,top,height)
  local closest,best_score,best_distance
  for _,n in ipairs(notes) do
    if (n.chan or 0)==(app.settings.channel or 0) then
    local x,y=velocity_handle(v,n,top,height); local _,cap_right=velocity_cap(v,n,notes,app.settings.channel or 0)
    local nearest_x=U.clamp(mx,x,cap_right); local dx,dy=nearest_x-mx,y-my; local distance=dx*dx+dy*dy
    -- If handles are geometrically identical, the selected note is the user's
    -- strongest available indication of intent.
    local score=distance-(Selection.has(app.selection,n.id) and 9 or 0)
    if not best_score or score<best_score then closest,best_score,best_distance=n,score,distance end
    end
  end
  return closest,best_distance or math.huge
end

local function begin_gesture(app,take,v,notes,hit,edge,mx,my,mods)
  local s=app.settings
  -- Selection modifiers take priority over every drawing tool.
  if hit and mods.ctrl then
    if mods.shift then Selection.add(app.selection,hit.id) else Selection.toggle(app.selection,hit.id) end
    return
  elseif hit and mods.shift then
    app.gesture={kind='copy_pending',hit=hit,mx=mx,my=my,anchor_qn=v:qn_from_x(mx),anchor_pitch=v:pitch_from_y(my),click_add=true}
    return
  end
  if not hit and (mods.shift or mods.ctrl or s.mode=='select') then
    app.gesture={kind='marquee',x1=mx,y1=my,x2=mx,y2=my,qn1=v:qn_from_x(mx),qn2=v:qn_from_x(mx),pitch1=v:pitch_from_y(my),pitch2=v:pitch_from_y(my),add=mods.ctrl or mods.shift}
    if not app.gesture.add then Selection.clear(app.selection) end
    return
  end
  if s.mode=='glue' then
    app.gesture={kind='glue',seams={},last_x=mx,last_y=my}; collect_glue_seams(v,notes,app.gesture,mx,my,s.row_height,s.channel or 0); return
  elseif s.mode=='slice' and not (hit and edge) then
    app.gesture={kind='slice',x1=mx,y1=my,x2=mx,y2=my,slices={},last_x=mx,last_y=my,unsnapped=mods.alt}; collect_slice_marks(app,v,notes,app.gesture,mx,my,mods); return
  elseif s.mode=='mute' and not (hit and edge) then
    if hit then
      local target=not hit.muted; app.edit:begin(target and 'ReaRoll: mute notes' or 'ReaRoll: unmute notes',take); app.edit:set_muted(take,hit.index,target); hit.muted=target
      app.gesture={kind='mute',target=target,visited={[hit.id]=true}}
    end
    return
  elseif hit then
    if mods.shift then Selection.add(app.selection,hit.id) else selected_or_one(app,hit) end
    if not mods.ctrl then
      local chosen=selected_or_one(app,hit); app.edit:begin(edge and 'ReaRoll: resize notes' or 'ReaRoll: move notes',take)
      app.gesture={kind=edge and 'resize' or 'move',edge=edge,mx=mx,my=my,anchor_qn=v:qn_from_x(mx),anchor_pitch=v:pitch_from_y(my),items=snapshot(chosen),last_dx=nil,last_dp=nil,audition_pitch=hit.pitch,audition_velocity=hit.vel,audition_channel=hit.chan,last_audition_pitch=hit.pitch}
      if s.inherit_length and not s.length_follow_grid then s.length_qn=(hit.e-hit.s)/v.ppq_per_qn; s.velocity=hit.vel end
      app.audition:play(hit.pitch,hit.vel,hit.chan)
    end
  elseif s.mode=='chord' then
    local length=Grid.note_length(s); local raw_q=v:qn_from_x(mx); local q=U.snap_time(s,raw_q); q=math.max(app.item_start_qn,q); local root=v:pitch_from_y(my)
    if q>=app.item_end_qn then return end
    if s.scale_enabled and s.scale_snap then root=app.music.snap(s.scale_root,s.scale_name,root) end
    local start=reaper.MIDI_GetPPQPosFromProjQN(take,q); local ending=reaper.MIDI_GetPPQPosFromProjQN(take,math.min(app.item_end_qn,q+length)); local pitches=chord_pitches(app,root)
    local preview={}; Selection.clear(app.selection)
    if s.chord_drag_length then
      local _,base=reaper.MIDI_CountEvts(take); local items={}; app.edit:begin('ReaRoll: draw '..s.chord_name..' chord',take)
      for i,pitch in ipairs(pitches) do
        preview[#preview+1]=pitch
        if app.edit:insert(take,start,ending,pitch,s.velocity,s.channel,true) then
          local index=base+i-1; local n={id='chord:'..tostring(index),index=index,s=start,e=ending,pitch=pitch,vel=s.velocity,chan=s.channel,muted=false}
          app.cache.notes[#app.cache.notes+1]=n; items[#items+1]={note=n,index=index,s=start,e=ending,pitch=pitch,vel=s.velocity}; Selection.add(app.selection,n.id)
        end
      end
      app.gesture={kind='chord_draw',mx=mx,start=start,last_e=ending,items=items}
    else
      app.edit:begin('ReaRoll: stamp '..s.chord_name..' chord',take)
      for _,pitch in ipairs(pitches) do preview[#preview+1]=pitch; app.edit:insert(take,start,ending,pitch,s.velocity,s.channel,true) end
      app.edit:finish(); app.cache:rebuild()
      for _,n in ipairs(app.cache.notes) do if math.abs(n.s-start)<.5 and n.chan==s.channel then for _,pitch in ipairs(pitches) do if n.pitch==pitch then Selection.add(app.selection,n.id) end end end end
    end
    app.audition:play_many(preview,s.velocity,s.channel); app.chord_preview=true
  elseif s.mode=='paint' then
    local occupied={}
    for _,n in ipairs(app.cache:get(true)) do local nq=U.snap(reaper.MIDI_GetProjQNFromPPQPos(take,n.s),s.grid_qn); occupied[string.format('%.6f:%d:%d',nq,n.pitch,n.chan or 0)]=true end
    app.edit:begin('ReaRoll: paint notes',take); app.gesture={kind='paint',last_q=nil,last_pitch=nil,visited={},occupied=occupied}; Selection.clear(app.selection)
  elseif mods.shift then
    app.gesture={kind='marquee',x1=mx,y1=my,x2=mx,y2=my,qn1=v:qn_from_x(mx),qn2=v:qn_from_x(mx),pitch1=v:pitch_from_y(my),pitch2=v:pitch_from_y(my),add=mods.ctrl}; if not mods.ctrl then Selection.clear(app.selection) end
  else
    local length=Grid.note_length(s); local raw_q=v:qn_from_x(mx); local q=U.snap_time(s,raw_q); q=math.max(app.item_start_qn,q); local p=v:pitch_from_y(my); if s.scale_enabled and s.scale_snap then p=app.music.snap(s.scale_root,s.scale_name,p) end
    if q>=app.item_end_qn then return end
    local _,index=reaper.MIDI_CountEvts(take); app.edit:begin('ReaRoll: draw note',take); local start=reaper.MIDI_GetPPQPosFromProjQN(take,q); local ending=reaper.MIDI_GetPPQPosFromProjQN(take,math.min(app.item_end_qn,q+length)); app.edit:insert(take,start,ending,p,s.velocity,s.channel,true)
    local n={id='new:'..tostring(index),index=index,s=start,e=ending,pitch=p,vel=s.velocity,chan=s.channel,muted=false}
    app.cache.notes[#app.cache.notes+1]=n; Selection.set_only(app.selection,n.id)
    app.gesture={kind='draw',mx=mx,note=n,index=index,start=start,last_e=ending,pitch=p,items={{note=n,index=index,s=start,e=ending,pitch=p,vel=s.velocity}}}; app.audition:play(p,s.velocity,s.channel)
  end
end

local function begin_stretch(app,take,v,mx)
  local chosen=Selection.list(app.selection,app.cache:get(true)); if #chosen<2 then return end
  local min_s,max_e=math.huge,-math.huge; for _,n in ipairs(chosen) do min_s=math.min(min_s,n.s); max_e=math.max(max_e,n.e) end
  app.edit:begin('ReaRoll: stretch note selection',take)
  app.gesture={kind='stretch',items=snapshot(chosen),min_s=min_s,max_e=max_e,anchor_qn=v:qn_from_x(mx),last_factor=nil}
end

local function apply_velocity_swipe(app,take,v,g,mx,my,straight)
  local function value_at(y)return U.clamp(math.floor((g.bottom-y)/g.height*127+.5),1,127) end
  local function write(a,value)
    if g.values[a.index]~=value then app.edit:set(a.index,take,nil,nil,nil,value); a.note.vel=value; g.values[a.index]=value end
  end
  if straight then
    local left,right=math.min(g.anchor_x,mx),math.max(g.anchor_x,mx); local span=mx-g.anchor_x; local touched={}
    for _,a in ipairs(g.items) do
      local nx=v:x_from_ppq(a.s)
      if nx>=left and nx<=right then
        local ratio=math.abs(span)<.001 and 0 or (nx-g.anchor_x)/span
        write(a,value_at(g.anchor_y+(my-g.anchor_y)*ratio)); touched[a.index]=true
      elseif g.shift_touched and g.shift_touched[a.index] then write(a,a.vel) end
    end
    g.shift_touched=touched; g.shift_active=true
  else
    if g.shift_active then
      -- Leaving line mode starts a fresh freehand segment at the current point.
      g.shift_active=false; g.shift_touched=nil; g.last_x,g.last_y=mx,my
    end
    local x0,y0=g.last_x or mx,g.last_y or my; local left,right=math.min(x0,mx),math.max(x0,mx)
    if math.abs(mx-x0)<.001 then
      local nearest=math.huge
      for _,a in ipairs(g.items) do nearest=math.min(nearest,math.abs(v:x_from_ppq(a.s)-mx)) end
      if nearest<=12 then left,right=mx-nearest-.01,mx+nearest+.01 else left,right=1,0 end
    end
    local span=mx-x0
    for _,a in ipairs(g.items) do local nx=v:x_from_ppq(a.s); if nx>=left and nx<=right then
      local ratio=math.abs(span)<.001 and 1 or (nx-x0)/span
      write(a,value_at(y0+(my-y0)*ratio))
    end end
  end
  g.last_x,g.last_y=mx,my; app.settings.velocity=value_at(my)
end

local function update_gesture(app,take,v,mx,my,mods)
  local g,s=app.gesture,app.settings; if not g then return end
  if g.kind=='copy_pending' then
    if math.abs(mx-g.mx)<4 and math.abs(my-g.my)<4 then return end
    local chosen=Selection.has(app.selection,g.hit.id) and Selection.list(app.selection,app.cache:get(true)) or {g.hit}
    app.edit:begin('ReaRoll: duplicate notes',take); local _,base=reaper.MIDI_CountEvts(take); local copies={}; Selection.clear(app.selection)
    for i,n in ipairs(chosen) do
      app.edit:insert(take,n.s,n.e,n.pitch,n.vel,n.chan,true,n.muted)
      local copy={id='new:'..tostring(base+i-1),index=base+i-1,s=n.s,e=n.e,pitch=n.pitch,vel=n.vel,chan=n.chan,muted=n.muted}
      app.cache.notes[#app.cache.notes+1]=copy; copies[#copies+1]=copy; Selection.add(app.selection,copy.id)
    end
    app.gesture={kind='move',mx=g.mx,my=g.my,anchor_qn=g.anchor_qn,anchor_pitch=g.anchor_pitch,items=snapshot(copies),last_dx=nil,last_dp=nil,audition_pitch=g.hit.pitch,audition_velocity=g.hit.vel,audition_channel=g.hit.chan,last_audition_pitch=g.hit.pitch}; g=app.gesture
  end
  if g.kind=='move' then
    local raw=v:qn_from_x(mx)-g.anchor_qn; local mode=(mods.alt and 'off' or U.snap_mode(s)); local dx_qn=raw
    if mode=='relative' then dx_qn=U.snap(raw,s.grid_qn) elseif mode=='absolute' then local first_qn=reaper.MIDI_GetProjQNFromPPQPos(take,g.items[1].s); dx_qn=U.snap(first_qn+raw,s.grid_qn)-first_qn end
    local dx=dx_qn*v.ppq_per_qn; local dp=v:pitch_from_y(my)-g.anchor_pitch
    if s.scale_enabled and s.scale_snap and #g.items==1 then local target=app.music.snap(s.scale_root,s.scale_name,g.items[1].pitch+dp,dp); dp=target-g.items[1].pitch end
    local item_s=reaper.MIDI_GetPPQPosFromProjQN(take,app.item_start_qn); local min_s,max_e=math.huge,-math.huge
    for _,a in ipairs(g.items) do min_s=math.min(min_s,a.s); max_e=math.max(max_e,a.e) end
    local item_e=reaper.MIDI_GetPPQPosFromProjQN(take,app.item_end_qn)
    dx=U.clamp(dx,item_s-min_s,item_e-max_e)
    if dx~=g.last_dx or dp~=g.last_dp then
      for _,a in ipairs(g.items) do app.edit:set(a.index,take,a.s+dx,a.e+dx,U.clamp(a.pitch+dp,0,127),nil); a.note.s,a.note.e,a.note.pitch=a.s+dx,a.e+dx,U.clamp(a.pitch+dp,0,127) end
      local audition_pitch=g.audition_pitch and U.clamp(g.audition_pitch+dp,0,127)
      if audition_pitch and audition_pitch~=g.last_audition_pitch then app.audition:play(audition_pitch,g.audition_velocity,g.audition_channel); g.last_audition_pitch=audition_pitch end
      g.last_dx,g.last_dp=dx,dp
    end
  elseif g.kind=='resize' then
    local raw=v:qn_from_x(mx)-g.anchor_qn; local mode=(mods.alt and 'off' or U.snap_mode(s)); local dx=raw*v.ppq_per_qn
    local item_s=reaper.MIDI_GetPPQPosFromProjQN(take,app.item_start_qn)
    if dx~=g.last_dx then for _,a in ipairs(g.items) do
      local minimum=(mode~='off' and s.grid_qn*v.ppq_per_qn or 1)
      if g.edge=='left' then local original=reaper.MIDI_GetProjQNFromPPQPos(take,a.s); local target=mode=='off' and original+raw or mode=='relative' and original+U.snap(raw,s.grid_qn) or U.snap(original+raw,s.grid_qn); local start=math.max(item_s,math.min(a.e-minimum,reaper.MIDI_GetPPQPosFromProjQN(take,target))); app.edit:set(a.index,take,start,nil,nil,nil); a.note.s=start
      else local original=reaper.MIDI_GetProjQNFromPPQPos(take,a.e); local target=mode=='off' and original+raw or mode=='relative' and original+U.snap(raw,s.grid_qn) or U.snap(original+raw,s.grid_qn); local ending=math.min(reaper.MIDI_GetPPQPosFromProjQN(take,app.item_end_qn),math.max(a.s+minimum,reaper.MIDI_GetPPQPosFromProjQN(take,target))); app.edit:set(a.index,take,nil,ending,nil,nil); a.note.e=ending end
    end; g.last_dx=dx end
  elseif g.kind=='stretch' then
    local target_qn=v:qn_from_x(mx); if not mods.alt then target_qn=U.snap_time(s,target_qn,reaper.MIDI_GetProjQNFromPPQPos(take,g.max_e)) end
    local target=U.clamp(reaper.MIDI_GetPPQPosFromProjQN(take,target_qn),g.min_s+1,reaper.MIDI_GetPPQPosFromProjQN(take,app.item_end_qn)); local span=math.max(1,g.max_e-g.min_s); local factor=(target-g.min_s)/span
    if factor~=g.last_factor then
      for _,a in ipairs(g.items) do local ns=g.min_s+(a.s-g.min_s)*factor; local ne=g.min_s+(a.e-g.min_s)*factor; app.edit:set(a.index,take,ns,ne,nil,nil); a.note.s,a.note.e=ns,ne end
      g.last_factor=factor
    end
  elseif g.kind=='draw' or g.kind=='chord_draw' then
    if not g.dragged and math.abs(mx-g.mx)<4 then return end
    g.dragged=true
    local raw_q=v:qn_from_x(mx); local start_qn=reaper.MIDI_GetProjQNFromPPQPos(take,g.start); local q=mods.alt and raw_q or U.snap_time(s,raw_q,start_qn); local minimum=(U.snap_mode(s)~='off' and s.grid_qn or 1/v.ppq_per_qn); q=U.clamp(q,minimum+start_qn,app.item_end_qn); local e=reaper.MIDI_GetPPQPosFromProjQN(take,q)
    if e~=g.last_e then
      if g.kind=='chord_draw' then for _,a in ipairs(g.items) do app.edit:set(a.index,take,nil,e,nil,nil); a.note.e=e end
      else app.edit:set(g.index,take,nil,e,nil,nil); g.note.e=e end
      g.last_e=e
    end
  elseif g.kind=='paint' then
    local length=Grid.note_length(s)
    local q=U.snap(v:qn_from_x(mx),s.grid_qn); local p=v:pitch_from_y(my); if s.scale_enabled and s.scale_snap then p=app.music.snap(s.scale_root,s.scale_name,p) end
    local q_steps=g.last_q and math.abs(math.floor((q-g.last_q)/s.grid_qn+.5)) or 0; local p_steps=g.last_pitch and math.abs(p-g.last_pitch) or 0; local steps=math.max(1,q_steps,p_steps)
    local painted=false
    for i=1,steps do
      local ratio=i/steps; local cell_q=g.last_q and U.snap(g.last_q+(q-g.last_q)*ratio,s.grid_qn) or q; local cell_p=g.last_pitch and math.floor(g.last_pitch+(p-g.last_pitch)*ratio+.5) or p
      if s.scale_enabled and s.scale_snap then cell_p=app.music.snap(s.scale_root,s.scale_name,cell_p,p-(g.last_pitch or p)) end
      local cell=string.format('%.6f:%d:%d',cell_q,cell_p,s.channel or 0)
      if not g.visited[cell] and cell_q>=app.item_start_qn and cell_q<app.item_end_qn then
        local sp=reaper.MIDI_GetPPQPosFromProjQN(take,cell_q); local ep=reaper.MIDI_GetPPQPosFromProjQN(take,math.min(app.item_end_qn,cell_q+length))
        if not g.occupied[cell] then
          local _,index=reaper.MIDI_CountEvts(take)
          if app.edit:insert(take,sp,ep,cell_p,s.velocity,s.channel,true) then app.cache.notes[#app.cache.notes+1]={id='paint:'..tostring(index),index=index,s=sp,e=ep,pitch=cell_p,vel=s.velocity,chan=s.channel,muted=false}; painted=true end
          g.occupied[cell]=true
        end
        g.visited[cell]=true
      end
    end
    g.last_q,g.last_pitch=q,p; if painted then app.audition:play(p,s.velocity,s.channel) end
  elseif g.kind=='marquee' then g.x2,g.y2=mx,my; update_marquee_world(g,v,mx,my)
  elseif g.kind=='cc_marquee' then
    local q=v:qn_from_x(mx); if s.snap_enabled then q=U.snap(q,s.grid_qn) end
    q=U.clamp(q,app.item_start_qn,app.item_end_qn); g.x2,g.y2=v:x_from_qn(q),my
    if math.abs(mx-(g.press_x or g.x1))>=3 then g.dragged=true end
  elseif g.kind=='slice' then g.x2,g.y2=mx,my; g.unsnapped=mods.alt; collect_slice_marks(app,v,app.cache:get(true),g,mx,my,mods)
  elseif g.kind=='glue' then collect_glue_seams(v,app.cache:get(true),g,mx,my,s.row_height,s.channel or 0)
  elseif g.kind=='velocity' then
    local target=U.clamp(math.floor((g.bottom-my)/g.height*127+.5),1,127); local delta=target-g.anchor
    if delta~=g.last_delta then
      for _,a in ipairs(g.items) do local vel=U.clamp(a.vel+delta,1,127); app.edit:set(a.index,take,nil,nil,nil,vel); a.note.vel=vel end
      g.last_delta=delta; s.velocity=target
    end
  elseif g.kind=='velocity_swipe' then
    apply_velocity_swipe(app,take,v,g,mx,my,mods.shift)
  elseif g.kind=='cc' then
    local qraw=v:qn_from_x(mx); local q=s.snap_enabled and U.snap(qraw,s.grid_qn) or qraw; q=U.clamp(q,app.item_start_qn,app.item_end_qn); local max_value=g.pitch and 16383 or 127; local value=U.clamp(math.floor((g.bottom-my)/g.height*max_value+.5),0,max_value)
    if g.switch then value=value>=64 and 127 or 0 end
    local steps=(g.discrete or g.switch) and 1 or (g.last_q and math.max(1,math.floor(math.abs(q-g.last_q)/s.grid_qn+.5)) or 1)
    for i=1,steps do
      local ratio=i/steps; local cq=(not g.discrete and not g.switch and g.last_q) and (g.last_q+(q-g.last_q)*ratio) or q; if s.snap_enabled then cq=U.snap(cq,s.grid_qn) end
      local cv=(not g.discrete and not g.switch and g.last_value) and math.floor(g.last_value+(value-g.last_value)*ratio+.5) or value; if g.switch then cv=cv>=64 and 127 or 0 end
      local key=string.format('%.6f',cq); local event=g.events[key]; local ppq=reaper.MIDI_GetPPQPosFromProjQN(take,cq)
      local old_value=event and (g.pitch and ((event.msg3<<7)|event.msg2) or (g.status and event.msg2 or event.msg3)) or nil
      if event then
        if old_value~=cv then if g.pitch then app.edit:set_pitch(take,event.index,ppq,cv); event.msg2,event.msg3=cv&0x7F,(cv>>7)&0x7F elseif g.status then app.edit:set_message(take,event.index,ppq,cv); event.msg2=cv else app.edit:set_cc(take,event.index,ppq,cv); event.msg3=cv end; event.ppq=ppq end
      else
        local _,_,index=reaper.MIDI_CountEvts(take)
        local ok=g.pitch and app.edit:insert_pitch(take,ppq,s.channel,cv) or (g.status and app.edit:insert_message(take,ppq,s.channel,g.status,cv) or app.edit:insert_cc(take,ppq,s.channel,g.cc,cv))
        if ok then event={index=index,ppq=ppq,chanmsg=g.pitch and 0xE0 or (g.status or 0xB0),chan=s.channel,msg2=g.pitch and (cv&0x7F) or (g.status and cv or g.cc),msg3=g.pitch and ((cv>>7)&0x7F) or (g.status and 0 or cv)}; app.cc_cache.events[#app.cc_cache.events+1]=event; g.events[key]=event end
      end
    end
    g.last_q,g.last_value=q,value
  elseif g.kind=='cc_move' then
    local q=v:qn_from_x(mx); local dq=q-g.anchor_qn; local mode=(mods.alt and 'off' or U.snap_mode(s)); if mode=='relative' then dq=U.snap(dq,s.grid_qn) elseif mode=='absolute' then local first=reaper.MIDI_GetProjQNFromPPQPos(take,g.items[1].ppq); dq=U.snap(first+dq,s.grid_qn)-first end
    local min_q,max_q=math.huge,-math.huge
    for _,a in ipairs(g.items) do local aq=reaper.MIDI_GetProjQNFromPPQPos(take,a.ppq); min_q=math.min(min_q,aq); max_q=math.max(max_q,aq) end
    dq=U.clamp(dq,app.item_start_qn-min_q,app.item_end_qn-max_q)
    local max_value=g.pitch and 16383 or 127; local current=U.clamp(math.floor((g.bottom-my)/g.height*max_value+.5),0,max_value); if g.switch then current=current>=64 and 127 or 0 end; local dv=current-g.anchor_value
    if dq~=g.last_dq or dv~=g.last_dv then for _,a in ipairs(g.items) do local ppq=reaper.MIDI_GetPPQPosFromProjQN(take,reaper.MIDI_GetProjQNFromPPQPos(take,a.ppq)+dq); local value=U.clamp(a.value+dv,0,max_value); if g.switch then value=value>=64 and 127 or 0 end
      if g.pitch then app.edit:set_pitch(take,a.index,ppq,value) elseif g.status then app.edit:set_message(take,a.index,ppq,value) else app.edit:set_cc(take,a.index,ppq,value) end
    end; g.last_dq,g.last_dv=dq,dv end
  end
end

local function auto_scroll(app,v,mx,my)
  local g=app.gesture
  -- Controller-lane gestures use the shared timeline viewport, but their Y
  -- coordinates live below the note grid.  Feeding them to note auto-scroll
  -- therefore looks like a permanent drag below the grid and scrolls pitches.
  if not g or g.kind=='pan' or g.kind=='velocity' or g.kind=='velocity_swipe' or g.kind=='cc' or g.kind=='cc_move' or g.kind=='cc_marquee' or g.kind=='slice' then return false end
  local now=reaper.time_precise(); g.scroll_time=g.scroll_time or now; local dt=math.min(.05,now-g.scroll_time); g.scroll_time=now
  local edge=30; local dx,dp=0,0
  if mx<v.x+edge then dx=-U.clamp((v.x+edge-mx)/edge,0,1) elseif mx>v.x+v.w-edge then dx=U.clamp((mx-(v.x+v.w-edge))/edge,0,1) end
  if my<v.y+edge then dp=U.clamp((v.y+edge-my)/edge,0,1) elseif my>v.y+v.h-edge then dp=-U.clamp((my-(v.y+v.h-edge))/edge,0,1) end
  if dx~=0 then
    local min_start=v.min_qn or app.item_start_qn; local max_start=v.max_start or math.max(min_start,(app.item_end_qn or min_start+app.settings.visible_qn)-app.settings.visible_qn)
    app.settings.start_qn=U.clamp(app.settings.start_qn+dx*app.settings.visible_qn*dt*1.4,min_start,max_start)
  end
  if dp~=0 then v:scroll_pitch(dp*(v.fold and 18 or 35)*dt) end
  return dx~=0 or dp~=0
end

local function prevent_note_overlaps(app,g)
  if not app.settings.prevent_overlaps or not g or not g.items then return end
  local touched={}; for _,a in ipairs(g.items) do
    local index=a.index or (a.note and a.note.index)
    if index~=nil then touched[index]=true end
  end
  local groups={}
  for _,n in ipairs(app.cache:get(true)) do
    local key=tostring(n.chan or 0)..':'..tostring(n.pitch); groups[key]=groups[key] or {}; groups[key][#groups[key]+1]=n
  end
  local deletes,delete_seen={},{}
  for _,group in pairs(groups) do
    table.sort(group,function(a,b) if a.s==b.s then return a.e<b.e end; return a.s<b.s end)
    for i=1,#group-1 do local earlier,later=group[i],group[i+1]
      if earlier.e>later.s and (touched[earlier.index] or touched[later.index]) then
        if later.s>earlier.s+1 then
          app.edit:set(earlier.index,app.take,nil,later.s,nil,nil); earlier.e=later.s
        else
          -- Two same-pitch notes cannot share a start safely in REAPER's raw
          -- MIDI stream. Prefer the note participating in this gesture.
          local remove=(touched[later.index] and not touched[earlier.index]) and earlier or later
          if remove.index~=nil and not delete_seen[remove.index] then deletes[#deletes+1]=remove.index; delete_seen[remove.index]=true; remove.e=remove.s end
        end
      end
    end
  end
  -- MIDI note indices are positional. Defer every deletion until all SetNote
  -- calls have used the original indices, then delete high-to-low in one pass.
  if #deletes>0 then app.edit:delete_indices(app.take,deletes) end
end

local function finish_gesture(app,notes)
  local g=app.gesture; if not g then return end
  if g.kind=='copy_pending' then if g.click_add then Selection.add(app.selection,g.hit.id) else Selection.toggle(app.selection,g.hit.id) end; app.gesture=nil; return
  elseif g.kind=='cc_move' then app.edit:finish(); app.cc_cache:rebuild(); app.gesture=nil; return
  elseif g.kind=='cc_marquee' then
    if not g.dragged then
      app.lane_time_selection=nil
      if not g.range_only then for _,e in ipairs(app.cc_cache:get(true)) do if (e.chan or 0)==g.channel then reaper.MIDI_SetCC(app.take,e.index,false,nil,nil,nil,nil,nil,nil,true) end end end
      reaper.MIDI_Sort(app.take); app.cc_cache:invalidate(); app.cc_cache:rebuild(); app.controller_selection_active=false; app.gesture=nil; return
    end
    local q1,q2=app.viewport:qn_from_x(g.x1),app.viewport:qn_from_x(g.x2); if app.settings.snap_enabled then q1,q2=U.snap(q1,app.settings.grid_qn),U.snap(q2,app.settings.grid_qn) end; q1,q2=U.clamp(math.min(q1,q2),app.item_start_qn,app.item_end_qn),U.clamp(math.max(q1,q2),app.item_start_qn,app.item_end_qn); if q2<=q1 then q2=math.min(app.item_end_qn,q1+app.settings.grid_qn) end
    app.lane_time_selection={start_qn=q1,end_qn=q2}
    if not g.range_only then
      if not g.add then for _,e in ipairs(app.cc_cache:get(true)) do if (e.chan or 0)==g.channel then reaper.MIDI_SetCC(app.take,e.index,false,nil,nil,nil,nil,nil,nil,true) end end end
      for _,e in ipairs(app.cc_cache:get(true)) do local matches=(g.pitch and e.chanmsg==0xE0) or (g.status and e.chanmsg==g.status) or (g.cc~=nil and e.chanmsg==0xB0 and e.msg2==g.cc); if matches and (e.chan or 0)==g.channel then local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,e.ppq); if q>=q1 and q<=q2 then reaper.MIDI_SetCC(app.take,e.index,true,nil,nil,nil,nil,nil,nil,true) end end end
    end
    reaper.MIDI_Sort(app.take); app.cc_cache:invalidate(); app.cc_cache:rebuild(); app.controller_selection_active=not g.range_only; app.gesture=nil; return
  elseif g.kind=='marquee' then
    local x1,x2=math.min(g.x1,g.x2),math.max(g.x1,g.x2); local y1,y2=math.min(g.y1,g.y2),math.max(g.y1,g.y2)
    for _,n in ipairs(app.cache:get(true)) do if marquee_note_hit(g,app.viewport,n) then Selection.add(app.selection,n.id) end end
  elseif g.kind=='glue' then apply_glue(app,g)
  elseif g.kind=='slice' then
    local cut_sets={}; for _,mark in pairs(g.slices or {}) do cut_sets[mark.note]=cut_sets[mark.note] or {}; cut_sets[mark.note][string.format('%.3f',mark.ppq)]=mark.ppq end
    local plans,indices={},{ }; for n,set in pairs(cut_sets) do local cuts={}; for _,ppq in pairs(set) do cuts[#cuts+1]=ppq end; table.sort(cuts); plans[#plans+1]={note=n,cuts=cuts}; indices[#indices+1]=n.index end
    if #plans>0 then app.edit:begin('ReaRoll: paint slice notes',app.take); app.edit:delete_indices(app.take,indices); local wanted={}
      for _,plan in ipairs(plans) do local n,start=plan.note,plan.note.s; for _,ending in ipairs(plan.cuts) do app.edit:insert(app.take,start,ending,n.pitch,n.vel,n.chan,true,n.muted); wanted[#wanted+1]={s=start,e=ending,pitch=n.pitch,vel=n.vel}; start=ending end; app.edit:insert(app.take,start,n.e,n.pitch,n.vel,n.chan,true,n.muted); wanted[#wanted+1]={s=start,e=n.e,pitch=n.pitch,vel=n.vel} end
      app.edit:finish(); app.cache:rebuild(); reselect(app,wanted)
    end
  else
    local wanted={}
    if g.items then for _,a in ipairs(g.items) do wanted[#wanted+1]={s=a.note.s,e=a.note.e,pitch=a.note.pitch,vel=a.note.vel} end end
    app.edit:finish(); app.cache:rebuild(); reselect(app,wanted)
  end
  app.audition:stop(); app.gesture=nil
end

function C.draw(app)
  local I,c,T,s,take=app.ImGui,app.ctx,app.theme,app.settings,app.take
  -- Alt-wheel property edits are deliberately coalesced for a short time.
  -- A new pointer gesture is a new user action and must get its own undo block.
  if app.property_wheel and (I.IsMouseClicked(c,I.MouseButton_Left) or I.IsMouseClicked(c,I.MouseButton_Right) or I.IsMouseClicked(c,I.MouseButton_Middle)) then app:flush_property_wheel(true) end
  local aw,ah=I.GetContentRegionAvail(c); local key_w,ruler_h,hbar_h,vbar_w=88,22,16,16
  local lane_tools_h=LaneTools.height(app); local lane_min=40+lane_tools_h
  local lane_total_h=s.lane_open and U.clamp(s.lane_height,lane_min,math.max(lane_min,ah*.46)) or lane_tools_h
  local raw_grid_h=math.max(90,ah-ruler_h-lane_total_h-hbar_h-1)
  local grid_h=s.lane_open and math.max(s.row_height,math.floor(raw_grid_h/s.row_height)*s.row_height) or raw_grid_h
  -- With the lane open, give the fractional pitch-row remainder to the lane.
  -- With it closed, let the grid absorb that remainder so the scrollbar and
  -- phrase toolbar remain flush against each other and the window bottom.
  if s.lane_open then lane_total_h=lane_total_h+(raw_grid_h-grid_h) end
  local x0,y0=I.GetCursorScreenPos(c); local gx,gy=x0+key_w,y0+ruler_h; local v=app.viewport
  local source_start,source_end=source_timeline_bounds(app)
  v:set_geometry(gx,gy,math.max(100,aw-key_w-vbar_w-2),grid_h,take,source_start,source_end)
  local item_ppq0=reaper.MIDI_GetPPQPosFromProjQN(take,app.item_start_qn)
  local item_ppq1=reaper.MIDI_GetPPQPosFromProjQN(take,app.item_end_qn)
  local fold_notes={}
  for _,n in ipairs(app.cache:get(app.gesture~=nil)) do if n.e>=item_ppq0 and n.s<=item_ppq1 then fold_notes[#fold_notes+1]=n end end
  if s.fold_enabled and app.key_colors and next(app.key_colors) then
    fold_notes={table.unpack(fold_notes)}; for pitch in pairs(app.key_colors) do fold_notes[#fold_notes+1]={pitch=pitch} end
  end
  v:set_fold(fold_notes)
  local notes={}
  for _,n in ipairs(app.cache:visible(v.ppq0,v.ppq1,v.fold and 0 or s.low_pitch,v.fold and 127 or v:high_pitch(),app.gesture~=nil)) do
    if n.e>=item_ppq0 and n.s<=item_ppq1 then notes[#notes+1]=n end
  end
  local mx,my=I.GetMousePos(c)
  local phrase_popup_open=LaneTools.any_popup_open(app)
  local interaction_channel=(s.mode=='select' or s.mode=='slice') and nil or (s.channel or 0)
  local inside_item=mx>=v:x_from_qn(app.item_start_qn) and mx<=v:x_from_qn(app.item_end_qn)
  local hover,edge=hit_note_inside(inside_item,v,notes,mx,my,s.row_height,interaction_channel)
  local glue_hover=nil
  if s.mode=='glue' then local best=math.huge; for _,boundary in ipairs(glue_boundaries(notes,s.channel or 0)) do local bx,by=v:x_from_ppq(boundary.ppq),v:y_from_pitch(boundary.pitch); local distance=by and math.sqrt((mx-bx)^2+(my-(by+s.row_height*.5))^2) or math.huge; if distance<=10 and distance<best then glue_hover,best=boundary,distance end end end
  local hover_pitch=nil; if my>=gy and my<=gy+grid_h and mx>=x0 and mx<=gx+v.w then hover_pitch=v:pitch_from_y(my) end
  local d=I.GetWindowDrawList(c)
  draw_background(app,d,v,x0,y0,key_w,ruler_h,grid_h,hover_pitch)
  local playhead=playhead_visual(app,v)
  I.DrawList_PushClipRect(d,gx,gy,gx+v.w,gy+grid_h,true); draw_playhead_pass(app,d,playhead,gy,gy+grid_h,false); I.DrawList_PopClipRect(d)
  local status=string.format('%s  ·  V%d  ·  %s',s.mode:sub(1,1):upper()..s.mode:sub(2),s.velocity,s.adaptive_grid and 'Auto' or string.format('G %.3g',s.grid_qn))
  if hover then
    local stacked=overlapping_channels(notes,hover); local stack_text=''
    if #stacked>0 then local labels={'Ch '..tostring((hover.chan or 0)+1)}; for _,channel in ipairs(stacked) do labels[#labels+1]='Ch '..tostring(channel+1) end; stack_text='  |  Stack '..table.concat(labels,' + ') end
    status=U.pitch_name(hover.pitch)..'  ·  V'..hover.vel..stack_text..'  ·  '..status
  end
  I.DrawList_PushClipRect(d,gx,gy,gx+v.w,gy+grid_h,true)
  local note_play_ppq=nil
  if s.note_playback_animation~=false and reaper.GetPlayState and (reaper.GetPlayState()&1)~=0 then note_play_ppq=reaper.MIDI_GetPPQPosFromProjTime(take,reaper.GetPlayPosition()) end
  local ghost_hover=draw_ghost_notes(app,d,v,mx,my); if not phrase_popup_open then draw_placement_preview(app,d,v,mx,my,hover or ghost_hover) end
  local active_left=U.clamp(v:x_from_qn(app.item_start_qn),gx,gx+v.w); local active_right=U.clamp(v:x_from_qn(app.item_end_qn),gx,gx+v.w)
  local stretch_hot=false
  if active_right>active_left then
    I.DrawList_PushClipRect(d,active_left,gy,active_right,gy+grid_h,true)
    draw_notes(app,d,v,notes,hover,note_play_ppq)
    local frame_notes,frame_all=app.cache:get(true),false
    if app.gesture and (app.gesture.kind=='move' or app.gesture.kind=='resize' or app.gesture.kind=='stretch') and app.gesture.items then
      frame_notes={}; for _,entry in ipairs(app.gesture.items) do frame_notes[#frame_notes+1]=entry.note end; frame_all=true
    end
    stretch_hot=draw_selection_bounds(app,d,v,frame_notes,mx,my,frame_all)
    if glue_hover then local bx,by=v:x_from_ppq(glue_hover.ppq),v:y_from_pitch(glue_hover.pitch); I.DrawList_AddLine(d,bx,by+1,bx,by+s.row_height-2,T.selected_edge or T.accent,3) end
    I.DrawList_PopClipRect(d)
  end
  I.DrawList_PopClipRect(d)
  local loop_start,loop_end=reaper.GetSet_LoopTimeRange(false,true,0,0,false)
  if loop_end>loop_start then
    local lx1=v:x_from_qn(reaper.TimeMap2_timeToQN(0,loop_start)); local lx2=v:x_from_qn(reaper.TimeMap2_timeToQN(0,loop_end))
    lx1,lx2=math.max(gx,lx1),math.min(gx+v.w,lx2)
    if lx2>lx1 then I.DrawList_AddRectFilled(d,lx1,y0,lx2,y0+ruler_h,0x6389F544); I.DrawList_AddLine(d,lx1,y0,lx1,gy+grid_h,0x6389F566); I.DrawList_AddLine(d,lx2,y0,lx2,gy+grid_h,0x6389F566) end
  end
  I.DrawList_PushClipRect(d,gx,gy,gx+v.w,gy+grid_h,true); draw_playhead_pass(app,d,playhead,gy,gy+grid_h,true); I.DrawList_PopClipRect(d)
  local status_w,status_h=I.CalcTextSize(c,status)
  if status_w<v.w*.62 then
    local chip_right=x0+aw; local sx=chip_right-status_w-6
    local chip_h=ruler_h; local chip_y=y0
    I.DrawList_PushClipRect(d,v.x,y0,chip_right,y0+ruler_h,true)
    I.DrawList_AddRectFilled(d,sx-4,chip_y,chip_right,chip_y+chip_h,T.ruler_top,0)
    I.DrawList_AddText(d,sx,chip_y+math.max(0,math.floor((chip_h-status_h)*.5)),T.hint,status)
    I.DrawList_PopClipRect(d)
  end
  local start_handle_x,end_handle_x=v:x_from_qn(app.item_start_qn),v:x_from_qn(app.item_end_qn)
  local handle_y1,handle_y2=y0+2,y0+ruler_h-2
  local start_hot=my>=y0 and my<=y0+ruler_h and math.abs(mx-start_handle_x)<=7
  local end_hot=my>=y0 and my<=y0+ruler_h and math.abs(mx-end_handle_x)<=7
  local handle_color=T.item_edge or T.accent
  if start_handle_x>=gx and start_handle_x<=gx+v.w then
    I.DrawList_AddRectFilled(d,start_handle_x,handle_y1,start_handle_x+2,handle_y2,handle_color,1)
    I.DrawList_AddTriangleFilled(d,start_handle_x+2,handle_y1,start_handle_x+8,handle_y1,start_handle_x+2,handle_y1+5,handle_color)
  end
  if end_handle_x>=gx and end_handle_x<=gx+v.w then
    I.DrawList_AddRectFilled(d,end_handle_x-2,handle_y1,end_handle_x,handle_y2,handle_color,1)
    I.DrawList_AddTriangleFilled(d,end_handle_x-8,handle_y1,end_handle_x-2,handle_y1,end_handle_x-2,handle_y1+5,handle_color)
  end
  I.DrawList_PushClipRect(d,gx,gy,gx+v.w,gy+grid_h,true)
  if app.gesture and app.gesture.kind=='marquee' then local g=app.gesture
    local ax=g.qn1 and v:x_from_qn(g.qn1) or g.x1; local bx=g.qn2 and v:x_from_qn(g.qn2) or g.x2
    -- Preserve endpoints in pitch/world space while edge scrolling. Using the
    -- original screen Y after an endpoint left the view made the box move with
    -- the viewport instead of extending beyond it.
    local ay=g.pitch1 and (v:y_from_pitch_unclipped(g.pitch1) or g.y1) or g.y1; local by=g.pitch2 and (v:y_from_pitch_unclipped(g.pitch2) or g.y2) or g.y2
    local x1,y1,x2,y2=math.min(ax,bx),math.min(ay,by),math.max(ax,bx),math.max(ay,by)
    I.DrawList_AddRectFilled(d,x1,y1,x2,y2,T.marquee_fill); I.DrawList_AddRect(d,x1,y1,x2,y2,T.marquee_edge)
  elseif app.gesture and app.gesture.kind=='slice' then for _,mark in pairs(app.gesture.slices or {}) do local x,y=v:x_from_ppq(mark.ppq),v:y_from_pitch(mark.note.pitch); if y then I.DrawList_AddLine(d,x,y+1,x,y+s.row_height-2,T.slice_line,3) end end
  elseif app.gesture and app.gesture.kind=='glue' then for _,boundary in ipairs(glue_boundaries(notes,s.channel or 0)) do if app.gesture.seams[glue_key(boundary.ppq,boundary.pitch,boundary.chan)] then local bx,by=v:x_from_ppq(boundary.ppq),v:y_from_pitch(boundary.pitch); if by then I.DrawList_AddLine(d,bx,by+1,bx,by+s.row_height-2,T.selected_edge or T.accent,3) end end end end
  I.DrawList_PopClipRect(d)

  -- The ruler is its own interaction surface: left click seeks, left drag
  -- navigates, and right drag edits REAPER's loop-point selection.
  I.SetCursorScreenPos(c,gx,y0); I.InvisibleButton(c,'##timeline_ruler',positive(v.w),positive(ruler_h),I.ButtonFlags_MouseButtonLeft|I.ButtonFlags_MouseButtonRight)
  local ruler_hovered=I.IsItemHovered(c) and not phrase_popup_open
  if ruler_hovered then
    I.SetMouseCursor(c,(start_hot or end_hot) and I.MouseCursor_ResizeEW or I.MouseCursor_Hand)
    if I.IsMouseClicked(c,I.MouseButton_Left) then
      if start_hot or end_hot then
        if app.edit.active then app.edit:finish() end
        reaper.Undo_BeginBlock2(0)
        app.item_resize_gesture={edge=start_hot and 'start' or 'end',changed=false}
      else app.ruler_gesture={x=mx,y=my,lastx=mx,lasty=my,dragged=false} end
    end
    if I.IsMouseClicked(c,I.MouseButton_Right) then
      local q=math.max(0,v:qn_from_x(mx)); if s.snap_enabled then q=U.snap(q,s.grid_qn) end
      app.ruler_loop_gesture={anchor_qn=q,current_qn=q}
    end
    I.SetTooltip(c,(start_hot or end_hot) and 'Drag: resize MIDI item / Alt: unsnapped' or 'Left click: move edit cursor / seek\nLeft drag sideways: scroll time\nLeft drag vertically: zoom time\nRight drag: set REAPER loop points')
  end
  local irg=app.item_resize_gesture
  if irg and I.IsMouseDown(c,I.MouseButton_Left) then
    local unsnapped=U.mods(I,c).alt
    local q=math.max(0,v:qn_from_x(mx)); if s.snap_enabled and not unsnapped then q=U.snap(q,s.grid_qn) end
    local minimum=math.max(.001,s.snap_enabled and not unsnapped and s.grid_qn or .001)
    local first,last=app.item_start_qn,app.item_end_qn
    if irg.edge=='start' then first=math.min(q,last-minimum) else last=math.max(q,first+minimum) end
    if math.abs(first-app.item_start_qn)>.000001 or math.abs(last-app.item_end_qn)>.000001 then irg.changed=app:set_item_extents(first,last) or irg.changed end
  elseif irg and I.IsMouseReleased(c,I.MouseButton_Left) then
    reaper.Undo_EndBlock2(0,'ReaRoll: resize MIDI item',irg.changed and -1 or 0)
    app.item_resize_gesture=nil
  end
  local rg=app.ruler_gesture
  if rg and I.IsMouseDown(c,I.MouseButton_Left) then
    local dx,dy=mx-rg.lastx,my-rg.lasty
    if rg.dragged or math.abs(mx-rg.x)+math.abs(my-rg.y)>=3 then
      rg.dragged=true
      if dx~=0 then v:pan(dx,0) end
      if dy~=0 then app:zoom_time(math.exp(dy*.012),rg.x) end
      rg.lastx,rg.lasty=mx,my
    end
  elseif rg and I.IsMouseReleased(c,I.MouseButton_Left) then
    if not rg.dragged then
      local q=cursor_qn(app,v,rg.x)
      -- Seek the running transport as well as the stopped edit cursor.
      reaper.SetEditCurPos(reaper.TimeMap2_QNToTime(0,q),true,true)
    end
    app.ruler_gesture=nil
  end
  local lg=app.ruler_loop_gesture
  if lg and I.IsMouseDown(c,I.MouseButton_Right) then
    local q=math.max(0,v:qn_from_x(U.clamp(mx,v.x,v.x+v.w))); if s.snap_enabled then q=U.snap(q,s.grid_qn) end
    lg.current_qn=q
    local first,last=math.min(lg.anchor_qn,q),math.max(lg.anchor_qn,q)
    reaper.GetSet_LoopTimeRange(true,true,reaper.TimeMap2_QNToTime(0,first),reaper.TimeMap2_QNToTime(0,last),false)
  elseif lg and I.IsMouseReleased(c,I.MouseButton_Right) then
    local first,last=math.min(lg.anchor_qn,lg.current_qn),math.max(lg.anchor_qn,lg.current_qn)
    if last<=first then last=first+(s.grid_qn or .25) end
    reaper.GetSet_LoopTimeRange(true,true,reaper.TimeMap2_QNToTime(0,first),reaper.TimeMap2_QNToTime(0,last),false)
    app.ruler_loop_gesture=nil
  end

  -- Mapping, automation lanes, and folding share the keyboard-header cell.
  I.SetCursorScreenPos(c,x0+3,y0+2)
  local map_x,map_y=I.GetCursorScreenPos(c)
  if I.InvisibleButton(c,'##keyboard_mapping',18,18) then app.key_map_open=not app.key_map_open; app.key_mapping_mode=app.key_map_open end
  local map_hot=I.IsItemHovered(c); local map_d=I.GetWindowDrawList(c)
  if app.key_mapping_mode or map_hot then I.DrawList_AddRectFilled(map_d,map_x,map_y,map_x+18,map_y+18,app.key_mapping_mode and T.beat or T.panel2,4) end
  for i,color in ipairs({0xE37A5FFF,0xE8A653FF,0x4CC49AFF,0x6389F5FF}) do local px=map_x+3+((i-1)%2)*6; local py=map_y+3+math.floor((i-1)/2)*6; I.DrawList_AddRectFilled(map_d,px,py,px+5,py+5,color,1) end
  if map_hot then I.SetTooltip(c,'Key color mapping\nSelect keys, then choose a color. Mapped keys remain visible when folded.') end
  I.SetCursorScreenPos(c,x0+23,y0+2)
  local lane_x,lane_y=I.GetCursorScreenPos(c)
  if I.InvisibleButton(c,'##automation_lanes',18,18) then s.lane_open=not s.lane_open end
  local lane_hot=I.IsItemHovered(c)
  if s.lane_open or lane_hot then I.DrawList_AddRectFilled(map_d,lane_x,lane_y,lane_x+18,lane_y+18,s.lane_open and T.beat or T.panel2,4) end
  for i,h in ipairs({5,11,8}) do local px=lane_x+3+(i-1)*5; I.DrawList_AddLine(map_d,px,lane_y+15,px,lane_y+15-h,s.lane_open and T.accent or T.hint,2) end
  if lane_hot then I.SetTooltip(c,s.lane_open and 'Hide Velocity / CC automation lanes' or 'Show Velocity / CC automation lanes') end
  I.SetCursorScreenPos(c,x0+43,y0+2)
  local fold_x,fold_y=I.GetCursorScreenPos(c)
  if I.InvisibleButton(c,'##keyboard_fold',18,18) then
    s.fold_enabled=not s.fold_enabled
    s.fold_offset=0
  end
  local fold_hot=I.IsItemHovered(c)
  if s.fold_enabled or fold_hot then I.DrawList_AddRectFilled(map_d,fold_x,fold_y,fold_x+18,fold_y+18,s.fold_enabled and T.beat or T.panel2,4) end
  local fold_color=s.fold_enabled and T.accent or T.hint
  I.DrawList_AddLine(map_d,fold_x+3,fold_y+9,fold_x+8,fold_y+9,fold_color,1.5)
  I.DrawList_AddLine(map_d,fold_x+5.5,fold_y+6.5,fold_x+5.5,fold_y+11.5,fold_color,1.5)
  I.DrawList_AddLine(map_d,fold_x+11,fold_y+9,fold_x+16,fold_y+9,fold_color,1.5)
  if I.IsItemHovered(c) then
    I.SetTooltip(c,s.fold_enabled and 'Show all piano keys' or 'Fold to pitches used in this MIDI item')
  end

  I.SetCursorScreenPos(c,gx,gy); I.InvisibleButton(c,'##piano_roll_canvas',positive(v.w),positive(v.h),I.ButtonFlags_MouseButtonLeft|I.ButtonFlags_MouseButtonRight|I.ButtonFlags_MouseButtonMiddle)
  local hovered=I.IsItemHovered(c) and not phrase_popup_open; local mods=U.mods(I,c)
  if hovered and (I.IsMouseClicked(c,I.MouseButton_Left) or I.IsMouseClicked(c,I.MouseButton_Right)) then app.controller_selection_active=false end
  if (hovered and edge) or (app.gesture and app.gesture.kind=='resize') then I.SetMouseCursor(c,I.MouseCursor_ResizeEW)
  elseif hovered and s.mode=='glue' then I.SetMouseCursor(c,I.MouseCursor_Hand) end
  if hovered and hover and not app.gesture then
    if edge then I.SetTooltip(c,'Drag to resize / Alt: unsnapped resize')
    elseif s.mode=='smart' or s.mode=='paint' or s.mode=='chord' then I.SetTooltip(c,'Drag: move | Shift-drag: clone | Ctrl: select | Alt: bypass snap | right-click: erase | Alt+right-click: actions') end
  end
  if hovered then
    local wheel=I.GetMouseWheel(c)
    if wheel~=0 and not app.gesture then
      if mods.ctrl and mods.shift then if Selection.count(app.selection)>0 then divide_selection(app,wheel>0 and 1 or -1) else v:pan(wheel*50,0) end
      elseif mods.alt and not mods.ctrl and hover then adjust_note_property(app,hover,wheel)
      elseif mods.ctrl and mods.alt then v:zoom_pitch(wheel>0 and 1.12 or .89,my)
      elseif mods.ctrl then app:zoom_time(wheel>0 and .82 or 1.22,mx)
      elseif mods.shift then v:pan(wheel*50,0)
      else v:scroll_pitch(wheel*3) end
    end
  end
  if hovered and I.IsMouseClicked(c,I.MouseButton_Middle) then app.gesture={kind='pan',mx=mx,my=my,lastx=mx,lasty=my} end
  if app.gesture and app.gesture.kind=='pan' and I.IsMouseDown(c,I.MouseButton_Middle) then v:pan(mx-app.gesture.lastx,my-app.gesture.lasty); app.gesture.lastx,app.gesture.lasty=mx,my
  elseif app.gesture and app.gesture.kind=='pan' and I.IsMouseReleased(c,I.MouseButton_Middle) then app.gesture=nil end
  if hovered and I.IsMouseClicked(c,I.MouseButton_Right) and not hover and not app.gesture then
    app.gesture={kind='marquee',x1=mx,y1=my,x2=mx,y2=my,qn1=v:qn_from_x(mx),qn2=v:qn_from_x(mx),pitch1=v:pitch_from_y(my),pitch2=v:pitch_from_y(my),button=I.MouseButton_Right,add=mods.ctrl or mods.shift}
    if not app.gesture.add then Selection.clear(app.selection) end
  elseif hovered and I.IsMouseClicked(c,I.MouseButton_Right) and hover and mods.alt then
    if not Selection.has(app.selection,hover.id) then Selection.set_only(app.selection,hover.id) end; I.OpenPopup(c,'##note_context')
  elseif hovered and I.IsMouseClicked(c,I.MouseButton_Right) and hover then
    app.edit:begin('ReaRoll: erase notes',take); app.edit:delete_indices(take,{hover.index}); app.gesture={kind='erase',last_id=hover.id}; Selection.clear(app.selection); app.cache:rebuild()
  elseif hovered and I.IsMouseDoubleClicked(c,I.MouseButton_Left) and hover and not app.gesture then
    if not Selection.has(app.selection,hover.id) then Selection.set_only(app.selection,hover.id) end; app.property_velocity=hover.vel; app.property_channel=hover.chan+1; app.property_muted=hover.muted; I.OpenPopup(c,'##note_properties')
  elseif hovered and I.IsMouseClicked(c,I.MouseButton_Left) and not app.gesture then
    if not hover and ghost_hover then app:focus_take(ghost_hover.take,ghost_hover)
    elseif stretch_hot then begin_stretch(app,take,v,mx) else begin_gesture(app,take,v,notes,hover,edge,mx,my,mods) end
  end
  local gesture_button=app.gesture and app.gesture.button or I.MouseButton_Left
  if app.gesture and I.IsMouseDown(c,gesture_button) then
    if auto_scroll(app,v,mx,my) then v:set_geometry(gx,gy,v.w,grid_h,take,app.item_start_qn,app.item_end_qn) end
  end
  if app.gesture and app.gesture.kind=='erase' and I.IsMouseDown(c,I.MouseButton_Right) then
    local current=hit_note(v,app.cache:visible(v.ppq0,v.ppq1,v.fold and 0 or s.low_pitch,v.fold and 127 or v:high_pitch(),true),mx,my,s.row_height,s.channel or 0)
    if current and current.id~=app.gesture.last_id then app.edit:delete_indices(take,{current.index}); app.gesture.last_id=current.id; app.cache:rebuild() end
  elseif app.gesture and app.gesture.kind=='erase' and I.IsMouseReleased(c,I.MouseButton_Right) then app.edit:finish(); app.gesture=nil end
  if app.gesture and app.gesture.kind=='mute' and I.IsMouseDown(c,I.MouseButton_Left) then
    local current=hit_note(v,app.cache:visible(v.ppq0,v.ppq1,v.fold and 0 or s.low_pitch,v.fold and 127 or v:high_pitch(),true),mx,my,s.row_height,s.channel or 0)
    if current and not app.gesture.visited[current.id] then app.edit:set_muted(take,current.index,app.gesture.target); current.muted=app.gesture.target; app.gesture.visited[current.id]=true end
  elseif app.gesture and app.gesture.kind=='mute' and I.IsMouseReleased(c,I.MouseButton_Left) then app.edit:finish(); app.cache:rebuild(); app.gesture=nil end
  if app.gesture and app.gesture.kind~='pan' and I.IsMouseDown(c,gesture_button) then update_gesture(app,take,v,mx,my,mods)
  elseif app.gesture and app.gesture.kind~='pan' and I.IsMouseReleased(c,gesture_button) then finish_gesture(app,notes) end
  note_context(app)
  note_properties(app)

  -- Piano keys preview the pitch without creating MIDI.
  I.SetCursorScreenPos(c,x0,gy); I.InvisibleButton(c,'##preview_keyboard',positive(key_w),positive(grid_h),I.ButtonFlags_MouseButtonLeft|I.ButtonFlags_MouseButtonRight)
  if I.IsItemHovered(c) and not app.gesture then
    local wheel=I.GetMouseWheel(c)
    if wheel~=0 then if mods.ctrl or mods.alt then v:zoom_pitch(wheel>0 and 1.12 or .89,my) else v:scroll_pitch(wheel*3) end end
  end
  if I.IsItemHovered(c) and not phrase_popup_open and app.key_mapping_mode and I.IsMouseClicked(c,I.MouseButton_Left) then
    local pitch=v:pitch_from_y(my); local selected=app.key_map_selection
    if mods.shift and app.key_map_anchor then
      if not mods.ctrl then for key in pairs(selected) do selected[key]=nil end end
      for key=math.min(app.key_map_anchor,pitch),math.max(app.key_map_anchor,pitch) do selected[key]=true end
    elseif mods.ctrl then selected[pitch]=not selected[pitch] or nil; app.key_map_anchor=pitch
    else for key in pairs(selected) do selected[key]=nil end; selected[pitch]=true; app.key_map_anchor=pitch end
    if app.key_colors[pitch] then app.key_map_color=app.key_colors[pitch] end
  elseif I.IsItemHovered(c) and not phrase_popup_open and app.key_mapping_mode and I.IsMouseClicked(c,I.MouseButton_Right) then
    local pitch=v:pitch_from_y(my); local base={}
    if mods.ctrl or mods.shift then for key,value in pairs(app.key_map_selection) do base[key]=value end end
    app.key_map_marquee={anchor=pitch,base=base}; app.key_map_anchor=pitch
  elseif app.key_mapping_mode and app.key_map_marquee and I.IsMouseDown(c,I.MouseButton_Right) then
    local current=v:pitch_from_y(U.clamp(my,gy,gy+grid_h-1)); local selected=app.key_map_selection
    for key in pairs(selected) do selected[key]=nil end; for key,value in pairs(app.key_map_marquee.base) do selected[key]=value end
    for key=math.min(app.key_map_marquee.anchor,current),math.max(app.key_map_marquee.anchor,current) do selected[key]=true end
  elseif app.key_map_marquee and I.IsMouseReleased(c,I.MouseButton_Right) then
    app.key_map_marquee=nil
  elseif I.IsItemActive(c) and not phrase_popup_open and I.IsMouseDown(c,I.MouseButton_Left) and not app.key_mapping_mode then
    local pitch=v:pitch_from_y(my)
    if app.key_preview_pitch~=pitch then
      if s.mode=='chord' then
        local root=pitch; if s.scale_enabled and s.scale_snap then root=app.music.snap(s.scale_root,s.scale_name,root) end
        app.audition:play_many(chord_pitches(app,root),s.velocity,s.channel)
      else app.audition:play(pitch,s.velocity,s.channel) end
      app.key_preview_pitch=pitch
    end
  elseif app.key_preview_pitch and I.IsMouseReleased(c,I.MouseButton_Left) then app.audition:stop(); app.key_preview_pitch=nil end

  local lane_top=gy+grid_h+1
  local lane_content_h=s.lane_open and (lane_total_h-lane_tools_h) or 0
  local phrase_y=lane_top+lane_content_h+hbar_h
  if s.lane_open then
  local splitter_y=gy+grid_h
  I.DrawList_AddLine(d,gx,splitter_y,gx+v.w,splitter_y,T.scrollbar_thumb,1.5)
  I.SetCursorScreenPos(c,gx,splitter_y-3); I.InvisibleButton(c,'##editor_lane_splitter',positive(v.w),6)
  if I.IsItemHovered(c) then I.SetMouseCursor(c,I.MouseCursor_ResizeNS) end
  if I.IsItemActive(c) and I.IsMouseDown(c,I.MouseButton_Left) then
    local bottom=y0+ah-hbar_h-3; s.lane_height=U.clamp(math.floor(bottom-my),lane_min,math.max(lane_min,ah-125))
  end

  local pins={}; local seen_lanes={[s.lane_target]=true}
  for slot=1,s.lane_refs_expanded and 2 or 0 do
    local target=s['lane_pin_'..slot]
    if target and target~='' and target~='none' and not seen_lanes[target] then
      seen_lanes[target]=true; pins[#pins+1]={slot=slot,target=target}
    end
  end
  local available_for_pins=lane_content_h-40
  local pin_h=#pins>0 and math.min(30,available_for_pins/#pins) or 0
  -- Below 16 px a pinned strip is neither readable nor safely interactive.
  -- Collapse references and give the space to the active lane instead.
  if pin_h<16 then pins={}; pin_h=0 end
  local pin_space=#pins*pin_h
  I.DrawList_AddRectFilled(d,x0,lane_top,gx+v.w,lane_top+lane_content_h,T.panel)
  I.DrawList_AddRectFilled(d,x0,lane_top,gx-1,lane_top+lane_content_h,T.lane_header)
  for index,pin in ipairs(pins) do
    local py=lane_top+(index-1)*pin_h; local def=draw_lane_preview(app,d,v,notes,py,pin_h,pin.target)
    I.DrawList_AddLine(d,x0,py+pin_h,gx+v.w,py+pin_h,T.grid)
    I.DrawList_AddText(d,x0+4,py+math.max(2,(pin_h-14)*.5),T.hint,def.short)
    draw_lane_title(app,d,gx+7,py+math.max(3,(pin_h-14)*.5),'Viewing: '..def.label,gx+v.w)
    I.SetCursorScreenPos(c,x0,py); I.InvisibleButton(c,'##pinned_lane_'..pin.slot,positive(key_w-2),positive(pin_h))
    if I.IsItemHovered(c) then I.SetTooltip(c,'Reference lane: '..def.label..'\nClick to make this the editable lane.'); if I.IsMouseClicked(c,I.MouseButton_Left) then local old=s.lane_target; s.lane_target=pin.target; s['lane_pin_'..pin.slot]=old end end
  end
  local vy=lane_top+pin_space; local lane_h=lane_content_h-pin_space
  phrase_y=lane_top+lane_content_h+hbar_h
  I.DrawList_AddRectFilled(d,gx,vy,gx+v.w,vy+lane_h,T.lane_bg or T.row)
  I.DrawList_AddRectFilled(d,x0,vy,gx-1,vy+lane_h,T.panel2)
  I.DrawList_AddLine(d,gx,lane_top,gx,lane_top+lane_content_h,T.grid)
  draw_lane_beat_shading(app,d,v,vy,lane_h)
  local lane_step=s.grid_qn
  while lane_step*v.px_per_qn<18 and lane_step<4 do lane_step=lane_step*2 end
  local lane_first=math.floor(s.start_qn/lane_step)*lane_step
  for q=lane_first,s.start_qn+s.visible_qn+lane_step,lane_step do local lx=crisp_x(v:x_from_qn(q)); if lx>=gx and lx<=gx+v.w then I.DrawList_AddLine(d,lx,vy,lx,vy+lane_h,T.lane_grid) end end
  draw_lane_meter_lines(app,d,v,vy,lane_h)
  local lane=lane_definition(s)
  draw_lane_title_right(app,d,vy+5,'Editing: '..lane.label,gx+8,gx+v.w-4)
  local velocity_hover,velocity_distance
  if not (lane.cc or lane.pitch or lane.status) and U.contains(mx,my,gx,vy,gx+v.w,vy+lane_h) then velocity_hover,velocity_distance=pick_velocity_handle(app,v,notes,mx,my,vy,lane_h) end
  I.DrawList_PushClipRect(d,gx,vy,gx+v.w,vy+lane_h,true)
  if lane.cc or lane.pitch or lane.status then draw_cc_events(app,d,v,vy,lane_h,lane)
  else
    local active_item=reaper.GetMediaItemTake_Item(take)
    local velocity_color=lane_graph_color(U.track_color(active_item and reaper.GetMediaItemTrack(active_item),T.note),T.lane_bg or T.row)
    for _,n in ipairs(notes) do
      local bx,top=velocity_handle(v,n,vy,lane_h); local bh=(n.vel/127)*(lane_h-8)
      local selected=Selection.has(app.selection,n.id); local col=velocity_color
      if bx>=gx and bx<=gx+v.w then
        I.DrawList_AddLine(d,bx,vy+lane_h-2,bx,top,col,2)
        local _,cap_right=velocity_cap(v,n,notes,s.channel or 0); cap_right=math.min(cap_right,gx+v.w)
        I.DrawList_AddLine(d,bx,top,cap_right,top,col,n==velocity_hover and velocity_distance<=225 and 1.5 or 1)
        local hot=n==velocity_hover and velocity_distance<=225; local radius=hot and 6 or (selected and 4.5 or 3.5)
        I.DrawList_AddCircleFilled(d,bx,top,radius,col)
        I.DrawList_AddCircle(d,bx,top,radius,selected and T.selected_edge or T.note_border,0,hot and 2 or 1)
      end
    end
  end
  draw_controller_gesture_value(app,d,lane,app.gesture,mx,my,gx,vy,lane_h,v.w)
  if app.lane_time_selection then local rx1,rx2=v:x_from_qn(app.lane_time_selection.start_qn),v:x_from_qn(app.lane_time_selection.end_qn); I.DrawList_AddRectFilled(d,rx1,vy,rx2,vy+lane_h,T.marquee_fill); I.DrawList_AddLine(d,rx1,vy,rx1,vy+lane_h,T.marquee_edge,2); I.DrawList_AddLine(d,rx2,vy,rx2,vy+lane_h,T.marquee_edge,2) end
  if app.gesture and app.gesture.kind=='cc_marquee' then local g=app.gesture; I.DrawList_AddRectFilled(d,math.min(g.x1,g.x2),vy,math.max(g.x1,g.x2),vy+lane_h,T.marquee_fill); I.DrawList_AddRect(d,math.min(g.x1,g.x2),vy,math.max(g.x1,g.x2),vy+lane_h,T.marquee_edge) end
  I.DrawList_PopClipRect(d)
  I.SetCursorScreenPos(c,gx,vy); I.InvisibleButton(c,'##editor_lane_canvas',positive(v.w),positive(lane_h))
  local lane_hovered=I.IsItemHovered(c) and not phrase_popup_open
  local lane_closest,lane_dist=nil,math.huge
  if lane_hovered and (lane.cc or lane.pitch or lane.status) then for _,e in ipairs(app.cc_cache:get(false)) do
    if lane_matches_event(lane,e,s.channel) then local value,max_value=lane.pitch and ((e.msg3<<7)|e.msg2) or (lane.status and e.msg2 or e.msg3),lane.pitch and 16383 or 127; local ex,ey=v:x_from_ppq(e.ppq),vy+lane_h-(value/max_value)*(lane_h-7)-3; local distance=(ex-mx)^2+(ey-my)^2; if distance<lane_dist then lane_closest,lane_dist=e,distance end end
  end end
  if lane_hovered then
    local q=U.clamp(v:qn_from_x(mx),app.item_start_qn,app.item_end_qn)
    local position=reaper.format_timestr_pos and reaper.format_timestr_pos(reaper.TimeMap2_QNToTime(0,q),'',2) or string.format('%.2f',q)
    local maximum=lane.pitch and 16383 or 127; local minimum=(lane.cc or lane.pitch or lane.status) and 0 or 1
    local value=U.clamp(math.floor((vy+lane_h-3-my)/math.max(1,lane_h-7)*maximum+.5),minimum,maximum)
    if lane.switch then value=value>=64 and 127 or 0 end
    local value_text=(lane.cc or lane.pitch or lane.status) and controller_value_label(s,lane,value) or tostring(value); local value_w=I.CalcTextSize(c,value_text)
    I.DrawList_PushClipRect(d,x0,vy,gx-1,vy+lane_h,true)
    I.DrawList_AddText(d,x0+5,vy+lane_h-18,T.hint,position)
    I.DrawList_AddText(d,gx-value_w-5,vy+lane_h-18,T.hint,value_text)
    I.DrawList_PopClipRect(d)
    if lane_closest and lane_dist<=100 then I.SetMouseCursor(c,I.MouseCursor_ResizeAll or I.MouseCursor_ResizeNS) end
  end
  if lane_hovered and I.IsMouseClicked(c,I.MouseButton_Right) and (lane.cc or lane.pitch or lane.status) and not app.gesture then
    if lane_closest and lane_dist<=100 then app.edit:begin('ReaRoll: delete controller event',take); app.edit:delete_cc_indices(take,{lane_closest.index}); app.edit:finish(); app.cc_cache:rebuild(); app.clipboard.chase_cc(app,lane) end
    if not lane_closest or lane_dist>100 then local anchor=mx; if app.lane_time_selection then local left,right=v:x_from_qn(app.lane_time_selection.start_qn),v:x_from_qn(app.lane_time_selection.end_qn); if math.abs(mx-left)<=8 then anchor=right elseif math.abs(mx-right)<=8 then anchor=left end end; if s.snap_enabled then anchor=v:x_from_qn(U.snap(v:qn_from_x(anchor),s.grid_qn)) end; app.controller_selection_active=true; app.controller_lane=lane; app.gesture={kind='cc_marquee',button=I.MouseButton_Right,x1=anchor,y1=vy,x2=anchor,y2=vy+lane_h,press_x=mx,cc=lane.cc,pitch=lane.pitch,status=lane.status,channel=s.channel or 0,bottom=vy+lane_h-3,height=lane_h-7,add=mods.ctrl or mods.shift} end
  end
  if lane_hovered and I.IsMouseClicked(c,I.MouseButton_Right) and not (lane.cc or lane.pitch or lane.status) and not app.gesture then local anchor=mx; if app.lane_time_selection then local left,right=v:x_from_qn(app.lane_time_selection.start_qn),v:x_from_qn(app.lane_time_selection.end_qn); if math.abs(mx-left)<=8 then anchor=right elseif math.abs(mx-right)<=8 then anchor=left end end; if s.snap_enabled then anchor=v:x_from_qn(U.snap(v:qn_from_x(anchor),s.grid_qn)) end; app.controller_selection_active=false; app.gesture={kind='cc_marquee',range_only=true,button=I.MouseButton_Right,x1=anchor,y1=vy,x2=anchor,y2=vy+lane_h,press_x=mx,channel=s.channel or 0,bottom=vy+lane_h-3,height=lane_h-7} end
  if lane_hovered and (lane.cc or lane.pitch or lane.status) and not app.gesture then
    local readout=''; if lane_closest and lane_dist<=100 then
      local value=lane.pitch and ((lane_closest.msg3<<7)|lane_closest.msg2) or (lane.status and lane_closest.msg2 or lane_closest.msg3)
      local q=reaper.MIDI_GetProjQNFromPPQPos(take,lane_closest.ppq); local position=reaper.format_timestr_pos and reaper.format_timestr_pos(reaper.TimeMap2_QNToTime(0,q),'',2) or string.format('%.3f QN',q)
      readout='\nPoint: '..controller_value_label(s,lane,value)..' at '..position..(lane.pitch and ' · raw '..tostring(value) or '')
    end
    I.SetTooltip(c,(lane.protected and 'Protected channel-mode lane: existing points are view/move/delete only.' or ('Drag: draw or reshape '..lane.label))..readout..'\nCtrl-click a point: add/remove selection\nRight-click empty lane: clear selection\nRight-drag empty lane: snapped musical range\nRight-drag a range edge: resize it\nDrag selected points: move\nShift-drag selected points: duplicate\nRight-click near a point: delete it\nThe mouse wheel here never scrolls note pitches.')
  elseif lane_hovered and velocity_hover and velocity_distance<=225 and not app.gesture then
    I.SetMouseCursor(c,I.MouseCursor_ResizeNS)
    I.SetTooltip(c,string.format('%s  velocity %d\nDrag the handle to edit%s\nDrag empty lane space to paint velocities; hold Shift for a straight line.',U.pitch_name(velocity_hover.pitch),velocity_hover.vel,Selection.has(app.selection,velocity_hover.id) and ' the selected notes' or ' this note'))
  elseif lane_hovered and not app.gesture then
    I.SetTooltip(c,'Left-drag to paint note velocities.\nHold Shift while dragging for a straight velocity line.\nRight-click empty lane: clear the selected range.\nRight-drag: create a snapped range.\nThe mouse wheel here never scrolls note pitches.')
  end
  if lane.cc or lane.pitch or lane.status then
    if lane_hovered and I.IsMouseClicked(c,I.MouseButton_Left) and not app.gesture then
      if lane_closest and lane_dist<=100 then
        app.controller_selection_active=true; app.controller_lane=lane
        local all=app.cc_cache:get(true); if mods.ctrl then reaper.MIDI_SetCC(take,lane_closest.index,not lane_closest.selected,nil,nil,nil,nil,nil,nil,true)
        elseif not lane_closest.selected then for _,e in ipairs(all) do if lane_matches_event(lane,e,s.channel) then reaper.MIDI_SetCC(take,e.index,false,nil,nil,nil,nil,nil,nil,true) end end; reaper.MIDI_SetCC(take,lane_closest.index,true,nil,nil,nil,nil,nil,nil,true) end
        reaper.MIDI_Sort(take); app.cc_cache:invalidate(); app.cc_cache:rebuild()
        -- Ctrl-click is selection-only.  Starting a drag from the event's stale
        -- pre-toggle state made deselection occasionally move the other points.
        if not mods.ctrl then local items={}; local anchor_value=lane.pitch and ((lane_closest.msg3<<7)|lane_closest.msg2) or (lane.status and lane_closest.msg2 or lane_closest.msg3)
          for _,e in ipairs(app.cc_cache.events) do if lane_matches_event(lane,e,s.channel) and e.selected then items[#items+1]={index=e.index,ppq=e.ppq,value=lane.pitch and ((e.msg3<<7)|e.msg2) or (lane.status and e.msg2 or e.msg3)} end end
          if #items>0 then
            if mods.shift then local _,_,base=reaper.MIDI_CountEvts(take); app.edit:begin('ReaRoll: duplicate controller events',take); local copies={}; for i,a in ipairs(items) do if lane.pitch then app.edit:insert_pitch(take,a.ppq,s.channel,a.value) elseif lane.status then app.edit:insert_message(take,a.ppq,s.channel,lane.status,a.value) else app.edit:insert_cc(take,a.ppq,s.channel,lane.cc,a.value) end; copies[#copies+1]={index=base+i-1,ppq=a.ppq,value=a.value} end; items=copies
            else app.edit:begin('ReaRoll: move controller events',take) end
            app.gesture={kind='cc_move',cc=lane.cc,pitch=lane.pitch,status=lane.status,switch=lane.switch,items=items,anchor_qn=v:qn_from_x(mx),anchor_value=anchor_value,bottom=vy+lane_h,height=lane_h-5}
          end
        end
      elseif not lane.protected then
        app.controller_selection_active=true; app.controller_lane=lane
        local events={}; for _,e in ipairs(app.cc_cache:get(true)) do if lane_matches_event(lane,e,s.channel) then local q=U.snap(reaper.MIDI_GetProjQNFromPPQPos(take,e.ppq),s.grid_qn); events[string.format('%.6f',q)]=e end end
        app.edit:begin('ReaRoll: draw '..lane.label,take); app.gesture={kind='cc',cc=lane.cc,pitch=lane.pitch,status=lane.status,switch=lane.switch,discrete=lane.discrete,events=events,last_q=nil,last_value=nil,bottom=vy+lane_h,height=lane_h-5}
      end
    end
  elseif I.IsItemHovered(c) and I.IsMouseClicked(c,I.MouseButton_Left) and not app.gesture then
    local closest,dist=pick_velocity_handle(app,v,notes,mx,my,vy,lane_h)
    if closest and dist<=225 and not mods.shift then
      if not Selection.has(app.selection,closest.id) then Selection.set_only(app.selection,closest.id) end
      local chosen=Selection.list(app.selection,app.cache:get(true)); app.edit:begin('ReaRoll: edit velocity',take)
      app.gesture={kind='velocity',items=snapshot(chosen),anchor=closest.vel,bottom=vy+lane_h,height=lane_h-4,last_delta=nil}
    else
      local active={}; for _,n in ipairs(app.cache:get(true)) do if (n.chan or 0)==(s.channel or 0) then active[#active+1]=n end end
      app.edit:begin('ReaRoll: paint velocity',take)
      app.gesture={kind='velocity_swipe',items=snapshot(active),anchor_x=mx,anchor_y=my,last_x=mx,last_y=my,bottom=vy+lane_h,height=lane_h-4,values={}}
      update_gesture(app,take,v,mx,my,mods)
    end
  end
  if app.gesture and (app.gesture.kind=='velocity' or app.gesture.kind=='velocity_swipe' or app.gesture.kind=='cc' or app.gesture.kind=='cc_move') and I.IsMouseDown(c,I.MouseButton_Left) then update_gesture(app,take,v,mx,my,mods)
  elseif app.gesture and (app.gesture.kind=='velocity' or app.gesture.kind=='velocity_swipe' or app.gesture.kind=='cc' or app.gesture.kind=='cc_move') and I.IsMouseReleased(c,I.MouseButton_Left) then finish_gesture(app,notes) end

  I.SetCursorScreenPos(c,x0,vy); I.SetNextItemWidth(c,key_w-2)
  if I.BeginCombo(c,'##editor_target',lane.short) then
    app.lane_search=app.lane_search or ''
    I.SetNextItemWidth(c,310)
    local search_changed; search_changed,app.lane_search=I.InputText(c,'##lane_search',app.lane_search)
    if I.IsItemHovered(c) then I.SetTooltip(c,'Search by controller name, CC number, velocity, pitch bend, or aftertouch.') end
    local refs_changed; refs_changed,s.lane_refs_expanded=I.Checkbox(c,'Show reference lanes',s.lane_refs_expanded)
    if I.IsItemHovered(c) then I.SetTooltip(c,'Show Mod and Expression as additional read-only graphs above the editable lane.') end
    I.Separator(c)
    local function choose(id,label)
      if I.Selectable(c,label,id==s.lane_target) then s.lane_target=id; local number=id:match('^cc(%d+)$'); if number then s.cc_number=tonumber(number) end end
    end
    local function cc_choice(number)
      choose('cc'..number,string.format('CC %03d  %s',number,cc_names[number] or 'Undefined / assignable'))
    end
    local query=(app.lane_search or ''):lower():match('^%s*(.-)%s*$')
    if query~='' then
      local matches=0
      for _,id in ipairs({'velocity','pitch','pressure','program'}) do local def=lane_defs[id]; if def.label:lower():find(query,1,true) or def.short:lower():find(query,1,true) then choose(id,def.label); matches=matches+1 end end
      for number=0,127 do
        local label=string.format('CC %03d  %s',number,cc_names[number] or 'Undefined / assignable')
        if label:lower():find(query,1,true) or tostring(number)==query then cc_choice(number); matches=matches+1 end
      end
      if matches==0 then I.TextDisabled(c,'No matching MIDI lane') end
    else
      I.TextDisabled(c,'Note and channel data')
      for _,id in ipairs({'velocity','pitch','pressure','program'}) do choose(id,lane_defs[id].label) end
      I.Separator(c); I.TextDisabled(c,'Quick access')
      for _,number in ipairs({1,2,4,7,10,11,64,65,66,67,71,72,73,74,91,93}) do cc_choice(number) end
      I.Separator(c); I.TextDisabled(c,'Browse all controllers')
      for _,folder in ipairs({{'CC 000–031',0,31},{'CC 032–063',32,63},{'CC 064–095',64,95},{'CC 096–111 · Data/NRPN',96,111},{'CC 112–119 · Data',112,119},{'CC 120–127 · Channel mode',120,127}}) do
        if I.BeginMenu(c,folder[1]) then for number=folder[2],folder[3] do cc_choice(number) end; I.EndMenu(c) end
      end
    end
    I.EndCombo(c)
  end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Editable lane: '..lane.label..'\nCC names are standard MIDI assignments, not a promise that the current VST responds.\nThe data is written on the selected MIDI channel and is heard during playback only when the receiver supports or maps it.') end
  if s.lane_target=='cc' then
    I.SetCursorScreenPos(c,x0,vy+26); I.SetNextItemWidth(c,key_w-2)
    local changed; changed,s.cc_number=I.InputInt(c,'##cc_number',s.cc_number,1,10)
    if changed then s.cc_number=U.clamp(s.cc_number,0,127) end
    Controls.number(app,s,'cc_number',1,1,0,127,'MIDI CC number')
    if I.IsItemHovered(c) then I.SetTooltip(c,(cc_names[s.cc_number] or 'MIDI controller')..' (CC '..s.cc_number..')\nWheel changes CC; right-click resets to Mod Wheel CC1.\nReceiver-dependent: a VST may ignore this CC unless it is mapped.') end
  elseif s.lane_target=='pitch' then
    I.SetCursorScreenPos(c,x0,vy+26); I.SetNextItemWidth(c,key_w-2)
    if I.BeginCombo(c,'##bend_range','+/-'..tostring(s.pitch_bend_range)) then for _,range in ipairs({1,2,12,24,48}) do if I.Selectable(c,'+/- '..range..' semitones',s.pitch_bend_range==range) then s.pitch_bend_range=range end end; I.EndCombo(c) end
    Controls.choice(app,s,'pitch_bend_range',2,{1,2,12,24,48},'Pitch bend display range')
    -- Scale labels belong to the graph, not underneath the lane-name combo.
    -- A small backing keeps them legible without obscuring controller points.
    local label_x=gx+5
    for _,mark in ipairs({{vy+3,'+'..s.pitch_bend_range},{vy+lane_h*.5-7,'0'},{vy+lane_h-16,'-'..s.pitch_bend_range}}) do
      local tw=I.CalcTextSize(c,mark[2]); I.DrawList_AddRectFilled(d,label_x-2,mark[1]-1,label_x+tw+2,mark[1]+15,T.panel); I.DrawList_AddText(d,label_x,mark[1],T.hint,mark[2])
    end
  end
  end
  draw_scrollbars(app,d,v,gx,gy,grid_h,lane_top,lane_content_h,hbar_h,vbar_w,mx,my)
  LaneTools.draw(app,gx,phrase_y,v.w,lane_tools_h)
  if app.chord_preview and I.IsMouseReleased(c,I.MouseButton_Left) then app.audition:stop(); app.chord_preview=nil end
  keyboard_shortcuts(app,take,notes)
end

function C.draw_empty(app,track)
  local I,c,T,s=app.ImGui,app.ctx,app.theme,app.settings
  local aw,ah=I.GetContentRegionAvail(c); local key_w,ruler_h,bottom,right=88,22,16,16
  local x0,y0=I.GetCursorScreenPos(c); local gx,gy=x0+key_w,y0+ruler_h
  local gw,gh=math.max(100,aw-key_w-right),math.max(90,ah-ruler_h-bottom)
  local rows=math.max(1,math.floor(gh/s.row_height)); s.low_pitch=U.clamp(s.low_pitch,0,math.max(0,128-rows))
  local d=I.GetWindowDrawList(c); I.DrawList_AddRectFilled(d,x0,y0,x0+aw,y0+ah,T.bg)
  I.DrawList_AddRectFilled(d,gx,y0,gx+gw,gy,T.ruler); I.DrawList_AddRectFilled(d,x0,gy,gx,gy+gh,T.white_key)
  local white_keys,black_keys={},{ }
  for row=0,rows-1 do
    local pitch=s.low_pitch+rows-1-row; local y=gy+row*s.row_height
    local black=U.is_black(pitch); local bottom_y=math.min(gy+gh,y+s.row_height)
    I.DrawList_AddRectFilled(d,gx,y,gx+gw,bottom_y,pitch%12==0 and T.c_row or (black and T.row_alt or T.row))
    I.DrawList_AddLine(d,gx,bottom_y,gx+gw,bottom_y,black and T.grid_soft or T.grid)
    local key={pitch=pitch,top=y,bottom=bottom_y,center=y+s.row_height*.5,black=black}
    if black then black_keys[#black_keys+1]=key else white_keys[#white_keys+1]=key end
  end
  for i,key in ipairs(white_keys) do
    key.top=i==1 and gy or (white_keys[i-1].center+key.center)*.5
    key.bottom=i==#white_keys and gy+gh or (key.center+white_keys[i+1].center)*.5
    local color=key.pitch%12==0 and T.c_key or T.white_key; local top_color=key.pitch%12==0 and T.c_key_top or T.white_key_top
    I.DrawList_AddRectFilledMultiColor(d,x0,key.top,gx-1,key.bottom,top_color,top_color,color,color)
    I.DrawList_AddLine(d,x0,key.bottom,gx-1,key.bottom,T.key_border)
    if key.pitch%12==0 and s.row_height>=11 then local label=U.pitch_name(key.pitch); local tw,th=I.CalcTextSize(c,label); I.DrawList_AddText(d,gx-tw-4,(key.top+key.bottom-(th or 12))*.5,T.black_key,label) end
  end
  for _,key in ipairs(black_keys) do
    local half=math.max(2,s.row_height*.43); local top_y,bottom_y=math.max(gy,key.center-half),math.min(gy+gh,key.center+half); local right_x=x0+key_w*.64
    local corners=I.DrawFlags_RoundCornersRight or I.DrawFlags_None
    I.DrawList_AddRectFilled(d,x0,top_y,right_x,bottom_y,T.black_key,2,corners)
    I.DrawList_AddLine(d,x0+1,top_y+1,right_x-2,top_y+1,T.black_key_top,1)
    I.DrawList_AddRect(d,x0,top_y,right_x,bottom_y,T.key_border,2,corners,1)
  end
  local step=math.max(s.grid_qn or .25,1/16); local first=math.floor(s.start_qn/step)*step
  for q=first,s.start_qn+s.visible_qn+step,step do
    local x=gx+(q-s.start_qn)/s.visible_qn*gw
    if x>=gx and x<=gx+gw then I.DrawList_AddLine(d,x,gy,x,gy+gh,(math.abs(q-math.floor(q+.5))<.00001) and T.beat or T.grid_soft) end
  end
  local _,track_name=reaper.GetTrackName(track); track_name=track_name~='' and track_name or 'selected track'
  local bars=math.max(1,math.floor(s.empty_item_bars or 4))
  I.DrawList_AddText(d,gx+12,gy+10,T.hint,'Empty '..track_name..' - click to create a '..bars..'-bar MIDI item')
  I.SetCursorScreenPos(c,gx,gy); I.InvisibleButton(c,'##empty_note_grid',gw,gh,I.ButtonFlags_MouseButtonLeft)
  if I.IsItemHovered(c) then
    local mx,my=I.GetMousePos(c); local mods=U.mods(I,c); local wheel=I.GetMouseWheel(c)
    if wheel~=0 then
      if mods.ctrl then
        local anchor=s.start_qn+(mx-gx)/gw*s.visible_qn; local ratio=(mx-gx)/gw; local wanted=U.clamp(s.visible_qn*(wheel>0 and .82 or 1.22),1/16,256); s.start_qn=math.max(0,anchor-ratio*wanted); s.visible_qn=wanted
      elseif mods.shift then s.start_qn=math.max(0,s.start_qn-wheel*s.visible_qn*.1)
      else s.low_pitch=U.clamp(s.low_pitch+wheel*3,0,math.max(0,128-rows)) end
    end
    if I.IsMouseClicked(c,I.MouseButton_Left) then
      local qn=s.start_qn+U.clamp((mx-gx)/gw,0,1)*s.visible_qn
      app:create_empty_item(track,qn)
    end
  end
end
return C
