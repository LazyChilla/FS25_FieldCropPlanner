-- ============================================================
--  DemandScanner
--  Ermittelt den Jahresbedarf an Inputs:
--    - Fabriken    (Placeables mit Production-Spec)
--    - Tierstaelle  (Placeables mit Husbandry-Food-Spec)
--
--  STATUS (nach erstem In-Game-Dump verifiziert):
--   - Farm-Filter: Fabriken/Staelle werden ueber das tatsaechliche
--     owningPlaceable:getOwnerFarmId() gefiltert. Der zuvor angenommene
--     Weg ueber productionChainManager.farmIds[farmId] hat im Test NICHT
--     gefiltert (alle Punkte der Map kamen zurueck) und wurde entfernt.
--   - Tierfutter ist einfacher als urspruenglich angenommen: KEINE
--     Futtergruppen mit productionWeight, sondern eine flache Liste
--     erlaubter Fruchtarten (spec_husbandryFood.fillTypes) plus einer
--     Gesamt-Verbrauchsrate (spec_husbandryFood.litersPerHour). Die
--     tatsaechliche Mix-Gewichtung fuer volle Tierzufriedenheit liegt
--     vermutlich in g_currentMission.animalFoodSystem (animalTypeIndex-
--     abhaengig) und ist hier noch NICHT modelliert. Wir geben deshalb
--     eine Obergrenze aus, keinen exakten Anteil.
--   - prod.inputs / prod.outputs sind Arrays aus { type = fillTypeIndex,
--     amount = ... } (outputs zusaetzlich mit sellDirectly). Bestaetigt
--     per Dump an der Mehlfabrik. WICHTIG: das Feld heisst "type", nicht
--     "fillTypeIndex".
--   - Farm-Filter (owningPlaceable:getOwnerFarmId() == farmId) ist korrekt:
--     in einem SP-Save mit nur einer Farm gehoeren tatsaechlich (fast) alle
--     registrierten Produktionspunkte der eigenen Farm. Reine Verkaufs-
--     punkte ohne Rezept (z.B. Marken-Tankstellen wie ARAL) haben gar
--     keine .productions und tauchen in diesem Scan ohnehin nie auf --
--     daher kein zusaetzliches Kriterium noetig.
--   - getFactoryDemand zaehlt NUR point.activeProductions, nicht point.productions
--     (Crosscheck DispoList + eigener Dump, 20.06.): Handelspunkte wie
--     "Zentrallager *"/"GetreideEinkauf gegen Geldkassetten" haben bis zu 60
--     Productions, aber 0 aktiv -- mit productions zaehlten wir Phantom-Bedarf.
--   - point.sharedThroughputCapacity == true (bestaetigt an Gewaechshaeusern,
--     17 bzw. 3 parallele aktive Kulturen) -> Kapazitaet wird durch
--     #activeProductions geteilt, sonst 17-facher Ueberzaehler.
--   - [AUFGEHOBEN 26.07.] Produktionen mit reinem Tierfutter-Output (SILAGE,
--     Heu-Varianten) wurden frueher komplett ausgeklammert (Scope-Entscheidung
--     20.06.). Jetzt zaehlen sie wieder mit (Fermenter/Heutrocknung sind echte
--     Verbraucher von Gras/Luzerne/Klee) -- siehe TIERFUTTER_OUTPUT_NAMES unten.
--     Frueher galt: verifiziert an
--     "Hof Heutrocknung XL" (Gras/Luzerne/Klee -> Heu) und "Fermenter"
--     (Gras/Haeckselgut/Luzerne/Klee -> Silage). Haeckselgut (CHAFF) ist KEIN
--     fester Fruchtart-Filter, da es aus vielen Feldfruechten gehaeckselt
--     werden kann -- der Output-basierte Filter ist deshalb robuster als ein
--     Input-Fruchtart-Filter.
-- ============================================================

-- Fruchtarten/FillTypes, deren Produktion ausschliesslich Tierfutter erzeugt
-- (siehe Scope-Entscheidung oben). Namen statt Indizes, damit es unabhaengig
-- von der konkreten Map-FillType-Reihenfolge bleibt.
-- REVERSAL (26.07., LazyChilla): Fermenter (-> SILAGE) und Heutrocknung
-- (-> DRY*_WINDROW/Heu) sind eigene weiterverarbeitende Fabriken und sollen
-- als echte Verbraucher von Gras/Luzerne/Klee zaehlen (Leitziel: Fabrik-Input
-- aus eigenem Anbau decken). Liste jetzt LEER = kein Output-basierter
-- Ausschluss mehr. Tierstaelle (spec_husbandryFood) bleiben unabhaengig davon
-- weiter aussen vor (eigener Mechanismus getHusbandryDemand, NICHT in
-- buildOverallPlan). Mehrfachzaehlung ausgeschlossen: die Fabriken haben pro
-- Zutat eine eigene Produktionslinie mit sharedThroughputCapacity=true ->
-- die bestehende 1/#activeProductions-Teilung greift bereits.
local TIERFUTTER_OUTPUT_NAMES = {}

local function getTierfutterOutputIndices()
    local indices = {}
    for _, name in ipairs(TIERFUTTER_OUTPUT_NAMES) do
        local idx = g_fillTypeManager:getFillTypeIndexByName(name)
        if idx ~= nil then
            indices[idx] = true
        end
    end
    return indices
end

DemandScanner = {}

