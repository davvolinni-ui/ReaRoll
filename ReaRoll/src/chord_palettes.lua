-- @noindex
local Music=require 'src.music'
local M={}
-- Degrees describe a collection, not a required playing order.
M.presets={
  {name='Major essentials',scale='Major',degrees={1,2,3,4,5,6},qualities={'Major','Minor','Minor','Major','Major','Minor'}},
  {name='Minor essentials',scale='Minor',degrees={1,3,4,5,6,7},qualities={'Minor','Major','Minor','Minor','Major','Major'}},
  {name='Bright pop',scale='Major',degrees={1,5,6,4,2,3},qualities={'Major','Major','Minor','Major','Minor','Minor'}},
  {name='Dark pop',scale='Minor',degrees={1,6,3,7,4,5},qualities={'Minor','Major','Major','Major','Minor','Minor'}},
  {name='Soul sevenths',scale='Major',degrees={1,6,2,5,3,4,7},qualities={'Major7','Minor7','Minor7','Dominant7','Minor7','Major7','Half-diminished7'},size=4},
  {name='Mellow minor',scale='Minor',degrees={1,4,7,3,6,2,5},qualities={'Minor7','Minor7','Dominant7','Major7','Major7','Half-diminished7','Minor7'},size=4},
  {name='Minor tension',scale='Minor',degrees={1,4,6,7,5,2,3},qualities={'Minor','Minor','Major','Major','Major','Diminished','Major'}},
  {name='Jazz turnaround',scale='Major',degrees={1,6,2,5,3,4,7},qualities={'Major7','Dominant7','Minor7','Dominant7','Minor7','Major7','Half-diminished7'},size=4},
  {name='Suspended colors',scale='Major',degrees={1,1,4,4,5,5,6,2},qualities={'Major','Sus2','Major','Add9','Sus4','Major','Minor','Minor'}},
  {name='Minor colors',scale='Minor',degrees={1,1,4,4,6,7,3,5},qualities={'Minor','Minor add9','Minor','Minor7','Major7','Sus2','Major','Dominant7'}},
  {name='Dorian groove',scale='Dorian',degrees={1,4,7,3,2,5,6},qualities={'Minor7','Dominant7','Major7','Major7','Minor7','Minor7','Half-diminished7'},size=4},
  {name='Open fifths',scale='Minor',degrees={1,3,4,5,6,7},qualities={'Power','Power','Power','Power','Power','Power'}},
}

local categories={'Essentials','Essentials','Pop','Pop','Soul / R&B','Soul / R&B','Essentials','Jazz','Pop','Pop','Soul / R&B','Rock'}
for index,preset in ipairs(M.presets) do preset.category=categories[index] end
-- Compact, readable definitions keep the library small. These are harmonic
-- starting points; genre also comes from rhythm, arrangement and sound choice.
local shapes={M='Major',m='Minor',d='Diminished',p='Power',s2='Sus2',s4='Sus4',
  a9='Add9',ma9='Minor add9',M6='Major6',m6='Minor6',M7='Major7',m7='Minor7',
  D7='Dominant7',h7='Half-diminished7',d7='Diminished7',M9='Major9',m9='Minor9'}
