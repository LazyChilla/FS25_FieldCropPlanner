-- InGameMenuSP.lua  v0.9.15.29
-- Saatplan-Assistent ESC-Tab
--
-- Tab 1 (Gesamtplan): Akkordeon-Liste aller aktiven Fruechte
-- Tab 2 (Filter):     Fruechte AN/AUS
-- Tab 3 (Felder):     Felder ausschliessen + Mindestgroesse-Filter

InGameMenuSP = {}
InGameMenuSP._mt = Class(InGameMenuSP, TabbedMenuFrameElement)
InGameMenuSP.ACTIVE_TAB = 1

---------------------------------------------------------------------------
-- Deutsche Fruchtnamen
---------------------------------------------------------------------------
local FRUIT_DE = {
    WHEAT="Weizen",BARLEY="Gerste",CANOLA="Raps",MAIZE="Mais",
    SUNFLOWER="Sonnenblume",SOYBEAN="Soja",POTATO="Kartoffel",
    SUGARBEET="Zuckerruebe",SUGARCANE="Zuckerrohr",COTTON="Baumwolle",
    RICE="Reis",RICELONGGRAIN="Langkornreis",RYE="Roggen",
    TRITICALE="Triticale",SPELT="Dinkel",SORGHUM="Sorghum",
    OATS="Hafer",POPPY="Mohn",HEMP="Hanf",TOBACCO="Tabak",
    CARROT="Karotte",ONION="Zwiebel",GARLIC="Knoblauch",
    PARSNIP="Pastinake",CABBAGE="Kohl",SPINACH="Spinach",
    LETTUCE="Salat",STRAWBERRY="Erdbeere",TOMATO="Tomate",
    PEPPER="Paprika",CUCUMBER="Gurke",PUMPKIN="Kuerbis",
    FLAX="Flachs",LINSEED="Lein",MUSTARD="Senf",
    BUCKWHEAT="Buchweizen",MILLET="Hirse",PEAS="Erbsen",
    BEANS="Bohnen",LENTILS="Linsen",CHICKPEAS="Kichererbsen",
    GRAPE="Weintraube",OLIVE="Olive",LAVENDER="Lavendel",
    HOPS="Hopfen",SUMMERBARLEY="Sommergerste",SUMMERWHEAT="Sommerweizen",
    WINTERBARLEY="Wintergerste",WINTERWHEAT="Winterweizen",
}

local function displayName(n, fillTypeIndex)
    -- Primaer: Giants-lokalisierter Name (Spielsprache, z.B. Kleegras, Luzerne)
    if fillTypeIndex ~= nil and g_fillTypeManager ~= nil then
        local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if ft ~= nil and ft.title ~= nil and ft.title ~= "" and ft.title ~= n then
            return ft.title .. " (" .. n .. ")"
        end
    end
    -- Fallback 1: deutsche Hardcode-Tabelle
    local de = FRUIT_DE[n]
    if de then return de .. " (" .. n .. ")" end
    -- Fallback 2: interner Name
    return n
end

---------------------------------------------------------------------------
-- Liter-Format: deutsch mit Punkten als Tausendertrenner
---------------------------------------------------------------------------
-- BUGFIX (11.07., Praxis-Fund): Die alte Implementierung platzierte den
-- Tausender-Punkt bei bestimmten Ziffernlaengen (v.a. 7-8-stellig, z.B.
-- 31363200) an der falschen Stelle ("31363.200" statt "31.363.200") --
-- eine fehlerhafte Modulo-Bedingung, kein Zufallsfehler. Neuer, robusterer
-- Ansatz: String umdrehen, in 3er-Gruppen von rechts mit Punkt trennen,
-- wieder umdrehen. Funktioniert fuer jede Ziffernlaenge ohne Sonderfaelle.
local function fmtL(n)
    if n == nil then return "?" end
    local neg = n < 0
    local s = tostring(math.floor(math.abs(n) + 0.5))
    local grouped = s:reverse():gsub("(%d%d%d)", "%1."):reverse()
    grouped = grouped:gsub("^%.", "") -- fuehrender Punkt weg, falls Laenge durch 3 teilbar
    if neg then grouped = "-" .. grouped end
    return grouped .. " L"
end

local function pctStr(p) return tostring(math.floor(p + 0.5)) .. "%" end

-- Feld-ID robust ermitteln (wie im SeedPlanner) fuer die Freigabe-Funktion
local function spFieldId(fe)
    if fe == nil then return nil end
    if fe.field ~= nil and fe.field.farmland ~= nil then
        local f = fe.field.farmland.field
        if f ~= nil and f.fieldId ~= nil then return f.fieldId end
    end
    if fe.label ~= nil then return tonumber(fe.label:match("%d+")) end
    return nil
end

-- Saatgut-Berechnungen: DemandScanner.calcSeedLiter / DemandScanner.getRealSeedLHa
-- (nach DemandScanner.lua verschoben 14.07., damit SeedPlanner + g_farmCore-Export
-- Zugriff haben ohne Tab-Oeffnen -- archi.md-Anforderung)
local function calcSeedLiter(fillTypeIndex, areaHa)
    return DemandScanner.calcSeedLiter(fillTypeIndex, areaHa)
end
local function getRealSeedLHa(fillTypeIndex)
    return DemandScanner.getRealSeedLHa(fillTypeIndex)
end

---------------------------------------------------------------------------
-- Konstruktor
---------------------------------------------------------------------------
function InGameMenuSP.new(i18n)
    local self = InGameMenuSP:superClass().new(nil, InGameMenuSP._mt)
    self.name = "ingameMenuSP"
    self.i18n = i18n

    -- Daten
    self.mainData   = {}   -- gemischte Frucht/Feld-Zeilen fuer Tab 1
    self.filterData = {}   -- Fruchtliste fuer Tab 2
    self.fieldData  = {}   -- Feldliste fuer Tab 3
    self.planResult   = nil
    self.mapHotspots  = {}   -- aktive Karten-Marker, werden in onFrameClose geloescht
    self.hotspotsHidden = false   -- Y-Toggle im Karten-Menue (nur zur Laufzeit)

    -- Sortierung Tab 1
    self.s1Col = "pct"
    self.s1Asc = false
    -- Saatgut-Gesamtbedarf pro Frucht (wird bei rebuildMainData berechnet)
    self.seedTotals = {}

    -- Sortierung Tab 2
    self.s2Col = "name"
    self.s2Asc = true

    -- Expansionszustand (nach Fruchtname)
    self.expanded = {}

    -- Feldausschluss
    self.excludedFieldIds = {}   -- Set: fieldId -> true
    self.releasedFields   = {}   -- fieldId -> Ursprungsfrucht (Freigabe, NUR Laufzeit)
    self.forcedFillTypeIndex = nil  -- FillType-Index der auf 100% erzwungenen Frucht, nil = keine
    self.schnittMultiMap = {}   -- fruitName -> Schnittanzahl (Mehrschnitt-Fruechte)
    self.minFieldSize     = 0.0  -- Mindestgroesse in ha (0 = kein Filter)
    self.maxFieldNumber   = 0    -- Felder ab dieser Nummer ignorieren (0 = aus, lokal/Host-only)

    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }

    -- Tasten fuer Tab 2 (Fruechte) und Tab 4 (Felder)
    self.acceptButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text        = g_i18n:getText("ui_sp_btn_toggle"),
        callback    = function() self:onButtonAccept() end,
    }
    self.releaseButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text        = g_i18n:getText("ui_sp_btn_release"),
        callback    = function() self:onButtonAccept() end,
    }
    self.pageNextButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text        = g_i18n:getText("ui_sp_btn_plus"),
        callback    = function() self:onButtonPageNext() end,
    }
    self.pagePrevButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text        = g_i18n:getText("ui_sp_btn_minus"),
        callback    = function() self:onButtonPagePrev() end,
    }

    self.selectedFilterIndex = 0
    self.selectedFieldIndex  = 0
    self.selectedMainIndex   = 0
    return self
end

function InGameMenuSP:onGuiSetupFinished()
    InGameMenuSP:superClass().onGuiSetupFinished(self)
    self.spMainList:setDataSource(self)
    self.spMainList:setDelegate(self)
    self.spFilterList:setDataSource(self)
    self.spFilterList:setDelegate(self)
    self.spFieldList:setDataSource(self)
    self.spFieldList:setDelegate(self)
    self.spFieldGrid:setDataSource(self)
    self.spFieldGrid:setDelegate(self)
    self:setMenuButtonInfo({ self.backButtonInfo })
end

--- Button-Leiste je nach aktivem Tab aktualisieren
function InGameMenuSP:updateButtonBar()
    local n = InGameMenuSP.ACTIVE_TAB
    if n == 2 then
        -- Fruechte-Tab: Enter=Toggle, Q=Schnitt-, E=Schnitt+
        self:setMenuButtonInfo({
            self.backButtonInfo,
            self.acceptButtonInfo,
            self.pagePrevButtonInfo,
            self.pageNextButtonInfo,
        })
    elseif n == 4 then
        -- Felderausschluss-Tab: Enter=Toggle
        self:setMenuButtonInfo({
            self.backButtonInfo,
            self.acceptButtonInfo,
        })
    elseif n == 1 then
        -- Gesamtplan: Enter = Ueberschussfeld freigeben
        self:setMenuButtonInfo({
            self.backButtonInfo,
            self.releaseButtonInfo,
        })
    else
        -- Tab 3: nur Zurueck
        self:setMenuButtonInfo({ self.backButtonInfo })
    end
    self:setMenuButtonInfoDirty()
end

--- Enter-Taste: Toggle fuer selektierte Zeile
function InGameMenuSP:onButtonAccept()
    local n = InGameMenuSP.ACTIVE_TAB
    if n == 2 then
        local f = self.filterData[self.selectedFilterIndex]
        if f ~= nil then
            f.active = not f.active
            self.spFilterList:reloadData()
        end
    elseif n == 4 then
        local fe = self.fieldData[self.selectedFieldIndex]
        if fe ~= nil and fe.fieldId ~= nil and not fe.belowMin and not fe.cutOff then
            fe.excluded = not fe.excluded
            if fe.excluded then
                self.excludedFieldIds[fe.fieldId] = true
            else
                self.excludedFieldIds[fe.fieldId] = nil
            end
            self.spFieldList:reloadData()
        end
    elseif n == 1 then
        -- Gesamtplan: ausgewaehltes Ueberschussfeld freigeben / zuruecknehmen
        local row = self.mainData[self.selectedMainIndex or 0]
        if row ~= nil and row.rowType == "field" and row.releasableFieldId ~= nil then
            local fid = row.releasableFieldId
            if self.releasedFields[fid] ~= nil then
                self.releasedFields[fid] = nil
            else
                self.releasedFields[fid] = row.originFruit
            end
            self:recalculate()
        end
    end
