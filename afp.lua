local shared = odh_shared_plugins
task.spawn(function()
    shared.load_from_github_url("/aux0on/CrashHandler/refs/heads/main/Prevention.lua")
end)

if shared.game_name ~= "Murder Mystery 2" then return end

local afp = shared.CreateTab("Autofarm+", "/aux0on/AFPIcon/refs/heads/main/Untitled163_20260919023714")
local section = afp:AddSection("Assassin")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

while not Players.LocalPlayer do task.wait() end
local player = Players.LocalPlayer

local autoKillEnabled = false
local whitelist = {}

local STATE = { IDLE = "IDLE", KILLING = "KILLING", WAITING = "WAITING", RESETTING = "RESETTING" }
local state = STATE.IDLE

local bagFullThisRound = false
local latestCoins = 0
local latestMaxCoins = 0
local roundStartedAt = 0
local resettingStartedAt = 0
local charAtResetStart = nil
local lastTargetName = nil

local KILL_COOLDOWN = 1.0
local REPLICATION_TIMEOUT = 4.0
local RESETTING_TIMEOUT = 8.0
local NO_TARGET_WARN_AFTER = 5.0

local function log(...)
    print("[Assassin]", ...)
end

local function isWhitelisted(p)
    if typeof(p) == "Instance" and p:IsA("Player") then
        return table.find(whitelist, p.UserId) ~= nil
    elseif type(p) == "string" then
        local plr = Players:FindFirstChild(p)
        return plr and table.find(whitelist, plr.UserId) ~= nil
    end
    return false
end

local function getKnife()
    local char = player.Character
    if char then
        local k = char:FindFirstChild("Knife")
        if k then return k end
    end
    local bp = player:FindFirstChild("Backpack")
    if bp then
        local k = bp:FindFirstChild("Knife")
        if k then return k end
    end
    return nil
end

local function hasKnife() return getKnife() ~= nil end

local function getKillPart(character)
    if not character then return nil end
    return character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
        or character:FindFirstChild("HumanoidRootPart")
end

local function getLivingPlayers()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character and not isWhitelisted(p) then
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then table.insert(list, p) end
        end
    end
    return list
end

local function getLivingCount() return #getLivingPlayers() end

-- EXACT copy from your original working script
local function getCurrentTargetName()
    local pGui = player:FindFirstChild("PlayerGui")
    if not pGui then return nil end
    local mainGui = pGui:FindFirstChild("MainGUI")
    if not mainGui then return nil end
    local gameFrame = mainGui:FindFirstChild("Game")
    if not gameFrame then return nil end
    local assassinTarget = gameFrame:FindFirstChild("AssassinTarget")
    if not assassinTarget then return nil end
    local targetNameObj = assassinTarget:FindFirstChild("TargetName")
    if targetNameObj and (targetNameObj:IsA("TextLabel") or targetNameObj:IsA("TextBox")) then
        local text = targetNameObj.Text
        if text and text ~= "" and text ~= "Nikilis" then
            return text
        end
    end
    return nil
end

-- EXACT copy from your original working script
local function killTarget(name)
    if not name or isWhitelisted(name) then return false end
    local knife = getKnife()
    if not knife then return false end
    local events = knife:FindFirstChild("Events")
    if not events then return false end
    local handleTouched = events:FindFirstChild("HandleTouched")
    if not handleTouched then return false end
    local target = Players:FindFirstChild(name)
    if not target or not target.Character then return false end
    local part = getKillPart(target.Character)
    local hum = target.Character:FindFirstChildOfClass("Humanoid")
    if part and hum and hum.Health > 0 then
        handleTouched:FireServer(part)
        return true
    end
    return false
end

local function resetCharacter()
    log("Resetting character")
    local char = player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        pcall(function() char:BreakJoints() end)
        return
    end
    pcall(function() hum.Health = 0 end)
    task.wait(0.15)
    if hum.Parent and hum.Health > 0 then
        pcall(function() hum:TakeDamage(hum.MaxHealth * 10) end)
    end
    task.wait(0.15)
    if hum.Parent and hum.Health > 0 then
        pcall(function() char:BreakJoints() end)
    end
    task.wait(0.15)
    if hum.Parent and hum.Health > 0 then
        -- last resort: destroy the humanoid so char is cleaned up
        pcall(function() hum:Destroy() end)
    end
end

local function startNewRound(source)
    if not autoKillEnabled then return end
    log("NEW ROUND — " .. (source or "unknown"))
    bagFullThisRound = false
    latestCoins = 0
    latestMaxCoins = 0
    lastTargetName = nil
    roundStartedAt = tick()
    resettingStartedAt = 0
    charAtResetStart = nil
    state = STATE.KILLING
end

local function goIdle(reason)
    if state ~= STATE.IDLE then
        log("IDLE — " .. (reason or ""))
    end
    state = STATE.IDLE
    bagFullThisRound = false
    latestCoins = 0
    latestMaxCoins = 0
    lastTargetName = nil
end

