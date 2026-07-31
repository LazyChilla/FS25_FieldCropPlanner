-- PlantingCalendar.lua  (Saatplan-Assistent)
-- Aussaatfenster pro Frucht als reine Info-Anzeige (Map-Hotspot + F7-HUD).
--
-- Datenquelle 100% gegen echten Giants-Code verifiziert:
--   FruitTypeDesc:getIsPlantableInPeriod(growthMode, seasonPeriod)  (fruits/FruitTypeDesc)
--   -- der native Ingame-Kalender (gui/InGameMenuCalendarFrame) baut sein
--   Aussaat-Fenster mit exakt derselben Schleife i=1..12.
-- Format-/Wrap-Logik neu implementiert nach dem Vorbild von SeedSelector
--   (getPlantability / formatPeriods): Perioden -> 12 Monate, zusammenhaengende
--   Bereiche, Jahres-Wrap fuer Winterfruechte. Monatskuerzel + Texte ueber l10n
--   (sp_cal_months / sp_cal_prefix / sp_cal_allYear), also zweisprachig.
-- pcall NUR um den einen fremden Engine-Aufruf (getIsPlantableInPeriod), und
-- dort MIT Fehler-Log (Achim-Standard: kein stilles Verschlucken, eigenen
-- deterministischen Code NICHT in pcall verstecken). Bei fehlenden Daten wird
-- nil zurueckgegeben und der Aufrufer laesst die Zeile einfach weg.

PlantingCalendar = {}

