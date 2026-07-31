-- ============================================================
--  Saatplan-Assistent - Einstiegspunkt
--  Laedt alle Module und registriert die Konsolenbefehle, mit
--  denen wir das Mod in der Entwicklungsphase ohne eigenes GUI
--  testen koennen.
-- ============================================================

local modDirectory = g_currentModDirectory
local modName = g_currentModName

source(modDirectory .. "src/DemandScanner.lua")
source(modDirectory .. "src/FieldScanner.lua")
source(modDirectory .. "src/SeedPlanner.lua")

SaatplanAssistent = {}
SaatplanAssistent.modDirectory = modDirectory
SaatplanAssistent.modName = modName

function SaatplanAssistent:loadMap()
    addConsoleCommand("gsSaatplan", "Saatplan fuer eine Fruchtart berechnen, z.B. gsSaatplan WHEAT", "consoleCommandSaatplan", self)
    addConsoleCommand("gsSaatplanAlle", "Gesamtuebersicht: alle Felder auf alle benoetigten Fruchtarten verteilen", "consoleCommandSaatplanAlle", self)
    addConsoleCommand("gsSaatplanDump", "Rohdaten von Fabriken/Staellen ausgeben (zur Strukturpruefung)", "consoleCommandDump", self)
    addConsoleCommand("gsSaatplanCheck", "Detailcheck einer Fruchtart: aktive Linien, parallel/geteilt, Filterbegruendung. z.B. gsSaatplanCheck BARLEY", "consoleCommandCheck", self)
    addConsoleCommand("gsSaatplanWindrowDump", "Zeigt windrowFillType-Zuordnung aller FruitTypes (STRAW/GERSTE-Verdacht pruefen)", "consoleCommandWindrowDump", self)
    addConsoleCommand("gsSaatplanSeedDump", "Zeigt seedUsagePerSqm und daraus berechnetes L/ha fuer alle Fruchtarten (Saatgut-Berechnung gegenchecken)", "consoleCommandSeedDump", self)

    -- ESC-Tab registrieren (nach verifiziertem FieldPriceMonitor-Pattern,
    -- d.h. fixInGameMenu aus FPM direkt wiederverwendet)
    local ok, err = pcall(function()
        g_gui:loadProfiles(modDirectory .. "gui/guiProfiles.xml")
        local frame = InGameMenuSP.new(g_i18n)
        InGameMenuSP.instance = frame  -- fuer ItemSystem.save Hook
        g_gui:loadGui(modDirectory .. "gui/InGameMenuSP.xml", "ingameMenuSP", frame, true)
        SaatplanAssistent.fixInGameMenu(frame, "ingameMenuSP", {0, 0, 1024, 1024}, 2,
            function() return true end)
        frame:initialize()

        -- Config JETZT laden (AutoDrive/DispoList-Pattern: in loadMap, nicht lazy
        -- beim ersten Tab-Oeffnen). Verhindert, dass der Save-Hook bei Autosaves
        -- VOR dem ersten Tab-Oeffnen den Guard feuert und die XML nicht nach
        -- tempsavegame schreibt -- Giants kopiert sonst tempsavegame (ohne unsere
        -- Datei) ueber savegame2 und loescht unsere Config. configLoaded-Guard
        -- auf saveConfig war der Fehler -- er gehoert nur auf loadConfig (kein
        -- Doppelladen), nicht auf saveConfig (immer schreiben).
        frame:loadConfig()
    end)
    if not ok then
        print("[Saatplan] FEHLER beim Laden des ESC-Tabs: " .. tostring(err))
    else
    end

    -- Zentraler Speicherpunkt (verifiziert nach AutoDrive-Pattern, ARCHITECTURE.md 01.07.)
    -- WICHTIG: SaatplanAssistent ist keine Klasse (kein Class()-Aufruf), also
    -- Hook als anonyme Funktion -- nicht als Methode (self waere sonst ItemSystem!)
    -- Beide Hooks fuer vollstaendige Abdeckung aller Speicher-Szenarien:
    -- ItemSystem.save:           Autosave + Speichern-und-Beenden (FS25 1.5+)
    -- FSBaseMission.saveSavegame: manuelles Speichern im ESC-Menue
    -- (Pattern verifiziert aus AutoDrive + BetterContracts/RoyalMod)
    local function spSave()
        if g_server ~= nil then
            if InGameMenuSP ~= nil and InGameMenuSP.instance ~= nil then
                InGameMenuSP.instance:saveConfig()
            end
        end
    end
    ItemSystem.save = Utils.prependedFunction(ItemSystem.save, spSave)
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, spSave)

    print("[Saatplan] Mod geladen. Konsole: gsSaatplan <FRUCHT>, gsSaatplanAlle, gsSaatplanDump, gsSaatplanCheck <FRUCHT>, gsSaatplanWindrowDump, gsSaatplanSeedDump. F7: HUD.")

    self.hudVisible = false
    self.hudLines = {}
    self.keyWasDown = false