local function add(category,name,scale,definition)
  local preset={category=category,name=name,scale=scale,degrees={},qualities={}}
  for degree,shape in definition:gmatch('(%d+):(%w+)') do
    assert(shapes[shape],'Unknown palette shape '..shape)
    preset.degrees[#preset.degrees+1]=tonumber(degree)
    preset.qualities[#preset.qualities+1]=shapes[shape]
  end
  M.presets[#M.presets+1]=preset
end

add('Dancehall','Minor bounce','Minor','1:m 7:M 6:M 4:m 5:m')
add('Dancehall','Sunlit bounce','Major','1:M 4:M 5:M 6:m 2:m')
add('Dancehall','Island colors','Minor','1:ma9 4:m7 6:M7 7:M 3:M')
add('Dancehall','Dorian lift','Dorian','1:m 4:M 7:M 5:m 3:M')
add('Reggae','Roots major','Major','1:M 4:M 5:M 2:m 6:m')
add('Reggae','Roots minor','Minor','1:m 4:m 5:m 7:M 6:M')
add('Reggae','Dub space','Dorian','1:m7 4:D7 7:M 1:s4 5:m7')
add('Reggae','Lovers colors','Major','1:M7 6:m7 2:m7 5:D7 4:M7')
add('Rock','Anthem chords','Major','1:M 5:M 6:m 4:M 2:m')
add('Rock','Minor drive','Minor','1:p 7:p 6:p 4:p 5:p')
add('Rock','Modal riffs','Mixolydian','1:M 7:M 4:M 5:m 2:m')
add('Rock','Acoustic colors','Major','1:a9 5:s4 6:m7 4:M7 2:m7 3:m')
add('Oldies','Doo-wop','Major','1:M 6:m 4:M 5:D7 2:m')
add('Oldies','Early soul','Major','1:M6 4:M6 2:m7 5:D7 6:m7')
add('Oldies','Ballad colors','Major','1:M 3:m 6:m 2:m 4:M 5:D7')
add('Oldies','Minor nostalgia','Minor','1:m 4:m 5:M 6:M 3:M 7:M')
add('Rap / Hip hop','Boom bap','Minor','1:m7 4:m7 6:M7 3:M7 7:M')
add('Rap / Hip hop','Sample soul','Major','2:m7 5:D7 1:M7 6:m7 3:m7 4:M7')
add('Rap / Hip hop','Melodic rap','Minor','1:m 6:M 3:M 7:M 4:m')
add('Rap / Hip hop','Jazz rap','Dorian','1:m7 4:D7 2:m7 7:M7 5:m7 3:M7')
add('Rap / Hip hop','Late night','Minor','1:ma9 6:M7 4:m7 5:m7 3:M7')
add('Trap','Dark keys','Minor','1:m 6:M 4:m 5:m')
add('Trap','Harmonic tension','Harmonic Minor','1:m 6:M 4:m 5:M 7:d')
add('Trap','Melodic glow','Minor','1:m7 3:M7 7:M 6:M7 4:m7')
add('Trap','Sparse fifths','Minor','1:p 6:p 7:p 4:p')
add('Phonk','Shadow chords','Minor','1:m 7:M 6:M 5:m 4:m')
add('Phonk','Memphis tension','Harmonic Minor','1:m 2:d 5:M 6:M 4:m')
add('Phonk','Drift fifths','Phrygian','1:p 2:p 7:p 6:p 4:p')
add('Phonk','Dusty minor','Minor','1:m7 4:m7 6:M7 7:D7 3:M7')
add('Classical','Major cadences','Major','1:M 2:m 4:M 5:D7 6:m 7:d')
add('Classical','Minor cadences','Harmonic Minor','1:m 2:d 4:m 5:D7 6:M 7:d7')
add('Classical','Circle colors','Major','1:M 4:M 7:d 3:m 6:m 2:m 5:D7')
add('Classical','Romantic minor','Minor','1:m 6:M 3:M 4:m 2:d 5:D7 7:M')
add('Electronic / Dance','Festival lift','Major','6:m 4:M 1:M 5:M 2:m')
add('Electronic / Dance','Minor house','Minor','1:m7 4:m7 6:M7 7:M 3:M7')
add('Electronic / Dance','Deep house','Dorian','1:m7 4:D7 2:m7 5:m7 7:M7')
add('Electronic / Dance','Suspended air','Major','1:s2 4:a9 5:s4 6:m7 2:m7')
add('Soul / R&B','Warm extensions','Major','1:M9 6:m9 2:m9 5:D7 4:M9')
add('Soul / R&B','Minor velvet','Minor','1:m9 4:m9 6:M9 3:M7 7:D7')
add('Jazz','Major standards','Major','2:m7 5:D7 1:M7 4:M7 6:m7 3:m7')
add('Jazz','Minor standards','Harmonic Minor','2:h7 5:D7 1:m6 4:m7 6:M7 7:d7')
add('Jazz','Secondary colors','Major','1:M7 3:D7 6:m7 2:D7 2:m7 5:D7')
add('Blues','Major blues colors','Major','1:D7 4:D7 5:D7 6:m7 2:m7')
add('Blues','Minor blues colors','Minor','1:m7 4:m7 5:D7 6:M7 2:h7')
add('Blues','Shuffle colors','Mixolydian','1:D7 4:D7 5:D7 1:M6 4:M6')
add('Blues','Slow blues','Major','1:D7 4:D7 5:D7 6:D7 2:m7')
add('Blues','Jazz blues','Major','1:D7 4:D7 6:D7 2:m7 5:D7 4:d7')
add('Blues','Gospel blues','Major','1:D7 4:D7 4:m7 1:M6 2:m7 5:D7')
add('Country / Folk','Open road','Major','1:M 4:M 5:M 6:m 2:m')
add('Country / Folk','Folk minor','Minor','1:m 7:M 3:M 6:M 4:m 5:M')
add('Pop','Dreamy major','Major','1:M7 4:M7 6:m7 2:m7 5:s4')
add('Pop','Bittersweet minor','Minor','1:ma9 6:M7 3:a9 7:M 4:m7')

add('Funk','Dominant pocket','Mixolydian','1:D7 4:D7 7:M 2:m7 5:m7')
add('Funk','Dorian pocket','Dorian','1:m7 4:D7 7:M7 2:m7 5:m7')
add('Funk','Bright syncopation','Major','1:M6 2:m7 4:M7 5:D7 6:m7')
add('Disco','Major shimmer','Major','1:M7 6:m7 2:m7 5:D7 4:M7')
add('Disco','Minor movement','Minor','1:m7 4:m7 7:D7 3:M7 6:M7')
add('Disco','Dorian strings','Dorian','1:m7 4:D7 2:m7 7:M7 5:m7')
add('Gospel','Major praise','Major','1:M 4:M 2:m7 5:D7 6:m7 3:m7')
add('Gospel','Warm church colors','Major','1:M6 4:M7 6:m7 2:m7 5:s4 5:D7')
add('Gospel','Passing tension','Major','1:M7 6:D7 2:m7 2:D7 5:D7 4:M7 7:d7')
add('Latin','Bolero major','Major','1:M 6:m 2:m 5:D7 4:M 3:D7')
add('Latin','Bolero minor','Harmonic Minor','1:m 4:m 2:h7 5:D7 6:M 3:M')
add('Latin','Bossa colors','Major','1:M7 6:m7 2:m7 5:D7 4:M7 3:D7')
add('Latin','Latin jazz minor','Harmonic Minor','1:m6 4:m7 2:h7 5:D7 6:M7')
add('Afrobeats','Sunny guitar','Major','1:M 5:M 6:m 4:M 2:m')
add('Afrobeats','Minor sway','Minor','1:m 7:M 6:M 3:M 4:m')
add('Afrobeats','Warm keys','Major','1:M7 4:M7 6:m7 5:M 2:m7')
add('Afrobeats','Dorian breeze','Dorian','1:m7 4:M 7:M 3:M7 5:m7')
add('Lo-fi','Soft tape','Major','1:M7 6:m7 2:m7 4:M7 5:D7')
add('Lo-fi','Rainy window','Minor','1:m9 4:m7 6:M7 3:M7 7:M')
add('Lo-fi','Dorian haze','Dorian','1:m7 2:m7 4:D7 7:M7 3:M7')
add('Ambient','Major space','Major','1:s2 4:M7 6:m7 5:s4 2:m7')
add('Ambient','Minor drift','Minor','1:ma9 6:M7 4:m7 7:s2 3:M7')
add('Ambient','Lydian light','Lydian','1:M7 2:M 5:M7 6:m7 3:m7')
add('Cinematic','Heroic lift','Major','1:M 4:M 6:m 5:M 2:m 3:m')
add('Cinematic','Dark landscape','Minor','1:m 6:M 4:m 3:M 7:M 5:M')
add('Cinematic','Suspense colors','Harmonic Minor','1:m 2:d 4:m 5:D7 7:d7 6:M')
add('Cinematic','Floating wonder','Lydian','1:M7 2:M 5:M 6:m 3:m')
add('Metal','Natural minor riffs','Minor','1:p 6:p 7:p 4:p 5:p 3:p')
add('Metal','Phrygian edge','Phrygian','1:p 2:p 7:p 6:p 4:p')
add('Metal','Harmonic drama','Harmonic Minor','1:m 5:M 6:M 4:m 2:d 7:d')
add('Punk','Major power','Major','1:p 4:p 5:p 6:p 2:p')
add('Punk','Minor power','Minor','1:p 6:p 7:p 3:p 4:p')
add('Punk','Pop punk colors','Major','1:M 5:M 6:m 4:M 2:m 3:m')
add('Synthwave','Neon minor','Minor','1:m 6:M 3:M 7:M 4:m')
add('Synthwave','Night drive','Minor','1:m7 6:M7 4:m7 7:M 3:M7')
add('Synthwave','Retro glow','Major','1:M7 4:M7 6:m7 5:s4 2:m7')
add('House','Classic piano','Minor','1:m7 4:m7 7:D7 3:M7 6:M7')
add('House','Soulful house','Major','2:m7 5:D7 1:M7 6:m7 4:M7')
add('House','Deep Dorian','Dorian','1:m9 4:D7 7:M7 2:m7 5:m7')
add('Techno','Minor stabs','Minor','1:m 4:m 6:M 7:M')
add('Techno','Dub stabs','Dorian','1:m7 4:D7 7:M 5:m7')
add('Techno','Suspended pulse','Minor','1:s2 4:s4 6:p 7:p 5:p')
add('Trance','Uplifting minor','Minor','1:m 6:M 3:M 7:M 4:m 5:m')
add('Trance','Major horizon','Major','6:m 4:M 1:M 5:M 2:m 3:m')
add('Trance','Suspended horizon','Minor','1:ma9 6:M7 3:a9 7:s4 4:m7')
add('Drum & Bass','Liquid soul','Major','2:m9 5:D7 1:M9 6:m7 4:M7')
add('Drum & Bass','Liquid minor','Minor','1:m9 4:m7 6:M7 3:M7 7:M')
add('Drum & Bass','Dark motion','Phrygian','1:m 2:M 7:m 6:M 4:m')
add('Garage / UK bass','Warm garage','Major','1:M7 6:m7 2:m7 5:D7 4:M7')
add('Garage / UK bass','Minor shuffle','Minor','1:m7 4:m7 6:M7 7:M 3:M7')
add('Garage / UK bass','Dorian bass','Dorian','1:m7 4:D7 7:M 2:m7 5:m7')
add('Indie / Alternative','Jangle colors','Major','1:a9 4:M7 2:m7 6:m 5:s4')
add('Indie / Alternative','Melancholy guitar','Minor','1:m 3:M7 6:M7 4:m7 7:M')
add('Indie / Alternative','Modal sunshine','Mixolydian','1:M 7:M 4:a9 2:m 5:m')

M.groups={}
local group_by_name={}
for index,preset in ipairs(M.presets) do
  local group=group_by_name[preset.category]
  if not group then
    group={name=preset.category,indices={}}
    M.groups[#M.groups+1]=group; group_by_name[preset.category]=group
  end
  group.indices[#group.indices+1]=index
end
function M.group_for(index)
  for number,group in ipairs(M.groups) do
    for _,value in ipairs(group.indices) do if value==index then return number end end
  end
  return 1
end

function M.resolve(settings,preset,index)
  index=math.max(1,math.min(#preset.degrees,index or 1))
  local degree=preset.degrees[index]
  local intervals=Music.scales[settings.chord_diatonic and settings.scale_name or preset.scale]
  local offset=intervals[(degree-1)%#intervals+1]
  local root=60+settings.scale_root+offset
  local shape=preset.qualities[index]
  local size=preset.size or (#Music.chords[shape]>=4 and 4 or 3)
  local chord={scale_root=settings.scale_root,scale_name=settings.scale_name,
    chord_diatonic=settings.chord_diatonic,chord_name=shape,chord_size=size,
    chord_inversion=settings.chord_inversion or 0}
  local pitches=Music.chord_pitches(chord,root)
  local outside=false
  for _,pitch in ipairs(pitches) do
    if not Music.contains(settings.scale_root,settings.scale_name,pitch) then outside=true end
  end
  return root,pitches,chord,outside
end

function M.select(settings,preset,index)
  local root,pitches,chord,outside=M.resolve(settings,preset,index)
  settings.chord_name=chord.chord_name
  settings.chord_size=chord.chord_size
  return root,pitches,outside
end
return M
