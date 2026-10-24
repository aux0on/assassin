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

local STATE = { IDLE = "IDLE", KILLING = "KILLING", WAITING = "WAITING", FINAL = "FINAL", DONE = "DONE" }
local state = STATE.IDLE
local currentKnifeRef = nil

-- Per-round coin tracking (reset every round)
local latestCoins = 0
local latestMaxCoins = 0
local bagFullThisRound = false

-- Per-round kill tracking
local firedTargets = {}     -- names we have fired at this round
local lastTargetName = nil
local lastKillAt = 0
local TARGET_RETRY_DELAY = 4.0
local FALLBACK_COOLDOWN = 1.2

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

local function getActualLivingPlayers()
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

local function resetRound(reason)
    if state ~= STATE.IDLE then
        print("[Assassin] Reset — " .. (reason or "manual"))
    end
    state = STATE.IDLE
    latestCoins = 0
    latestMaxCoins = 0
    bagFullThisRound = false
    firedTargets = {}
    lastTargetName = nil
    lastKillAt = 0
end

-- Main state machine
task.spawn(function()
    while true do
        task.wait(0.1)

        if not autoKillEnabled then
            if state ~= STATE.IDLE then resetRound("toggle off") end
            currentKnifeRef = nil
            continue
        end

        local knife = getKnife()
        if not knife then
            if state ~= STATE.IDLE then resetRound("knife gone") end
            currentKnifeRef = nil
            continue
        end

        -- New tool instance means new round, even if old one never disappeared
        if currentKnifeRef ~= nil and knife ~= currentKnifeRef then
            resetRound("new knife instance")
        end
        currentKnifeRef = knife

        if state == STATE.IDLE then
            latestCoins = 0
            latestMaxCoins = 0
            bagFullThisRound = false
            firedTargets = {}
            lastTargetName = nil
            lastKillAt = 0
            state = STATE.KILLING
            print("[Assassin] Knife detected — starting (targets: " .. #getActualLivingPlayers() .. ")")
            task.wait(1.5)
            if not hasKnife() then resetRound("knife gone at startup") continue end
        end

        if state == STATE.KILLING then
            local living = getActualLivingPlayers()
            local unfired = 0
            for _, p in ipairs(living) do
                if not firedTargets[p.Name] then unfired = unfired + 1 end
            end

            if unfired <= 1 then
                state = STATE.WAITING
                print(string.format("[Assassin] %d unfired — waiting for max coins (%d/%d)",
                    unfired, latestCoins, latestMaxCoins))
            else
                local targetName = getCurrentTargetName()

                if targetName and isWhitelisted(targetName) then
                    state = STATE.WAITING
                    print("[Assassin] Target is whitelisted — waiting")
                elseif targetName then
                    local target = Players:FindFirstChild(targetName)
                    local hum = target and target.Character and target.Character:FindFirstChildOfClass("Humanoid")

                    if target and hum and hum.Health > 0 then
                        if not firedTargets[targetName] then
                            if fireAtPlayer(target) then
                                firedTargets[targetName] = true
                                lastTargetName = targetName
                                lastKillAt = tick()
                                print("[Assassin] Fired at " .. targetName)
                            end
                        elseif tick() - lastKillAt >= TARGET_RETRY_DELAY then
                            if fireAtPlayer(target) then
                                lastKillAt = tick()
                                print("[Assassin] Retried " .. targetName)
                            end
                        end
                    else
                        task.wait(0.3)
                    end
                else
                    task.wait(0.2)
                end
            end

        elseif state == STATE.WAITING then
            local living = getActualLivingPlayers()
            if #living == 0 then
                state = STATE.DONE
                print("[Assassin] No targets — done")
            elseif #living > 1 then
                local unfired = 0
                for _, p in ipairs(living) do
                    if not firedTargets[p.Name] then unfired = unfired + 1 end
                end
                if unfired > 1 then
                    print("[Assassin] " .. unfired .. " unfired appeared — resuming KILLING")
                    state = STATE.KILLING
                else
                    -- All living already fired at; wait for health replication
                    task.wait(0.5)
                end
            elseif bagFullThisRound then
                state = STATE.FINAL
                lastKillAt = 0
                print("[Assassin] Bag full — final kill")
            end

        elseif state == STATE.FINAL then
            local living = getActualLivingPlayers()
            if #living == 0 then
                state = STATE.DONE
                print("[Assassin] Round complete")
            elseif #living > 1 then
                print("[Assassin] FINAL aborted — " .. #living .. " living, back to WAITING")
                state = STATE.WAITING
            elseif tick() - lastKillAt >= FALLBACK_COOLDOWN then
                local victim = living[1]
                if victim and fireAtPlayer(victim) then
                    lastKillAt = tick()
                    print("[Assassin] Final kill fired at " .. victim.Name)
                end
            end
            task.wait(0.2)

        elseif state == STATE.DONE then
            -- Idle until knife disappears or is replaced
        end
    end
end)

-- CoinCollected — EXACT Autofarm+ signature, and only accepted during the current round
task.spawn(function()
    local ok, CoinCollected = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Gameplay"):WaitForChild("CoinCollected", 10)
    end)
    if not ok or not CoinCollected then
        shared.Notify("CoinCollected remote missing", 3)
        return
    end

    CoinCollected.OnClientEvent:Connect(function(_, currentCoins, maxCoins)
        if not autoKillEnabled then return end
        -- Reject events that arrive outside an active round
        if state ~= STATE.KILLING and state ~= STATE.WAITING then return end
        if type(currentCoins) ~= "number" or type(maxCoins) ~= "number" then return end
        if maxCoins <= 0 then return end

        latestCoins = currentCoins
        latestMaxCoins = maxCoins

        if currentCoins >= maxCoins and not bagFullThisRound then
            bagFullThisRound = true
            print(string.format("[Assassin] Bag full (%d/%d)", currentCoins, maxCoins))
        end
    end)
end)

section:AddToggle("Auto-Kill All", function(v)
    autoKillEnabled = v
    resetRound("toggle")
    currentKnifeRef = nil
    if v then
        shared.Notify("Assassin Enabled", 2)
    else
        shared.Notify("Assassin Disabled", 2)
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

shared.Notify("Assassin AFP Loaded Successfully!", 1)
