local shared = odh_shared_plugins

shared.load_from_github_url("/aux0on/CrashHandler/refs/heads/main/Prevention.lua")

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
local maxCoinsReached = false

local STATE = { IDLE = "IDLE", KILLING = "KILLING", WAITING = "WAITING", FINAL = "FINAL" }
local state = STATE.IDLE

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

local function getKillPart(char)
    if not char then return nil end
    return char:FindFirstChild("UpperTorso")
        or char:FindFirstChild("Torso")
        or char:FindFirstChild("HumanoidRootPart")
end

-- count living non-self non-whitelisted players
local function getLivingCount()
    local n = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and not isWhitelisted(p) and p.Character then
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then n += 1 end
        end
    end
    return n
end

-- read target name directly via FindFirstChild — no yielding
local function getTargetName()
    local gui = player:FindFirstChild("PlayerGui")
    if not gui then return nil end
    local main = gui:FindFirstChild("MainGUI")
    if not main then return nil end
    local game_ = main:FindFirstChild("Game")
    if not game_ then return nil end
    local at = game_:FindFirstChild("AssassinTarget")
    if not at then return nil end
    local tn = at:FindFirstChild("TargetName")
    if not tn then return nil end
    local text = tn.Text
    if text and text ~= "" and text ~= "Nikilis" then
        return text
    end
    return nil
end

local function fireKnife(part)
    local knife = getKnife()
    if not knife then return false end
    local events = knife:FindFirstChild("Events")
    if not events then return false end
    local ht = events:FindFirstChild("HandleTouched")
    if not ht then return false end
    ht:FireServer(part)
    return true
end

local function killTarget(name)
    if not name or isWhitelisted(name) then return false end
    local p = Players:FindFirstChild(name)
    if not p or not p.Character then return false end
    local part = getKillPart(p.Character)
    local hum = p.Character:FindFirstChildOfClass("Humanoid")
    if part and hum and hum.Health > 0 then
        return fireKnife(part)
    end
    return false
end

local function killAllRemaining()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and not isWhitelisted(p) and p.Character then
            local part = getKillPart(p.Character)
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if part and hum and hum.Health > 0 then
                fireKnife(part)
            end
        end
    end
end

-- main loop
task.spawn(function()
    while true do
        task.wait(0.12)

        if not autoKillEnabled then
            state = STATE.IDLE
            maxCoinsReached = false
            continue
        end

        -- lost knife mid-round or round ended
        if not hasKnife() then
            if state ~= STATE.IDLE then
                log("knife gone — resetting")
                state = STATE.IDLE
                maxCoinsReached = false
            end
            continue
        end

        if state == STATE.IDLE then
            -- knife appeared, new round starting
            log("knife detected — waiting 1.5s before killing")
            task.wait(1.5)
            if not hasKnife() or not autoKillEnabled then continue end
            maxCoinsReached = false
            state = STATE.KILLING
            log("KILLING started")
        end

        if state == STATE.KILLING then
            local living = getLivingCount()

            if living <= 1 then
                -- one left — hold off and wait for max coins
                log("1 player remaining — waiting for max coins")
                state = STATE.WAITING
                continue
            end

            -- more than 1 alive — kill current assigned target
            local targetName = getTargetName()
            if not targetName then
                -- target name not visible yet, retry
                task.wait(0.15)
                continue
            end

            local killed = killTarget(targetName)
            log((killed and "killed " or "missed ") .. targetName .. " | living: " .. living)
            task.wait(killed and 0.6 or 0.15)

        elseif state == STATE.WAITING then
            if getLivingCount() == 0 then
                -- someone else finished the last kill
                log("no one left — done")
                state = STATE.IDLE
                maxCoinsReached = false
                continue
            end

            if maxCoinsReached then
                log("max coins — killing final player")
                state = STATE.FINAL
            end

        elseif state == STATE.FINAL then
            killAllRemaining()
            task.wait(0.5)
            if getLivingCount() == 0 then
                log("final kill done — round complete")
                state = STATE.IDLE
                maxCoinsReached = false
            end
        end
    end
end)

-- coin tracking
task.spawn(function()
    local ok, remote = pcall(function()
        return ReplicatedStorage
            :WaitForChild("Remotes", 10)
            :WaitForChild("Gameplay", 10)
            :WaitForChild("CoinCollected", 10)
    end)
    if not ok or not remote then
        log("CoinCollected remote not found")
        return
    end

    remote.OnClientEvent:Connect(function(a, b, c)
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
            log(string.format("bag full (%d/%d) — final kill armed", current, max))
        end
    end)
end)

section:AddToggle("Auto-Kill All", function(v)
    autoKillEnabled = v
    state = STATE.IDLE
    maxCoinsReached = false
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
