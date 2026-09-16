-- @noindex
local M={}
-- Draw-list icons use the same pixel geometry on every platform: no icon font.
function M.button(app,id,kind,tip,active)
  local I,c,T=app.ImGui,app.ctx,app.theme
  local scale=math.max(.8,math.min(1.5,app.settings.ui_scale or 1))
  local function sx(value)return value*scale end
  local x,y=I.GetCursorScreenPos(c)
  local clicked=I.InvisibleButton(c,'##'..id,sx(28),sx(26))
  local hot=I.IsItemHovered(c)
  local d=I.GetWindowDrawList(c)
  if active or hot then I.DrawList_AddRectFilled(d,x,y,x+sx(28),y+sx(26),active and T.beat or T.panel2,sx(4)) end
  local col=active and (T.header_icon or T.note_hover) or (hot and T.text or T.hint)
  local function line(a,b,e,f) I.DrawList_AddLine(d,x+sx(a),y+sx(b),x+sx(e),y+sx(f),col,sx(1.5)) end
  local function rect(a,b,e,f) I.DrawList_AddRect(d,x+sx(a),y+sx(b),x+sx(e),y+sx(f),col,sx(1),I.DrawFlags_None,sx(1.5)) end
  if kind=='menu' then for k=8,18,5 do line(7,k,21,k) end
  elseif kind=='more' then for px=8,20,6 do I.DrawList_AddCircleFilled(d,x+sx(px),y+sx(13),sx(2),col) end
  elseif kind=='select' then
    for k=6,18,6 do line(k,5,k+3,5);line(k,21,k+3,21);line(5,k,5,k+3);line(23,k,23,k+3) end
  elseif kind=='smart' then
    -- Pencil silhouette with a distinct nib and separated eraser cap.
    line(7,16,17,6);line(17,6,22,11);line(22,11,12,21)
    line(12,21,5,23);line(5,23,7,16);line(7,16,12,21)
    line(15,8,20,13);line(5,23,8,22)
  elseif kind=='paint' then
    -- Brush handle, ferrule and bristles above repeated painted notes.
    line(16,4,20,6);line(20,6,15,14);line(15,14,11,12);line(11,12,16,4)
    line(11,12,8,17);line(8,17,13,17);line(13,17,15,14)
    for k=5,19,7 do rect(k,21,k+4,23) end
  elseif kind=='chord' then
    -- Compact piano keyboard: white-key divisions with raised black keys.
    rect(5,6,23,21)
    for k=1,5 do line(5+k*3,14,5+k*3,21) end
    for _,px in ipairs({8,14,17}) do
      I.DrawList_AddRectFilled(d,x+sx(px),y+sx(6),x+sx(px+2.5),y+sx(14),col)
    end
  elseif kind=='slice' then line(7,20,21,6); line(8,6,20,18); I.DrawList_AddCircle(d,x+sx(7),y+sx(19),sx(3),col,0,sx(1.5))
  elseif kind=='glue' then rect(5,8,12,18); rect(16,8,23,18); line(11,13,17,13); line(14,10,14,16)
  elseif kind=='mute' then rect(6,10,10,16); line(10,10,15,6); line(15,6,15,20); line(15,20,10,16); line(19,10,24,16); line(24,10,19,16)
  elseif kind=='play' then line(9,6,21,13); line(21,13,9,20); line(9,20,9,6)
  elseif kind=='pause' then rect(8,7,11,19); rect(17,7,20,19)
  elseif kind=='snap_absolute' then
    -- Independent strokes avoid compound-path join artifacts at toolbar scale.
    line(7,12,7,17); line(7,17,10,20); line(10,20,14,21.5); line(14,21.5,18,20); line(18,20,21,17); line(21,17,21,12)
    line(7,12,10,12); line(18,12,21,12)
    I.DrawList_AddBezierCubic(d,x+sx(8),y+sx(6),x+sx(11),y+sx(2),x+sx(17),y+sx(2),x+sx(20),y+sx(6),col,sx(1.5))
    I.DrawList_AddBezierCubic(d,x+sx(10),y+sx(9),x+sx(12),y+sx(6.5),x+sx(16),y+sx(6.5),x+sx(18),y+sx(9),col,sx(1.5))
  elseif kind=='snap_relative' then
    line(7,7,7,16); line(7,16,10,19); line(10,19,14,20.5); line(14,20.5,18,19); line(18,19,21,16); line(21,16,21,7)
    line(7,10,10,10); line(18,10,21,10)
  elseif kind=='fold' then line(7,6,14,11); line(14,11,21,6); line(7,20,14,15); line(14,15,21,20)
  elseif kind=='scale' then for k=0,3 do line(6+k*4,19-k*3,10+k*4,19-k*3) end
  elseif kind=='ghost' then I.DrawList_AddCircle(d,x+sx(14),y+sx(12),sx(7),col,0,sx(1.5)); line(7,12,7,21); line(21,12,21,21); line(7,21,11,18); line(11,18,15,21); line(15,21,18,18); line(18,18,21,21); line(11,11,11,13); line(17,11,17,13)
  elseif kind=='phrase' then
    line(10,7,10,18); line(20,5,20,16); line(10,7,20,5); line(10,11,20,9)
    I.DrawList_AddCircleFilled(d,x+sx(7.5),y+sx(19),sx(3.5),col); I.DrawList_AddCircleFilled(d,x+sx(17.5),y+sx(17),sx(3.5),col)
  elseif kind=='tools' then line(7,7,21,21); line(7,21,21,7); I.DrawList_AddCircle(d,x+sx(8),y+sx(8),sx(3),col,0,sx(1.5))
  elseif kind=='view' then I.DrawList_AddCircle(d,x+sx(12),y+sx(11),sx(6),col,0,sx(1.5)); line(16,16,22,22)
  elseif kind=='setup' then for k=7,19,6 do line(k,6,k,21) end; rect(5,9,9,12); rect(11,15,15,18); rect(17,8,21,11)
  end
  if hot then I.SetTooltip(c,tip) end
  return clicked,hot
end
return M
