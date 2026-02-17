print("=== [Summon The Moving Box] MOD LOADING ===\n")

local UEHelpers = require("UEHelpers")
local LogUtil = require("LogUtil")
local ConfigUtil = require("ConfigUtil")

-- ============================================================
-- CONFIG
-- ============================================================

local CONFIG_SCHEMA = {
    { path = "StorageSlots",              type = "number",  default = 18,    min = 1,   max = 42 },
    { path = "SpeedMultiplier",           type = "number",  default = 1.5,   min = 0.1 },
    { path = "GatheringSpeedMultiplier",  type = "number",  default = 2.0,   min = 0.1, max = 5.0 },
    { path = "DisableCollision",          type = "boolean", default = false },
    { path = "Summon.Enabled",            type = "boolean", default = true },
    { path = "Summon.ConsumeChance",      type = "number",  default = 10.0,  min = 0,   max = 100 },
    { path = "Summon.FogChance",          type = "number",  default = 2.5,   min = 0,   max = 100 },
    { path = "Summon.Cooldown",           type = "number",  default = 30,    min = 1 },
    { path = "Summon.ProximityDistance",   type = "number",  default = 10,    min = 0 },
    { path = "Summon.Notifications.CooldownWarning", type = "boolean", default = true },
    { path = "Summon.Notifications.SummonChat",      type = "boolean", default = true },
    { path = "Summon.Notifications.FogWarning",      type = "boolean", default = true },
    { path = "Summon.Notifications.ShowModName",      type = "boolean", default = false },
    { path = "Debug",                     type = "boolean", default = false },
}

local UserConfig = require("../config")
local configLog = LogUtil.CreateLogger("SummonTheMovingBox (Config)", true)
local Config = ConfigUtil.ValidateFromSchema(UserConfig, CONFIG_SCHEMA, configLog)
local Log = LogUtil.CreateLogger("SummonTheMovingBox", Config.Debug)

-- ============================================================
-- CONSTANTS
-- ============================================================

-- Weather event row names from DT_WeatherEvents (discovered via Live View)
-- Available: Fog, RadLeak, Spores, ColdSnap, Blackout, BlackFog
local FOG_EVENT_ROW_NAME = "Fog"

-- Item RowNames (discovered via melee hook + CurrentItemRow)
local ORGAN_ROW_NAME = "organ"

-- ============================================================
-- STATE
-- ============================================================

local gameStateHookFired = false
local hookRegistered = false
local notifyRegistered = false
local summonHooksRegistered = false

-- Track processed Boxys to avoid re-processing
local processedBoxys = setmetatable({}, { __mode = "k" })

-- Summon cooldown tracking (os.clock = seconds since process start)
local lastSummonTime = -999

-- ============================================================
-- UTILITIES
-- ============================================================

-- GameMode only exists on the server/host
local function IsHost()
    local gameMode = FindFirstOf("Abiotic_Survival_GameMode_C")
    return gameMode:IsValid()
end

-- ============================================================
-- FEATURE: Storage Slots
-- ============================================================

-- Modify the CDO component template so new GameState instances (including from
-- save deserialization) are created with expanded slots. Mirrors the .pak mod.
local function ExpandStorageCDO()
    if Config.StorageSlots <= 6 then return end

    -- Template lives on the class object with _GEN_VARIABLE suffix (found via Live View)
    local boxyInventory = StaticFindObject("/Game/Blueprints/Meta/Abiotic_Survival_GameState.Abiotic_Survival_GameState_C:Inventory_Boxy_GEN_VARIABLE")
    if not boxyInventory:IsValid() then
        Log.Warning("ExpandStorageCDO: Inventory_Boxy_GEN_VARIABLE template not found")
        return
    end

    boxyInventory.MaxSlots = Config.StorageSlots
    boxyInventory.InitialInventorySize = Config.StorageSlots
    Log.Debug("Storage CDO updated: MaxSlots=%d, InitialInventorySize=%d", Config.StorageSlots, Config.StorageSlots)
end

local function ExpandStorageSlots(gameState)
    if Config.StorageSlots <= 6 then return end

    local boxyInventory = gameState.Inventory_Boxy
    if not boxyInventory:IsValid() then
        Log.Warning("ExpandStorageSlots: Inventory_Boxy not found on GameState")
        return
    end

    local okUpdate = pcall(function()
        boxyInventory:UpdateInventorySlotCount(Config.StorageSlots, false, {})
    end)

    if okUpdate then
        Log.Debug("Storage slots set to %d (via GameState.Inventory_Boxy)", Config.StorageSlots)
    else
        Log.Warning("ExpandStorageSlots: UpdateInventorySlotCount failed")
    end
