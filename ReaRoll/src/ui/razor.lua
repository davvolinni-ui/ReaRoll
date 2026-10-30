-- @noindex
local Razor=require 'src.razor'
local Shortcuts=require 'src.shortcuts'
local U=require 'src.util'
local M={}
local function areas(app)
  local out={};for _,a in ipairs(app.razor_areas or {})do if a.end_qn>a.start_qn then out[#out+1]=a end end
  if app.razor_area and app.razor_area.end_qn>app.razor_area.start_qn then out[#out+1]=app.razor_area end
  return out
end
local function translated(list,dq,dp)
  local out={};for _,a in ipairs(list)do out[#out+1]={start_qn=a.start_qn+dq,end_qn=a.end_qn+dq,low=a.low+dp,high=a.high+dp,channel=a.channel}end;return out
end
function M.grid(app,v,d,hovered,mx,my)
  if app.settings.mode~='razor' then
    if app.razor_drag then app.razor_area=app.razor_drag.original;app.razor_areas=app.razor_drag.saved_areas;app.razor_drag=nil end
    return false
  end
  local I,c,s,T=app.ImGui,app.ctx,app.settings,app.theme
  local mods=U.mods(I,c)
  local item_first=app.multi_edit_mode and v.item_qn or app.item_start_qn
  local item_last=app.multi_edit_mode and v.item_end_qn or app.item_end_qn
  local function source_hash()
    if not app.multi_edit_mode then return select(2,reaper.MIDI_GetHash(app.take,false,''))end
    local out={};for _,source in ipairs(require('src.multi_notes').sources(app))do
      out[#out+1]=tostring(source.take)..':'..tostring(select(2,reaper.MIDI_GetHash(source.take,false,'')))..':'..source.start_qn..':'..source.end_qn..':'..tostring(source.readonly)..':'..tostring(source.rate)..':'..tostring(source.offset)
    end;table.sort(out);return table.concat(out,'|')
  end
  local function point()
    local q=U.clamp(v:qn_from_x(mx),item_first,item_last)
    if s.snap_enabled and not mods.alt then q=U.snap(q,s.grid_qn) end
    return U.clamp(q,item_first,item_last),v:pitch_from_y(U.clamp(my,v.y,v.y+v.h-1))
  end
  local area=app.razor_area
  local q,p=point()
  if hovered and not app.gesture and I.IsMouseClicked(c,I.MouseButton_Left) then
    app.razor_notice=nil
    app.controller_selection_active=false
    app.razor_focus='notes'
    app.razor_areas=app.razor_areas or {}
    if not mods.shift then for i,a in ipairs(app.razor_areas)do if q>=a.start_qn and q<=a.end_qn and p>=a.low and p<=a.high then
      if area then app.razor_areas[i]=area else table.remove(app.razor_areas,i)end;area=a;app.razor_area=a;break
    end end end
    local inside=area and q>=area.start_qn and q<=area.end_qn and p>=area.low and p<=area.high
    local edge
    if area and p>=area.low and p<=area.high then
      if math.abs(mx-v:x_from_qn(area.start_qn))<=6 then edge='left'
      elseif math.abs(mx-v:x_from_qn(area.end_qn))<=6 then edge='right' end
    end
    local hash=source_hash()
    local saved={table.unpack(app.razor_areas)};local original_group=areas(app)
    app.razor_drag={q=q,p=p,original=area,saved_areas=saved,group=original_group,move=inside and not edge,edge=edge,stretch=edge and mods.shift,copy=mods.ctrl,hash=hash}
    if not inside and not edge then
      if mods.shift and area and area.end_qn>area.start_qn then app.razor_areas[#app.razor_areas+1]=area
      elseif not mods.shift then app.razor_areas={} end
    end
  end
  local drag=app.razor_drag
  if drag then
    if drag.edge then
      local a=drag.original
      local step=math.min(a.end_qn-a.start_qn,s.snap_enabled and not mods.alt and s.grid_qn or .001)
      app.razor_area={start_qn=drag.edge=='left' and math.max(item_first,math.min(q,a.end_qn-step)) or a.start_qn,
        end_qn=drag.edge=='right' and math.min(item_last,math.max(q,a.start_qn+step)) or a.end_qn,low=a.low,high=a.high,channel=a.channel}
    elseif drag.move then
      local a=drag.original
      local first,last,low,high=Razor.bounds(drag.group)
      local dq=U.clamp(q-drag.q,item_first-first,item_last-last)
      local dp=U.clamp(p-drag.p,-low,127-high)
      drag.dq,drag.dp=dq,dp
      app.razor_area={start_qn=a.start_qn+dq,end_qn=a.end_qn+dq,low=a.low+dp,high=a.high+dp,channel=a.channel}
      app.razor_areas=translated(drag.saved_areas,dq,dp)
    else
      local channel;if s.edit_all_channels==false then channel=s.channel or 0 end
      app.razor_area=Razor.area(drag.q,q,drag.p,p,channel)
    end
    if I.IsMouseReleased(c,I.MouseButton_Left) then
      local hash=source_hash()
      if hash~=drag.hash then app.razor_area=drag.original;app.razor_areas=drag.saved_areas
      elseif drag.edge and drag.stretch then
        local a,b=drag.original,app.razor_area
        if not Razor.apply(app,a,'stretch',b.start_qn-a.start_qn,0,(b.end_qn-b.start_qn)/(a.end_qn-a.start_qn)) then app.razor_area=a end
      elseif drag.move and ((drag.dq or 0)~=0 or (drag.dp or 0)~=0) then
        if not Razor.apply(app,drag.group,drag.copy and 'copy' or 'move',drag.dq,drag.dp)then app.razor_area=drag.original;app.razor_areas=drag.saved_areas end
      end
      app.razor_drag=nil
      if app.razor_area and app.razor_area.end_qn<=app.razor_area.start_qn then app.razor_area=table.remove(app.razor_areas)end
    end
  end
  if app.razor_focus~='controller' and not app.controller_selection_active and I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows) and (drag or not I.IsAnyItemActive(c)) then
    if Shortcuts.pressed(app,'cancel',mods) then
      app.razor_area=drag and drag.original or nil; app.razor_drag=nil
      app.razor_areas=drag and drag.saved_areas or {}
    elseif not app.razor_drag then
      area=app.razor_area
      local group=areas(app)
      if Shortcuts.pressed(app,'paste',mods) then local _,notice=Razor.paste(app,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()));app.razor_notice=notice
      elseif #group>0 and Shortcuts.pressed(app,'copy',mods) then Razor.copy(app,group)
      elseif #group>0 and Shortcuts.pressed(app,'cut',mods) then if Razor.copy(app,group)then Razor.apply(app,group,'delete')end
      elseif #group>0 and Shortcuts.pressed(app,'delete',mods) then Razor.apply(app,group,'delete')
      elseif #group>0 and Shortcuts.pressed(app,'duplicate',mods) then
        local first,last=Razor.bounds(group);local span=last-first
        if Razor.apply(app,group,'copy',span,0) then
          app.razor_areas=translated(app.razor_areas or {},span,0)
          if area then app.razor_area=translated({area},span,0)[1]end
        end
      elseif Shortcuts.pressed(app,'undo',mods) or Shortcuts.pressed(app,'redo',mods) then
        if Shortcuts.pressed(app,'undo',mods) then reaper.Undo_DoUndo2(0) else reaper.Undo_DoRedo2(0) end
        app.cache:invalidate(); app.cc_cache:invalidate()
      end
    end
  end
  for _,area in ipairs(areas(app))do
    local top,bottom=v:y_from_pitch(area.high),v:y_from_pitch(area.low)
    if top and bottom then
      I.DrawList_PushClipRect(d,v.x,v.y,v.x+v.w,v.y+v.h,true)
      local left,right=v:x_from_qn(area.start_qn),v:x_from_qn(area.end_qn)
      I.DrawList_AddRectFilled(d,left,top,right,bottom+s.row_height,T.marquee_fill)
      I.DrawList_AddRect(d,left,top,right,bottom+s.row_height,T.marquee_edge,0,0,2)
      I.DrawList_PopClipRect(d)
    end
  end
  if hovered then I.SetTooltip(c,app.razor_notice or 'Razor: drag creates an area; Shift-drag empty space adds areas. Drag inside moves the group; Ctrl-drag copies.\nEdges resize the active area; Shift-edge stretches its contents.\nCopy/Cut/Paste, Delete, Duplicate and Escape apply to the area group. Overlaps are processed once.') end
  return true
end
return M
