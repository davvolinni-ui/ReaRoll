-- @noindex
local M={}

M.defaults={
  select_all='Ctrl+A',deselect='Ctrl+D',copy='Ctrl+C',cut='Ctrl+X',paste='Ctrl+V',duplicate='Ctrl+B',
  undo='Ctrl+Z',redo='Ctrl+Shift+Z',delete='Delete',cancel='Escape',play='Space',
  quantize='Ctrl+U',legato='Ctrl+L',snap='Backspace',fit_width='W',fit_height='H',fit_selection='Z',
  zoom_in='PageUp',zoom_out='PageDown',nudge_left='LeftArrow',nudge_right='RightArrow',pitch_up='UpArrow',pitch_down='DownArrow',
  length_shorter='Shift+LeftArrow',length_longer='Shift+RightArrow',octave_up='Shift+UpArrow',octave_down='Shift+DownArrow',velocity_up='Ctrl+UpArrow',velocity_down='Ctrl+DownArrow',
  duplicate_octave_up='Ctrl+Shift+UpArrow',duplicate_octave_down='Ctrl+Shift+DownArrow',
  reaper_action_1='None',reaper_action_2='None',reaper_action_3='None',reaper_action_4='None',
  tool_smart='P',tool_paint='B',tool_select='E',tool_slice='C',tool_mute='T',tool_chord='S',
}
M.labels={
  select_all='Select all',deselect='Deselect',copy='Copy',cut='Cut',paste='Paste',duplicate='Duplicate to right',undo='Undo',redo='Redo',delete='Delete',cancel='Cancel / deselect',play='Play / pause',
  quantize='Quantize starts',legato='Legato',snap='Toggle snap',fit_width='Fit time',fit_height='Fit pitches',fit_selection='Fit selection',
  zoom_in='Zoom time in',zoom_out='Zoom time out',nudge_left='Move left by grid',nudge_right='Move right by grid',pitch_up='Transpose semitone up',pitch_down='Transpose semitone down',
  length_shorter='Shorten by grid',length_longer='Lengthen by grid',octave_up='Transpose octave up',octave_down='Transpose octave down',velocity_up='Velocity up',velocity_down='Velocity down',
  duplicate_octave_up='Duplicate octave up',duplicate_octave_down='Duplicate octave down',
  reaper_action_1='Run REAPER action 1',reaper_action_2='Run REAPER action 2',reaper_action_3='Run REAPER action 3',reaper_action_4='Run REAPER action 4',
  tool_smart='Smart tool',tool_paint='Paint tool',tool_select='Select tool',tool_slice='Slice tool',tool_mute='Mute tool',tool_chord='Chord tool',
}
M.order={'select_all','deselect','copy','cut','paste','duplicate','duplicate_octave_up','duplicate_octave_down','undo','redo','delete','cancel','play','quantize','legato','snap','fit_width','fit_height','fit_selection','zoom_in','zoom_out','nudge_left','nudge_right','pitch_up','pitch_down','length_shorter','length_longer','octave_up','octave_down','velocity_up','velocity_down','tool_smart','tool_paint','tool_select','tool_slice','tool_mute','tool_chord','reaper_action_1','reaper_action_2','reaper_action_3','reaper_action_4'}
M.choices={'None','Space','Delete','Escape','Backspace','PageUp','PageDown','LeftArrow','RightArrow','UpArrow','DownArrow','A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z','Shift+LeftArrow','Shift+RightArrow','Shift+UpArrow','Shift+DownArrow','Ctrl+UpArrow','Ctrl+DownArrow','Ctrl+Shift+UpArrow','Ctrl+Shift+DownArrow','Ctrl+A','Ctrl+B','Ctrl+C','Ctrl+D','Ctrl+E','Ctrl+F','Ctrl+G','Ctrl+H','Ctrl+I','Ctrl+J','Ctrl+K','Ctrl+L','Ctrl+M','Ctrl+N','Ctrl+O','Ctrl+P','Ctrl+Q','Ctrl+R','Ctrl+S','Ctrl+T','Ctrl+U','Ctrl+V','Ctrl+W','Ctrl+X','Ctrl+Y','Ctrl+Z','Ctrl+Shift+Z'}

function M.load(settings)
  settings.shortcuts={}; local schema=tonumber(reaper.GetExtState('ReaRoll','shortcut_schema')) or 0
  for action,default in pairs(M.defaults) do
    local value=reaper.GetExtState('ReaRoll','shortcut_'..action)
    settings.shortcuts[action]=schema>=2 and value~='' and value or default
  end
end
function M.save(settings)
  reaper.SetExtState('ReaRoll','shortcut_schema','2',true)
  for action,default in pairs(M.defaults) do reaper.SetExtState('ReaRoll','shortcut_'..action,settings.shortcuts[action] or default,true) end
end
local function parse(binding)
  local ctrl,shift,alt=false,false,false; local key
  for part in binding:gmatch('[^+]+') do
    if part=='Ctrl' then ctrl=true elseif part=='Shift' then shift=true elseif part=='Alt' then alt=true else key=part end
  end
  return key,ctrl,shift,alt
end
function M.pressed(app,action,mods)
  local binding=app.settings.shortcuts and app.settings.shortcuts[action] or M.defaults[action]
  if not binding or binding=='None' then return false end
  local key,ctrl,shift,alt=parse(binding); local code=key and app.ImGui['Key_'..key]
  -- ReaImGui's repeat default has changed across releases.  Editor commands
  -- must fire once per physical press: repeating Undo is especially dangerous
  -- because one ordinary key hold can otherwise walk back through many edits.
  return code and mods.ctrl==ctrl and mods.shift==shift and mods.alt==alt and app.ImGui.IsKeyPressed(app.ctx,code,false)
end
return M