end

---------------------------------------------------------------------------
-- fixInGameMenu -- nach dem FieldPriceMonitor-Pattern (verifiziert, laeuft bei dir)
---------------------------------------------------------------------------
function SaatplanAssistent.fixInGameMenu(frame, pageName, uvs, position, predicateFunc)
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    local abovePrices = 0

    for k, v in pairs({pageName}) do
        inGameMenu.controlIDs[v] = nil
    end

    for i = 1, #inGameMenu.pagingElement.elements do
        local child = inGameMenu.pagingElement.elements[i]
        if child == inGameMenu["pageStatistics"] then
            abovePrices = i
        end
    end

    if abovePrices == 0 then abovePrices = position end

    inGameMenu[pageName] = frame
    inGameMenu.pagingElement:addElement(inGameMenu[pageName])
    inGameMenu:exposeControlsAsFields(pageName)

    for i = 1, #inGameMenu.pagingElement.elements do
        local child = inGameMenu.pagingElement.elements[i]
        if child == inGameMenu[pageName] then
            table.remove(inGameMenu.pagingElement.elements, i)
            table.insert(inGameMenu.pagingElement.elements, abovePrices, child)
            break
        end
    end

    for i = 1, #inGameMenu.pagingElement.pages do
        local child = inGameMenu.pagingElement.pages[i]
        if child.element == inGameMenu[pageName] then
            table.remove(inGameMenu.pagingElement.pages, i)
            table.insert(inGameMenu.pagingElement.pages, abovePrices, child)
            break
        end
    end

    inGameMenu.pagingElement:updateAbsolutePosition()
    inGameMenu.pagingElement:updatePageMapping()
    inGameMenu:registerPage(inGameMenu[pageName], position, predicateFunc)

    local iconFileName = Utils.getFilename("images/menuIcon.dds", modDirectory)
    inGameMenu:addPageTab(inGameMenu[pageName], iconFileName, GuiUtils.getUVs(uvs))

    for i = 1, #inGameMenu.pageFrames do
        local child = inGameMenu.pageFrames[i]
        if child == inGameMenu[pageName] then
            table.remove(inGameMenu.pageFrames, i)
            table.insert(inGameMenu.pageFrames, abovePrices, child)
            break
        end
    end

    inGameMenu:rebuildTabList()
end

function SaatplanAssistent:deleteMap()
    -- Karten-Marker aufraumen beim Spielende/Kartenwechsel (analog AutoDrive:deleteMap)
    if InGameMenuSP ~= nil and InGameMenuSP.instance ~= nil then
        InGameMenuSP.instance:clearMapHotspots()
    end
end

function SaatplanAssistent:consoleCommandSaatplan(fillTypeName)
    if fillTypeName == nil or fillTypeName == "" then
        print("Nutzung: gsSaatplan <FruchtName>  (z.B. WHEAT, BARLEY, CANOLA ...)")
        return
    end

    -- TODO verifizieren: g_currentMission:getFarmId() liefert in Singleplayer
    -- ueblicherweise die Farm des lokalen Spielers. Falls das im Test nicht
    -- stimmt: alternativ g_currentMission.player.farmId pruefen.
    local farmId = g_currentMission:getFarmId()

    local result = SeedPlanner.buildPlanForFruitType(farmId, fillTypeName)
    SeedPlanner.printPlan(result)
end

