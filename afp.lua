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
local resetDoneThisRound = false
local latestCoins = 0
local latestMaxCoins = 0
local firedThisRound = {}
local roundStartedAt = 0
local resettingStartedAt = 0
local charAtResetStart = nil

local KILL_COOLDOWN = 1.0
local RESETTING_TIMEOUT = 8.0
local MIN_ROUND_AGE_FOR_RESET = 5.0

local function log(...) print("[Assassin]", ...) end

local function isWhitelisted(p)
    if typeof(p) == "Instance" and p:IsA("Player") then
        return table.find(whitelist, p.UserId) ~= nil
    elseif type(p) == "string" then
        local plr = Players:FindFirstChild(p)
        return plr and table.find(whitelist, plr.UserId) ~= nil
    end
    return false
end

local function hasToolNamed(p, toolName)
    if not p then return false end
    local bp = p:FindFirstChild("Backpack")
    if bp and bp:FindFirstChild(toolName) then return true end
    local char = p.Character
    if char and char:FindFirstChild(toolName) then return true end
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

local function getLivingOthers()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and not isWhitelisted(p) and hasToolNamed(p, "Knife") then
            table.insert(list, p)
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

-- Hard-guarded reset: only called from WAITING + bagFull path.
local function resetCharacter(roundAge)
    if not autoKillEnabled then return end
    if state ~= STATE.WAITING then return end
    if not bagFullThisRound then return end
    if resetDoneThisRound then return end
    if (roundAge or 0) < MIN_ROUND_AGE_FOR_RESET then
        log("reset blocked — round too fresh (" .. string.format("%.1f", roundAge or 0) .. "s)")
        return
    end
    resetDoneThisRound = true
    log("Attempting character reset")
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
        task.wait(0.15)
    end
    if hum.Parent and hum.Health > 0 then
        pcall(function() char:BreakJoints() end)
        task.wait(0.15)
    end
    if hum.Parent and hum.Health > 0 then
        log("WARNING — reset methods failed (health still " .. tostring(hum.Health) .. ")")
        pcall(function() hum:Destroy() end)
    else
        log("Character reset — health now " .. tostring(hum and hum.Health or "N/A"))
    end
end

local function startNewRound(source)
    if not autoKillEnabled then return end
    if state == STATE.RESETTING then
        log("Round start ignored — still resetting")
        return
    end
    log("NEW ROUND — " .. (source or "unknown"))
    bagFullThisRound = false
    resetDoneThisRound = false
    latestCoins = 0
    latestMaxCoins = 0
    firedThisRound = {}
    roundStartedAt = tick()
    resettingStartedAt = 0
    charAtResetStart = nil
    state = STATE.KILLING
end

local function goIdle(reason)
    if state ~= STATE.IDLE then log("IDLE — " .. (reason or "")) end
    state = STATE.IDLE
    bagFullThisRound = false
    resetDoneThisRound = false
    latestCoins = 0
    latestMaxCoins = 0
    firedThisRound = {}
    resettingStartedAt = 0
    charAtResetStart = nil
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
            if hasKnife() then startNewRound("knife present in IDLE") end
            continue
        end

        if state == STATE.KILLING then
            if not hasKnife() then goIdle("knife gone mid-round") continue end

            local others = getLivingOthers()
            local unkilled = 0
            for _, p in ipairs(others) do
                if not firedThisRound[p.Name] then unkilled = unkilled + 1 end
            end

            log(string.format("(knife-holders: %d, unkilled: %d)", #others, unkilled))

            if #others <= 1 then
                log(string.format("Only %d knife-holder(s) — WAITING for max coins (%d/%d)",
                    #others, latestCoins, latestMaxCoins))
                state = STATE.WAITING
                task.wait(0.3)
                continue
            end

            local targetName = getCurrentTargetName()
            if not targetName then
                task.wait(0.2)
            elseif firedThisRound[targetName] then
                task.wait(0.3)
            else
                log(string.format("Firing at %s (knife-holders: %d)", targetName, #others))
                if killTarget(targetName) then
                    firedThisRound[targetName] = true
                end
                task.wait(KILL_COOLDOWN)
            end

        elseif state == STATE.WAITING then
            if not hasKnife() then goIdle("knife gone while waiting") continue end

            local roundAge = tick() - roundStartedAt

            if bagFullThisRound
                and not resetDoneThisRound
                and roundAge >= MIN_ROUND_AGE_FOR_RESET then
                log(string.format("MAX COINS (%d/%d) — resetting self (age %.1fs)",
                    latestCoins, latestMaxCoins, roundAge))
                charAtResetStart = player.Character
                resetCharacter(roundAge)
                state = STATE.RESETTING
                resettingStartedAt = tick()
            else
                local others = getLivingOthers()
                if #others > 1 then
                    log(string.format("%d knife-holder(s) — back to KILLING", #others))
                    state = STATE.KILLING
                else
                    task.wait(0.4)
                end
            end

        elseif state == STATE.RESETTING then
            local elapsed = tick() - resettingStartedAt
            local newChar = player.Character ~= charAtResetStart
            local knifeGone = not hasKnife()
            if newChar then goIdle("new character")
            elseif knifeGone then goIdle("knife gone")
            elseif elapsed > RESETTING_TIMEOUT then goIdle("reset timeout")
            end
            task.wait(0.4)
        end
    end
end)

-- GiveWeapon
task.spawn(function()
    local ok, GiveWeapon = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("GiveWeapon", 10)
    end)
    if not ok or not GiveWeapon then log("GiveWeapon remote NOT FOUND") return end
    GiveWeapon.OnClientEvent:Connect(function(weaponName)
        if weaponName == "Knife" then startNewRound("GiveWeapon Knife") end
    end)
end)

-- CoinsStarted fallback
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

-- CoinCollected
task.spawn(function()
    local ok, CoinCollected = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("CoinCollected", 10)
    end)
    if not ok or not CoinCollected then log("CoinCollected remote NOT FOUND") return end
    CoinCollected.OnClientEvent:Connect(function(_currencyId, currentCoins, maxCoins, _extra)
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
        if state == STATE.RESETTING then
            goIdle("toggle on — clearing stale resetting")
        end
        if hasKnife() then startNewRound("toggle on with knife")
        else goIdle("toggle on, no knife") end
        shared.Notify("Assassin enabled", 2)
    else
        goIdle("toggle")
        shared.Notify("Assassin disabled", 2)
    end
end)

section:AddButton("Force Reset Round", function()
    goIdle("manual force reset")
    shared.Notify("Round state cleared.", 2)
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
