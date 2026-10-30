-- @noindex
-- A single MIDI bend applies to the whole connected overlap group. The linked
-- saved ownership domain includes every member through the final release.
local M={}
function M.members(stream,note,domain_first,domain_last)
  local members={[note.index or note]=true};local first,last=require('src.slide_links').domain(note);first=domain_first or first;last=domain_last or last;local changed=true
  while changed do changed=false
    for _,other in ipairs(stream.notes)do if other.chan==note.chan and other.s<last and other.e>first and not members[other.index or other]then
      members[other.index or other]=true;first=math.min(first,other.s);last=math.max(last,other.e);changed=true
    end end
  end
  return members,first,last
end
function M.cohort(stream,note,selected)
  local members,first,last=M.members(stream,note)
  local saved_first,saved_last=require('src.slide_links').domain(note)
  if first<saved_first or last>saved_last then return nil,'The shared-channel slide group changed. Redraw its target before moving the complete group.'end
  members[note.index or note]=nil
  for index in pairs(members)do if not(selected and selected[index])then return nil,'Select the entire shared-channel slide group to carry its pitch data.'end end
  return members
end
function M.within(reference,target)
  local first,last=require('src.slide_links').domain(reference)
  return target and target.chan==reference.chan and target.s>=first and target.e<=last and target.e>target.s
end
function M.require_complete(stream,selected)
  local Links=require 'src.slide_links'
  for _,reference in ipairs(stream.notes)do if Links.has(reference)then
    local members=M.members(stream,reference);local touched=false
    for index in pairs(members)do touched=touched or selected[index]end
    if touched then
      if not selected[reference.index]then return false,'Copy the complete shared-channel slide group to retain its pitch data.'end
      local cohort,notice=M.cohort(stream,reference,selected);if not cohort then return false,notice end
    end
  end end
  return true
end
function M.mapped(reference,destination,note,target)
  if not destination or not target or destination.chan~=target.chan then return false end
  local scale=(destination.e-destination.s)/math.max(1,reference.e-reference.s)
  local function position(p)return math.floor(destination.s+(p-reference.s)*scale+.5)end
  local shifted=target.s==note.s+destination.s-reference.s and target.e==note.e+destination.e-reference.e
  return target.e>target.s and(shifted or target.s==position(note.s)and target.e==position(note.e))
end
return M