-- Liest ALLE im GUI gespeicherten Saatplan-Einstellungen (Fruchtfilter,
-- Feldausschluss, Mindestgroesse, Schnitt-Multiplikatoren, Zuteilungs-
-- strategie) -- fuer Konsolenbefehle/g_farmCore-Export, die kein "self"
-- vom GUI-Frame haben (siehe Singleton InGameMenuSP.instance).
--
-- BUGFIX (11.07., gefunden ueber FarmAssistant): Vorher wurden hier bei
-- excludedSet/excludedFieldIds/minFieldSize/schnittMultiMap immer nur
-- feste nil/Defaults an buildOverallPlan() durchgereicht -- das heisst,
-- der g_farmCore-Export (getPlan/getAutarkie) hat Feld-Ausschluss UND
-- Fruchtfilter komplett ignoriert und einen ungefilterten Plan geliefert,
-- waehrend der eigene Saatplan-Tab (recalculate() in InGameMenuSP.lua)
-- korrekt gefiltert hat. Diese Funktion spiegelt jetzt exakt dieselbe
-- Aufbaulogik wie recalculate(), damit Export und eigener Tab immer
-- denselben Plan liefern.
local function getSavedPlanParams()
    local excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, priorityFillTypeIndex, maxFieldNumber = {}, {}, 0.0, {}, "absolut", nil, 0
    local releasedFieldIds = {}

    if InGameMenuSP ~= nil and InGameMenuSP.instance ~= nil then
        local inst = InGameMenuSP.instance

        if inst.filterData ~= nil and #inst.filterData > 0 then
            -- Tab wurde mind. einmal geoeffnet: filterData ist aktuell und vollstaendig
            for _, f in ipairs(inst.filterData) do
                if not f.active then excl[f.fillTypeIndex] = true end
                if (f.schnittMulti or 1) > 1 then
                    schnittMultiMap[f.name] = f.schnittMulti
                end
            end
        else
            -- filterData noch leer (Tab nie geoeffnet): Fallback auf Puffer die
            -- loadConfig in loadMap bereits aus der Config-XML gelesen hat.
            -- Fuer excl brauchen wir den FillType-Index -- per Vorwaerts-Lookup.
            if inst.savedDisabledNames ~= nil then
                if g_fruitTypeManager ~= nil and g_fruitTypeManager.fruitTypes ~= nil then
                    for _, ft in ipairs(g_fruitTypeManager.fruitTypes) do
                        if ft.name ~= nil and inst.savedDisabledNames[ft.name] and ft.fillType ~= nil then
                            excl[ft.fillType.index] = true
                        end
                    end
                end
            end
            -- schnittMultiMap nutzt Fruchtnamen direkt (kein Index noetig)
            if inst.savedMultiNames ~= nil then
                for name, val in pairs(inst.savedMultiNames) do
                    if val > 1 then schnittMultiMap[name] = val end
                end
            end
        end

        if inst.excludedFieldIds ~= nil then
            for fieldId, _ in pairs(inst.excludedFieldIds) do
                exclFields[fieldId] = true
            end
        end

        minFieldSize          = inst.minFieldSize or 0.0
        maxFieldNumber        = inst.maxFieldNumber or 0
        allocStrategy         = inst.allocStrategy or "absolut"
        priorityFillTypeIndex = inst.forcedFillTypeIndex

        -- Freigegebene Felder (Zwischenzustand) auch in Export/FA spiegeln
        -- (Freigabe-Bruecke 26.07.): dieselbe Selbstheilung/Set-Logik wie im
        -- Saatplan-Tab, damit g_farmCore/FarmAssistant denselben Plan rechnen.
        if inst.buildReleasedFieldIds ~= nil and g_currentMission ~= nil then
            releasedFieldIds = inst:buildReleasedFieldIds(g_currentMission:getFarmId())
        end
    end

    return excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, priorityFillTypeIndex, releasedFieldIds, maxFieldNumber
end

function SaatplanAssistent:consoleCommandSaatplanAlle()
    local farmId = g_currentMission:getFarmId()
    local excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, prio, releasedFieldIds, maxFieldNumber = getSavedPlanParams()
    local result = SeedPlanner.buildOverallPlan(farmId, excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, prio, releasedFieldIds, maxFieldNumber)
    SeedPlanner.printOverallPlan(result)
end

function SaatplanAssistent:consoleCommandDump()
    local farmId = g_currentMission:getFarmId()
    DemandScanner.debugDump(farmId)
    FieldScanner.debugDump(farmId)
end

function SaatplanAssistent:consoleCommandCheck(fillTypeName)
    if fillTypeName == nil or fillTypeName == "" then
        print("Nutzung: gsSaatplanCheck <FruchtName>  (z.B. gsSaatplanCheck BARLEY)")
        return
    end
    local farmId = g_currentMission:getFarmId()
    DemandScanner.debugFruitCheck(farmId, fillTypeName)
end

function SaatplanAssistent:consoleCommandWindrowDump()
    DemandScanner.debugWindrowDump()
