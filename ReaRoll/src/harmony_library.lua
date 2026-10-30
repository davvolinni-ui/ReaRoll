-- @noindex
local Music=require 'src.music'
local P=require 'src.chord_palettes'
local M={}
local function entry(s,root,pitches,octave)
 local tones={};for _,p in ipairs(pitches)do
  p=p+12*(octave or 0)
  if p<0 or p>127 or not Music.contains(s.scale_root,s.scale_name,p)then return end
  tones[#tones+1]=p
 end
 return {label=Music.chord_label(pitches,root),pitches=tones}
end
function M.entries(s,octave)
 local out={}
 for _,offset in ipairs(Music.scales[s.scale_name])do
  local root=60+s.scale_root+offset
  for _,size in ipairs({3,4})do
   local e=entry(s,root,Music.diatonic_chord(s.scale_root,s.scale_name,root,size,s.chord_inversion or 0),octave)
   if e then out[#out+1]=e end
  end
 end
 return out
end
function M.palettes(s,octave)
 local settings={};for k,v in pairs(s)do settings[k]=v end;settings.chord_diatonic=false
 local out={}
 for index,preset in ipairs(P.presets)do
  local entries={};for i in ipairs(preset.degrees)do
   local root,pitches=P.resolve(settings,preset,i);local e=entry(s,root,pitches,octave)
   if e then entries[#entries+1]=e end
  end
  if #entries>1 then out[#out+1]={index=index,name=preset.name,category=preset.category,entries=entries}end
 end
 return out
end
return M
