-- @noindex
local H=require 'src.harmony_regions';local Music=require 'src.music'
local M={}
local function copy(t)local out={};for k,v in pairs(t)do out[k]=v end;return out end
function M.draw(app)
  if not app.harmony_regions_open then return end
  H.refresh(app)
  local I,c=app.ImGui,app.ctx;I.SetNextWindowSize(c,430,420,I.Cond_FirstUseEver)
  local visible;visible,app.harmony_regions_open=I.Begin(c,'Harmony regions',app.harmony_regions_open)
  if visible then
    local data=app.harmony_regions or H.new()
    I.TextWrapped(c,'Track-specific key/scale regions use project beats. Drawing with Pitch Safe, diatonic chord drawing and Scale quantize use the key at each note onset. Existing notes are unchanged until you edit them.')
    local hit,enabled=I.Checkbox(c,'Use regional harmony',data.enabled)
    if hit then local changed=assert(H.decode(H.encode(data)));changed.enabled=enabled;local _,notice=H.save(app,changed);app.harmony_region_notice=notice;data=app.harmony_regions or data end
    app.harmony_region_index=math.max(1,math.min(app.harmony_region_index or 1,math.max(1,#data.regions)))
    local region=data.regions[app.harmony_region_index]
    if I.BeginCombo(c,'Region',region and (Music.roots[region.root+1]..' '..region.scale..' ['..region.start_qn..'–'..region.end_qn..']') or 'No regions')then
      for i,r in ipairs(data.regions)do if I.Selectable(c,i..'. '..Music.roots[r.root+1]..' '..r.scale..' ['..r.start_qn..'–'..r.end_qn..']',i==app.harmony_region_index)then app.harmony_region_index=i;app.harmony_region_draft=nil end end
      I.EndCombo(c)
    end
    if I.Button(c,'New region at edit cursor')then local q=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition());app.harmony_region_draft={start_qn=q,end_qn=q+4,root=app.settings.scale_root,scale=app.settings.scale_name,new=true}end
    if region or app.harmony_region_draft then
      app.harmony_region_draft=app.harmony_region_draft or copy(region);local draft=app.harmony_region_draft
      hit,draft.start_qn=I.InputDouble(c,'Start (project beats)',draft.start_qn,.25,4,'%.3f')
      hit,draft.end_qn=I.InputDouble(c,'End (project beats)',draft.end_qn,.25,4,'%.3f')
      if I.BeginCombo(c,'Root',Music.roots[draft.root+1])then for i,name in ipairs(Music.roots)do if I.Selectable(c,name,draft.root==i-1)then draft.root=i-1 end end;I.EndCombo(c)end
      if I.BeginCombo(c,'Scale',draft.scale)then local names={};for name in pairs(Music.scales)do names[#names+1]=name end;table.sort(names);for _,name in ipairs(names)do if I.Selectable(c,name,draft.scale==name)then draft.scale=name end end;I.EndCombo(c)end
      if I.Button(c,'Use selected-note time range')then
        local notes=require('src.selection').list(app.selection,app.cache:get(false));local a,b=math.huge,-math.huge
        for _,n in ipairs(notes)do a=math.min(a,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s));b=math.max(b,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e))end
        if #notes>0 then draft.start_qn,draft.end_qn=a,b else app.harmony_region_notice='Select notes to use their time range.'end
      end
      if I.Button(c,'Save region')then
        local changed=assert(H.decode(H.encode(data)));local r=copy(draft);r.new=nil
        if draft.new then changed.regions[#changed.regions+1]=r else changed.regions[app.harmony_region_index]=r end
        local ok,notice=H.save(app,changed);app.harmony_region_notice=notice
        if ok then if draft.new then app.harmony_region_index=#changed.regions end;app.harmony_region_draft=nil end
      end
      if region and not draft.new then I.SameLine(c);if I.Button(c,'Delete region')then local changed=assert(H.decode(H.encode(data)));table.remove(changed.regions,app.harmony_region_index);local _,notice=H.save(app,changed);app.harmony_region_notice=notice;app.harmony_region_draft=nil end end
    end
    I.TextWrapped(c,'Regions cannot overlap. Endpoints are exclusive. Gaps use the global Harmony key. Scale-only view shows the union of the global scale and enabled regional scales, so notes in a regional key remain visible.')
    if app.harmony_region_notice then I.TextWrapped(c,app.harmony_region_notice)end
  end
  if visible then I.End(c)end
end
return M
