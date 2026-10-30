-- @noindex
local Music=require 'src.music'
local M={key='P_EXT:ReaRollHarmonyRegions'}
local function track(app)return require('src.instrument_map').track(app)end
local function finite(n)return type(n)=='number' and n==n and n>=0 and n<1e7 end
function M.new()return {enabled=false,regions={}}end
function M.validate(data)
  if type(data)~='table' or type(data.regions)~='table' or #data.regions>256 then return false end
  local sorted={}
  for _,r in ipairs(data.regions)do
    if not finite(r.start_qn) or not finite(r.end_qn) or r.end_qn<=r.start_qn or type(r.root)~='number' or r.root%1~=0 or r.root<0 or r.root>11 or not Music.scales[r.scale]then return false end
    sorted[#sorted+1]=r
  end
  table.sort(sorted,function(a,b)return a.start_qn<b.start_qn end)
  for i=2,#sorted do if sorted[i].start_qn<sorted[i-1].end_qn-1e-9 then return false end end
  return true
end
function M.encode(data)
  assert(M.validate(data),'Invalid harmony regions')
  local out={'RRKEYS1\t'..(data.enabled and '1' or '0')}
  for _,r in ipairs(data.regions)do out[#out+1]=string.format('%.17g\t%.17g\t%d\t%s',r.start_qn,r.end_qn,r.root,r.scale)end
  return table.concat(out,'\n')
end
function M.decode(raw)
  if raw==nil or raw=='' then return M.new()end
  if type(raw)~='string' or #raw>30000 then return nil,'Harmony-region data is too large.'end
  local lines={};for line in (raw..'\n'):gmatch('(.-)\n')do lines[#lines+1]=line end
  local enabled=lines[1]:match('^RRKEYS1\t([01])$');if not enabled then return nil,'Unknown harmony-region format.'end
  local data={enabled=enabled=='1',regions={}}
  for i=2,#lines do local a,b,c,d=lines[i]:match('^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$');if not a then return nil,'Malformed harmony region.'end
    data.regions[#data.regions+1]={start_qn=tonumber(a),end_qn=tonumber(b),root=tonumber(c),scale=d}
  end
  if not M.validate(data)then return nil,'Regions must have valid keys and non-overlapping positive time ranges.'end
  return data
end
-- Regional harmony is retired from the editor. Preserve project metadata on disk,
-- but always use the shared scale for drawing, snapping and scale-only rows.
function M.refresh(app,force)
  app.harmony_regions=M.new()
end
function M.at(app,q)
  return app.settings.scale_root,app.settings.scale_name
end
function M.snap(app,q,p,direction)local root,scale=M.at(app,q);return Music.snap(root,scale,p,direction)end
function M.chord(app,q,p)
  if app.settings.chord_follow_track then local entry=require('src.chord_track').at(app,q);if entry then return require('src.chord_track').pitches(entry,p)end end
  local root,scale=M.at(app,q);local settings={};for k,v in pairs(app.settings)do settings[k]=v end
  settings.scale_root=root;settings.scale_name=scale;return Music.chord_pitches(settings,p)
end
function M.save(app,data)
  local tr=track(app);if not tr or not M.validate(data)then return false,'Choose a track and non-overlapping time ranges with valid keys.'end
  if app.transform_preview or app.gesture then return false,'Finish the current preview or gesture first.'end
  local raw=M.encode(data);local _,before=reaper.GetSetMediaTrackInfo_String(tr,M.key,'',false);if raw==before then return true end
  reaper.Undo_BeginBlock2(0);local ok=reaper.GetSetMediaTrackInfo_String(tr,M.key,raw,true)
  reaper.Undo_EndBlock2(0,'ReaRoll: harmony regions',ok and 1 or 0)
  if not ok then return false,'Could not save harmony regions.'end
  app.harmony_regions=data;app.harmony_region_track=tr;app.harmony_region_raw=raw;return true
end
function M.draw(app,d,v,y,height)
  local data=app.harmony_regions;if not data or not data.enabled then return end
  local I,c,T=app.ImGui,app.ctx,app.theme
  I.DrawList_PushClipRect(d,v.x,y,v.x+v.w,y+height,true)
  for i,r in ipairs(data.regions)do
    local a,b=math.max(v.x,v:x_from_qn(r.start_qn)),math.min(v.x+v.w,v:x_from_qn(r.end_qn))
    if b>a then
      I.DrawList_AddRectFilled(d,a,y,b,y+height,(T.accent&0xFFFFFF00)|65)
      I.DrawList_AddLine(d,a,y,a,y+height,T.accent)
      local text=Music.roots[r.root+1]..' '..r.scale
      I.DrawList_PushClipRect(d,a,y,b,y+height,true);I.DrawList_AddText(d,a+4,y,T.text,text);I.DrawList_PopClipRect(d)
      local mx,my=I.GetMousePos(c)
      if mx>=a and mx<=b and my>=y and my<=y+height then
        I.SetTooltip(c,text..' / '..r.start_qn..'–'..r.end_qn..' beats\nDouble-click to edit harmony regions')
        if I.IsMouseDoubleClicked(c,I.MouseButton_Left)then app.harmony_regions_open=true;app.harmony_region_index=i;app.harmony_region_draft=nil end
      end
    end
  end
  I.DrawList_PopClipRect(d)
end
return M