-- TODO verifizieren: Perioden ("Monate") pro Spieljahr sind in den
-- Savegame-Einstellungen konfigurierbar. 12 ist der Standard-Fallback.
local DEFAULT_PERIODS_PER_YEAR = 12

local function getPeriodsPerYear()
    local env = g_currentMission.environment
    if env ~= nil and env.periodsPerYear ~= nil then
        return env.periodsPerYear
    end
    return DEFAULT_PERIODS_PER_YEAR
end

--- Alle Produktionspunkte auf der Map (ungefiltert)
local function getAllProductionPoints()
    local chainManager = g_currentMission.productionChainManager
    if chainManager == nil then
        return {}
    end
    return chainManager.productionPoints or {}
end

--- Produktionspunkte einer Farm (farmId == nil -> alle auf der Map).
-- Filtert ueber das tatsaechliche owningPlaceable, nicht ueber
-- chainManager.farmIds (siehe Hinweis oben).
function DemandScanner.getProductionPoints(farmId)
    local all = getAllProductionPoints()
    if farmId == nil then
        return all
    end

    local owned = {}
    for _, point in ipairs(all) do
        local owner = point.owningPlaceable
        if owner ~= nil and owner.getOwnerFarmId ~= nil and owner:getOwnerFarmId() == farmId then
            table.insert(owned, point)
        end
    end
    return owned
end

--- Alle Tierstaelle auf der Map (ungefiltert)
local function getAllHusbandries()
    local result = {}
    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem == nil or placeableSystem.placeables == nil then
        return result
    end

    for _, placeable in ipairs(placeableSystem.placeables) do
        if placeable.spec_husbandryFood ~= nil then
            table.insert(result, placeable)
        end
    end
    return result
end

--- Tierstaelle einer Farm (farmId == nil -> alle auf der Map)
function DemandScanner.getHusbandries(farmId)
    local all = getAllHusbandries()
    if farmId == nil then
        return all
    end

    local owned = {}
    for _, husbandry in ipairs(all) do
        if husbandry.getOwnerFarmId ~= nil and husbandry:getOwnerFarmId() == farmId then
            table.insert(owned, husbandry)
        end
    end
    return owned
end

local function resolveFillTypeName(index)
    if index == nil or g_fillTypeManager == nil then
        return "?"
    end
    local ok, fillType = pcall(function() return g_fillTypeManager:getFillTypeByIndex(index) end)
    if ok and fillType ~= nil then
        return fillType.name or tostring(fillType.title) or "?"
    end
    return "?"
end

--- Baut einmalig (und gecached) ein Set aller FillType-Indizes, die die
-- PRIMAERE, eigene FillType einer echten FruitType sind (fruitTypes[i].fillType.index,
-- verifiziert per Live-Dump 21.06.: WHEAT-FruitType.fillType.index == 2 == WHEATs
-- eigener FillTypeIndex).
--
-- WICHTIG: NICHT ueber getFruitTypeByFillTypeIndex/fillTypeIndexToFruitTypeIndex
-- (Rueckwaerts-Richtung) loesen -- die ist fuer Erntenebenprodukte mehrdeutig
-- nachgewiesen (Praxis-Fund 21.06.: STRAW->getFruitTypeByFillTypeIndex liefert
-- die FruitType SUMMERBARLEY, nicht etwa STRAW selbst oder nil. Mehrere
-- Getreidearten erzeugen STRAW als Windrow-Nebenprodukt, die Rueckwaerts-
-- Tabelle speichert offenbar nur einen beliebigen Treffer davon). Die
-- Vorwaerts-Richtung (FruitType -> ihre eigene FillType) ist dagegen eindeutig.
local sowableFillTypeIndices = nil
local function getSowableFillTypeIndices()
    if sowableFillTypeIndices ~= nil then
        return sowableFillTypeIndices
    end

    sowableFillTypeIndices = {}
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.fruitTypes ~= nil then
        for _, fruitType in ipairs(g_fruitTypeManager.fruitTypes) do
            if fruitType.fillType ~= nil and fruitType.fillType.index ~= nil then
                sowableFillTypeIndices[fruitType.fillType.index] = true
            end
        end
    end
    return sowableFillTypeIndices
end

