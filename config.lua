return {
    StorageSlots = 18,              -- 1-42 (7x6 grid max), vanilla is 6 [default: 18]
    SpeedMultiplier = 1.5,          -- 1.0 = vanilla [default: 1.5]
    GatheringSpeedMultiplier = 2.0, -- 1.0 = vanilla (checks every 10s), max 5.0 (every 2s) [default: 2.0 (every 5s)]
    DisableCollision = false,       -- Players walk through Boxy [default: false]
    Summon = {
        Enabled = true,
        UpdateOrganDescription = true,  -- Append summon hint to SymphOrgan item description [default: true]
        ConsumeChance = 10.0,        -- Percent chance to consume organ on summon (0 = never, 100 = always) [default: 10.0]
        FogChance = 2.5,            -- Percent chance (1.0 = 1%, supports decimals like 0.5) [default: 2.5]
        Cooldown = 30,              -- Seconds between summons (0 = no cooldown) [default: 30]
        ProximityDistance = 10,     -- Meters - block summon if Boxy is already this close (0 = disable check) [default: 10]
        Notifications = {
            CooldownWarning = true, -- Screen warning with beep when summoning too soon [default: true]
            SummonChat = true,      -- Chat message when Boxy is summoned [default: true]
            FogWarning = true,      -- Screen + chat message when fog is triggered [default: true]
            ShowModName = false,    -- Prepend [SummonTheBox] to chat messages [default: false]
        },
    },
    Debug = false,
}
