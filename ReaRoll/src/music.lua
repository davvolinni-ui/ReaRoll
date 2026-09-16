-- @noindex
local U=require 'src.util'
local M={}
M.roots={'C','C#','D','D#','E','F','F#','G','G#','A','A#','B'}
M.scales={
  Major={0,2,4,5,7,9,11}, Minor={0,2,3,5,7,8,10},
  Dorian={0,2,3,5,7,9,10}, Phrygian={0,1,3,5,7,8,10}, Lydian={0,2,4,6,7,9,11}, Mixolydian={0,2,4,5,7,9,10}, Locrian={0,1,3,5,6,8,10},
  ['Harmonic Minor']={0,2,3,5,7,8,11}, ['Melodic Minor']={0,2,3,5,7,9,11}, ['Phrygian Dominant']={0,1,4,5,7,8,10}, ['Lydian Dominant']={0,2,4,6,7,9,10}, Altered={0,1,3,4,6,8,10},
  Pentatonic={0,2,4,7,9}, ['Minor Pent.']={0,3,5,7,10}, Blues={0,3,5,6,7,10}, ['Major Blues']={0,2,3,4,7,9},
  ['Whole Tone']={0,2,4,6,8,10}, ['Diminished H-W']={0,1,3,4,6,7,9,10}, ['Diminished W-H']={0,2,3,5,6,8,9,11}, Chromatic={0,1,2,3,4,5,6,7,8,9,10,11},
  ['Bebop Major']={0,2,4,5,7,8,9,11}, ['Bebop Dominant']={0,2,4,5,7,9,10,11},
  ['Double Harmonic']={0,1,4,5,7,8,11}, ['Hungarian Minor']={0,2,3,6,7,8,11}, Hirajoshi={0,2,3,7,8}, ['Japanese In']={0,1,5,7,8},
}
M.scale_groups={
  {'Common',{'Major','Minor'}},
  {'Modes',{'Dorian','Phrygian','Lydian','Mixolydian','Locrian'}},
  {'Minor & melodic',{'Harmonic Minor','Melodic Minor','Phrygian Dominant','Lydian Dominant','Altered'}},
  {'Pentatonic & blues',{'Pentatonic','Minor Pent.','Blues','Major Blues'}},
  {'Symmetrical',{'Whole Tone','Diminished H-W','Diminished W-H','Chromatic'}},
  {'Jazz',{'Bebop Major','Bebop Dominant'}},
  {'World & exotic',{'Double Harmonic','Hungarian Minor','Hirajoshi','Japanese In'}},
}
M.scale_order={}
for _,group in ipairs(M.scale_groups) do for _,name in ipairs(group[2]) do M.scale_order[#M.scale_order+1]=name end end
M.chords={
  Major={0,4,7}, Minor={0,3,7}, Diminished={0,3,6}, Augmented={0,4,8}, Power={0,7},
  Sus2={0,2,7}, Sus4={0,5,7}, Add9={0,4,7,14}, ['Minor add9']={0,3,7,14},
  Major6={0,4,7,9}, Minor6={0,3,7,9}, ['6/9']={0,4,7,9,14},
  Major7={0,4,7,11}, Minor7={0,3,7,10}, Dominant7={0,4,7,10}, ['Minor major7']={0,3,7,11},
  Diminished7={0,3,6,9}, ['Half-diminished7']={0,3,6,10}, ['Dominant7 sus4']={0,5,7,10},
  Major9={0,4,7,11,14}, Minor9={0,3,7,10,14}, Dominant9={0,4,7,10,14},
  Major11={0,4,7,11,14,17}, Minor11={0,3,7,10,14,17}, Dominant11={0,4,7,10,14,17},
  Major13={0,4,7,11,14,17,21}, Minor13={0,3,7,10,14,17,21}, Dominant13={0,4,7,10,14,17,21},
}
M.chord_groups={
  {'Basic',{'Major','Minor','Diminished','Augmented','Power'}},
  {'Suspended & added',{'Sus2','Sus4','Add9','Minor add9'}},
  {'Sixth chords',{'Major6','Minor6','6/9'}},
  {'Seventh chords',{'Major7','Minor7','Dominant7','Minor major7','Diminished7','Half-diminished7','Dominant7 sus4'}},
  {'Extended chords',{'Major9','Minor9','Dominant9','Major11','Minor11','Dominant11','Major13','Minor13','Dominant13'}},
}
M.chord_order={}
for _,group in ipairs(M.chord_groups) do for _,name in ipairs(group[2]) do M.chord_order[#M.chord_order+1]=name end end
function M.contains(root,name,pitch)
  local pc=(pitch-root)%12; for _,v in ipairs(M.scales[name] or M.scales.Major) do if pc==v then return true end end; return false
end
function M.snap(root,name,pitch,direction)
  pitch=U.clamp(math.floor(pitch+.5),0,127); if M.contains(root,name,pitch) then return pitch end
  for d=1,11 do
    local up=U.clamp(pitch+d,0,127); local down=U.clamp(pitch-d,0,127)
    if direction and direction<0 then if M.contains(root,name,down) then return down end; if M.contains(root,name,up) then return up end
    else if M.contains(root,name,up) then return up end; if M.contains(root,name,down) then return down end end
  end
  return pitch
end
function M.diatonic_chord(root,name,pitch,size,inversion)
  local scale=M.scales[name] or M.scales.Major
  local snapped=M.snap(root,name,pitch)
  local relative=snapped-root; local octave=math.floor(relative/12); local pc=relative%12
  local degree=1
  for i,value in ipairs(scale) do if value==pc then degree=i; break end end
  local pitches={}; size=math.max(3,math.min(4,math.floor(size or 3)))
  for tone=0,size-1 do
    local index=degree+tone*2; local extra=math.floor((index-1)/#scale); local value=scale[(index-1)%#scale+1]
    pitches[#pitches+1]=root+(octave+extra)*12+value
  end
  inversion=math.max(0,math.min(#pitches-1,math.floor(inversion or 0)))
  for i=1,inversion do pitches[i]=pitches[i]+12 end
  table.sort(pitches)
  for i,p in ipairs(pitches) do pitches[i]=U.clamp(p,0,127) end
  return pitches
end
return M
