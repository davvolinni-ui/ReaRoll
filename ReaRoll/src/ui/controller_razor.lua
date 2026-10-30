-- @noindex
local U=require 'src.util'
local Shortcuts=require 'src.shortcuts'
local Model=require 'src.controller_razor'
local Areas=require 'src.controller_areas'
local M={}
function M.draw(app,v,d,lane,top,height,hovered,mx,my)
  if app.settings.mode~='razor' then app.controller_razor_drag=nil;return false end
  if not (lane.cc~=nil or lane.pitch or lane.status==0xD0) or lane.protected or lane.discrete then return false end
  local I,c,s,T=app.ImGui,app.ctx,app.settings,app.theme;local mods=U.mods(I,c)
  local function qn()
    local q=v:qn_from_x(mx)
    if s.snap_enabled and not mods.alt then q=U.snap(q,s.grid_qn)end
    return U.clamp(q,app.item_start_qn,app.item_end_qn)
  end
  local area=app.controller_razor
  local owns=area and area.lane.id==lane.id and area.channel==s.channel
  if hovered and I.IsMouseClicked(c,I.MouseButton_Left) and not app.gesture then
    owns=owns and mx>=v:x_from_qn(area.start_qn)-6 and mx<=v:x_from_qn(area.end_qn)+6
    local saved={table.unpack(app.controller_razor_areas or {})};local original=area
    if not owns then
      local chosen
      for index,candidate in ipairs(app.controller_razor_areas or {})do
        if candidate.lane.id==lane.id and candidate.channel==s.channel and mx>=v:x_from_qn(candidate.start_qn)-6 and mx<=v:x_from_qn(candidate.end_qn)+6 then chosen=index;break end
      end
      if chosen then
        local candidate=app.controller_razor_areas[chosen]
        table.remove(app.controller_razor_areas,chosen)
        if area then app.controller_razor_areas[#app.controller_razor_areas+1]=area end
        area=candidate;app.controller_razor=area;owns=true
      elseif mods.shift then
        app.controller_razor_areas=Areas.list(app)
      else app.controller_razor_areas={}end
    end
    app.razor_focus='controller';app.controller_selection_active=true;app.controller_lane=lane
    local q=qn();local edge
    if owns and math.abs(mx-v:x_from_qn(area.start_qn))<=6 then edge='left'
    elseif owns and math.abs(mx-v:x_from_qn(area.end_qn))<=6 then edge='right'end
    local _,hash=reaper.MIDI_GetHash(app.take,false,'')
    app.controller_razor_drag={anchor=q,old=area,original=original,saved=saved,move=owns and q>area.start_qn and q<area.end_qn and not edge,edge=edge,stretch=edge and mods.shift,copy=mods.ctrl,hash=hash,lane=lane,channel=s.channel}
  end
  local drag=app.controller_razor_drag
  if drag and drag.lane.id==lane.id and drag.channel==s.channel then
    local q=qn();local a=drag.old
    local first,last
    if drag.edge then
      local minimum=math.min(a.end_qn-a.start_qn,s.snap_enabled and not mods.alt and s.grid_qn or .001)
      first=drag.edge=='left' and math.min(q,a.end_qn-minimum) or a.start_qn
      last=drag.edge=='right' and math.max(q,a.start_qn+minimum) or a.end_qn
    elseif drag.move then
      local delta=U.clamp(q-drag.anchor,app.item_start_qn-a.start_qn,app.item_end_qn-a.end_qn)
      first,last=a.start_qn+delta,a.end_qn+delta
    else first,last=math.min(q,drag.anchor),math.max(q,drag.anchor)end
    area={start_qn=first,end_qn=last,lane=lane,channel=s.channel,identity=(drag.move or drag.edge)and(drag.old.identity or drag.old)or drag};app.controller_razor=area;owns=true
    if I.IsMouseReleased(c,I.MouseButton_Left) then
      local _,hash=reaper.MIDI_GetHash(app.take,false,'')
      if hash~=drag.hash then app.controller_razor=drag.original;app.controller_razor_areas=drag.saved;app.controller_razor_notice='The MIDI changed during this drag; no area edit was applied.'
      elseif (drag.move and math.abs(first-a.start_qn)>1e-9)or (drag.stretch and (math.abs(first-a.start_qn)>1e-9 or math.abs(last-a.end_qn)>1e-9))then
        local operation=drag.stretch and 'stretch' or drag.copy and 'copy' or 'move'
        local scale=drag.stretch and (last-first)/(a.end_qn-a.start_qn) or 1
        local ok,notice=Model.apply(app,a,operation,first-a.start_qn,scale)
        app.controller_razor_notice=notice;if not ok then app.controller_razor=drag.old end
      end
      app.controller_razor_drag=nil
    end
  end
  if owns and app.razor_focus=='controller' and I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows) and (drag or not I.IsAnyItemActive(c))then
    if Shortcuts.pressed(app,'cancel',mods)then app.controller_razor=drag and drag.original or nil;app.controller_razor_areas=drag and drag.saved or {};app.controller_razor_drag=nil
    elseif not drag then
      local mixed=app.mixed_razor and app.razor_area
      local parent=app.multi_controller_parent
      if parent and(Shortcuts.pressed(app,'copy',mods)or Shortcuts.pressed(app,'cut',mods))then
        local engine=require('src.multi_controller_razor')
        local notes=parent.mixed_razor and require('src.mixed_razor').note_areas(parent)or {}
        local ok,notice=engine.copy(parent,notes)
        if ok and Shortcuts.pressed(app,'cut',mods)then ok,notice=engine.apply(parent,notes,'delete')end
        app.razor_clipboard=parent.razor_clipboard;app.controller_razor_notice=notice
      elseif parent and Shortcuts.pressed(app,'paste',mods)then
        local ok,notice=require('src.razor').paste(parent,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()))
        app.razor_clipboard=parent.razor_clipboard;app.controller_razor_notice=notice
      elseif mixed and Shortcuts.pressed(app,'copy',mods)then
        local _,notice=require('src.mixed_razor').copy(app,require('src.mixed_razor').note_areas(app));app.controller_razor_notice=notice
      elseif mixed and Shortcuts.pressed(app,'cut',mods)then
        local ok,notice=require('src.mixed_razor').copy(app,require('src.mixed_razor').note_areas(app))
        if ok then ok,notice=Model.apply(app,area,'delete')end;app.controller_razor_notice=notice
      elseif mixed and Shortcuts.pressed(app,'paste',mods)then
        local _,notice=require('src.razor').paste(app,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()));app.controller_razor_notice=notice
      elseif Shortcuts.pressed(app,'copy',mods)or Shortcuts.pressed(app,'cut',mods)then
        local ok,notice=Model.copy(app)
        if ok and Shortcuts.pressed(app,'cut',mods)then ok,notice=Model.apply(app,area,'delete')end
        app.controller_razor_notice=notice
      elseif Shortcuts.pressed(app,'paste',mods)then
        local _,notice=require('src.razor').paste(app,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()));app.controller_razor_notice=notice
      elseif Shortcuts.pressed(app,'delete',mods)then local _,notice=Model.apply(app,area,'delete');app.controller_razor_notice=notice
      elseif Shortcuts.pressed(app,'duplicate',mods)then
        local span=area.end_qn-area.start_qn;local ok,notice=Model.apply(app,area,'copy',span);app.controller_razor_notice=notice
        if ok then app.controller_razor={start_qn=area.start_qn+span,end_qn=area.end_qn+span,lane=lane,channel=s.channel}end
      elseif Shortcuts.pressed(app,'undo',mods)then reaper.Undo_DoUndo2(0);app.cache:invalidate();app.cc_cache:invalidate()
      elseif Shortcuts.pressed(app,'redo',mods)then reaper.Undo_DoRedo2(0);app.cache:invalidate();app.cc_cache:invalidate()end
    end
  end
  area=app.controller_razor
  for _,saved in ipairs(Areas.list(app))do if saved~=area and saved.lane.id==lane.id and saved.channel==s.channel then
    I.DrawList_PushClipRect(d,v.x,top,v.x+v.w,top+height,true)
    I.DrawList_AddRectFilled(d,v:x_from_qn(saved.start_qn),top,v:x_from_qn(saved.end_qn),top+height,T.marquee_fill)
    I.DrawList_AddRect(d,v:x_from_qn(saved.start_qn),top,v:x_from_qn(saved.end_qn),top+height,T.marquee_edge,0,0,2)
    I.DrawList_PopClipRect(d)
  end end
  if area and app.razor_focus=='controller' then app.lane_time_selection={start_qn=area.start_qn,end_qn=area.end_qn}end
  if area and area.lane.id==lane.id and area.channel==s.channel then
    I.DrawList_PushClipRect(d,v.x,top,v.x+v.w,top+height,true)
    I.DrawList_AddRectFilled(d,v:x_from_qn(area.start_qn),top,v:x_from_qn(area.end_qn),top+height,T.marquee_fill)
    I.DrawList_AddRect(d,v:x_from_qn(area.start_qn),top,v:x_from_qn(area.end_qn),top+height,T.marquee_edge,0,0,2)
    I.DrawList_PopClipRect(d)
  end
  if hovered then I.SetTooltip(c,app.controller_razor_notice or (app.mixed_razor and app.razor_area and 'Mixed razor: drag inside to move notes and all controller areas; Ctrl-drag copies.\nShift-edge stretches the whole group. Copy/Cut/Paste, Delete and Duplicate include the whole group.\nValue scale/tilt remains specific to this controller.'or 'Controller razor: drag an area; Shift-drag another lane to add it.\nEnable Include controller areas with note razor to edit all lanes together.\nDrag inside to move this area; Ctrl-drag copies. Shift-edge stretches. Delete/Duplicate affect this area.'))end
  return true
end
return M
