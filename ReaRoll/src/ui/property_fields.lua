-- @noindex
local Controls=require 'src.ui.controls'
local M={}
function M.row(app,label)
  local I,c=app.ImGui,app.ctx;local z=app.settings.ui_scale or 1
  local x=I.GetCursorPosX(c);local width=I.GetContentRegionAvail(c)
  I.AlignTextToFramePadding(c);I.Text(c,label)
  I.SameLine(c,x+math.min(94*z,width*.49));I.SetNextItemWidth(c,-1)
end
function M.number(app,draft,key,label,integer,mixed,tip,minimum,maximum)
  local I,c=app.ImGui,app.ctx
  draft.text=draft.text or {};draft.initial=draft.initial or {};draft.invalid=draft.invalid or {}
  local function formatted(value)return integer and tostring(value)or string.format('%.4f',value)end
  if draft.initial[key]==nil then draft.initial[key]=draft[key]end
  if draft.text[key]==nil then draft.text[key]=mixed and ''or formatted(draft[key])end
  M.row(app,label)
  local changed,text=I.InputTextWithHint(c,'##property_'..key,mixed and 'Mixed'or '',draft.text[key])
  if changed then
    draft.text[key]=text
    if mixed and text==''then draft.dirty[key]=nil;draft.invalid[key]=nil
    else
      local value=tonumber(text)
      local valid=value and value==value and math.abs(value)~=math.huge and(not integer or value%1==0)
        and(not minimum or value>=minimum)and(not maximum or value<=maximum)
      draft.dirty[key]=true;draft.invalid[key]=not valid or nil
      if valid then draft[key]=value end
    end
  end
  local wheel,reset=Controls.input(app,label,draft[key],draft.initial[key],true)
  if reset then
    draft[key]=draft.initial[key];draft.text[key]=mixed and ''or formatted(draft[key]);draft.dirty[key]=nil;draft.invalid[key]=nil
  elseif wheel~=0 then
    local value=draft[key]+(wheel>0 and 1 or -1)*(integer and 1 or app.settings.grid_qn or .25)
    value=math.max(minimum or -math.huge,math.min(maximum or math.huge,value))
    draft[key]=value;draft.text[key]=formatted(value);draft.dirty[key]=true;draft.invalid[key]=nil
  end
  if I.IsItemHovered(c)then
    I.SetTooltip(c,(draft.invalid[key]and 'Enter a valid '..(integer and 'whole number.\n'or 'number.\n')or '')..tip..'\nWheel: adjust. Right-click: revert this field.')
  end
end
return M
