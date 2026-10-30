-- @noindex
local Group=require 'src.expression_group'
local Controls=require 'src.ui.controls'
local M={}
function M.close(app)
  app.expression_group_open=false;app.expression_group_draft=nil;app.expression_group_values=nil
  if app.expression_dimension=='velocity'or app.expression_dimension=='release_velocity'then app.expression_dimension='pitch'end
end
function M.sync_selection(app,count)
  if app.expression_dimension=='velocity'or app.expression_dimension=='release_velocity'then
    app.expression_dimension='pitch';app.expression_group_draft=nil;app.expression_group_values=nil
  end
  if app.expression_group_open and count<2 then
    M.close(app)
    if app.expression_notice=='Select at least two notes to adjust together.'then app.expression_notice=nil end
    return false
  end
  return app.expression_group_open==true
end
function M.draw(app,next_item)
  if not M.sync_selection(app,#require('src.expression_scope').selected(app))then return false end
  local I,c,s=app.ImGui,app.ctx,app.settings
  next_item=next_item or function()I.SameLine(c)end
  if not s.mpe_enabled then app.expression_group_open=false;app.expression_group_draft=nil;return false end
  local signature=Group.signature(app)
  if not app.expression_group_draft or app.expression_group_draft.signature~=signature then
    app.expression_group_draft,app.expression_notice=Group.begin(app)
    app.expression_group_values={};app.expression_group_kind=nil;app.expression_group_gain=1;app.expression_group_offset=0
  end
  local draft=app.expression_group_draft
  if not draft then
    I.TextWrapped(c,app.expression_notice or 'Select at least two MPE notes.')
    if #require('src.expression_scope').selected(app)>0 and I.Button(c,'Make selected notes MPE')then
      local ok,notice=require('src.expression_scope').assign(app);app.expression_notice=notice
      if ok then app.expression_group_draft=nil end
    end
    return true
  end
  local kind=app.expression_dimension or 'pressure'
  if app.expression_group_kind~=kind then
    local values=(app.expression_group_values or {})[kind]or {gain=1,offset=0}
    app.expression_group_gain=values.gain;app.expression_group_offset=values.offset;app.expression_group_kind=kind
  end
  local z=s.ui_scale or 1
  next_item(88*z);I.SetNextItemWidth(c,88*z)
  local changed;changed,app.expression_group_gain=I.DragDouble(c,'##expression_group_depth',app.expression_group_gain,.01,0,2,'Depth %.2fx')
  Controls.number(app,app,'expression_group_gain',1,.05,0,2,'Group depth',true)
  if I.IsItemHovered(c)then I.SetTooltip(c,'Wheel: adjust depth. Right-click: reset. Depth: scale existing expression on all selected notes. Flat curves stay flat. Ctrl-click to type.')end
  next_item(104*z);I.SetNextItemWidth(c,104*z)
  local range=kind=='pitch'and(s.mpe_pitch_bend_range or 48)or 127
  changed,app.expression_group_offset=I.DragDouble(c,'##expression_group_offset',app.expression_group_offset,kind=='pitch'and .1 or 1,-range,range,kind=='pitch'and 'Offset %+.1f st'or 'Offset %+.0f')
  Controls.number(app,app,'expression_group_offset',0,1,-range,range,'Group offset',true)
  if I.IsItemHovered(c)then I.SetTooltip(c,'Wheel: adjust offset. Right-click: reset. Offset: shift every selected envelope by this amount. Ctrl-click to type.')end
  app.expression_group_values=app.expression_group_values or {};app.expression_group_values[kind]={gain=app.expression_group_gain,offset=app.expression_group_offset}
  Group.adjust(draft,s,kind,app.expression_group_offset,app.expression_group_gain)
  next_item(28*z)
  if require('src.ui.icons').button(app,'expression_apply','apply','Apply pending adjustments to every selected note')then
    local ok,notice=Group.apply(app,draft);app.expression_notice=notice
    if ok then M.close(app)end
  end
  if app.expression_notice then I.TextWrapped(c,app.expression_notice)end
  return true
end
return M
