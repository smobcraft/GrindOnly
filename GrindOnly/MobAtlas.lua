-- Grind Only Mob Atlas - ForeverDB integration (WoW Forever 1.60.1)
-- Reference data remains in ForeverDB; no copy is saved to GrindOnlyDB.
do
  local D, atlas, mapID, selectedID, page, matches, pins = nil,nil,nil,nil,1,{},{}
  local filterText, filterMin, filterMax = '',0,99
  local mapWasVisible=false
  local function cash(n)
    n=math.max(0,math.floor(tonumber(n) or 0))
    return string.format('%dg %02ds %02dc',math.floor(n/10000),math.floor(n/100)%100,n%100)
  end
  local function loadDB()
    if type(ForeverDB)=='table' and type(ForeverDB.npc)=='table' then D=ForeverDB;return true end
    if C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn,'ForeverDB')
    elseif LoadAddOn then pcall(LoadAddOn,'ForeverDB') end
    if type(ForeverDB)=='table' and type(ForeverDB.npc)=='table' then D=ForeverDB;return true end
    return false
  end
  local function npc(id) return D and D.npc and D.npc[id] end
  local function itemName(id)
    local entry=D and D.item and D.item[id]
    return (entry and entry[1]) or (GetItemInfo and GetItemInfo(id)) or ('Item #'..id)
  end
  local function price(id)
    -- GetItemInfo returns vendor sell price as its 11th result when cached.
    if GetItemInfo then
      local ok,_,_,_,_,_,_,_,_,_,sell=pcall(GetItemInfo,id)
      if ok and type(sell)=='number' and sell>=0 then return sell end
    end
    -- Item price data is not guaranteed to be present in ForeverDB.vp.
    local p=D and D.vp and D.vp[id]
    if type(p)=='number' then return p end
    return nil
  end
  local function dropsFor(id)
    local out={};if not D or type(D.drop)~='table' then return out end
    -- ForeverDB.drop is ITEM-centric, with flat {npc, chance, ...} rows.
    for itemID,sources in pairs(D.drop) do
      if type(sources)=='table' then
        for i=1,#sources do
          local r=sources[i]
          if type(r)=='table' then
            local src=r[1] or r.npc or r.source
            local srcID=tonumber(src) or (type(src)=='string' and tonumber(src:match('^c(%d+)$')))
            if srcID==id then
              local chance=tonumber(r[2] or r.chance)
              out[#out+1]={id=tonumber(itemID),chance=chance,price=price(tonumber(itemID))}
              break
            end
          end
        end
        -- Some builds use a flat numeric sequence: {npc, chance, npc, chance, ...}.
        if type(sources[1])=='number' then
          for i=1,#sources-1,2 do
            if sources[i]==id then
              out[#out+1]={id=tonumber(itemID),chance=tonumber(sources[i+1]),price=price(tonumber(itemID))}
              break
            end
          end
        end
      end
    end
    table.sort(out,function(a,b) return (a.chance or 0)>(b.chance or 0) end)
    return out
  end
  local function calculateEV(id,rows)
    local known,missing=0,0
    for _,r in ipairs(rows) do
      if r.chance and r.chance>0 and r.price then
        known=known+(r.chance/10000)*r.price
      else missing=missing+1 end
    end
    local g=D and D.gold and D.gold[id]
    local coin=(type(g)=='table' and tonumber(g[1])) or 0
    return known+coin,missing,coin
  end
  -- Tooltip loot is intentionally cached: scanning the item-centric drop table
  -- on every mouse movement would cause frame hitches on crowded maps.
  local tooltipCache = {}
  local forecastCache = {}
  local function tooltipRows(id)
    if tooltipCache[id] and GetTime()-forecastCache[id].t<60 then return tooltipCache[id] end
    local all=dropsFor(id)
    local ev,missing=calculateEV(id,all)
    forecastCache[id]={ev=ev,missing=missing,count=#all,coinKnown=type(D.gold and D.gold[id])=="table",t=GetTime()}
    local scored={}
    for _,r in ipairs(all) do
      if r.id and r.chance and r.chance>0 then
        local name=itemName(r.id)
        local quality=(D and D.item and D.item[r.id] and tonumber(D.item[r.id][3])) or nil
        local value=r.price and (r.price*r.chance/10000) or 0
        -- Prefer known-value materials and uncommon drops; suppress common
        -- gray trash, while still showing useful drops with unknown prices.
        local notable=(quality and quality>=2) or (r.chance<=3000) or value>=100
        if notable then
          scored[#scored+1]={name=name,chance=r.chance,quality=quality,value=value,
            score=(quality and quality>=2 and 300 or 0)+math.min(value,2000)/5+
              (r.chance<=1000 and 75 or 0)+(r.chance<=3000 and 20 or 0)}
        end
      end
    end
    table.sort(scored,function(a,b)
      if a.score==b.score then return a.chance>b.chance end
      return a.score>b.score
    end)
    local top={}
    for i=1,math.min(5,#scored) do top[i]=scored[i] end
    tooltipCache[id]=top
    return top
  end
  local function appendLootTooltip(tip,id,limit)
    if not loadDB() or not npc(id) then return end
    local rows=tooltipRows(id)
    if #rows==0 then return end
    tip:AddLine(' ')
    tip:AddLine('GRIND ONLY  /  NOTABLE LOOT',0.96,0.73,0.31)
    for i=1,math.min(limit or 5,#rows) do
      local r=rows[i]
      local color=(r.quality and r.quality>=2) and {0.4,0.9,0.55} or {0.88,0.91,0.95}
      tip:AddDoubleLine(r.name,string.format('%.2f%%',r.chance/100),color[1],color[2],color[3],0.96,0.73,0.31)
    end
    tip:AddLine('ForeverDB estimates; click a map marker for full loot',0.55,0.66,0.74,true)
  end
  local function guidNPCID(guid)
    if type(guid)~='string' then return nil end
    local id=guid:match('^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)')
      or guid:match('^Vehicle%-%d+%-%d+%-%d+%-%d+%-(%d+)')
    if id then return tonumber(id) end
    -- Classic GUIDs encode NPC entry in bits 24..39 of a 64-bit hex GUID.
    local hex=guid:match('^0x([%x]+)$')
    if hex and #hex>=10 then
      local entry=tonumber(hex:sub(-10,-7),16)
      if entry and entry>0 then return entry end
    end
  end
  -- Persist tooltip preference independently from the session-only loot cache.
  local function tooltipSettings()
    if type(GrindOnlyDB)~='table' then GrindOnlyDB={} end
    if type(GrindOnlyDB.mobAtlasSettings)~='table' then GrindOnlyDB.mobAtlasSettings={} end
    return GrindOnlyDB.mobAtlasSettings
  end
  local tooltipEnabled=tooltipSettings().notableTooltipEnabled~=false
  -- Native structured tooltip augmentation: Blizzard owns layout and visibility.
  local function readable(v)
    if type(issecretvalue)=='function' then
      local ok,secret=pcall(issecretvalue,v)
      if not ok or secret then return false end
    end
    return true
  end
  local function safeUnitValue(fn,unit)
    if type(fn)~='function' then return nil,false end
    local ok,v=pcall(fn,unit)
    if not ok or not readable(v) then return nil,false end
    return v,true
  end
  local appended=false
  local function setTooltipEnabled(enabled)
    tooltipEnabled=not not enabled
    tooltipSettings().notableTooltipEnabled=tooltipEnabled
    print('Grind Only Atlas: Mob loot tooltip '..(tooltipEnabled and 'ON' or 'OFF')..' (next hover)')
  end
  local function addNativeLoot(tip,data)
    if tip~=GameTooltip or appended or (not tooltipEnabled and tooltipSettings().predictionEnabled==false) then return end
    if not readable(data) or type(data)~='table' then return end
    if type(canaccesstable)=='function' and not canaccesstable(data) then return end
    local guid=data.guid
    if not readable(guid) or type(guid)~='string' then return end
    local id=guidNPCID(guid)
    if not id then return end
    local unit=data.unitToken
    if not readable(unit) then return end
    if type(unit)~='string' and tip.GetUnit then
      local ok,_,token=pcall(tip.GetUnit,tip)
      if ok and readable(token) then unit=token end
    end
    if type(unit)~='string' then return end
    local actual,actualOK=safeUnitValue(UnitGUID,unit)
    if not actualOK or actual~=guid then return end
    local dead,deadOK=safeUnitValue(UnitIsDeadOrGhost,unit)
    if not deadOK then dead,deadOK=safeUnitValue(UnitIsDead,unit) end
    if not deadOK or dead then return end
    if not loadDB() or not npc(id) then return end
    local rows=tooltipRows(id)
    appended=true
    if tooltipSettings().predictionEnabled~=false and GrindOnlyPrediction and GrindOnlyForecastContext then
      local pl,okP=safeUnitValue(UnitLevel,'player')
      local ml,okM=safeUnitValue(UnitLevel,unit)
      if okP and okM and type(pl)=='number' and type(ml)=='number' and ml>0 and pl>0 then
        local c=forecastCache[id]
        local active=GrindOnlyForecastContext(pl)
        local classification,clOK=safeUnitValue(UnitClassification,unit)
        local rest,restOK=safeUnitValue(GetXPExhaustion)
        if not clOK then classification=nil end
        if not restOK or type(rest)~="number" then rest=0 end
        local f=GrindOnlyPrediction.forecast(GrindOnlyDB,id,npc(id)[1],ml,pl,c.ev,c.missing,c.coinKnown,c.count,active,GetTime(),classification,rest)
        local maxXP,okXP=safeUnitValue(UnitXPMax,'player')
        if okXP and maxXP==0 then f.xpk=nil;f.xph=nil end
        tip:AddLine(' ')
        tip:AddLine('Grind Only - Projected Grinding',.96,.73,.31)
        tip:AddDoubleLine('Est. Gold/hr',f.gph and ('~'..cash(f.gph)) or '--',1,1,1,1,.82,.3)
        tip:AddDoubleLine('Est. XP/hr',f.xph and ('~'..math.floor(f.xph+.5)) or '--',1,1,1,.45,.75,1)
        tip:AddDoubleLine('Observed kills',tostring(f.kills),.8,.85,.9,.8,.85,.9)
        local _,score=GrindOnlyForecastContext(pl,f.gph,f.xph)
        if score then tip:AddDoubleLine('Projected efficiency',string.format('~%.1f / 10',score)) end
        tip:AddLine(f.confidence,.65,.72,.8)
        if tooltipSettings().predictionDetailed then
          tip:AddDoubleLine('Est. kills/hr',f.kph and tostring(math.floor(f.kph+.5)) or '--')
          tip:AddDoubleLine('Est. gold/kill',f.gpk and cash(f.gpk) or '--')
          tip:AddDoubleLine('Est. XP / next kill',f.xpk and tostring(math.floor(f.xpk+.5)) or '--')
          if f.source then tip:AddLine(f.source,.65,.72,.8) end
          if c.missing>0 then tip:AddLine('Some item values missing',.8,.65,.35) end
          tip:AddLine('Solo XP formula estimate; rested pool capped per hour. AoE kills may be missed.',.65,.72,.8,true)
        end
      end
    end
    if tooltipEnabled and #rows>0 then
      tip:AddLine(' ')
      tip:AddLine('Grind Only - Notable Loot',0.96,0.73,0.31)
      for i=1,math.min(5,#rows) do
        local r=rows[i]
        local c=(r.quality and r.quality>=2) and {0.4,0.9,0.55} or {0.88,0.91,0.95}
        tip:AddDoubleLine(r.name,string.format('%.2f%%',r.chance/100),c[1],c[2],c[3],0.96,0.73,0.31)
      end
      tip:AddLine('ForeverDB estimates',0.55,0.66,0.74)
    end
  end
  local nativeHookReady=false
  if GameTooltip and GameTooltip.HookScript and GameTooltip.GetPrimaryTooltipData
      and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
      and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
    local ok=pcall(GameTooltip.HookScript,GameTooltip,'OnTooltipCleared',function() appended=false end)
    if ok then
      nativeHookReady=pcall(TooltipDataProcessor.AddTooltipPostCall,Enum.TooltipDataType.Unit,function(tip,data)
        -- Fail closed if this client's payload contains restricted fields.
        pcall(addNativeLoot,tip,data)
      end)
    end
  end
  if not nativeHookReady then
    print('Grind Only Atlas: native mob tooltip hook unavailable; normal tooltips unchanged.')
  end
  -- Use the same solid-color texture API as the working Grind Only dashboard.
  -- WHITE8X8 is not guaranteed to exist on WoW Forever, and a missing
  -- texture leaves the entire atlas transparent, including its controls.
  local function solid(tex,r,g,b,a)
    if tex.SetColorTexture then
      tex:SetColorTexture(r,g,b,a or 1)
    else
      tex:SetTexture('Interface\\ChatFrame\\ChatFrameBackground')
      tex:SetVertexColor(r,g,b,a or 1)
    end
  end
  local f=CreateFrame('Frame','GrindOnlyMobAtlas',UIParent)
  f:SetSize(560,525);f:SetPoint('CENTER');f:SetFrameStrata('DIALOG');f:EnableMouse(true)
  f:SetMovable(true);f:RegisterForDrag('LeftButton');f:SetScript('OnDragStart',f.StartMoving);f:SetScript('OnDragStop',f.StopMovingOrSizing)
  local bg=f:CreateTexture(nil,'BACKGROUND');bg:SetAllPoints();solid(bg,0.045,0.073,0.105,0.97)
  local top=f:CreateTexture(nil,'BORDER');top:SetPoint('TOPLEFT',f,2,-2);top:SetPoint('TOPRIGHT',f,-2,-2);top:SetHeight(3);solid(top,0.76,0.55,0.22,1)
  local function line(y)
    local t=f:CreateTexture(nil,'ARTWORK');t:SetPoint('TOPLEFT',f,18,y);t:SetPoint('TOPRIGHT',f,-18,y);t:SetHeight(1);solid(t,0.29,0.38,0.46,0.7)
  end
  local function font(parent,template,size,color)
    local fs=parent:CreateFontString(nil,'OVERLAY',template or 'GameFontNormal')
    if fs.SetFont then
      local path=STANDARD_TEXT_FONT or 'Fonts\\FRIZQT__.TTF'
      fs:SetFont(path,size or 12,'')
    end
    if color then fs:SetTextColor(unpack(color)) end
    return fs
  end
  local muted={0.62,0.70,0.77};local gold={0.96,0.73,0.31};local pale={0.86,0.91,0.95}
  local title=font(f,'GameFontNormalLarge',17,pale);title:SetPoint('TOPLEFT',20,-18);title:SetText('MOB ATLAS')
  local subtitle=font(f,'GameFontNormalSmall',11,muted);subtitle:SetPoint('TOPLEFT',20,-43);subtitle:SetText('FOREVERDB  /  MOB LOCATIONS & LOOT')
  local close=CreateFrame('Button',nil,f);close:SetSize(24,24);close:SetPoint('TOPRIGHT',-12,-12)
  local closeText=font(close,'GameFontNormalLarge',19,muted);closeText:SetPoint('CENTER');closeText:SetText('x')
  close:SetScript('OnClick',function() f:Hide() end)
  close:SetScript('OnEnter',function() closeText:SetTextColor(1,0.45,0.4) end)
  close:SetScript('OnLeave',function() closeText:SetTextColor(unpack(muted)) end)
  line(-68)
  local searchLabel=font(f,'GameFontNormalSmall',11,muted);searchLabel:SetPoint('TOPLEFT',20,-84);searchLabel:SetText('SEARCH MOBS OR NPC ID')
  local searchBg=CreateFrame('Frame',nil,f);searchBg:SetSize(520,31);searchBg:SetPoint('TOPLEFT',20,-103)
  local searchTex=searchBg:CreateTexture(nil,'BACKGROUND');searchTex:SetAllPoints();solid(searchTex,0.095,0.145,0.195,1)
  local search=CreateFrame('EditBox',nil,searchBg);search:SetSize(494,26);search:SetPoint('LEFT',12,0);search:SetAutoFocus(false)
  search:SetFont(STANDARD_TEXT_FONT or 'Fonts\\FRIZQT__.TTF',13,'');search:SetTextColor(0.91,0.94,0.98)
  local hint=font(f,'GameFontHighlightSmall',10,muted);hint:SetPoint('TOPLEFT',20,-141);hint:SetText('Type a mob name or NPC ID  |  Click a result to inspect loot')
  line(-164)
  local status=font(f,'GameFontHighlightSmall',12,pale);status:SetPoint('TOPLEFT',20,-178);status:SetWidth(520);status:SetHeight(39);status:SetJustifyH('LEFT');status:SetJustifyV('TOP')
  local function styledButton(parent,w,h)
    local b=CreateFrame('Button',nil,parent);b:SetSize(w,h)
    local shade=b:CreateTexture(nil,'BACKGROUND');shade:SetAllPoints();solid(shade,0.09,0.15,0.21,0.93)
    local edge=b:CreateTexture(nil,'ARTWORK');edge:SetPoint('LEFT');edge:SetSize(3,h);solid(edge,0.29,0.43,0.54,1)
    local label=font(b,'GameFontNormal',12,pale);label:SetPoint('LEFT',12,0);label:SetPoint('RIGHT',-8,0);label:SetJustifyH('LEFT');label:SetWordWrap(false)
    b:SetScript('OnEnter',function() solid(shade,0.14,0.23,0.31,1);solid(edge,0.96,0.73,0.31,1) end)
    b:SetScript('OnLeave',function() solid(shade,0.09,0.15,0.21,0.93);solid(edge,0.29,0.43,0.54,1) end)
    b.SetText=function(_,value) label:SetText(value or '') end
    b.GetFontString=function() return label end
    return b
  end
  local rows={}
  for i=1,9 do
    local b=styledButton(f,520,25);b:SetPoint('TOPLEFT',20,-222-(i-1)*29);rows[i]=b
  end
  line(-493)
  local prev=styledButton(f,90,25);prev:SetPoint('BOTTOMLEFT',20,12);prev:SetText('Previous')
  local nextB=styledButton(f,76,25);nextB:SetPoint('LEFT',prev,'RIGHT',8,0);nextB:SetText('Next')
  local mapB=styledButton(f,142,25);mapB:SetPoint('BOTTOMRIGHT',-20,12);mapB:SetText('Show on Map')
  local function showDetails(id)
    if not loadDB() then status:SetText('ForeverDB not installed or could not load.');return end
    selectedID=id;page=1
    local n=npc(id);if not n then status:SetText('Unknown NPC ID '..id);return end
    local drops=dropsFor(id);local ev,missing,coin=calculateEV(id,drops)
    status:SetText(string.format('%s (#%d) Lv %s-%s | EV >= %s%s',n[1] or '?',id,tostring(n[3] or '?'),tostring(n[4] or '?'),cash(ev),missing>0 and (' ('..missing..' unknown entries)') or ''))
    matches=drops
    for i=1,#rows do rows[i]:SetScript('OnClick',nil) end
    local function render()
      for i,b in ipairs(rows) do
        local r=matches[(page-1)*#rows+i]
        if r then
          b:Show();b:SetText(string.format('%s | %s | %s',itemName(r.id),r.chance and r.chance>0 and string.format('%.2f%%',r.chance/100) or '?%',r.price and cash(r.price) or 'price unknown'))
          b:SetScript('OnEnter',function(self) GameTooltip:SetOwner(self,'ANCHOR_RIGHT');GameTooltip:SetHyperlink('item:'..r.id);GameTooltip:Show() end)
          b:SetScript('OnLeave',function() GameTooltip:Hide() end)
        else b:Hide() end
      end
    end
    prev:SetScript('OnClick',function() page=math.max(1,page-1);render() end)
    nextB:SetScript('OnClick',function() if page*#rows<#matches then page=page+1;render() end end)
    render()
  end
  local function searchMobs(q)
    if not loadDB() then status:SetText('Install ForeverDB by fatedfr (CurseForge: forever-db).');return end
    selectedID=nil;page=1;matches={}
    q=(q or ''):lower()
    local numeric=tonumber(q)
    if numeric and npc(numeric) then showDetails(numeric);return end
    if #q<2 then status:SetText('Type at least two characters to search.');for _,b in ipairs(rows) do b:Hide() end;return end
    for id,n in pairs(D.npc) do
      if type(n)=='table' and type(n[1])=='string' and n[1]:lower():find(q,1,true) then
        matches[#matches+1]={id=id,name=n[1],min=n[3],max=n[4]}
      end
    end
    table.sort(matches,function(a,b) return a.name<b.name end)
    status:SetText(#matches..' matching NPCs. Click one to view loot and expected gold.')
    local function render()
      for i,b in ipairs(rows) do
        local r=matches[(page-1)*#rows+i]
        if r then
          b:Show();b:SetText(string.format('%s  (Lv %s-%s, #%d)',r.name,tostring(r.min or '?'),tostring(r.max or '?'),r.id))
          b:SetScript('OnClick',function() showDetails(r.id) end)
          b:SetScript('OnEnter',nil);b:SetScript('OnLeave',nil)
        else b:Hide() end
      end
    end
    prev:SetScript('OnClick',function() page=math.max(1,page-1);render() end)
    nextB:SetScript('OnClick',function() if page*#rows<#matches then page=page+1;render() end end)
    render()
  end
  search:SetScript('OnEnterPressed',function(self) self:ClearFocus();searchMobs(self:GetText()) end)
  search:SetScript('OnTextChanged',function(self,user) if user then searchMobs(self:GetText()) end end)
  -- WoW Forever can expose the classic map API rather than Retail's scroll canvas.
  local function getMap()
    if WorldMapFrame and WorldMapFrame.GetMapID then
      local ok,id=pcall(WorldMapFrame.GetMapID,WorldMapFrame)
      if ok and id then return id end
    end
    if C_Map and C_Map.GetBestMapForUnit then
      local ok,id=pcall(C_Map.GetBestMapForUnit,'player')
      if ok and id then return id end
    end
    if GetCurrentMapAreaID then
      local ok,id=pcall(GetCurrentMapAreaID)
      if ok and id then return id end
    end
    return nil
  end
  local function mapParent()
    if WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child then
      return WorldMapFrame.ScrollContainer.Child
    end
    -- Classic/Forever world map; WorldMapButton is the actual map texture canvas.
    return WorldMapDetailFrame or WorldMapButton
  end
  local function atlasMessage(message)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffedc55aGrind Only Atlas:|r '..message) end
  end
  local lastDiagnostic=''
  local function diagnostic(message)
    if message~=lastDiagnostic then lastDiagnostic=message;atlasMessage(message) end
  end
  local function clearPins()
    for _,p in ipairs(pins) do p:Hide();p:SetParent(UIParent) end
    wipe(pins)
  end
  -- Spatial aggregation prevents arbitrary NPC iteration and the 180-pin cap
  -- from hiding whole sections of a zone. All observed spawn points contribute.
  local function showMapPins()
    clearPins()
    if not loadDB() then diagnostic('ForeverDB library unavailable.');return end
    local mid=getMap();local parent=mapParent()
    if not mid or not parent then diagnostic('Map canvas unavailable: '..tostring(mid));return end
    if not D.spm then diagnostic('ForeverDB spm map-position dataset missing.');return end
    local q=filterText:lower()
    local cells={};local keys={};local grid=20 -- 5% of map per cell
    local totalSpawns=0
    for id,n in pairs(D.npc) do
      if type(n)=='table' and type(n[1])=='string' and (q=='' or n[1]:lower():find(q,1,true))
        and (tonumber(n[4]) or 0)>=filterMin and (tonumber(n[3]) or 999)<=filterMax then
        local spots=D.spm['c'..id] and D.spm['c'..id][mid]
        if type(spots)=='table' then
          for j=1,#spots-1,2 do
            local x,y=(tonumber(spots[j]) or -1)/1000,(tonumber(spots[j+1]) or -1)/1000
            if x>=0 and x<=1 and y>=0 and y<=1 then
              local cx=math.min(grid-1,math.floor(x*grid))
              local cy=math.min(grid-1,math.floor(y*grid))
              local key=cx..':'..cy
              local cell=cells[key]
              if not cell then
                cell={x=0,y=0,count=0,mobs={},mobIDs={},cx=cx,cy=cy}
                cells[key]=cell;keys[#keys+1]=key
              end
              cell.x=cell.x+x;cell.y=cell.y+y;cell.count=cell.count+1
              if not cell.mobIDs[id] then
                cell.mobIDs[id]=true
                cell.mobs[#cell.mobs+1]={id=id,name=n[1],min=n[3],max=n[4]}
              end
              totalSpawns=totalSpawns+1
            end
          end
        end
      end
    end
    -- Prioritize populated cells, but don't depend on pairs() iteration order.
    table.sort(keys,function(ka,kb)
      local a,b=cells[ka],cells[kb]
      if a.count~=b.count then return a.count>b.count end
      if a.cy~=b.cy then return a.cy<b.cy end
      return a.cx<b.cx
    end)
    local rendered=0
    for i=1,math.min(#keys,180) do
      local cell=cells[keys[i]]
      table.sort(cell.mobs,function(a,b) return a.name<b.name end)
      local x,y=cell.x/cell.count,cell.y/cell.count
      local button=CreateFrame('Button',nil,parent)
      local size=cell.count>8 and 20 or (cell.count>2 and 17 or 14)
      button:SetSize(size,size)
      button:SetFrameLevel(parent:GetFrameLevel()+20)
      local background=button:CreateTexture(nil,'ARTWORK');background:SetAllPoints()
      solid(background,0.11,0.25,0.34,0.92)
      local rim=button:CreateTexture(nil,'BORDER');rim:SetPoint('CENTER');rim:SetSize(size+2,size+2)
      solid(rim,0.88,0.69,0.30,0.9)
      local number=button:CreateFontString(nil,'OVERLAY','GameFontNormalSmall')
      number:SetPoint('CENTER');number:SetFont(STANDARD_TEXT_FONT or 'Fonts\\FRIZQT__.TTF',10,'OUTLINE')
      number:SetText(tostring(#cell.mobs))
      button:SetPoint('CENTER',parent,'TOPLEFT',parent:GetWidth()*x,-parent:GetHeight()*y)
      button:SetScript('OnEnter',function(self)
        GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
        GameTooltip:SetText(#cell.mobs..' mob types / '..cell.count..' spawn records')
        for j=1,math.min(8,#cell.mobs) do
          local m=cell.mobs[j]
          GameTooltip:AddLine(m.name..' (Lv '..tostring(m.min)..'-'..tostring(m.max)..')',1,0.85,0.4)
        end
        if #cell.mobs>8 then GameTooltip:AddLine('+'..(#cell.mobs-8)..' more mobs',0.8,0.8,0.8) end
        -- Show drops for the current selection when a cluster contains one mob.
        -- Multi-mob clusters remain a summary to avoid misleading attribution.
        if #cell.mobs==1 then appendLootTooltip(GameTooltip,cell.mobs[1].id,5) end
        GameTooltip:AddLine('Click to inspect; Shift-click for next mob',1,1,1)
        GameTooltip:Show()
      end)
      button:SetScript('OnLeave',function() GameTooltip:Hide() end)
      button:SetScript('OnClick',function(self)
        if IsShiftKeyDown and IsShiftKeyDown() then
          self.mobIndex=(self.mobIndex or 1)%#cell.mobs+1
        else self.mobIndex=1 end
        f:Show();showDetails(cell.mobs[self.mobIndex].id)
      end)
      pins[#pins+1]=button;rendered=rendered+1
    end
    if rendered==0 then diagnostic('No mob spawns for map '..tostring(mid)..' with current level filters.')
    else lastDiagnostic='' end
  end
  local function refreshMap()
    if not WorldMapFrame or not WorldMapFrame:IsShown() then
      if mapWasVisible then
        mapWasVisible=false
        filterText='' -- Never carry a selected-mob map filter into the next map opening.
        mapID=nil
      end
      clearPins()
      return
    end
    if not mapWasVisible then
      mapWasVisible=true
      filterText='' -- Always show every mob on a newly opened map.
      mapID=nil
    end
    if getMap()~=mapID then mapID=getMap();showMapPins() end
  end
  local watcher=CreateFrame('Frame');local elapsed=0
  watcher:SetScript('OnUpdate',function(_,dt)
    elapsed=elapsed+dt;if elapsed<0.75 then return end;elapsed=0
    refreshMap()
  end)
  mapB:SetScript('OnClick',function()
    filterText='' -- Show on Map must not permanently filter the atlas to one mob.
    if WorldMapFrame and WorldMapFrame.Show then WorldMapFrame:Show() elseif ToggleWorldMap then ToggleWorldMap() end
    mapID=nil;refreshMap()
  end)
  f:Hide()
  SLASH_GRINDONLYATLAS1='/goatlas'
  SlashCmdList.GRINDONLYATLAS=function(msg)
    msg=(msg or ''):match('^%s*(.-)%s*$')
    local tooltipArg=msg:lower():match('^tooltip%s*(.*)$')
    local predictionArg=msg:lower():match('^prediction%s*(.*)$')
    if predictionArg~=nil then
      local settings=tooltipSettings()
      if predictionArg=='on' then settings.predictionEnabled=true
      elseif predictionArg=='off' then settings.predictionEnabled=false
      elseif predictionArg=='detail' then settings.predictionDetailed=true
      elseif predictionArg=='compact' then settings.predictionDetailed=false
      else settings.predictionEnabled=settings.predictionEnabled==false end
      atlasMessage('Prediction '..(settings.predictionEnabled==false and 'OFF' or 'ON')..' / '..(settings.predictionDetailed and 'detail' or 'compact'))
    elseif tooltipArg~=nil then
      if tooltipArg=='on' then
        setTooltipEnabled(true)
      elseif tooltipArg=='off' then
        setTooltipEnabled(false)
      elseif tooltipArg=='' or tooltipArg=='toggle' then
        setTooltipEnabled(not tooltipEnabled)
      else
        atlasMessage('Usage: /goatlas tooltip [on|off|toggle]')
      end
    elseif msg=='debug' then
      local ok=loadDB();local mid=getMap();local parent=mapParent()
      atlasMessage('nativeTooltipHook='..tostring(nativeHookReady)..' DB='..tostring(ok)..' npc='..tostring(D and D.npc~=nil)..' spm='..tostring(D and D.spm~=nil)..' mapID='..tostring(mid)..' canvas='..tostring(parent and parent:GetName())..' visible='..tostring(WorldMapFrame and WorldMapFrame:IsShown()))
      if ok and D.spm then
        local samples=0
        for key,entry in pairs(D.spm) do
          if type(entry)=='table' then
            local mapList=''
            for k in pairs(entry) do mapList=mapList..tostring(k)..',';if #mapList>75 then break end end
            atlasMessage('sample spm '..tostring(key)..' maps: '..mapList)
            samples=samples+1
            if samples>=2 then break end
          end
        end
      end
    elseif msg=='map' then
      filterText='';if WorldMapFrame then WorldMapFrame:Show() elseif ToggleWorldMap then ToggleWorldMap() end
      mapID=nil;refreshMap()
    elseif msg:match('^level%s+%d+%s+%d+') then
      local a,b=msg:match('^level%s+(%d+)%s+(%d+)');filterMin=tonumber(a);filterMax=tonumber(b);mapID=nil;refreshMap()
      print('Grind Only Atlas: map level filter '..a..'-'..b)
    else f:Show();search:SetText(msg);searchMobs(msg) end
  end
  -- World map checkbox; default ON, toggle without changing Grind Only's history.
  local toggle
  local function createToggle()
    if toggle or not WorldMapFrame then return end
    toggle=CreateFrame('CheckButton','GrindOnlyAtlasMapToggle',WorldMapFrame,'UICheckButtonTemplate')
    toggle:SetSize(24,24);toggle:SetFrameStrata('DIALOG');toggle:SetFrameLevel(WorldMapFrame:GetFrameLevel()+50);toggle:SetPoint('TOPLEFT',WorldMapFrame,'TOPLEFT',40,-32);toggle:SetChecked(true)
    local label=toggle:CreateFontString(nil,'OVERLAY','GameFontNormalSmall');label:SetPoint('LEFT',toggle,'RIGHT',2,0);label:SetText('Grind Only mobs')
    toggle:SetScript('OnClick',function(self)
      if self:GetChecked() then mapID=nil;refreshMap() else clearPins() end
    end)
  end
  local oldRefresh=refreshMap
  refreshMap=function()
    createToggle()
    if toggle and not toggle:GetChecked() then clearPins();return end
    oldRefresh()
  end
end