end

function SaatplanAssistent:consoleCommandSeedDump()
    DemandScanner.debugSeedRateDump()
end

-- ============================================================
--  HUD-Overlay (Phase 4 UX, 21.06.)
--  Taste F7 blendet die Gesamtuebersicht direkt auf dem Bildschirm ein/aus.
--  Hook-Muster (BaseMission.draw/update via Utils.appendedFunction,
--  Input.isKeyPressed mit Flanken-Erkennung statt registerActionEvent)
--  unveraendert aus dem eigenen, bestaetigt laufenden Mod uebertragen
--  FS25_GoToNextField.lua -- bewusst NICHT das ungetestete
--  registerActionEvent/modDesc-inputBinding-Muster aus der vorigen Version,
--  weil dieses hier nachweislich in genau dieser FS25-Version funktioniert.
-- ============================================================

-- Schreibweise der Tastenkonstante (KEY_F7 vs. KEY_f7) ist aus den verfuegbaren
-- Referenzen nicht zweifelsfrei verifizierbar (alle gefundenen Beispiele nutzen
-- nur Buchstabentasten wie KEY_n, KEY_lshift). Statt zu raten: beide Varianten
-- probieren, einmalig loggen welche (falls ueberhaupt eine) existiert.
local saatplanF7Key = Input.KEY_F7 or Input.KEY_f7
if saatplanF7Key == nil then
    print("[Saatplan] Warnung: Input.KEY_F7/KEY_f7 nicht gefunden -- HUD-Taste funktioniert nicht. Bitte Rueckmeldung, dann korrigiere ich die Konstante.")
end

local function saatplanOnUpdate(dt)
    if saatplanF7Key == nil then
        return
    end
    local f7Down = Input.isKeyPressed(saatplanF7Key)

    if f7Down then
        if not SaatplanAssistent.keyWasDown then
            SaatplanAssistent.keyWasDown = true
            SaatplanAssistent.hudVisible = not SaatplanAssistent.hudVisible
            if SaatplanAssistent.hudVisible then
                local farmId = g_currentMission:getFarmId()
                local excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, prio, releasedFieldIds, maxFieldNumber = getSavedPlanParams()
                local result = SeedPlanner.buildOverallPlan(farmId, excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, prio, releasedFieldIds, maxFieldNumber)
                SaatplanAssistent.hudLines = SeedPlanner.formatOverallPlanLines(result)
            end
        end
    else
        SaatplanAssistent.keyWasDown = false
    end
end

local function saatplanOnDraw()
    if not SaatplanAssistent.hudVisible then
        return
    end

    local x = 0.02
    local y = 0.95
    local lineHeight = 0.02
    local textSize = 0.014

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    renderText(x, y, textSize, "=== Saatplan-Assistent (F7 zum Schliessen) ===")
    setTextBold(false)
    y = y - lineHeight

    for _, line in ipairs(SaatplanAssistent.hudLines) do
        renderText(x, y, textSize, line)
        y = y - lineHeight
        if y < 0.05 then
            break -- Bildschirmrand erreicht, Rest abschneiden statt ueberlaufen
        end
    end

    setTextColor(1, 1, 1, 1)
end

BaseMission.draw = Utils.appendedFunction(BaseMission.draw, function(self)
    if self == g_currentMission then saatplanOnDraw() end
end)

---------------------------------------------------------------------------
-- Karten-Menue: Y (MENU_EXTRA_1) blendet die Saatplan-Marker ein/aus.
-- md-verifizierter ESC-Menue-Weg (MENU_EXTRA_1 frei) + ImplementCheck-Rezept
-- (registerActionEvent beim Frame-Open, removeActionEvent beim Close).
-- Nicht-invasiv: nur unsere eigene Action, keine nativen Buttons angefasst.
---------------------------------------------------------------------------
if InGameMenuMapFrame ~= nil then
    InGameMenuMapFrame.onFrameOpen = Utils.appendedFunction(InGameMenuMapFrame.onFrameOpen, function()
        local inst = InGameMenuSP.instance
        if inst == nil or g_inputBinding == nil then return end
        local success, eventId = g_inputBinding:registerActionEvent(InputAction.MENU_EXTRA_1, inst, inst.onToggleMapLabels, false, true, false, true)
        if success then
            inst.spMapToggleEventId = eventId
            g_inputBinding:setActionEventTextVisibility(eventId, true)
            inst:updateMapToggleText()
        end
    end)

    InGameMenuMapFrame.onFrameClose = Utils.prependedFunction(InGameMenuMapFrame.onFrameClose, function()
        local inst = InGameMenuSP.instance
        if inst ~= nil and inst.spMapToggleEventId ~= nil and g_inputBinding ~= nil then
            g_inputBinding:removeActionEvent(inst.spMapToggleEventId)
            inst.spMapToggleEventId = nil
        end
    end)
