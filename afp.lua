local shared = odh_shared_plugins

shared.load_from_github_url("/aux0on/CrashHandler/refs/heads/main/Prevention.lua")

-- delta fix: poll until game_name resolves
local _t = tick() + 6
repeat task.wait(0.15) until shared.game_name ~= nil or tick() > _t

if shared.game_name ~= "Murder Mystery 2" then return end

local afp = shared.CreateTab("Autofarm+", "/aux0on/AFPIcon/refs/heads/main/Untitled163_20260919023714")
local section = afp:AddSection("Assassin")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

while not Players.LocalPlayer do task.wait() end
local player = Players.LocalPlayer

local autoKillEnabled = false
local whitelist = {}

local STATE = {
    IDLE    = "IDLE",
    KILLING = "KILLING",
    WAITING = "WAITING",
    FINAL   = "FINAL",
    DONE    = "DONE",
}

local state = STATE.IDLE
local maxCoinsReached = false

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
        if p ~= player and not isWhitelisted(p) and p.Character then
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                table.insert(list, p)
            end
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
    local obj = assassinTarget:FindFirstChild("TargetName")
    if obj and (obj:IsA("TextLabel") or obj:IsA("TextBox")) then
        local text = obj.Text
        if text and text ~= "" and text ~= "Nikilis" then
            return text
        end
    end
    return nil
end

local function fireKnifeAt(part)
    local knife = getKnife()
    if not knife then return false end
    local events = knife:FindFirstChild("Events")
    if not events then return false end
    local ht = events:FindFirstChild("HandleTouched")
    if not ht then return false end
    ht:FireServer(part)
    return true
end

local function killPlayer(p)
    if not p or isWhitelisted(p) or not p.Character then return false end
    local part = getKillPart(p.Character)
    local hum = p.Character:FindFirstChildOfClass("Humanoid")
    if part and hum and hum.Health > 0 then
        return fireKnifeAt(part)
    end
    return false
end

local function resetRoundState()
    maxCoinsReached = false
end

-- main loop
task.spawn(function()
    while true do
        task.wait(0.1)

        if not autoKillEnabled then
            if state ~= STATE.IDLE then
                state = STATE.IDLE
                resetRoundState()
            end
            continue
        end

        if not hasKnife() then
            if state ~= STATE.IDLE then
                log("knife gone — waiting for next round")
                state = STATE.IDLE
                resetRoundState()
            end
            continue
        end

        -- knife just appeared
        if state == STATE.IDLE then
            resetRoundState()
            log("knife detected — starting in 1.5s")
            task.wait(1.5)
            if not hasKnife() or not autoKillEnabled then continue end
            state = STATE.KILLING
            log("KILLING — leaving 1 alive")
        end

        if state == STATE.KILLING then
            local targetName = getCurrentTargetName()

            -- no target name yet — UI hasn't loaded, wait and retry
            if not targetName then
                task.wait(0.2)
                continue
            end

            local living = getLivingPlayers()

            -- 1 or fewer left — go wait for max coins
            if #living <= 1 then
                log("1 target remaining — WAITING for max coins")
                state = STATE.WAITING
                continue
            end

            -- kill anyone who is NOT our current assigned target
            local killed = false
            for _, p in ipairs(living) do
                if p.Name ~= targetName then
                    if killPlayer(p) then
                        log("killed " .. p.Name)
                        killed = true
                        break
                    end
                end
            end

            -- no non-target found but >1 alive — all remaining must be target chain edge case
            -- just go to WAITING so we never kill the last one early
            if not killed then
                log("no non-target to kill — moving to WAITING")
                state = STATE.WAITING
            else
                task.wait(0.5)
            end

        elseif state == STATE.WAITING then
            local living = getLivingPlayers()

            if #living == 0 then
                log("no targets left — DONE")
                state = STATE.DONE
                continue
            end

            if maxCoinsReached then
                log("max coins reached — FINAL kill")
                state = STATE.FINAL
            end

        elseif state == STATE.FINAL then
            local living = getLivingPlayers()

            if #living == 0 then
                log("last target dead — round complete")
                state = STATE.DONE
                continue
            end

            -- kill every remaining player (should just be 1)
            for _, p in ipairs(living) do
                if killPlayer(p) then
                    log("final kill: " .. p.Name)
                end
            end
            task.wait(0.5)

        elseif state == STATE.DONE then
            -- sit here until knife disappears (handled at top)
        end
    end
end)

-- coin tracking
task.spawn(function()
    local ok, CoinCollected = pcall(function()
        return ReplicatedStorage
            :WaitForChild("Remotes", 10)
            :WaitForChild("Gameplay", 10)
            :WaitForChild("CoinCollected", 10)
    end)
    if not ok or not CoinCollected then
        log("CoinCollected remote not found")
        return
    end

    CoinCollected.OnClientEvent:Connect(function(a, b, c)
        if not autoKillEnabled then return end
        if maxCoinsReached then return end
        if state ~= STATE.KILLING and state ~= STATE.WAITING then return end

        local current, max
        if typeof(b) == "number" and typeof(c) == "number" then
            current, max = b, c
        elseif typeof(a) == "number" and typeof(b) == "number" then
            current, max = a, b
        else
            return
        end

        if max > 0 and current >= max then
            maxCoinsReached = true
            log(string.format("bag full (%d/%d)", current, max))
        end
    end)
end)

section:AddToggle("Auto-Kill All", function(v)
    autoKillEnabled = v
    state = STATE.IDLE
    resetRoundState()
    shared.Notify(v and "Assassin enabled" or "Assassin disabled", 2)
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