-- Monatskuerzel aus l10n (kommagetrennt). Periode 1 = "Maerz" (FS25-Jahr startet
-- im Fruehling), deckt sich mit g_i18n:formatPeriod und dem Wissensspeicher.
local function getMonthNames()
    local raw = (g_i18n ~= nil) and g_i18n:getText("sp_cal_months") or ""
    local names = {}
    for part in string.gmatch(raw, "([^,]+)") do
        names[#names + 1] = part
    end
    if #names < 12 then
        names = { "1","2","3","4","5","6","7","8","9","10","11","12" }
    end
    return names
end

-- Fruchtdeskriptor aus Fruchtname (primaer) oder FillType-Index (Fallback) holen
local function resolveFruitDesc(fruitName, fillTypeIndex)
    if g_fruitTypeManager == nil then return nil end
    local fd = nil
    if fruitName ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil then
        fd = g_fruitTypeManager:getFruitTypeByName(fruitName)
    end
    if fd == nil and fillTypeIndex ~= nil and g_fruitTypeManager.getFruitTypeByFillTypeIndex ~= nil then
        fd = g_fruitTypeManager:getFruitTypeByFillTypeIndex(fillTypeIndex)
    end
    return fd
end

-- Nach dem Vorbild von SeedSelector.getPlantability.
-- Rueckgabe: allowed (Bool-Array je Periode) | nil, n (Periodenzahl), hasData (bool)
--   allowed == nil UND hasData == true  -> keine saisonale Restriktion (ganzjaehrig)
--   hasData == false                    -> keine verwertbaren Daten (Aufrufer: Zeile weglassen)
local function getPlantability(fd)
    local n = (Environment ~= nil and Environment.PERIODS_IN_YEAR) or 12
    if fd == nil or fd.getIsPlantableInPeriod == nil then
        return nil, n, false
    end
    local gm = (g_currentMission ~= nil and g_currentMission.missionInfo ~= nil)
        and g_currentMission.missionInfo.growthMode or nil
    if gm == nil then
        return nil, n, false
    end
    -- pcall NUR um den fremden Engine-Aufruf getIsPlantableInPeriod (kann bei
    -- Fruechten mit unvollstaendigen Wachstumsdaten werfen). Achim-Standard:
    -- Fehler nicht still schlucken -- einmal pro Frucht loggen (kein 12x-Spam).
    local allowed, anyFalse = {}, false
    local firstErr = nil
    for p = 1, n do
        local ok, res = pcall(fd.getIsPlantableInPeriod, fd, gm, p)
        if not ok and firstErr == nil then firstErr = res end
        local plantable = ok and (res == true)
        allowed[p] = plantable
        if not plantable then anyFalse = true end
    end
    if firstErr ~= nil then
        print(string.format("[Saatplan] PlantingCalendar: getIsPlantableInPeriod warf fuer Frucht '%s' -- Aussaatfenster evtl. unvollstaendig: %s",
            tostring(fd.name), tostring(firstErr)))
    end
    if not anyFalse then
        return nil, n, true   -- alle Perioden erlaubt -> ganzjaehrig
    end
    return allowed, n, true
end

-- Nach dem Vorbild von SeedSelector.formatPeriods:
-- Perioden auf 12 Monate mappen, zusammenhaengende Bereiche bilden,
-- Jahres-Wrap zusammenziehen (z.B. Winterfrucht "Sep-Feb").
local function formatPeriods(allowed, n)
    if allowed == nil then return nil end
    local m = getMonthNames()
    local numMonthNames = #m
    local perMonth = math.max(1, math.floor(n / numMonthNames))
    local numMonths = math.ceil(n / perMonth)

    local monthAllowed = {}
    for mo = 1, numMonths do
        local anyOk = false
        for sub = 1, perMonth do
            local p = (mo - 1) * perMonth + sub
            if p <= n and allowed[p] == true then anyOk = true; break end
        end
        monthAllowed[mo] = anyOk
    end

    local ranges, rs = {}, nil
    for mo = 1, numMonths do
        if monthAllowed[mo] then
            if rs == nil then rs = mo end
        elseif rs ~= nil then
            table.insert(ranges, { rs, mo - 1 })
            rs = nil
        end
    end
    if rs ~= nil then table.insert(ranges, { rs, numMonths }) end
    if #ranges == 0 then return nil end

    -- Jahres-Wrap: erster Bereich ab Monat 1 + letzter bis Monatsende -> zusammenziehen
    if #ranges > 1 and ranges[1][1] == 1 and ranges[#ranges][2] == numMonths then
        ranges[#ranges][2] = ranges[1][2]
        table.remove(ranges, 1)
    end

    local parts = {}
    for _, r in ipairs(ranges) do
        local from = m[r[1]] or tostring(r[1])
        local to   = m[r[2]] or tostring(r[2])
        table.insert(parts, (r[1] == r[2]) and from or (from .. "-" .. to))
    end
    return table.concat(parts, ", ")
end

--- Aussaatfenster-Text OHNE Praefix, z.B. "Mär-Mai" oder der ganzjaehrig-Text.
-- Gibt nil zurueck, wenn keine Daten ermittelbar sind (Aufrufer laesst die Zeile weg).
-- Kein umhuellender pcall (Achim-Standard: eigenen, deterministischen Code nicht
-- in pcall verstecken). Der einzige fremde Engine-Aufruf (getIsPlantableInPeriod)
-- ist in getPlantability gekapselt und geloggt; g_fruitTypeManager-Getter und
-- g_i18n:getText liefern hoechstens nil bzw. einen Platzhalter, werfen nicht.
function PlantingCalendar.getWindowText(fruitName, fillTypeIndex)
    local fd = resolveFruitDesc(fruitName, fillTypeIndex)
    local allowed, n, hasData = getPlantability(fd)
    if not hasData then return nil end
    if allowed == nil then
        return (g_i18n ~= nil) and g_i18n:getText("sp_cal_allYear") or nil
    end
    return formatPeriods(allowed, n)
end

--- Wie getWindowText, aber mit Praefix, z.B. "Aussaat: Mär-Mai" (fuers HUD).
function PlantingCalendar.getWindowLabeled(fruitName, fillTypeIndex)
    local w = PlantingCalendar.getWindowText(fruitName, fillTypeIndex)
    if w == nil then return nil end
    local prefix = (g_i18n ~= nil) and g_i18n:getText("sp_cal_prefix") or "Aussaat"
    return prefix .. ": " .. w
end
