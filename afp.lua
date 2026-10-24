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
local firedThisRound = {}     -- names we've fired at this round
local roundStartedAt = 0
local resettingStartedAt = 0
local charAtResetStart = nil
local lastSeenTarget = nil

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

local function getCurrentTargetName()
    local pGui = player:FindFirstChild("PlayerGui")
    if not pGui then return nil end
    local mainGui = pGui:FindFirstChild("MainGUI")
    if not mainGui then return end nil
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
    lastSeenTarget = nil
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
    lastSeenTarget = nil
    resettingStartedAt = 0
    charAtResetStart = nil
end

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

            local targetName = getCurrentTargetName()
            log(string.format("(target: %s, fired: %d)",
                tostring(targetName), #firedThisRound))

            -- Case 1: GUI has no target
            if not targetName then
                task.wait(0.3)
                continue
            end

            -- Case 2: target is already in our fired set
            -- This is normal immediately after a kill. Wait for the GUI to advance.
            if firedThisRound[targetName] then
                task.wait(0.4)
                continue
            end

            -- Case 3: target is whitelisted — treat as "last one left"
            if isWhitelisted(targetName) then
                log("Target is whitelisted — WAITING for max coins")
                state = STATE.WAITING
                task.wait(0.3)
                continue
            end

            -- Count how many other knife-holders remain (best-effort).
            -- We use PlayerGui as the source of truth: once we've fired at all but one
            -- target name that existed, we should stop.
            local allPlayers = Players:GetPlayers()
            local liveKnifeHolders = {}
            for _, p in ipairs(allPlayers) do
                if p ~= player and not isWhitelisted(p) then
                    local bp = p:FindFirstChild("Backpack")
                    local ch = p.Character
                    local holdsKnife = (bp and bp:FindFirstChild("Knife"))
                        or (ch and ch:FindFirstChild("Knife"))
                    if holdsKnife then
                        table.insert(liveKnifeHolders, p)
                    end
                end
            end

            -- Filter out anyone we've already fired at — they're dead
            local unkilledHolders = {}
            for _, p in ipairs(liveKnifeHolders) do
                if not firedThisRound[p.Name] then
                    table.insert(unkilledHolders, p)
                end
            end

            log(string.format("(knife-holders: %d, unkilled: %d, target: %s)",
                #liveKnifeHolders, #unkilledHolders, targetName))

            if #liveKnifeHolders > 0 and #unkilledHolders <= 1 then
                log("Only 1 unkilled knife-holder — WAITING for max coins")
                state = STATE.WAITING
                task.wait(0.3)
                continue
            end

            -- If we can't count knife-holders reliably (0), fall back to
            -- "we've seen and killed all names except the current target"
            if #liveKnifeHolders == 0 and #firedThisRound >= 1 then
                -- At least one kill already happened and no knife-holders are visible.
                -- Keep going only if the target is new.
                if not firedThisRound[targetName] then
                    log(string.format("Firing at %s (fired so far: %d)", targetName, #firedThisRound))
                    if killTarget(targetName) then
                        firedThisRound[targetName] = true
                        lastSeenTarget = targetName
                    end
                    task.wait(KILL_COOLDOWN)
                end
                continue
            end

            -- Normal case: fire at current target
            log(string.format("Firing at %s (knife-holders: %d, unkilled: %d)",
                targetName, #liveKnifeHolders, #unkilledHolders))
            if killTarget(targetName) then
                firedThisRound[targetName] = true
                lastSeenTarget = targetName
            end
            task.wait(KILL_COOLDOWN)

        elseif state == STATE.WAITING then
            if not hasKnife() then goIdle("knife gone while waiting") continue end

            local roundAge = tick() - roundStartedAt

            if bagFullThisRound and not resetDoneThisRound and roundAge >= MIN_ROUND_AGE_FOR_RESET then
                log(string.format("MAX COINS (%d/%d) — resetting self (age %.1fs)",
                    latestCoins, latestMaxCoins, roundAge))
                charAtResetStart = player.Character
                resetCharacter(roundAge)
                state = STATE.RESETTING
                resettingStartedAt = tick()
            else
                -- Only leave WAITING if a brand-new target name appears that we haven't fired at
                local targetName = getCurrentTargetName()
                if targetName and not firedThisRound[targetName]
                    and not isWhitelisted(targetName)
                    and targetName ~= lastSeenTarget then
                    log("New target appeared: " .. targetName .. " — back to KILLING")
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

task.spawn(function()
    local ok, GiveWeapon = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 10):WaitForChild("Gameplay", 10):WaitForChild("GiveWeapon", 10)
    end)
    if not ok or not GiveWeapon then log("GiveWeapon remote NOT FOUND") return end
    GiveWeapon.OnClientEvent:Connect(function(weaponName)
        if weaponName == "Knife" then startNewRound("GiveWeapon Knife") end
    end)
end)

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
        if state == STATE.RESETTING then goIdle("toggle on — clearing stale resetting") end
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
