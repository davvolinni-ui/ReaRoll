-- @noindex
local M={}
-- Each row is centered inside the space reserved between the two anchors.
function M.plan(slots,left,right,top,height,row_gap)
  local rows={{slots={},width=0}};local available=math.max(1,right-left)
  for _,slot in ipairs(slots)do
    local row=rows[#rows];local gap=#row.slots>0 and slot.gap or 0
    if #row.slots>0 and row.width+gap+slot.width>available then
      row={slots={},width=0};rows[#rows+1]=row;gap=0
    end
    row.slots[#row.slots+1]={offset=row.width+gap,width=slot.width}
    row.width=row.width+gap+slot.width
  end
  local positions={}
  for index,row in ipairs(rows)do
    local x=left+math.max(0,(available-row.width)*.5)
    for _,slot in ipairs(row.slots)do positions[#positions+1]={x=x+slot.offset,y=top+(index-1)*(height+row_gap),width=slot.width}end
  end
  return positions,top+(#rows-1)*(height+row_gap)+height,rows
end
function M.new(app,slots)
  local I,c=app.ImGui,app.ctx;local z=math.max(.8,math.min(1.5,app.settings.ui_scale or 1))
  local x,y=I.GetCursorScreenPos(c);local width=I.GetContentRegionAvail(c)
  local anchor=28*z;local gap=8*z
  local positions,bottom=M.plan(slots,x+anchor+gap,x+width-anchor-gap,y,math.max(26*z,I.GetFrameHeight(c)),6*z)
  local layout={index=0}
  function layout:next()
    self.index=self.index+1;local position=assert(positions[self.index],'Unplanned toolbar control')
    I.SetCursorScreenPos(c,position.x,position.y)
  end
  function layout:menu()I.SetCursorScreenPos(c,x+width-anchor,y)end
  function layout:finish()
    assert(self.index==#positions,'Toolbar control missing from layout')
    I.SetCursorScreenPos(c,x,bottom);I.Dummy(c,width,0)
  end
  return layout
end
return M
