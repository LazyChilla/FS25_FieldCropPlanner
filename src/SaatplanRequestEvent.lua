-- SaatplanRequestEvent.lua
-- Client → Server: "Bitte schick mir deine Config"
-- Kein Dateninhalt noetig (leeres Event)
-- Pattern verifiziert aus AutoDrive/UserConnectedEvent.lua

SaatplanRequestEvent = {}
SaatplanRequestEvent_mt = Class(SaatplanRequestEvent, Event)
InitEventClass(SaatplanRequestEvent, "SaatplanRequestEvent")

function SaatplanRequestEvent.emptyNew()
    return Event.new(SaatplanRequestEvent_mt)
end

function SaatplanRequestEvent.new()
    return SaatplanRequestEvent.emptyNew()
end

function SaatplanRequestEvent:writeStream(streamId, connection)
    -- kein Inhalt
end

function SaatplanRequestEvent:readStream(streamId, connection)
    self:run(connection)
end

function SaatplanRequestEvent:run(connection)
    if g_server ~= nil then
        -- Server empfaengt Request vom Client → Config zurueckschicken
        print("[Saatplan] RequestEvent: Client hat Config angefragt, sende Response...")
        if InGameMenuSP ~= nil and InGameMenuSP.instance ~= nil then
            local inst = InGameMenuSP.instance
            -- Config-Strings zusammenbauen (gleiche Logik wie saveConfig)
            local dis = {}
            for _, f in ipairs(inst.filterData or {}) do
                if not f.active then table.insert(dis, f.name) end
            end
            local excl = {}
            for fieldId, _ in pairs(inst.excludedFieldIds or {}) do
                table.insert(excl, tostring(fieldId))
            end
            local multiParts = {}
            for _, f in ipairs(inst.filterData or {}) do
                if (f.schnittMulti or 1) > 1 then
                    table.insert(multiParts, f.name .. ":" .. tostring(f.schnittMulti))
                end
            end
            connection:sendEvent(SaatplanResponseEvent.new(
                table.concat(dis, ","),
                table.concat(excl, ","),
                inst.minFieldSize or 0.0,
                table.concat(multiParts, ",")
            ))
        else
            -- Kein Tab geoeffnet auf Host → leere Response
            connection:sendEvent(SaatplanResponseEvent.new("", "", 0.0, ""))
        end
    end
end

function SaatplanRequestEvent.sendToServer()
    if g_server == nil then
        print("[Saatplan] RequestEvent: sende Config-Anfrage an Server...")
        g_client:getServerConnection():sendEvent(SaatplanRequestEvent.new())
    end
end
