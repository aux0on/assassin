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

local autoKillEnabled    = false
local lastPlayerEnabled  = false
local killAtMaxEnabled   = false
local autoKillReset      = false
local whitelist         = {}
local coinsThisRound    = 0
local COIN_THRESHOLD    = 50
local activeKillName    = nil
local targetLabel       = nil
local roundId           = 0
local roundStarted      = false
local killThreadActive  = false

local DEBUG = false
local function log(...) if DEBUG then print("[Assassin]", ...) end end

local STATE = { IDLE = "IDLE", KILLING = "KILLING", WAITING = "WAITING", FINAL = "FINAL" }
local state = STATE.IDLE

-- // two separate connection buckets:
-- // "persistent" — label + remotes, survive toggle off/on, only cleared on full script death
-- // "round"      — per-round kill threads (none currently use this, but kept for future use)
local persistentConns = {}
local charConn = nil   -- tracked separately so watchChar can swap it each respawn

local function trackPersistent(c)
    table.insert(persistentConns, c)
    return c
end

-- // resetRound only resets kill-state, never touches persistent connections
-- // killSelf: if true, also kills the local character so the game respawns us
local function resetRound(killSelf)
    roundStarted    = false
    state           = STATE.IDLE
    coinsThisRound  = 0
    activeKillName  = nil
    killThreadActive = false
    log("round reset")
    if killSelf then
        local char = player.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 then
            hum.Health = 0
        end
    end
end

-- ============================================================
-- helpers
-- ============================================================

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

-- returns two counts: total living nearby, killable living nearby (excludes whitelisted)
local function getLivingCount()
    local myChar = player.Character
    if not myChar then return 0, 0 end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return 0, 0 end
    local total, killable = 0, 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character then
            local pRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if pRoot then
                local dist = (pRoot.Position - myRoot.Position).Magnitude
                if dist <= 500 then
                    local hum = p.Character:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        total += 1
                        if not isWhitelisted(p) then
                            killable += 1
                        end
                    end
                end
            end
        end
    end
    return total, killable
end

local function getTargetName()
    if not targetLabel then return nil end
    local text = targetLabel.Text
    if text and text ~= "" and text ~= "Nikilis" then return text end
    return nil
end

local function coinThresholdMet()
    if not lastPlayerEnabled and not killAtMaxEnabled and not autoKillReset then return true end
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

-- ============================================================
-- kill logic
-- ============================================================

local function rapidKill(name, myRoundId)
    if activeKillName == name then return end
    if killThreadActive then return end
    killThreadActive = true
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
                log("coins met — FINAL")
            end

            local _, killable = getLivingCount()
            if killable <= 1 then
                if autoKillReset then
                    resetRound(true)
                    break
                end
                if not coinThresholdMet() then
                    state = STATE.WAITING
                    task.wait(0.1)
                    continue
                end
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

        killThreadActive = false
        if activeKillName == name then activeKillName = nil end
        log("rapidKill ended: " .. name)
    end)
end

