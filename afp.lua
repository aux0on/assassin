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
local coinsThisRound = 0
local COIN_THRESHOLD = 50
local activeKillName = nil
local targetLabel = nil
local roundId = 0
local roundStarted = false

-- kill cap from RoundStart remote
local killCap = 0
local killCount = 0
local prevTarget = nil  -- tracks previous target to confirm kills via name change

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

local function getTargetName()
    if not targetLabel then return nil end
    local text = targetLabel.Text
    if text and text ~= "" and text ~= "Nikilis" then return text end
    return nil
end

local function coinThresholdMet()
    return coinsThisRound >= COIN_THRESHOLD
end

local function capMet()
    return killCap > 0 and killCount >= killCap
end

local function rawFire(name)
    if not name then return end
    local knife = getKnife()
    if not knife then return end
    local events = knife:FindFirstChild("Events")
    if not events then return end
    local ht = events:FindFirstChild("HandleTouched")
    if not ht then return end
    local p = Players:FindFirstChild(name)
    if not p or not p.Character then return end
    local part = getKillPart(p.Character)
    if not part then return end
    ht:FireServer(part)
end

local function rapidKill(name, myRoundId)
    if activeKillName == name then return end
    activeKillName = name
    log("rapidKill: " .. name)
    task.spawn(function()
        while autoKillEnabled and hasKnife() do
            if myRoundId ~= roundId then break end
            if state == STATE.IDLE then break end

            if state == STATE.WAITING then
                if not coinThresholdMet() then
                    task.wait(0.1)
                    continue
                end
                state = STATE.FINAL
                log("coins met in loop — FINAL")
            end

            -- hard block: cap met and coins not met
            if capMet() and not coinThresholdMet() then
                state = STATE.WAITING
                task.wait(0.1)
                continue
            end

            local cur = getTargetName()
            if cur ~= name then break end
            local p = Players:FindFirstChild(name)
            if not p or not p.Character then break end
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 then break end
            rawFire(name)
            task.wait(0.05)
        end
        if activeKillName == name then activeKillName = nil end
    end)
end

local function attemptKill(name, source)
    task.spawn(function()
        if not autoKillEnabled then return end
        if not name or name == "" then return end
        if isWhitelisted(name) then return end
        if not hasKnife() then return end

        -- absolute guard: cap met and coins not met = protect last player
        if capMet() and not coinThresholdMet() then
            if state == STATE.KILLING then
                state = STATE.WAITING
                log("cap met, coins not met — protecting last player")
            end
            return
        end

        if state == STATE.WAITING and not coinThresholdMet() then
            log("waiting for coins (" .. coinsThisRound .. "/" .. COIN_THRESHOLD .. ")")
            return
        end

        if state == STATE.IDLE then state = STATE.KILLING end

        log(string.format("[%s] target=%s kills=%d/%d coins=%d",
            source, name, killCount, killCap, coinsThisRound))

        if state == STATE.KILLING then
            if capMet() then
                state = STATE.WAITING
                log("cap met — WAITING for coins")
                if coinThresholdMet() then
                    state = STATE.FINAL
                    rawFire(name)
                    rapidKill(name, roundId)
                end
                return
            end
            rawFire(name)
            rapidKill(name, roundId)

        elseif state == STATE.FINAL then
            rawFire(name)
            rapidKill(name, roundId)
        end
    end)
end

local function resetRound()
    roundStarted = false
    state = STATE.IDLE
    coinsThisRound = 0
    activeKillName = nil
    killCount = 0
    killCap = 0
    prevTarget = nil
    log("round reset")
end

local function startRound()
    if roundStarted then return end
    roundStarted = true
    roundId += 1
    coinsThisRound = 0
    activeKillName = nil
    killCount = 0
    prevTarget = nil
    state = STATE.KILLING
    log(string.format("knife detected — roundId=%d killCap=%d", roundId, killCap))
end

local function onKnifeDetected()
    task.spawn(function()
        if not autoKillEnabled then return end
        startRound()
        attemptKill(getTargetName(), "knife")
    end)
end

