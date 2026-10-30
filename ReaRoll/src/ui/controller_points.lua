-- @noindex
local Engine=require 'src.controller_points'
local U=require 'src.util'
local Mouse=require 'src.mouse'
local M={}
function M.draw(app,source,lane,ch,v,d,top,height,hovered,mx,my)
  local I,c,s=app.ImGui,app.ctx,app.settings;local maximum=lane.pitch and 16383 or 127
  local function py(value)return top+height-4-value/maximum*math.max(1,height-20)end
  local function value(y)return U.clamp(math.floor((top+height-4-y)/math.max(1,height-20)*maximum+.5),0,maximum)end
  local points=Engine.points(source.take,lane,ch);local key=tostring(source.take)..':'..(lane.id or lane.short or tostring(lane.cc or lane.status or 'pitch'))..':'..ch
  local selected=Engine.selection(app,key,source.take)
  local nearest,distance
  for _,p in ipairs(points)do
    local x=v:x_from_qn(reaper.MIDI_GetProjQNFromPPQPos(source.take,p.ppq));local y=py(p.value)
    if selected[p.index]then I.DrawList_AddCircle(d,x,y,5,app.theme.selected_edge,0,2)end
    local dist=(mx-x)^2+(my-y)^2;if not distance or dist<distance then nearest,distance=p,dist end
  end
  if distance and distance>64 then nearest=nil end
  local mods=U.mods(I,c);local g=app.controller_point_gesture
  if hovered and not require('src.ui.lane_tools').any_popup_open(app)then
    if nearest then I.SetTooltip(c,lane.label..' / Ch '..(ch+1)..' / '..nearest.value..'\nDrag: move / Shift-drag: copy / Ctrl-click: select / right-click: delete / Alt-right-click: curve shape')end
    if not g and not app.gesture and I.IsMouseClicked(c,I.MouseButton_Left)then
      app.multi_controller_point_focus=true;app.controller_point_focus_key=key;app.controller_point_context={take=source.take,lane=lane,ch=ch,key=key,name=source.name}
      if mods.ctrl and nearest then selected[nearest.index]=not selected[nearest.index]
      else
        local operation=nearest and(mods.shift and 'copy'or 'move')or 'draw'
        if nearest and not selected[nearest.index]then selected={[nearest.index]=true};app.controller_point_selection[key]=selected end
        local ok,notice=Engine.begin(app,source.take,lane,ch,operation,selected);app.multi_controller_point_notice=notice
        if ok then g=app.controller_point_gesture;g.key=key;g.anchor=v:qn_from_x(mx);g.anchor_value=value(my);g.origin=nearest and reaper.MIDI_GetProjQNFromPPQPos(source.take,nearest.ppq)or g.anchor end
      end
    elseif not g and not app.gesture and nearest and I.IsMouseClicked(c,I.MouseButton_Right)then
      app.multi_controller_point_focus=true;app.controller_point_focus_key=key;app.controller_point_context={take=source.take,lane=lane,ch=ch,key=key,name=source.name}
      if mods.alt then
        if not selected[nearest.index]then selected={[nearest.index]=true};app.controller_point_selection[key]=selected end
        app.controller_shape_context={key=key,indices=selected,raw=select(2,reaper.MIDI_GetAllEvts(source.take,''))};I.OpenPopup(c,'##controller_point_shape_'..key)
      else
      local ok,notice=Engine.begin(app,source.take,lane,ch,'delete',{[nearest.index]=true})
      if ok then ok,notice=Engine.preview(app);if ok then ok,notice=Engine.finish(app)end end
      app.multi_controller_point_notice=notice
      end
    end
  end
  if I.BeginPopup(c,'##controller_point_shape_'..key)then
    I.Text(c,'Controller curve shape')
    for index,label in ipairs({'Square','Linear','Slow start/end','Fast start','Fast end','Bezier'})do
      if I.MenuItem(c,label)then
        local context=app.controller_shape_context;local indices=context and context.key==key and context.indices or selected
        local ok,notice=Engine.begin(app,source.take,lane,ch,'shape',indices,context and context.raw)
        if ok then ok,notice=Engine.preview(app,index-1,app.controller_shape_tension or 0);if ok then ok,notice=Engine.finish(app)end end
        app.multi_controller_point_notice=notice;I.CloseCurrentPopup(c)
      end
    end
    local changed,tension=I.SliderDouble(c,'Bezier tension',app.controller_shape_tension or 0,-1,1,'%.2f');if changed then app.controller_shape_tension=tension end
    I.EndPopup(c)
  end
  selected=Engine.selection(app,key,source.take)
  if app.controller_point_focus_key==key and not app.gesture and not I.IsAnyItemActive(c)and I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows)and not require('src.ui.lane_tools').any_popup_open(app)then
    local pressed=require('src.shortcuts').pressed
    if pressed(app,'undo',mods)or pressed(app,'redo',mods)then
      if pressed(app,'undo',mods)then reaper.Undo_DoUndo2(0)else reaper.Undo_DoRedo2(0)end
      Engine.selection(app,key,source.take);app.cache:invalidate();app.cc_cache:invalidate();require('src.multi_notes').refresh(app,true)
    elseif pressed(app,'select_all',mods)then for _,p in ipairs(points)do selected[p.index]=true end
    elseif pressed(app,'cancel',mods)or pressed(app,'deselect',mods)then app.controller_point_selection[key]={};app.multi_controller_point_focus=false;app.controller_point_focus_key=nil
    elseif pressed(app,'copy',mods)or pressed(app,'cut',mods)then
      local clip,notice=Engine.copy(source.take,lane,ch,selected)
      if clip then
        app.controller_point_clipboard=clip
        if pressed(app,'cut',mods)then
          local ok;ok,notice=Engine.begin(app,source.take,lane,ch,'delete',selected)
          if ok then ok,notice=Engine.preview(app);if ok then ok,notice=Engine.finish(app)end end
        end
      end
      app.multi_controller_point_notice=notice
    elseif pressed(app,'paste',mods)then
      local _,notice=Engine.paste(app,source.take,lane,ch,app.controller_point_clipboard,U.snap_time(s,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition())))
      app.multi_controller_point_notice=notice
    elseif pressed(app,'delete',mods)then
      local ok,notice=Engine.begin(app,source.take,lane,ch,'delete',selected)
      if ok then ok,notice=Engine.preview(app);if ok then ok,notice=Engine.finish(app)end end
      app.multi_controller_point_notice=notice
    end
  end
  g=app.controller_point_gesture
  if g and g.key==key then
    if I.IsKeyPressed(c,I.Key_Escape)then Engine.cancel(app)
    else
      local q=v:qn_from_x(mx);local current=value(my);local dq=q-g.anchor
      if not Mouse.is(s,'unsnap',mods)then dq=U.snap_time(s,g.origin+dq,g.origin)-g.origin;q=U.snap_time(s,q)end
      local signature=g.operation=='draw'and(q..':'..current)or(dq..':'..current)
      if signature~=g.signature then
        local ok,notice
        if g.operation=='draw'then ok,notice=Engine.draw_point(app,q,current,(not Mouse.is(s,'unsnap',mods)and U.snap_mode(s)~='off')and s.grid_qn or 2/math.max(1,v.px_per_qn or 1))else ok,notice=Engine.preview(app,dq,current-g.anchor_value)end
        app.multi_controller_point_notice=notice;if ok then g.signature=signature end
      end
      if app.controller_point_gesture and I.IsMouseReleased(c,I.MouseButton_Left)then
        local _,notice=Engine.finish(app);app.multi_controller_point_notice=notice
      end
    end
  end
end
return M
