-- ============================================
-- SENTINEL TAMPER SEAM — the cheat, on demand
-- ============================================
--
-- The Sentinel (whip_core/server/sentinel.lua) can only be proven by a write that
-- ORIGINATES on a client — a server-side seam would just exercise the write-through
-- helper and prove nothing. So this is a deliberate, working cheat: it writes whip's
-- watched statebag keys exactly the way a cheat menu would, so you can watch the
-- Sentinel stamp them back out and log you.
--
--   /sn_tamper isDead true              -> own player bag
--   /sn_tamper damageModifier 0.01      -> own player bag (the god-mode spoof)
--   /sn_tamper charId nil               -> key-deletion attack
--   /sn_tamper whipVehicleId 999999     -> current vehicle's entity bag (you must be driving)
--
-- Values parse as: nil, true, false, number, else raw string.
--
-- Key names are HARDCODED STRINGS on purpose, not whip_core's shared constants: globals
-- do not cross resource boundaries, and a real cheat hardcodes them too — if a rename in
-- shared/statebags.lua breaks this file's aim, it broke every cheat menu's aim the same
-- day, which is exactly the drill this seam exists to run. The gate is the resource
-- itself: whip_test is never ensured — this command only exists while manually started.

local ENTITY_KEYS = {
    whipVehicleId      = true,
    whipVehicleSession = true,
    whipStats          = true,
    whipLive           = true,
    whipAppearance     = true,
    whipVehData        = true,
}

local function parseValue(raw)
    if raw == nil or raw == 'nil' then return nil end
    if raw == 'true' then return true end
    if raw == 'false' then return false end
    local n = tonumber(raw)
    if n then return n end
    return raw
end

RegisterCommand('sn_tamper', function(_, args)
    local key = args[1]
    if not key or key == '' then
        print('[whip_test:sn_tamper] usage: /sn_tamper <key> <value>')
        return
    end
    local value = parseValue(args[2])

    if ENTITY_KEYS[key] then
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if veh == 0 then
            print('[whip_test:sn_tamper] entity keys need you in a vehicle (you own what you drive)')
            return
        end
        Entity(veh).state:set(key, value, true)
        print(('[whip_test:sn_tamper] wrote %s = %s on vehicle entity %d — watch the sentinel')
            :format(key, tostring(value), veh))
    else
        LocalPlayer.state:set(key, value, true)
        print(('[whip_test:sn_tamper] wrote %s = %s on own player bag — watch the sentinel')
            :format(key, tostring(value)))
    end
end, false)