--- Baut einen Lookup: windrowFillTypeIndex -> fruitFillTypeIndex
-- Benutzt ft.windrowFillType (verifiziert per Dump 28.06.):
--   GRASS_WINDROW(28)  -> GRASS(26)
--   ALFALFA_WINDROW(193) -> ALFALFA(192)
--   CLOVER_WINDROW(197)  -> CLOVER(196)
--   MEADOW/FIELDGRASS -> GRASS_WINDROW (ebenfalls abgedeckt)
-- Kartenunabhaengig, kein Hardcoding noetig.
local windrowToFruitIndex = nil
local function getWindrowToFruitIndex()
    if windrowToFruitIndex ~= nil then
        return windrowToFruitIndex
    end
    windrowToFruitIndex = {}
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.fruitTypes ~= nil then
        for _, ft in ipairs(g_fruitTypeManager.fruitTypes) do
            if ft.windrowFillType ~= nil
            and ft.windrowFillType.index ~= nil
            and ft.fillType ~= nil
            and ft.fillType.index ~= nil then
                -- Windrow-Index -> Frucht-FillType-Index
                -- Mehrere Fruechte koennen denselben Windrow erzeugen
                -- (GRASS, MEADOW, FIELDGRASS -> alle GRASS_WINDROW).
                -- Wir behalten den mit dem hoechsten literPerSqm
                -- (relevant fuer Ertragsschaetzung).
                --
                -- AUSNAHME (Praxis-Fund 09.07., siehe gsSaatplanWindrowDump):
                -- Echte Erntenebenprodukte wie STRAW und SOYBEANSTRAW nutzen
                -- denselben windrowFillType-Mechanismus, werden aber von
                -- mehreren agronomisch VERSCHIEDENEN Fruchtarten geteilt
                -- (STRAW: Weizen/Gerste/Hafer/Dinkel/Roggen/Triticale/
                -- Sommerweizen/Sommergerste -- SOYBEANSTRAW: Ackerbohnen/
                -- Erbsen/Linsen). Eine Zuordnung zu EINER Frucht per
                -- Tie-Break waere hier immer willkuerlich/falsch -- anders
                -- als bei GRASS_WINDROW/ALFALFA_WINDROW/etc., wo es um
                -- echtes Schwad-Erntegut fuer denselben Verwendungszweck
                -- geht. Erkennung ueber Namensmuster "STRAW" statt
                -- Hardcoding einzelner Fruchtnamen -- bleibt kartenunabhaengig.
                local windrowName = ft.windrowFillType.name or ""
                if not string.find(windrowName, "STRAW") then
                    local wIdx = ft.windrowFillType.index
                    local existing = windrowToFruitIndex[wIdx]
                    if existing == nil
                    or (ft.literPerSqm or 0) > (existing.literPerSqm or 0) then
                        windrowToFruitIndex[wIdx] = {
                            fruitFillTypeIndex = ft.fillType.index,
                            literPerSqm        = ft.literPerSqm or 0,
                            fruitName          = ft.name or "?",
                        }
                    end
                end
            end
        end
    end
    return windrowToFruitIndex
end

local function isSowableFruitType(fillTypeIndex)
    return getSowableFillTypeIndices()[fillTypeIndex] == true
end

--- Gibt den saebaren Frucht-FillTypeIndex fuer einen Input-FillTypeIndex zurueck.
-- Wenn der Input selbst saebare Frucht ist -> direkt zurueck.
-- Wenn der Input ein Windrow-Produkt ist -> aufloesen via getWindrowToFruitIndex.
-- Sonst nil.
local function resolveSowableFruitIndex(fillTypeIndex)
    if isSowableFruitType(fillTypeIndex) then
        return fillTypeIndex
    end
    local lookup = getWindrowToFruitIndex()
    local entry = lookup[fillTypeIndex]
    if entry ~= nil then
        return entry.fruitFillTypeIndex
    end
    return nil
end

--- Prueft, ob ein FillType eine eigenstaendig saebare Fruchtart ist --
-- also die primaere FillType einer echten FruitType (nicht nur ein
-- Erntenebenprodukt wie STRAW, das zwar getFillTypeLiterPerSqm > 0 haben
-- kann, aber keiner FruitType als EIGENE FillType zugeordnet ist).

--- Liefert die Menge aller FillType-Indizes, die irgendeine eigene Fabrik
-- als echten Input braucht (gleiche Filter wie getFactoryDemand: nur
-- activeProductions, Silo-Pattern und reine Tierfutter-Productions
-- ausgeschlossen) UND die tatsaechlich auf einem Feld anbaubar sind
-- (g_fruitTypeManager:getFillTypeLiterPerSqm > 0). Letzteres ist wichtig:
-- Fabriken brauchen auch viele Nicht-Anbau-Inputs (WATER, DIESEL, GLASS,
-- ELECTRICCHARGE, FERTILIZER, EMPTYPALLET, ...) -- ohne diesen Filter
-- landen die als "Fruchtart mit Bedarf" in der Gesamtuebersicht, obwohl
-- kein Feld sie je liefern kann (Praxis-Fund 20.06., siehe buildOverallPlan).
-- Basis fuer die Gesamtuebersicht (gsSaatplanAlle).
-- Rueckgabe: Liste von { fillTypeIndex = ..., name = ... }, alphabetisch
-- nach Name sortiert (stabile Reihenfolge fuer die Ausgabe).
function DemandScanner.getAllDemandedFillTypes(farmId)
    local seen = {}
    local tierfutterOutputs = getTierfutterOutputIndices()

    for _, point in ipairs(DemandScanner.getProductionPoints(farmId)) do
        local activeProductions = point.activeProductions or point.productions or {}

        for _, prod in ipairs(activeProductions) do
            local outputTypes = {}
            local isTierfutterProduction = false
            for _, output in ipairs(prod.outputs or {}) do
                outputTypes[output.type] = true
                if tierfutterOutputs[output.type] then
                    isTierfutterProduction = true
                end
            end

            if not isTierfutterProduction then
                for _, input in ipairs(prod.inputs or {}) do
                    if not outputTypes[input.type] then
                        -- Direkt saebare Frucht ODER Windrow-Produkt einer Mehrschnitt-Kultur
                        local fruitIdx = resolveSowableFruitIndex(input.type)
                        if fruitIdx ~= nil then
                            seen[fruitIdx] = true
                        end
                    end
                end
            end
        end
    end

    local result = {}
    for fillTypeIndex, _ in pairs(seen) do
        table.insert(result, { fillTypeIndex = fillTypeIndex, name = resolveFillTypeName(fillTypeIndex) })
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

