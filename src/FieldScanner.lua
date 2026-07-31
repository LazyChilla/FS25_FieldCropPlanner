-- ============================================================
--  FieldScanner
--  Erfasst die eigenen, noch ungesaeten Felder und ihren zu
--  erwartenden Ertrag je Fruchtart.
--
--  STATUS: field.areaHa und g_fruitTypeManager:getFillTypeLiterPerSqm sind
--  anhand des echten FS25-Quellcodes verifiziert. Feldbesitz laeuft ueber
--  field.farmland.farmId / field.farmland.isOwned (direkte Objekt-Referenz,
--  von FieldManager beim Laden gesetzt) -- siehe getFieldOwnerFarmId()
--  unten, per gsSaatplanDump live verifiziert. NICHT verwenden:
--  field.fieldState.ownerFarmId und field.fieldState.farmlandId sind beide
--  unzuverlaessig (siehe Kommentar an getFieldOwnerFarmId).
--  Die Ertragsformel im "realistic"-Modus (Duenge-/Kalkbonus) ist eine
--  grobe Naeherung und sollte gegen echte Erntewerte kalibriert werden.
-- ============================================================

FieldScanner = {}

-- BESTAETIGTER FUND (per gsSaatplanDump, Tiefendiagnose Tabellenstruktur):
-- - field.fieldState.ownerFarmId ist NICHT zuverlaessig nutzbar: zeigt in
--   der Praxis Werte wie 15, die nichts mit dem tatsaechlichen Farmbesitz
--   zu tun haben (vermutlich ein anderweitig genutztes Legacy-/Mission-Feld).
-- - field.fieldState.farmlandId bleibt durchgehend 0 -- ebenfalls unbrauchbar.
-- - Der korrekte Weg ist field.farmland (direkte Objekt-Referenz auf das
--   Farmland, von FieldManager beim Laden gesetzt) mit den Feldern
--   field.farmland.farmId und field.farmland.isOwned. Live verifiziert:
--   farmId=1, isOwned=true fuer ein bestaetigt eigenes Feld.
local function getFieldOwnerFarmId(field)
    if field.farmland == nil then
        return FarmlandManager.NO_OWNER_FARM_ID
    end
    return field.farmland.farmId or FarmlandManager.NO_OWNER_FARM_ID
end

local function resolveFruitTypeName(fruitTypeIndex)
    if fruitTypeIndex == nil or g_fruitTypeManager == nil then
        return "?"
    end
    if fruitTypeIndex == FruitType.UNKNOWN then
        return "UNBESAET"
    end
    local ok, fruitType = pcall(function() return g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) end)
    if ok and fruitType ~= nil then
        return fruitType.name or "?"
    end
    return "?"
end

