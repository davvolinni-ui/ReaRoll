-- @noindex
local KeyMap=require 'src.key_map'
local Appearance=require 'src.ui.appearance'
local M={}
local palettes={
  Balanced={0xE75D5DFF,0xEA8847FF,0xE8B84FFF,0xA9C957FF,0x55C47AFF,0x4DC3B3FF,0x55B8EFFF,0x6389F5FF,0x797DE8FF,0x9B72E8FF,0xCB68B8FF,0xE06791FF,0xB9805AFF,0x8DA06BFF,0x6F99A8FF,0xA1A8B3FF},
  Drums={0xE24B4BFF,0xF06A3FFF,0xF39A3FFF,0xE6C84FFF,0x9FC54DFF,0x51B85FFF,0x3EB99CFF,0x3FAFC8FF,0x438FD8FF,0x536FE0FF,0x7659D8FF,0xA052C1FF,0xC552A0FF,0xD85D78FF,0x9C7657FF,0x71808FFF},
  Orchestral={0xB94D5AFF,0xD47A50FF,0xD2A54EFF,0x9EAF5AFF,0x5EA66CFF,0x4B9A8CFF,0x4F8DA8FF,0x5879B8FF,0x6D68B4FF,0x8964ADFF,0xA15F98FF,0xB3657FFF,0x8C6A58FF,0x777F65FF,0x667B8DFF,0x90949BFF},
  Primary={0xFF2B20FF,0xFF6A00FF,0xFFC400FF,0xE8F500FF,0x62E600FF,0x00D884FF,0x00DCD4FF,0x00B8F0FF,0x1688FFFF,0x3558FFFF,0x6D24FFFF,0xA900E8FF,0xE000C8FF,0xFF168DFF,0x252525FF,0xF2F2F2FF},
  Cool={0x75695DFF,0x85806AFF,0x8D965FFF,0x629959FF,0x399E62FF,0x269A72FF,0x268D89FF,0x257F92FF,0x367993FF,0x4B748EFF,0x61738EFF,0x6B7195FF,0x73709FFF,0x7774AAFF,0x7E78B6FF,0x8179C0FF},
  Warm={0x9D3E40FF,0xB84A3BFF,0xC85A36FF,0xD67339FF,0xE29040FF,0xE8AA4BFF,0xD6B857FF,0xB9B567FF,0xA3A06DFF,0x93876EFF,0x8A756DFF,0x806A6DFF,0x765F6BFF,0x6E5968FF,0x675665FF,0x615660FF},
  Pastel={0xE66F91FF,0xF08A8AFF,0xF3A47FFF,0xF3C17CFF,0xE7DB83FF,0xC6E58DFF,0x9EE4A2FF,0x83DDBEFF,0x79D4D2FF,0x78C9E7FF,0x86B3EFFF,0x9C9FECFF,0xB591E6FF,0xCB87D8FF,0xDC82BEFF,0xE480A4FF},
  Neon={0xFF006EFF,0xFF1744FF,0xFF5400FF,0xFFB300FF,0xE9FF00FF,0x73FF00FF,0x00EF62FF,0x00E5C3FF,0x00CFFFFF,0x0088FFFF,0x304BFFFF,0x692CFFFF,0xA900FFFF,0xE000D7FF,0xFF00A8FF,0xFF3B7CFF},
  Earth={0x804B3DFF,0x9A5C3FFF,0xAD7546FF,0xB98E50FF,0xB2A65AFF,0x929C5DFF,0x718E5EFF,0x558064FF,0x47736CFF,0x416975FF,0x49617EFF,0x585D82FF,0x695A7CFF,0x765A70FF,0x795D64FF,0x71615DFF},
}
local palette_order={'Balanced','Cool','Primary','Drums','Pastel','Orchestral','Warm','Neon','Earth'}

local function apply_color(app,color)
  app.key_map_color=color
  for pitch in pairs(app.key_map_selection or {}) do app.key_colors[pitch]=color end
  app:save_key_colors()
end