end

--- E-Taste: Schnitt-Multiplikator +
function InGameMenuSP:onButtonPageNext()
    if InGameMenuSP.ACTIVE_TAB ~= 2 then return end
    local f = self.filterData[self.selectedFilterIndex]
    if f == nil then return end
    f.schnittMulti = math.min(10, (f.schnittMulti or 1) + 1)
    self.spFilterList:reloadData()
    self:updateMultiLabel()
end

--- Q-Taste: Schnitt-Multiplikator -
function InGameMenuSP:onButtonPagePrev()
    if InGameMenuSP.ACTIVE_TAB ~= 2 then return end
    local f = self.filterData[self.selectedFilterIndex]
    if f == nil then return end
    f.schnittMulti = math.max(1, (f.schnittMulti or 1) - 1)
    self.spFilterList:reloadData()
    self:updateMultiLabel()
end

function InGameMenuSP:onFrameOpen()
    InGameMenuSP:superClass().onFrameOpen(self)

    -- Versionsnummer + Titel automatisch. Modname DYNAMISCH (SaatplanAssistent.modName
    -- aus main.lua) -- ueberlebt die Umbenennung; frueher hart "FS25_Saatplan",
    -- dadurch fand getModByName den umbenannten Mod nicht -> Titel zeigte "v?".
    -- Titel ueber l10n (ui_sp_title), damit er lokalisiert und markenkonform ist.
    local version = "?"
    if g_modManager ~= nil then
        local modName = (SaatplanAssistent ~= nil and SaatplanAssistent.modName) or "FS25_FieldCropPlanner"
        local mod = g_modManager:getModByName(modName)
        if mod ~= nil and mod.version ~= nil then version = mod.version end
    end
    if self.categoryHeaderText ~= nil then
        local title = (self.i18n ~= nil and self.i18n:getText("ui_sp_title")) or "CROP PLAN ASSISTANT"
        self.categoryHeaderText:setText(title .. "  v" .. version)
    end

    if g_server == nil then
        -- Wir sind Client im MP: Config vom Host anfragen
        if not self.configLoaded then
            -- "Lade..." anzeigen bis Response kommt
            if self.spStatFelder ~= nil then
                self.spStatFelder:setText("Lade Daten vom Host...")
                self.spStatFelder:setTextColor(1.0, 0.72, 0.0, 1)
            end
            SaatplanRequestEvent.sendToServer()
            print("[Saatplan] Client: Config-Anfrage gesendet, warte auf Response...")
            -- configLoaded bleibt false bis applyServerConfig aufgerufen wird
        end
    else
        -- Host oder Singleplayer: lokal laden
        if not self.configLoaded then
            self:loadConfig()
            self.configLoaded = true
            print("[Saatplan] Config erstmals geladen")
        else
        end
    end
    self:buildFieldData()
    self:recalculate()
    self:showTab(InGameMenuSP.ACTIVE_TAB)
end

function InGameMenuSP:onFrameClose()
    InGameMenuSP:superClass().onFrameClose(self)
    -- Zwischenspeichern beim Tab-Schliessen (verifiziert: onFrameClose wird von
    -- Giants aufgerufen wenn ESC-Tab geschlossen wird, analog FPM/BetterContracts)
    -- Verhindert Datenverlust wenn Tab vor dem naechsten Autosave nochmal
    -- geoeffnet wird (onFrameOpen wuerde sonst loadConfig aufrufen und RAM ueberschreiben)
    self:saveConfig()
    -- Karten-Marker bleiben persistent (analog GoToNextField/AutoDrive)
    -- werden nur in deleteMap() geloescht
end

---------------------------------------------------------------------------
-- Neuberechnung
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Karten-Markierungen (MapHotspot, verifiziert aus GoToNextField + FS25_FarmlandAuctions)
---------------------------------------------------------------------------

-- Minimale eigene Klasse damit getCategory() korrekt CATEGORY_FIELD zurueckgibt
-- (MapHotspot.new() direkt hat keine Setter dafuer -- Pattern aus GoToNextField.lua)
local SaatplanHotspot = {}
local SaatplanHotspot_mt = Class(SaatplanHotspot, MapHotspot)

function SaatplanHotspot.new(wx, wz, line1, line2, line3)
    local self = MapHotspot.new(SaatplanHotspot_mt)
    self.width  = 0.028        -- gleiche Breite wie GoToNextField
    self.height = 0.020        -- etwas hoeher wegen 2 Zeilen Text
    self.wx     = wx
    self.wz     = wz
    self.line1  = line1 or ""  -- z.B. "Gerste"
    self.line2  = line2 or ""  -- z.B. "442 L"
    self.line3  = line3 or ""  -- z.B. "Mär-Mai" (Aussaatfenster), optional
    self.r, self.g, self.b, self.a = 1.0, 0.72, 0.0, 1.0  -- gelb
    return self
end

function SaatplanHotspot:setColor(r, g, b, a)
    self.r, self.g, self.b, self.a = r, g, b, a or 1
end

function SaatplanHotspot:getCategory()      return MapHotspot.CATEGORY_FIELD end
function SaatplanHotspot:getWorldPosition() return self.wx, self.wz end
function SaatplanHotspot:getWorldRotation() return 0 end
function SaatplanHotspot:getIsPersistent()  return false end
function SaatplanHotspot:setScale(s)        end

