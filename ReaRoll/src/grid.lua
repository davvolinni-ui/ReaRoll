-- @noindex
local M={}
-- Quarter-note values are shared by snapping, drawing and note lengths.
M.division_groups={
 {id='straight',name='Straight',factor=1,suffix='',description=''},
 {id='triplet',name='Triplet',factor=2/3,suffix='T',description=' triplet'},
 {id='dotted',name='Dotted',factor=1.5,suffix='D',description=' dotted'},
}
M.divisions={};M.division_values={};M.base_values={1/32,1/16,1/8,1/4,1/2,1,2,4}
for _,group in ipairs(M.division_groups) do
 group.divisions={}
 for _,denominator in ipairs({1,2,4,8,16,32,64,128}) do
  local entry={label='1/'..denominator..group.description,short='1/'..denominator..group.suffix,qn=4/denominator*group.factor,base=4/denominator,kind=group.id}
  group.divisions[#group.divisions+1]=entry
  M.divisions[#M.divisions+1]=entry
  M.division_values[#M.division_values+1]=entry.qn
 end
end
table.sort(M.division_values)
function M.label(qn)
 for _,entry in ipairs(M.divisions) do if math.abs(entry.qn-qn)<.000001 then return entry.short end end
 return string.format('%.3g QN',qn)
end
function M.factor(kind)
 for _,group in ipairs(M.division_groups) do if group.id==kind then return group.factor end end
 return 1
end
function M.kind(s)
 for _,group in ipairs(M.division_groups) do if s.grid_type==group.id then return group.id end end
 for _,entry in ipairs(M.divisions) do if math.abs(entry.qn-s.grid_qn)<.000001 then return entry.kind end end
 return 'straight'
end
function M.base(s)return s.grid_qn/M.factor(M.kind(s)) end
function M.set_type(s,kind)
 local base=M.base(s)
 s.grid_type=kind;s.grid_qn=base*M.factor(kind)
end
function M.set_base(s,base)
 s.grid_type=M.kind(s);s.grid_qn=base*M.factor(s.grid_type);s.adaptive_grid=false
end
function M.on_line(qn,step)
 local index=qn/step
 return math.abs(index-math.floor(index+.5))<.00001
end
function M.visual_step(qn,px_per_qn)
 local step=qn
 while step*px_per_qn<8 and step<8 do step=step*2 end
 return step
end
function M.resolve(px_per_qn,kind)
  local factor=M.factor(kind)
  local step=1/32*factor
  while step*px_per_qn<24 and step<4*factor do step=step*2 end
  return step
end
function M.update(app,px_per_qn)
  local multi=app.multi_notes
  local editing=app.gesture or multi and (multi.transaction or multi.paint or multi.structure_brush or multi.mute_brush)
  local px=px_per_qn or app.viewport and app.viewport.px_per_qn
  if app.settings.adaptive_grid and not editing and px then
    app.settings.grid_qn=M.resolve(px,M.kind(app.settings))
  end
end
function M.note_length(settings)
  return (settings.mode=='paint' or settings.length_follow_grid) and settings.grid_qn or settings.length_qn
end
return M