--- Debug: zeigt alle Felder auf der Map vs. eigene, und fuer jedes
-- eigene Feld den aktuellen Zustand (Frucht, Wachstum, Groesse).
-- Damit pruefbar, ob unbesaete Felder ueberhaupt erkannt werden.
function FieldScanner.debugDump(farmId)
    local fieldManager = g_fieldManager
    local fields = (fieldManager ~= nil and fieldManager.fields) or {}
    print(string.format("Felder Map gesamt: %d", #fields))
    print(string.format("g_farmlandManager vorhanden: %s | farmId Parameter: %s (Typ %s)",
        tostring(g_farmlandManager ~= nil), tostring(farmId), type(farmId)))

    -- Diagnose: erste 5 Felder roh ausgeben, unabhaengig vom Besitz-Filter.
    print("  -- Rohdaten erste 5 Felder (zur Fehlersuche) --")
    for i = 1, math.min(5, #fields) do
        local field = fields[i]
        local farmland = field.farmland
        print(string.format("  [%d] farmland.farmId=%s | farmland.isOwned=%s | aufgeloester Owner=%s | areaHa=%s",
            i, tostring(farmland ~= nil and farmland.farmId or nil),
            tostring(farmland ~= nil and farmland.isOwned or nil),
            tostring(getFieldOwnerFarmId(field)), tostring(field.areaHa)))
    end

    local ownFields = {}
    for _, field in ipairs(fields) do
        if getFieldOwnerFarmId(field) == farmId then
            table.insert(ownFields, field)
        end
    end
    print(string.format("Davon eigene: %d", #ownFields))

    for _, field in ipairs(ownFields) do
        local state = field.fieldState
        local fruitName = resolveFruitTypeName(state ~= nil and state.fruitTypeIndex or nil)
        print(string.format("  Feld bei (%.0f, %.0f): %.2f ha | Frucht=%s | growthState=%s | isValid=%s | farmlandId=%s",
            field.posX or 0, field.posZ or 0, field.areaHa or 0, fruitName,
            tostring(state ~= nil and state.growthState or "?"),
            tostring(state ~= nil and state.isValid or "?"),
            tostring(state ~= nil and state.farmlandId or "?")))
    end
end

--- Gibt eine lesbare Feldbezeichnung zurueck.
-- Prioritaet: farmland.field.fieldId (verifiziert in GoToNextField.lua:
-- farmland.field.fieldId ist die echte Feldnummer) -> Koordinaten als Fallback.
local function getFieldLabel(field)
    local farmland = field.farmland
    if farmland ~= nil then
        -- farmland.field.fieldId: bestaetigter Pfad aus FS25_GoToNextField
        local f = farmland.field
        if f ~= nil and f.fieldId ~= nil then
            return "Feld " .. tostring(f.fieldId)
        end
        -- Alternativ: farmland.name (z.B. "Feld 5" auf manchen Karten)
        if farmland.name ~= nil and farmland.name ~= "" then
            return farmland.name
        end
    end
    return string.format("(%.0f,%.0f)", field.posX or 0, field.posZ or 0)
end

--- Liefert alle eigenen Felder (besaet UND unbesaet) mit Feldnummer und
-- aktueller Frucht -- fuer die Anzeige im Detail-Tab (besaete Felder
-- sollen gruen mit Feldnummer erscheinen).
function FieldScanner.getAllOwnedFields(farmId)
    local result = {}
    local fieldManager = g_fieldManager
    if fieldManager == nil or fieldManager.fields == nil then return result end

    for _, field in ipairs(fieldManager.fields) do
        local state = field.fieldState
        if state ~= nil and state.isValid and getFieldOwnerFarmId(field) == farmId then
            local fruitIdx = state.fruitTypeIndex
            local isSown = fruitIdx ~= nil and fruitIdx ~= FruitType.UNKNOWN

            -- Fruchtnamen aufloesen
            local fruitName = nil
            if isSown then
                local ft = g_fruitTypeManager ~= nil
                    and g_fruitTypeManager:getFruitTypeByIndex(fruitIdx) or nil
                fruitName = ft ~= nil and (ft.fillType ~= nil and ft.fillType.name) or nil
            end

            table.insert(result, {
                field     = field,
                label     = getFieldLabel(field),
                areaHa    = field.areaHa or 0,
                posX      = field.posX or 0,
                posZ      = field.posZ or 0,
                isSown    = isSown,
                fruitName = fruitName,
            })
        end
    end
    return result
end

--- Liefert alle eigenen Felder, die aktuell unbestellt sind
-- (kein FruitType bzw. FruitType.UNKNOWN im FieldState).
function FieldScanner.getUnsownFields(farmId)
    local result = {}
    local fieldManager = g_fieldManager

    if fieldManager == nil or fieldManager.fields == nil then
        return result
    end

    for _, field in ipairs(fieldManager.fields) do
        local state = field.fieldState
        if state ~= nil and state.isValid and getFieldOwnerFarmId(field) == farmId then
            if state.fruitTypeIndex == nil or state.fruitTypeIndex == FruitType.UNKNOWN then
                table.insert(result, {
                    field  = field,
                    label  = getFieldLabel(field),
                    areaHa = field.areaHa or 0,
                    posX   = field.posX or 0,
                    posZ   = field.posZ or 0,
                })
            end
        end
    end

    return result
end

--- Geschaetzter Ertrag (Liter) eines Feldes fuer eine Fruchtart.
-- Erwartet ein fieldEntry {field, label, areaHa, ...} wie von getUnsownFields().
function FieldScanner.estimateYield(fieldEntry, fillTypeIndex, mode)
    -- getFillTypeLiterPerSqm gibt fuer Windrow-Fruechte (Gras, Klee, Luzerne,
    -- Alfalfa, Hanf, Flachs) 0 zurueck, weil sie beim Ernten nicht direkt
    -- ihren eigenen FillType produzieren, sondern einen Windrow (GRASS_WINDROW
    -- etc.). Der echte Ertragswert steckt in fruitType.literPerSqm -- derselbe
    -- Vorwaerts-Lookup den wir schon an anderen Stellen im Mod nutzen.
    local literPerSqm = g_fruitTypeManager:getFillTypeLiterPerSqm(fillTypeIndex, 0) or 0
    if literPerSqm == 0 and g_fruitTypeManager ~= nil and g_fruitTypeManager.fruitTypes ~= nil then
        for _, ft in ipairs(g_fruitTypeManager.fruitTypes) do
            if ft.fillType ~= nil and ft.fillType.index == fillTypeIndex then
                literPerSqm = ft.literPerSqm or 0
                break
            end
        end
    end

    local sqm = (fieldEntry.areaHa or 0) * 10000
    local baseYield = sqm * literPerSqm

    if mode ~= "realistic" then
        return baseYield
    end

    local state = fieldEntry.field ~= nil and fieldEntry.field.fieldState or nil
    local fertilizeBonus = 1.0
    if state ~= nil and state.sprayLevel ~= nil and state.sprayLevel > 0 then
        fertilizeBonus = fertilizeBonus + 0.25 * math.min(state.sprayLevel, 2)
    end
    if state ~= nil and state.limeLevel ~= nil and state.limeLevel > 0 then
        fertilizeBonus = fertilizeBonus + 0.05
    end

    return baseYield * fertilizeBonus
end

--- Alle unbesaeten Felder einer Farm samt geschaetztem Ertrag fuer eine
-- Fruchtart, absteigend nach Ertrag sortiert (groesster Beitrag zuerst).
-- Rueckgabe: Liste von { field, label, areaHa, posX, posZ, yield }
function FieldScanner.getAvailableFieldsSorted(farmId, fillTypeIndex, mode)
    local fields = FieldScanner.getUnsownFields(farmId)
    local withYield = {}

    for _, fieldEntry in ipairs(fields) do
        local y = FieldScanner.estimateYield(fieldEntry, fillTypeIndex, mode)
        table.insert(withYield, {
            field  = fieldEntry.field,
            label  = fieldEntry.label,
            areaHa = fieldEntry.areaHa,
            posX   = fieldEntry.posX,
            posZ   = fieldEntry.posZ,
            yield  = y,
        })
    end

    table.sort(withYield, function(a, b) return a.yield > b.yield end)
    return withYield
end
