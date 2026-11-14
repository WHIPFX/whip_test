-- ============================================
-- whip_test — LOAD TEST (client half)
-- ============================================
--
-- Two jobs, and only two:
--   1. Fire synthetic events at the server, because a SecureEvent needs a real source and the
--      server cannot give itself one.
--   2. Show the live panel.
--
-- It holds no state the server needs. If this client crashes the run keeps going and the server
-- console can still stop it with /testloadstop — which is the whole reason that command does not
-- require a player.

local firing      = false
local eventRate   = 0
local sentTotal   = 0

--- Fire events at the requested rate, in small batches, forever until told to stop.
---
--- BATCHED PER 100ms RATHER THAN SPACED EVENLY, because that is closer to how real traffic
--- arrives — players act in clusters, not on a metronome — and because a Wait per event would
--- cap the rate at the frame rate long before it reached anything interesting.
---
--- THE RISK THIS CARRIES: these are real reliable network events. FiveM's server-side limiter is
--- not something whip can bypass, and a client that overruns it gets kicked for event overflow.
--- The server caps the rate before it ever gets here; this loop does not second-guess that, but it
--- does report what it actually sent so the panel shows reality rather than the request.
CreateThread(function()
    while true do
        if not firing or eventRate <= 0 then
            Wait(250)
            goto continue
        end

        local perTick = math.max(1, math.floor(eventRate / 10))
        for _ = 1, perTick do
            if not firing then break end
            -- Cheap, side-effect-free, and still travels the entire SecureEvent path: validation,
            -- rate limiter, player lookup. vehicleId 0 is the documented "no vehicle" case.
            TriggerServerEvent('whip_core:server:checkIgnition', 0)
            sentTotal = sentTotal + 1
        end

        Wait(100)
        ::continue::
    end
end)

--- Report what was actually sent, once a second. Cheap, and it is the only way the panel can show
--- the real rate rather than the one that was asked for.
CreateThread(function()
    while true do
        Wait(1000)
        if firing then
            TriggerServerEvent('whip_test:loadEventStat', sentTotal)
        end
    end
end)

RegisterNetEvent('whip_test:loadStart', function(cfg)
    cfg = cfg or {}
    eventRate = tonumber(cfg.eventsPerSec) or 0
    sentTotal = 0
    firing    = eventRate > 0

    SendNUIMessage({ action = 'loadStart' })
end)

RegisterNetEvent('whip_test:loadUpdate', function(data)
    SendNUIMessage({ action = 'loadUpdate', data = data })
end)

RegisterNetEvent('whip_test:loadStop', function()
    firing    = false
    eventRate = 0
    SendNUIMessage({ action = 'loadStop' })
end)

--- If whip_test stops mid-run, stop firing. Without this the thread would keep hammering the
--- server after the resource that owns it is gone.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        firing = false
    end
end)