end

-- ============================================================
-- FEATURE: Movement Speed
-- ============================================================

local function ModifyMovementSpeed(boxy)
    if Config.SpeedMultiplier == 1.0 then return end

    local currentWalkSpeed = boxy.WalkSpeed
    local newSpeed = currentWalkSpeed * Config.SpeedMultiplier
    boxy.WalkSpeed = newSpeed
    Log.Debug("WalkSpeed: %.1f -> %.1f", currentWalkSpeed, newSpeed)

    local cmc = boxy.CharacterMovement
    if not cmc:IsValid() then return end

    local currentMax = cmc.MaxWalkSpeed
    local newMax = currentMax * Config.SpeedMultiplier
    cmc.MaxWalkSpeed = newMax
    Log.Debug("MaxWalkSpeed: %.1f -> %.1f", currentMax, newMax)
end

-- ============================================================
-- FEATURE: Disable Collision
-- ============================================================

local function DisablePlayerCollision(boxy)
    if not Config.DisableCollision then return end

    local capsule = boxy.CapsuleComponent
    if not capsule:IsValid() then
        Log.Debug("DisableCollision: CapsuleComponent not found")
        return
    end

    capsule:SetCollisionResponseToChannel(2, 1)  -- Pawn channel -> Overlap
    Log.Debug("Collision: Pawn channel set to Overlap")
end

-- ============================================================
-- FEATURE: Gathering Speed
-- ============================================================

local VANILLA_ITEM_CHECK_INTERVAL = 10.0  -- Bytecode: K2_SetTimerDelegate("CheckForNearbyItems", 10.0, true)

local function ModifyGatheringSpeed(boxy)
    if Config.GatheringSpeedMultiplier == 1.0 then return end

    local controller = boxy.Controller
    if not controller:IsValid() then
        Log.Debug("GatheringSpeed: Controller not found")
        return
    end

    local kismetLib = UEHelpers.GetKismetSystemLibrary()
    if not kismetLib:IsValid() then
        Log.Warning("GatheringSpeed: KismetSystemLibrary not found")
        return
    end

    local newInterval = VANILLA_ITEM_CHECK_INTERVAL / Config.GatheringSpeedMultiplier

    kismetLib:K2_ClearTimer(controller, "CheckForNearbyItems")
    kismetLib:K2_SetTimer(controller, "CheckForNearbyItems", newInterval, true, false, 0.0, 0.0)

    Log.Debug("GatheringSpeed: Item check interval %.1fs -> %.1fs", VANILLA_ITEM_CHECK_INTERVAL, newInterval)
end

-- ============================================================
-- BOXY PROCESSING
-- ============================================================

local function ProcessBoxy(boxy)
    if not boxy:IsValid() then return end
    if processedBoxys[boxy] then return end
    processedBoxys[boxy] = true

    Log.Debug("Processing Boxy: %s", boxy:GetFullName())

    -- Movement speed (directly on the NPC)
    ModifyMovementSpeed(boxy)

    -- Collision (directly on the NPC)
    DisablePlayerCollision(boxy)

    -- Gathering speed (via AI controller)
    ModifyGatheringSpeed(boxy)
end

-- ============================================================
-- NOTIFICATIONS
-- ============================================================

-- CriticalityLevels: Green=0, Gray=1, Yellow=2, Red=3, Purple=4
local COLOR_WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local COLOR_GREEN = { R = 0.4, G = 1.0, B = 0.4, A = 1.0 }

local CHAT_PREFIX = "[SummonTheBox]"

local function SendChatMessage(message)
    local gameMode = FindFirstOf("Abiotic_Survival_GameMode_C")
    if not gameMode:IsValid() then return end
    local prefix = Config.Summon.Notifications.ShowModName and CHAT_PREFIX or ""
    gameMode:SendTextChatMessageToAllPlayers(
        false, false,           -- FactionCheck, FactionOnlySee
        prefix, COLOR_GREEN,    -- Prefix, PrefixColor
        message, COLOR_WHITE,   -- Message, MessageColor
        "", nil, false          -- ExcludedCallerName, PlayerState, IsPlayerChatTextMessage
    )
end

local function SendScreenWarning(message, criticalityLevel, withBeep)
    local player = UEHelpers.GetPlayer()
    if not player:IsValid() then return end
    player:Client_DisplayWarningMessage(FText(message), criticalityLevel, withBeep)
end

