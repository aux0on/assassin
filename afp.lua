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

-- Strict round state machine
local STATE = {
    IDLE = "IDLE",       -- no knife / disabled
    KILLING = "KILLING", -- knife detected, killing down to 1
    WAITING = "WAITING", -- exactly 1 target left, waiting for max coins
    FINAL = "FINAL",     -- max coins reached, killing the last one
    DONE = "DONE",       -- round finished, waiting for knife to vanish
}

local state = STATE.IDLE
local maxCoinsReached = false

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

local function hasKnife()
    return getKnife() ~= nil
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
            if hum and hum.Health > 0 then
                table.insert(list, p)
            end
        end
    end
    return list
end

local function getLivingCount()
    return #getLivingPlayers()
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
        if text and text ~= "" and text ~= "Nikilis" then
            return text
        end
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

local function killPlayer(p)
    if not p or not p.Character or isWhitelisted(p) then return false end
    local part = getKillPart(p.Character)
    local hum = p.Character:FindFirstChildOfClass("Humanoid")
    if part and hum and hum.Health > 0 then
        return fireKnifeKill(part)
    end
    return false
end

local function killTarget(name)
    if not name or isWhitelisted(name) then return false end
    local target = Players:FindFirstChild(name)
    if not target then return false end
    return killPlayer(target)
end

local function killAllRemaining()
    for _, p in ipairs(getLivingPlayers()) do
        killPlayer(p)
    end
end

-- Strict state machine: one path, no overlapping loops
task.spawn(function()
    while true do
        task.wait(0.1)

        if not autoKillEnabled then
            state = STATE.IDLE
            maxCoinsReached = false
            continue
        end

        if not hasKnife() then
            if state ~= STATE.IDLE then
                print("[Assassin] Knife no longer detected — reset for next round")
            end
            state = STATE.IDLE
            maxCoinsReached = false
            continue
        end

        if state == STATE.IDLE then
            state = STATE.KILLING
            maxCoinsReached = false
            print("[Assassin] Knife detected — killing all but 1")
            task.wait(1.35)
            if not hasKnife() then
                state = STATE.IDLE
                continue
            end
        end

        if state == STATE.KILLING then
            local living = getLivingCount()
            if living == 0 then
                state = STATE.DONE
                print("[Assassin] No living targets — done")
            elseif living == 1 then
                state = STATE.WAITING
                print("[Assassin] 1 target left — waiting for max coins")
            else
                local targetName = getCurrentTargetName()
                local livingPlayers = getLivingPlayers()
                local didKill = false

                -- Strictly avoid the assassin's assigned target while others remain.
                for _, p in ipairs(livingPlayers) do
                    if not (targetName and p.Name == targetName) then
                        if killPlayer(p) then
                            didKill = true
                            break
                        end
                    end
                end

                -- Fallback only if a non-target could not be killed and >1 remain.
                if not didKill and living > 1 then
                    for _, p in ipairs(livingPlayers) do
                        if killPlayer(p) then
                            didKill = true
                            break
                        end
                    end
                end

                task.wait(didKill and 0.5 or 0.12)
            end
        elseif state == STATE.WAITING then
            if getLivingCount() == 0 then
                state = STATE.DONE
                print("[Assassin] All targets gone — done")
            elseif maxCoinsReached then
                state = STATE.FINAL
                print("[Assassin] Max coins reached — killing the last target")
            end
        elseif state == STATE.FINAL then
            if getLivingCount() <= 0 then
                state = STATE.DONE
                print("[Assassin] Last target eliminated — round complete")
            else
                killAllRemaining()
                task.wait(0.5)
            end
        elseif state == STATE.DONE then
            -- Idle until the knife disappears; reset happens above.
        end
    end
end)

-- Max coins detection: only arms the FINAL state, never kills directly.
task.spawn(function()
    local ok, CoinCollected = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Gameplay"):WaitForChild("CoinCollected", 10)
    end)
    if not ok or not CoinCollected then
        shared.Notify("CoinCollected remote missing", 3)
        return
    end

    CoinCollected.OnClientEvent:Connect(function(a, b, c)
        if not autoKillEnabled then return end
        if maxCoinsReached then return end
        if state ~= STATE.KILLING and state ~= STATE.WAITING then return end

        local currentCoins, maxCoins
        if typeof(b) == "number" and typeof(c) == "number" then
            currentCoins, maxCoins = b, c
        elseif typeof(a) == "number" and typeof(b) == "number" then
            currentCoins, maxCoins = a, b
        else
            return
        end

        if currentCoins >= maxCoins then
            maxCoinsReached = true
            print(string.format("[Assassin] Max coins detected (%d/%d)", currentCoins, maxCoins))
        end
    end)
end)

section:AddToggle("Auto-Kill All", function(v)
    autoKillEnabled = v
    state = STATE.IDLE
    maxCoinsReached = false
    if v then
        shared.Notify("Assassin enabled — kill all but 1, final kill at max bag", 2)
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
