-- Local database browser. Reference tables remain owned by ForeverDB.
do
 local panel, db, index, results, selected, page, category, history, query = nil,nil,nil,{},nil,1,'All',nil,''
 local function name(t,id) local r=t and t[id]; return type(r)=='table' and r[1] or nil end
 local function money(n) n=math.floor(tonumber(n) or 0);return string.format('%dg %02ds %02dc',math.floor(n/10000),math.floor(n/100)%100,n%100) end
 local function load()
  if not ForeverDB or not ForeverDB.npc then if C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn,'ForeverDB') end end
  if not ForeverDB or not ForeverDB.npc then return false end
  db=ForeverDB;return true
 end
 local kinds={{'Items','item'},{'NPCs','npc'},{'Quests','quest'},{'Objects','obj'},{'Zones','umap'}}
 local function build()
  index={}
  for _,k in ipairs(kinds) do for id,r in pairs(db[k[2]] or {}) do if type(r)=='table' and type(r[1])=='string' then index[#index+1]={kind=k[1],id=id,name=r[1],r=r,key=r[1]:lower()} end end end
 end
 local function locations(key)
  local a={};for id,coords in pairs((db.spm or {})[key] or {}) do if type(coords)=='table' then a[#a+1]=(name(db.umap,id) or ('Map '..id))..' ('..math.floor(#coords/2)..' pins)' end end;table.sort(a);return table.concat(a,', ')
 end
 local function label(e)
  local r=e.r
  if e.kind=='NPCs' then return e.name..' | Lv '..tostring(r[3] or '?')..'-'..tostring(r[4] or '?') end
  if e.kind=='Items' then return e.name..' | Quality '..tostring(r[2] or '?') end
  if e.kind=='Quests' then return e.name..' | Lv '..tostring(r[2] or '?') end
  return e.name
 end
 local function detail(e)
  local a={};local function add(s) a[#a+1]=s end
  local function ref(key) local p,id=tostring(key):match('^([co])(%d+)$');return p and (name(p=='c' and db.npc or db.obj,tonumber(id)) or key) or tostring(key) end
  local function drops(t, target, sourceTable, prefix)
   if target then for iid,rr in pairs(t or {}) do for j=1,#rr-1,2 do if rr[j]==target then add((name(db.item,iid) or ('Item '..iid))..' | '..string.format('%.2f%%',rr[j+1]/100)) end end end
   else for j=1,#(t or {})-1,2 do local id=t[j];add((name(sourceTable,id) or (prefix..id))..' | '..string.format('%.2f%%',t[j+1]/100)) end end
  end
  if e.kind=='Items' then
   add('Creature drops');drops((db.drop or {})[e.id],nil,db.npc,'NPC ')
   add('Object drops');drops((db.odrop or {})[e.id],nil,db.obj,'Object ')
   add('Container sources');drops((db.idrop or {})[e.id],nil,db.item,'Item ')
   add('Vendors');for id,v in pairs((db.vp or {})[e.id] or {}) do add((name(db.npc,id) or ('NPC '..id))..' | '..money(v[1])..' | '..locations('c'..id)) end
   for _,id in ipairs((db.rew or {})[e.id] or {}) do add('Quest reward: '..(name(db.quest,id) or id)) end
  elseif e.kind=='NPCs' or e.kind=='Objects' then
   local npc=e.kind=='NPCs';local key=(npc and 'c' or 'o')..e.id
   add('Locations: '..(locations(key)~='' and locations(key) or 'No map pins'))
   if db.note and db.note[key] then add(db.note[key]) end
   if db.resp and db.resp[key] then add('Recorded respawn: '..db.resp[key]..' sec') end
   add('Loot table');drops(npc and db.drop or db.odrop,e.id)
   if npc then for _,id in ipairs((db.vend or {})[e.id] or {}) do add('Sells: '..(name(db.item,id) or id)) end end
  elseif e.kind=='Quests' then
   add('Minimum level: '..tostring(e.r[3] or '?'))
   for _,k in ipairs((db.qg or {})[e.id] or {}) do add('Starts: '..ref(k)..' | '..locations(k)) end
   for _,k in ipairs((db.qe or {})[e.id] or {}) do add('Ends: '..ref(k)..' | '..locations(k)) end
   local q=(db.qinfo or {})[e.id];if q and q.xb then add('Database base XP: '..q.xb) end
   for id,qs in pairs(db.rew or {}) do for _,v in ipairs(qs) do if v==e.id then add('Reward: '..(name(db.item,id) or id)) end end end
  elseif e.kind=='Zones' then
   for key,maps in pairs(db.spm or {}) do if maps[e.id] then add(ref(key)..' | '..math.floor(#maps[e.id]/2)..' pins') end end
  elseif e.kind=='History' then
   local r=e.r;add('Recorded time: '..math.floor((r.seconds or 0)/60)..' min');add('Kills: '..(r.kills or 0));if (r.seconds or 0)>=60 then add('Gold/hr: '..money(((r.coin or 0)+(r.vendor or 0))*3600/r.seconds)) end;if (r.xpSeconds or 0)>=60 then add('XP/hr: '..math.floor((r.xp or 0)*3600/r.xpSeconds)) end
  end
  return #a>0 and a or {'No additional data available.'}
 end
 local function render()
  local entries=selected and selected.details or results;local max=math.max(1,math.ceil(#entries/11));page=math.min(math.max(page,1),max)
  panel.status:SetText((selected and label(selected) or (#entries..' results | '..category))..'   |   Page '..page..'/'..max)
  for i,b in ipairs(panel.rows) do local e=entries[(page-1)*11+i];b.entry=not selected and e or nil;b.label:SetText(e and (selected and e or (e.kind..' | '..label(e))) or '');if e then b:Show() else b:Hide() end end
 end
 local function search()
  query=panel.input:GetText():lower():match('^%s*(.-)%s*$');selected=nil;page=1;results={}
  local function match(e) if category~='All' and e.kind~=category then return end;for word in query:gmatch('%S+') do if not e.key:find(word,1,true) and tostring(e.id)~=word then return end end;results[#results+1]=e end
  if index then for _,e in ipairs(index) do match(e) end end
  for k,r in pairs(history and history.zones or {}) do match({kind='History',id=k,name=k,key=k:lower(),r=r}) end
  table.sort(results,function(a,b) local x=a.key==query;local y=b.key==query;if x~=y then return x end;if a.key==b.key then return tostring(a.id)<tostring(b.id) end;return a.key<b.key end);render()
  if not db then panel.status:SetText('ForeverDB missing or disabled; personal history only.') end
 end
 function GrindOnlyShowExplorer(parent,h)
  history=h
  if panel then panel:Show();return end
  if load() then build() end
  panel=CreateFrame('Frame',nil,parent);panel:SetPoint('TOPLEFT',12,-110);panel:SetPoint('BOTTOMRIGHT',-12,8);panel:SetFrameLevel(parent:GetFrameLevel()+10)
  local bg=panel:CreateTexture(nil,'BACKGROUND');bg:SetAllPoints();bg:SetColorTexture(.055,.075,.105,1)
  local function button(txt,x,y,w,fn) local b=CreateFrame('Button',nil,panel,'UIPanelButtonTemplate');b:SetSize(w,23);b:SetPoint('TOPLEFT',x,y);b:SetText(txt);b:SetScript('OnClick',fn);return b end
  local input=CreateFrame('EditBox',nil,panel,'InputBoxTemplate');input:SetSize(545,25);input:SetPoint('TOPLEFT',12,-8);input:SetAutoFocus(false);input:SetMaxLetters(120);panel.input=input;input:SetScript('OnEnterPressed',function(self)self:ClearFocus();search()end);input:SetScript('OnEscapePressed',function(self)self:ClearFocus()end)
  button('Search',565,-8,78,search);button('Back',650,-8,65,function()selected=nil;page=1;render()end)
  for i,k in ipairs({'All','Items','NPCs','Quests','Objects','Zones','History'}) do button(k,8+(i-1)*99,-39,95,function()category=k;search()end) end
  panel.status=panel:CreateFontString(nil,'OVERLAY','GameFontNormalSmall');panel.status:SetPoint('TOPLEFT',10,-70);panel.status:SetWidth(710);panel.status:SetJustifyH('LEFT')
  panel.rows={};for i=1,11 do local b=CreateFrame('Button',nil,panel);b:SetSize(715,23);b:SetPoint('TOPLEFT',8,-92-(i-1)*24);local t=b:CreateTexture(nil,'BACKGROUND');t:SetAllPoints();t:SetColorTexture(.19,.25,.32,.55);b:SetHighlightTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight');b.label=b:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall');b.label:SetPoint('LEFT',5,0);b.label:SetWidth(705);b.label:SetJustifyH('LEFT');b.label:SetWordWrap(false);b:SetScript('OnClick',function(self)if self.entry then selected=self.entry;selected.details=detail(selected);page=1;render()end end);panel.rows[i]=b end
  button('< Prev',8,-365,75,function()page=page-1;render()end);button('Next >',88,-365,75,function()page=page+1;render()end)
  local credit=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall');credit:SetPoint('TOPRIGHT',-15,-371);credit:SetText('ForeverDB by fatedfr | Local data')
  search()
 end
 function GrindOnlyHideExplorer() if panel then panel:Hide() end end
end