local function palette_card(app,name,width)
  local I,c,T=app.ImGui,app.ctx,app.theme; local x,y=I.GetCursorScreenPos(c)
  local clicked=I.InvisibleButton(c,'##palette_'..name,width,39); local hot=I.IsItemHovered(c)
  local d=I.GetWindowDrawList(c); if hot or app.key_palette_name==name then I.DrawList_AddRectFilled(d,x,y,x+width,y+39,hot and T.beat or T.panel2,4) end
  I.DrawList_AddText(d,x+6,y+3,app.key_palette_name==name and T.text or T.hint,name)
  local colors=palettes[name]; local left=x+6; local sw=(width-12)/#colors
  for index,color in ipairs(colors) do I.DrawList_AddRectFilled(d,left+(index-1)*sw,y+21,left+index*sw,y+33,color) end
  return clicked
end

function M.draw(app)
  if not app.key_map_open then return end
  local I,c=app.ImGui,app.ctx
  I.SetNextWindowSize(c,270,190,I.Cond_FirstUseEver)
  local visible; visible,app.key_map_open=I.Begin(c,'Key Color Palette',app.key_map_open,I.WindowFlags_AlwaysAutoResize)
  if visible then
    local count=0; for _ in pairs(app.key_map_selection or {}) do count=count+1 end
    I.Text(c,count==0 and 'Select keys on the keyboard' or (count..' key'..(count==1 and '' or 's')..' selected'))
    app.key_palette_name=app.key_palette_name or 'Balanced'
    if I.Button(c,'Palette: '..app.key_palette_name..'  v',190,0) then I.OpenPopup(c,'##key_palette_browser') end
    if I.BeginPopup(c,'##key_palette_browser') then
      I.TextDisabled(c,'Color palettes'); I.Separator(c)
      for index,name in ipairs(palette_order) do
        if index%2==0 then I.SameLine(c) end
        if palette_card(app,name,176) then app.key_palette_name=name; I.CloseCurrentPopup(c) end
      end
      I.EndPopup(c)
    end
    for index,color in ipairs(palettes[app.key_palette_name]) do
      if (index-1)%8~=0 then I.SameLine(c) end
      if I.ColorButton(c,'##key_swatch_'..index,Appearance.to_widget_color(color),I.ColorEditFlags_NoAlpha,24,20) then apply_color(app,color) end
    end
    I.SetNextItemWidth(c,90)
    local changed,color=I.ColorEdit4(c,'Color',Appearance.to_widget_color(app.key_map_color),I.ColorEditFlags_NoAlpha|I.ColorEditFlags_NoOptions)
    if changed then apply_color(app,Appearance.from_widget_color(color)) end
    I.SameLine(c)
    I.BeginDisabled(c,count==0)
    if I.Button(c,'Clear') then for pitch in pairs(app.key_map_selection) do app.key_colors[pitch]=nil end; app:save_key_colors() end
    I.EndDisabled(c)
    I.Separator(c)
    local presets=KeyMap.presets(); local preview=app.key_map_preset or 'Presets'
    I.SetNextItemWidth(c,112)
    if I.BeginCombo(c,'##key_color_presets',preview) then
      for _,name in ipairs(presets) do if I.Selectable(c,name,name==app.key_map_preset) then app.key_colors=KeyMap.load_preset(name); app.key_map_preset=name; app:save_key_colors() end end
      I.EndCombo(c)
    end
    I.SameLine(c); I.SetNextItemWidth(c,92)
    local renamed; renamed,app.key_map_preset_name=I.InputText(c,'##key_preset_name',app.key_map_preset_name or '')
    if I.Button(c,'Save preset') and KeyMap.save_preset(app.key_map_preset_name,app.key_colors) then app.key_map_preset=app.key_map_preset_name end
    if app.key_map_preset then I.SameLine(c); if I.Button(c,'Delete') then KeyMap.delete_preset(app.key_map_preset); app.key_map_preset=nil end end
    I.TextDisabled(c,'Ctrl: add/remove  |  Shift/right-drag: range')
  end
  if visible then I.End(c) end
  if not app.key_map_open then app.key_mapping_mode=false end
end

return M
