-- @noindex
local V=require 'src.viewport'
local now=0
reaper={time_precise=function() return now end,MIDI_GetPPQPosFromProjQN=function(_,q) return q*960 end}
local s={smooth_scroll=true,start_qn=4,visible_qn=4,low_pitch=60,row_height=20}
local v=V.new(s); v:set_geometry(0,0,400,100,true,0,20)
v:wheel_scroll(-100,3)
assert(s.start_qn==4 and s.low_pitch==60,'wheel input queues a target')
now=.016; v:update_scroll(now,false); v:set_geometry(0,0,400,100,true,0,20)
assert(s.start_qn>4 and s.start_qn<5 and v.pitch_visual>0,'both axes ease')
for p=60,65 do
  local y=v:y_from_pitch(p)
  if y and y>=0 and y+10<100 then assert(v:pitch_from_y(y+10)==p,'drawing and picking agree') end
end
v:wheel_scroll(-100,3)
for i=1,60 do now=now+.016; v:update_scroll(now,false) end
assert(s.start_qn==6 and s.low_pitch==66 and v.scroll_target==nil,'repeated wheel input reaches the accumulated target')
v:wheel_scroll(0,-3); now=now+.016; v:update_scroll(now,false)
v:pan(10,0); assert(v.scroll_target==nil and v.pitch_visual==0,'direct navigation cancels easing')
v:wheel_scroll(0,3); v:update_scroll(now,true); assert(v.scroll_target==nil,'editing cancels easing')
s.smooth_scroll=false; local pitch=s.low_pitch; v:wheel_scroll(0,3); assert(s.low_pitch==pitch+3,'disabled setting scrolls immediately')
s.smooth_scroll=true; v.fold={60,64,67,72,76,79}; v.fold_index={}; for i,p in ipairs(v.fold) do v.fold_index[p]=i end
s.fold_offset=0; v:wheel_scroll(0,100)
for i=1,60 do now=now+.016; v:update_scroll(now,false) end
assert(s.fold_offset==1 and v.pitch_visual==0,'fold scroll clamps and settles')
v.follow_origin=0; v.follow_suspended=false; v:wheel_scroll(-30,0)
assert(v.follow_suspended,'wheel navigation suspends playback follow')
print('PASS smooth scroll: easing, accumulation, hit testing, cancellation, fold bounds and follow')

local function distance(glide,frames)
  now=0
  local settings={smooth_scroll=true,scroll_glide_ms=glide,start_qn=4,visible_qn=4,low_pitch=60,row_height=20}
  local view=V.new(settings); view:set_geometry(0,0,400,100,true,0,20)
  view:wheel_scroll(-100,0)
  for i=1,frames do now=.1*i/frames; view:update_scroll(now,false) end
  return settings.start_qn-4
end
assert(distance(60,6)>distance(200,6) and distance(200,6)>distance(400,6),'longer glide gives gentler movement')
assert(math.abs(distance(200,6)-distance(200,12))<1e-9,'glide is independent of frame rate')
assert(math.abs(distance(200,6)-(1-math.sqrt(.05)))<1e-9,'200 ms glide covers 95 percent in 200 ms')
print('PASS configurable glide duration and frame independence')