local function attemptKill(name, source)
    task.spawn(function()
        if not autoKillEnabled then return end
        if not name or name == "" then return end
        if not hasKnife() then return end
        -- if this specific target is whitelisted, skip silently and wait for target to change
        if isWhitelisted(name) then return end

        local total, killable = getLivingCount()

        -- autoKillReset: hold until 50 coins, kill everyone except last killable, then reset
        if autoKillReset then
            if not coinThresholdMet() then
                if state == STATE.KILLING or state == STATE.IDLE then
                    state = STATE.WAITING
                end
                return
            end
            if killable <= 1 then
                resetRound(true)
                log("autoKillReset — last killable player reached, resetting")
                return
            end
            rawFire(name)
            rapidKill(name, roundId)
            return
        end

        -- killAtMaxEnabled: hold ALL kills until 50 coins
        if killAtMaxEnabled and not coinThresholdMet() then
            if state == STATE.KILLING or state == STATE.IDLE then
                state = STATE.WAITING
            end
            return
        end

        -- lastPlayerEnabled: only hold on the last killable player
        if killable <= 1 and not coinThresholdMet() then
            if state == STATE.KILLING then
                state = STATE.WAITING
                log("last killable player, coins not met — WAITING (" .. coinsThisRound .. "/" .. COIN_THRESHOLD .. ")")
            end
            return
        end

        if state == STATE.WAITING and not coinThresholdMet() then
            log("still waiting for coins (" .. coinsThisRound .. "/" .. COIN_THRESHOLD .. ")")
            return
        end

        if state == STATE.IDLE then state = STATE.KILLING end

        log(string.format("[%s] target=%s killable=%d coins=%d", source, name, killable, coinsThisRound))

        if state == STATE.KILLING then
            if killable <= 1 and lastPlayerEnabled then
                state = STATE.WAITING
                log("1 killable nearby — waiting for coins")
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

local function startRound()
    if roundStarted then return end
    roundStarted    = true
    roundId        += 1
    coinsThisRound  = 0
    activeKillName  = nil
    killThreadActive = false
    state           = STATE.KILLING
    local _, killable = getLivingCount()
    log(string.format("round start — killable=%d (roundId=%d)", killable, roundId))
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

-- ============================================================
-- persistent watchers — set up ONCE, never torn down on toggle
-- ============================================================

-- target label
task.spawn(function()
    local ok, lbl = pcall(function()
        return player.PlayerGui
            :WaitForChild("MainGUI")
            :WaitForChild("Game")
            :WaitForChild("AssassinTarget")
            :WaitForChild("TargetName")
    end)
    if not ok or not lbl then
        log("target label not found")
        return
    end
    targetLabel = lbl
    log("label cached")

    local cur = getTargetName()
    if cur then onTargetChanged(cur) end

    trackPersistent(targetLabel:GetPropertyChangedSignal("Text"):Connect(function()
        onTargetChanged(targetLabel.Text)
    end))
end)

-- knife / character watcher
task.spawn(function()
    local function watchChar(char)
        if not char then return end
        if charConn and charConn.Connected then
            charConn:Disconnect()
        end
        charConn = char.ChildAdded:Connect(function(item)
            if item.Name == "Knife" then onKnifeDetected() end
        end)
    end

    local bp = player:WaitForChild("Backpack")
    trackPersistent(bp.ChildAdded:Connect(function(item)
        if item.Name == "Knife" then onKnifeDetected() end
    end))

    watchChar(player.Character)
    trackPersistent(player.CharacterAdded:Connect(function(char)
        resetRound()   -- new life = new round
        watchChar(char)
    end))

    local ok, giveWeapon = pcall(function()
        return ReplicatedStorage
            :WaitForChild("Remotes", 10)
            :WaitForChild("Gameplay", 10)
            :WaitForChild("GiveWeapon", 10)
    end)
    if ok and giveWeapon then
        trackPersistent(giveWeapon.OnClientEvent:Connect(function(weaponName)
            if weaponName ~= "Knife" then return end
            task.spawn(function()
                local waited = 0
                while waited < 2 do
                    if hasKnife() then onKnifeDetected() return end
                    task.wait(0.02)
                    waited += 0.02
                end
            end)
        end))
    end
end)

-- state watchdog
task.spawn(function()
    while true do
        task.wait(0.4)
        if autoKillEnabled and not hasKnife() and state ~= STATE.IDLE then
            resetRound()
        end
    end
end)

-- coin collector
task.spawn(function()
    local ok, remote = pcall(function()
        return ReplicatedStorage
            :WaitForChild("Remotes", 10)
            :WaitForChild("Gameplay", 10)
            :WaitForChild("CoinCollected", 10)
    end)
    if not ok or not remote then log("CoinCollected remote not found") return end

    trackPersistent(remote.OnClientEvent:Connect(function(a, b)
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
                    log("threshold crossed — resuming kill: " .. name)
                    -- autoKillReset kills freely, not just the final target
                    state = autoKillReset and STATE.KILLING or STATE.FINAL
                    rawFire(name)
                    rapidKill(name, roundId)
                end
            end
        end)
    end))
end)

-- ============================================================
-- UI
-- ============================================================

section:AddToggle("Auto-Kill All", function(v)
    task.spawn(function()
        autoKillEnabled = v
        resetRound()
        shared.Notify(v and "Assassin enabled" or "Assassin disabled", 2)
    end)
end)

section:AddToggle("Auto Kill Last Player", function(v)
    task.spawn(function()
        lastPlayerEnabled = v
        if not v and state == STATE.WAITING then
            state = STATE.FINAL
            local name = getTargetName()
            if name and autoKillEnabled and hasKnife() then
                rawFire(name)
                rapidKill(name, roundId)
            end
        end
        shared.Notify(v and "Auto Kill Last Player ON" or "Auto Kill Last Player OFF", 2)
    end)
end)

section:AddToggle("Auto Kill Reset", function(v)
    task.spawn(function()
        autoKillReset = v
        if not v and state == STATE.WAITING then
            state = STATE.IDLE
        end
        shared.Notify(v and "Auto Kill Reset ON" or "Auto Kill Reset OFF", 2)
    end)
end)

section:AddToggle("Auto Kill All At Max", function(v)
    task.spawn(function()
        killAtMaxEnabled = v
        if not v and state == STATE.WAITING then
            state = STATE.FINAL
            local name = getTargetName()
            if name and autoKillEnabled and hasKnife() then
                rawFire(name)
                rapidKill(name, roundId)
            end
        end
        shared.Notify(v and "Auto Kill All At Max ON" or "Auto Kill All At Max OFF", 2)
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
