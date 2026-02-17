# Summon The Moving Box

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for [Abiotic Factor](https://store.steampowered.com/app/427410/Abiotic_Factor/) that enhances Boxy - expanded storage, faster movement and gathering, and on-demand summoning via the Organ item.

## Features

All features are independently configurable. Set any multiplier to 1.0 or disable any toggle to keep vanilla behavior with zero overhead.

### Boxy Enhancements

- **Expanded Storage** - Increase Boxy's inventory from 6 to up to 42 slots (7x6 grid). Persists through save/load via CDO archetype modification. Default: 18 slots
- **Movement Speed** - Multiply Boxy's walk speed. Default: 1.5x
- **Gathering Speed** - Multiply how frequently Boxy checks for nearby items. Vanilla interval is 10s. Default: 2.0x (every 5s)
- **Disable Collision** - Players walk through Boxy. Default: off

### Summon Boxy

- **Organ Summoning** - Use the Organ's secondary action (right-click) to call Boxy to your location. Teleports existing Boxy or triggers the AI director's EQS spawn
- **Cooldown** - Configurable cooldown between summons with on-screen warning. Default: 30s
- **Proximity Check** - Blocks summon if Boxy is already within range. Default: 10m
- **Consume Chance** - Percent chance the Organ is consumed on use. Default: 10%
- **Fog Chance** - Percent chance summoning triggers a fog weather event. Default: 2.5%
- **Notifications** - Chat messages (broadcast via `GameMode:SendTextChatMessageToAllPlayers`), screen warnings, fog alerts. All individually toggleable

## Architecture

### Multiplayer Model

Summoning uses a client-server RPC pattern:

1. **Client** hooks `Local_DoSecondaryAction`, detects Organ use, enforces cooldown/proximity checks locally
2. **Client** sends `Request_UseItem` as a server RPC signal (the Organ doesn't normally use this pathway, so it acts as the communication channel)
3. **Server** hooks `Request_UseItem`, filters for Organ + secondary action, spawns/teleports Boxy via `AIDirector`
4. **Server** broadcasts chat notifications via `GameMode:SendTextChatMessageToAllPlayers` (`FUNC_NetClient` verified in uasset)

### Storage Persistence

Storage expansion uses two mechanisms:
- **CDO archetype modification** (`Inventory_Boxy_GEN_VARIABLE` on the class object) - affects all future instances including save deserialization
- **Live instance update** (`UpdateInventorySlotCount` on GameState's `Inventory_Boxy`) - applies to the current session

### Hook Strategy

- **GameState detection**: Polls for `GameStateBase`, registers hook on `Abiotic_Survival_GameState_C:ReceiveBeginPlay`
- **Boxy detection**: `RegisterHook` on `NPC_Boxy_C:ReceiveBeginPlay` + delayed `FindFirstOf` fallback for late-joining clients
- **Gathering speed**: Clears and re-sets `CheckForNearbyItems` timer via `KismetSystemLibrary` on Boxy's AI controller

## Configuration

Edit `config.lua` in the mod folder:

```lua
return {
    StorageSlots = 18,              -- 1-42 (7x6 grid max), vanilla is 6
    SpeedMultiplier = 1.5,          -- 1.0 = vanilla
    GatheringSpeedMultiplier = 2.0, -- 1.0 = vanilla (10s), max 5.0 (2s)
    DisableCollision = false,       -- Players walk through Boxy
    Summon = {
        Enabled = true,
        ConsumeChance = 10.0,        -- 0 = never, 100 = always
        FogChance = 2.5,             -- 0 = never
        Cooldown = 30,               -- Seconds between summons
        ProximityDistance = 10,       -- Meters, 0 = disable check
        Notifications = {
            CooldownWarning = true,
            SummonChat = true,
            FogWarning = true,
            ShowModName = false,     -- Prepend [SummonTheBox] to chat
        },
    },
    Debug = false,
}
```

Config is validated at load time via schema with type checking, range clamping, and default substitution (`ConfigUtil.lua`).

## Installation

### For Players

See the [NexusMods page](https://www.nexusmods.com/abioticfactor/mods/191) for installation instructions.

### For Development

```
AbioticFactor/Binaries/Win64/Mods/SummonTheMovingBox/
    enabled.txt
    config.lua
    scripts/
        main.lua
        LogUtil.lua
        ConfigUtil.lua
```

Requires [UE4SS](https://www.nexusmods.com/abioticfactor/mods/35) installed in the game's `Binaries/Win64` directory.

## Multiplayer

The host needs the mod installed for Boxy enhancements and to handle summon requests. Players who want to summon Boxy also need the mod installed so the Organ right-click is hooked.

Storage expansion persists through save/load on the host's save file. Clients joining a modded host see the expanded storage automatically.

Works on dedicated servers - the server must have the mod installed. Boxy's speed and gathering rate are controlled by the server's `config.lua`.

**Note:** Uninstalling the mod reverts Boxy to 6 slots. Items in slots 7+ will be lost.

## Requirements

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (recommended: [NexusMods release for Abiotic Factor](https://www.nexusmods.com/abioticfactor/mods/35))
- Abiotic Factor (tested on v1.2 Holiday Cryosphere Update)

## Credits

Built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) by the RE-UE4SS team.

Thanks to Caites' [Better Boxy](https://www.nexusmods.com/abioticfactor/mods/91) mod for inspiration.
