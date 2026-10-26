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
    if not targetLabel then return nil end
    local text = targetLabel.Text
    if text and text ~= "" and text ~= "Nikilis" then return text end
    return nil
end

local function coinThresholdMet()
    return coinsThisRound >= COIN_THRESHOLD
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

            -- hard block: never fire at last player unless coins met
            if state == STATE.WAITING then
                if not coinThresholdMet() then
                    task.wait(0.1)
                    continue
                end
                -- coins met while we were waiting — transition to final
                state = STATE.FINAL
                log("coins met in rapidKill loop — transitioning to FINAL")
            end

            -- stop if only 1 left and coins not met
            if getLivingCount() <= 1 and not coinThresholdMet() then
                state = STATE.WAITING
                log("1 left, coins not met — holding")
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

        -- absolute guard: never kill last player without 50 coins
        if getLivingCount() <= 1 and not coinThresholdMet() then
            if state == STATE.KILLING then
                state = STATE.WAITING
                log("1 left, coins not met — holding in attemptKill")
            end
            return
        end

        -- already waiting and coins still not met
        if state == STATE.WAITING and not coinThresholdMet() then
            log("still waiting for coins (" .. coinsThisRound .. "/" .. COIN_THRESHOLD .. ")")
            return
        end

        if state == STATE.IDLE then state = STATE.KILLING end

        log(string.format("[%s] target=%s living=%d coins=%d",
            source, name, getLivingCount(), coinsThisRound))

        if state == STATE.KILLING then
            -- re-check living after state set
            if getLivingCount() <= 1 then
                state = STATE.WAITING
                log("1 left — waiting for " .. COIN_THRESHOLD .. " coins")
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
    log("round reset")
end

local function startRound()
    if roundStarted then return end
    roundStarted = true
    roundId += 1
    coinsThisRound = 0
    activeKillName = nil
    state = STATE.KILLING
    log(string.format("round start — living=%d (roundId=%d)", getLivingCount(), roundId))
end

local function onKnifeDetected()
    task.spawn(function()
        if not autoKillEnabled then return end
        startRound()
        attemptKill(getTargetName(), "knife")
    end)
end

local function onTargetChanged(name)
    task.spawn(function()
        if not autoKillEnabled then return end
        if not hasKnife() then return end
        attemptKill(name, "targetChanged")
    end)
end

task.spawn(function()
    targetLabel = player.PlayerGui
        :WaitForChild("MainGUI")
        :WaitForChild("Game")
        :WaitForChild("AssassinTarget")
        :WaitForChild("TargetName")

    log("label cached")

    local cur = getTargetName()
    if cur then onTargetChanged(cur) end

    targetLabel:GetPropertyChangedSignal("Text"):Connect(function()
        onTargetChanged(targetLabel.Text)
    end)
end)

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

-- knife gone = round over
task.spawn(function()
    while true do
        task.wait(0.4)
        if not autoKillEnabled then continue end
        if not hasKnife() and state ~= STATE.IDLE then
            resetRound()
        end
    end
end)

-- coin tracking — just accumulate, no max needed
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

            -- crossed threshold while in WAITING — fire final kill immediately
            if coinThresholdMet() and state == STATE.WAITING then
                local name = getTargetName()
                if name then
                    log("threshold crossed — killing last target: " .. name)
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