local function GetPlayerName(player)
    local playerState = player.PlayerState
    if not playerState:IsValid() then return "Someone" end
    local playerName = playerState:GetPlayerName()
    if not playerName or playerName == "" then return "Someone" end
    return playerName:ToString()
end

-- ============================================================
-- FEATURE: Summon via SymphOrgan
-- ============================================================

local function TryTriggerFogEvent()
    if Config.Summon.FogChance <= 0 then return false end

    local roll = math.random() * 100
    if roll >= Config.Summon.FogChance then
        Log.Debug("Fog roll: %.2f >= %.2f, no fog", roll, Config.Summon.FogChance)
        return false
    end

    local dayNightManager = FindFirstOf("DayNightManager_C")
    if not dayNightManager:IsValid() then
        Log.Debug("DayNightManager not found, skipping fog")
        return false
    end

    local currentWeather = dayNightManager.CurrentWeatherEvent:ToString()
    if currentWeather ~= "None" and currentWeather ~= "0" then
        Log.Debug("Weather already active (%s), skipping fog", currentWeather)
        return false
    end

    Log.Debug("Fog event triggered! (roll=%.2f, chance=%.2f%%)", roll, Config.Summon.FogChance)

    local weatherLib = StaticFindObject("/Script/AbioticFactor.Default__WeatherEventHandleFunctionLibrary")
    if not weatherLib:IsValid() then
        Log.Warning("WeatherEventHandleFunctionLibrary not found")
        return false
    end

    local outRowHandles = {}
    weatherLib:GetAllWeatherEventRowHandles(outRowHandles)

    if #outRowHandles == 0 then
        Log.Warning("No weather row handles found")
        return false
    end

    for i = 1, #outRowHandles do
        local rowHandle = outRowHandles[i]:get()
        if not rowHandle:IsValid() then return false end
        if rowHandle.RowName:ToString() == FOG_EVENT_ROW_NAME then
            dayNightManager:TriggerWeatherEvent({
                RowName = rowHandle.RowName,
                DataTablePath = rowHandle.DataTablePath
            })
            Log.Debug("Fog weather event triggered")
            return true
        end
    end

    Log.Warning("Fog row not found in weather event handles")
    return false
end

local SUMMON_OFFSET = 250  -- Unreal units (~2.5m) to avoid spawning inside the player

local function GetOffsetLocation(playerLoc)
    local angle = math.random() * 2 * math.pi
    return {
        X = playerLoc.X + math.cos(angle) * SUMMON_OFFSET,
        Y = playerLoc.Y + math.sin(angle) * SUMMON_OFFSET,
        Z = playerLoc.Z
    }
end

local function SummonBoxy(player)
    local aiDirector = FindFirstOf("Abiotic_AIDirector_C")
    if not aiDirector:IsValid() then
        Log.Warning("AIDirector not found")
        return false
    end

    -- If Boxy already exists, teleport nearby (not on top of player)
    local activeBoxy = aiDirector.ActiveBoxy
    if activeBoxy:IsValid() then
        local playerLoc = player:K2_GetActorLocation()
        local offsetLoc = GetOffsetLocation(playerLoc)
        activeBoxy:K2_SetActorLocation(offsetLoc, false, {}, true)
        Log.Debug("Existing Boxy teleported near player")
        return true
    end

    -- No existing Boxy - use the game's EQS-based spawn (finds a nearby location, Boxy walks in)
    local okTrigger = pcall(function()
        aiDirector:TriggerBoxyEventNearTarget(player)
    end)

    if not okTrigger then
        Log.Warning("TriggerBoxyEventNearTarget failed")
        return false
    end

    Log.Debug("TriggerBoxyEventNearTarget called, EQS query started")

    -- Boxy's AI only detects players within 1000 UU - teleport him closer if EQS placed him further
    local AI_DETECTION_RANGE_SQ = 1000 * 1000
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            if not player:IsValid() or not aiDirector:IsValid() then return end

            local boxy = aiDirector.ActiveBoxy
            if boxy:IsValid() then
                if boxy:GetSquaredDistanceTo(player) > AI_DETECTION_RANGE_SQ then
                    local playerLoc = player:K2_GetActorLocation()
                    boxy:K2_SetActorLocation(GetOffsetLocation(playerLoc), false, {}, true)
                    Log.Debug("Boxy outside AI detection range, teleported near player")
                end
                return
            end

            -- EQS failed to spawn Boxy, spawn directly near player
            local playerLoc = player:K2_GetActorLocation()
            aiDirector:SpawnBoxy(GetOffsetLocation(playerLoc))
            Log.Debug("EQS spawn failed, spawned Boxy directly")
        end)
    end)

    return true