--- Interne Kernberechnung -- liefert Detail-Eintraege pro Fabrik (Name, Modus,
-- Betrag), gefiltert auf > 0. getFactoryDemand() (Konsole/SeedPlanner) UND
-- getFactoryDemandBreakdown() (GUI-Fabrik-Aufschluesselung im Saatplan-Tab)
-- nutzen BEIDE diese eine Funktion -- es gibt nur eine Stelle mit der
-- eigentlichen Filterlogik, kein Risiko dass beide auseinanderlaufen.
-- Fabrikname robust ermitteln: point:getName() liefert bei manchen (v.a. Mod-)
-- Fabriken einen LEEREN String -- in Lua ist "" truthy, deshalb greift ein
-- "or ..."-Fallback nicht und die Zelle bleibt leer. Fallback auf die
-- owningPlaceable (verifiziert an Giants ProductionPoint.lua: self.owningPlaceable
-- + self.name), sonst "?".
local function ppFactoryName(point)
    local nm = (point.getName ~= nil) and point:getName() or nil
    if nm ~= nil and nm ~= "" then return nm end
    local pl = point.owningPlaceable
    if pl ~= nil and pl.getName ~= nil then
        local n2 = pl:getName()
        if n2 ~= nil and n2 ~= "" then return n2 end
    end
    return "?"
end

local function computeFactoryDemandDetail(farmId, fillTypeIndex)
    local entries = {}
    local periodsPerYear = getPeriodsPerYear()
    local tierfutterOutputs = getTierfutterOutputIndices()

    for _, point in ipairs(DemandScanner.getProductionPoints(farmId)) do
        local pointTotal = 0
        local activeProductions = point.activeProductions or point.productions or {}

        local multi = 1
        if point.sharedThroughputCapacity and #activeProductions > 0 then
            multi = 1 / #activeProductions
        end

        for _, prod in ipairs(activeProductions) do
            local cyclesPerYear = (prod.cyclesPerMonth or 0) * periodsPerYear

            -- Silos/Lagerpunkte haben oft eine "Production", deren Output
            -- derselbe FillType wie der Input ist (reines Umlagern, keine
            -- echte Verarbeitung). Solche Eintraege zaehlen NICHT als
            -- Jahresbedarf, sonst wird Lagerkapazitaet faelschlich als
            -- Verbrauch interpretiert (Praxis-Fund: "Hof Silo").
            local outputTypes = {}
            local isTierfutterProduction = false
            for _, output in ipairs(prod.outputs or {}) do
                outputTypes[output.type] = true
                if tierfutterOutputs[output.type] then
                    isTierfutterProduction = true
                end
            end

            if not isTierfutterProduction then
                for _, input in ipairs(prod.inputs or {}) do
                    -- Input kann direkt der FillType sein, oder ein Windrow der
                    -- auf diese Frucht aufgeloest wird (z.B. GRASS_WINDROW -> GRASS)
                    local resolvedIdx = resolveSowableFruitIndex(input.type)
                    if resolvedIdx == fillTypeIndex and not outputTypes[fillTypeIndex] then
                        pointTotal = pointTotal + (input.amount or 0) * cyclesPerYear * multi
                    end
                end
            end
        end

        if pointTotal > 0 then
            table.insert(entries, {
                name   = ppFactoryName(point),
                amount = pointTotal,
                mode   = point.sharedThroughputCapacity and "GETEILT" or "PARALLEL",
            })
        end
    end

    table.sort(entries, function(a, b) return a.amount > b.amount end)
    return entries
end