end

BaseMission.update = Utils.appendedFunction(BaseMission.update, function(self, dt)
    if self == g_currentMission then saatplanOnUpdate(dt) end
end)

addModEventListener(SaatplanAssistent)


---------------------------------------------------------------------------
-- Zentraler Speicherpunkt (analog AutoDrive:saveSavegame)
-- Wird von ItemSystem.save Hook aufgerufen (bei Speichern/Autosave/Beenden)
-- savegameDirectory zeigt zu diesem Zeitpunkt auf tempsavegame (FS25 1.5+)
-- Giants kopiert danach tempsavegame -> savegameXX automatisch
---------------------------------------------------------------------------
function SaatplanAssistent:saveSavegame()
    if g_server ~= nil then
        if InGameMenuSP ~= nil and InGameMenuSP.instance ~= nil then
            InGameMenuSP.instance:saveConfig()
        else
            print("[Saatplan] saveSavegame: InGameMenuSP.instance ist nil!")
        end
    end
end

-- ============================================================
--  g_farmCore Export (fuer FarmAssistant / Dachmod)
--  Kein Hard-Dependency: dieser Mod funktioniert genauso ohne
--  FarmCore-Mod installiert, deshalb "g_farmCore = g_farmCore or {}"
--
--  WICHTIG (Performance): buildOverallPlan() iteriert ueber alle
--  eigenen Felder + Fabriken/Staelle -- das ist kein ganz billiger
--  Aufruf. getAutarkie() und getPlan() rufen das Ergebnis JEWEILS
--  NEU auf. Wer beides braucht, sollte einmal getPlan() aufrufen
--  und result.autarkieGrad selbst auslesen, statt beide Funktionen
--  hintereinander zu rufen. Fuer den ESC-Tab-Open-Zeitpunkt (kein
--  Dauerbetrieb, siehe FarmAssistant) ist das trotzdem unkritisch.
--
--  WICHTIG (Cross-Mod-Zugriff, seit Vorfall 06.07.): FarmAssistant
--  liest dieses Modul NICHT ueber ein gemeinsames g_farmCore-Global,
--  sondern aktiv per _G["FS25_Saatplan"].g_farmCore.modules.saatplan
--  -- jeder Mod hat seine eigene private Lua-Umgebung in FS25.
-- ============================================================
g_farmCore = g_farmCore or { modules = {} }
g_farmCore.modules.saatplan = {

    -- Autarkiegrad (0.0 - 1.0+) fuer die eigene Farm.
    -- farmId optional, Default = aktuell gesteuerte Farm.
    getAutarkie = function(farmId)
        farmId = farmId or (g_currentMission ~= nil and g_currentMission:getFarmId())
        if farmId == nil then return 0 end
        local excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, prio, releasedFieldIds, maxFieldNumber = getSavedPlanParams()
        local result = SeedPlanner.buildOverallPlan(farmId, excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, prio, releasedFieldIds, maxFieldNumber)
        return result ~= nil and (result.autarkieGrad or 0) or 0
    end,

    -- Kompletter Anbauplan (Struktur siehe SeedPlanner.buildOverallPlan).
    -- Enthaelt u.a. result.autarkieGrad, result.fruitState (Liste je Frucht).
    getPlan = function(farmId)
        farmId = farmId or (g_currentMission ~= nil and g_currentMission:getFarmId())
        if farmId == nil then return nil end
        local excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, prio, releasedFieldIds, maxFieldNumber = getSavedPlanParams()
        return SeedPlanner.buildOverallPlan(farmId, excl, exclFields, minFieldSize, schnittMultiMap, allocStrategy, prio, releasedFieldIds, maxFieldNumber)
    end,

    -- Rohliste aller benoetigten Fruchtarten (Fabrik-/Stallbedarf).
    getDemand = function(farmId)
        farmId = farmId or (g_currentMission ~= nil and g_currentMission:getFarmId())
        if farmId == nil then return {} end
        return DemandScanner.getAllDemandedFillTypes(farmId)
    end,
}
