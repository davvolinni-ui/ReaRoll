-- @noindex
local Grid=require 'src.grid'
local Controls=require 'src.ui.controls'
local M={width=84}
local rhythms={'straight','triplet','dotted'}
local function length_label(s)
 if s.mode=='paint' or s.length_follow_grid then return 'Grid' end
 return Grid.label(Grid.note_length(s))
end
local function set_length(s,base,kind)
 s.length_qn=base*Grid.factor(kind);s.length_follow_grid=false;s.inherit_length=false
end
local function rhythm_row(app,id,current,apply)
 local I,c=app.ImGui,app.ctx
 for index,group in ipairs(Grid.division_groups) do
  if index>1 then I.SameLine(c) end
  local label=group.name..(id=='' and '' or '##'..id)
  if I.RadioButton(c,label,current==group.id) then current=group.id;apply(current) end
  local value,changed=Controls.cycle(app,rhythms,current)
  if changed then current=value;apply(current) end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Wheel: Straight / Triplet / Dotted.') end
 end
end
function M.draw(app,z)
 local I,c,s=app.ImGui,app.ctx,app.settings
 local kind=Grid.kind(s)
 local rhythm=kind:sub(1,1):upper()..kind:sub(2)
 local size=s.adaptive_grid and 'Auto' or Grid.label(Grid.base(s))
 I.SetNextItemWidth(c,M.width*z)
 if I.SetNextWindowSizeConstraints then I.SetNextWindowSizeConstraints(c,300*z,0,420*z,500*z) end
 local caption=size..(kind=='triplet' and ' T' or kind=='dotted' and ' D' or '')
 if I.BeginCombo(c,'##toolbar_grid_combo',caption) then
  I.TextDisabled(c,'Grid')
  I.SetNextItemWidth(c,160*z)
  if I.BeginCombo(c,'##grid_size',s.adaptive_grid and 'Auto' or Grid.label(Grid.base(s))) then
   if I.Selectable(c,'Auto',s.adaptive_grid) then s.adaptive_grid=true;Grid.update(app) end
   for _,value in ipairs(Grid.base_values) do
    if I.Selectable(c,Grid.label(value),not s.adaptive_grid and math.abs(Grid.base(s)-value)<.000001) then Grid.set_base(s,value) end
   end
   I.EndCombo(c)
  end
  local grid_size={value=Grid.base(s)}
  if Controls.choice(app,grid_size,'value',.25,Grid.base_values,'Grid size') then Grid.set_base(s,grid_size.value) end
  rhythm_row(app,'',Grid.kind(s),function(value)Grid.set_type(s,value);Grid.update(app)end)
  I.Separator(c);I.TextDisabled(c,'Note length')
  I.BeginDisabled(c,s.mode=='paint')
  local follow=s.length_follow_grid==true
  if I.RadioButton(c,'Follow grid',follow) then s.length_follow_grid=true;s.inherit_length=false end
  I.SameLine(c)
  if I.RadioButton(c,'Fixed',not follow and not s.inherit_length) then s.length_qn=Grid.note_length(s);s.length_follow_grid=false;s.inherit_length=false end
  I.SameLine(c)
  if I.RadioButton(c,'Learn from notes',not follow and s.inherit_length==true) then s.length_follow_grid=false;s.inherit_length=true end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Learn length from clicked notes.') end
  if not s.length_follow_grid and not s.inherit_length then
   local length_kind=Grid.kind({grid_qn=s.length_qn})
   local base=s.length_qn/Grid.factor(length_kind)
   I.SetNextItemWidth(c,160*z)
   if I.BeginCombo(c,'##insert_length',Grid.label(base)) then
    for _,value in ipairs(Grid.base_values) do
     if I.Selectable(c,Grid.label(value),math.abs(value-base)<.000001) then set_length(s,value,length_kind) end
    end
    I.EndCombo(c)
   end
   local length_size={value=s.length_qn/Grid.factor(length_kind)}
   if Controls.choice(app,length_size,'value',.25,Grid.base_values,'Note length') then set_length(s,length_size.value,length_kind) end
   rhythm_row(app,'length_rhythm',length_kind,function(value)set_length(s,s.length_qn/Grid.factor(length_kind),value);length_kind=value end)
  end
  I.EndDisabled(c)
  if s.mode=='paint' then I.TextDisabled(c,'Paint notes always follow the grid.') end
  I.EndCombo(c)
 else
  local value={size=Grid.base(s)}
  if Controls.choice(app,value,'size',.25,Grid.base_values,'Grid size',true) then Grid.set_base(s,value.size) end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Grid: '..size..' · '..rhythm..' ('..Grid.label(s.grid_qn)..')\nWheel: grid size. Open for rhythm and note length.\nWheel over the rhythm choices to cycle Straight / Triplet / Dotted.\nNote length: '..length_label(s)..'. Snap uses the displayed grid spacing.') end
 end
end
return M
