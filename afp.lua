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
local activeKill = nil -- current rapidKill coroutine name

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

local function getTargetName()
    local gui = player:FindFirstChild("PlayerGui")
    if not gui then return nil end
    local main = gui:FindFirstChild("MainGUI")
    if not main then return nil end
    local g = main:FindFirstChild("Game")
    if not g then return nil end
    local at = g:FindFirstChild("AssassinTarget")
    if not at then return nil end
    local tn = at:FindFirstChild("TargetName")
    if not tn then return nil end
    local text = tn.Text
    if text and text ~= "" and text ~= "Nikilis" then return text end
    return nil
end

-- fire the knife remote directly, no wrappers
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

-- attempt one kill on a named player, returns true if remote fired
local function tryKill(name)
    if not name or isWhitelisted(name) then return false end
    local p = Players:FindFirstChild(name)
    if not p or not p.Character then return false end
    local hum = p.Character:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    local part = getKillPart(p.Character)
    if not part then return false end
    return fireKnifeAt(part)
end

-- tight retry loop on one target until target text changes or they die
local function rapidKill(name)
    if not name then return end
    activeKill = name
    while autoKillEnabled and hasKnife() do
        local current = getTargetName()
        -- target changed = they died, new target assigned
        if current ~= name then break end
        local p = Players:FindFirstChild(name)
        if not p or not p.Character then break end
        local hum = p.Character:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then break end
        local part = getKillPart(p.Character)
        if part then fireKnifeAt(part) end
        task.wait(0.05)
    end
    if activeKill == name then activeKill = nil end
end

-- core decision: given current target name, decide what to do
local function handleTarget(name)
    if not autoKillEnabled or not name then return end
    if not hasKnife() then return end

    local living = getLivingCount()

    if state == STATE.IDLE then
        state = STATE.KILLING
    end

    if state == STATE.KILLING then
        if living <= 1 then
            state = STATE.WAITING
            log("1 left — holding for max coins")
            if maxCoinsReached then
                state = STATE.FINAL
                task.spawn(function()
                    rapidKill(name)
                    state = STATE.IDLE
                    maxCoinsReached = false
                end)
            end
            return
        end
        -- spawn retry loop, first shot fires inside synchronously before yield
        task.spawn(function() rapidKill(name) end)

    elseif state == STATE.WAITING then
        if maxCoinsReached then
            state = STATE.FINAL
            task.spawn(function()
                rapidKill(name)
                state = STATE.IDLE
                maxCoinsReached = false
            end)
        end

    elseif state == STATE.FINAL then
        task.spawn(function()
            rapidKill(name)
            state = STATE.IDLE
            maxCoinsReached = false
        end)
    end
end

-- called the frame knife lands in backpack or character
local function onKnifeDetected()
    if not autoKillEnabled then return end
    log("knife detected — firing instantly")
    state = STATE.KILLING
    maxCoinsReached = false

    local name = getTargetName()

    if name then
        -- fire immediately inline, no spawn, no delay
        tryKill(name)
        -- then keep retrying in background
        task.spawn(function() rapidKill(name) end)
    else
        -- target name not in GUI yet — poll for it as fast as possible
        task.spawn(function()
            local waited = 0
            while waited < 3 do
                task.wait(0.03)
                waited += 0.03
                local n = getTargetName()
                if n then
                    -- fire the instant it appears
                    tryKill(n)
                    rapidKill(n)
                    return
                end
            end
            log("target name never appeared after knife")
        end)
    end
end

-- watch knife appearing in backpack
task.spawn(function()
    local bp = player:WaitForChild("Backpack")
    bp.ChildAdded:Connect(function(item)
        if item.Name == "Knife" then onKnifeDetected() end
    end)

    local function watchChar(char)
        if not char then return end
        char.ChildAdded:Connect(function(item)
            if item.Name == "Knife" then onKnifeDetected() end
        end)
    end

    watchChar(player.Character)
    player.CharacterAdded:Connect(watchChar)
end)

-- watch target name text changes during round
task.spawn(function()
    local label = player.PlayerGui
        :WaitForChild("MainGUI")
        :WaitForChild("Game")
        :WaitForChild("AssassinTarget")
        :WaitForChild("TargetName")

    log("watching TargetName")

    if label.Text ~= "" and label.Text ~= "Nikilis" then
        handleTarget(label.Text)
    end

    label:GetPropertyChangedSignal("Text"):Connect(function()
        local name = label.Text
        if name ~= "" and name ~= "Nikilis" then
            handleTarget(name)
        end
    end)
end)

-- knife gone = round over
task.spawn(function()
    while true do
        task.wait(0.4)
        if not autoKillEnabled then continue end
        if not hasKnife() and state ~= STATE.IDLE then
            log("knife gone — resetting")
            state = STATE.IDLE
            maxCoinsReached = false
            activeKill = nil
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
    if not ok or not remote then log("CoinCollected remote not found") return end

    remote.OnClientEvent:Connect(function(a, b, c)
        if not autoKillEnabled then return end
        if maxCoinsReached then return end

        local current, max
        if typeof(b) == "number" and typeof(c) == "number" then
            current, max = b, c
        elseif typeof(a) == "number" and typeof(b) == "number" then
            current, max = a, b
        else return end

        if max > 0 and current >= max then
            maxCoinsReached = true
            log(string.format("bag full (%d/%d)", current, max))

            if state == STATE.WAITING then
                local name = getTargetName()
                if name then
                    state = STATE.FINAL
                    -- fire instantly inline first
                    tryKill(name)
                    task.spawn(function()
                        rapidKill(name)
                        state = STATE.IDLE
                        maxCoinsReached = false
                    end)
                end
            end
        end
    end)
end)

section:AddToggle("Auto-Kill All", function(v)
    autoKillEnabled = v
    state = STATE.IDLE
    maxCoinsReached = false
    activeKill = nil
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