--- Jahresbedarf (Liter) einer Fruchtart ueber alle Fabriken einer Farm.
-- Rueckgabe: { total = liter, perPoint = { [Fabrikname] = liter, ... } }
--
-- WICHTIG (verifiziert per Live-Dump am 20.06.): zwei Korrekturen eingebaut,
-- beide gegen reale Logdaten geprueft, siehe TODO Phase 1 / Crosscheck DispoList:
--  1) Nur point.activeProductions zaehlen, NICHT point.productions. Handelspunkte
--     wie "Zentrallager *" oder "GetreideEinkauf gegen Geldkassetten" haben
--     Dutzende Productions (bis zu 60), aber 0 davon aktiv -- mit productions
--     wuerden wir Phantom-Bedarf fuer nie laufende Rezepte mitzaehlen.
--     Bestaetigt: activeProductions[i] sind vollwertige Objekte mit eigenem
--     .inputs (kein Index-Umweg noetig), aber NICHT immer identisch mit
--     productions[1] (eigene, gefilterte Liste).
--  2) Wenn point.sharedThroughputCapacity == true, teilen sich alle aktiven
--     Productions EINE Gesamtkapazitaet (bestaetigt an den Gewaechshaeusern:
--     17 bzw. 3 parallele Kulturen, alle aktiv). Ohne Korrektur wuerde jede
--     einzelne Kultur mit voller Kapazitaet gezaehlt -> 17-facher Ueberzaehler.
--     Korrektur (wie DispoList): amount * cyclesPerYear * (1 / #activeProductions).
function DemandScanner.getFactoryDemand(farmId, fillTypeIndex)
    local entries = computeFactoryDemandDetail(farmId, fillTypeIndex)
    local total = 0
    local perPoint = {}
    for _, e in ipairs(entries) do
        perPoint[e.name] = e.amount
        total = total + e.amount
    end
    return { total = total, perPoint = perPoint }
end

--- Fabrik-Aufschluesselung fuer die GUI (Saatplan-Tab, Klapp-Detail "Fabriken",
-- eingefuehrt 09.07. nach dem Gerste/Stroh-Fund). Liefert nur Fabriken mit
-- tatsaechlich gezaehltem Bedarf > 0 (Sprechende Null: kein Verbraucher =
-- leere Liste, GUI zeigt dann einfach keinen Fabrik-Abschnitt).
-- Rueckgabe: { {name=Fabrikname, amount=Liter/Jahr, mode="PARALLEL"|"GETEILT"}, ... }
-- sortiert nach amount absteigend. Nutzt dieselbe Filterlogik wie
-- getFactoryDemand (siehe computeFactoryDemandDetail) -- keine Doppelpflege.
function DemandScanner.getFactoryDemandBreakdown(farmId, fillTypeIndex)
    return computeFactoryDemandDetail(farmId, fillTypeIndex)
end

--- Jahresbedarf (Liter) einer Fruchtart ueber alle Tierstaelle einer Farm.
-- WICHTIG: dies ist eine OBERGRENZE (was diese Frucht theoretisch maximal
-- beitragen KOENNTE, wenn man ausschliesslich sie verfuettern wuerde),
-- kein exakter Anteil -- die echte Mix-Gewichtung liegt im AnimalFoodSystem
-- und ist hier noch nicht modelliert (siehe Hinweis am Dateianfang).
function DemandScanner.getHusbandryDemand(farmId, fillTypeIndex)
    local total = 0
    local perHusbandry = {}

    -- TODO verifizieren gegen g_currentMission.environment (Periodenlaenge)
    local hoursPerYear = 24 * 365

    for _, husbandry in ipairs(DemandScanner.getHusbandries(farmId)) do
        local spec = husbandry.spec_husbandryFood

        if spec ~= nil and spec.litersPerHour ~= nil and spec.fillTypes ~= nil then
            for _, ft in ipairs(spec.fillTypes) do
                if ft == fillTypeIndex then
                    local maxAnnual = spec.litersPerHour * hoursPerYear
                    total = total + maxAnnual
                    perHusbandry[husbandry:getName()] = maxAnnual
                    break
                end
            end
        end
    end

    return { total = total, perHusbandry = perHusbandry, isUpperBound = true }
end

--- Diagnose: Zeigt die komplette windrowFillType-Zuordnung aller FruitTypes,
-- inkl. wer bei mehrfacher Zuordnung (z.B. STRAW) den Lookup-Eintrag
-- "gewinnt" (hoechster literPerSqm gewinnt, siehe getWindrowToFruitIndex).
-- Hintergrund/Verdacht (09.07.): FS25 nutzt windrowFillType offenbar nicht
-- nur fuer echte Schwad-Fruechte (Gras/Luzerne/Klee), sondern moeglicherweise
-- auch fuer Stroh als Erntenebenprodukt von Getreide -- das wuerde erklaeren
-- warum Stroh-Verbrauch (Komposter, Ballenlager, Textilfabrik...) faelschlich
-- als Gerste-Bedarf gezaehlt wird (siehe gsSaatplanCheck BARLEY, 09.07.).
-- Reine Ausgabe, keine Aenderung an der echten Rechenlogik.
function DemandScanner.debugWindrowDump()
    print("===== Saatplan Windrow-Zuordnung (alle FruitTypes mit windrowFillType) =====")
    if g_fruitTypeManager == nil or g_fruitTypeManager.fruitTypes == nil then
        print("g_fruitTypeManager nicht verfuegbar")
        return
    end

    print("--- Rohliste: jede FruitType, die ueberhaupt windrowFillType gesetzt hat ---")
    for _, ft in ipairs(g_fruitTypeManager.fruitTypes) do
        if ft.windrowFillType ~= nil and ft.windrowFillType.index ~= nil then
            print(string.format("  %s (fillTypeIndex=%s) -> windrowFillType=%s (index=%s), literPerSqm=%s",
                tostring(ft.name),
                tostring(ft.fillType and ft.fillType.index),
                tostring(ft.windrowFillType.name),
                tostring(ft.windrowFillType.index),
                tostring(ft.literPerSqm)))
        end
    end

    print("--- Ergebnis nach Tie-Break (hoechster literPerSqm gewinnt pro Windrow-Index) ---")
    local lookup = getWindrowToFruitIndex()
    for wIdx, entry in pairs(lookup) do
        local windrowFtName = "?"
        if g_fillTypeManager ~= nil then
            local windrowFt = g_fillTypeManager:getFillTypeByIndex(wIdx)
            if windrowFt ~= nil then
                windrowFtName = windrowFt.name
            end
        end
        print(string.format("  %s (index=%s) -> wird aufgeloest zu: %s (fruitFillTypeIndex=%s, literPerSqm=%s)",
            tostring(windrowFtName), tostring(wIdx),
            tostring(entry.fruitName), tostring(entry.fruitFillTypeIndex), tostring(entry.literPerSqm)))
    end
    print("===== ENDE Windrow-Zuordnung =====")
end

--- Diagnose fuer GENAU EINE Fruchtart: zeigt fuer jede Fabrik, die diese
-- Frucht ueberhaupt irgendwo als Input hat, ob sie PARALLEL (jede aktive
-- Linie zaehlt mit voller Kapazitaet) oder GETEILT (sharedThroughputCapacity
-- == true, Kapazitaet wird durch #activeProductions geteilt) rechnet, WELCHE
-- Linie(n) tatsaechlich aktiv sind (point.activeProductions, NICHT die
-- Rohliste point.productions!) und ob/warum eine Linie gezaehlt oder
-- ausgeschlossen wird (Tierfutter-Filter, Silo-Schleife). Spiegelt exakt
-- die Filterlogik aus getFactoryDemand/getAllDemandedFillTypes -- baut keine
-- keine eigene Rechenlogik, damit das Ergebnis konsistent mit dem Saatplan-Tab ist.
-- Zusaetzlich: Tierstall-Bedarf separat (zur Kontrolle), mit dem expliziten
-- Hinweis dass dieser laut Scope-Entscheidung (20.06.) NICHT in
-- buildOverallPlan/buildPlanForFruitType einfliesst.
function DemandScanner.debugFruitCheck(farmId, fillTypeName)
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    if fillTypeIndex == nil then
        print(string.format("[Saatplan-Check] Unbekannte Fruchtart/FillType: '%s'", tostring(fillTypeName)))
        return
    end

    print(string.format("===== Saatplan Fruchtart-Check: %s (fillTypeIndex=%d, farmId=%s) =====",
        tostring(fillTypeName), fillTypeIndex, tostring(farmId)))

    local periodsPerYear = getPeriodsPerYear()
    local tierfutterOutputs = getTierfutterOutputIndices()
    print(string.format("periodsPerYear=%s (Fallback 12, falls Savegame-Wert nicht lesbar)", tostring(periodsPerYear)))

    -- ===== Fabriken =====
    local factoryTotal = 0
    print("--- Fabriken (nur solche, die diese Frucht irgendwo als Input listen) ---")
    for _, point in ipairs(DemandScanner.getProductionPoints(farmId)) do
        local activeProductions = point.activeProductions or point.productions or {}
        local totalProductions = point.productions or {}

        -- Erst pruefen ob diese Fabrik ueberhaupt relevant ist (verhindert
        -- Log-Spam ueber alle eigenen Fabriken) -- dazu ALLE Productions
        -- durchsuchen (auch inaktive), nur zur Vorauswahl fuer die Anzeige.
        local mightBeRelevant = false
        for _, prod in ipairs(totalProductions) do
            for _, input in ipairs(prod.inputs or {}) do
                if resolveSowableFruitIndex(input.type) == fillTypeIndex then
                    mightBeRelevant = true
                    break
                end
            end
            if mightBeRelevant then break end
        end

        if mightBeRelevant then
            print(string.format("Fabrik: %s | sharedThroughputCapacity=%s | #productions=%d | #activeProductions=%d",
                point:getName(), tostring(point.sharedThroughputCapacity), #totalProductions, #activeProductions))

            if point.sharedThroughputCapacity then
                print(string.format("  -> GETEILT: alle aktiven Linien teilen sich EINE Kapazitaet (Faktor 1/%d)",
                    math.max(#activeProductions, 1)))
            else
                print("  -> PARALLEL: jede aktive Linie zaehlt mit voller eigener Kapazitaet")
            end

            local multi = 1
            if point.sharedThroughputCapacity and #activeProductions > 0 then
                multi = 1 / #activeProductions
            end

            if #activeProductions == 0 then
                print("  (keine einzige Production aktuell aktiv -- Frucht kommt hier NICHT in den Bedarf)")
            end

            for i, prod in ipairs(activeProductions) do
                local cyclesPerYear = (prod.cyclesPerMonth or 0) * periodsPerYear

                local outputTypes = {}
                local isTierfutterProduction = false
                for _, output in ipairs(prod.outputs or {}) do
                    outputTypes[output.type] = true
                    if tierfutterOutputs[output.type] then
                        isTierfutterProduction = true
                    end
                end

                for _, input in ipairs(prod.inputs or {}) do
                    local resolvedIdx = resolveSowableFruitIndex(input.type)
                    if resolvedIdx == fillTypeIndex then
                        local reason
                        if isTierfutterProduction then
                            reason = "AUSGESCHLOSSEN (reine Tierfutter-Production)"
                        elseif outputTypes[fillTypeIndex] then
                            reason = "AUSGESCHLOSSEN (Silo-Schleife: Input=Output gleiche Frucht)"
                        else
                            local amount = (input.amount or 0) * cyclesPerYear * multi
                            factoryTotal = factoryTotal + amount
                            reason = string.format("GEZAEHLT: %.0f L/Jahr", amount)
                        end
                        print(string.format("  [aktiv #%d] %s, cyclesPerMonth=%s, Input-Menge=%s -> %s",
                            i, tostring(prod.name), tostring(prod.cyclesPerMonth), tostring(input.amount), reason))
                    end
                end
            end
        end
    end
    print(string.format("=> Fabrik-Gesamtbedarf (das fliesst tatsaechlich in den Saatplan ein): %.0f L/Jahr", factoryTotal))

    -- ===== Tierstaelle (Scope-Entscheidung 20.06.: NICHT im Saatplan-Bedarf) =====
    print("--- Tierstaelle (Scope-Entscheidung 20.06.: NICHT im Saatplan-Bedarf enthalten, nur zur Kontrolle) ---")
    local husbandryDemand = DemandScanner.getHusbandryDemand(farmId, fillTypeIndex)
    local anyHusbandry = false
    for name, amount in pairs(husbandryDemand.perHusbandry) do
        anyHusbandry = true
        print(string.format("  %s: %.0f L/Jahr (Obergrenze: volle litersPerHour * 8760h, keine echte Mix-Gewichtung)", name, amount))
    end
    if not anyHusbandry then
        print("  (kein Stall erlaubt diese Frucht als Futter)")
    end
    print(string.format("=> Tierstall-Obergrenze gesamt: %.0f L/Jahr -- fliesst NICHT in buildOverallPlan/buildPlanForFruitType ein", husbandryDemand.total))

    print(string.format("===== ENDE Check %s =====", tostring(fillTypeName)))
end

--- Debug: zeigt Map-Gesamtzahl vs. eigene Anzahl (damit der Farm-Filter
-- sichtbar pruefbar ist) und dumpt die Rohstruktur jeder eigenen Fabrik/
-- jedes eigenen Stalls.

function DemandScanner.debugDump(farmId)
    print(string.format("===== Saatplan Debug Dump (farmId=%s) =====", tostring(farmId)))

    -- Diagnose (21.06.): getFruitTypeIndexFromFillTypeIndex existiert in dieser
    -- FS25-Version nicht (siehe Warnung in gsSaatplanAlle). Ziel hier: die echte
    -- Struktur von g_fruitTypeManager finden, um STRAW/CHAFF zuverlaessig als
    -- "kein eigener Anbau" zu erkennen, ohne weiter zu raten.
    print(string.format("=== Anbaubare Fruchtarten erkannt: %d (von %d FruitTypes auf der Map) ===",
        (function()
            local count = 0
            for _ in pairs(getSowableFillTypeIndices()) do count = count + 1 end
            return count
        end)(),
        g_fruitTypeManager ~= nil and g_fruitTypeManager.fruitTypes ~= nil and #g_fruitTypeManager.fruitTypes or 0))

    local allPoints = getAllProductionPoints()
    local ownPoints = DemandScanner.getProductionPoints(farmId)
    print(string.format("Produktionspunkte Map gesamt: %d | davon eigene: %d", #allPoints, #ownPoints))

    for _, point in ipairs(ownPoints) do
        local ownerFarmId = "?"
        if point.owningPlaceable ~= nil and point.owningPlaceable.getOwnerFarmId ~= nil then
            ownerFarmId = tostring(point.owningPlaceable:getOwnerFarmId())
        end

        print(string.format("--- Fabrik: %s (ownerFarmId=%s) ---", point:getName(), ownerFarmId))

        -- Diagnose fuer sharedThroughputCapacity (noch unverifiziert, siehe TODO Phase 1):
        -- rein lesend, keine Rechenlogik geaendert. Ziel: pruefen ob/wie oft dieses
        -- Feld bei unseren eigenen Fabriken ueberhaupt vorkommt und ob activeProductions
        -- sich von productions unterscheidet.
        local activeCount = "n/a"
        if point.activeProductions ~= nil then
            activeCount = tostring(#point.activeProductions)
        end
        print(string.format("    [Diagnose] sharedThroughputCapacity=%s | #productions=%d | #activeProductions=%s",
            tostring(point.sharedThroughputCapacity), #(point.productions or {}), activeCount))

        for i, prod in ipairs(point.productions or {}) do
            print(string.format("  Production %d (%s), cyclesPerMonth=%s, cyclesPerHour=%s",
                i, tostring(prod.name), tostring(prod.cyclesPerMonth), tostring(prod.cyclesPerHour)))
            for _, input in ipairs(prod.inputs or {}) do
                print(string.format("    Input:  type=%s (%s)  amount=%s", tostring(input.type), resolveFillTypeName(input.type), tostring(input.amount)))
            end
            for _, output in ipairs(prod.outputs or {}) do
                print(string.format("    Output: type=%s (%s)  amount=%s", tostring(output.type), resolveFillTypeName(output.type), tostring(output.amount)))
            end
        end
    end

    local allHusbandries = getAllHusbandries()
    local ownHusbandries = DemandScanner.getHusbandries(farmId)
    print(string.format("Tierstaelle Map gesamt: %d | davon eigene: %d", #allHusbandries, #ownHusbandries))
    print("  (Hinweis: Staelle werden NICHT mehr in den Saatplan-Bedarf eingerechnet,")
    print("   Scope-Entscheidung vom 20.06., siehe TODO_Saatplan.md. Liste unten nur informativ.)")

    for _, husbandry in ipairs(ownHusbandries) do
        local ownerFarmId = "?"
        if husbandry.getOwnerFarmId ~= nil then
            ownerFarmId = tostring(husbandry:getOwnerFarmId())
        end

        local spec = husbandry.spec_husbandryFood
        print(string.format("--- Stall: %s (ownerFarmId=%s) litersPerHour=%s ---",
            husbandry:getName(), ownerFarmId, spec ~= nil and tostring(spec.litersPerHour) or "?"))

        if spec ~= nil and spec.fillTypes ~= nil then
            for _, ft in ipairs(spec.fillTypes) do
                print(string.format("    Erlaubt: type=%s (%s)", tostring(ft), resolveFillTypeName(ft)))
            end
        end
    end
end

--- Diagnose (11.07., Praxis-Fund): zeigt fuer JEDE Fruchtart den rohen
-- seedUsagePerSqm-Wert aus g_fruitTypeManager plus den daraus berechneten
-- Liter/ha-Bedarf (seedUsagePerSqm * 10000) -- zum direkten Gegenchecken,
-- ob ein einzelner Wert (z.B. LINSEED) unplausibel hoch ist, oder ob die
-- Formel/Feldflaeche stimmt und die Abweichung woanders herkommt (z.B.
-- Saemaschinen-Kalibrierung im Spiel, die wir aus FruitTypeManager gar
-- nicht auslesen koennen). Reine Ausgabe, keine Aenderung an der Rechenlogik.
function DemandScanner.debugSeedRateDump()
    print("===== Saatplan Saatgut-Rate-Check: seedUsagePerSqm je Fruchtart =====")
    if g_fruitTypeManager == nil or g_fruitTypeManager.fruitTypes == nil then
        print("g_fruitTypeManager nicht verfuegbar")
        return
    end

    local rows = {}
    for _, ft in ipairs(g_fruitTypeManager.fruitTypes) do
        if ft.seedUsagePerSqm ~= nil then
            table.insert(rows, {
                name = ft.name or "?",
                seedUsagePerSqm = ft.seedUsagePerSqm,
                literPerHa = ft.seedUsagePerSqm * 10000,
            })
        end
    end

    table.sort(rows, function(a, b) return a.literPerHa > b.literPerHa end)

    for _, row in ipairs(rows) do
        print(string.format("  %-20s seedUsagePerSqm=%.6f  ->  %.1f L/ha", row.name, row.seedUsagePerSqm, row.literPerHa))
    end
    print("===== ENDE Saatgut-Rate-Check =====")
end

---------------------------------------------------------------------------
-- Saatgut-Berechnungen (hierher verschoben aus InGameMenuSP.lua, damit
-- SeedPlanner.lua und der g_farmCore-Export Zugriff haben ohne den Tab
-- geoeffnet haben zu muessen -- archi.md-Anforderung 14.07.)
---------------------------------------------------------------------------

--- Reale Saatgut-Richtwerte in L/ha, ermittelt aus mehreren oeffentlichen
-- Agrarquellen (Landwirtschaftskammer NRW, LfL Bayern u.a.).
-- Umgerechnet von kg/ha -> L/ha mit fruchtspezifischen Schuettdichten.
-- Nur als Orientierung -- tatsaechlicher Verbrauch haengt von Sorte,
-- Saatzeit und Bodenbedingungen ab. Fehlende Werte (nil): keine sinnvolle
-- L/ha-Angabe moeglich (Pillensaat, Pflanzknolle, vegetative Vermehrung)
-- oder keine verlaessliche Quellenangabe gefunden.
DemandScanner.REAL_SEED_L_HA = {
    WHEAT         = 220,  SUMMERWHEAT   = 240,
    BARLEY        = 250,  SUMMERBARLEY  = 260,
    OAT           = 260,  RYE           = 160,
    TRITICALE     = 250,  SPELT         = 265,
    CANOLA        = 5,    SUNFLOWER     = 15,    LINSEED  = 70,
    SOYBEAN       = 140,  BEANS         = 290,   PEAS     = 250,  PEA = 250,
    POTATO        = 1540, SUGARBEET     = nil,   BEETROOT = nil,
    MAIZE         = 28,   SORGHUM       = 25,
    HEMP          = 60,   COTTON        = 70,
    GRASS         = 90,   MEADOW        = 90,    FIELDGRASS = 90,
    ALFALFA       = 55,   CLOVER        = 50,
    MUSTARD       = 18,   BUCKWHEAT     = 115,   POPPY    = 15,
    RICE          = 160,  RICELONGGRAIN = 170,
    CARROT        = 8,    ONION         = 12,    SPINACH  = 30,
    LAVENDER      = 20,   LENTILS       = 100,
    TOBACCO       = nil,  GRAPE         = nil,   OLIVE    = nil,
    POPLAR        = nil,  SUGARCANE     = nil,
}

--- Realer Saatgut-Richtwert (L/ha) per FillType-Index, nil wenn unbekannt.
-- Nutzt Vorwaerts-Lookup (fruitType.fillType.index == fillTypeIndex) --
-- getFruitTypeByIndex() wuerde den falschen Index-Nummernkreis verwenden.
function DemandScanner.getRealSeedLHa(fillTypeIndex)
    if fillTypeIndex == nil or g_fruitTypeManager == nil then return nil end
    for _, ft in ipairs(g_fruitTypeManager.fruitTypes) do
        if ft.fillType ~= nil and ft.fillType.index == fillTypeIndex then
            return DemandScanner.REAL_SEED_L_HA[ft.name]
        end
    end
    return nil
end

--- Spielwert Saatgutbedarf in Litern fuer gegebene Flaeche.
-- seedUsagePerSqm aus fruitType (Vorwaerts-Lookup), nicht getFillTypeLiterPerSqm
-- (das waere der Ertragswert, nicht der Saatgutbedarf).
function DemandScanner.calcSeedLiter(fillTypeIndex, areaHa)
    if fillTypeIndex == nil or areaHa == nil or g_fruitTypeManager == nil then return 0 end
    for _, ft in ipairs(g_fruitTypeManager.fruitTypes) do
        if ft.fillType ~= nil and ft.fillType.index == fillTypeIndex then
            return (ft.seedUsagePerSqm or 0) * areaHa * 10000
        end
    end
    return 0
end
