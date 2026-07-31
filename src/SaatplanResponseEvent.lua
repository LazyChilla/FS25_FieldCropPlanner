-- SaatplanResponseEvent.lua
-- Server → Client: Config-Daten (disabled, excludedFields, minFieldSize, schnittMulti)
-- Pattern verifiziert aus AutoDrive/UserDataEvent.lua (streamWriteString/Float32)

SaatplanResponseEvent = {}
SaatplanResponseEvent_mt = Class(SaatplanResponseEvent, Event)
InitEventClass(SaatplanResponseEvent, "SaatplanResponseEvent")

function SaatplanResponseEvent.emptyNew()
    return Event.new(SaatplanResponseEvent_mt)
end

function SaatplanResponseEvent.new(disabled, excludedFields, minFieldSize, schnittMulti)
    local self = SaatplanResponseEvent.emptyNew()
    self.disabled      = disabled      or ""
    self.excludedFields = excludedFields or ""
    self.minFieldSize  = minFieldSize  or 0.0
    self.schnittMulti  = schnittMulti  or ""
    return self
end

function SaatplanResponseEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.disabled)
    streamWriteString(streamId, self.excludedFields)
    streamWriteFloat32(streamId, self.minFieldSize)
    streamWriteString(streamId, self.schnittMulti)
end

function SaatplanResponseEvent:readStream(streamId, connection)
    self.disabled       = streamReadString(streamId)
    self.excludedFields = streamReadString(streamId)
    self.minFieldSize   = streamReadFloat32(streamId)
    self.schnittMulti   = streamReadString(streamId)
    self:run(connection)
end

function SaatplanResponseEvent:run(connection)
    if g_server == nil then
        -- Client empfaengt Config vom Server → anwenden
        print(string.format("[Saatplan] ResponseEvent: Config empfangen (disabled='%s', excl='%s', minSize=%.1f)",
            self.disabled, self.excludedFields, self.minFieldSize))
        if InGameMenuSP ~= nil and InGameMenuSP.instance ~= nil then
            InGameMenuSP.instance:applyServerConfig(
                self.disabled, self.excludedFields, self.minFieldSize, self.schnittMulti)
        end
    end
end

function SaatplanResponseEvent.sendToClient(connection, disabled, excludedFields, minFieldSize, schnittMulti)
    connection:sendEvent(SaatplanResponseEvent.new(disabled, excludedFields, minFieldSize, schnittMulti))
end
