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
local killing = false -- prevents overlapping kill loops

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

local function killByName(name)
    if not name or name == "" or name == "Nikilis" then return false end
    if isWhitelisted(name) then return false end
    local p = Players:FindFirstChild(name)
    if not p or not p.Character then return false end
    local part = getKillPart(p.Character)
    local hum = p.Character:FindFirstChildOfClass("Humanoid")
    if part and hum and hum.Health > 0 then
        return fireKnife(part)
    end
    return false
end

local function getTargetLabel()
    local gui = player:FindFirstChild("PlayerGui")
    if not gui then return nil end
    local main = gui:FindFirstChild("MainGUI")
    if not main then return nil end
    local game_ = main:FindFirstChild("Game")
    if not game_ then return nil end
    local at = game_:FindFirstChild("AssassinTarget")
    if not at then return nil end
    return at:FindFirstChild("TargetName")
end

local function getTargetName()
    local label = getTargetLabel()
    if not label then return nil end
    local text = label.Text
    if text and text ~= "" and text ~= "Nikilis" then return text end
    return nil
end

-- spam fire at a specific target until they die or target changes
local function rapidKill(name)
    if not name then return end
    log("rapid kill: " .. name)
    local attempts = 0
    while autoKillEnabled and hasKnife() do
        -- target changed means they died, stop this loop
        local current = getTargetName()
        if current ~= name then
            log("target changed — " .. name .. " is dead")
            break
        end
        local p = Players:FindFirstChild(name)
        if not p or not p.Character then break end
        local hum = p.Character:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then break end
        local part = getKillPart(p.Character)
        if part then
            fireKnife(part)
            attempts += 1
        end
        task.wait(0.05) -- fire every 50ms — fast enough to beat other exploiters
    end
    log("rapidKill done after " .. attempts .. " attempts")
end

-- main kill logic, called on target change or knife detect
local function onTarget(name)
    if not autoKillEnabled then return end
    if not name or name == "" or name == "Nikilis" then return end
    if not hasKnife() then return end
    if killing then return end -- already in a kill loop

    local living = getLivingCount()
    log(string.format("onTarget: %s | living: %d | state: %s | coins: %s",
        name, living, state, tostring(maxCoinsReached)))

    if state == STATE.IDLE then
        state = STATE.KILLING
    end

    if state == STATE.KILLING then
        if living <= 1 then
            log("1 left — waiting for max coins")
            state = STATE.WAITING
            if maxCoinsReached then
                state = STATE.FINAL
                task.spawn(function()
                    killing = true
                    rapidKill(name)
                    killing = false
                    state = STATE.IDLE
                    maxCoinsReached = false
                end)
            end
            return
        end

        task.spawn(function()
            killing = true
            rapidKill(name)
            killing = false
        end)

    elseif state == STATE.WAITING then
        if maxCoinsReached then
            log("coins full — final kill: " .. name)
            state = STATE.FINAL
            task.spawn(function()
                killing = true
                rapidKill(name)
                killing = false
                state = STATE.IDLE
                maxCoinsReached = false
            end)
        end

    elseif state == STATE.FINAL then
        task.spawn(function()
            killing = true
            rapidKill(name)
            killing = false
            state = STATE.IDLE
            maxCoinsReached = false
        end)
    end
end

-- watch target label for changes
task.spawn(function()
    local label = player.PlayerGui
        :WaitForChild("MainGUI")
        :WaitForChild("Game")
        :WaitForChild("AssassinTarget")
        :WaitForChild("TargetName")

    log("TargetName label found")

    if label.Text ~= "" then
        onTarget(label.Text)
    end

    label:GetPropertyChangedSignal("Text"):Connect(function()
        onTarget(label.Text)
    end)
end)

-- knife detection — fires the moment knife lands in backpack or character
local function onKnifeAdded(item)
    if item.Name ~= "Knife" then return end
    if not autoKillEnabled then return end
    log("knife detected instantly")
    state = STATE.KILLING
    maxCoinsReached = false
    -- immediately attempt current target
    local name = getTargetName()
    if name then
        onTarget(name)
    end
end

task.spawn(function()
    -- watch backpack
    local bp = player:WaitForChild("Backpack")
    bp.ChildAdded:Connect(onKnifeAdded)

    -- watch character (knife moves to char when equipped)
    local function watchChar(char)
        if not char then return end
        char.ChildAdded:Connect(onKnifeAdded)
    end

    watchChar(player.Character)
    player.CharacterAdded:Connect(watchChar)
end)

-- knife watcher — resets between rounds
task.spawn(function()
    while true do
        task.wait(0.5)
        if not autoKillEnabled then continue end
        if not hasKnife() then
            if state ~= STATE.IDLE then
                log("knife gone — round over")
                state = STATE.IDLE
                maxCoinsReached = false
                killing = false
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

            if state == STATE.WAITING then
                local name = getTargetName()
                if name then
                    log("firing final kill: " .. name)
                    state = STATE.FINAL
                    task.spawn(function()
                        killing = true
                        rapidKill(name)
                        killing = false
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
    killing = false
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
