-- ============================================================
--  SeedPlanner
--  Verbindet Bedarf (DemandScanner) und Angebot (FieldScanner) zu
--  einem konkreten Saatplan: welche eigenen Felder ansaeen, bis der
--  Jahresbedarf der Fabriken/Staelle fuer eine Fruchtart gedeckt ist.
-- ============================================================

SeedPlanner = {}

local function printTopContributors(label, table_, limit)
    local entries = {}
    for name, value in pairs(table_ or {}) do
        table.insert(entries, { name = name, value = value })
    end
    table.sort(entries, function(a, b) return a.value > b.value end)

    if #entries == 0 then
        return
    end

    print(string.format("  Top-Beitragende (%s):", label))
    for i = 1, math.min(limit, #entries) do
        print(string.format("    %s: %.0f L/Jahr", entries[i].name, entries[i].value))
    end
end

--- Best-Fit-Auswahl: waehlt das am besten passende Feld fuer den Restbedarf.
-- Statt immer das groesste Feld zu nehmen (Greedy/First-Fit), wird geprueft
-- ob ein kleineres Feld den Restbedarf ohne grosse Verschwendung deckt.
-- Drei Faelle in Prioritaet:
--   1. "Perfektes Feld": yield liegt zwischen restBedarf und restBedarf*1.3
--      -> kleinstes davon nehmen (minimale Verschwendung, Feld passt fast exakt)
--   2. "Zu kleines Feld": yield < restBedarf, aber kein perfektes gefunden
--      -> groesstes davon nehmen (naechster Schritt Richtung Ziel)
--   3. "Nur grosse Felder verfuegbar": alle yields > restBedarf*1.3
--      -> kleinstes davon nehmen (kleinste Verschwendung unter den zu grossen)
-- Konsequenz: statt ein 89ha Zuckerrueben-Feld zu nehmen wenn noch 5ha
-- Bedarf uebrig ist, wird ein passendes kleines Feld gesucht.
local function bestFitPick(remaining, restBedarf)
    local perfect   = nil  -- yield zwischen restBedarf und restBedarf*1.3
    local tooSmall  = nil  -- yield < restBedarf, groesstes davon
    local tooLarge  = nil  -- yield > restBedarf*1.3, kleinstes davon

    for _, fe in ipairs(remaining) do
        local y = fe.yield
        if y >= restBedarf and y <= restBedarf * 1.3 then
            -- Perfekter Treffer: kleinstes perfektes Feld bevorzugen
            if perfect == nil or y < perfect.yield then
                perfect = fe
            end
        elseif y < restBedarf then
            -- Zu klein: groesstes nehmen (naechster Schritt)
            if tooSmall == nil or y > tooSmall.yield then
                tooSmall = fe
            end
        else
            -- Zu gross (y > restBedarf*1.3): kleinstes nehmen
            if tooLarge == nil or y < tooLarge.yield then
                tooLarge = fe
            end
        end
    end

    -- Prioritaet: perfekt > tooSmall > tooLarge
    return perfect or tooSmall or tooLarge
end

function SeedPlanner.buildPlanForFruitType(farmId, fillTypeName)
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    if fillTypeIndex == nil then
        return { error = string.format("Unbekannte Fruchtart/Fuelltyp: '%s'", fillTypeName) }
    end

    -- Bewusste Scope-Entscheidung (20.06.): Tierstall-Bedarf nicht eingerechnet.
    local factoryDemand = DemandScanner.getFactoryDemand(farmId, fillTypeIndex)
    local totalDemand = factoryDemand.total

    local candidates = FieldScanner.getAvailableFieldsSorted(farmId, fillTypeIndex, "optimistic")

    -- Best-Fit-Algorithmus: Pool schrumpft mit jeder Zuteilung.
    -- Solange Restbedarf > 0 und noch Felder vorhanden:
    --   Waehle das am besten passende Feld (nicht blind das groesste).
    local remaining = {}
    for _, fe in ipairs(candidates) do
        table.insert(remaining, fe)
    end

    local plan = {}
    local covered = 0

    while #remaining > 0 and (covered < totalDemand or totalDemand <= 0) do
        local restBedarf = math.max(0, totalDemand - covered)
        local pick = bestFitPick(remaining, restBedarf)
        if pick == nil then break end

        -- Gewaehlt: aus Pool entfernen
        for i, fe in ipairs(remaining) do
            if fe == pick then
                table.remove(remaining, i)
                break
            end
        end

        table.insert(plan, pick)
        covered = covered + pick.yield

        if totalDemand <= 0 then break end
    end

    return {
        fillTypeName   = fillTypeName,
        fillTypeIndex  = fillTypeIndex,
        totalDemand    = totalDemand,
        factoryDemand  = factoryDemand,
        candidateCount = #candidates,
        plan           = plan,
        covered        = covered,
        sufficient     = covered >= totalDemand
    }
end

--- Gesamtuebersicht: verteilt alle eigenen freien Felder auf alle
-- Fruchtarten, die irgendeine eigene Fabrik braucht, mit dem Ziel den
-- Gesamt-Autarkiegrad zu maximieren (Phase 2, siehe TODO_Saatplan.md).
--
-- Algorithmus (Greedy, kein exaktes Optimum -- siehe TODO-Begruendung):
--   Wiederhole bis alle Felder verteilt oder aller Bedarf gedeckt:
--     1. Finde die Fruchtart, die laut gewaehlter allocStrategy dran ist
--        (siehe unten, 10.07. Einstellungs-Tab)
--     2. Nimm dafuer das ertragsstaerkste noch freie Feld fuer GENAU
--        diese Fruchtart
--     3. Weise zu, Feld ist danach belegt (fuer alle anderen Fruchtarten
--        nicht mehr verfuegbar)
-- Jedes Feld kann nur einer Fruchtart zugewiesen werden, das ist hier
-- ueber den gemeinsamen, schrumpfenden Pool freier Felder geloest.
--
-- allocStrategy (10.07., Einstellungs-Tab, LazyChilla-Wunsch):
--   "absolut" (Default, bisheriges Verhalten) -- Frucht mit dem groessten
--     NOCH UNGEDECKTEN Bedarf in LITERN zuerst. Maximiert den Gesamt-
--     Autarkiegrad in Litern ueber alle Fruechte, kann aber kleine
--     Fruchtarten (wenig Gesamtbedarf) leer ausgehen lassen, wenn grosse
--     Fruchtarten immer wieder den groesseren absoluten Rest haben.
--   "prozent" -- Frucht mit der groessten PROZENTUALEN Deckungsluecke
--     zuerst (wer prozentual am weitesten hinten liegt, kommt zuerst dran).
--     Fairer gegenueber kleinen Fruchtarten, maximiert aber nicht mehr
--     zwingend den Gesamt-Autarkiegrad in Litern.
--   "reihum" -- jede noch unterversorgte Fruchtart bekommt abwechselnd
--     ein Feld, in fester Reihenfolge der Fruchtliste, bis alle gleich
--     weit sind oder keine Felder mehr da sind.
-- Feld-ID robust ermitteln (farmland.field.fieldId, Fallback: Nummer aus Label)
local function spGetFieldId(fe)
    if fe == nil then return nil end
    if fe.field ~= nil and fe.field.farmland ~= nil then
        local f = fe.field.farmland.field
        if f ~= nil and f.fieldId ~= nil then return f.fieldId end
    end
    if fe.label ~= nil then return tonumber(fe.label:match("%d+")) end
    return nil
end

function SeedPlanner.buildOverallPlan(farmId, excludedSet, excludedFieldIds, minFieldSize, schnittMultiMap, allocStrategy, priorityFillTypeIndex, releasedFieldIds, maxFieldNumber)
    allocStrategy = allocStrategy or "absolut"
    local demandedFillTypes = DemandScanner.getAllDemandedFillTypes(farmId)

    -- Pro Fruchtart: Gesamtbedarf + bereits gedeckte Menge.
    local fruitState = {}
    local totalDemandAll = 0
    for _, ft in ipairs(demandedFillTypes) do
        -- Ausgefilterte Fruechte (aus ESC-Tab Filter) nicht beruecksichtigen
        if excludedSet == nil or not excludedSet[ft.fillTypeIndex] then
            local demand = DemandScanner.getFactoryDemand(farmId, ft.fillTypeIndex)
            if demand.total > 0 then
                table.insert(fruitState, {
                    fillTypeIndex = ft.fillTypeIndex,
                    name = ft.name,
                    demand = demand.total,
                    covered = 0,
                    assignedFields = {}
                })
                totalDemandAll = totalDemandAll + demand.total
            end
        end
    end

    -- Bereits gesaete Felder als Startwert in covered einrechnen.
    -- Sonst wuerde der Algorithmus bei z.B. Dinkel (205% durch gesaete Felder)
    -- trotzdem noch ein freies Feld zuteilen -- der Bedarf ist ja schon gedeckt.

    -- Hilfsfunktion: schnittMulti fuer eine Frucht lesen (muss VOR dem ersten
    -- Aufruf definiert sein -- Lua-lokale Funktionen sind erst nach Definition
    -- sichtbar, nicht wie in anderen Sprachen gehoisted)
    local function getMulti(fruitName)
        return schnittMultiMap ~= nil and (schnittMultiMap[fruitName] or 1) or 1
    end

    local allFields = FieldScanner.getAllOwnedFields(farmId)
    for _, fe in ipairs(allFields) do
        if fe.isSown and fe.fruitName ~= nil then
            local fid = spGetFieldId(fe)
            local isReleased = releasedFieldIds ~= nil and fid ~= nil and releasedFieldIds[fid]
            if not isReleased then
                for _, fs in ipairs(fruitState) do
                    if fs.name == fe.fruitName then
                        local y = FieldScanner.estimateYield(fe, fs.fillTypeIndex, "optimistic")
                        local multi = getMulti(fs.name)
                        fs.covered = fs.covered + y * multi
                        break
                    end
                end
            end
        end
    end

    -- "Vorher"-Deckung festhalten: Stand NUR aus aktuell gesaeten Feldern,
    -- BEVOR die Saatvorschlaege freie/freigegebene Felder zuteilen. Die GUI
    -- zeigt das als "Quote" (aktuell); fs.covered waechst danach zu "Danach"
    -- (wenn man den Vorschlaegen folgt).
    for _, fs in ipairs(fruitState) do
        fs.coveredBase = fs.covered
    end

    -- Gemeinsamer, schrumpfender Pool freier Felder (jedes Feld nur einmal vergebbar).
    local remainingFields = FieldScanner.getUnsownFields(farmId)
    -- Freigegebene (physisch besaete) Felder wie freie Felder behandeln:
    -- in den Pool legen, damit sie Luecken-Fruechten zugewiesen werden koennen.
    if releasedFieldIds ~= nil and next(releasedFieldIds) ~= nil then
        for _, fe in ipairs(allFields) do
            if fe.isSown and fe.fruitName ~= nil then
                local fid = spGetFieldId(fe)
                if fid ~= nil and releasedFieldIds[fid] then
                    remainingFields[#remainingFields + 1] = fe
                end
            end
        end
    end
    -- Feldausschluss: manuell ausgeschlossene Felder und Mindestgroesse herausfiltern
    if excludedFieldIds ~= nil or (minFieldSize ~= nil and minFieldSize > 0) or (maxFieldNumber ~= nil and maxFieldNumber > 0) then
        local filtered = {}
        for _, fe in ipairs(remainingFields) do
            local fieldId = nil
            if fe.field ~= nil and fe.field.farmland ~= nil then
                local f = fe.field.farmland.field
                if f ~= nil then fieldId = f.fieldId end
            end
            -- Fallback: Nummer aus Label lesen (z.B. "Feld 4" -> 4), gleiche
            -- Logik wie in der GUI (InGameMenuSP.lua buildFieldData) -- wichtig
            -- weil farmland.field.fieldId in manchen Faellen nil liefert
            if fieldId == nil and fe.label ~= nil then
                fieldId = tonumber(fe.label:match("%d+"))
            end
            local isExcluded = fieldId ~= nil and excludedFieldIds ~= nil and excludedFieldIds[fieldId]
            local isTooSmall = minFieldSize ~= nil and minFieldSize > 0 and fe.areaHa < minFieldSize
            -- Feld-Cutoff (v78): Felder ab Nummer N raus (gleiche Feld-ID-Logik)
            local isAboveCut = maxFieldNumber ~= nil and maxFieldNumber > 0 and fieldId ~= nil and fieldId >= maxFieldNumber
            if not isExcluded and not isTooSmall and not isAboveCut then
                table.insert(filtered, fe)
            end
        end
        remainingFields = filtered
    end
    local assignmentOrder = {}
    local blocked = {} -- Fruchtarten, fuer die kein verbleibendes Feld Ertrag > 0 liefert
    local roundRobinIndex = 0 -- nur fuer allocStrategy == "reihum"

    -- Phase 0 (optional): Wenn eine Frucht explizit auf 100% erzwungen wird
    -- (UI-Button "Auf 100% auffuellen"), bekommt sie zuerst alle Felder die
    -- sie braucht -- bevor die normale Zuteilungsschleife startet. Nutzt
    -- exakt denselben Best-Fit-Mechanismus wie Phase 1, keine Sonderlogik.
    if priorityFillTypeIndex ~= nil then
        for _, fs in ipairs(fruitState) do
            if fs.fillTypeIndex == priorityFillTypeIndex and fs.demand > 0 and fs.covered < fs.demand then
                while #remainingFields > 0 and fs.covered < fs.demand do
                    local restBedarf = math.max(0, fs.demand - fs.covered)
                    local multi = getMulti(fs.name)
                    local fieldsWithYield = {}
                    for _, fieldEntry in ipairs(remainingFields) do
                        local y = FieldScanner.estimateYield(fieldEntry, fs.fillTypeIndex, "optimistic") * multi
                        if y > 0 then
                            table.insert(fieldsWithYield, { fieldEntry = fieldEntry, yield = y })
                        end
                    end
                    if #fieldsWithYield == 0 then break end
                    -- Best-Fit: perfekt passendes Feld bevorzugen (bis 130% des Restbedarfs),
                    -- dann kleinstes ertragreiches, dann kleinstes ueberdimensioniertes.
                    local bestPerfect, bestSmall, bestLarge = nil, nil, nil
                    for _, fw in ipairs(fieldsWithYield) do
                        local y = fw.yield
                        if y >= restBedarf and y <= restBedarf * 1.3 then
                            if bestPerfect == nil or y < bestPerfect.yield then bestPerfect = fw end
                        elseif y < restBedarf then
                            if bestSmall == nil or y > bestSmall.yield then bestSmall = fw end
                        else
                            if bestLarge == nil or y < bestLarge.yield then bestLarge = fw end
                        end
                    end
                    local best = bestPerfect or bestSmall or bestLarge
                    for i, fe in ipairs(remainingFields) do
                        if fe == best.fieldEntry then table.remove(remainingFields, i); break end
                    end
                    fs.covered = fs.covered + best.yield
                    local areaHa = best.fieldEntry.areaHa or 0
                    table.insert(fs.assignedFields, {
                        fieldEntry     = best.fieldEntry,
                        yield          = best.yield,
                        seedLiterSpiel = DemandScanner.calcSeedLiter(fs.fillTypeIndex, areaHa),
                        seedLiterReal  = DemandScanner.getRealSeedLHa(fs.fillTypeIndex) and
                                         DemandScanner.getRealSeedLHa(fs.fillTypeIndex) * areaHa or nil,
                    })
                    table.insert(assignmentOrder, { fillTypeName = fs.name, fieldEntry = best.fieldEntry, yield = best.yield })
                end
                break
            end
        end
    end

    while #remainingFields > 0 do
        -- Schritt 1: Fruchtart auswaehlen, die laut gewaehlter Strategie
        -- als naechstes ein Feld bekommt (geblockte Fruchtarten werden
        -- uebersprungen, siehe unten).
        local target = nil

        if allocStrategy == "prozent" then
            -- Groesste PROZENTUALE Deckungsluecke zuerst (wer prozentual
            -- am weitesten hinten liegt, kommt zuerst dran).
            local worstPct = 1.0 -- 1.0 = 100% gedeckt, keine Luecke
            for _, fs in ipairs(fruitState) do
                if fs.demand > 0 and not blocked[fs.fillTypeIndex] and fs.covered < fs.demand then
                    local pct = fs.covered / fs.demand
                    if pct < worstPct then
                        worstPct = pct
                        target = fs
                    end
                end
            end

        elseif allocStrategy == "reihum" then
            -- Reihum: naechste noch unterversorgte Fruchtart ab
            -- roundRobinIndex suchen (feste Reihenfolge der Fruchtliste).
            local n = #fruitState
            for step = 1, n do
                local idx = ((roundRobinIndex + step - 1) % n) + 1
                local fs = fruitState[idx]
                if fs.covered < fs.demand and not blocked[fs.fillTypeIndex] then
                    target = fs
                    roundRobinIndex = idx
                    break
                end
            end

        else
            -- "absolut" (Default, bisheriges Verhalten): groesster
            -- NOCH UNGEDECKTER Bedarf in Litern zuerst.
            local biggestGap = 0
            for _, fs in ipairs(fruitState) do
                local gap = fs.demand - fs.covered
                if gap > biggestGap and not blocked[fs.fillTypeIndex] then
                    biggestGap = gap
                    target = fs
                end
            end
        end

        if target == nil then
            break -- aller (nicht geblockter) Bedarf gedeckt, restliche Felder bleiben frei
        end

        -- Schritt 2: Best-Fit-Feld fuer GENAU diese Fruchtart finden.
        -- Erst Ertraege fuer alle verbleibenden Felder berechnen,
        -- dann bestFitPick anwenden (nicht blind das groesste nehmen).
        local restBedarf = math.max(0, target.demand - target.covered)
        local multi = getMulti(target.name)
        local fieldsWithYield = {}
        for _, fieldEntry in ipairs(remainingFields) do
            local y = FieldScanner.estimateYield(fieldEntry, target.fillTypeIndex, "optimistic") * multi
            if y > 0 then
                table.insert(fieldsWithYield, { fieldEntry = fieldEntry, yield = y })
            end
        end

        if #fieldsWithYield == 0 then
            blocked[target.fillTypeIndex] = true
        else
            -- bestFitPick erwartet Objekte mit .yield
            local bestPerfect, bestSmall, bestLarge = nil, nil, nil
            for _, fw in ipairs(fieldsWithYield) do
                local y = fw.yield
                if y >= restBedarf and y <= restBedarf * 1.3 then
                    if bestPerfect == nil or y < bestPerfect.yield then bestPerfect = fw end
                elseif y < restBedarf then
                    if bestSmall == nil or y > bestSmall.yield then bestSmall = fw end
                else
                    if bestLarge == nil or y < bestLarge.yield then bestLarge = fw end
                end
            end
            local best = bestPerfect or bestSmall or bestLarge

            -- Feld aus dem Pool entfernen und zuweisen
            for i, fe in ipairs(remainingFields) do
                if fe == best.fieldEntry then
                    table.remove(remainingFields, i)
                    break
                end
            end
            target.covered = target.covered + best.yield
            local areaHa = best.fieldEntry.areaHa or 0
            table.insert(target.assignedFields, {
                fieldEntry     = best.fieldEntry,
                yield          = best.yield,
                seedLiterSpiel = DemandScanner.calcSeedLiter(target.fillTypeIndex, areaHa),
                seedLiterReal  = DemandScanner.getRealSeedLHa(target.fillTypeIndex) and
                                 DemandScanner.getRealSeedLHa(target.fillTypeIndex) * areaHa or nil,
            })
            table.insert(assignmentOrder, { fillTypeName = target.name, fieldEntry = best.fieldEntry, yield = best.yield })
        end
    end

    local totalCoveredAll = 0
    for _, fs in ipairs(fruitState) do
        totalCoveredAll = totalCoveredAll + math.min(fs.covered, fs.demand)
    end

    return {
        fruitState = fruitState,
        assignmentOrder = assignmentOrder,
        unassignedFieldCount = #remainingFields,
        totalDemandAll = totalDemandAll,
        totalCoveredAll = totalCoveredAll,
        autarkieGrad = totalDemandAll > 0 and (totalCoveredAll / totalDemandAll) or 0
    }
end

--- Erzeugt die Gesamtuebersicht als Liste einzelner Textzeilen (ohne print),
-- damit dieselbe Logik sowohl fuer die Konsolenausgabe als auch fuer das
-- HUD-Overlay (renderText) verwendet werden kann -- eine Quelle der Wahrheit,
-- kein doppelter Formatierungscode. "Pro Fruchtart"-Liste ist nach
-- Deckungsquote absteigend sortiert (groesste Engpaesse zuerst sichtbar,
-- TODO-Wunsch vom 21.06.).
function SeedPlanner.formatOverallPlanLines(result)
    local lines = {}

    if #result.fruitState == 0 then
        table.insert(lines, "Kein Fabrikbedarf gefunden (oder noch nicht verifiziert -> gsSaatplanDump pruefen).")
        return lines
    end

    table.insert(lines, "-- Zuteilung --")
    for i, entry in ipairs(result.assignmentOrder) do
        local fe = entry.fieldEntry
        local label = fe ~= nil and fe.label or "?"
        local areaHa = fe ~= nil and fe.areaHa or 0
        table.insert(lines, string.format("%d. %s (%.1fha) -> %s (ca. %.0fL)",
            i, label, areaHa, entry.fillTypeName, entry.yield))
    end

    table.insert(lines, "")
    table.insert(lines, "-- Pro Fruchtart (nach Deckungsquote absteigend) --")

    -- Sortierte Kopie nach Deckungsquote ABSTEIGEND (so wortwoertlich gewuenscht,
    -- 21.06.) -- nicht zu verwechseln mit "groesster Engpass zuerst" (waere
    -- aufsteigend gewesen, das war meine eigene Fehl-Interpretation beim
    -- Notieren des TODO-Punkts, hiermit korrigiert).
    local sorted = {}
    for _, fs in ipairs(result.fruitState) do
        table.insert(sorted, fs)
    end
    table.sort(sorted, function(a, b)
        local pctA = a.demand > 0 and (math.min(a.covered, a.demand) / a.demand) or 0
        local pctB = b.demand > 0 and (math.min(b.covered, b.demand) / b.demand) or 0
        return pctA > pctB
    end)

    for _, fs in ipairs(sorted) do
        local pct = fs.demand > 0 and (math.min(fs.covered, fs.demand) / fs.demand * 100) or 0
        local line = string.format("  %s: %.0f%% (%.0f / %.0f L, %d Feld(er))",
            fs.name, pct, math.min(fs.covered, fs.demand), fs.demand, #fs.assignedFields)
        -- Aussaatfenster anhaengen (reine Info; PlantingCalendar ist pcall-gesichert)
        local sow = (PlantingCalendar ~= nil) and PlantingCalendar.getWindowLabeled(fs.name, fs.fillTypeIndex) or nil
        if sow ~= nil then line = line .. "  [" .. sow .. "]" end
        table.insert(lines, line)
    end

    table.insert(lines, "")
    table.insert(lines, string.format("Unbenutzte freie Felder: %d", result.unassignedFieldCount))
    table.insert(lines, string.format("GESAMT-AUTARKIEGRAD: %.0f%% (%.0f / %.0f L)",
        result.autarkieGrad * 100, result.totalCoveredAll, result.totalDemandAll))

    return lines
end

function SeedPlanner.printOverallPlan(result)
    print("===== Saatplan Gesamtuebersicht (alle Fabrik-Fruchtarten) =====")
    for _, line in ipairs(SeedPlanner.formatOverallPlanLines(result)) do
        print(line)
    end
end
function SeedPlanner.printPlan(result)
    if result.error ~= nil then
        print("[Saatplan] " .. result.error)
        return
    end

    print(string.format("===== Saatplan fuer %s (fillTypeIndex=%s) =====", result.fillTypeName, tostring(result.fillTypeIndex)))
    print(string.format("Jahresbedarf gesamt (nur Fabriken): %.0f L", result.totalDemand))
    printTopContributors("Fabriken", result.factoryDemand.perPoint, 5)
    print("  (Tierstaelle bewusst nicht eingerechnet, siehe TODO_Saatplan.md)")
    print(string.format("Eigene unbesaete Felder gefunden: %d", result.candidateCount))

    if result.totalDemand <= 0 then
        print("Kein Bedarf an dieser Frucht gefunden (oder Inputs/Futtergruppen noch nicht verifiziert -> gsSaatplanDump pruefen).")
    end

    for i, candidate in ipairs(result.plan) do
        local label = candidate.label or "?"
        local areaHa = candidate.areaHa or 0
        print(string.format("%d. %s  (%.1f ha) -> ca. %.0f L", i, label, areaHa, candidate.yield))
    end

    print(string.format("Gedeckt: %.0f L von %.0f L (%s)",
        result.covered, result.totalDemand,
        result.sufficient and "ausreichend" or "NICHT ausreichend -- weitere Felder noetig"))
end
