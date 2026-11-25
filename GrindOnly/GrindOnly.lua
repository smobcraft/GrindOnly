-- Grind Only: session tracking, analytics, buffs and core UI.
-- Session resets on login/reload. English client buff/loot messages assumed.
local addon=CreateFrame('Frame')
local S={start=0,money=0,vendor=0,pending={}}
local function coin(c)
  c=math.max(0,math.floor(c or 0))
  return string.format('%dg %02ds %02dc',math.floor(c/10000),math.floor(c/100)%100,c%100)
end
local function duration(s)
  s=math.max(0,math.floor(s or 0))
  return string.format('%dh %02dm',math.floor(s/3600),math.floor(s/60)%60)
end
local function text(parent,size,color)
  local t=parent:CreateFontString(nil,'OVERLAY',size or 'GameFontHighlightSmall')
  if color then t:SetTextColor(color[1],color[2],color[3]) end
  return t
end
local gold={1,.78,.32};local pale={.87,.87,.84};local muted={.63,.67,.70}

-- Persistent analytics. SavedVariables are flushed by the client on logout/reload.
local H, current, recentDeaths = nil,nil,{}
local mailboxOpen=false
-- Some Forever client builds do not reliably emit MAIL_CLOSED.  Check the
-- actual mailbox UI on each loot event so a stale event flag cannot suppress
-- all future mob loot and coin earnings.
local function isMailboxVisible()
  if MailFrame and MailFrame.IsShown then
    local ok,shown=pcall(MailFrame.IsShown,MailFrame)
    if ok then
      if not shown then mailboxOpen=false end
      return shown
    end
  end
  return mailboxOpen
