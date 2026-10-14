-- @noindex
local Shortcuts=require 'src.shortcuts'
local Mouse=require 'src.mouse'
local Canvas=require 'src.ui.canvas'
local Selection=require 'src.selection'
local function up(fn,name)
  for i=1,100 do local key,value=debug.getupvalue(fn,i); if key==name then return value end end
  error('missing '..name)
end
local begin=up(Canvas.draw,'begin_gesture')
local update=up(Canvas.draw,'update_gesture')
local state={}
reaper={GetExtState=function(_,key)return state[key] or '' end,SetExtState=function(_,key,value)state[key]=value end,
  MIDI_GetProjQNFromPPQPos=function(_,p)return p/960 end,MIDI_GetPPQPosFromProjQN=function(_,q)return q*960 end}
local settings={}
Shortcuts.load(settings)
assert(settings.input_preset=='default' and settings.shortcuts.duplicate=='Ctrl+B','new users retain ReaRoll defaults')
local choices={}; for _,binding in ipairs(Shortcuts.choices) do choices[binding]=true end
for _,id in ipairs(Shortcuts.preset_order) do
  assert(Shortcuts.apply_preset(settings,id))
  local used={}
  for action,binding in pairs(settings.shortcuts) do
    assert(choices[binding],id..' has an uneditable binding '..binding)
    if binding~='None' then assert(not used[binding],id..' conflicts on '..binding); used[binding]=action end
  end
  Shortcuts.save(settings); local loaded={}; Shortcuts.load(loaded)
  assert(loaded.input_preset==id)
  for action,binding in pairs(settings.shortcuts) do assert(loaded.shortcuts[action]==binding) end
  for key,value in pairs(settings.mouse) do assert(loaded.mouse[key]==value) end
end
settings.shortcuts.duplicate='Alt+Q'; settings.mouse.clone='Alt'; settings.input_preset='custom'
Shortcuts.save(settings); Shortcuts.load(settings)
assert(settings.shortcuts.duplicate=='Alt+Q' and settings.mouse.clone=='Alt' and settings.input_preset=='custom','custom edits survive reload')
state.mouse_clone='invalid'; Shortcuts.load(settings); assert(settings.mouse.clone=='Shift','invalid persisted mouse bindings recover')
state={shortcut_schema='2',shortcut_duplicate='Ctrl+R'}; Shortcuts.load(settings)
assert(settings.shortcuts.duplicate=='Ctrl+R' and settings.input_preset=='custom','existing custom keymaps migrate without replacement')
local v={ppq_per_qn=960,qn_from_x=function(_,x)return x/100 end,pitch_from_y=function()return 60 end}
local note={id='a',index=0,s=0,e=960,pitch=60,vel=90,chan=0}
for _,id in ipairs(Shortcuts.preset_order) do
  local s={mode='smart',grid_qn=.25,snap_mode='absolute'}; Shortcuts.apply_preset(s,id)
  local app={settings=s,selection=Selection.new(),cache={notes={note},get=function()return {note} end},edit={begin=function()end},audition={play=function()end}}
  local clone={ctrl=false,shift=false,alt=false}; clone[s.mouse.clone:lower()]=true
  begin(app,true,v,{note},note,nil,20,20,clone)
  assert(app.gesture and app.gesture.kind=='copy_pending',id..' clone modifier starts duplication')
  app.gesture=nil
  local select={ctrl=false,shift=false,alt=false}; select[s.mouse.select:lower()]=true
  begin(app,true,v,{note},note,nil,20,20,select)
  assert(not app.gesture and Selection.has(app.selection,'a'),id..' selection modifier must not move notes')
  if id=='live' then
    begin(app,true,v,{note},nil,nil,20,20,{ctrl=false,shift=false,alt=false})
    assert(app.gesture.kind=='marquee','Live empty drag selects instead of drawing')
    app.gesture=nil; app.item_start_qn,app.item_end_qn=0,8
    app.settings.velocity=90; app.settings.channel=0; app.settings.length_qn=.25
    app.edit.note_count=function()return 1 end
    local inserted
    app.edit.insert=function(_,_,start,ending)inserted={start,ending} end
    begin(app,true,v,{note},nil,nil,20,20,{ctrl=false,shift=false,alt=false},true)
    assert(app.gesture.kind=='draw' and inserted[1]==240 and inserted[2]==480,'Live empty double-click inserts a snapped note')
    local keyboard={settings=s,ctx={},ImGui={Key_4=4,IsKeyPressed=function(_,key,repeat_key)assert(repeat_key==false);return key==4 end}}
    assert(Shortcuts.pressed(keyboard,'snap',{ctrl=true,alt=false,shift=false}),'Live Ctrl+4 must reach the snap command')
  end
  -- Resize uses the chosen bypass modifier after the gesture starts.
  local ending
  app.edit.set=function(_,_,_,_,e)ending=e end
  app.gesture={kind='resize',edge='right',anchor_qn=0,items={{index=0,s=0,e=960,note={e=960}}}}
  app.item_start_qn,app.item_end_qn=0,8
  local bypass={ctrl=false,shift=false,alt=false}; bypass[s.mouse.unsnap:lower()]=true
  update(app,true,v,13,20,bypass)
  assert(math.abs(ending-1084.8)<.001,id..' bypass modifier must disable snap during resize')
end
print('PASS: preset bindings, conflict freedom, migration, persistence, clone/selection and unsnapped resize')