-- called when TargetName text changes
local function onTargetChanged(name)
    task.spawn(function()
        if not autoKillEnabled then return end
        if not hasKnife() then return end

        -- each target change after the first = 1 confirmed kill
        if prevTarget ~= nil and prevTarget ~= "" and state == STATE.KILLING then
            killCount += 1
            log(string.format("kill confirmed (target changed) — %d/%d", killCount, killCap))
        end
        prevTarget = name

        attemptKill(name, "targetChanged")
    end)
end

-- RoundStart remote: count alive players to set killCap
task.spawn(function()
    local ok, roundStart = pcall(function()
        return ReplicatedStorage
            :WaitForChild("Remotes", 10)
            :WaitForChild("Gameplay", 10)
            :WaitForChild("RoundStart", 10)
    end)
    if not ok or not roundStart then
        log("RoundStart remote not found")
        return
    end

    roundStart.OnClientEvent:Connect(function(_duration, playerData)
        task.spawn(function()
            if not autoKillEnabled then return end
            if type(playerData) ~= "table" then return end

            -- count alive players including self, then subtract 2
            -- (1 for self, 1 for the last player to leave alive)
            local aliveCount = 0
            for _, data in pairs(playerData) do
                if type(data) == "table" and data.Dead == false then
                    aliveCount += 1
                end
            end

            killCap = math.max(aliveCount - 2, 0)
            killCount = 0
            prevTarget = nil
            log(string.format("RoundStart: %d alive — killCap=%d", aliveCount, killCap))
        end)
    end)
end)

-- watch TargetName label
task.spawn(function()
    targetLabel = player.PlayerGui
        :WaitForChild("MainGUI")
        :WaitForChild("Game")
        :WaitForChild("AssassinTarget")
        :WaitForChild("TargetName")

    log("label cached")

    local cur = getTargetName()
    if cur then
        prevTarget = cur
        attemptKill(cur, "initial")
    end

    targetLabel:GetPropertyChangedSignal("Text"):Connect(function()
        local name = targetLabel.Text
        if name and name ~= "" and name ~= "Nikilis" then
            onTargetChanged(name)
        end
    end)
end)

-- knife watchers
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

    local ok, giveWeapon = pcall(function()
        return ReplicatedStorage
            :WaitForChild("Remotes", 10)
            :WaitForChild("Gameplay", 10)
            :WaitForChild("GiveWeapon", 10)
    end)
    if ok and giveWeapon then
        giveWeapon.OnClientEvent:Connect(function(weaponName)
            if weaponName ~= "Knife" then return end
            task.spawn(function()
                local waited = 0
                while waited < 2 do
                    if hasKnife() then onKnifeDetected() return end
                    task.wait(0.02)
                    waited += 0.02
                end
            end)
        end)
    end
end)

-- round reset watcher
task.spawn(function()
    while true do
        task.wait(0.4)
        if not autoKillEnabled then continue end
        if not hasKnife() and state ~= STATE.IDLE then
            resetRound()
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
        task.spawn(function()
            if not autoKillEnabled then return end

            local current
            if typeof(b) == "number" then
                current = b
            elseif typeof(a) == "number" then
                current = a
            else return end

            coinsThisRound = current
            log(string.format("coins: %d/%d", coinsThisRound, COIN_THRESHOLD))

            if coinThresholdMet() and state == STATE.WAITING then
                local name = getTargetName()
                if name then
                    log("50 coins — killing last: " .. name)
                    state = STATE.FINAL
                    rawFire(name)
                    rapidKill(name, roundId)
                end
            end
        end)
    end)
end)

section:AddToggle("Auto-Kill All", function(v)
    task.spawn(function()
        autoKillEnabled = v
        resetRound()
        shared.Notify(v and "Assassin enabled" or "Assassin disabled", 2)
    end)
end)

section:AddPlayerDropdown("Whitelist Player", function(p)
    task.spawn(function()
        if not table.find(whitelist, p.UserId) then
            table.insert(whitelist, p.UserId)
            shared.Notify(p.Name .. " whitelisted.", 2)
        end
    end)
end)

section:AddButton("Clear Whitelist", function()
    task.spawn(function()
        whitelist = {}
        shared.Notify("Whitelist cleared.", 2)
    end)
end)

shared.Notify("Assassin Kill loaded", 1)