end
local xpLast,levelLast,maxXPAtLast=nil,nil,nil
local recordMetric, recordZoneXP
local lastMetricBucket=nil
recordMetric=function(kind,amount)
  if not H or not current or type(amount)~='number' or amount<=0 then return end
  -- Live reward timestamps are session-local, never written to SavedVariables.
  if kind=='coin' or kind=='vendor' or kind=='xp' then
    local events=S.liveRewards or {};S.liveRewards=events
    events[#events+1]={t=GetTime(),kind=kind,amount=amount}
  end
  local a=H.analytics
  if not a then return end
  local now=GetTime()
  local start=S.start or now
  local index=math.max(0,math.floor((now-start)/300))
  local key=tostring(current.started)..':'..tostring(index)
  local b=lastMetricBucket
  if not b or b.key~=key then
    b={key=key,started=current.started,offset=index*300,level=UnitLevel and UnitLevel('player') or current.level,
       zone=(GetRealZoneText and GetRealZoneText()) or current.zone,
       subzone=(GetSubZoneText and GetSubZoneText()) or '',coin=0,vendor=0,xp=0,items=0}
    a.buckets[#a.buckets+1]=b;lastMetricBucket=b
    if #a.buckets>12000 then table.remove(a.buckets,1) end
  end
  b[kind]=(b[kind] or 0)+amount
end
local function safeNumber(v)
  if type(v)=='number' and (not issecretvalue or not issecretvalue(v)) then return v end
end
local function sampleXP()
  if not UnitXP or not UnitLevel then return end
  local ok,xp=pcall(UnitXP,'player')
  local okL,level=pcall(UnitLevel,'player')
  if not ok or not okL then return end
  xp=safeNumber(xp);level=safeNumber(level)
  if not xp or not level then return end
  local mx=UnitXPMax and safeNumber(UnitXPMax('player')) or nil
  if xpLast and levelLast then
    local delta=0
    if level==levelLast then delta=math.max(0,xp-xpLast)
    elseif level==levelLast+1 and maxXPAtLast then
      delta=math.max(0,maxXPAtLast-xpLast+xp)
    end
    if delta>0 and delta<10000000 then
      if current then current.xp=(current.xp or 0)+delta end
      recordMetric('xp',delta)
      if recordZoneXP then recordZoneXP(delta) end
    end
  end
  xpLast=xp;levelLast=level;maxXPAtLast=mx
end

-- Conservative source gate: only count rewards near one observed corpse.
-- WoW Forever does not provide a guaranteed source identifier on every loot chat event.
local addEarnings
local function nowEpoch() return (time and time()) or 0 end
local function initHistory()
  if type(GrindOnlyDB)~='table' then GrindOnlyDB={} end
  H=GrindOnlyDB
  if type(H.sessions)~='table' then H.sessions={} end
  if type(H.mobs)~='table' then H.mobs={} end
  if type(H.items)~='table' then H.items={} end
  if type(H.zones)~='table' then H.zones={} end
  if type(H.days)~='table' then H.days={} end
  if type(H.observations)~='table' then H.observations={} end
  if type(H.buffTracking)~='table' then
    H.buffTracking={['Battle Shout']=true,['Find Minerals']=true,['Food']=true,
      ['Agility']=true,['Strength']=true,["Troll's Blood"]=true,
      ['Spirit']=true,['Weapon enhancement']=true}
  end
  if type(H.customBuffs)~='table' then H.customBuffs={} end
  -- v1 history schema: preserve all legacy aggregates and sessions in place.
  H.version=5
  if type(H.mobAtlas)~='table' then H.mobAtlas={schema=1} end
  H.mobAtlas.schema=1
  if type(H.analytics)~='table' then H.analytics={} end
  if type(H.analytics.levels)~='table' then H.analytics.levels={} end
  if type(H.analytics.buckets)~='table' then H.analytics.buckets={} end
  H.analytics.schema=1
  if type(H.efficiency)~="table" then H.efficiency={samples={}} end
  if type(H.efficiency.samples)~="table" then H.efficiency.samples={} end
  -- Bounded history to avoid unlimited SavedVariables growth.
  -- Preserve historical session summaries; only compact detailed time buckets.
  while #H.analytics.buckets>12000 do table.remove(H.analytics.buckets,1) end
  -- Freeze a historical estimate once; never merge overlapping legacy and direct XP.
  if type(H.analytics.zoneXPBackfill)~='table' then
    local recovered={}
    local sessions={}
    for _,session in ipairs(H.sessions) do
      if type(session)=='table' and type(session.started)=='number' then
        if sessions[session.started] then sessions[session.started]=false
        else sessions[session.started]=session end
      end
    end
    local seen={}
    for _,b in ipairs(H.analytics.buckets) do
      if type(b)=='table' and type(b.zone)=='string' and b.zone~='' and type(b.offset)=='number' and b.offset>=0 and type(b.xp)=='number' and b.xp>=0 then
        local session=sessions[b.started]
        local seconds=session and math.min(300,(tonumber(session.duration) or 0)-b.offset) or 0
        local id=tostring(b.started)..':'..tostring(b.offset)
        if seconds>0 and not seen[id] then
          seen[id]=true
          local sub=b.subzone or ''
          local key=b.zone..' / '..(sub~='' and sub or '(unspecified)')
          local r=recovered[key] or {zone=b.zone,subzone=sub,xp=0,seconds=0}
          recovered[key]=r;r.xp=r.xp+b.xp;r.seconds=r.seconds+seconds
        end
      end
    end
    H.analytics.zoneXPBackfill=recovered
  end
  current={started=nowEpoch(),zone=(GetRealZoneText and GetRealZoneText()) or 'Unknown',kills=0,coin=0,vendor=0,items=0}
  current.subzone=(GetSubZoneText and GetSubZoneText()) or ''
  current.duration=0
  current.xp=0;current.level=UnitLevel and UnitLevel('player') or 0;current.levelStart=current.level;current.schema=4
  current.timedKills=0;current.fightSeconds=0;current.gapSeconds=0;current.gapSamples=0;current.efficiencySamples={} 
  H.sessions[#H.sessions+1]=current
end
local observeMobLocation,recordMobLootEvidence
local function mobKey(name,level) return tostring(name or 'Unknown')..'|'..tostring(level or '?') end
local function rememberMob(name,level)
  if not H or not name or name=='' then return end
  local key=mobKey(name,level)
  local m=H.mobs[key]
  if not m then m={name=name,level=level or '?',kills=0,coin=0,vendor=0,items={},last=0};H.mobs[key]=m end
  return m
end
-- Mob Atlas v1: compact observations; no external networking or map UI required.
-- Only the player's position is available, so coordinates are approximate.
-- This block scopes implementation locals to avoid the WoW Lua 200-local limit.
do
  local function npcID(guid)
    if type(guid)~='string' then return nil end
    local id=guid:match('^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-')
       or guid:match('^Vehicle%-%d+%-%d+%-%d+%-%d+%-(%d+)%-')
       or guid:match('^0xF130(%x%x%x%x%x%x)')
    if not id then return nil end
    return tonumber(id, guid:sub(1,2)=='0x' and 16 or 10)
  end
  local function playerPosition()
    local map,x,y
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
      local ok,m=pcall(C_Map.GetBestMapForUnit,'player')
      if ok and type(m)=='number' then
        local success,pos=pcall(C_Map.GetPlayerMapPosition,m,'player')
        if success and pos then
          local okX,xx=pcall(function() return pos.x end)
          local okY,yy=pcall(function() return pos.y end)
          if okX and okY then map,x,y=m,xx,yy end
        end
      end
    end
    -- Legacy map coordinates are only valid if the displayed map is the player's
    -- current zone. Never call SetMapToCurrentZone: it would move the user's map.
    if not x and GetPlayerMapPosition and GetCurrentMapZone and GetCurrentMapContinent then
      local ok,xx,yy=pcall(GetPlayerMapPosition,'player')
      if ok and type(xx)=='number' and type(yy)=='number' then
        local okZ,z=pcall(GetCurrentMapZone)
        local okC,c=pcall(GetCurrentMapContinent)
        if okZ and okC and type(z)=='number' and z>0 and type(c)=='number' and c>0 then
          map='legacy:'..c..':'..z;x=xx;y=yy
        end
      end
    end
    if type(x)~='number' or type(y)~='number' or x<=0 or y<=0 or x>=1 or y>=1 then return end
    return map,x,y
  end
  observeMobLocation=function(name,level,guid,kind)
    if not H or type(name)~='string' or name=='' then return end
    local m=rememberMob(name,level)
    if not m then return end
    local id=npcID(guid)
    if id and id>0 then
      m.npcIDs=m.npcIDs or {};m.npcIDs[tostring(id)]=true
    end
    if type(level)=='number' and level>0 then
      m.minLevel=math.min(m.minLevel or level,level)
      m.maxLevel=math.max(m.maxLevel or level,level)
    end
    m.encounters=(m.encounters or 0)+(kind=='encounter' and 1 or 0)
    m.atlasSchema=1
    local map,x,y=playerPosition()
    if not map then return end
    m.locations=m.locations or {}
    -- 2% map-grid buckets bound growth and avoid storing individual positions.
    local gx=math.min(49,math.floor(x*50));local gy=math.min(49,math.floor(y*50))
    local key=tostring(map)..':'..gx..':'..gy
    local b=m.locations[key]
    if not b then
      b={map=map,x=(gx+.5)/50,y=(gy+.5)/50,zone=(GetRealZoneText and GetRealZoneText()) or '',
         subzone=(GetSubZoneText and GetSubZoneText()) or '',encounters=0,kills=0,first=nowEpoch()}
      m.locations[key]=b
    end
    b[kind=='kill' and 'kills' or 'encounters']=(b[kind=='kill' and 'kills' or 'encounters'] or 0)+1
    b.last=nowEpoch()
    -- Cap spatial buckets per mob, retaining the most observed cells.
    local n=0;for _ in pairs(m.locations) do n=n+1 end
    if n>120 then
      local oldestKey,oldestScore
      for k,v in pairs(m.locations) do
        local score=(v.kills or 0)*4+(v.encounters or 0)
        if not oldestScore or score<oldestScore then oldestKey,oldestScore=k,score end
      end
      if oldestKey then m.locations[oldestKey]=nil end
    end
  end
  recordMobLootEvidence=function(m,id,count)
    if not m then
      if H and H.mobAtlas then H.mobAtlas.unattributedItems=(H.mobAtlas.unattributedItems or 0)+count end
      return
    end
    m.lootAttribution=m.lootAttribution or {singleCandidateItems=0}
    m.lootAttribution.singleCandidateItems=m.lootAttribution.singleCandidateItems+count
    -- Do not claim a corpse denominator: CHAT_MSG_LOOT does not guarantee one.
    local r=m.items and m.items[tostring(id)]
    if r then r.attribution='single_recent_corpse' end
  end
end

local function recentMob()
  local t=GetTime();local match=nil;local count=0
  for i=#recentDeaths,1,-1 do
    local d=recentDeaths[i]
    if t-d.t>12 then table.remove(recentDeaths,i)
    else count=count+1;match=d.key end
  end
  -- Deliberately don't attribute loot when several corpses are plausible.
  if count==1 then return H and H.mobs[match] end
end
local function recordLootItem(id,count,price,itemName,itemLink)
  if not H or not current then return end
  current.items=current.items+count
  local item=H.items[tostring(id)] or {count=0,value=0}
  if itemName and itemName~='' then item.name=itemName end
  if itemLink and itemLink~='' then item.link=itemLink end
  item.count=item.count+count;item.value=item.value+(price or 0)*count
  if price and price>0 then addEarnings('vendor',price*count);recordMetric('vendor',price*count) end
  H.items[tostring(id)]=item
  local m=recentMob()
  if m then
    local rec=m.items[tostring(id)] or {count=0,value=0}
    if itemName and itemName~='' then rec.name=itemName end
    if itemLink and itemLink~='' then rec.link=itemLink end
    rec.count=rec.count+count;rec.value=rec.value+(price or 0)*count
    m.items[tostring(id)]=rec
    m.vendor=m.vendor+(price or 0)*count
  end
  recordMobLootEvidence(m,id,count)
end
local function recordCoin(amount)
  if current then current.coin=current.coin+amount end
  if addEarnings then addEarnings('coin',amount) end
  recordMetric('coin',amount)
  local m=recentMob()
  if m then m.coin=m.coin+amount end
end
local function pruneMobs()
  -- Never delete mob summaries: they are the personal atlas's long-term record.
  -- Spatial observations are already compacted and capped per mob.
end
-- v0.6: aggregate only newly observed earnings. Older records are preserved untouched.
local function dayKey(epoch)
  return (date and date('%Y-%m-%d',epoch or nowEpoch())) or 'Unknown'
end
local function zoneKey()
  local z=(GetRealZoneText and GetRealZoneText()) or 'Unknown'
  local sub=(GetSubZoneText and GetSubZoneText()) or ''
  if z=='' then z='Unknown' end
  return z,sub,z..' / '..(sub~='' and sub or '(unspecified)')
end
local function bucket(map,key)
  local b=map[key]
  if not b then b={coin=0,vendor=0,seconds=0,kills=0,first=nowEpoch(),last=nowEpoch()};map[key]=b end
  return b
end
recordZoneXP=function(amount)
  if not H or not current then return end
  local z,sub,key=zoneKey()
  local b=bucket(H.zones,key)
  b.zone=z;b.subzone=sub
  b.xp=(b.xp or 0)+amount
end
addEarnings=function(kind,amount)
  if not H or not current or amount<=0 then return end
  local z,sub,key=zoneKey()
  local b=bucket(H.zones,key);b[kind]=(b[kind] or 0)+amount;b.last=nowEpoch()
  b.zone=z;b.subzone=sub
  local d=bucket(H.days,dayKey());d[kind]=(d[kind] or 0)+amount;d.last=nowEpoch()
end
-- Session-local observations are bounded and never used to modify old history.
local liveKills={}
local function windowSummary(seconds)
  local now=GetTime()
  local count,fight,valid=0,0,0
  for i=#liveKills,1,-1 do
    local e=liveKills[i]
    if now-e.t<=seconds then
      count=count+1
      if e.fight and e.fight>0 then fight=fight+e.fight;valid=valid+1 end
    end
  end
  local age=math.max(1,math.min(seconds,now-(S.start or now)))
  return count,3600*count/age,valid>0 and fight/valid or nil
end
local function recordObservedKill(m,elapsedFight,elapsedGap)
  if not H or not current then return end
  local now=GetTime()
  liveKills[#liveKills+1]={t=now,fight=elapsedFight}
  while #liveKills>0 and (now-liveKills[1].t>1800 or #liveKills>1200) do table.remove(liveKills,1) end
  current.timedKills=(current.timedKills or 0)+((elapsedFight and elapsedFight>0 and elapsedFight<600) and 1 or 0)
  if elapsedFight and elapsedFight>0 and elapsedFight<600 then current.fightSeconds=(current.fightSeconds or 0)+elapsedFight end
  if elapsedGap and elapsedGap>=0 and elapsedGap<1200 then
    current.gapSeconds=(current.gapSeconds or 0)+elapsedGap
    current.gapSamples=(current.gapSamples or 0)+1
  end
  local z,sub,key=zoneKey()
  local b=bucket(H.zones,key);b.kills=(b.kills or 0)+1
  local d=bucket(H.days,dayKey());d.kills=(d.kills or 0)+1
  if m then
    if elapsedFight and elapsedFight>0 and elapsedFight<600 then
      m.fightSeconds=(m.fightSeconds or 0)+elapsedFight
      m.timedKills=(m.timedKills or 0)+1
    end
    if elapsedGap and elapsedGap>=0 and elapsedGap<1200 then
      m.gapSeconds=(m.gapSeconds or 0)+elapsedGap
      m.gapSamples=(m.gapSamples or 0)+1
    end
  end
end
local function updateZoneClock(dt)
  if not H or not current or dt<=0 or dt>10 then return end
  local z,sub,key=zoneKey()
  local b=bucket(H.zones,key);b.seconds=(b.seconds or 0)+dt
  b.xpSeconds=(b.xpSeconds or 0)+dt
  local d=bucket(H.days,dayKey());d.seconds=(d.seconds or 0)+dt
  current.zone=z;current.subzone=sub
  current.duration=(current.duration or 0)+dt
end
local panel=CreateFrame('Frame','GrindOnlyPanel',UIParent)
panel:SetSize(460,250)
panel:SetPoint('CENTER',UIParent,'CENTER',320,0)
panel:SetMovable(true);panel:EnableMouse(true)
panel:RegisterForDrag('LeftButton')
panel:SetScript('OnDragStart',function(self) self:StartMoving() end)
panel:SetScript('OnDragStop',function(self) self:StopMovingOrSizing() end)
local bg=panel:CreateTexture(nil,'BACKGROUND');bg:SetAllPoints();bg:SetColorTexture(.055,.075,.105,.95)
local top=panel:CreateTexture(nil,'BORDER');top:SetPoint('TOPLEFT',0,0);top:SetPoint('TOPRIGHT',0,0);top:SetHeight(4);top:SetColorTexture(.77,.53,.18,1)
local function rule(y)
  local t=panel:CreateTexture(nil,'ARTWORK');t:SetColorTexture(.28,.32,.38,.85)
  t:SetPoint('TOPLEFT',12,y);t:SetPoint('TOPRIGHT',-12,y);t:SetHeight(1)
end
local heading=text(panel,'GameFontNormalLarge',gold);heading:SetPoint('TOPLEFT',14,-14);heading:SetText('GRIND ONLY')
local sub=text(panel,'GameFontHighlightSmall',muted);sub:SetPoint('TOPRIGHT',-13,-18);sub:SetText('SESSION')
local statsButton=CreateFrame('Button',nil,panel,'UIPanelButtonTemplate')
statsButton:SetSize(88,21);statsButton:SetPoint('TOPLEFT',panel,'TOPLEFT',355,-43);statsButton:SetText('Stats')
rule(-34)
rule(-71)
local rateLabel=text(panel,'GameFontHighlightSmall',muted);rateLabel:SetPoint('TOPLEFT',14,-85);rateLabel:SetText('GOLD PER HOUR')
local rate=text(panel,'GameFontNormalLarge',gold);rate:SetPoint('TOPLEFT',14,-101);rate:SetText('0g 00s 00c')
-- Compact cards define the middle separator
local function metric(label,y)
  local l=text(panel,'GameFontHighlightSmall',muted);l:SetPoint('TOPLEFT',14,y);l:SetText(label)
  local v=text(panel,'GameFontHighlightSmall',pale);v:SetPoint('TOPRIGHT',-14,y);v:SetJustifyH('RIGHT')
  return v
end
local raw=metric('Raw coin looted',-144)
local vendor=metric('Vendor loot value',-164)
local total=metric('Total earned',-184)
local elapsed=metric('Session time',-204)
-- Footer separator drawn by Design D
local buffTitle=text(panel,'GameFontNormal',gold);buffTitle:SetPoint('TOPLEFT',14,-237);buffTitle:SetText('BUFF CHECKLIST')
local status=text(panel,'GameFontHighlightSmall',muted);status:SetPoint('TOPRIGHT',-14,-239)
local buffText=text(panel,'GameFontHighlightSmall',pale)
buffText:SetPoint('TOPLEFT',14,-260);buffText:SetWidth(257);buffText:SetJustifyH('LEFT');buffText:SetJustifyV('TOP')
buffText:SetText('Checking buffs...')
-- Highly visible warning panel: only displayed if a required buff is missing.
local warning=CreateFrame('Frame',nil,panel)
warning:SetPoint('TOPLEFT',panel,'TOPLEFT',12,-259)
warning:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-12,-259)
warning:SetHeight(80)
local warningBg=warning:CreateTexture(nil,'BACKGROUND')
warningBg:SetAllPoints()
warningBg:SetColorTexture(.43,.055,.055,.94)
local warningStripe=warning:CreateTexture(nil,'BORDER')
warningStripe:SetPoint('TOPLEFT',0,0);warningStripe:SetPoint('BOTTOMLEFT',0,0)
warningStripe:SetWidth(4);warningStripe:SetColorTexture(1,.25,.16,1)
local warningHeader=text(warning,'GameFontNormalLarge',{1,.88,.76})
warningHeader:SetPoint('TOPLEFT',12,-8)
warningHeader:SetText('!  MISSING BUFFS')
local warningDetails=text(warning,'GameFontHighlightSmall',{1,.91,.85})
warningDetails:SetPoint('TOPLEFT',12,-30)
warningDetails:SetWidth(228)
warningDetails:SetJustifyH('LEFT');warningDetails:SetJustifyV('TOP')
local warningCount=0
local pulseTime=0
warning:Hide()

-- v0.8.7: compact missing-buff indicator, with full missing names on hover.
local buffIndicator=CreateFrame('Frame',nil,panel)
buffIndicator:SetSize(120,25)
buffIndicator:SetPoint('TOPLEFT',panel,'TOPLEFT',16,-299)
buffIndicator:EnableMouse(true)
local buffIndicatorBg=buffIndicator:CreateTexture(nil,'BACKGROUND')
buffIndicatorBg:SetAllPoints()
local buffIndicatorText=text(buffIndicator,'GameFontNormal',gold)
buffIndicatorText:SetPoint('CENTER')
local missingBuffTooltip=''
local refreshBuffChips
buffIndicator:SetScript('OnEnter',function(self)
  GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
  GameTooltip:AddLine('Missing tracked buffs',1,.8,.3)
  GameTooltip:AddLine(missingBuffTooltip~='' and missingBuffTooltip or 'All tracked buffs active',1,1,1,true)
  GameTooltip:Show()
end)
buffIndicator:SetScript('OnLeave',function()GameTooltip:Hide()end)
local function showCompactBuffs(missing,count)
  missingBuffTooltip=table.concat(missing,', ')
  if refreshBuffChips then refreshBuffChips(missing,count) end
  buffIndicatorText:SetText(count>0 and ('! '..count..' MISSING') or 'BUFFS READY')
  if count>0 then
    buffIndicatorBg:SetColorTexture(.38,.055,.055,.96)
    buffIndicatorText:SetTextColor(1,.52,.44)
  else
    buffIndicatorBg:SetColorTexture(.06,.20,.13,.96)
    buffIndicatorText:SetTextColor(.4,.9,.6)
  end
end
-- Spellcast predictions are temporary and never override the next out-of-combat scan.
-- Curated category catalog; categories are opt-in except the legacy defaults.
-- Exact names can also be learned from buffs observed on the player's character.
local checks={
 {'Battle Shout',{'battle shout'}},
 {'Find Minerals',{'find minerals'}},
 {'Food',{'well fed','food buff'}},
 {'Agility',{'agility','mongoose'}},
 {'Strength',{'strength','giants'}},
 {"Troll's Blood",{'troll.s blood','health regeneration','health regen'}},
 {'Spirit',{'spirit','sagefish'}},
 {'Power Word: Fortitude',{'power word: fortitude','prayer of fortitude'}},
 {'Mark of the Wild',{'mark of the wild','gift of the wild'}},
 {'Arcane Intellect',{'arcane intellect','arcane brilliance'}},
 {'Blessing of Might',{'blessing of might','greater blessing of might'}},
 {'Blessing of Kings',{'blessing of kings','greater blessing of kings'}},
 {'Blessing of Wisdom',{'blessing of wisdom','greater blessing of wisdom'}},
 {'Blessing of Salvation',{'blessing of salvation','greater blessing of salvation'}},
 {'Blessing of Sanctuary',{'blessing of sanctuary','greater blessing of sanctuary'}},
 {'Thorns',{'thorns'}},
 {'Demon Armor',{'demon armor','demon skin','fel armor'}},
 {'Lightning Shield',{'lightning shield'}},
 {'Water Shield',{'water shield'}},
 {'Inner Fire',{'inner fire'}},
 {'Shadow Protection',{'shadow protection','prayer of shadow protection'}},
 {'Trueshot Aura',{'trueshot aura'}},
 {'Aspect of the Hawk',{'aspect of the hawk'}},
 {'Aspect of the Monkey',{'aspect of the monkey'}},
 {'Aspect of the Cheetah',{'aspect of the cheetah'}},
 {'Battle Elixir',{'elixir of','flask of'}},
 {'Flask',{'flask of'}},
 {'Rumsey Rum',{'rumsey rum'}},
 {'Scroll of Stamina',{'scroll of stamina'}},
 {'Scroll of Agility',{'scroll of agility'}},
 {'Scroll of Strength',{'scroll of strength'}},
 {'Scroll of Intellect',{'scroll of intellect'}},
 {'Scroll of Spirit',{'scroll of spirit'}},
 {'Find Herbs',{'find herbs'}},
 {'Track Humanoids',{'track humanoids'}},
 {'Track Beasts',{'track beasts'}},
 {'Track Undead',{'track undead'}},
 {'Track Hidden',{'track hidden'}},
}
local function tracked(name)
  return H and H.buffTracking and H.buffTracking[name]==true
end
local predicted={}
local predictedWeapon=false
local verifiedMissing={}
local verifiedWeaponMissing=false
local hasVerified=false
local function categoryFromName(name)
  if type(name)~='string' then return nil end
  name=name:lower()
  if name:find('battle shout',1,true) then return 'Battle Shout' end
  if name:find('find minerals',1,true) then return 'Find Minerals' end
  if name:find('troll',1,true) and name:find('blood',1,true) then return "Troll's Blood" end
  if name:find('elixir of giants',1,true) or name:find('elixir of ogre',1,true) or name:find("ogre's strength",1,true) or name:find('ogre strength',1,true) or (name:find('strength',1,true) and name:find('elixir',1,true)) then return 'Strength' end
  if (name:find('agility',1,true) and name:find('elixir',1,true)) or name:find('mongoose',1,true) then return 'Agility' end
  if name:find('spirit',1,true) and name:find('elixir',1,true) then return 'Spirit' end
  if name:find('sharpening stone',1,true) or name:find('weightstone',1,true) then return 'Weapon enhancement' end
  return nil
end
-- Diagnostic output is opt-in so normal grinding stays quiet.
local debugCasts=false
local function debugLine(message)
  if debugCasts then print('|cffd6aa55WGF DEBUG:|r '..tostring(message)) end
end
-- Confirmed by Forever 1.60.1 cast diagnostics; only these two IDs are added.
local knownBuffSpellIDs={
  [11328]='Agility',
  [3164]='Strength',
}
local function recordCast(spellID, suppliedName)
  local name=suppliedName
  if type(name)~='string' and type(spellID)=='number' and not (issecretvalue and issecretvalue(spellID)) then
    if C_Spell and C_Spell.GetSpellInfo then
      local ok,info=pcall(C_Spell.GetSpellInfo,spellID)
      if ok and type(info)=='table' then name=info.name end
    end
    if type(name)~='string' and GetSpellInfo then
      local ok,result=pcall(GetSpellInfo,spellID)
      if ok then name=result end
    end
  end
  if type(name)~='string' or (issecretvalue and issecretvalue(name)) then
    debugLine('cast succeeded, spellID='..tostring(spellID)..', name unavailable')
    return
  end
  local category=knownBuffSpellIDs[spellID] or categoryFromName(name)
  debugLine('cast succeeded: '..name..' ['..tostring(spellID)..'] => '..tostring(category or 'unmatched'))
  if category=='Weapon enhancement' then predictedWeapon=true
  elseif category then predicted[category]=true end
end
local function buffName(i)
  if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
    local ok,data=pcall(C_UnitAuras.GetBuffDataByIndex,'player',i)
    if ok and data and type(data.name)=='string' then return data.name end
  end
  if UnitBuff then
    local ok,name=pcall(UnitBuff,'player',i)
    if ok and type(name)=='string' then return name end
  end
end
local function checkBuffs()
  if InCombatLockdown and InCombatLockdown() then
    if not hasVerified then status:SetText('WAITING');return end
    local missing={}
    for _,name in ipairs(verifiedMissing) do if tracked(name) and not predicted[name] then missing[#missing+1]=name end end
    local weaponMissing=tracked('Weapon enhancement') and verifiedWeaponMissing and not predictedWeapon
    local count=#missing+(weaponMissing and 1 or 0)
    warningCount=count
    status:SetText(count==0 and 'READY*' or tostring(count)..' MISSING')
    if weaponMissing then missing[#missing+1]='Weapon enhancement' end
    showCompactBuffs(missing,count)
    if count>0 then
      warningHeader:SetText('!  '..count..' MISSING BUFF'..(count==1 and '' or 'S'))
      local lines={}
      for _,name in ipairs(missing) do lines[#lines+1]='|cffffe2d6• '..name..'|r' end
      warningDetails:SetText(table.concat(lines,'\n'))
      local h=math.max(70,38+#missing*17)
      warning:SetHeight(h);warning:Hide();buffText:Hide()
    else
      warning:Hide();buffText:Show();buffText:SetText('|cff69d69aAll tracked buffs active (estimated)|r')
    end
    return
  end
  if UnitIsDeadOrGhost and UnitIsDeadOrGhost('player') then
    status:SetText('DEAD');return
  end
  local names={}
  for i=1,40 do local n=buffName(i);if not n then break end;names[#names+1]=n:lower() end
  -- An empty aura list is valid: report enabled buffs as missing rather than UNKNOWN.
  -- If neither aura API exists, however, avoid a false missing-buff alert.
  if not (UnitBuff or (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex)) then
    status:SetText('UNKNOWN');buffText:SetText('Buff API unavailable.');warning:Hide();return
  end
  predicted={}
  predictedWeapon=false
  local missing={}
  for _,entry in ipairs(checks) do
    if tracked(entry[1]) then
    local present=false
    for _,name in ipairs(names) do
      for _,pat in ipairs(entry[2]) do if name:find(pat) then present=true;break end end
      if present then break end
    end
    if not present and not predicted[entry[1]] then missing[#missing+1]=entry[1] end
    end
  end
  -- Custom exact-name buffs discovered from the character's active auras.
  if H and H.customBuffs then
    for label,enabled in pairs(H.customBuffs) do
      if enabled then
        local present=false
        for _,name in ipairs(names) do if name==label:lower() then present=true;break end end
        if not present then missing[#missing+1]=label end
      end
    end
  end
  local weapon='Weapon enhancement: unknown'
  local weaponMissing=false
  if GetWeaponEnchantInfo then
    local ok,has=pcall(GetWeaponEnchantInfo)
    if ok and type(has)=='boolean' then
      weapon=has and '|cff69d69aWeapon enhancement: active|r' or '|cffff8888Weapon enhancement: missing|r'
      weaponMissing=tracked('Weapon enhancement') and not has and not predictedWeapon
    end
  end
  verifiedMissing={}
  for _,name in ipairs(missing) do verifiedMissing[#verifiedMissing+1]=name end
  verifiedWeaponMissing=weaponMissing
  hasVerified=true
  local count=#missing+(weaponMissing and 1 or 0)
  warningCount=count
  status:SetText(count==0 and 'READY' or tostring(count)..' MISSING')
  if weaponMissing then missing[#missing+1]='Weapon enhancement' end
  showCompactBuffs(missing,count)
  if count>0 then
    warningHeader:SetText('!  '..count..' MISSING BUFF'..(count==1 and '' or 'S'))
    local lines={}
    for _,name in ipairs(missing) do lines[#lines+1]='|cffffe2d6• '..name..'|r' end
    warningDetails:SetText(table.concat(lines,'\n'))
    local h=math.max(70,38+#missing*17)
    warning:SetHeight(h)
    warning:Show()
    buffText:Hide()
  else
    warning:Hide()
    buffText:Show()
    buffText:SetText('|cff69d69aAll tracked buffs active|r\n'..weapon)
  end
end
local function update()
  if S.start==0 then return end
  local secs=math.max(1,GetTime()-S.start)
  local sum=S.money+S.vendor
  if secs < 60 then
    rate:SetText('Calculating...')
  else
    rate:SetText(coin(sum*3600/secs))
  end
  raw:SetText(coin(S.money));vendor:SetText(coin(S.vendor))
  total:SetText(coin(sum));elapsed:SetText(duration(secs))
end
local function itemPrice(item)
  local f=(C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not f then return nil end
  local ok,name,link,quality,level,minLevel,itemType,subType,stackCount,equipLoc,texture,sellPrice=pcall(f,item)
  if ok and type(sellPrice)=='number' then return sellPrice end -- 11th GetItemInfo result
  return nil
end
local function addItem(link,count)
  local id=link and tonumber(link:match('item:(%d+)'))
  if not id then return end
  count=tonumber(count) or 1
  local itemName=link:match('%[([^%]]+)%]')
  local p=itemPrice(link)
  if p then S.vendor=S.vendor+p*count;recordLootItem(id,count,p,itemName,link)
  else
    S.pending[id]=(S.pending[id] or 0)+count;recordLootItem(id,count,0,itemName,link)
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID,id) end
  end
end
local function flushItem(id)
  id=tonumber(id);local count=id and S.pending[id]
  if not count then return end
  local p=itemPrice(id)
  if p then S.vendor=S.vendor+p*count;if current then current.vendor=S.vendor end;S.pending[id]=nil
    if addEarnings then addEarnings('vendor',p*count) end
    recordMetric('vendor',p*count)
    if H then local item=H.items[tostring(id)];if item then item.value=item.value+p*count end end
  end
end
local function parseMoney(msg)
  local g=tonumber(msg:match('(%d+)%s*[Gg]old')) or tonumber(msg:match('(%d+)%s*[Gg]%f[^%a]')) or 0
  local s=tonumber(msg:match('(%d+)%s*[Ss]ilver')) or tonumber(msg:match('(%d+)%s*[Ss]%f[^%a]')) or 0
  local c=tonumber(msg:match('(%d+)%s*[Cc]opper')) or tonumber(msg:match('(%d+)%s*[Cc]%f[^%a]')) or 0
  return g*10000+s*100+c
end
local function reset()
  S.start=GetTime();S.money=0;S.vendor=0;S.pending={};S.liveRewards={};xpLast=nil;levelLast=nil;sampleXP();update()
end

-- Historical analytics window, built with ordinary UI widgets (no external chart library).
-- Graphical efficiency dashboard, independently draggable.
local efficiencyPanel=CreateFrame('Frame',nil,UIParent)
efficiencyPanel:SetSize(350,244)
efficiencyPanel:SetPoint('TOP',panel,'BOTTOM',0,-6)
efficiencyPanel:SetFrameStrata('MEDIUM')
efficiencyPanel:SetMovable(true)
efficiencyPanel:SetClampedToScreen(true)
efficiencyPanel:EnableMouse(true)
efficiencyPanel:RegisterForDrag('LeftButton')
efficiencyPanel:SetScript('OnDragStart',function(self) self:StartMoving() end)
efficiencyPanel:SetScript('OnDragStop',function(self)
  self:StopMovingOrSizing()
  if H then
    local point,_,relativePoint,x,y=self:GetPoint(1)
    H.efficiencyPosition={point=point,relativePoint=relativePoint,x=x,y=y}
  end
end)
local epBg=efficiencyPanel:CreateTexture(nil,'BACKGROUND')
epBg:SetAllPoints();epBg:SetColorTexture(.055,.075,.105,.97)
local epTop=efficiencyPanel:CreateTexture(nil,'ARTWORK')
epTop:SetPoint('TOPLEFT');epTop:SetPoint('TOPRIGHT');epTop:SetHeight(3)
epTop:SetColorTexture(.91,.63,.17,1)
local epTitle=text(efficiencyPanel,'GameFontNormal',gold)
epTitle:SetPoint('TOPLEFT',12,-12);epTitle:SetText('GRIND EFFICIENCY')
local epHint=text(efficiencyPanel,'GameFontHighlightSmall',muted)
epHint:SetPoint('TOPRIGHT',-12,-14);epHint:SetText('LIVE')
local function metricCard(x,y,w,h,label)
  local bg=efficiencyPanel:CreateTexture(nil,'BACKGROUND')
  bg:SetPoint('TOPLEFT',x,y);bg:SetSize(w,h);bg:SetColorTexture(.11,.15,.19,.98)
  local lbl=text(efficiencyPanel,'GameFontHighlightSmall',muted)
  lbl:SetPoint('TOPLEFT',x+9,y-8);lbl:SetText(label)
  local val=text(efficiencyPanel,'GameFontNormalLarge',gold)
  val:SetPoint('TOPLEFT',x+9,y-26)
  return val,bg,lbl
end
local epRate5, epRate5Bg, epRate5Label=metricCard(12,-35,158,47,'KILLS / HOUR  (5m)')
local epTime, epTimeBg, epTimeLabel=metricCard(180,-35,158,47,'AVG TARGET TIME')
local epRate15, epRate15Bg, epRate15Label=metricCard(12,-88,158,47,'KILLS / HOUR  (15m)')
local epRate30, epRate30Bg, epRate30Label=metricCard(180,-88,158,47,'KILLS / HOUR  (30m)')
-- High-contrast, full-width performance status banner.
local epStatusBg=efficiencyPanel:CreateTexture(nil,'ARTWORK')
epStatusBg:SetPoint('TOPLEFT',12,-140)
epStatusBg:SetSize(326,25)
local epStatusAccent=efficiencyPanel:CreateTexture(nil,'OVERLAY')
epStatusAccent:SetPoint('TOPLEFT',12,-140)
epStatusAccent:SetSize(4,25)
local epTrendStatus=text(efficiencyPanel,'GameFontNormal',pale)
epTrendStatus:SetPoint('LEFT',epStatusBg,'LEFT',13,0)
epTrendStatus:SetWidth(300)
epTrendStatus:SetJustifyH('LEFT')
local epTrend=text(efficiencyPanel,'GameFontHighlightSmall',muted)
epTrend:SetPoint('TOPLEFT',12,-174);epTrend:SetText('KILLS / MINUTE  -  LAST 10 MIN')
local epBars={}
for i=1,10 do
  local bar=efficiencyPanel:CreateTexture(nil,'ARTWORK')
  bar:SetPoint('BOTTOMLEFT',efficiencyPanel,'TOPLEFT',16+(i-1)*32,-243)
  bar:SetSize(22,2);bar:SetColorTexture(.94,.69,.24,.95)
  epBars[i]=bar
end
local epFooter=text(efficiencyPanel,'GameFontHighlightSmall',pale)
epFooter:SetPoint('TOPLEFT',12,-252);epFooter:SetWidth(326)
epFooter:SetJustifyH('LEFT')
local epCaveat=text(efficiencyPanel,'GameFontHighlightSmall',muted)
epCaveat:SetPoint('TOPLEFT',12,-277)
epCaveat:SetText('Estimated target time; no protected combat events')
-- Compact-only layout. The header remains available for dragging.
for i=1,10 do
  epBars[i]:ClearAllPoints()
  epBars[i]:SetPoint('BOTTOMLEFT',efficiencyPanel,'TOPLEFT',16+(i-1)*32,-216)
end
epFooter:ClearAllPoints()
epFooter:SetPoint('TOPLEFT',12,-224)
epCaveat:Hide()
local function refreshEfficiencyPanel()
  if not current then return end
  local _,r5=windowSummary(300)
  local _,r15=windowSummary(900)
  local _,r30=windowSummary(1800)
  local timed=current.timedKills or 0
  local avg=timed>0 and string.format('%.1fs',(current.fightSeconds or 0)/timed) or '--'
  local gap=(current.gapSamples or 0)>0 and string.format('%.1fs',(current.gapSeconds or 0)/current.gapSamples) or '--'
  epRate5:SetText(string.format('%.0f',r5))
  epRate15:SetText(string.format('%.0f',r15))
  epRate30:SetText(string.format('%.0f',r30))
  epTime:SetText(avg)
  local now=GetTime()
  local counts={}
  for i=1,10 do counts[i]=0 end
  for i=1,#liveKills do
    local age=now-liveKills[i].t
    if age>=0 and age<600 then
      local bin=10-math.floor(age/60)
      if bin>=1 and bin<=10 then counts[bin]=counts[bin]+1 end
    end
  end
  local maxCount=1
  for i=1,10 do if counts[i]>maxCount then maxCount=counts[i] end end
  for i=1,10 do
    epBars[i]:SetHeight(math.max(2,math.floor(counts[i]/maxCount*18)))
    if counts[i]==0 then epBars[i]:SetColorTexture(.27,.32,.38,.85)
    else epBars[i]:SetColorTexture(.94,.69,.24,.95) end
  end
  -- Compare two NON-overlapping, equal-length two-minute periods.
  -- Never infer a trend from overlapping 5m/30m rates or partial startup data.
  local recent,previous=0,0
  for i=1,#liveKills do
    local age=now-liveKills[i].t
    if age>=0 and age<120 then recent=recent+1
    elseif age>=120 and age<240 then previous=previous+1 end
  end
  local sessionAge=now-(S.start or now)
  local status,detail,red,green,blue
  if sessionAge<240 or recent<3 or previous<3 then
    status='WARMING UP'
    detail=string.format('2m samples: %d / %d',recent,previous)
    red,green,blue=.45,.70,1
  else
    local change=(recent/previous-1)*100
    if change>10 then
      status='IMPROVING';detail=string.format('+%.0f%% vs prior 2m',change)
      red,green,blue=.31,.90,.55
    elseif change< -10 then
      status='SLOWING';detail=string.format('%.0f%% vs prior 2m',change)
      red,green,blue=1,.39,.32
    else
      status='STEADY';detail='Within 10% of prior 2m'
      red,green,blue=1,.73,.28
    end
  end
  epStatusBg:SetColorTexture(red*.16,green*.16,blue*.16,.98)
  epStatusAccent:SetColorTexture(red,green,blue,1)
  epTrendStatus:SetText(status..'  |  '..detail)
  epTrendStatus:SetTextColor(red,green,blue)
  epFooter:SetText(string.format('Observed kills: %d     Avg between-kill gap: %s',current.kills or 0,gap))
end
local efficiencyToggle=CreateFrame('Button',nil,panel,'UIPanelButtonTemplate')
efficiencyToggle:SetSize(107,21);efficiencyToggle:SetPoint('TOPLEFT',panel,'TOPLEFT',240,-43);efficiencyToggle:SetText('Efficiency')
-- Efficiency button opens the detailed historical Efficiency tab below.
-- Two compact shortcuts share the existing top button row.
local spotsButton=CreateFrame('Button',nil,panel,'UIPanelButtonTemplate')
spotsButton:SetSize(103,21)
spotsButton:SetPoint('TOPLEFT',panel,'TOPLEFT',129,-43)
spotsButton:SetText('Spots')
local buffsButton=CreateFrame('Button',nil,panel,'UIPanelButtonTemplate')
buffsButton:SetSize(103,21)
buffsButton:SetPoint('TOPLEFT',panel,'TOPLEFT',18,-43)
buffsButton:SetText('Buffs')
-- v0.9.1 Minimal dashboard: gold/hour, total earned, time, trend, buffs.
-- All decorative regions are native UI elements, constrained to 460x250.
local function move(r,x,y,parent)
  r:ClearAllPoints()
  r:SetPoint('TOPLEFT',parent or panel,'TOPLEFT',x,y)
end
local function rect(parent,x,y,w,h,r,g,b,a)
  local t=parent:CreateTexture(nil,'BACKGROUND')
  t:SetPoint('TOPLEFT',parent,'TOPLEFT',x,y)
  t:SetSize(w,h);t:SetColorTexture(r,g,b,a or 1)
  return t
end
local function caption(label,x,y,parent)
  local f=text(parent or panel,'GameFontHighlightSmall',muted)
  move(f,x,y,parent or panel);f:SetText(label);return f
end
-- Retire old multi-row money and efficiency cards; leave their data tracking intact.
rateLabel:Hide()
raw:Hide();vendor:Hide()
for _,r in ipairs({panel:GetRegions()}) do
  if r.GetText then
    local t=r:GetText()
    if t=='Raw coin looted' or t=='Vendor loot value' or
       t=='Total earned' or t=='Session time' then r:Hide() end
  end
end
rect(panel,12,-75,212,49,.19,.145,.05,.96)
rect(panel,230,-75,124,49,.07,.13,.18,.93)
rect(panel,359,-75,89,49,.07,.13,.18,.93)
caption('GOLD / HOUR',19,-80)
caption('TOTAL GOLD',237,-80)
caption('SESSION',366,-80)
move(rate,19,-97);rate:SetWidth(202)
rate:SetTextColor(1,.79,.23)
move(total,237,-98);total:SetWidth(116);total:SetJustifyH('LEFT')
move(elapsed,366,-98);elapsed:SetWidth(78);elapsed:SetJustifyH('LEFT')
-- A single high-visibility efficiency banner.
rect(panel,12,-132,436,1,.28,.34,.41,.85)
efficiencyPanel:SetParent(panel)
efficiencyPanel:ClearAllPoints()
efficiencyPanel:SetPoint('TOPLEFT',panel,'TOPLEFT',12,-139)
efficiencyPanel:SetSize(436,62)
efficiencyPanel:SetMovable(false);efficiencyPanel:EnableMouse(false)
epBg:Hide();epTop:Hide();epHint:Hide();epFooter:Hide()
for _,region in ipairs({epRate5Bg,epTimeBg,epRate15Bg,epRate30Bg,
  epRate5Label,epTimeLabel,epRate15Label,epRate30Label}) do region:Hide() end
epTitle:Hide();epTrend:Hide()
for i=1,10 do epBars[i]:Hide() end
epStatusBg:ClearAllPoints()
epStatusBg:SetPoint('TOPLEFT',efficiencyPanel,'TOPLEFT',0,-1)
epStatusBg:SetSize(436,32)
epStatusAccent:ClearAllPoints()
epStatusAccent:SetPoint('TOPLEFT',efficiencyPanel,'TOPLEFT',0,-1)
epStatusAccent:SetSize(5,32)
epTrendStatus:ClearAllPoints()
epTrendStatus:SetPoint('TOPLEFT',efficiencyPanel,'TOPLEFT',12,-9)
epTrendStatus:SetWidth(415)
epTrendStatus:SetJustifyH('LEFT')
epTrendStatus:SetFontObject('GameFontNormalLarge')
-- Secondary efficiency metrics, in one small row.
local kphLabel=caption('5m KPH',2,-42,efficiencyPanel)
local avgLabel=caption('Avg target',112,-42,efficiencyPanel)
local k15Label=caption('15m',245,-42,efficiencyPanel)
local k30Label=caption('30m',345,-42,efficiencyPanel)
move(epRate5,58,-41,efficiencyPanel);epRate5:SetWidth(46)
move(epTime,182,-41,efficiencyPanel);epTime:SetWidth(54)
move(epRate15,280,-41,efficiencyPanel);epRate15:SetWidth(52)
move(epRate30,380,-41,efficiencyPanel);epRate30:SetWidth(52)
-- Missing buffs are explicit text chips rather than blank slots.
rect(panel,12,-210,436,1,.28,.34,.41,.85)
local buffFooterTitle=text(panel,'GameFontNormal',gold)
move(buffFooterTitle,17,-224)
buffFooterTitle:SetText('BUFFS')
local chipFrames={}
for i=1,4 do
  local f=CreateFrame('Frame',nil,panel)
  f:SetSize(79,23)
  f:SetPoint('TOPLEFT',panel,'TOPLEFT',85+(i-1)*82,-217)
  f:EnableMouse(true)
  local back=f:CreateTexture(nil,'BACKGROUND');back:SetAllPoints()
  local label=text(f,'GameFontHighlightSmall',pale)
  label:SetPoint('CENTER',f,'CENTER',0,0)
  label:SetWidth(75);label:SetJustifyH('CENTER')
  f:SetScript('OnEnter',function(self)
    if self.buffName then
      GameTooltip:SetOwner(self,'ANCHOR_TOP')
      GameTooltip:AddLine('Missing: '..self.buffName,1,.75,.6)
      GameTooltip:Show()
    end
  end)
  f:SetScript('OnLeave',function()GameTooltip:Hide()end)
  chipFrames[i]={frame=f,back=back,label=label}
end
refreshBuffChips=function(missing,count)
  buffFooterTitle:SetText('BUFFS ('..tostring(count)..')')
  for i=1,4 do
    local c=chipFrames[i]
    local name=missing[i]
    c.frame.buffName=name
    if name then
      c.back:SetColorTexture(.43,.055,.055,.96)
      local short=name
      if name=='Battle Shout' then short='Shout'
      elseif name=='Weapon enhancement' then short='Weapon'
      elseif name=='Find Minerals' then short='Mining'
      elseif #name>11 then short=name:sub(1,10)..'.' end
      c.label:SetText('! '..short)
      c.label:SetTextColor(1,.88,.8)
    else
      c.back:SetColorTexture(.08,.12,.16,.65)
      c.label:SetText('')
    end
  end
  if count>4 then chipFrames[4].label:SetText('+'..(count-3)..' more') end
end
buffIndicator:Hide();buffTitle:Hide();status:Hide();buffText:Hide()
-- Legacy buff updater can re-show its old green text every check. Never display it.
buffText:SetAlpha(0)
status:SetAlpha(0)
warning:SetAlpha(0)
warning:EnableMouse(false)
warning:Hide();warning:SetAlpha(0)
local function refreshUnifiedFooter() end
-- Full efficiency history and detailed chart remain in Stats > Efficiency.

local refreshMinimal
do
-- v0.9.3: Design B compact grade panel. History and existing tracking remain.
panel:SetSize(340,300)
statsButton:Hide();buffsButton:Hide();spotsButton:Hide();efficiencyToggle:Hide()
efficiencyPanel:Hide();warning:Hide();buffText:Hide();status:Hide()
rate:Hide();total:Hide();elapsed:Hide()
buffFooterTitle:Hide();buffIndicator:Hide()
for _,c in ipairs(chipFrames) do c.frame:Hide() end
-- Hide all previous dashboard text and decorative regions except heading/subtitle.
for _,region in ipairs({panel:GetRegions()}) do
  if region~=bg and region~=top and region~=heading and region~=sub then
    region:Hide()
  end
end
heading:Hide();sub:Hide()
local function miniText(parent,font,x,y,color)
  local v=text(parent,font,color)
  v:SetPoint('TOPLEFT',parent,'TOPLEFT',x,y)
  return v
end
local function miniRect(x,y,w,h,r,g,b)
  local t=panel:CreateTexture(nil,'ARTWORK')
  t:SetPoint('TOPLEFT',panel,'TOPLEFT',x,y);t:SetSize(w,h)
  t:SetColorTexture(r,g,b,.95)
  return t
end
local miniRuleTop=miniRect(12,-7,316,1,.30,.35,.41)
local miniGoldLabel=miniText(panel,'GameFontHighlightSmall',17,-17,muted)
miniGoldLabel:SetText('GOLD / HOUR')
local miniGold=miniText(panel,'GameFontNormalLarge',17,-34,gold)
local miniTotalLabel=miniText(panel,'GameFontHighlightSmall',186,-17,muted)
miniTotalLabel:SetText('SESSION GOLD')
local miniTotal=miniText(panel,'GameFontNormalLarge',186,-34,gold)
local miniXPLabel=miniText(panel,'GameFontHighlightSmall',17,-68,muted)
miniXPLabel:SetText('XP / HOUR')
local miniXP=miniText(panel,'GameFontNormalLarge',17,-85,pale)
local miniSessionXPLabel=miniText(panel,'GameFontHighlightSmall',186,-68,muted)
miniSessionXPLabel:SetText('SESSION XP')
local miniSessionXP=miniText(panel,'GameFontNormalLarge',186,-85,pale)
local miniRuleMiddle=miniRect(12,-108,316,1,.30,.35,.41)
local gradeBack=miniRect(12,-115,110,61,.11,.19,.19)
local gradeNumber=miniText(panel,'GameFontNormalLarge',24,-127,pale)
gradeNumber:SetText('--')
local gradeCaption=miniText(panel,'GameFontHighlightSmall',24,-158,muted)
gradeCaption:SetText('OVERALL / 10')
local scoreHeading=miniText(panel,'GameFontHighlightSmall',151,-122,muted)
scoreHeading:SetText('SCORES')
local goldScore=miniText(panel,'GameFontNormalLarge',151,-140,pale)
goldScore:SetText('Gold: --')
local xpScore=miniText(panel,'GameFontNormalLarge',151,-164,pale)
xpScore:SetText('XP/hr: --')
local gradeFeedback=miniText(panel,'GameFontHighlightSmall',24,-178,muted)
local miniRuleBottom=miniRect(12,-196,316,1,.30,.35,.41)
local buffLabel=miniText(panel,'GameFontNormal',16,-209,gold)
local buffValues=miniText(panel,'GameFontHighlight',109,-208,pale)
buffValues:SetWidth(220)
buffValues:SetJustifyH('LEFT')
-- Bottom-right drag grip. Both width and height are user-adjustable.
-- The 310px minimum keeps score labels and gold amounts readable.
panel:SetResizable(true)
if panel.SetResizeBounds then
  panel:SetResizeBounds(310,285,580,480)
else
  if panel.SetMinResize then panel:SetMinResize(310,285) end
  if panel.SetMaxResize then panel:SetMaxResize(580,480) end
end
local resizeGrip=CreateFrame('Button',nil,panel)
resizeGrip:SetSize(22,22)
resizeGrip:SetPoint('BOTTOMRIGHT',panel,'BOTTOMRIGHT',0,0)
resizeGrip:SetFrameLevel(panel:GetFrameLevel()+10)
resizeGrip:EnableMouse(true)
local gripLines={}
for i=1,3 do
  local t=resizeGrip:CreateTexture(nil,'OVERLAY')
  t:SetColorTexture(.72,.55,.28,.95)
  t:SetSize(2,7+i*3)
  t:SetPoint('BOTTOMRIGHT',resizeGrip,'BOTTOMRIGHT',-4-i*5,4)
  gripLines[i]=t
end
resizeGrip:SetScript('OnMouseDown',function(self,button)
  if button=='LeftButton' then panel:StartSizing('BOTTOMRIGHT') end
end)
resizeGrip:SetScript('OnMouseUp',function()
  panel:StopMovingOrSizing()
  if H then
    H.uiWidth=math.floor(panel:GetWidth()+.5)
    H.uiHeight=math.floor(panel:GetHeight()+.5)
  end
end)
resizeGrip:SetScript('OnHide',function()panel:StopMovingOrSizing()end)
local function layoutForSize()
  local w=panel:GetWidth()
  if w<310 then w=310 elseif w>580 then w=580 end
  miniRuleTop:SetWidth(w-24)
  miniRuleMiddle:SetWidth(w-24)
  miniRuleBottom:SetWidth(w-24)
  local x=math.floor(w*.55)
  miniTotalLabel:ClearAllPoints()
  miniTotalLabel:SetPoint('TOPLEFT',panel,'TOPLEFT',x,-17)
  miniTotal:ClearAllPoints()
  miniTotal:SetPoint('TOPLEFT',panel,'TOPLEFT',x,-34)
  miniTotal:SetWidth(w-x-16)
  miniSessionXPLabel:ClearAllPoints()
  miniSessionXPLabel:SetPoint('TOPLEFT',panel,'TOPLEFT',x,-68)
  miniSessionXP:ClearAllPoints()
  miniSessionXP:SetPoint('TOPLEFT',panel,'TOPLEFT',x,-85)
  miniSessionXP:SetWidth(w-x-16)
  miniXP:SetWidth(x-25)
  buffValues:SetWidth(w-125)
  -- Spread the existing sections vertically as the panel grows or shrinks.
  -- At the new 239px default height, every position is identical to v0.9.7.
  local h=math.max(285,math.min(480,panel:GetHeight()))
  local extra=h-239
  local mid=math.floor(extra*.42)
  local bottom=math.floor(extra*.88)
  local function reposition(frame,x,y)
    frame:ClearAllPoints()
    frame:SetPoint('TOPLEFT',panel,'TOPLEFT',x,y)
  end
  reposition(miniRuleMiddle,12,-108-mid)
  reposition(gradeBack,12,-115-mid)
  reposition(gradeNumber,24,-127-mid)
  reposition(gradeCaption,24,-158-mid)
  reposition(scoreHeading,151,-122-mid)
  reposition(goldScore,151,-140-mid)
  reposition(xpScore,151,-164-mid)
  reposition(gradeFeedback,24,-178-mid)
  reposition(miniRuleBottom,12,-196-bottom)
  reposition(buffLabel,16,-209-bottom)
  reposition(buffValues,109,-208-bottom)
end
panel:SetScript('OnSizeChanged',function(self,w,h)
  layoutForSize()
end)
layoutForSize()
local function ratingColor(score)
  if score>=8 then return .32,.93,.40 end
  if score>=6 then return .98,.78,.26 end
  if score>=4 then return 1,.52,.20 end
  return 1,.26,.25
end
local function rating(rate,baseline)
  if not baseline or baseline<=0 then return nil end
  return math.max(1,math.min(10,5+5*(rate/baseline-1)))
end
local function historicalBaseline(metric,level)
  if not H then return nil,nil end
  local observations={}
  local totalWeight=0
  for _,entry in ipairs(H.sessions or {}) do
    local age=entry.duration or 0
    local lev=entry.levelStart or entry.level
    local diff=type(lev)=='number' and type(level)=='number' and math.abs(lev-level) or 99
    local weight=(diff==0 and 1) or (diff==1 and .75) or (diff==2 and .4) or (diff==3 and .15) or 0
    local value
    if metric=='xp' then value=entry.xp else value=(entry.coin or 0)+(entry.vendor or 0) end
    if entry~=current and age>=300 and weight>0 and type(value)=='number' and value>=0 then
      local rate=value*3600/age
      observations[#observations+1]={rate=rate,weight=weight*math.min(1,age/1800)}
    end
  end
  if #observations<3 then return nil,#observations end
  table.sort(observations,function(a,b) return a.rate<b.rate end)
  for _,v in ipairs(observations) do totalWeight=totalWeight+v.weight end
  local running=0
  for _,v in ipairs(observations) do
    running=running+v.weight
    if running>=totalWeight*.5 then return v.rate,#observations end
  end
  return nil,#observations
end
-- Shared live scoring baseline for predictive tooltip; no duration penalty.
function GrindOnlyForecastContext(level,goldRate,xpRate)
  local g=goldRate and rating(goldRate,historicalBaseline('gold',level)) or nil
  local x=xpRate and rating(xpRate,historicalBaseline('xp',level)) or nil
  return current,g and x and (g+x)/2 or nil
end
-- Exact timestamped rewards, including zero-reward time, over the last 15 minutes.
local function rollingRates(now)
  local seconds=math.max(0,now-S.start)
  local window=math.min(900,seconds)
  local cutoff=now-window
  local events=S.liveRewards or {}
  local kept={}
  local goldTotal,xpTotal=0,0
  for _,event in ipairs(events) do
    if event.t>=cutoff then
      kept[#kept+1]=event
      if event.kind=='xp' then xpTotal=xpTotal+event.amount
      else goldTotal=goldTotal+event.amount end
    end
  end
  S.liveRewards=kept
  return goldTotal*3600/math.max(1,window),xpTotal*3600/math.max(1,window),seconds,window
end
refreshMinimal=function()
  if S.start==0 then return end
  local goldRate,xpRate,seconds,window=rollingRates(GetTime())
  local earnings=(S.money or 0)+(S.vendor or 0)
  miniGold:SetText(seconds<15 and 'Calculating...' or coin(goldRate))
  miniTotal:SetText(coin(earnings))
  local sessionXP=math.max(0,((current and current.xp) or 0))
  local function xpNumber(value)
    return tostring(math.floor(value+0.5)):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,','')
  end
  miniXP:SetText(seconds<15 and 'Calculating...' or xpNumber(xpRate))
  miniSessionXP:SetText(xpNumber(sessionXP))
  local maxed=(UnitXPMax and safeNumber(UnitXPMax('player'))==0)
  local level=(UnitLevel and safeNumber(UnitLevel('player'))) or (current and current.level)
  local baseG=historicalBaseline('gold',level)
  local baseX=historicalBaseline('xp',level)
  -- Confidence is descriptive only; it never changes the performance score.
  local g=seconds>=300 and baseG and rating(goldRate,baseG) or nil
  local x=(not maxed and seconds>=300 and baseX and baseX>0) and rating(xpRate,baseX) or nil
  local function applyScore(label,score)
    if not score then
      label:SetText(label==goldScore and 'Gold: --' or 'XP/hr: --')
      label:SetTextColor(.60,.72,.84)
      return
    end
    local r,gg,b=ratingColor(score)
    label:SetText(string.format('%s: %.1f',label==goldScore and 'Gold' or 'XP/hr',score))
    label:SetTextColor(r,gg,b)
  end
  applyScore(goldScore,g)
  applyScore(xpScore,x)
  local score=(g and x and (g+x)/2) or (maxed and g) or nil
  if score then
    local r,gg,b=ratingColor(score)
    gradeNumber:SetText(string.format('%.1f',score))
    gradeNumber:SetTextColor(r,gg,b)
    gradeBack:SetColorTexture(r*.13,gg*.13,b*.13,.95)
    gradeFeedback:SetText((score>=8 and 'EXCELLENT' or score>=6 and 'GOOD' or score>=4 and 'FAIR' or 'NEEDS WORK')..(window<900 and ' | EARLY' or ' | 15M'))
    gradeFeedback:SetTextColor(r,gg,b)
  else
    gradeNumber:SetText('--')
    gradeNumber:SetTextColor(.65,.77,.88)
    gradeBack:SetColorTexture(.09,.16,.23,.95)
    gradeFeedback:SetText(seconds<300 and 'COLLECTING DATA' or 'BUILDING HISTORY')
    gradeFeedback:SetTextColor(.65,.77,.88)
  end
  if maxed then xpScore:SetText('XP/hr: MAX LEVEL') end
end
-- Legacy buff detector calls this function; display exact missing names in one row.
refreshBuffChips=function(missing,count)
  buffLabel:SetText('BUFFS ('..tostring(count)..')')
  if count==0 then
    buffValues:SetText('ALL ACTIVE');buffValues:SetTextColor(.38,.90,.50)
  else
    local names={}
    for i=1,math.min(3,#missing) do names[#names+1]=missing[i] end
    local label=table.concat(names,', ')
    if count>3 then label=label..'  +'..(count-3) end
    buffValues:SetText(label)
    buffValues:SetTextColor(1,.34,.30)
  end
end


-- Read-only presentation bridge for the Modern Tactical dashboard.
GrindOnlyDashboardData=function()
  local buffsText=buffValues:GetText() or ''
  local count=tonumber((buffLabel:GetText() or ''):match('%((%d+)%)')) or 0
  return {goldRate=miniGold:GetText(),sessionGold=miniTotal:GetText(),
    xpRate=miniXP:GetText(),sessionXP=miniSessionXP:GetText(),
    grade=gradeNumber:GetText(),feedback=gradeFeedback:GetText(),
    goldScore=goldScore:GetText(),xpScore=xpScore:GetText(),
    buffTitle=buffLabel:GetText(),buffs=buffsText,buffCount=count}
end
end -- scoped Design B UI; avoids Lua 200-local main chunk limit

-- Historical analytics window, built with ordinary UI widgets (no external chart library).
local stats=CreateFrame('Frame','GrindOnlyStats',UIParent)
stats:SetSize(760,550);stats:SetPoint('CENTER');stats:SetFrameStrata('DIALOG')
stats:SetMovable(true);stats:EnableMouse(true);stats:RegisterForDrag('LeftButton')
stats:SetScript('OnDragStart',function(self)self:StartMoving()end)
stats:SetScript('OnDragStop',function(self)self:StopMovingOrSizing()end)
local statsBackground=stats:CreateTexture(nil,'BACKGROUND')
statsBackground:SetAllPoints(stats)
statsBackground:SetColorTexture(.055,.075,.105,.97)
local stTitle=text(stats,'GameFontNormalLarge',gold);stTitle:SetPoint('TOPLEFT',20,-17);stTitle:SetText('GRIND ONLY  |  HISTORY')
local close=CreateFrame('Button',nil,stats,'UIPanelCloseButton');close:SetPoint('TOPRIGHT',-3,-3)
local tabs={};local selectedTab='Overview';local selectedMob=nil;local selectedItem=nil;local selectedZone=nil;local page=1;local trendPeriod='Day';local notableSort='Value'
local body=text(stats,'GameFontHighlightSmall',pale);body:SetPoint('TOPLEFT',20,-120);body:SetWidth(715);body:SetJustifyH('LEFT');body:SetJustifyV('TOP')
local rows={}
for i=1,13 do
  local r=CreateFrame('Button',nil,stats)
  r:SetSize(715,22);r:SetPoint('TOPLEFT',20,-170-(i-1)*24)
  local bg=r:CreateTexture(nil,'BACKGROUND');bg:SetAllPoints();bg:SetColorTexture(.19,.25,.32,.45)
  local label=text(r,'GameFontHighlightSmall',pale);label:SetPoint('LEFT',8,0);label:SetWidth(695);label:SetJustifyH('LEFT')
  r.label=label;r.bg=bg;r:Hide();rows[i]=r
  r:SetScript('OnEnter',function(self)bg:SetColorTexture(.38,.29,.15,.8)end)
  r:SetScript('OnLeave',function(self)bg:SetColorTexture(.19,.25,.32,.45)end)
end
local back=CreateFrame('Button',nil,stats,'UIPanelButtonTemplate')
back:SetSize(90,23);back:SetPoint('BOTTOMRIGHT',-20,15);back:SetText('Back');back:Hide()
local bars={};local barLabels={}
for i=1,8 do
  local b=stats:CreateTexture(nil,'ARTWORK');b:SetColorTexture(.8,.57,.22,.9);b:SetSize(8,8);b:Hide();bars[i]=b
  local t=text(stats,'GameFontHighlightSmall',muted);t:SetWidth(62);t:SetJustifyH('CENTER');t:Hide();barLabels[i]=t
end
-- Item interactions use Blizzard's own tooltip and link handlers. No protected actions.
-- Prefer the exact looted hyperlink to retain random suffixes and enchant details.
local function resolveItemLink(id,record)
  if record and type(record.link)=='string' and record.link:find('item:',1,true) then return record.link end
  local numericID=tonumber(id)
  if numericID and GetItemInfo then
    local _,fullLink=GetItemInfo(numericID)
    if fullLink then return fullLink end
  end
  if numericID then return 'item:'..numericID end
end
local function showItemTooltip(widget,id,record)
  local link=resolveItemLink(id,record)
  if not link or not GameTooltip then return end
  GameTooltip:SetOwner(widget,'ANCHOR_RIGHT')
  local ok=pcall(function() GameTooltip:SetHyperlink(link) end)
  if not ok then
    GameTooltip:Hide()
    if GameTooltip.SetItemByID then
      ok=pcall(function() GameTooltip:SetItemByID(tonumber(id)) end)
    end
  end
  if ok then GameTooltip:Show() end
end
local function itemModifierClick(id,record)
  local link=resolveItemLink(id,record)
  if not link then return false end
  if IsShiftKeyDown and IsShiftKeyDown() then
    local chat=ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if chat and ChatEdit_InsertLink then
      ChatEdit_InsertLink(link)
      return true
    end
  end
  if IsControlKeyDown and IsControlKeyDown() and DressUpItemLink then
    pcall(DressUpItemLink,link)
    return true
  end
  return false
end
local function bindItemRow(row,id,record)
  row:SetScript('OnEnter',function(self)
    self.bg:SetColorTexture(.38,.29,.15,.8)
    showItemTooltip(self,id,record)
  end)
  row:SetScript('OnLeave',function(self)
    self.bg:SetColorTexture(.19,.25,.32,.45)
    if GameTooltip then GameTooltip:Hide() end
  end)
  row.itemID=id;row.itemRecord=record
end
local function resetRow(row)
  row.itemID=nil;row.itemRecord=nil
  row:SetScript('OnEnter',function(self)self.bg:SetColorTexture(.38,.29,.15,.8)end)
  row:SetScript('OnLeave',function(self)
    self.bg:SetColorTexture(.19,.25,.32,.45)
    if GameTooltip then GameTooltip:Hide() end
  end)
end
local detailItemHotspot=CreateFrame('Button',nil,stats)
detailItemHotspot:SetSize(350,24)
detailItemHotspot:SetPoint('TOPLEFT',stats,'TOPLEFT',18,-102)
detailItemHotspot:Hide()
local function updateDetailItemHotspot(id,record)
  detailItemHotspot:Show()
  detailItemHotspot:SetScript('OnEnter',function(self)showItemTooltip(self,id,record)end)
  detailItemHotspot:SetScript('OnLeave',function()if GameTooltip then GameTooltip:Hide()end end)
  detailItemHotspot:SetScript('OnClick',function()itemModifierClick(id,record)end)
end
local function hideDynamic()
  for _,b in ipairs(bars)do b:Hide()end
  for _,t in ipairs(barLabels)do t:Hide()end
  for _,r in ipairs(rows)do r:Hide();r:SetScript('OnClick',nil);resetRow(r)end
  back:Hide();detailItemHotspot:Hide();body:Show()
end
local function sortedMobs()
  local a={};if H then for k,m in pairs(H.mobs) do a[#a+1]={key=k,m=m} end end
  table.sort(a,function(x,y)return ((x.m.vendor or 0)+(x.m.coin or 0))>((y.m.vendor or 0)+(y.m.coin or 0)) end)
  return a
end
local function addRow(i,label,action,itemID,itemRecord)
  local r=rows[i];if not r then return end
  -- Keep list rows below the section description; detail pages need extra room.
  local firstY=(selectedTab=='Detail' or selectedTab=='ItemDetail' or selectedTab=='ZoneDetail' or selectedTab=='SpotDetail') and -255 or -170
  r:ClearAllPoints()
  r:SetPoint('TOPLEFT',stats,'TOPLEFT',20,firstY-(i-1)*24)
  r.label:SetText(label);r:SetScript('OnClick',function()
    if itemID and itemModifierClick(itemID,itemRecord) then return end
    if action then action() end
  end)
  if itemID then bindItemRow(r,itemID,itemRecord) end
  r:Show()
end
local function listPage(entries,formatter,clicker,itemResolver)
  local per=(selectedTab=='Detail' or selectedTab=='ItemDetail' or selectedTab=='ZoneDetail' or selectedTab=='SpotDetail') and 10 or #rows
  local pages=math.max(1,math.ceil(#entries/per))
  if page>pages then page=pages end
  if page<1 then page=1 end
  for i=1,per do
    local index=(page-1)*per+i
    local e=entries[index]
    if e then
      local itemID,itemRecord
      if itemResolver then itemID,itemRecord=itemResolver(e) end
      addRow(i,formatter(e,index),function()if clicker then clicker(e) end end,itemID,itemRecord)
    end
  end
  return pages
end
local function itemLabel(id,it)
  local name=it.name or (GetItemInfo and GetItemInfo(tonumber(id))) or ('Item #'..id)
  return tostring(name)
end
local function sortedItems()
  local a={};for id,it in pairs(H.items or {}) do a[#a+1]={id=id,it=it} end
  table.sort(a,function(x,y)return (x.it.value or 0)>(y.it.value or 0)end)
  return a
end
local function sortedZones()
  local a={};for k,z in pairs(H.zones or {})do a[#a+1]={key=k,z=z}end
  table.sort(a,function(x,y)
    local aS=math.max(1,x.z.seconds or 0);local bS=math.max(1,y.z.seconds or 0)
    return ((x.z.coin or 0)+(x.z.vendor or 0))/aS>((y.z.coin or 0)+(y.z.vendor or 0))/bS
  end)
  return a
end
local function safeRate(value,secs)
  if not secs or secs<60 then return 'collecting' end
  return coin(value*3600/secs)
end
local function barsFrom(values,labels)
  local peak=1
  for _,v in ipairs(values)do if v>peak then peak=v end end
  for i,v in ipairs(values)do
    local b=bars[i];if b then
      b:ClearAllPoints();b:SetPoint('BOTTOMLEFT',stats,'BOTTOMLEFT',45+(i-1)*86,82)
      b:SetSize(48,math.max(3,math.floor(130*v/peak)));b:Show()
      local t=barLabels[i];t:ClearAllPoints();t:SetPoint('TOP',b,'BOTTOM',0,-5)
      t:SetText(labels[i] or '');t:Show()
    end
  end
end
local function trendData()
  local aggregated={}
  for day,d in pairs(H.days or {})do
    local k=day
    if trendPeriod=='Week' then
      -- ISO-like Monday grouping via local date; locale time rules are client supplied.
      local y,m,n=day:match('^(%d+)%-(%d+)%-(%d+)$')
      local epoch=y and time({year=tonumber(y),month=tonumber(m),day=tonumber(n),hour=12})
      local weekday=epoch and tonumber(date('%w',epoch)) or 1
      k=epoch and date('%Y-%m-%d',epoch-((weekday+6)%7)*86400) or day
    elseif trendPeriod=='Month' then k=day:sub(1,7) end
    aggregated[k]=(aggregated[k] or 0)+(d.coin or 0)+(d.vendor or 0)
  end
  local keys={};for k in pairs(aggregated)do keys[#keys+1]=k end
  table.sort(keys)
  local values,labels={},{}
  for i=math.max(1,#keys-7),#keys do values[#values+1]=aggregated[keys[i]];labels[#labels+1]=keys[i]:sub(6) end
  return values,labels
end
local refreshStats
local buffPage='Catalog'
local buffControls={}
local buffControlCount=0
local function clearBuffControls()
  for _,b in ipairs(buffControls) do b:Hide() end
  buffControlCount=0
end
local function buffControl(label, x, y, width, fn)
  buffControlCount=buffControlCount+1
  local b=buffControls[buffControlCount]
  if not b then
    b=CreateFrame('Button',nil,stats,'UIPanelButtonTemplate')
    buffControls[buffControlCount]=b
  end
  b:ClearAllPoints()
  b:SetSize(width or 205,23)
  b:SetPoint('TOPLEFT',stats,'TOPLEFT',x,y)
  b:SetText(label)
  b:SetScript('OnClick',fn)
  b:Show()
  return b
end
refreshStats=function()
  if GrindOnlyHideExplorer then GrindOnlyHideExplorer() end
  clearBuffControls()
  hideDynamic()
  if selectedTab=='Explorer' and GrindOnlyShowExplorer then body:Hide();GrindOnlyShowExplorer(stats,H);return end
  if not H then body:SetText('Waiting for login data...');return end
  if selectedTab=='Overview' then
    local totalCoin,totalVendor,totalKills=0,0,0
    for _,s in ipairs(H.sessions)do totalCoin=totalCoin+(s.coin or 0);totalVendor=totalVendor+(s.vendor or 0);totalKills=totalKills+(s.kills or 0) end
    body:SetText('|cffffcc77LIFETIME RECORDED|r\nSessions: '..#H.sessions..'    Observed kills: '..totalKills..'\nRaw coin: '..coin(totalCoin)..'    Vendor: '..coin(totalVendor)..'\nTotal: '..coin(totalCoin+totalVendor)..'\n\n|cffffcc77RECENT SESSIONS|r\nGold per session; newest on the right.\n\nUse Trends for day/week/month charts.')
    local values,labels={},{}
    for i=math.max(1,#H.sessions-7),#H.sessions do local s=H.sessions[i];values[#values+1]=(s.coin or 0)+(s.vendor or 0);labels[#labels+1]='#'..i end
    barsFrom(values,labels)
  elseif selectedTab=='Spots' then
    body:SetText('|cffffcc77GRINDING SPOT INTELLIGENCE|r\nOne entry per zone; subzones are combined. Only zones with observed kills are shown.\nReliable sample: 15+ minutes and 10+ kills. Earnings and time are historical estimates.')
    -- Read-only aggregation of existing zone/subzone buckets. Never rewrite history:
    -- the Zones tab and zone drilldowns still show their original subzone records.
    local grouped={}
    for key,z in pairs(H.zones or {}) do
      if type(z)=='table' then
        local zone=z.zone
        if type(zone)~='string' or zone=='' then
          -- Legacy buckets stored the location only in the key.
          zone=type(key)=='string' and key:match('^(.-) / ') or key
        end
        if type(zone)=='string' and zone~='' and zone~='Unknown' then
          local g=grouped[zone]
          if not g then
            g={key=zone,coin=0,vendor=0,seconds=0,kills=0,subzones=0}
            grouped[zone]=g
          end
          g.coin=g.coin+(tonumber(z.coin) or 0)
          g.vendor=g.vendor+(tonumber(z.vendor) or 0)
          g.seconds=g.seconds+(tonumber(z.seconds) or 0)
          g.kills=g.kills+(tonumber(z.kills) or 0)
          g.subzones=g.subzones+1
        end
      end
    end
    local a={}
    for _,g in pairs(grouped) do
      -- Towns and travel locations with no observed kills aren't grinding spots.
      if g.kills>0 and g.seconds>0 then
        g.rate=(g.coin+g.vendor)*3600/g.seconds
        g.kr=g.kills*3600/g.seconds
        g.conf=(g.seconds>=900 and g.kills>=10)
        a[#a+1]=g
      end
    end
    table.sort(a,function(x,y)
      if x.conf~=y.conf then return x.conf end
      if x.rate~=y.rate then return x.rate>y.rate end
      return x.key<y.key
    end)
    local pages=listPage(a,function(e,i)
      return string.format('%d. %s  |  %s/h  |  %.0f kills/h  |  %d kills  |  %s',
        i,e.key,coin(e.rate),e.kr,e.kills,e.conf and '|cff65d995RELIABLE|r' or '|cffffb366LOW SAMPLE|r')
    end,function(e)
      selectedZone=e.key;selectedTab='SpotDetail';page=1;refreshStats()
    end)
    if #a==0 then body:SetText('No grinding zones with recorded kills yet. Grind mobs to collect data.')
    else body:SetText(body:GetText()..'\nPage '..page..' / '..pages) end
  elseif selectedTab=='SpotDetail' then
    back:Show()
    local coinTotal,vendorTotal,seconds,kills,subs=0,0,0,0,{}
    for key,z in pairs(H.zones or {}) do
      if type(z)=='table' then
        local zone=z.zone
        if type(zone)~='string' or zone=='' then zone=type(key)=='string' and key:match('^(.-) / ') or key end
        if zone==selectedZone then
          coinTotal=coinTotal+(tonumber(z.coin) or 0)
          vendorTotal=vendorTotal+(tonumber(z.vendor) or 0)
          seconds=seconds+(tonumber(z.seconds) or 0)
          kills=kills+(tonumber(z.kills) or 0)
          subs[#subs+1]={key=key,z=z}
        end
      end
    end
    if #subs==0 then selectedTab='Spots';refreshStats();return end
    body:SetText('|cffffcc77'..selectedZone..' - COMBINED SPOT|r\nTime: '..duration(seconds)..'    Observed kills: '..kills..'\nRaw coin: '..coin(coinTotal)..'    Vendor: '..coin(vendorTotal)..'\nTotal: '..coin(coinTotal+vendorTotal)..'    Gold/hour: '..safeRate(coinTotal+vendorTotal,seconds)..'\n\n|cffffcc77SUBZONE BREAKDOWN|r\nClick a subzone to see its original records.')
    table.sort(subs,function(x,y)return (x.z.kills or 0)>(y.z.kills or 0)end)
    listPage(subs,function(e,i)
      local z=e.z
      return i..'. '..e.key..' | '..safeRate((z.coin or 0)+(z.vendor or 0),z.seconds)..'/h | '..duration(z.seconds or 0)..' | '..(z.kills or 0)..' kills'
    end,function(e)selectedZone=e.key;selectedTab='ZoneDetail';page=1;refreshStats()end)
  elseif selectedTab=='Buffs' then
    body:SetText('|cffffcc77MISSING BUFF TRACKING|r\nClick a buff to enable/disable its warning. Changes are saved per account.\nCustom buffs can be learned from your currently active auras.\nGreen = tracked; grey = ignored.')
    buffControl('Catalog',20,-157,110,function()buffPage='Catalog';page=1;refreshStats()end)
    buffControl('Active buffs',140,-157,125,function()buffPage='Active';page=1;refreshStats()end)
    local choices={}
    if buffPage=='Catalog' then
      for _,entry in ipairs(checks) do choices[#choices+1]=entry[1] end
      choices[#choices+1]='Weapon enhancement'
    else
      local seen={}
      for i=1,40 do
        local name=buffName(i)
        if not name then break end
        if type(name)=='string' and not (issecretvalue and issecretvalue(name)) and not seen[name] then
          seen[name]=true;choices[#choices+1]=name
        end
      end
      table.sort(choices)
      if #choices==0 then body:SetText(body:GetText()..'\nNo readable active buffs detected.') end
    end
    local per=24
    local pages=math.max(1,math.ceil(#choices/per))
    if page>pages then page=pages end
    for i=(page-1)*per+1,math.min(#choices,page*per) do
      local name=choices[i]
      local enabled=(buffPage=='Catalog' and tracked(name)) or (buffPage=='Active' and H.customBuffs[name]==true)
      local x=20+((i-1)%2)*360
      local y=-192-math.floor(((i-1)%per)/2)*26
      buffControl((enabled and '|cff65d995[ON] |r' or '|cffaaaaaa[OFF] |r')..name,x,y,345,function()
        if buffPage=='Catalog' then H.buffTracking[name]=not tracked(name)
        else H.customBuffs[name]=not (H.customBuffs[name]==true) end
        checkBuffs();refreshStats()
      end)
    end
    body:SetText(body:GetText()..'\nPage '..page..' / '..pages)
  elseif selectedTab=='Mobs' then
    body:SetText('|cffffcc77MOB PROFITABILITY|r\nClick a row for drops and timing. Gold/hour uses observed kills and estimated active time.')
    local a=sortedMobs()
    local pages=listPage(a,function(e,i)
      local m=e.m;local v=(m.coin or 0)+(m.vendor or 0);local k=math.max(1,m.kills or 0)
      return string.format('%d. %s Lv %s  |  %d kills  |  %.1fs / kill  |  %s',i,m.name or '?',tostring(m.level),m.kills or 0,v/k/100,coin(v))
    end,function(e)selectedMob=e.key;selectedTab='Detail';page=1;refreshStats()end)
    if #a==0 then body:SetText('No observed mob kills yet.')end
    body:SetText(body:GetText()..'\nPage '..page..' / '..pages)
  elseif selectedTab=='Detail' then
    back:Show();local m=selectedMob and H.mobs[selectedMob]
    if not m then selectedTab='Mobs';refreshStats();return end
    local v=(m.coin or 0)+(m.vendor or 0);local kills=math.max(1,m.kills or 0)
    local fight=(m.timedKills or 0)>0 and string.format('%.1fs',m.fightSeconds/m.timedKills) or 'Not measured'
    local gap=(m.gapSamples or 0)>0 and string.format('%.1fs',m.gapSeconds/m.gapSamples) or 'Not measured'
    local combatRate=(m.fightSeconds or 0)>0 and string.format('%.1f',3600*(m.timedKills or 0)/m.fightSeconds) or 'n/a'
    body:SetText('|cffffcc77'..(m.name or '?')..' Lv '..tostring(m.level)..'|r\nObserved kills: '..(m.kills or 0)..'   Earnings: '..coin(v)..'   Silver/kill: '..string.format('%.2f',v/kills/100)..'\nAverage observed fight: '..fight..'   Between kills: '..gap..'   Combat-only kills/h: '..combatRate..'\nTiming only includes continuously observed targeted mobs.\n\n|cffffcc77ATTRIBUTED DROPS (ITEMS PER KILL)|r')
    local a={};for id,it in pairs(m.items or {})do a[#a+1]={id=id,it=it}end
    table.sort(a,function(x,y)return (x.it.value or 0)>(y.it.value or 0)end)
    listPage(a,function(e) return itemLabel(e.id,e.it)..' x'..(e.it.count or 0)..'  |  '..string.format('%.1f',100*(e.it.count or 0)/kills)..' items/100 kills  |  '..coin(e.it.value or 0) end,function(e)selectedItem=e.id;selectedTab='ItemDetail';refreshStats()end,function(e)return e.id,e.it end)
    if #a==0 then body:SetText(body:GetText()..'\nNo confidently attributed drops yet.')end
  elseif selectedTab=='Zones' or selectedTab=='ZoneBreakdown' then
    local grouped={}
    local detail=selectedTab=='ZoneBreakdown'
    local sort=H.zoneSort or 'gold'
    for key,z in pairs(H.zones or {}) do
      if type(z)=='table' then
        local zone=z.zone or key:match('^(.-) / ') or key
        local sub=z.subzone or key:match(' / (.*)$') or ''
        if sub=='' or sub=='(unspecified)' then sub='Other locations' end
        if not detail or zone==selectedZone then
          local name=detail and sub or zone
          local g=grouped[name] or {key=name,coin=0,vendor=0,seconds=0,kills=0,xp=0,xpSeconds=0}
          grouped[name]=g
          for _,k in ipairs({'coin','vendor','seconds','kills','xp','xpSeconds'}) do g[k]=g[k]+(tonumber(z[k]) or 0) end
        end
      end
    end
    for key,r in pairs(H.analytics.zoneXPBackfill or {}) do
      if not detail or r.zone==selectedZone then
        local sub=r.subzone
        if not sub or sub=='' or sub=='(unspecified)' then sub='Other locations' end
        local name=detail and sub or r.zone
        local g=grouped[name] or {key=name,coin=0,vendor=0,seconds=0,kills=0,xp=0,xpSeconds=0}
        grouped[name]=g
        g.estimatedXP=(g.estimatedXP or 0)+r.xp
        g.estimatedSeconds=(g.estimatedSeconds or 0)+r.seconds
      end
    end
    local a={};for _,g in pairs(grouped) do a[#a+1]=g end
    local function rate(g,k)
      if k=='xp' then
        if g.xpSeconds>=60 then return g.xp*3600/g.xpSeconds end
        if (g.estimatedSeconds or 0)>=60 then return g.estimatedXP*3600/g.estimatedSeconds end
        return -1
      end
      return g.seconds>=60 and (g.coin+g.vendor)*3600/g.seconds or -1
    end
    table.sort(a,function(x,y)
      if sort=='name' then return x.key<y.key end
      local v,w=rate(x,sort),rate(y,sort)
      if v==w then return x.key<y.key end
      return v>w
    end)
    body:SetText('|cffffcc77'..(detail and ('ZONES / '..selectedZone) or 'ZONE PROFITABILITY')..'|r\nGold: all recorded time. XP: measured since v1.3.13; ~ = historical estimate. Click a zone.')
    if detail then back:Show() end
    for i,c in ipairs({{'Location','name',20,275},{'Gold/hr','gold',300,130},{'XP/hr','xp',435,115}}) do
      buffControl(c[1]..(sort==c[2] and ' *' or ''),c[3],-148,c[4],function()H.zoneSort=c[2];page=1;refreshStats()end)
    end
    local pages=math.max(1,math.ceil(#a/12));page=math.max(1,math.min(page,pages))
    for i=1,12 do
      local g=a[(page-1)*12+i]
      if g then
        local xp=rate(g,'xp');local xpText=xp>=0 and ((g.xpSeconds<60 and '~' or '')..string.format('%.0f',xp)) or '--'
        addRow(i,g.key..'  |  '..safeRate(g.coin+g.vendor,g.seconds)..'/h  |  '..xpText..' XP/h  |  '..duration(g.seconds)..'  |  '..g.kills..' kills',not detail and function()selectedZone=g.key;selectedTab='ZoneBreakdown';page=1;refreshStats()end or nil)
        rows[i]:ClearAllPoints();rows[i]:SetPoint('TOPLEFT',stats,'TOPLEFT',20,-180-(i-1)*24)
      end
    end
    if #a==0 then body:SetText(body:GetText()..' No location data yet.') end
  elseif selectedTab=='ZoneDetail' then
    back:Show();local z=H.zones[selectedZone]
    if not z then selectedTab='Zones';refreshStats();return end
    local v=(z.coin or 0)+(z.vendor or 0)
    body:SetText('|cffffcc77'..selectedZone..'|r\nTime: '..duration(z.seconds or 0)..'    Kills observed: '..(z.kills or 0)..'\nRaw coin: '..coin(z.coin or 0)..'    Vendor: '..coin(z.vendor or 0)..'\nTotal: '..coin(v)..'    Gold/hour: '..safeRate(v,z.seconds)..'\n\nSubzone results depend on your client reporting subzone changes.')
  elseif selectedTab=='Trends' then
    body:SetText('|cffffcc77EARNINGS BY '..trendPeriod:upper()..'|r\nClick Day / Week / Month below to switch grouping.\nCharts start collecting with v0.6.0; old sessions lack dated earnings buckets.')
    local values,labels=trendData();barsFrom(values,labels)
  elseif selectedTab=='Loot' or selectedTab=='Notable' then
    local a=sortedItems()
    if selectedTab=='Notable' then
      body:SetText('|cffffcc77NOTABLE LOOT - '..notableSort:upper()..'|r\nValue: highest unit vendor price. Rarest: fewest observed items (not drop chance).')
      if notableSort=='Rarest' then table.sort(a,function(x,y)return (x.it.count or 0)<(y.it.count or 0)end)
      else table.sort(a,function(x,y)return (x.it.value or 0)/math.max(1,x.it.count or 1)>(y.it.value or 0)/math.max(1,y.it.count or 1)end) end
    else body:SetText('|cffffcc77LOOT EXPLORER|r\nClick an item for recorded sources and estimated item frequency.') end
    listPage(a,function(e,i)local it=e.it;return i..'. '..itemLabel(e.id,it)..' x'..(it.count or 0)..' | '..coin(it.value or 0)..' | '..coin((it.value or 0)/math.max(1,it.count or 1))..'/item' end,function(e)selectedItem=e.id;selectedTab='ItemDetail';refreshStats()end,function(e)return e.id,e.it end)
    if #a==0 then body:SetText('No loot recorded yet.')end
  elseif selectedTab=='ItemDetail' then
    back:Show();local it=H.items[selectedItem]
    if not it then selectedTab='Loot';refreshStats();return end
    local name=itemLabel(selectedItem,it)
    updateDetailItemHotspot(selectedItem,it)
    body:SetText('|cffffcc77'..name..'|r\nItem ID: '..selectedItem..'   Total looted: '..(it.count or 0)..'\nTotal vendor value: '..coin(it.value or 0)..'\nAverage value per item: '..coin((it.value or 0)/math.max(1,it.count or 1))..'\n\n|cffffcc77ATTRIBUTED MOB SOURCES|r\nItems per 100 observed kills (not exact drop chance).')
    local a={};for _,m in pairs(H.mobs)do local rec=m.items and m.items[selectedItem];if rec then a[#a+1]={m=m,rec=rec}end end
    table.sort(a,function(x,y)return (x.rec.count or 0)>(y.rec.count or 0)end)
    listPage(a,function(e)return (e.m.name or '?')..' Lv '..tostring(e.m.level)..' | x'..(e.rec.count or 0)..' | '..string.format('%.1f',100*(e.rec.count or 0)/math.max(1,e.m.kills or 0))..' items/100 kills' end,function(e)selectedMob=mobKey(e.m.name,e.m.level);selectedTab='Detail';refreshStats()end)
    if #a==0 then body:SetText(body:GetText()..'\nNo confident mob source attribution.')end
  elseif selectedTab=='Efficiency' then
    local k5,r5,a5=windowSummary(300)
    local k15,r15,a15=windowSummary(900)
    local k30,r30,a30=windowSummary(1800)
    local timed=current.timedKills or 0
    local fight=current.fightSeconds or 0
    local gap=current.gapSeconds or 0
    local samples=current.gapSamples or 0
    local avg=timed>0 and string.format('%.1fs',fight/timed) or 'n/a'
    local avgGap=samples>0 and string.format('%.1fs',gap/samples) or 'n/a'
    local observed=math.max(0,current.duration or 0)
    local observedPct=observed>0 and 100*math.min(fight,observed)/observed or 0
    body:SetText(string.format('|cffffcc77LIVE GRIND EFFICIENCY|r\nKills/hour: last 5m %.0f (%d)   15m %.0f (%d)   30m %.0f (%d)\nObserved kills: %d   Timed kills: %d\nAverage target-to-death: %s   Average between-kill gap: %s\nObserved target time / session: %.1f%% (NOT actual combat uptime)\n\n|cffffcc77SESSION KILL TREND|r\nKills per 5-minute interval. Only data collected since v0.7.0.\n\nMeasurements are target-based estimates; target switching and idle targeting distort timings.',r5,k5,r15,k15,r30,k30,current.kills or 0,timed,avg,avgGap,observedPct))
    local values,labels={},{}
    local now=GetTime()
    for i=6,1,-1 do
      local n=0
      local lo=(i-1)*300;local hi=i*300
      for _,e in ipairs(liveKills) do
        local age=now-e.t
        if age>=lo and age<hi then n=n+1 end
      end
      values[#values+1]=n;labels[#labels+1]=tostring(math.floor(hi/60))..'m'
    end
    barsFrom(values,labels)
  elseif selectedTab=='Combat' then
    local a=sortedMobs();table.sort(a,function(x,y)return (x.m.timedKills or 0)>(y.m.timedKills or 0)end)
    body:SetText('|cffffcc77COMBAT EFFICIENCY - TARGET OBSERVATIONS|r\nEstimated fight duration is time from first living target observation to death.\nThis is not a combat log and can include target idle time; unobserved kills are missed.')
    listPage(a,function(e)local m=e.m;local fights=m.timedKills or 0;local avg=fights>0 and string.format('%.1fs',m.fightSeconds/fights) or 'n/a';local gap=(m.gapSamples or 0)>0 and string.format('%.1fs',m.gapSeconds/m.gapSamples) or 'n/a';return (m.name or '?')..' Lv '..tostring(m.level)..' | '..fights..' timed | '..avg..' avg fight | '..gap..' gap' end,function(e)selectedMob=e.key;selectedTab='Detail';refreshStats()end)
  end
end
back:SetScript('OnClick',function()
  if selectedTab=='Detail' then selectedTab='Mobs'
  elseif selectedTab=='ZoneDetail' or selectedTab=='ZoneBreakdown' then selectedTab='Zones'
  else selectedTab='Loot' end
  page=1;refreshStats()
end)
for i,tabName in ipairs({'Overview','Mobs','Loot','Zones','Spots','Trends','Notable','Combat','Efficiency','Buffs','Explorer'})do
  local b=CreateFrame('Button',nil,stats,'UIPanelButtonTemplate')
  b:SetSize(86,24)
  b:SetPoint('TOPLEFT',18+((i-1)%8)*90,-52-math.floor((i-1)/8)*27)
  b:SetText(tabName)
  b:SetScript('OnClick',function()selectedTab=tabName;selectedMob=nil;selectedItem=nil;page=1;refreshStats()end)
  tabs[#tabs+1]=b
end
local prev=CreateFrame('Button',nil,stats,'UIPanelButtonTemplate')
prev:SetSize(68,22);prev:SetPoint('BOTTOMLEFT',20,15);prev:SetText('< Prev')
prev:SetScript('OnClick',function()page=math.max(1,page-1);refreshStats()end)
local nextPage=CreateFrame('Button',nil,stats,'UIPanelButtonTemplate')
nextPage:SetSize(68,22);nextPage:SetPoint('BOTTOMLEFT',94,15);nextPage:SetText('Next >')
nextPage:SetScript('OnClick',function()page=page+1;refreshStats()end)
local rarity=CreateFrame('Button',nil,stats,'UIPanelButtonTemplate')
rarity:SetSize(100,22);rarity:SetPoint('BOTTOMLEFT',520,15);rarity:SetText('Value / Rarest')
rarity:SetScript('OnClick',function()notableSort=(notableSort=='Value') and 'Rarest' or 'Value';selectedTab='Notable';page=1;refreshStats()end)
for i,period in ipairs({'Day','Week','Month'})do
  local b=CreateFrame('Button',nil,stats,'UIPanelButtonTemplate')
  b:SetSize(70,22);b:SetPoint('BOTTOMLEFT',275+(i-1)*75,15);b:SetText(period)
  b:SetScript('OnClick',function()trendPeriod=period;selectedTab='Trends';refreshStats()end)
end
stats:Hide()
statsButton:SetScript('OnClick',function()if stats:IsShown()then stats:Hide()else refreshStats();stats:Show()end end)
local function openMainTab(tab)
  selectedTab=tab
  selectedMob=nil;selectedItem=nil;selectedZone=nil
  page=1
  refreshStats()
  stats:Show()
end
efficiencyToggle:SetScript('OnClick',function()openMainTab('Efficiency')end)
spotsButton:SetScript('OnClick',function()openMainTab('Spots')end)
buffsButton:SetScript('OnClick',function()openMainTab('Buffs')end)

-- Forward declarations: login handler is defined before minimap implementation.
local setMinimapPosition, setUIVisible, saveVisibility
for _,ev in ipairs({'PLAYER_LOGIN','PLAYER_XP_UPDATE','PLAYER_LEVEL_UP','CHAT_MSG_LOOT','CHAT_MSG_MONEY','GET_ITEM_INFO_RECEIVED','UNIT_AURA','PLAYER_REGEN_ENABLED','PLAYER_ENTERING_WORLD','UNIT_SPELLCAST_SUCCEEDED','PLAYER_LOGOUT','ZONE_CHANGED_NEW_AREA','MAIL_SHOW','MAIL_CLOSED'}) do addon:RegisterEvent(ev) end
addon:SetScript('OnEvent',function(_,ev,...)
  if ev=='PLAYER_LOGIN' then
    initHistory();liveKills={};reset();
    if H and type(H.uiWidth)=='number' then panel:SetWidth(math.max(310,math.min(580,H.uiWidth))) end
    if H and type(H.uiHeight)=='number' then panel:SetHeight(math.max(285,math.min(480,H.uiHeight))) end
    checkBuffs();
    setMinimapPosition(H.minimapAngle or 220)
    if H.uiVisible==false then setUIVisible(false) end
    -- Old detached efficiency position is intentionally ignored.
    print('|cffd6aa55Grind Only:|r loot tracking enabled; mailbox loot excluded without stale mailbox lockout. /wgf stats for history.')
  elseif ev=='PLAYER_XP_UPDATE' or ev=='PLAYER_LEVEL_UP' then sampleXP()
  elseif ev=='MAIL_SHOW' then mailboxOpen=true
  elseif ev=='MAIL_CLOSED' then mailboxOpen=false
  elseif ev=='PLAYER_ENTERING_WORLD' then mailboxOpen=false
  elseif ev=='PLAYER_LOGOUT' then saveVisibility();if current then current.ended=nowEpoch() end;pruneMobs()
  elseif ev=='ZONE_CHANGED_NEW_AREA' then if current and GetRealZoneText then current.zone=GetRealZoneText() end
  elseif ev=='UNIT_SPELLCAST_SUCCEEDED' then
    local unit,castGUID,spellID=...
    if unit=='player' then
      -- Different client forks may supply a spell name rather than an ID.
      if type(spellID)=='string' then recordCast(nil,spellID)
      else recordCast(spellID) end
      checkBuffs()
    end
  elseif ev=='CHAT_MSG_LOOT' then
    local msg=...
    if not isMailboxVisible() and type(msg)=='string' and (not issecretvalue or not issecretvalue(msg)) then
      -- Loot events are independent of mob observation; source attribution remains best-effort.
      local link=msg:match('(|c%x+|Hitem:.-|h%[.-%]|h|r)') or msg:match('(|Hitem:.-|h%[.-%]|h)')
      if link then addItem(link,tonumber(msg:match('[xX](%d+)%s*[%.!]?$')) or 1) end
    end
  elseif ev=='CHAT_MSG_MONEY' then
    local msg=...;if not isMailboxVisible() and type(msg)=='string' and (not issecretvalue or not issecretvalue(msg)) then local amount=parseMoney(msg);if amount>0 then S.money=S.money+amount;recordCoin(amount) end end
  elseif ev=='GET_ITEM_INFO_RECEIVED' then flushItem(...)
  elseif ev=='UNIT_AURA' then if ...=='player' then checkBuffs() end
  else checkBuffs() end
  if current then current.vendor=S.vendor;current.coin=S.money end
  if stats:IsShown() and (ev=='CHAT_MSG_LOOT' or ev=='CHAT_MSG_MONEY') then refreshStats() end
  update()
end)

-- Minimap launcher: left click toggles all Grind Only UI, right click opens history.
-- Uses only ordinary UI frames; no combat-log registration or external libraries.
local minimapButton=CreateFrame('Button','GrindOnlyMinimapButton',Minimap)
minimapButton:SetSize(32,32)
minimapButton:SetFrameStrata('MEDIUM')
minimapButton:SetFrameLevel((Minimap:GetFrameLevel() or 1)+8)
minimapButton:RegisterForClicks('LeftButtonUp','RightButtonUp')
minimapButton:RegisterForDrag('LeftButton')
minimapButton:SetMovable(true)
local iconTexture=minimapButton:CreateTexture(nil,'ARTWORK')
iconTexture:SetTexture('Interface\\Icons\\INV_Misc_Coin_01')
iconTexture:SetSize(20,20)
iconTexture:SetPoint('CENTER',0,0)
local iconBorder=minimapButton:CreateTexture(nil,'OVERLAY')
iconBorder:SetTexture('Interface\\Minimap\\MiniMap-TrackingBorder')
iconBorder:SetSize(54,54)
iconBorder:SetPoint('TOPLEFT',0,0)
setMinimapPosition=function(angle)
  angle=tonumber(angle) or 220
  minimapButton:ClearAllPoints()
  local rad=math.rad(angle)
  minimapButton:SetPoint('CENTER',Minimap,'CENTER',math.cos(rad)*80,math.sin(rad)*80)
end
saveVisibility=function()
  if not H then return end
  H.uiVisible=panel:IsShown()
  H.uiWidth=math.floor(panel:GetWidth()+.5)
  H.uiHeight=math.floor(panel:GetHeight()+.5)
  -- Efficiency is embedded in the unified panel.
end
setUIVisible=function(visible)
  if visible then
    panel:Show()
    -- Detailed efficiency remains in the History tab.
  else
    panel:Hide()
    stats:Hide()
  end
  saveVisibility()
end
minimapButton:SetScript('OnClick',function(_,button)
  if button=='RightButton' then
    if stats:IsShown() then stats:Hide() else refreshStats();stats:Show() end
  else
    setUIVisible(not panel:IsShown())
  end
end)
minimapButton:SetScript('OnDragStart',function(self) self.dragging=true end)
minimapButton:SetScript('OnDragStop',function(self) self.dragging=false end)
minimapButton:SetScript('OnUpdate',function(self)
  if not self.dragging then return end
  local x,y=GetCursorPosition()
  local scale=Minimap:GetEffectiveScale()
  local cx,cy=Minimap:GetCenter()
  if not x or not y or not cx or not cy then return end
  local angle=math.deg((math.atan2 and math.atan2(y/scale-cy,x/scale-cx)) or math.atan(y/scale-cy,x/scale-cx))
  setMinimapPosition(angle)
  if H then H.minimapAngle=angle end
end)
minimapButton:SetScript('OnEnter',function(self)
  GameTooltip:SetOwner(self,'ANCHOR_LEFT')
  GameTooltip:AddLine('Grind Only',1,.78,.32)
  GameTooltip:AddLine('Left-click: Toggle dashboard',1,1,1)
  GameTooltip:AddLine('Right-click: Toggle statistics',1,1,1)
  GameTooltip:AddLine('Drag: Move minimap button',.65,.7,.75)
  GameTooltip:Show()
end)
minimapButton:SetScript('OnLeave',function() GameTooltip:Hide() end)
setMinimapPosition(220)

-- Conservative target-based kill detection; no combat-log event registration.
-- Only counts a hostile NPC that was seen alive and subsequently seen dead while targeted.
-- Does not count untargeted kills, and does not claim complete mob statistics.
local targetSeen={}
local targetTick=0
local lastObservedKill=nil
-- Secret values are opaque on modern/Forever clients. Never use one as a table key.
local function isRestricted(value)
  if type(issecretvalue) ~= 'function' then return false end
  local ok, result = pcall(issecretvalue, value)
  return not ok or result == true
end
local targetSamplingFaults=0
local function sampleTarget()
  if not current or not UnitExists then return end
  local exists=UnitExists('target')
  if isRestricted(exists) or not exists then return end
  if UnitIsPlayer then
    local player=UnitIsPlayer('target')
    if isRestricted(player) or player then return end
  end
  if UnitCanAttack then
    local attackable=UnitCanAttack('player','target')
    if isRestricted(attackable) or not attackable then return end
  end
  local guid=UnitGUID and UnitGUID('target')
  local name=UnitName and UnitName('target')
  if isRestricted(guid) or isRestricted(name) then return end
  if type(guid)~='string' or guid=='' or type(name)~='string' or name=='' then return end
  local dead=UnitIsDead and UnitIsDead('target')
  if isRestricted(dead) then return end
  local entry=targetSeen[guid]
  if not dead then
    if not entry then
      local level=UnitLevel and UnitLevel('target') or '?'
      if isRestricted(level) or (type(level)~='number' and type(level)~='string') then level='?' end
      targetSeen[guid]={name=name,level=level,seen=GetTime(),counted=false}
      observeMobLocation(name,level,guid,'encounter')
    end
  elseif entry and not entry.counted then
    entry.counted=true
    local m=rememberMob(entry.name,entry.level)
    if m then
      observeMobLocation(entry.name,entry.level,guid,'kill')
      m.kills=m.kills+1;m.last=nowEpoch();current.kills=current.kills+1
      local observedAt=GetTime()
      local fight=observedAt-(entry.seen or observedAt)
      local gap=lastObservedKill and (entry.seen-lastObservedKill) or nil
      recordObservedKill(m,fight,gap)
      lastObservedKill=observedAt
      recentDeaths[#recentDeaths+1]={key=mobKey(entry.name,entry.level),t=GetTime()}
      while #recentDeaths>15 do table.remove(recentDeaths,1) end
      if stats:IsShown() then refreshStats() end
    end
  end
  local now=GetTime()
  for k,v in pairs(targetSeen) do if now-v.seen>120 then targetSeen[k]=nil end end
end
-- Protect the high-frequency poller so a client-specific restricted value
-- cannot produce an endless stream of Lua errors in dungeons.
local function safeSampleTarget()
  if targetSamplingFaults>=3 then return end
  local ok,err=pcall(sampleTarget)
  if not ok then
    targetSamplingFaults=targetSamplingFaults+1
    if targetSamplingFaults==1 then
      print('|cffff8855Grind Only:|r target sampling disabled after an API error; other tracking remains active. /reload to retry.')
    end
    -- Disable this polling path immediately; no repeating errors or spam.
    targetSamplingFaults=3
  end
end

local tick=0
addon:SetScript('OnUpdate',function(_,dt)
  if false and warning:IsShown() then
    pulseTime=pulseTime+dt
    local a=.77+.18*math.sin(pulseTime*4)
    warningBg:SetAlpha(a)
  end
  updateZoneClock(dt)
  targetTick=targetTick+dt
  if targetTick>=0.2 then targetTick=0;safeSampleTarget() end
  tick=tick+dt
  if tick>=2 then tick=0;update();checkBuffs();warning:Hide();buffText:Hide();refreshEfficiencyPanel();refreshUnifiedFooter();sampleXP();refreshMinimal() end
end)
SLASH_WARRIORGRINDFOREVER1='/wgf'
SLASH_WARRIORGRINDFOREVER2='/grindonly'
SlashCmdList.WARRIORGRINDFOREVER=function(msg)
  msg=(msg or ''):lower():match('^%s*(.-)%s*$')
  if msg=='debug' then
    debugCasts=not debugCasts
    print('Grind Only: cast diagnostics '..(debugCasts and 'ON' or 'OFF'))
  elseif msg=='buffs' then selectedTab='Buffs';refreshStats();stats:Show()
  elseif msg=='spots' then selectedTab='Spots';refreshStats();stats:Show()
  elseif msg=='eff' or msg=='efficiency' then selectedTab='Efficiency';refreshStats();stats:Show()
  elseif msg=='reset' then liveKills={};reset();lastMetricBucket=nil;if current then current.ended=nowEpoch() end;current={started=nowEpoch(),zone=(GetRealZoneText and GetRealZoneText()) or 'Unknown',kills=0,coin=0,vendor=0,items=0};current.duration=0;current.xp=0;current.level=UnitLevel and UnitLevel('player') or 0;current.levelStart=current.level;current.schema=4;xpLast=nil;levelLast=nil;sampleXP();current.timedKills=0;current.fightSeconds=0;current.gapSeconds=0;current.gapSamples=0;current.efficiencySamples={};lastObservedKill=nil;targetSeen={};recentDeaths={};if H then H.sessions[#H.sessions+1]=current end;print('Grind Only: session reset')
  elseif msg=='stats' then refreshStats();stats:Show()
  elseif msg:match('^mob%s+%d+') then local index=tonumber(msg:match('%d+'));local entry=sortedMobs()[index];if entry then selectedMob=entry.key;selectedTab='Detail';refreshStats();stats:Show() else print('Grind Only: mob number not found') end
  elseif msg=='show' then setUIVisible(true)
  elseif msg=='hide' then setUIVisible(false)
  else setUIVisible(not panel:IsShown()) end
end