-- Main loop
task.spawn(function()
    while true do
        task.wait(0.1)

        if not autoKillEnabled then
            if state ~= STATE.IDLE then goIdle("toggle off") end
            continue
        end

        -- Auto-start if we're idle with a knife (covers missed GiveWeapon)
        if state == STATE.IDLE then
            if hasKnife() then
                startNewRound("knife present in IDLE")
            end
            continue
        end

        if state == STATE.KILLING then
            if not hasKnife() then
                goIdle("knife gone mid-round")
                continue
            end

            local living = getLivingCount()
            if living <= 1 then
                log(string.format("Only %d living — WAITING for max coins (%d/%d)",
                    living, latestCoins, latestMaxCoins))
                state = STATE.WAITING
                lastTargetName = nil
                task.wait(0.3)
                continue
            end

            local targetName = getCurrentTargetName()
            if not targetName then
                -- No GUI target — wait. Warn once if it's been too long.
                if tick() - roundStartedAt > NO_TARGET_WARN_AFTER and not lastTargetName then
                    log("WARNING — no target name after " .. math.floor(tick() - roundStartedAt) .. "s (GUI path may have changed)")
                end
                task.wait(0.2)
            else
                lastTargetName = targetName
                local before = living
                log(string.format("Firing at %s (%d living)", targetName, before))
                local ok = killTarget(targetName)
                if ok then
                    -- Wait for health to replicate before next kill
                    local timeout = tick() + REPLICATION_TIMEOUT
                    while tick() < timeout do
                        task.wait(0.2)
                        if getLivingCount() < before then break end
                    end
                    task.wait(0.3)
                else
                    task.wait(0.5)
                end
            end

        elseif state == STATE.WAITING then
            if not hasKnife() then
                goIdle("knife gone while waiting")
                continue
            end

            local living = getLivingCount()
            if living > 1 then
                log(string.format("%d living — back to KILLING", living))
                state = STATE.KILLING
            elseif bagFullThisRound then
                log(string.format("MAX COINS (%d/%d) — resetting self", latestCoins, latestMaxCoins))
                charAtResetStart = player.Character
                resetCharacter()
                state = STATE.RESETTING
                resettingStartedAt = tick()
            else
                task.wait(0.4)
            end

        elseif state == STATE.RESETTING then
            local newChar = player.Character ~= charAtResetStart
            local knifeGone = not hasKnife()
            local timedOut = tick() - resettingStartedAt > RESETTING_TIMEOUT

            if newChar or knifeGone or timedOut then
                goIdle(timedOut and "reset timeout" or (newChar and "new character" or "knife gone"))
            elseif tick() - resettingStartedAt > 2 then
                local char = player.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    resetCharacter()  -- retry
                end
            end
            task.wait(0.3)
        end
    end
end)

-- GiveWeapon — primary round-start signal
task.spawn(function()
    local ok, GiveWeapon = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("GiveWeapon", 10)
    end)
    if not ok or not GiveWeapon then
        log("GiveWeapon remote NOT FOUND — falling back to knife presence only")
        return
    end
    GiveWeapon.OnClientEvent:Connect(function(weaponName)
        if weaponName == "Knife" then
            startNewRound("GiveWeapon Knife")
        end
    end)
end)

-- CoinsStarted — soft fallback
task.spawn(function()
    local ok, CoinsStarted = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("CoinsStarted", 10)
    end)
    if not ok or not CoinsStarted then return end
    CoinsStarted.OnClientEvent:Connect(function(_data)
        if autoKillEnabled and state == STATE.IDLE and hasKnife() then
            startNewRound("CoinsStarted")
        end
    end)
end)

-- CoinCollected — exact arg order confirmed by you: (currencyId, current, max, extra)
task.spawn(function()
    local ok, CoinCollected = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("CoinCollected", 10)
    end)
    if not ok or not CoinCollected then
        log("CoinCollected remote NOT FOUND")
        return
    end
    CoinCollected.OnClientEvent:Connect(function(currencyId, currentCoins, maxCoins, extra)
        -- Only accept during an active round
        if state ~= STATE.KILLING and state ~= STATE.WAITING then return end
        if type(currentCoins) ~= "number" or type(maxCoins) ~= "number" then return end
        if maxCoins <= 0 then return end

        latestCoins = currentCoins
        latestMaxCoins = maxCoins

        if currentCoins >= maxCoins and not bagFullThisRound then
            bagFullThisRound = true
            log(string.format("BAG FULL (%d/%d)", currentCoins, maxCoins))
        end
    end)
end)

section:AddToggle("Auto-Kill All", function(v)
    autoKillEnabled = v
    if v then
        log("Toggle ON")
        if hasKnife() then
            startNewRound("toggle on with knife")
        else
            goIdle("toggle on, no knife yet")
        end
        shared.Notify("Assassin enabled", 2)
    else
        goIdle("toggle")
        shared.Notify("Assassin disabled", 2)
    end
end)

section:AddPlayerDropdown("Whitelist Player", function(p)
    if not table.find(whitelist, p.UserId) then
        table.insert(whitelist, p.UserId)
        shared.Notify(p.Name .. " whitelisted.", 2)
    end
end)

section:AddButton("Clear Whitelist", function()
    whitelist = {}
    shared.Notify("Whitelist cleared.", 2)
end)

log("Loaded")
shared.Notify("Assassin Kill loaded", 1)