end

local function ConsumeOrgan(player)
    if Config.Summon.ConsumeChance <= 0 then return false end

    local roll = math.random() * 100
    if roll >= Config.Summon.ConsumeChance then
        Log.Debug("Consume roll: %.2f >= %.2f, organ kept", roll, Config.Summon.ConsumeChance)
        return false
    end

    local okConsume = pcall(function()
        player:ConsumeItemOfSpecificCount(FName(ORGAN_ROW_NAME), 1)
    end)
    if okConsume then
        Log.Debug("SymphOrgan consumed (roll=%.2f, chance=%.2f%%)", roll, Config.Summon.ConsumeChance)
        return true
    else
        Log.Debug("ConsumeItemOfSpecificCount failed")
        return false
    end
end

-- ============================================================
-- SUMMON: Client-side trigger (sends RPC to server)
-- ============================================================

local function OnSummonAttempt(Context, ItemSlotDataParam, ItemToUseParam)
    local player = Context:get()
    if not player:IsValid() then return end

    local currentRow = player.CurrentItemRow:ToString()
    if currentRow ~= ORGAN_ROW_NAME then return end

    local now = os.clock()
    if Config.Summon.Cooldown > 0 and (now - lastSummonTime) < Config.Summon.Cooldown then
        local timeLeft = math.ceil(Config.Summon.Cooldown - (now - lastSummonTime))
        Log.Debug("Summon on cooldown (%ds remaining)", timeLeft)
        if Config.Summon.Notifications.CooldownWarning then
            SendScreenWarning("It's too soon to summon Boxy! (" .. timeLeft .. "s)", 3, true)
        end
        return
    end

    -- Proximity check - block if Boxy is already nearby
    if Config.Summon.ProximityDistance > 0 then
        local existingBoxy = FindFirstOf("NPC_Boxy_C")
        if existingBoxy:IsValid() then
            local proximityUU = Config.Summon.ProximityDistance * 100
            local distSq = existingBoxy:GetSquaredDistanceTo(player)
            if distSq <= proximityUU * proximityUU then
                Log.Debug("Boxy already within %.0fm", Config.Summon.ProximityDistance)
                SendScreenWarning("Boxy is already within " .. math.floor(Config.Summon.ProximityDistance) .. "m of you!", 3, true)
                return
            end
        end
    end

    Log.Debug("SymphOrgan used (RMB) - sending Request_UseItem to server")

    -- Send Request_UseItem as a client->server RPC signal
    -- The organ doesn't normally use this pathway, so it acts as our communication channel
    local item = ItemToUseParam:get()
    if not item:IsValid() then
        Log.Debug("Item_To_Use is invalid, cannot send request")
        return
    end

    local playerTransform = player:GetTransform()

    local okRequest = pcall(function()
        player:Request_UseItem(item, playerTransform, true, item)
    end)

    if okRequest then
        Log.Debug("Request_UseItem sent (item=%s)", item:GetClass():GetFName():ToString())
        lastSummonTime = os.clock()
    else
        Log.Warning("Request_UseItem call failed")
    end
end

-- ============================================================
-- SUMMON: Server-side handler (receives RPC, does the spawn)
-- ============================================================

local function OnRequestUseItem(Context, ItemParam, TransformParam, SecondaryActionParam, TargetActorParam)
    local player = Context:get()
    if not player:IsValid() then return end

    local secondaryAction = SecondaryActionParam:get()
    if not secondaryAction then return end

    local currentRow = player.CurrentItemRow:ToString()
    if currentRow ~= ORGAN_ROW_NAME then return end

    -- Only the server/host should actually spawn
    if not IsHost() then return end

    Log.Debug("Server received organ summon request")

    local summoned = SummonBoxy(player)
    if not summoned then return end

    Log.Debug("Boxy summoned for %s", GetPlayerName(player))
    ConsumeOrgan(player)

    ExecuteWithDelay(250, function()
        ExecuteInGameThread(function()
            local fogTriggered = TryTriggerFogEvent()
            local playerName = GetPlayerName(player)

            if fogTriggered and Config.Summon.Notifications.FogWarning then
                SendScreenWarning("Boxy was summoned, but they brought the fog with them...", 2, false)
                if Config.Summon.Notifications.SummonChat then
                    SendChatMessage(playerName .. " summoned Boxy, but they brought the fog with them...")
                end
            elseif Config.Summon.Notifications.SummonChat then
                SendChatMessage("Boxy was summoned by " .. playerName .. ".")
            end
        end)
    end)