function SaatplanHotspot:render(x, y, yRot, smallVersion)
    -- Zeilen einsammeln (line3 = Aussaatfenster ist optional)
    local lines = { self.line1, self.line2 }
    if self.line3 ~= nil and self.line3 ~= "" then
        lines[#lines + 1] = self.line3
    end
    local nLines   = #lines
    local lineH    = self.height          -- Hoehe pro Textzeile
    local h        = lineH * nLines
    local textSize = self.height * 0.56    -- wie bisher (h*0.28 bei 2 Zeilen)
    local pad      = 0.004                 -- Seitenabstand

    -- Dynamische Breite: breitester Text bestimmt Box-Breite
    -- (verifiziert aus Courseplay/CustomFieldHotspot.lua: setTextBold vor getTextWidth!)
    setTextBold(true)
    local w = 0
    for _, ln in ipairs(lines) do
        w = math.max(w, getTextWidth(textSize, ln))
    end
    setTextBold(false)
    w = w + pad * 2

    -- Unterhalb des Feldnummer-Ankerpunkts positionieren
    local ry  = y - h
    local brd = 0.0004
    -- Schwarzer Rahmen + gelbe Box
    drawFilledRect(x,       ry,       w,         h,         0, 0, 0, 0.85)
    drawFilledRect(x + brd, ry + brd, w - brd*2, h - brd*2, self.r, self.g, self.b, self.a)
    -- Text zentriert, Zeilen von oben nach unten gleichmaessig verteilt
    local cx = x + w * 0.5
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(0, 0, 0, 1)
    for i, ln in ipairs(lines) do
        local ly = ry + h - i * lineH + lineH * 0.28
        renderText(cx, ly, textSize, ln)
    end
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

---------------------------------------------------------------------------
-- Karten-Marker per Y ein-/ausblenden (MENU_EXTRA_1, registriert im nativen
-- Karten-Menue -- siehe Hook in main.lua). Zustand haelt zur Laufzeit an
-- self.hotspotsHidden, bleibt also ueber Karte-zu/auf und Neuaufbau bestehen
-- (bis Spiel-Neustart). updateMapHotspots respektiert self.hotspotsHidden.
---------------------------------------------------------------------------
function InGameMenuSP:updateMapToggleText()
    if self.spMapToggleEventId == nil or g_inputBinding == nil then return end
    local key = self.hotspotsHidden and "sp_map_labels_show" or "sp_map_labels_hide"
    g_inputBinding:setActionEventText(self.spMapToggleEventId, g_i18n:getText(key))
end

function InGameMenuSP:onToggleMapLabels()
    self.hotspotsHidden = not self.hotspotsHidden
    for _, hs in ipairs(self.mapHotspots or {}) do
        if hs.setVisible ~= nil then hs:setVisible(not self.hotspotsHidden) end
    end
    self:updateMapToggleText()
end

function InGameMenuSP:clearMapHotspots()
    for _, hs in ipairs(self.mapHotspots) do
        if g_currentMission ~= nil and g_currentMission.removeMapHotspot ~= nil then
            g_currentMission:removeMapHotspot(hs)
        end
        if hs.delete ~= nil then hs:delete() end
    end
    self.mapHotspots = {}
end

function InGameMenuSP:updateMapHotspots()
    self:clearMapHotspots()
    if g_currentMission == nil or self.planResult == nil then return end

    local farmId = g_currentMission:getFarmId()
    local allFields = FieldScanner.getAllOwnedFields(farmId)

    -- Set: Label -> fruitName fuer zugewiesene Felder
    local assignedInfo = {}
    for _, fs in ipairs(self.planResult.fruitState) do
        for _, af in ipairs(fs.assignedFields or {}) do
            local lbl = af.fieldEntry and af.fieldEntry.label or nil
            if lbl ~= nil then
                assignedInfo[lbl] = {
                    fruitName = fs.name,
                    fillTypeIdx = fs.fillTypeIndex,
                }
            end
        end
    end

    for _, fe in ipairs(allFields) do
        local info = assignedInfo[fe.label or ""]
        -- Nur vorgeschlagene (gelbe) Felder markieren
        -- Besaete Felder sind auf der Karte schon durch Feldfarbe erkennbar
        if info ~= nil and fe.field ~= nil then
            local ok, fx, fz = pcall(function()
                return fe.field:getIndicatorPosition()
            end)
            if not ok then
                print(string.format("[Saatplan] Karten-Marker: getIndicatorPosition fehlgeschlagen fuer Feld %s: %s",
                    tostring(fe.label), tostring(fx)))
            elseif fx ~= nil then
                -- Fruchtname (lokalisiert) + Saatgutmenge
                local fruitName = displayName(info.fruitName, info.fillTypeIdx)
                -- Nur ersten Teil vor "(" nehmen fuer Kurzname
                local shortName = fruitName:match("^([^%(]+)") or info.fruitName
                shortName = shortName:gsub("%s+$", "")  -- trailing spaces weg
                local seedL = calcSeedLiter(info.fillTypeIdx, fe.areaHa or 0)
                local seedStr = seedL > 0 and fmtL(seedL) or "—"
                local sowText = PlantingCalendar.getWindowText(info.fruitName, info.fillTypeIdx)
                local hs = SaatplanHotspot.new(fx, fz, shortName, seedStr, sowText)
                if hs.setVisible ~= nil then hs:setVisible(not self.hotspotsHidden) end
                g_currentMission:addMapHotspot(hs)
                table.insert(self.mapHotspots, hs)
            end
        end
    end
end

--- Baut das effektive Set freigegebener Feld-IDs (fieldId -> true) und heilt
-- dabei veraltete Eintraege (Feld traegt nicht mehr die Ursprungsfrucht =
-- umgesaet/leer). EINE Quelle fuer Menue (recalculate) UND Export
-- (getSavedPlanParams in main.lua), damit FarmAssistant/g_farmCore exakt
-- denselben Plan wie der Saatplan-Tab rechnen (Freigabe-Bruecke 26.07.).
function InGameMenuSP:buildReleasedFieldIds(farmId)
    local releasedFieldIds = {}
    if next(self.releasedFields) ~= nil then
        local currentCrop = {}
        for _, fe in ipairs(FieldScanner.getAllOwnedFields(farmId)) do
            local fid = spFieldId(fe)
            if fid ~= nil then currentCrop[fid] = (fe.isSown and fe.fruitName) or false end
        end
        for fid, originFruit in pairs(self.releasedFields) do
            if currentCrop[fid] == originFruit then
                releasedFieldIds[fid] = true
            else
                self.releasedFields[fid] = nil   -- Selbstheilung
            end
        end
    end
    return releasedFieldIds
end

function InGameMenuSP:recalculate()
    local farmId = g_currentMission:getFarmId()

    -- Frucht-Filter
    local excl = {}
    for _, f in ipairs(self.filterData) do
        if not f.active then excl[f.fillTypeIndex] = true end
    end

    -- Feld-Ausschluss: excludedFieldIds + Mindestgroesse
    local exclFields = {}
    for fieldId, _ in pairs(self.excludedFieldIds) do
        exclFields[fieldId] = true
    end

    -- Schnitt-Multiplikatoren als Map aufbauen
    local schnittMultiMap = {}
    for _, f in ipairs(self.filterData) do
        if (f.schnittMulti or 1) > 1 then
            schnittMultiMap[f.name] = f.schnittMulti
        end
    end
    self.schnittMultiMap = schnittMultiMap  -- auf self, damit rebuildMainData immer Zugriff hat

    -- Freigegebene Felder (Set + Selbstheilung) -- gemeinsame Quelle mit dem
    -- Export (getSavedPlanParams), damit FA und Menue denselben Plan rechnen.
    local releasedFieldIds = self:buildReleasedFieldIds(farmId)

    self.planResult = SeedPlanner.buildOverallPlan(farmId, excl, exclFields, self.minFieldSize, schnittMultiMap, self.allocStrategy, self.forcedFillTypeIndex, releasedFieldIds, self.maxFieldNumber)

    local demand = {}
    for _, fs in ipairs(self.planResult.fruitState) do
        demand[fs.name] = fs.demand
    end
    for _, f in ipairs(self.filterData) do
        f.demand = demand[f.name] or 0
    end

    self:rebuildMainData()
    self.spFilterList:reloadData()
    self:updateSortButtons()
    print(string.format("[Saatplan] Berechnung fertig: %d Fruechte, Autarkie=%.0f%%",
        #self.planResult.fruitState, (self.planResult.autarkieGrad or 0)*100))
    self:updateStatBar()
    self:updateMapHotspots()
end

---------------------------------------------------------------------------
-- mainData aufbauen: Fruchtzeilen + aufgeklappte Feldzeilen
---------------------------------------------------------------------------
function InGameMenuSP:rebuildMainData()
    local farmId = g_currentMission:getFarmId()

    -- Frucht-Basiszeilen
    local fruits = {}
    for _, fs in ipairs(self.planResult.fruitState) do
        -- "Quote" = aktuelle Deckung NUR aus gesaeten Feldern (Vorher), ungedeckelt.
        -- "Danach" (afterPct) = Deckung, wenn man den Saatvorschlaegen folgt.
        local coveredBase = fs.coveredBase or fs.covered
        local pct = fs.demand > 0
            and math.floor(coveredBase / fs.demand * 100 + 0.5) or 0
        -- Saatgutbedarf: Summe aller zugewiesenen + gesaeten Felder
        local totalAreaHa = 0
        for _, af in ipairs(fs.assignedFields or {}) do
            totalAreaHa = totalAreaHa + (af.fieldEntry and af.fieldEntry.areaHa or 0)
        end
        local seedTotal = calcSeedLiter(fs.fillTypeIndex, totalAreaHa)
        table.insert(fruits, {
            rowType     = "fruit",
            name        = fs.name,
            dispName    = displayName(fs.name, fs.fillTypeIndex),
            pct         = pct,
            covered     = math.min(fs.covered, fs.demand),
            demand      = fs.demand,
            fillTypeIdx = fs.fillTypeIndex,
            fillTypeIndex = fs.fillTypeIndex,
            seedTotal   = seedTotal,
            totalAreaHa = totalAreaHa,
            hasAssigned = #(fs.assignedFields or {}) > 0,
            afterPct    = fs.demand > 0 and math.floor(fs.covered / fs.demand * 100 + 0.5) or 0,
            surplus     = math.max(0, fs.covered - fs.demand),
        })
    end

    -- Sortierung Tab 1
    table.sort(fruits, function(a, b)
        local va, vb
        if self.s1Col == "name" then va, vb = a.dispName, b.dispName
        elseif self.s1Col == "pct" then va, vb = a.pct, b.pct
        elseif self.s1Col == "seed" then va, vb = a.seedTotal, b.seedTotal
        else va, vb = a.demand, b.demand
        end
        if va == vb then return false end
        if type(va) == "string" then
            if self.s1Asc then return va < vb else return va > vb end
        else
            if self.s1Asc then return va < vb else return va > vb end
        end
    end)

    -- mainData aufbauen
    self.mainData = {}
    for _, fr in ipairs(fruits) do
        table.insert(self.mainData, fr)

        if self.expanded[fr.name] then
            local assignedFields = {}
            local assignedLabels = {}
            for _, fs in ipairs(self.planResult.fruitState) do
                if fs.name == fr.name then
                    for _, af in ipairs(fs.assignedFields or {}) do
                        local lbl = af.fieldEntry and (af.fieldEntry.label or "?") or "?"
                        table.insert(assignedFields, {
                            rowType    = "field",
                            fieldNr    = lbl,
                            areaHa     = af.fieldEntry and af.fieldEntry.areaHa or 0,
                            yield      = af.yield,
                            isSown     = false,
                            isAssigned = true,
                            fillTypeIdx= fr.fillTypeIdx,
                        })
                        assignedLabels[lbl] = true
                    end
                    break
                end
            end

            local schnittMulti = (self.schnittMultiMap ~= nil and self.schnittMultiMap[fr.name]) or 1

            -- Gesaete Felder mit genau dieser Frucht (gruen)
            local allFields = FieldScanner.getAllOwnedFields(farmId)
            local gesaet = {}
            for _, fe in ipairs(allFields) do
                if fe.isSown and fe.fruitName == fr.name then
                    local y = FieldScanner.estimateYield(fe, fr.fillTypeIdx, "optimistic") * schnittMulti
                    table.insert(gesaet, {
                        rowType    = "field",
                        fieldNr    = fe.label or "?",
                        fieldId    = spFieldId(fe),
                        areaHa     = fe.areaHa,
                        yield      = y,
                        isSown     = true,
                        fruitName  = fe.fruitName,
                        fillTypeIdx= fr.fillTypeIdx,
                    })
                end
            end
            table.sort(gesaet, function(a, b) return a.areaHa > b.areaHa end)

            local cumul = 0
            local demand = fr.demand
            local isOver = (fr.afterPct ~= nil and fr.afterPct > 100)   -- ueberversorgt?

            local hasFields = #gesaet > 0 or #assignedFields > 0
            if hasFields then
                table.insert(self.mainData, { rowType = "fieldHeader" })
            end

            local anyReleasable = false
            for _, fe in ipairs(gesaet) do
                local isReleased = fe.fieldId ~= nil and self.releasedFields[fe.fieldId] ~= nil
                if isReleased then
                    -- freigegeben: zaehlt NICHT zur Deckung (blau)
                    fe.released          = true
                    fe.releasableFieldId = fe.fieldId
                    fe.originFruit       = fr.name
                    fe.cumul    = cumul
                    fe.afterPct = demand > 0 and math.floor(cumul / demand * 100 + 0.5) or 0
                    fe.surplus  = 0
                    table.insert(self.mainData, fe)
                else
                    -- Bei ueberversorgter Frucht JEDES Feld freigebbar machen
                    -- (LazyChilla 27.07.): frueher nur die Felder ueber der
                    -- 100%-Linie (cumul >= demand) -- dadurch waren die ersten,
                    -- die 100% erst aufbauenden Felder gesperrt und ein gezielt
                    -- gewuenschtes Feld nicht erreichbar. Gate bleibt: nur
                    -- Fruechte MIT Ueberschuss bieten Freigabe ueberhaupt an.
                    if isOver and demand > 0 then
                        fe.releasable        = true
                        fe.releasableFieldId = fe.fieldId
                        fe.originFruit       = fr.name
                        anyReleasable = true
                    end
                    cumul = cumul + fe.yield
                    fe.cumul    = cumul
                    fe.afterPct = demand > 0 and math.floor(cumul / demand * 100 + 0.5) or 0
                    fe.surplus  = cumul > demand and (cumul - demand) or 0
                    table.insert(self.mainData, fe)
                end
            end
            if anyReleasable then
                table.insert(self.mainData, { rowType = "releaseHint" })
            end

            for _, fe in ipairs(assignedFields) do
                cumul = cumul + fe.yield
                local pctReal = demand > 0 and math.floor(cumul / demand * 100 + 0.5) or 0
                local ueber   = cumul > demand and (cumul - demand) or 0
                fe.cumul    = cumul
                fe.afterPct = pctReal
                fe.surplus  = ueber
                table.insert(self.mainData, fe)
            end

            -- Keine weiteren freien Felder mehr anzeigen:
            -- Gruen = bereits gesaet (nichts tun)
            -- Gelb >> = vom Algorithmus zugewiesen (ansaeen)
            -- Alles andere ist nicht relevant fuer diese Frucht

            -- Fabrik-Aufschluesselung (Klapp-Detail, 09.07. nach dem Gerste/
            -- Stroh-Fund): welche Fabrik verbraucht wie viel dieser Frucht,
            -- PARALLEL oder GETEILT gerechnet -- spiegelt gsSaatplanCheck
            -- direkt im GUI statt nur in der Konsole. Sprechende Null: kein
            -- Verbraucher = kein Abschnitt, kein Rauschen.
            local factories = DemandScanner.getFactoryDemandBreakdown(farmId, fr.fillTypeIdx)
            if #factories > 0 then
                table.insert(self.mainData, { rowType = "factoryHeader" })
                for _, fac in ipairs(factories) do
                    table.insert(self.mainData, {
                        rowType = "factory",
                        name    = fac.name,
                        mode    = fac.mode,
                        amount  = fac.amount,
                    })
                end
            end

            -- force100-Button: nur anzeigen wenn Frucht noch unter 100% liegt
            -- (oder bereits erzwungen ist -- dann als Toggle zum Aufheben).
            -- Keine Zeile bei bereits vollstaendig gedeckter Frucht (wuerde
            -- verwirren, da kein Handlungsbedarf).
            local pctNow = fr.demand > 0 and (fr.covered / fr.demand) or 1
            local isForced = self.forcedFillTypeIndex == fr.fillTypeIdx
            if pctNow < 1.0 or isForced then
                table.insert(self.mainData, {
                    rowType      = "force100",
                    fillTypeIdx  = fr.fillTypeIdx,
                    dispName     = fr.dispName,
                    isForced     = isForced,
                })
            end
        end
    end

    self.spMainList:reloadData()
end

---------------------------------------------------------------------------
-- Tab 3: Feldliste aufbauen
---------------------------------------------------------------------------
function InGameMenuSP:buildFieldData()
    local farmId = g_currentMission:getFarmId()
    local allFields = FieldScanner.getAllOwnedFields(farmId)

    -- Nach Feldnummer sortieren (numerisch wenn moeglich)
    table.sort(allFields, function(a, b)
        local na = tonumber((a.label or ""):match("%d+")) or 0
        local nb = tonumber((b.label or ""):match("%d+")) or 0
        if na == nb then return false end
        return na < nb
    end)

    -- Vom Algorithmus vorgeschlagene Felder als Set aufbauen
    local assignedLabels = {}
    if self.planResult ~= nil then
        for _, fs in ipairs(self.planResult.fruitState) do
            for _, af in ipairs(fs.assignedFields or {}) do
                local lbl = af.fieldEntry and af.fieldEntry.label or nil
                if lbl ~= nil then assignedLabels[lbl] = true end
            end
        end
    end

    self.fieldData = {}
    for _, fe in ipairs(allFields) do
        -- fieldId fuer Persistenz ermitteln
        local fieldId = nil
        if fe.field ~= nil and fe.field.farmland ~= nil then
            local f = fe.field.farmland.field
            if f ~= nil then fieldId = f.fieldId end
        end
        -- Fallback: Nummer aus Label lesen (z.B. "Feld 4" -> 4)
        if fieldId == nil and fe.label ~= nil then
            fieldId = tonumber(fe.label:match("%d+"))
        end

        local fruitDisp = fe.fruitName and displayName(fe.fruitName, nil) or "—"
        local excluded = fieldId ~= nil and self.excludedFieldIds[fieldId] == true
        local belowMin = self.minFieldSize > 0 and fe.areaHa < self.minFieldSize
        local cutOff   = (self.maxFieldNumber or 0) > 0 and fieldId ~= nil and fieldId >= self.maxFieldNumber

        local isAssigned = not fe.isSown and assignedLabels[fe.label or ""] == true
        table.insert(self.fieldData, {
            label      = fe.label or "?",
            areaHa     = fe.areaHa,
            fruitDisp  = fruitDisp,
            fieldId    = fieldId,
            excluded   = excluded,
            belowMin   = belowMin,
            cutOff     = cutOff,
            isSown     = fe.isSown,
            isAssigned = isAssigned,
        })
    end

    if self.spFieldList ~= nil then
        self.spFieldList:reloadData()
    end
    self:updateMinSizeText()
end

---------------------------------------------------------------------------
-- Tab-Umschalter
---------------------------------------------------------------------------
function InGameMenuSP:showTab(n)
    InGameMenuSP.ACTIVE_TAB = n
    if self.spTab1 ~= nil then self.spTab1:setVisible(n == 1) end
    if self.spTab2 ~= nil then self.spTab2:setVisible(n == 2) end
    if self.spTab3 ~= nil then self.spTab3:setVisible(n == 3) end
    if self.spTab4 ~= nil then self.spTab4:setVisible(n == 4) end
    if self.spTab5 ~= nil then self.spTab5:setVisible(n == 5) end
    -- StatBar nur in Tab 1 sichtbar
    if self.spStatBar ~= nil then self.spStatBar:setVisible(n == 1) end

    local function setActive(btn, active)
        if btn ~= nil then
            btn:setTextColor(active and 1 or 0.5, active and 1 or 0.5, active and 1 or 0.5, 1)
        end
    end
    setActive(self.spBtnTab1, n == 1)
    setActive(self.spBtnTab2, n == 2)
    setActive(self.spBtnTab3, n == 3)
    setActive(self.spBtnTab4, n == 4)
    setActive(self.spBtnTab5, n == 5)

    if n == 1 then
        FocusManager:setFocus(self.spMainList)
    elseif n == 2 then
        FocusManager:setFocus(self.spFilterList)
    elseif n == 3 then
        self:refreshFieldGrid()
    elseif n == 4 then
        FocusManager:setFocus(self.spFieldList)
    elseif n == 5 then
        self:refreshSettingsTab()
        -- KEIN erzwungener Fokus mehr (v73): der hat die Zeile dauerhaft
        -- weiss hervorgehoben ("kaputt"-Optik). Die Zeile rendert jetzt im
        -- Normalzustand und ist per Maus/Hover bedienbar (ScrollingLayout).
    end
    self:updateButtonBar()
end

function InGameMenuSP:onClickTab1()
    if InGameMenuSP.ACTIVE_TAB ~= 1 then
        self:recalculate()
    end
    self:showTab(1)
end
function InGameMenuSP:onClickTab2() self:showTab(2) end
function InGameMenuSP:onClickTab3() self:showTab(3) end
function InGameMenuSP:onClickTab4()
    self:buildFieldData()
    self:showTab(4)
end
function InGameMenuSP:onClickTab5() self:showTab(5) end

---------------------------------------------------------------------------
-- Tab 5: Einstellungen (10.07., natives MultiTextOption statt eigenem
-- [-] Wert [+] -- siehe BetterContracts/RealisticAnimalLosses als Vorbild,
-- aber bewusst NUR innerhalb unseres eigenen Tabs, kein Eingriff in die
-- native Giants-Einstellungsseite, siehe Entscheidung LazyChilla 10.07.)
---------------------------------------------------------------------------

-- Reihenfolge = Optionsindex in der MultiTextOption (1-basiert)
InGameMenuSP.ALLOC_STRATEGIES = { "absolut", "prozent", "reihum" }

function InGameMenuSP:allocStrategyIndex()
    for i, key in ipairs(InGameMenuSP.ALLOC_STRATEGIES) do
        if key == (self.allocStrategy or "absolut") then return i end
    end
    return 1
end

-- FA-Stil (v76): schlichte Stepper-Buttons statt nativem MultiTextOption
-- (dessen Pfeile klickten im eigenen Tab nie zuverlaessig). Hier nur den
-- Wert-Text aktualisieren.
function InGameMenuSP:refreshSettingsTab()
    if self.spAllocValue == nil then return end
    local key = InGameMenuSP.ALLOC_STRATEGIES[self:allocStrategyIndex()]
    self.spAllocValue:setText(self.i18n:getText("ui_sp_settings_allocStrategy_" .. key))
    -- Dynamische Erklaerzeile (v80): erklaert die aktuell gewaehlte Strategie,
    -- damit auch "Reihum" ohne Extra-Wissen verstaendlich ist.
    if self.spAllocTip ~= nil then
        self.spAllocTip:setText(self.i18n:getText("ui_sp_settings_allocStrategy_desc_" .. key))
    end
    self:refreshFieldCut()
end

-- Stepper: Strategie durchschalten (dir = +1/-1), speichern, neu rechnen.
function InGameMenuSP:cycleAllocStrategy(dir)
    local n = #InGameMenuSP.ALLOC_STRATEGIES
    local idx = (self:allocStrategyIndex() - 1 + dir) % n + 1
    self.allocStrategy = InGameMenuSP.ALLOC_STRATEGIES[idx]
    self:refreshSettingsTab()
    self:saveConfig()
    self:recalculate()
end
function InGameMenuSP:onAllocPrev() self:cycleAllocStrategy(-1) end
function InGameMenuSP:onAllocNext() self:cycleAllocStrategy(1) end

-- Feld-Cutoff (v78): Felder ab Nummer N aus Plan/Bedarf ausschliessen.
-- Gleicher Weg wie minFieldSize (Feld-Schwellenwert), nur lokal/Host-only
-- (kein MP-Event, wie allocStrategy). N=0 = aus.
function InGameMenuSP:refreshFieldCut()
    if self.spFieldCutValue == nil then return end
    local n = self.maxFieldNumber or 0
    if n <= 0 then
        self.spFieldCutValue:setText(self.i18n:getText("ui_sp_settings_fieldCut_off"))
    else
        self.spFieldCutValue:setText(string.format(self.i18n:getText("ui_sp_settings_fieldCut_val"), n))
    end
end
function InGameMenuSP:cycleFieldCut(dir)
    self.maxFieldNumber = math.max(0, (self.maxFieldNumber or 0) + dir)
    self:refreshFieldCut()
    self:saveConfig()
    self:buildFieldData()
    self:recalculate()
end
function InGameMenuSP:onFieldCutPrev() self:cycleFieldCut(-1) end
function InGameMenuSP:onFieldCutNext() self:cycleFieldCut(1) end

---------------------------------------------------------------------------
-- Mindestgroesse +/-
---------------------------------------------------------------------------
function InGameMenuSP:onClickMinSizeInc()
    self.minFieldSize = math.floor((self.minFieldSize + 0.5) * 10 + 0.5) / 10
    self:buildFieldData()
end

function InGameMenuSP:onClickMinSizeDec()
    self.minFieldSize = math.max(0.0, math.floor((self.minFieldSize - 0.5) * 10 + 0.5) / 10)
    self:buildFieldData()
end

function InGameMenuSP:updateMinSizeText()
    local txt = self.minFieldSize <= 0 and "aus" or string.format("%.1f ha", self.minFieldSize)
    if self.spMinSizeText  ~= nil then self.spMinSizeText:setText(txt) end
    if self.spMinSizeText2 ~= nil then self.spMinSizeText2:setText(txt) end
end

---------------------------------------------------------------------------
-- Sortier-Buttons Tab 1
---------------------------------------------------------------------------
function InGameMenuSP:onClickSort1Name()
    if self.s1Col == "name" then self.s1Asc = not self.s1Asc
    else self.s1Col = "name"; self.s1Asc = true end
    self.expanded = {}
    self:rebuildMainData(); self:updateSortButtons()
end
function InGameMenuSP:onClickSort1Pct()
    if self.s1Col == "pct" then self.s1Asc = not self.s1Asc
    else self.s1Col = "pct"; self.s1Asc = false end
    self.expanded = {}
    self:rebuildMainData(); self:updateSortButtons()
end
function InGameMenuSP:onClickSort1Demand()
    if self.s1Col == "demand" then self.s1Asc = not self.s1Asc
    else self.s1Col = "demand"; self.s1Asc = false end
    self.expanded = {}
    self:rebuildMainData(); self:updateSortButtons()
end
function InGameMenuSP:onClickSort1Seed()
    if self.s1Col == "seed" then self.s1Asc = not self.s1Asc
    else self.s1Col = "seed"; self.s1Asc = false end
    self.expanded = {}
    self:rebuildMainData(); self:updateSortButtons()
end

---------------------------------------------------------------------------
-- Sortier-Buttons Tab 2
---------------------------------------------------------------------------
function InGameMenuSP:onClickSort2Name()
    if self.s2Col == "name" then self.s2Asc = not self.s2Asc
    else self.s2Col = "name"; self.s2Asc = true end
    self:sortAndReloadFilter(); self:updateSortButtons()
end
function InGameMenuSP:onClickSort2Demand()
    if self.s2Col == "demand" then self.s2Asc = not self.s2Asc
    else self.s2Col = "demand"; self.s2Asc = false end
    self:sortAndReloadFilter(); self:updateSortButtons()
end
function InGameMenuSP:onClickSort2Active()
    if self.s2Col == "active" then self.s2Asc = not self.s2Asc
    else self.s2Col = "active"; self.s2Asc = false end
    self:sortAndReloadFilter(); self:updateSortButtons()
end

function InGameMenuSP:sortAndReloadFilter()
    table.sort(self.filterData, function(a, b)
        local va, vb
        if self.s2Col == "name" then va, vb = a.dispName, b.dispName
        elseif self.s2Col == "demand" then va, vb = a.demand, b.demand
        else va, vb = a.active and 1 or 0, b.active and 1 or 0
        end
        if va == vb then return false end
        if type(va) == "string" then
            if self.s2Asc then return va < vb else return va > vb end
        else
            if self.s2Asc then return va < vb else return va > vb end
        end
    end)
    self.spFilterList:reloadData()
end

function InGameMenuSP:updateSortButtons()
    local function upd(btn, col, state, label)
        if btn == nil then return end
        local arrow = state.col == col and (state.asc and " ^" or " v") or ""
        btn:setText(string.upper(label .. arrow))
    end
    upd(self.spSort1Name,   "name",   {col=self.s1Col,asc=self.s1Asc}, "Frucht")
    upd(self.spSort1Pct,    "pct",    {col=self.s1Col,asc=self.s1Asc}, "Quote")
    upd(self.spSort1Demand, "demand", {col=self.s1Col,asc=self.s1Asc}, "Jahresbedarf")
    upd(self.spSort1Seed,   "seed",   {col=self.s1Col,asc=self.s1Asc}, "Saatgut")
    upd(self.spSort2Name,   "name",   {col=self.s2Col,asc=self.s2Asc}, "Frucht")
    upd(self.spSort2Demand, "demand", {col=self.s2Col,asc=self.s2Asc}, "Jahresbedarf")
    upd(self.spSort2Active, "active", {col=self.s2Col,asc=self.s2Asc}, "Status")
end

---------------------------------------------------------------------------
-- Klick-Handler
---------------------------------------------------------------------------
function InGameMenuSP:handleAccept(index)
    if InGameMenuSP.ACTIVE_TAB == 1 then
        local row = self.mainData[index]
        if row and row.rowType == "fruit" then
            self.expanded[row.name] = not self.expanded[row.name]
            self:rebuildMainData()
        elseif row and row.rowType == "force100" then
            -- Toggle: wenn diese Frucht bereits erzwungen ist, Priorisierung
            -- aufheben; sonst auf 100% priorisieren.
            if self.forcedFillTypeIndex == row.fillTypeIdx then
                self.forcedFillTypeIndex = nil
            else
                self.forcedFillTypeIndex = row.fillTypeIdx
            end
            self:recalculate()
        end
    end
end

function InGameMenuSP:onClickMain(list, section, index, element, wasAlreadySelected)
    InGameMenuSP.ACTIVE_TAB = 1
    self.selectedMainIndex = index
    self:handleAccept(index)
end

function InGameMenuSP:onClickFilter(list, section, index, element, wasAlreadySelected)
    InGameMenuSP.ACTIVE_TAB = 2
    self.selectedFilterIndex = index
    self:updateMultiLabel()
    -- Kein Toggle hier -- Enter-Taste (onButtonAccept) toggled
end

--- Stat-Bar in Tab 1: Autarkie + Feldzaehler
function InGameMenuSP:updateStatBar()
    if self.spStatAutarkie == nil then return end
    local pct = math.floor((self.planResult and self.planResult.autarkieGrad or 0) * 100 + 0.5)
    self.spStatAutarkie:setText(string.format("Autarkie: %d%%", pct))
    if pct >= 80 then self.spStatAutarkie:setTextColor(0.53, 0.88, 0.0, 1)
    elseif pct >= 50 then self.spStatAutarkie:setTextColor(1.0, 0.72, 0.0, 1)
    else self.spStatAutarkie:setTextColor(0.95, 0.45, 0.0, 1)
    end

    if self.spStatFelder == nil then return end
    local farmId = g_currentMission:getFarmId()
    local allFields = FieldScanner.getAllOwnedFields(farmId)
    local nSown, nAssigned, nFree, nExcl = 0, 0, 0, 0

    -- assignedLabels aus planResult
    local assignedLabels = {}
    if self.planResult ~= nil then
        for _, fs in ipairs(self.planResult.fruitState) do
            for _, af in ipairs(fs.assignedFields or {}) do
                local lbl = af.fieldEntry and af.fieldEntry.label or nil
                if lbl ~= nil then assignedLabels[lbl] = true end
            end
        end
    end

    for _, fe in ipairs(allFields) do
        local fieldId = nil
        if fe.field ~= nil and fe.field.farmland ~= nil then
            local f = fe.field.farmland.field
            if f ~= nil then fieldId = f.fieldId end
        end
        if fieldId == nil and fe.label ~= nil then
            fieldId = tonumber(fe.label:match("%d+"))
        end
        local isExcluded = fieldId ~= nil and self.excludedFieldIds[fieldId] == true
        local belowMin = self.minFieldSize > 0 and fe.areaHa < self.minFieldSize
        if isExcluded or belowMin then
            nExcl = nExcl + 1
        elseif fe.isSown then
            nSown = nSown + 1
        elseif assignedLabels[fe.label or ""] then
            nAssigned = nAssigned + 1
        else
            nFree = nFree + 1
        end
    end
    self.spStatFelder:setText(string.format(
        "Felder: %d  |  Besaet: %d  |  Im Plan: %d  |  Frei: %d  |  Ausgeschl.: %d",
        #allFields, nSown, nAssigned, nFree, nExcl))
    self.spStatFelder:setTextColor(0.70, 0.70, 0.70, 1)
end

--- Tab 3: Feldgitter aufbauen (SmoothList, 10 Felder pro Zeile)
function InGameMenuSP:refreshFieldGrid()
    local farmId = g_currentMission:getFarmId()
    local allFields = FieldScanner.getAllOwnedFields(farmId)

    -- Nach Feldnummer sortieren
    table.sort(allFields, function(a, b)
        local na = tonumber((a.label or ""):match("%d+")) or 0
        local nb = tonumber((b.label or ""):match("%d+")) or 0
        if na == nb then return false end
        return na < nb
    end)

    -- assignedLabels aus planResult
    local assignedLabels = {}
    if self.planResult ~= nil then
        for _, fs in ipairs(self.planResult.fruitState) do
            for _, af in ipairs(fs.assignedFields or {}) do
                local lbl = af.fieldEntry and af.fieldEntry.label or nil
                if lbl ~= nil then assignedLabels[lbl] = true end
            end
        end
    end

    -- Felder in Zehnergruppen aufteilen
    local PER_ROW = 10
    local nSown, nAssigned, nFree, nExcl = 0, 0, 0, 0

    self.fieldGridRows = {}
    local currentRow = {}

    for _, fe in ipairs(allFields) do
        local fieldId = nil
        if fe.field ~= nil and fe.field.farmland ~= nil then
            local f = fe.field.farmland.field
            if f ~= nil then fieldId = f.fieldId end
        end
        if fieldId == nil and fe.label ~= nil then
            fieldId = tonumber(fe.label:match("%d+"))
        end

        local isExcluded = fieldId ~= nil and self.excludedFieldIds[fieldId] == true
        local belowMin   = self.minFieldSize > 0 and fe.areaHa < self.minFieldSize
        local isAssigned = assignedLabels[fe.label or ""] == true

        local r, g, b
        if isExcluded or belowMin then
            r, g, b = 0.85, 0.12, 0.12  -- rot, kraeftiger
            nExcl = nExcl + 1
        elseif fe.isSown then
            r, g, b = 0.20, 0.95, 0.30  -- gruen, kraeftiger (Giants-Gruenton)
            nSown = nSown + 1
        elseif isAssigned then
            r, g, b = 1.0, 0.78, 0.0   -- gelb, kraeftiger
            nAssigned = nAssigned + 1
        else
            r, g, b = 0.92, 0.92, 0.92 -- weiss, heller (naeher an echtem Weiss)
            nFree = nFree + 1
        end

        table.insert(currentRow, {
            label = fe.label or "?",
            r = r, g = g, b = b,
        })

        if #currentRow >= PER_ROW then
            table.insert(self.fieldGridRows, currentRow)
            currentRow = {}
        end
    end
    -- letzte unvollstaendige Zeile
    if #currentRow > 0 then
        table.insert(self.fieldGridRows, currentRow)
    end

    -- Zusammenfassung
    if self.spOverviewStat ~= nil then
        self.spOverviewStat:setText(string.format(
            "Eigene Felder: %d  |  Besaet: %d  |  Im Plan: %d  |  Frei: %d  |  Ausgeschl.: %d",
            #allFields, nSown, nAssigned, nFree, nExcl))
        self.spOverviewStat:setTextColor(0.70, 0.70, 0.70, 1)
    end

    if self.spFieldGrid ~= nil then
        self.spFieldGrid:reloadData()
    end
    self:updateMinSizeText()
end

--- Zelle fuer Tab3-Gitter befuellen
function InGameMenuSP:populateFieldGridCell(index, cell)
    local row = self.fieldGridRows and self.fieldGridRows[index]
    if row == nil then return end

    for i = 1, 10 do
        local el = cell:getAttribute("fn" .. i)
        if el ~= nil then
            local slot = row[i]
            if slot ~= nil then
                el:setText(slot.label)
                el:setTextColor(slot.r, slot.g, slot.b, 1)
                -- WICHTIG (10.07.): das Profil "spFN" definiert textSelectedColor
                -- separat von textColor -- ohne diese zwei Zeilen faellt die
                -- Feldfarbe (gruen/gelb/rot) genau in der Zeile unter dem
                -- Mauszeiger auf das statische Profil-Grau zurueck, weil die
                -- GUI dort automatisch die "selected/focused"-Farbe zeigt statt
                -- der per setTextColor() gesetzten. Gleiche Attributnamen wie
                -- im Profil-Schema (guiProfiles.xml), direkt als Instanzfeld
                -- ueberschrieben.
                el.textSelectedColor = {slot.r, slot.g, slot.b, 1}
                el.textFocusedColor  = {slot.r, slot.g, slot.b, 1}
            else
                el:setText("")
                el:setTextColor(0, 0, 0, 0)
                el.textSelectedColor = {0, 0, 0, 0}
                el.textFocusedColor  = {0, 0, 0, 0}
            end
        end
    end
end


function InGameMenuSP:updateMultiLabel()
    if self.spMultiLabel == nil then return end
    local f = self.filterData[self.selectedFilterIndex or 0]
    local m = f ~= nil and (f.schnittMulti or 1) or 1
    self.spMultiLabel:setText(tostring(m) .. "x")
    if m > 1 then
        self.spMultiLabel:setTextColor(1.0, 0.72, 0.0, 1)
    else
        self.spMultiLabel:setTextColor(0.5, 0.5, 0.5, 1)
    end
end

function InGameMenuSP:onClickMultiDec()
    local f = self.filterData[self.selectedFilterIndex]
    if f == nil then return end
    f.schnittMulti = math.max(1, (f.schnittMulti or 1) - 1)
    self.spFilterList:reloadData()
    self:updateMultiLabel()
end

function InGameMenuSP:onClickMultiInc()
    local f = self.filterData[self.selectedFilterIndex]
    if f == nil then return end
    f.schnittMulti = math.min(10, (f.schnittMulti or 1) + 1)
    self.spFilterList:reloadData()
    self:updateMultiLabel()
    self:saveConfig()
end

function InGameMenuSP:onClickFieldExclude(list, section, index, element, wasAlreadySelected)
    InGameMenuSP.ACTIVE_TAB = 4
    self.selectedFieldIndex = index
    -- Kein Toggle hier -- Enter-Taste (onButtonAccept) toggled
end

---------------------------------------------------------------------------
-- SmoothList DataSource / Delegate
---------------------------------------------------------------------------
function InGameMenuSP:getNumberOfSections(list) return 1 end
function InGameMenuSP:getTitleForSectionHeader(list, s) return nil end

function InGameMenuSP:getNumberOfItemsInSection(list, s)
    if list == self.spMainList   then return #self.mainData end
    if list == self.spFilterList then return #self.filterData end
    if list == self.spFieldList  then return #self.fieldData end
    if list == self.spFieldGrid  then return #(self.fieldGridRows or {}) end
    return 0
end

function InGameMenuSP:populateCellForItemInSection(list, section, index, cell)
    if list == self.spMainList then
        self:populateMainCell(index, cell)
    elseif list == self.spFilterList then
        self:populateFilterCell(index, cell)
    elseif list == self.spFieldList then
        self:populateFieldCell(index, cell)
    elseif list == self.spFieldGrid then
        self:populateFieldGridCell(index, cell)
    end
end

---------------------------------------------------------------------------
-- Haupt-Liste (Akkordeon)
---------------------------------------------------------------------------
function InGameMenuSP:populateMainCell(index, cell)
    local row = self.mainData[index]
    if row == nil then return end

    for _, name in ipairs({"col1","col2","col3","col4","col5","col6","col7","hint"}) do
        local c = cell:getAttribute(name)
        if c ~= nil then
            c:setText("")
            c:setTextColor(0.72, 0.72, 0.72, 1)
        end
    end

    if row.rowType == "fieldHeader" then
        local labels = {
            col1 = "   Feld", col2 = "Flaeche", col3 = "Ertrag ca.",
            col4 = "Kumuliert", col5 = "Danach", col6 = "Ueberschuss", col7 = "v",
            col8 = "SPIEL / REAL",
        }
        for name, label in pairs(labels) do
            local c = cell:getAttribute(name)
            if c ~= nil then
                c:setText(label)
                c:setTextColor(0.60, 0.60, 0.60, 1)
            end
        end
        return
    end

    if row.rowType == "factoryHeader" then
        local labels = { col1 = "   Fabrik", col2 = "Modus", col3 = "Bedarf/Jahr" }
        for name, label in pairs(labels) do
            local c = cell:getAttribute(name)
            if c ~= nil then
                c:setText(label)
                c:setTextColor(0.60, 0.60, 0.60, 1)
            end
        end
        return
    end

    if row.rowType == "releaseHint" then
        -- v78: in das volle-Breite Element "hint" schreiben (col1 = 280px
        -- schnitt den Satz ab). "hint" wird oben in der Reset-Schleife geleert.
        local c = cell:getAttribute("hint")
        if c ~= nil then
            c:setText(g_i18n:getText("ui_sp_release_hint"))
            c:setTextColor(0.30, 0.92, 1.0, 1)
        end
        return
    end

    if row.rowType == "force100" then
        local c1 = cell:getAttribute("col1")
        if c1 ~= nil then
            if row.isForced then
                c1:setText("  [x] Priorisierung aufheben")
                c1:setTextColor(0.95, 0.45, 0.0, 1)
            else
                c1:setText("  [*] Auf 100% auffuellen")
                c1:setTextColor(0.40, 0.78, 1.0, 1)
            end
        end
        return
    end

    if row.rowType == "factory" then
        local c1 = cell:getAttribute("col1")
        if c1 ~= nil then
            local nm = row.name
            if nm == nil or nm == "" then nm = "?" end
            c1:setText("   " .. nm)
            c1:setTextColor(0.72, 0.72, 0.72, 1)
        end
        local c2 = cell:getAttribute("col2")
        if c2 ~= nil then
            c2:setText(row.mode)
            c2:setTextColor(0.5, 0.5, 0.5, 1)
        end
        local c3 = cell:getAttribute("col3")
        if c3 ~= nil then
            c3:setText(fmtL(row.amount))
            c3:setTextColor(0.40, 0.78, 1.0, 1)
        end
        return
    end

    if row.rowType == "fruit" then
        local arrow = self.expanded[row.name] and "v " or "> "
        local star = (self.forcedFillTypeIndex ~= nil and self.forcedFillTypeIndex == row.fillTypeIdx) and " [*]" or ""
        local c1 = cell:getAttribute("col1")
        if c1 ~= nil then
            c1:setText(arrow .. row.dispName .. star)
            if row.hasAssigned then
                c1:setTextColor(1.0, 0.72, 0.0, 1)   -- gelb = zu besaende Felder vorhanden
            else
                local a = row.pct > 0 and 1 or 0.4
                c1:setTextColor(a, a, a, 1)
            end
        end
        local c2 = cell:getAttribute("col2")
        if c2 ~= nil then
            if row.pct > 0 then
                c2:setText(pctStr(row.pct))
                if row.pct >= 100 then c2:setTextColor(0.53, 0.88, 0.0, 1)
                elseif row.pct >= 80 then c2:setTextColor(0.40, 0.88, 0.10, 1)
                else c2:setTextColor(0.75, 0.75, 0.75, 1)   -- Gelb entfaellt: Gelb nur fuer anzusaeende Felder
                end
            else
                c2:setText("0%")
                c2:setTextColor(0.3, 0.3, 0.3, 1)
            end
        end
        local c3 = cell:getAttribute("col3")
        if c3 ~= nil then
            c3:setText(fmtL(row.demand))
            c3:setTextColor(0.72, 0.72, 0.72, 1)
        end
        -- Danach: ungedeckelte End-Deckung der Frucht (kann >100% sein bei
        -- Ueberversorgung), Ueberschuss: Liter ueber Bedarf -- beides schon
        -- im Header sichtbar, ohne Aufklappen (LazyChilla 25.07.).
        local c5f = cell:getAttribute("col5")
        if c5f ~= nil then
            c5f:setText(pctStr(row.afterPct or 0))
            if (row.afterPct or 0) >= 100 then c5f:setTextColor(0.53, 0.88, 0.0, 1)
            else c5f:setTextColor(0.75, 0.75, 0.75, 1)   -- Gelb entfaellt
            end
        end
        local c6f = cell:getAttribute("col6")
        if c6f ~= nil then
            if (row.surplus or 0) > 0 then
                c6f:setText("+" .. fmtL(row.surplus))
                c6f:setTextColor(1.0, 0.55, 0.0, 1)
            else
                c6f:setText("—")
                c6f:setTextColor(0.3, 0.3, 0.3, 1)
            end
        end
        local c8f = cell:getAttribute("col8")
        if c8f ~= nil then
            if (row.seedTotal or 0) > 0 then
                local realLHa = getRealSeedLHa(row.fillTypeIndex)
                local totalAreaHa = row.totalAreaHa or 0
                if realLHa ~= nil and totalAreaHa > 0 then
                    local realTotal = realLHa * totalAreaHa
                    c8f:setText(fmtL(row.seedTotal) .. " / ~" .. fmtL(realTotal))
                else
                    c8f:setText(fmtL(row.seedTotal))
                end
                c8f:setTextColor(0.40, 0.78, 1.0, 1)
            else
                c8f:setText("—")
                c8f:setTextColor(0.3, 0.3, 0.3, 1)
            end
        end

    elseif row.rowType == "field" then
        local indent = "   "
        local r, g, b
        if row.released then
            r, g, b = 0.10, 0.35, 1.0        -- kraeftiges Royal-Blau = freigegeben
        elseif row.releasable then
            r, g, b = 0.30, 0.92, 1.0        -- helles Cyan = Freigabe-Vorschlag
        elseif row.isSown then
            r, g, b = 0.20, 0.95, 0.30
        elseif row.isAssigned then
            r, g, b = 1.0, 0.78, 0.0
        else
            r, g, b = 0.55, 0.55, 0.55
        end
        local c1 = cell:getAttribute("col1")
        if c1 ~= nil then
            local prefix = row.isAssigned and ">> " or indent
            local suffix = ""
            if row.released then suffix = "  freigegeben"
            elseif row.releasable then suffix = "  (freigeben)" end
            c1:setText(prefix .. row.fieldNr .. suffix)
            c1:setTextColor(r, g, b, 1)
        end
        local c2 = cell:getAttribute("col2")
        if c2 ~= nil then
            c2:setText(string.format("%.1f ha", row.areaHa))
            c2:setTextColor(r * 0.85, g * 0.85, b * 0.85, 1)
        end
        local c3 = cell:getAttribute("col3")
        if c3 ~= nil then
            c3:setText(fmtL(row.yield))
            c3:setTextColor(r * 0.85, g * 0.85, b * 0.85, 1)
        end
        local c4 = cell:getAttribute("col4")
        if c4 ~= nil then
            c4:setText(fmtL(row.cumul))
            c4:setTextColor(r * 0.85, g * 0.85, b * 0.85, 1)
        end
        local c5 = cell:getAttribute("col5")
        if c5 ~= nil then
            c5:setText(pctStr(row.afterPct))
            if row.afterPct >= 100 then c5:setTextColor(0.53, 0.88, 0.0, 1)
            else c5:setTextColor(0.75, 0.75, 0.75, 1)   -- Gelb entfaellt
            end
        end
        local c6 = cell:getAttribute("col6")
        if c6 ~= nil then
            if row.surplus > 0 then
                c6:setText("+" .. fmtL(row.surplus))
                c6:setTextColor(1.0, 0.55, 0.0, 1)
            else
                c6:setText("—")
                c6:setTextColor(0.25, 0.25, 0.25, 1)
            end
        end
        local c7 = cell:getAttribute("col7")
        if c7 ~= nil then
            if row.isSown then
                c7:setText("v")
                c7:setTextColor(0.53, 0.88, 0.0, 1)
            elseif row.isAssigned then
                c7:setText("!")
                c7:setTextColor(1.0, 0.72, 0.0, 1)
            else
                c7:setText("")
            end
        end
        -- col8: Saatgut Spiel / Real fuer dieses Feld
        local c8 = cell:getAttribute("col8")
        if c8 ~= nil then
            local seedL = calcSeedLiter(row.fillTypeIdx, row.areaHa or 0)
            if seedL > 0 then
                local realLHa = getRealSeedLHa(row.fillTypeIdx)
                if realLHa ~= nil and (row.areaHa or 0) > 0 then
                    local realL = realLHa * row.areaHa
                    c8:setText(fmtL(seedL) .. " / ~" .. fmtL(realL))
                else
                    c8:setText(fmtL(seedL))
                end
                c8:setTextColor(0.40, 0.78, 1.0, 1)
            else
                c8:setText("—")
                c8:setTextColor(0.3, 0.3, 0.3, 1)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Filter-Liste (Tab 2)
---------------------------------------------------------------------------
function InGameMenuSP:populateFilterCell(index, cell)
    local f = self.filterData[index]
    if f == nil then return end

    local nc = cell:getAttribute("fName")
    if nc ~= nil then
        nc:setText(f.dispName)
        local a = f.active and 1 or 0.4
        nc:setTextColor(a, a, a, 1)
    end
    local dc = cell:getAttribute("fDemand")
    if dc ~= nil then
        dc:setText(f.demand > 0 and fmtL(f.demand) or "—")
        local a = f.active and 0.65 or 0.3
        dc:setTextColor(a, a, a, 1)
    end
    local ac = cell:getAttribute("fActive")
    if ac ~= nil then
        if f.active then
            ac:setText("AN")
            ac:setTextColor(0.53, 0.88, 0.0, 1)
        else
            ac:setText("AUS")
            ac:setTextColor(0.90, 0.10, 0.10, 1)
        end
    end
    local mc = cell:getAttribute("fMulti")
    if mc ~= nil then
        local m = f.schnittMulti or 1
        mc:setText(tostring(m) .. "x")
        if m > 1 then
            mc:setTextColor(1.0, 0.72, 0.0, 1)
        else
            mc:setTextColor(0.60, 0.60, 0.60, 1)
        end
    end

    -- Aussaatfenster (v75, Stufe 1): reine Info pro Frucht, Daten aus
    -- PlantingCalendar (gegen Giants verifiziert). Keine Rechenlogik beruehrt.
    local cc = cell:getAttribute("fCal")
    if cc ~= nil then
        local win = (PlantingCalendar ~= nil) and PlantingCalendar.getWindowText(f.name, f.fillTypeIndex) or nil
        cc:setText(win or "—")
        local a = f.active and 0.72 or 0.35
        cc:setTextColor(a, a, a, 1)
    end
end

---------------------------------------------------------------------------
-- Feld-Liste (Tab 3)
---------------------------------------------------------------------------
function InGameMenuSP:populateFieldCell(index, cell)
    local fe = self.fieldData[index]
    if fe == nil then return end

    -- Farbe bestimmen:
    --   Grau-durchgestrichen (belowMin): automatisch durch Mindestgroesse raus
    --   Rot (excluded): manuell ausgeschlossen
    --   Gruen (aktiv): im Algorithmus dabei
    local r, g, b
    local statusText
    if fe.belowMin then
        r, g, b = 0.35, 0.35, 0.35
        statusText = "< min"
    elseif fe.cutOff then
        r, g, b = 0.35, 0.35, 0.35
        statusText = "Nr aus"
    elseif fe.excluded then
        r, g, b = 0.85, 0.12, 0.12
        statusText = "AUS"
    elseif fe.isSown then
        r, g, b = 0.20, 0.95, 0.30    -- gruen = besaet (konsistent mit Tab 1/3)
        statusText = "AN"
    elseif fe.isAssigned then
        r, g, b = 1.0, 0.78, 0.0     -- gelb = vom Algorithmus vorgeschlagen
        statusText = "AN"
    else
        r, g, b = 0.8, 0.8, 0.8      -- weiss/hellgrau = frei, nicht vorgeschlagen
        statusText = "AN"
    end

    local c1 = cell:getAttribute("efNr")
    if c1 ~= nil then
        c1:setText(fe.label)
        c1:setTextColor(r, g, b, 1)
    end
    local c2 = cell:getAttribute("efArea")
    if c2 ~= nil then
        c2:setText(string.format("%.2f ha", fe.areaHa))
        c2:setTextColor(r * 0.85, g * 0.85, b * 0.85, 1)
    end
    local c3 = cell:getAttribute("efFruit")
    if c3 ~= nil then
        c3:setText(fe.fruitDisp)
        c3:setTextColor(r * 0.85, g * 0.85, b * 0.85, 1)
    end
    local c4 = cell:getAttribute("efActive")
    if c4 ~= nil then
        c4:setText(statusText)
        c4:setTextColor(r, g, b, 1)
    end
end

---------------------------------------------------------------------------
-- Persistenz: alles in EINE XML-Datei
-- <SaatplanConfig disabled="WHEAT,CANOLA" excludedFields="4,5" minFieldSize="0.5"/>
---------------------------------------------------------------------------
function InGameMenuSP:getSaveDir()
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        local mi = g_currentMission.missionInfo
        if mi.savegameDirectory ~= nil and mi.savegameDirectory ~= "" then
            return mi.savegameDirectory
        end
        -- Fallback wie AutoDrive (verifiziert aus AutoDrive/scripts/XML.lua):
        if mi.savegameIndex ~= nil then
            local base = getUserProfileAppPath()
            if base ~= nil then
                return base .. "savegame" .. tostring(mi.savegameIndex)
            end
        end
    end
    return nil
end

function InGameMenuSP:loadConfig()
    local farmId = g_currentMission:getFarmId()
    local demanded = DemandScanner.getAllDemandedFillTypes(farmId)

    local prevActive = {}
    for _, f in ipairs(self.filterData) do prevActive[f.name] = f.active end

    local savedDisabled   = {}
    local savedExcluded   = {}
    local savedMinSize    = 0.0
    local savedMulti      = {}
    local savedAllocStrategy = "absolut"
    local savedMaxFieldNumber = 0

    local saveDir = self:getSaveDir()
    if saveDir then
        local xmlPath = saveDir .. "/FS25_Saatplan_config.xml"
        if fileExists(xmlPath) then
            local schemaName = "spCfgLoad_" .. tostring(math.floor(getTime and getTime() or 0))
            local schema = XMLSchema.new(schemaName)
            schema:register(XMLValueType.STRING, "SaatplanConfig#disabled")
            schema:register(XMLValueType.STRING, "SaatplanConfig#excludedFields")
            schema:register(XMLValueType.FLOAT,  "SaatplanConfig#minFieldSize")
            schema:register(XMLValueType.STRING, "SaatplanConfig#schnittMulti")
            schema:register(XMLValueType.STRING, "SaatplanConfig#allocStrategy")
            schema:register(XMLValueType.INT, "SaatplanConfig#forcedFillType")
            schema:register(XMLValueType.INT, "SaatplanConfig#maxFieldNumber")
            local xmlFile = XMLFile.loadIfExists("spCfgLoad", xmlPath, schema)
            if xmlFile ~= nil then
                -- Frucht-Filter
                local disabled = xmlFile:getValue("SaatplanConfig#disabled")
                if disabled ~= nil and disabled ~= "" then
                    for name in string.gmatch(disabled, "([^,]+)") do
                        savedDisabled[name] = true
                    end
                end
                -- Feld-Ausschluss
                local exclStr = xmlFile:getValue("SaatplanConfig#excludedFields")
                if exclStr ~= nil and exclStr ~= "" then
                    for idStr in string.gmatch(exclStr, "([^,]+)") do
                        local id = tonumber(idStr)
                        if id ~= nil then savedExcluded[id] = true end
                    end
                end
                -- Mindestgroesse
                local minSize = xmlFile:getValue("SaatplanConfig#minFieldSize")
                if minSize ~= nil then savedMinSize = minSize end

                -- Feld-Cutoff ab Nummer (v78, lokal/Host-only)
                local maxFN = xmlFile:getValue("SaatplanConfig#maxFieldNumber")
                if maxFN ~= nil and maxFN > 0 then savedMaxFieldNumber = maxFN end

                -- Schnitt-Multiplikatoren: "GRASS:3,ALFALFA:2"
                local multiStr = xmlFile:getValue("SaatplanConfig#schnittMulti")
                if multiStr ~= nil and multiStr ~= "" then
                    for pair in string.gmatch(multiStr, "([^,]+)") do
                        local name, val = pair:match("([^:]+):(%d+)")
                        if name ~= nil and val ~= nil then
                            savedMulti[name] = tonumber(val) or 1
                        end
                    end
                end

                -- Zuteilungsstrategie (10.07., Einstellungs-Tab, rein lokal/
                -- Host-only -- kein MP-Sync, siehe Entscheidung LazyChilla)
                local allocStr = xmlFile:getValue("SaatplanConfig#allocStrategy")
                if allocStr ~= nil and allocStr ~= "" then
                    savedAllocStrategy = allocStr
                end

                local forcedFT = xmlFile:getValue("SaatplanConfig#forcedFillType")
                if forcedFT ~= nil and forcedFT > 0 then
                    self.forcedFillTypeIndex = forcedFT
                end

                xmlFile:delete()
                print(string.format("[Saatplan] loadConfig: %d deaktivierte Fruechte, %d ausgeschl. Felder, minSize=%.1f",
                    (function() local n=0; for _ in pairs(savedDisabled) do n=n+1 end; return n end)(),
                    (function() local n=0; for _ in pairs(savedExcluded) do n=n+1 end; return n end)(),
                    savedMinSize))
            else
                print("[Saatplan] loadConfig: XMLFile.loadIfExists lieferte nil")
            end
        else
            print("[Saatplan] loadConfig: Datei nicht gefunden (erster Start)")
        end
    else
        print("[Saatplan] loadConfig: getSaveDir() lieferte nil")
    end

    -- savedDisabled als Puffer auf self merken -- saveConfig nutzt ihn als
    -- Fallback wenn filterData noch leer ist (passiert wenn loadConfig in
    -- loadMap aufgerufen wird und DemandScanner dort noch leere Liste liefert)
    self.savedDisabledNames = savedDisabled
    self.savedMultiNames    = savedMulti

    -- Frucht-Filter aufbauen
    -- WICHTIG: savedDisabled (aus XML) hat IMMER Vorrang. prevActive (Stand im
    -- RAM aus vorheriger Session) wird NUR fuer Fruechte verwendet, die weder
    -- in der XML noch frisch sind - verhindert dass ein alter RAM-Zustand
    -- einen frisch geladenen XML-Zustand ueberschreibt (Bug 30.06.: Filter
    -- "vergass" Aenderungen nach Schliessen/Neuoeffnen des ESC-Tabs).
    self.filterData = {}
    for _, ft in ipairs(demanded) do
        local active = true
        if savedDisabled[ft.name] then
            active = false
        end
        -- schnittMulti aus gespeicherter Config laden
        local multi = 1
        if savedMulti ~= nil and savedMulti[ft.name] ~= nil then
            multi = savedMulti[ft.name]
        end
        table.insert(self.filterData, {
            name          = ft.name,
            dispName      = displayName(ft.name, ft.fillTypeIndex),
            fillTypeIndex = ft.fillTypeIndex,
            active        = active,
            demand        = 0,
            schnittMulti  = multi,
        })
    end

    -- Feld-Ausschluss und Mindestgroesse uebernehmen
    self.excludedFieldIds = savedExcluded
    self.minFieldSize     = savedMinSize
    self.maxFieldNumber   = savedMaxFieldNumber
    self.allocStrategy    = savedAllocStrategy

    print(string.format("[Saatplan] Config geladen: %d Fruechte", #self.filterData))

    -- Puffer loeschen sobald filterData aufgebaut ist (Tab geoeffnet oder
    -- DemandScanner hat Daten geliefert) -- saveConfig nutzt dann filterData,
    -- nicht mehr den Puffer
    if #self.filterData > 0 then
        self.savedDisabledNames = nil
        self.savedMultiNames    = nil
    end
end

--- Vom Server empfangene Config auf Client anwenden (MP)
function InGameMenuSP:applyServerConfig(disabled, excludedFields, minFieldSize, schnittMulti)

    -- Disabled-Fruechte parsen
    local savedDisabled = {}
    if disabled ~= nil and disabled ~= "" then
        for name in string.gmatch(disabled, "([^,]+)") do
            savedDisabled[name] = true
        end
    end

    -- Feld-Ausschluss parsen
    local savedExcluded = {}
    if excludedFields ~= nil and excludedFields ~= "" then
        for idStr in string.gmatch(excludedFields, "([^,]+)") do
            local id = tonumber(idStr)
            if id ~= nil then savedExcluded[id] = true end
        end
    end

    -- Schnitt-Multiplikatoren parsen
    local savedMulti = {}
    if schnittMulti ~= nil and schnittMulti ~= "" then
        for pair in string.gmatch(schnittMulti, "([^,]+)") do
            local name, val = pair:match("([^:]+):(%d+)")
            if name ~= nil and val ~= nil then
                savedMulti[name] = tonumber(val) or 1
            end
        end
    end

    -- filterData aktualisieren
    for _, f in ipairs(self.filterData or {}) do
        f.active = not savedDisabled[f.name]
        if savedMulti[f.name] ~= nil then
            f.schnittMulti = savedMulti[f.name]
        end
    end

    -- Feld-Ausschluss und Mindestgroesse
    self.excludedFieldIds = savedExcluded
    self.minFieldSize     = minFieldSize or 0.0

    self.configLoaded = true

    -- Tab neu aufbauen
    self:buildFieldData()
    self:recalculate()
    self:showTab(InGameMenuSP.ACTIVE_TAB)
end

function InGameMenuSP:saveConfig()
    -- Client im MP speichert nicht -- nur Host/Singleplayer schreibt ins Savegame
    if g_server == nil then
        return
    end

    -- KEIN configLoaded-Guard mehr (Bugfix 12.07., AutoDrive/DispoList-Pattern):
    -- loadConfig() wird jetzt in loadMap() aufgerufen, d.h. configLoaded ist
    -- immer true bevor der erste Save-Hook feuert. Der frueherer Guard blockierte
    -- das Schreiben nach tempsavegame -- Giants kopierte tempsavegame (ohne
    -- unsere Datei) ueber savegame2 und loeschte unsere Config.
    local saveDir = self:getSaveDir()
    if saveDir == nil then
        print("[Saatplan] saveConfig: kein savegameDirectory, Abbruch.")
        return
    end
    local xmlPath = saveDir .. "/FS25_Saatplan_config.xml"
    local schemaName = "spCfgSave_" .. tostring(math.floor(getTime and getTime() or 0))
    local schema = XMLSchema.new(schemaName)
    schema:register(XMLValueType.STRING, "SaatplanConfig#disabled")
    schema:register(XMLValueType.STRING, "SaatplanConfig#excludedFields")
    schema:register(XMLValueType.FLOAT,  "SaatplanConfig#minFieldSize")
    schema:register(XMLValueType.STRING, "SaatplanConfig#schnittMulti")
    schema:register(XMLValueType.STRING, "SaatplanConfig#allocStrategy")
            schema:register(XMLValueType.INT, "SaatplanConfig#forcedFillType")
    schema:register(XMLValueType.INT, "SaatplanConfig#maxFieldNumber")
    local xmlFile = XMLFile.create("spCfgSave", xmlPath, "SaatplanConfig", schema)
    if xmlFile == nil then
        print("[Saatplan] Warnung: Config konnte nicht gespeichert werden: " .. xmlPath)
        return
    end

    -- Frucht-Filter: filterData nutzen wenn befuellt (Tab mind. einmal geoeffnet),
    -- sonst Fallback auf savedDisabledNames (gelesen in loadConfig, aber filterData
    -- war zum loadMap-Zeitpunkt noch leer weil DemandScanner dort noch keine
    -- Produktionsketten liefert)
    local dis = {}
    if #self.filterData > 0 then
        for _, f in ipairs(self.filterData) do
            if not f.active then table.insert(dis, f.name) end
        end
    elseif self.savedDisabledNames ~= nil then
        for name, _ in pairs(self.savedDisabledNames) do
            table.insert(dis, name)
        end
    end
    xmlFile:setValue("SaatplanConfig#disabled", table.concat(dis, ","))

    -- Feld-Ausschluss
    local excl = {}
    for fieldId, _ in pairs(self.excludedFieldIds) do
        table.insert(excl, tostring(fieldId))
    end
    xmlFile:setValue("SaatplanConfig#excludedFields", table.concat(excl, ","))

    -- Mindestgroesse
    xmlFile:setValue("SaatplanConfig#minFieldSize", self.minFieldSize)

    -- Schnitt-Multiplikatoren: Fallback analog Frucht-Filter
    local multiParts = {}
    if #self.filterData > 0 then
        for _, f in ipairs(self.filterData) do
            if (f.schnittMulti or 1) > 1 then
                table.insert(multiParts, f.name .. ":" .. tostring(f.schnittMulti))
            end
        end
    elseif self.savedMultiNames ~= nil then
        for name, val in pairs(self.savedMultiNames) do
            if val > 1 then table.insert(multiParts, name .. ":" .. tostring(val)) end
        end
    end
    xmlFile:setValue("SaatplanConfig#schnittMulti", table.concat(multiParts, ","))

    -- Zuteilungsstrategie (10.07., rein lokal/Host-only, kein MP-Event noetig)
    xmlFile:setValue("SaatplanConfig#allocStrategy", self.allocStrategy or "absolut")
    xmlFile:setValue("SaatplanConfig#forcedFillType", self.forcedFillTypeIndex or 0)
    xmlFile:setValue("SaatplanConfig#maxFieldNumber", self.maxFieldNumber or 0)

    xmlFile:save()
    xmlFile:delete()
    print(string.format("[Saatplan] Config gespeichert: %d deakt.Fruechte, %d ausgeschl.Felder, minSize=%.1f",
        #dis, #excl, self.minFieldSize))
end
