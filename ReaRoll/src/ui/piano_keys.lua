-- @noindex
local U=require 'src.util'
local M={}
local function selected_key(app,d,key,left,right)
  local I,T=app.ImGui,app.theme
  local z=app.settings.ui_scale or 1
  local top,bottom=key.top+1,key.bottom-1
  if bottom<=top then return end
  local color=(T.selected_edge&0xFFFFFF00)|255
  local rounding=key.black and 2*z or 0
  I.DrawList_AddRectFilled(d,left+1,top,right-1,bottom,(color&0xFFFFFF00)|(key.black and 135 or 100),rounding)
  -- Dark backing keeps the accent boundary visible on both white and black keys.
  I.DrawList_AddRect(d,left+1,top,right-1,bottom,0x10131AE0,rounding,I.DrawFlags_None,4*z)
  I.DrawList_AddRect(d,left+1,top,right-1,bottom,color,rounding,I.DrawFlags_None,2*z)
  -- A shape, rather than color alone, identifies the selected keys. Leave the
  -- rightmost color strip visible so assigned colors can still be compared.
  if bottom-top>=12*z and right-left>=36*z then
    local x,y=right-20*z,(top+bottom)*.5
    for _,style in ipairs({{0x10131AFF,4*z},{0xFFFFFFFF,2*z}})do
      I.DrawList_AddLine(d,x-3*z,y,x,y+3*z,style[1],style[2])
      I.DrawList_AddLine(d,x,y+3*z,x+6*z,y-4*z,style[1],style[2])
    end
  end
end
function M.draw(app,d,v,x0,key_w,white_keys,black_keys,hover_pitch)
  local I,c,T,s=app.ImGui,app.ctx,app.theme,app.settings
  if v.mapped then
    require('src.ui.drum_rows').draw(app,d,v,x0,{white_keys,black_keys},hover_pitch)
  else
  if v.fold then
    -- Fold mode is an arbitrary pitch list, so preserve one honest key per row.
    for _,key in ipairs(white_keys) do
      local color=key.pitch%12==0 and T.c_key or T.white_key
      local top_color=key.pitch%12==0 and T.c_key_top or T.white_key_top
      I.DrawList_AddRectFilledMultiColor(d,x0,key.top,v.x-1,key.bottom,top_color,top_color,color,color)
      I.DrawList_AddLine(d,x0,key.bottom,v.x-1,key.bottom,T.key_border)
    end
  else
    -- White keys own the space halfway to the next visible white-key centre.
    -- Accidentals are then laid over those bodies, like a physical keyboard.
    for i,key in ipairs(white_keys) do
      key.top=i==1 and v.y or (white_keys[i-1].center+key.center)*.5
      key.bottom=i==#white_keys and v.y+v.h or (key.center+white_keys[i+1].center)*.5
      local color=key.pitch%12==0 and T.c_key or T.white_key
      local top_color=key.pitch%12==0 and T.c_key_top or T.white_key_top
      I.DrawList_AddRectFilledMultiColor(d,x0,key.top,v.x-1,key.bottom,top_color,top_color,color,color)
      I.DrawList_AddLine(d,x0,key.bottom,v.x-1,key.bottom,T.key_border)
    end
  end

  -- A highlighted white key remains behind the raised accidentals.
  if hover_pitch and not U.is_black(hover_pitch) then
    for _,key in ipairs(white_keys) do
      if key.pitch==hover_pitch then
        I.DrawList_AddRectFilled(d,x0,key.top,v.x-1,key.bottom,T.key_hover)
        I.DrawList_AddRect(d,x0,key.top,v.x-1,key.bottom,T.selected_edge,0,I.DrawFlags_None,1)
        break
      end
    end
  end
  -- White-key selection belongs below the raised black keys.
  if app.key_mapping_mode and app.key_map_selection then
    for _,key in ipairs(white_keys) do if app.key_map_selection[key.pitch] then selected_key(app,d,key,x0,v.x-1) end end
  end

  for _,key in ipairs(black_keys) do
    local top,bottom
    if v.fold then top,bottom=key.top,key.bottom
    else
      local half=math.max(2,s.row_height*.43)
      top,bottom=math.max(v.y,key.center-half),math.min(v.y+v.h,key.center+half)
    end
    local right=x0+key_w*.64
    local right_corners=I.DrawFlags_RoundCornersRight or I.DrawFlags_None
    I.DrawList_AddRectFilled(d,x0,top,right,bottom,T.black_key,2,right_corners)
    I.DrawList_AddLine(d,x0+1,top+1,right-2,top+1,T.black_key_top,1)
    I.DrawList_AddRect(d,x0,top,right,bottom,T.key_border,2,right_corners,1)
    key.top,key.bottom,key.right=top,bottom,right
  end
  -- Black-key hover belongs above the black-key layer itself.
  if hover_pitch and U.is_black(hover_pitch) then
    for _,key in ipairs(black_keys) do
      if key.pitch==hover_pitch then
        local right_corners=I.DrawFlags_RoundCornersRight or I.DrawFlags_None
        I.DrawList_AddRectFilled(d,x0,key.top,key.right,key.bottom,T.key_hover,2,right_corners)
        I.DrawList_AddRect(d,x0,key.top,key.right,key.bottom,T.selected_edge,2,right_corners,1)
        break
      end
    end
  end

  -- Pitch maps color only a compact section of each key. Note bodies retain
  -- their channel colors and the piano's black/white geometry stays legible.
  for _,keys in ipairs({white_keys,black_keys}) do
    for _,key in ipairs(keys) do
      local right=key.right or v.x-1; local color=app.key_colors and app.key_colors[key.pitch]
      if app.input_notes and app.input_notes[key.pitch]then
        I.DrawList_AddRectFilled(d,x0,key.top,right,key.bottom,(T.accent&0xFFFFFF00)|155,key.black and 2 or 0)
        I.DrawList_AddRect(d,x0,key.top,right,key.bottom,T.accent,key.black and 2 or 0,I.DrawFlags_None,1.5)
      end
      if key.black and app.key_mapping_mode and app.key_map_selection and app.key_map_selection[key.pitch] then
        selected_key(app,d,key,x0,right)
      end
      if color then
        local strip=math.max(6,math.min(10,(right-x0)*.18))
        I.DrawList_AddRectFilled(d,right-strip,key.top+1,right,key.bottom-1,color,key.black and 2 or 0)
      end
    end
  end

  local label_keys=white_keys
  if v.mapped then label_keys={};for _,keys in ipairs({white_keys,black_keys})do for _,key in ipairs(keys)do label_keys[#label_keys+1]=key end end end
  for _,key in ipairs(label_keys) do
    local custom=app.note_label and app:note_label(key.pitch) or nil
    if (custom or v.fold or key.pitch%12==0) and s.row_height>=11 then
      local label=custom or U.pitch_name(key.pitch); if #label>12 then label=label:sub(1,12) end
      local tw,th=I.CalcTextSize(c,label); th=th or math.min(s.row_height,key.bottom-key.top)
      I.DrawList_AddText(d,v.x-tw-4,(key.top+key.bottom-th)*.5,T.black_key,label)
    end
  end
  end
end
return M