end

-- ============================================================
-- SUMMON HOOK REGISTRATION
-- ============================================================

local function RegisterSummonHook()
    if summonHooksRegistered then return end
    if not Config.Summon.Enabled then return end
    summonHooksRegistered = true

    -- Server-side: handle incoming summon requests via Request_UseItem RPC
    local okReq, errReq = pcall(RegisterHook,
        "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:Request_UseItem",
        OnRequestUseItem
    )
    if okReq then
        Log.Debug("Request_UseItem hook registered (server-side summon handler)")
    else
        Log.Warning("Request_UseItem hook failed: %s", tostring(errReq))
    end

    -- Client-side: detect organ RMB and send RPC to server
    local okHook, errHook = pcall(RegisterHook,
        "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:Local_DoSecondaryAction",
        OnSummonAttempt
    )
    if okHook then
        Log.Debug("Local_DoSecondaryAction hook registered (client-side trigger)")
    else
        Log.Warning("Local_DoSecondaryAction hook failed: %s", tostring(errHook))
    end
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

local function OnGameState(world)
    gameStateHookFired = true
    if not world:IsValid() then return end

    local fullName = world:GetFullName()
    local mapName = fullName:match("/Game/Maps/([^%.]+)")
    if not mapName or mapName:match("MainMenu") then return end

    Log.Debug("Gameplay detected: %s", mapName)

    -- Hook Boxy's ReceiveBeginPlay for future spawns (components ready, no async handoff)
    if not notifyRegistered then
        notifyRegistered = true
        local okBoxyHook, errBoxyHook = pcall(RegisterHook,
            "/Game/Blueprints/Characters/NPCs/NPC_Boxy.NPC_Boxy_C:ReceiveBeginPlay",
            function(Context)
                local boxy = Context:get()
                if not boxy:IsValid() then return end
                Log.Debug("Boxy ReceiveBeginPlay fired")
                ProcessBoxy(boxy)
            end
        )
        if okBoxyHook then
            Log.Debug("Boxy ReceiveBeginPlay hook registered")
        else
            Log.Warning("Boxy ReceiveBeginPlay hook failed: %s", tostring(errBoxyHook))
        end
    end

    -- Register summon hooks (client trigger + server handler)
    RegisterSummonHook()

    -- Check for existing Boxy (late-joining clients)
    ExecuteWithDelay(2500, function()
        ExecuteInGameThread(function()
            local existingBoxy = FindFirstOf("NPC_Boxy_C")
            if existingBoxy:IsValid() then
                Log.Debug("Found existing Boxy via FindFirstOf")
                ProcessBoxy(existingBoxy)
            else
                Log.Debug("No existing Boxy found")
            end
        end)
    end)
end

local function OnGameStateHook(Context)
    Log.Debug("Abiotic_Survival_GameState:ReceiveBeginPlay fired")
    local gameState = Context:get()
    if not gameState:IsValid() then return end

    ExpandStorageSlots(gameState)

    local world = gameState:GetWorld()
    if world:IsValid() then
        OnGameState(world)
    end
end

-- ============================================================
-- GAMESTATE HOOK REGISTRATION VIA POLLING
-- ============================================================

local function PollForGameState(attempts)
    attempts = attempts or 0
    if gameStateHookFired then return end

    ExecuteInGameThread(function()
        local base = FindFirstOf("GameStateBase")
        if not base:IsValid() then
            if attempts < 100 then
                ExecuteWithDelay(100, function()
                    PollForGameState(attempts + 1)
                end)
            else
                Log.Error("GameStateBase never found after %d attempts", attempts + 1)
            end
            return
        end

        if not hookRegistered then
            local okHook = pcall(RegisterHook,
                "/Game/Blueprints/Meta/Abiotic_Survival_GameState.Abiotic_Survival_GameState_C:ReceiveBeginPlay",
                OnGameStateHook
            )
            if okHook then
                hookRegistered = true
                Log.Debug("GameState hook registered")
            end
        end

        local gameState = FindFirstOf("Abiotic_Survival_GameState_C")
        if gameState:IsValid() then
            Log.Debug("Already in gameplay, invoking OnGameState")
            ExpandStorageSlots(gameState)
            local world = gameState:GetWorld()
            if world:IsValid() then
                OnGameState(world)
            end
        end
    end)
end

-- Modify CDO before any GameState instance is created (affects save deserialization)
ExecuteWithDelay(2500, function()
    ExecuteInGameThread(function()
        ExpandStorageCDO()
    end)
end)

PollForGameState()
Log.Info("Mod loaded")
