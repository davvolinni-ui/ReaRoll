-- @noindex
local V=require 'src.viewport'
local now=0
reaper={time_precise=function() return now end,MIDI_GetPPQPosFromProjQN=function(_,q)return q*960 end}
local function setup(fold)
  now=0
  local s={smooth_scroll=true,scroll_glide_ms=200,start_qn=8,visible_qn=8,low_pitch=48,row_height=14,fold_offset=20,fold_enabled=fold,follow_playback=true,follow_style='page'}
  local v=V.new(s); v:set_geometry(0,0,800,280,true,0,64)
  if fold then local notes={}; for p=0,127,2 do notes[#notes+1]={pitch=p} end; v:set_fold(notes) end
  return v,s
end
local v,s=setup(false)
local q=v:qn_from_x(560)
v:wheel_zoom_time(.82,560);v:wheel_zoom_time(.82,560)
assert(s.visible_qn==8,'wheel zoom queues changes')
for i=1,160 do
  now=i/60;v:update_wheel_zoom(now,false);v:set_geometry(0,0,800,280,true,0,64)
  assert(math.abs(v:qn_from_x(560)-q)<1e-9,'time focus stays under mouse throughout easing')
end
assert(math.abs(s.visible_qn-8*.82*.82)<1e-9 and not v.zoom_target,'repeated zoom reaches accumulated target')
for _,fold in ipairs({false,true}) do
  v,s=setup(fold)
  local p=v:pitch_from_y(140);local y=v:y_from_pitch_unclipped(p)
  v:wheel_zoom_pitch(1.12,140)
  for i=1,8 do
    now=i/60; v:update_wheel_zoom(now,false);v:set_geometry(0,0,800,280,true,0,64)
    local expected=140+(y-140)*s.row_height/14
    assert(math.abs(v:y_from_pitch_unclipped(p)-expected)<1e-8,'pitch focus stays anchored across row-count changes')
  end
  for i=9,160 do now=i/60;v:update_wheel_zoom(now,false) end
  assert(math.abs(s.row_height-14*1.12)<1e-9 and not v.zoom_target,'pitch zoom settles')
end
-- Match canvas layout with the lane open: it rounds grid height before the
-- animation tick, then applies geometry again using that same frame's height.
for _,fold in ipairs({false,true}) do
  for _,factor in ipairs({1.12,.89}) do
    v,s=setup(fold)
    local my=137
    v:wheel_zoom_pitch(factor,my); v:wheel_zoom_pitch(factor,my)
    local target=14*factor*factor
    local focus=v.zoom_target.value
    for i=1,160 do
      local height=math.floor(285/s.row_height)*s.row_height
      v:set_geometry(0,0,800,height,true,0,64)
      local previous=s.row_height
      now=i/60; v:update_wheel_zoom(now,false)
      v:set_geometry(0,0,800,height,true,0,64)
      if v.zoom_target then
        assert(math.abs(s.row_height-target)<math.abs(previous-target),'lane layout interrupted pitch glide')
        local key=fold and 'fold_offset' or 'low_pitch'
        local coordinate=s[key]+(v.pitch_visual or 0)+(fold and v:rows() or v:rows()-1)-my/s.row_height
        assert(math.abs(coordinate-focus)<1e-8,'lane layout moved smooth pitch focus')
      end
    end
    assert(math.abs(s.row_height-target)<1e-9 and not v.zoom_target,'lane layout reset final zoom height')
  end
end
v,s=setup(false);v:update_follow(1,10);v:wheel_zoom_time(.82,560)
for i=1,15 do now=i/60;v:update_wheel_zoom(now,false);v:set_geometry(0,0,800,280,true,0,64);v:update_follow(1,10+i/60) end
assert(not v.follow_suspended,'smooth zoom preserves playback follow')
v:pan(10,0);assert(not v.zoom_target,'direct pan cancels smooth zoom')
v:wheel_zoom_pitch(1.12,140);v:wheel_scroll(-50,0);assert(not v.zoom_target,'scrolling cancels zoom')
v:wheel_zoom_time(.82,560);v:update_wheel_zoom(now,true);assert(not v.zoom_target,'editing cancels zoom')
v:wheel_zoom_time(.82,560);v:zoom_time(1.22,560);assert(not v.zoom_target,'direct zoom cancels wheel animation')
s.smooth_scroll=false;local before=s.row_height;v:wheel_zoom_pitch(1.12,140);assert(s.row_height==before*1.12,'disabled smoothing uses direct zoom')
print('PASS smooth modifier zoom: accumulation, timeline/pitch anchors, folded rows, follow and cancellation')
