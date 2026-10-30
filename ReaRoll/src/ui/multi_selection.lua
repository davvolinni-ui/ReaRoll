-- @noindex
local Model=require 'src.multi_notes'
local M={}
function M.begin(app,v,mx,my,button,add)
  local state=app.multi_notes;local base={};local previous={}
  for key,value in pairs(state.selection)do previous[key]=value;if add then base[key]=value end end
  state.marquee={x=mx,y=my,qn=v:qn_from_x(mx),pitch=v:pitch_from_y(my),button=button,base=base,previous=previous}
  app.gesture={kind='source_marquee',button=button}
  app.multi_controller_point_focus=false;app.controller_point_focus_key=nil;app.controller_selection_active=false
end
function M.bounds(app,v,mx,my)
  local m=app.multi_notes.marquee
  return v:x_from_qn(m.qn),v:y_from_pitch_unclipped(m.pitch),mx,my
end
function M.update(app,v,mx,my)
  local state=app.multi_notes;local m=state.marquee;if not m then return end
  local I,c=app.ImGui,app.ctx
  if I.IsKeyPressed(c,I.Key_Escape)then state.selection=m.previous;state.marquee=nil;app.gesture=nil;Model.sync(app);return end
  local ax,ay,bx,by=M.bounds(app,v,mx,my)
  state.selection={};for key,value in pairs(m.base)do state.selection[key]=value end
  for _,n in ipairs(state.notes)do
    local top=v:y_from_pitch(n.pitch)
    if not n.source.readonly and(app.settings.edit_all_channels~=false or n.chan==(app.settings.channel or 0))and top
      and v:x_from_qn(n.e)>=math.min(ax,bx)and v:x_from_qn(n.s)<=math.max(ax,bx)
      and top+app.settings.row_height>=math.min(ay,by)and top<=math.max(ay,by)then state.selection[n.key]=true end
  end
  Model.sync(app)
  if I.IsMouseReleased(c,m.button)then state.marquee=nil;app.gesture=nil end
end
return M
