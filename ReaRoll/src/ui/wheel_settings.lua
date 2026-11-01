-- @noindex
local Wheel=require 'src.wheel'
local M={}
local names={['Scroll pitches']='Scroll up / down',['Scroll time']='Scroll left / right',['Zoom time']='Zoom horizontally',['Zoom pitch']='Zoom vertically',['Adjust note property']='Adjust note value',['Divide selection']='Change note divisions',['Disabled']='Do nothing'}
local function row(app,context,axis,mask,linked)
 local I,c,s=app.ImGui,app.ctx,app.settings
 local key=context..'_'..axis..'_'..mask
 local gesture=mask==0 and 'Wheel' or Wheel.display(Wheel.modifiers[mask+1]):gsub('%+',' + ')..' + wheel'
 if axis=='h' then gesture=mask==0 and 'Horizontal wheel' or gesture:gsub('wheel$','horizontal wheel') end
 I.Text(c,gesture)
 if mask~=7 then I.SameLine(c,210) end
 I.SetNextItemWidth(c,170)
 local current=Wheel.value(s,key)
 if I.BeginCombo(c,'##wheel_'..key,names[current] or current) then
  for _,action in ipairs(Wheel.actions) do
   if (context=='grid' or action~='Adjust note property' and action~='Divide selection') and I.Selectable(c,names[action],current==action) then
    s.wheel[key]=action; s.input_preset='custom'
    if linked and mask~=0 then s.wheel[context..'_h_'..mask]=action end
   end
  end
  I.EndCombo(c)
 end
 I.SameLine(c)
 local changed,reverse=I.Checkbox(c,'Reverse##wheel_'..key,s.wheel[key..'_reverse']=='1')
 if changed then
  s.input_preset='custom'
  s.wheel[key..'_reverse']=reverse and '1' or '0'
  if linked and mask~=0 then s.wheel[context..'_h_'..mask..'_reverse']=s.wheel[key..'_reverse'] end
 end
end
function M.draw(app)
 local I,c,s=app.ImGui,app.ctx,app.settings
 s.wheel=s.wheel or {}
 I.Separator(c);I.Text(c,'Mouse wheel and zoom')
 I.TextWrapped(c,'Choose what each wheel gesture does over the notes. Reverse flips its direction.')
 for _,mask in ipairs({0,1,4,5,2}) do row(app,'grid','v',mask,true) end
 I.TextWrapped(c,'Changing a modifier gesture here also updates its horizontal wheel action. Advanced lets you set them separately.')
 if I.CollapsingHeader(c,'Advanced wheel settings') then
  I.Text(c,'More gestures over notes')
  for _,mask in ipairs({3,6,7}) do row(app,'grid','v',mask) end
  I.TextWrapped(c,'Horizontal wheel / trackpad: macOS may send Shift + wheel here. Customize these if your mouse reports sideways movement.')
  for mask=0,7 do row(app,'grid','h',mask) end
  for _,context in ipairs({'keys','empty'}) do
   if I.CollapsingHeader(c,Wheel.context_labels[context]..'##wheel_area') then
    I.Text(c,'Wheel')
    for mask=0,7 do row(app,context,'v',mask) end
    I.Text(c,'Horizontal wheel / trackpad')
    for mask=0,7 do row(app,context,'h',mask) end
   end
  end
 end
 if I.Button(c,'Reset wheel settings') then s.wheel={};s.input_preset='custom' end
end
return M
