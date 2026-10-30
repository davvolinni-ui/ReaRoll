-- @noindex
local C=require 'src.chord_track';local Music=require 'src.music'
local M={}
local function clone(t)local out={};for k,v in pairs(t)do out[k]=v end;return out end
local function save(app,data)local ok,notice=C.save(app,data);app.chord_track_notice=notice;return ok end
function M.draw(app)
  if not app.chord_track_open then return end
  C.refresh(app)
  local I,c=app.ImGui,app.ctx;I.SetNextWindowSize(c,520,630,I.Cond_FirstUseEver)
  local visible;visible,app.chord_track_open=I.Begin(c,'Chord progression',app.chord_track_open)
  if visible then
    local data=app.chord_track or C.new();local hit,enabled=I.Checkbox(c,'Show chord track',data.enabled)
    if hit then local changed=C.copy(data);changed.enabled=enabled;save(app,changed);data=app.chord_track or data end
    hit,app.settings.chord_follow_track=I.Checkbox(c,'Chord drawing follows progression',app.settings.chord_follow_track==true)
    I.TextWrapped(c,'Chords belong to this track and use project beats. Editing this lane leaves existing MIDI unchanged. Insert progression writes notes on the toolbar channel in one Undo.')
    app.chord_track_index=math.max(1,math.min(app.chord_track_index or 1,math.max(1,#data.chords)))
    local entry=data.chords[app.chord_track_index]
    if I.BeginCombo(c,'Chord',entry and (C.label(entry)..' ['..entry.start_qn..'–'..entry.end_qn..']')or 'No chords')then
      for i,a in ipairs(data.chords)do if I.Selectable(c,i..'. '..C.label(a)..' ['..a.start_qn..'–'..a.end_qn..']',i==app.chord_track_index)then app.chord_track_index=i;app.chord_track_draft=nil end end;I.EndCombo(c)
    end
    if I.Button(c,'New chord at edit cursor')then local q=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition());app.chord_track_draft={start_qn=q,end_qn=q+4,root=60+(app.settings.scale_root or 0),quality='Major',inversion=0,new=true}end
    if entry or app.chord_track_draft then
      app.chord_track_draft=app.chord_track_draft or clone(entry);local draft=app.chord_track_draft
      hit,draft.start_qn=I.InputDouble(c,'Start (project beats)',draft.start_qn,.25,4,'%.3f')
      hit,draft.end_qn=I.InputDouble(c,'End (project beats)',draft.end_qn,.25,4,'%.3f')
      hit,draft.root=I.SliderInt(c,'Root MIDI pitch',draft.root,0,127)
      I.SameLine(c);I.Text(c,require('src.util').pitch_name(draft.root))
      if I.BeginCombo(c,'Chord quality',draft.quality)then for _,quality in ipairs(Music.chord_order)do if I.Selectable(c,quality,draft.quality==quality)then draft.quality=quality;draft.inversion=math.min(draft.inversion,#Music.chords[quality]-1)end end;I.EndCombo(c)end
      hit,draft.inversion=I.SliderInt(c,'Inversion',draft.inversion,0,#Music.chords[draft.quality]-1)
      local names={};for _,pitch in ipairs(C.pitches(draft))do names[#names+1]=require('src.util').pitch_name(pitch)end;I.TextWrapped(c,table.concat(names,'  '))
      if I.Button(c,'Save chord')then local changed=C.copy(data);local a=clone(draft);a.new=nil
        if draft.new then changed.chords[#changed.chords+1]=a else changed.chords[app.chord_track_index]=a end
        if save(app,changed)then if draft.new then app.chord_track_index=#changed.chords end;app.chord_track_draft=nil;data=app.chord_track end
      end
      I.SameLine(c);if I.Button(c,'Cancel chord edit')then app.chord_track_draft=nil end
      if entry and not draft.new then
        if I.Button(c,'Duplicate after chord')then local changed=C.copy(data);local a=clone(entry);a.start_qn=entry.end_qn;a.end_qn=a.start_qn+entry.end_qn-entry.start_qn;changed.chords[#changed.chords+1]=a
          if save(app,changed)then app.chord_track_index=#changed.chords;app.chord_track_draft=nil;data=app.chord_track end
        end
        I.SameLine(c);if I.Button(c,'Delete chord')then local changed=C.copy(data);table.remove(changed.chords,app.chord_track_index);if save(app,changed)then app.chord_track_draft=nil;data=app.chord_track end end
      end
    end
    I.Separator(c)
    if I.Button(c,'Capture selected MIDI chords')then app.chord_sequence_preview,app.chord_track_notice=C.capture(app)end
    if I.Button(c,'Prepare I – vi – IV – V')then
      local q=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition());local root=48+(app.settings.scale_root or 0)
      local sequence={enabled=true,chords={}};for i,a in ipairs({{0,'Major'},{9,'Minor'},{5,'Major'},{7,'Dominant7'}})do sequence.chords[i]={start_qn=q+(i-1)*4,end_qn=q+i*4,root=root+a[1],quality=a[2],inversion=0}end
      app.chord_sequence_preview=sequence
    end
    if app.chord_sequence_preview then
      I.TextWrapped(c,'Review: '..#app.chord_sequence_preview.chords..' chords will replace the chord track. Existing MIDI stays unchanged.')
      for i,a in ipairs(app.chord_sequence_preview.chords)do if i<=12 then I.Text(c,C.label(a)..' / '..a.start_qn..'–'..a.end_qn)end end
      if I.Button(c,'Apply progression to track')then if save(app,app.chord_sequence_preview)then app.chord_sequence_preview=nil;app.chord_track_draft=nil;data=app.chord_track end end
      I.SameLine(c);if I.Button(c,'Cancel progression')then app.chord_sequence_preview=nil end
    end
    if I.Button(c,'Review MIDI insertion')then
      local plan,notice=C.plan(app,data);app.chord_track_notice=notice
      app.chord_insert_review=plan and {data=C.copy(data),count=#plan}or nil
    end
    if app.chord_insert_review then
      I.TextWrapped(c,app.chord_insert_review.count..' notes on channel '..((app.settings.channel or 0)+1)..'. Apply rechecks item bounds, locking and overlaps.')
      if I.Button(c,'Insert progression as MIDI')then local ok,notice=C.insert(app,app.chord_insert_review.data);app.chord_track_notice=notice;if ok then app.chord_insert_review=nil end end
      I.SameLine(c);if I.Button(c,'Cancel insertion')then app.chord_insert_review=nil end
    end
    if I.Button(c,'Copy progression to clipboard')then I.SetClipboardText(c,C.encode(data))end
    I.SameLine(c);if I.Button(c,'Read progression from clipboard')then app.chord_sequence_preview,app.chord_track_notice=C.decode(I.GetClipboardText(c):gsub('\r\n','\n'):gsub('\n+$',''))end
    if app.chord_track_notice then I.TextWrapped(c,app.chord_track_notice)end
  end
  if visible then I.End(c)end
end
return M
