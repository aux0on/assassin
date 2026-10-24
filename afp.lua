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
local lastKillAt = 0
local roundStartedAt = 0
local resettingStartedAt = 0

local KILL_COOLDOWN = 1.0        -- min seconds between knife fires
local REPLICATION_TIMEOUT = 3.0  -- how long to wait for a kill to replicate
local KNIFE_GRACE = 5.0          -- GiveWeapon can arrive before the tool replicates
local RESETTING_TIMEOUT = 8.0    -- abort RESETTING if death never registers

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

local function getMyHumanoid()
    local char = player.Character
    if char then return char:FindFirstChildOfClass("Humanoid") end
    return nil
end

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
        if text and text ~= "" and text ~= "Nikilis" then return text end
    end
    return nil
end

local function fireKnifeKill(part)
    local knife = getKnife()
    if not knife then return false end
    local events = knife:FindFirstChild("Events")
    if not events then return false end
    local handleTouched = events:FindFirstChild("HandleTouched")
    if not handleTouched then return false end
    handleTouched:FireServer(part)
    return true
end

local function fireAtPlayer(p)
    if not p or not p.Character or isWhitelisted(p) then return false end
    local part = getKillPart(p.Character)
    local hum = p.Character:FindFirstChildOfClass("Humanoid")
    if part and hum and hum.Health > 0 then
        return fireKnifeKill(part)
    end
    return false
end

local function resetMyCharacter()
    local char = player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        pcall(function() char:BreakJoints() end)
        return
    end
    pcall(function() hum.Health = 0 end)
    task.wait(0.1)
    if hum.Parent and hum.Health > 0 then
        pcall(function() hum:TakeDamage(hum.MaxHealth * 2) end)
    end
end

local function startNewRound()
    if not autoKillEnabled then return end
    log("NEW ROUND — GiveWeapon Knife")
    state = STATE.KILLING
    bagFullThisRound = false
    latestCoins = 0
    latestMaxCoins = 0
    lastKillAt = 0
    roundStartedAt = tick()
    resettingStartedAt = 0
end

local function goIdle(reason)
    if state ~= STATE.IDLE then
        log("IDLE — " .. (reason or ""))
    end
    state = STATE.IDLE
    bagFullThisRound = false
    latestCoins = 0
    latestMaxCoins = 0
end

-- Main loop
task.spawn(function()
    while true do
        task.wait(0.1)

        if not autoKillEnabled then
            if state ~= STATE.IDLE then goIdle("toggle off") end
            continue
        end

        if state == STATE.IDLE then
            if hasKnife() then startNewRound() end
            continue
        end

        if state == STATE.RESETTING then
            local myHum = getMyHumanoid()
            local isDead = not hasKnife() or (myHum and myHum.Health <= 0)
            local timedOut = resettingStartedAt > 0 and tick() - resettingStartedAt > RESETTING_TIMEOUT
            if isDead or timedOut then
                goIdle(timedOut and "reset timeout" or "reset complete")
            end
            continue
        end

        -- Knife disappeared mid-round (we died, or the tool was removed)
        if not hasKnife() and tick() - roundStartedAt > KNIFE_GRACE then
            goIdle("knife gone mid-round")
            continue
        end

        if state == STATE.KILLING then
            local living = getLivingPlayers()
            if #living <= 1 then
                state = STATE.WAITING
                log(string.format("1 living — WAITING for max coins (%d/%d)", latestCoins, latestMaxCoins))
            elseif tick() - lastKillAt >= KILL_COOLDOWN then
                -- Prefer a non-target victim so the Assassin target is the survivor
                local targetName = getCurrentTargetName()
                local victim = nil
                for _, p in ipairs(living) do
                    if not (targetName and p.Name == targetName) then
                        victim = p
                        break
                    end
                end
                if not victim then victim = living[1] end

                local beforeCount = #living
                if fireAtPlayer(victim) then
                    lastKillAt = tick()
                    log(string.format("Fired at %s (%d living)", victim.Name, beforeCount))
                    -- Wait for health to actually replicate before the next kill
                    local timeout = tick() + REPLICATION_TIMEOUT
                    while tick() < timeout do
                        task.wait(0.2)
                        local now = #getLivingPlayers()
                        if now < beforeCount then
                            log(string.format("Confirmed (%d living now)", now))
                            break
                        end
                    end
                end
            end
        elseif state == STATE.WAITING then
            if bagFullThisRound then
                log(string.format("MAX COINS (%d/%d) — resetting self", latestCoins, latestMaxCoins))
                resetMyCharacter()
                state = STATE.RESETTING
                resettingStartedAt = tick()
            else
                local living = getLivingPlayers()
                if #living == 0 then
                    goIdle("no players left")
                elseif #living > 1 then
                    log("More than 1 living — back to KILLING")
                    state = STATE.KILLING
                end
            end
        end
    end
end)

-- GiveWeapon — primary round-start signal
task.spawn(function()
    local ok, GiveWeapon = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("GiveWeapon", 10)
    end)
    if not ok or not GiveWeapon then
        log("GiveWeapon remote not found")
        return
    end
    GiveWeapon.OnClientEvent:Connect(function(weaponName)
        if weaponName == "Knife" then
            startNewRound()
        end
    end)
end)

-- CoinsStarted — soft fallback in case GiveWeapon was missed
task.spawn(function()
    local ok, CoinsStarted = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("CoinsStarted", 10)
    end)
    if not ok or not CoinsStarted then return end
    CoinsStarted.OnClientEvent:Connect(function(_data)
        if autoKillEnabled and state == STATE.IDLE and hasKnife() then
            log("CoinsStarted with knife — starting")
            startNewRound()
        end
    end)
end)

-- CoinCollected — max detection: args are (currencyId, current, max, extra)
task.spawn(function()
    local ok, CoinCollected = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("CoinCollected", 10)
    end)
    if not ok or not CoinCollected then
        log("CoinCollected remote not found")
        return
    end
    CoinCollected.OnClientEvent:Connect(function(currencyId, currentCoins, maxCoins, _extra)
        if not autoKillEnabled then return end
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
    goIdle("toggle")
    if v then
        if hasKnife() then
            log("Toggle on with knife — starting")
            startNewRound()
        end
        shared.Notify("Assassin enabled", 2)
    else
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

shared.Notify("Assassin Kill loaded", 1)
