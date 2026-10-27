--[[
    RoChess Engine Bot & Analysis Helper v5.0 (Ultra-Stable & Fast Auto-Play)
    - Crash-proof: uses non-blocking lookups and safe pcall wrappers
    - Bulletproof Auto-Play: continuous frame-based scheduler (never stalls or skips)
    - Direct Input Execution: binds exclusively to Board.Input.InputBegan
    - Instant Bullet Prediction (~15-25ms) + Deep Stockfish 16 Mode
    - Dual Visual Markers: Instant Square Glows + Vector Arrow
--]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5)

-- Clean up any prior running bot instance
if _G.RoChessBotCleanup then
    pcall(_G.RoChessBotCleanup)
end

local Chess = RS:FindFirstChild("Chess") or RS:WaitForChild("Chess", 5)
local Engine = require(Chess:WaitForChild("Engine", 5))
local Bot = require(Chess:WaitForChild("Bot", 5))
local VortexBot = require(Chess:WaitForChild("VortexBot", 5))

-- Configuration
local Config = {
    Mode = "Vortex",        -- "Vortex", "Bullet", "Rapid"
    AutoPlay = true,
    MarkerStyle = "Both",   -- "Both", "Squares", "Arrow"
    ShowEval = true,
    EloRating = 2800,
    MinDelay = 0.08,        -- Fast execution once calculation is complete
    MaxDelay = 0.18
}

-- State
local State = {
    InGame = false,
    MyColor = 1,            -- 1 = White, -1 = Black
    IsMyTurn = false,
    CurrentPly = -1,
    LastEvaluatedPly = -999,
    LastPlayedPly = -999,
    ScheduledPly = -999,
    ScheduledMoveTime = 0,
    BestMove = nil,
    EvalScore = 0,
    MovesHistory = {},
    CalcTimeMs = 0,
    IsMoving = false,
    IsThinking = false
}

-- Helpers: Coordinate conversion (algebraic "e2" to square 1..64)
local function algToSq(alg)
    if not alg or #alg < 2 then return nil end
    local fileChar = string.sub(alg, 1, 1)
    local rankChar = string.sub(alg, 2, 2)
    local fileIdx = string.byte(fileChar) - string.byte("a") -- 0..7
    local rankIdx = tonumber(rankChar) - 1                  -- 0..7
    if fileIdx < 0 or fileIdx > 7 or rankIdx < 0 or rankIdx > 7 then return nil end
    return 1 + fileIdx + rankIdx * 8
end

-- Safe UI getters
local function getBoardElements()
    local chessUI = PlayerGui and PlayerGui:FindFirstChild("ChessUI")
    local root = chessUI and chessUI:FindFirstChild("Root")
    local board = root and root:FindFirstChild("Board")
    local squares = board and board:FindFirstChild("Squares")
    local arrows = board and board:FindFirstChild("Arrows")
    local highlights = board and board:FindFirstChild("Highlights")
    local input = board and board:FindFirstChild("Input")
    return chessUI, root, board, squares, arrows, highlights, input
end

-- =====================================================================
-- Visual Markers (Persistent, Zero-Allocation)
-- =====================================================================
local _, rootUI, boardUI, squaresUI, arrowsUI, highlightsUI = getBoardElements()

-- 1. Square Highlights
local HlFolder = highlightsUI and highlightsUI:FindFirstChild("RoChessPredictionHL")
if not HlFolder and highlightsUI then
    HlFolder = Instance.new("Folder")
    HlFolder.Name = "RoChessPredictionHL"
    HlFolder.Parent = highlightsUI
elseif HlFolder then
    HlFolder:ClearAllChildren()
end

local FromSquareFrame = Instance.new("Frame")
FromSquareFrame.Name = "FromSq"
FromSquareFrame.Size = UDim2.fromScale(0.125, 0.125)
FromSquareFrame.BackgroundColor3 = Color3.fromRGB(0, 230, 118)
FromSquareFrame.BackgroundTransparency = 0.42
FromSquareFrame.BorderSizePixel = 0
FromSquareFrame.Visible = false
FromSquareFrame.ZIndex = 3
FromSquareFrame.Parent = HlFolder

local FromStroke = Instance.new("UIStroke")
FromStroke.Thickness = 2.5
FromStroke.Color = Color3.fromRGB(0, 255, 140)
FromStroke.Transparency = 0.1
FromStroke.Parent = FromSquareFrame

local FromCorner = Instance.new("UICorner")
FromCorner.CornerRadius = UDim.new(0, 4)
FromCorner.Parent = FromSquareFrame

local ToSquareFrame = Instance.new("Frame")
ToSquareFrame.Name = "ToSq"
ToSquareFrame.Size = UDim2.fromScale(0.125, 0.125)
ToSquareFrame.BackgroundColor3 = Color3.fromRGB(0, 195, 255)
ToSquareFrame.BackgroundTransparency = 0.42
ToSquareFrame.BorderSizePixel = 0
ToSquareFrame.Visible = false
ToSquareFrame.ZIndex = 3
ToSquareFrame.Parent = HlFolder

local ToStroke = Instance.new("UIStroke")
ToStroke.Thickness = 2.5
ToStroke.Color = Color3.fromRGB(0, 220, 255)
ToStroke.Transparency = 0.1
ToStroke.Parent = ToSquareFrame

local ToCorner = Instance.new("UICorner")
ToCorner.CornerRadius = UDim.new(0, 4)
ToCorner.Parent = ToSquareFrame

local ToDot = Instance.new("Frame")
ToDot.Name = "Dot"
ToDot.AnchorPoint = Vector2.new(0.5, 0.5)
ToDot.Position = UDim2.fromScale(0.5, 0.5)
ToDot.Size = UDim2.fromOffset(18, 18)
ToDot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
ToDot.BackgroundTransparency = 0.15
ToDot.BorderSizePixel = 0
ToDot.ZIndex = 4
ToDot.Parent = ToSquareFrame

local DotCorner = Instance.new("UICorner")
DotCorner.CornerRadius = UDim.new(1, 0)
DotCorner.Parent = ToDot

-- 2. Vector Arrow
local ArrowFolder = arrowsUI and arrowsUI:FindFirstChild("RoChessArrowFolder")
if not ArrowFolder and arrowsUI then
    ArrowFolder = Instance.new("Folder")
    ArrowFolder.Name = "RoChessArrowFolder"
    ArrowFolder.Parent = arrowsUI
elseif ArrowFolder then
    ArrowFolder:ClearAllChildren()
end

local ArrowShaft = Instance.new("Frame")
ArrowShaft.Name = "ArrowShaft"
ArrowShaft.AnchorPoint = Vector2.new(0.5, 0.5)
ArrowShaft.BackgroundColor3 = Color3.fromRGB(0, 230, 118)
ArrowShaft.BackgroundTransparency = 0.25
ArrowShaft.BorderSizePixel = 0
ArrowShaft.Visible = false
ArrowShaft.ZIndex = 8
ArrowShaft.Parent = ArrowFolder

local ArrowHead = Instance.new("ImageLabel")
ArrowHead.Name = "ArrowHead"
ArrowHead.AnchorPoint = Vector2.new(0.5, 0.5)
ArrowHead.ScaleType = Enum.ScaleType.Stretch
ArrowHead.Image = "rbxassetid://110181402669597"
ArrowHead.ImageRectOffset = Vector2.new(576, 896)
ArrowHead.ImageRectSize = Vector2.new(64, 64)
ArrowHead.ImageColor3 = Color3.fromRGB(0, 230, 118)
ArrowHead.ImageTransparency = 0.25
ArrowHead.BackgroundTransparency = 1
ArrowHead.BorderSizePixel = 0
ArrowHead.Visible = false
ArrowHead.ZIndex = 8
ArrowHead.Parent = ArrowFolder

local function clearMarkers()
    FromSquareFrame.Visible = false
    ToSquareFrame.Visible = false
    ArrowShaft.Visible = false
    ArrowHead.Visible = false
end

local function updateMarkers(fromSqNum, toSqNum, score)
    local _, _, board, squares = getBoardElements()
    if not board or not squares or not fromSqNum or not toSqNum or fromSqNum == toSqNum then
        clearMarkers()
        return
    end

    local fromSq = squares:FindFirstChild("S" .. fromSqNum)
    local toSq = squares:FindFirstChild("S" .. toSqNum)
    if not fromSq or not toSq then
        clearMarkers()
        return
    end

    local showSquares = (Config.MarkerStyle == "Both" or Config.MarkerStyle == "Squares")
    local showArrow = (Config.MarkerStyle == "Both" or Config.MarkerStyle == "Arrow")

    if showSquares then
        FromSquareFrame.Position = fromSq.Position
        ToSquareFrame.Position = toSq.Position
        FromSquareFrame.Visible = true
        ToSquareFrame.Visible = true
    else
        FromSquareFrame.Visible = false
        ToSquareFrame.Visible = false
    end

    if showArrow then
        local sqPx = board.AbsoluteSize.X / 8
        local bPos = board.AbsolutePosition
        local v273 = fromSq.AbsolutePosition - bPos + fromSq.AbsoluteSize / 2
        local v274 = toSq.AbsolutePosition - bPos + toSq.AbsoluteSize / 2
        local v275 = v274 - v273
        local Magnitude = v275.Magnitude

        if Magnitude >= 1 then
            local v276 = v275 / Magnitude
            local v278 = math.deg(math.atan2(v275.Y, v275.X))
            local v279 = sqPx * 0.20
            local v280 = sqPx * 0.45
            local v281 = sqPx * 0.48
            local v282 = v273 + v276 * (sqPx * 0.12)
            local v283 = v274 - v276 * (sqPx * 0.05)
            local v284 = v283 - v276 * v280
            local Magnitude2 = (v284 - v282).Magnitude
            local v285 = (v282 + v284) / 2

            local arrowColor = Color3.fromRGB(0, 230, 118)
            if score and score < -150 then
                arrowColor = Color3.fromRGB(255, 179, 0)
            end

            ArrowShaft.Position = UDim2.fromOffset(v285.X, v285.Y)
            ArrowShaft.Size = UDim2.fromOffset(Magnitude2, v279)
            ArrowShaft.Rotation = v278
            ArrowShaft.BackgroundColor3 = arrowColor
            ArrowShaft.Visible = true

            ArrowHead.Position = UDim2.fromOffset((v283 - v276 * (v280 / 2)).X, (v283 - v276 * (v280 / 2)).Y)
            ArrowHead.Size = UDim2.fromOffset(v280, v281)
            ArrowHead.Rotation = v278
            ArrowHead.ImageColor3 = arrowColor
            ArrowHead.Visible = true
        else
            ArrowShaft.Visible = false
            ArrowHead.Visible = false
        end
    else
        ArrowShaft.Visible = false
        ArrowHead.Visible = false
    end
end

-- Eval Bar Management
local function updateEvalBar(score)
    local _, root = getBoardElements()
    local EvalBar = root and root:FindFirstChild("EvalBar")
    local EvalFill = EvalBar and EvalBar:FindFirstChild("White")
    local EvalText = EvalBar and EvalBar:FindFirstChild("Score")

    if not EvalBar or not EvalFill or not EvalText then return end
    if not Config.ShowEval or not State.InGame then
        EvalBar.Visible = false
        return
    end

    EvalBar.Visible = true
    local cp = score or 0
    local normalized = 1 / (1 + 10 ^ (-cp / 400))
    EvalFill.Size = UDim2.fromScale(1, math.clamp(normalized, 0.05, 0.95))

    local evalStr
    if math.abs(cp) > 25000 then
        local mateMoves = math.ceil((30000 - math.abs(cp)) / 2)
        evalStr = (cp > 0 and "+M" or "-M") .. tostring(mateMoves)
    else
        evalStr = string.format("%+.1f", cp / 100)
    end
    EvalText.Text = evalStr
end

-- =====================================================================
-- Move Execution (Robust Native Click Dispatcher with Inset Fix)
-- =====================================================================
local function clickSquare(sqNum)
    local _, _, board, squares = getBoardElements()
    if not board or not squares or not sqNum then return false end

    local sq = squares:FindFirstChild("S" .. sqNum)
    if not sq then return false end

    local GuiService = game:GetService("GuiService")
    local inset = GuiService:GetGuiInset()

    local center = sq.AbsolutePosition + sq.AbsoluteSize / 2
    local x = math.floor(center.X)
    local y = math.floor(center.Y + inset.Y)

    VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
    task.wait(0.04)
    VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)

    return true
end

local function executeMove(uci)
    if not uci or #uci < 4 or State.IsMoving then return end
    State.IsMoving = true

    local fromAlg = string.sub(uci, 1, 2)
    local toAlg = string.sub(uci, 3, 4)
    local promoChar = #uci >= 5 and string.sub(uci, 5, 5) or nil

    local fromSq = algToSq(fromAlg)
    local toSq = algToSq(toAlg)

    if fromSq and toSq then
        clickSquare(fromSq)
        task.wait(Config.Mode == "Bullet" and 0.08 or 0.12)
        clickSquare(toSq)

        -- Handle promotion modal if it appears
        if promoChar then
            task.wait(0.12)
            local _, _, board = getBoardElements()
            local promoCol = board and board:FindFirstChild("PromoColumn")
            if promoCol and promoCol.Visible then
                for _, item in ipairs(promoCol:GetChildren()) do
                    if (item:IsA("GuiButton") or item:IsA("Frame")) and item.Visible then
                        local GuiService = game:GetService("GuiService")
                        local inset = GuiService:GetGuiInset()
                        local center = item.AbsolutePosition + item.AbsoluteSize / 2
                        local cx = math.floor(center.X)
                        local cy = math.floor(center.Y + inset.Y)
                        VIM:SendMouseButtonEvent(cx, cy, 0, true, game, 0)
                        task.wait(0.03)
                        VIM:SendMouseButtonEvent(cx, cy, 0, false, game, 0)
                        break
                    end
                end
            end
        end
    end

    State.IsMoving = false
end

-- =====================================================================
-- Adaptive Engine Think
-- =====================================================================
local function computeBestMove(uciMoves)
    local t0 = os.clock()

    -- 1. Grandmaster Opening Book (Instant ~0ms for first 16 plies)
    if #uciMoves < 16 then
        local okBook, bMove = pcall(function()
            return Bot.bookMove(uciMoves)
        end)
        if okBook and bMove and type(bMove) == "string" and #bMove >= 4 then
            local elapsedMs = math.floor((os.clock() - t0) * 1000)
            return bMove, { book = true, score = 0, depth = 99 }, elapsedMs
        end
    end

    -- 2. Bullet Mode (~15-25ms Instant Local)
    if Config.Mode == "Bullet" then
        local persona = {
            rating = 2800,
            depth = 4,
            time = 0.02,
            noise = 0,
            blunder = 0
        }
        local bestMove, stats = Bot.think(nil, uciMoves, persona, {})
        local elapsedMs = math.floor((os.clock() - t0) * 1000)
        return bestMove, stats, elapsedMs
    end

    -- 3. Rapid Mode (~50-80ms Strong Local)
    if Config.Mode == "Rapid" then
        local persona = {
            rating = 2800,
            depth = 6,
            time = 0.06,
            noise = 0,
            blunder = 0
        }
        local bestMove, stats = Bot.think(nil, uciMoves, persona, {})
        local elapsedMs = math.floor((os.clock() - t0) * 1000)
        return bestMove, stats, elapsedMs
    end

    -- 4. Vortex Mode (Server Stockfish 16 Engine)
    local persona = {
        rating = 2800,
        depth = 20,
        time = 0.8,
        noise = 0,
        blunder = 0
    }

    local bestMove, stats = nil, nil

    -- Call Vortex server directly
    local VortexThink = Chess:FindFirstChild("VortexThink")
    if VortexThink then
        local okVortex, res = pcall(function()
            return VortexThink:InvokeServer({
                startFen = nil,
                moves = uciMoves,
                persona = persona
            })
        end)
        if okVortex and type(res) == "table" and res.uci and #res.uci >= 4 then
            bestMove = res.uci
            stats = {
                score = res.score or 0,
                depth = res.depth or 20,
                nodes = res.nodes or 0,
                time = (res.time or 0) / 1000
            }
        end
    end

    -- Fallback to VortexBot wrapper if direct server call didn't return
    if not bestMove then
        local okWrap, wMove, wStats = pcall(function()
            return VortexBot.think(nil, uciMoves, persona, {})
        end)
        if okWrap and wMove and type(wMove) == "string" and #wMove >= 4 then
            bestMove = wMove
            stats = wStats
        end
    end

    -- Final Safety Fallback: Local Bot.think
    if not bestMove then
        local okBot, bMove, bStats = pcall(function()
            return Bot.think(nil, uciMoves, { rating = 2800, depth = 6, time = 0.08, noise = 0, blunder = 0 }, {})
        end)
        if okBot and bMove then
            bestMove = bMove
            stats = bStats
        end
    end

    local elapsedMs = math.floor((os.clock() - t0) * 1000)
    return bestMove, stats, elapsedMs
end

-- =====================================================================
-- State Synchronization
-- =====================================================================
local function syncState()
    local _, root, _, squares = getBoardElements()
    if not root or not squares then
        State.InGame = false
        return
    end

    local sideFrame = root:FindFirstChild("Side")
    local panelFrame = sideFrame and sideFrame:FindFirstChild("Panel")
    local bodyFrame = panelFrame and panelFrame:FindFirstChild("Body")
    local gameFrame = bodyFrame and bodyFrame:FindFirstChild("Game")

    -- 1. Check if game is in progress
    local isGameVisible = gameFrame and gameFrame.Visible
    local hasActiveBtn = false
    if isGameVisible and gameFrame:FindFirstChild("Actions") then
        for _, d in ipairs(gameFrame.Actions:GetDescendants()) do
            if d:IsA("TextLabel") and (d.Text == "Resign" or d.Text == "Abort") and d.Visible then
                hasActiveBtn = true
                break
            end
        end
    end

    State.InGame = (isGameVisible and hasActiveBtn) or false

    if not State.InGame then
        if State.LastEvaluatedPly ~= -999 then
            clearMarkers()
            updateEvalBar(0)
            State.BestMove = nil
            State.IsMyTurn = false
            State.LastEvaluatedPly = -999
            State.ScheduledPly = -999
            State.CurrentPly = 0
        end
        return
    end

    -- 2. Detect Color (S1 at bottom = White)
    local s1 = squares:FindFirstChild("S1")
    if s1 then
        State.MyColor = (s1.Position.Y.Scale > 0.5) and 1 or -1
    end

    -- 3. Parse MoveList
    local moveListFrame = gameFrame:FindFirstChild("Moves")
    moveListFrame = moveListFrame and moveListFrame:FindFirstChild("MoveList")

    local plies = {}
    if moveListFrame then
        for _, child in ipairs(moveListFrame:GetChildren()) do
            if string.sub(child.Name, 1, 3) == "Row" then
                for _, cell in ipairs(child:GetChildren()) do
                    if string.sub(cell.Name, 1, 3) == "Ply" then
                        local plyNum = tonumber(string.sub(cell.Name, 4))
                        if plyNum and cell.Text and cell.Text ~= "" then
                            plies[plyNum] = cell.Text
                        end
                    end
                end
            end
        end
    end

    local plyCount = #plies
    State.CurrentPly = plyCount

    -- 4. Check Turn
    local sideToMove = (plyCount % 2 == 0) and 1 or -1
    State.IsMyTurn = (sideToMove == State.MyColor)

    -- If ply has changed, re-evaluate best move
    if plyCount ~= State.LastEvaluatedPly and not State.IsThinking then
        State.IsThinking = true
        State.BestMove = nil       -- CRITICAL: Clear stale move immediately to avoid executing old plies
        State.ScheduledPly = -999  -- CRITICAL: Cancel any prior schedule
        clearMarkers()

        task.spawn(function()
            local simEngine = Engine.new()
            local uciMoves = {}

            for i = 1, plyCount do
                local sanText = plies[i]
                local matchedMove = nil
                for _, legalMove in ipairs(simEngine:legalMoves()) do
                    if simEngine:moveToSan(legalMove) == sanText then
                        matchedMove = legalMove
                        break
                    end
                end

                if matchedMove then
                    table.insert(uciMoves, simEngine:moveToUci(matchedMove))
                    simEngine:makeMove(matchedMove)
                else
                    break
                end
            end

            State.MovesHistory = uciMoves
            local bestMove, stats, elapsedMs = computeBestMove(uciMoves)

            -- Verify game didn't advance or reset while thinking
            if State.CurrentPly == plyCount and State.InGame then
                State.BestMove = bestMove
                State.EvalScore = stats and stats.score or 0
                State.CalcTimeMs = elapsedMs or 0
                State.LastEvaluatedPly = plyCount

                if bestMove and #bestMove >= 4 then
                    local fromSq = algToSq(string.sub(bestMove, 1, 2))
                    local toSq = algToSq(string.sub(bestMove, 3, 4))
                    updateMarkers(fromSq, toSq, State.EvalScore)
                else
                    clearMarkers()
                end

                updateEvalBar(State.EvalScore)
            end

            State.IsThinking = false
        end)
    elseif plyCount == State.LastEvaluatedPly and State.BestMove then
        local fromSq = algToSq(string.sub(State.BestMove, 1, 2))
        local toSq = algToSq(string.sub(State.BestMove, 3, 4))
        updateMarkers(fromSq, toSq, State.EvalScore)
        updateEvalBar(State.EvalScore)
    end
end

-- =====================================================================
-- Dedicated Auto-Play Scheduler (Never Stalls, Never Races Stale Moves)
-- =====================================================================
local function checkAutoPlay()
    if not Config.AutoPlay or not State.InGame or not State.IsMyTurn or State.IsMoving then
        return
    end

    -- CRITICAL: Never execute while engine is actively thinking
    if State.IsThinking then
        return
    end

    -- CRITICAL: Only execute if the evaluated move matches the current ply
    if State.LastEvaluatedPly ~= State.CurrentPly or not State.BestMove or #State.BestMove < 4 then
        return
    end

    local currentPly = State.CurrentPly

    -- If this ply is already scheduled, check if it's time to move (or retry)
    if State.ScheduledPly == currentPly then
        if os.clock() >= State.ScheduledMoveTime then
            -- Set a 0.40s retry deadline in case the move didn't register
            State.ScheduledMoveTime = os.clock() + 0.40
            executeMove(State.BestMove)
        end
        return
    end

    -- First schedule for new evaluated ply
    State.ScheduledPly = currentPly
    local delay = math.random() * (Config.MaxDelay - Config.MinDelay) + Config.MinDelay
    State.ScheduledMoveTime = os.clock() + delay
end

-- =====================================================================
-- Floating Control GUI
-- =====================================================================
local oldGui = game:GetService("CoreGui"):FindFirstChild("RoChessEngineBotGui") or (PlayerGui and PlayerGui:FindFirstChild("RoChessEngineBotGui"))
if oldGui then oldGui:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "RoChessEngineBotGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

pcall(function()
    ScreenGui.Parent = game:GetService("CoreGui")
end)
if not ScreenGui.Parent and PlayerGui then
    ScreenGui.Parent = PlayerGui
end

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.fromOffset(260, 335)
MainFrame.Position = UDim2.new(0, 30, 0.5, -167)
MainFrame.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0, 10)
Corner.Parent = MainFrame

local Stroke = Instance.new("UIStroke")
Stroke.Color = Color3.fromRGB(50, 54, 66)
Stroke.Thickness = 1.5
Stroke.Parent = MainFrame

-- Title Bar
local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 36)
TitleBar.BackgroundColor3 = Color3.fromRGB(32, 35, 45)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = MainFrame

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 10)
TitleCorner.Parent = TitleBar

local TitleText = Instance.new("TextLabel")
TitleText.Text = "🧠 RoChess Bot v5 (Vortex 2800)"
TitleText.TextColor3 = Color3.fromRGB(255, 255, 255)
TitleText.Font = Enum.Font.GothamBold
TitleText.TextSize = 13
TitleText.TextXAlignment = Enum.TextXAlignment.Left
TitleText.BackgroundTransparency = 1
TitleText.Size = UDim2.new(1, -40, 1, 0)
TitleText.Position = UDim2.fromOffset(12, 0)
TitleText.Parent = TitleBar

local CloseBtn = Instance.new("TextButton")
CloseBtn.Text = "✕"
CloseBtn.TextColor3 = Color3.fromRGB(180, 180, 190)
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 13
CloseBtn.BackgroundTransparency = 1
CloseBtn.Size = UDim2.fromOffset(30, 36)
CloseBtn.Position = UDim2.new(1, -32, 0, 0)
CloseBtn.Parent = TitleBar

-- Container
local Container = Instance.new("Frame")
Container.Name = "Container"
Container.Size = UDim2.new(1, -20, 1, -46)
Container.Position = UDim2.fromOffset(10, 42)
Container.BackgroundTransparency = 1
Container.Parent = MainFrame

local Layout = Instance.new("UIListLayout")
Layout.FillDirection = Enum.FillDirection.Vertical
Layout.Padding = UDim.new(0, 5)
Layout.Parent = Container

local function createBtn(name, text, bg, callback)
    local btn = Instance.new("TextButton")
    btn.Name = name
    btn.Size = UDim2.new(1, 0, 0, 30)
    btn.BackgroundColor3 = bg or Color3.fromRGB(40, 44, 56)
    btn.Font = Enum.Font.GothamMedium
    btn.TextSize = 12
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Text = text
    btn.BorderSizePixel = 0
    btn.Parent = Container

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = btn

    btn.MouseButton1Click:Connect(callback)
    return btn
end

-- 1. Mode Button
local Modes = {
    { id = "Vortex", label = "Mode: 🧠 Vortex 2800 Elo (Stockfish 16)", min = 0.08, max = 0.18, bg = Color3.fromRGB(130, 50, 220) },
    { id = "Bullet", label = "Mode: ⚡ Bullet (Instant ~20ms)", min = 0.04, max = 0.10, bg = Color3.fromRGB(220, 90, 0) },
    { id = "Rapid", label = "Mode: ♟ Rapid (~60ms)", min = 0.15, max = 0.30, bg = Color3.fromRGB(40, 120, 200) }
}
local modeIdx = 1

local ModeBtn = createBtn("ModeBtn", Modes[modeIdx].label, Modes[modeIdx].bg, function()
    modeIdx = (modeIdx % #Modes) + 1
    local cur = Modes[modeIdx]
    Config.Mode = cur.id
    Config.MinDelay = cur.min
    Config.MaxDelay = cur.max
    ModeBtn.Text = cur.label
    ModeBtn.BackgroundColor3 = cur.bg
    State.LastEvaluatedPly = -999
end)

-- 2. Marker Style Button
local MarkerStyles = {
    { id = "Both", label = "Markers: Both (Arrow + Squares)" },
    { id = "Squares", label = "Markers: Squares Only (Fastest)" },
    { id = "Arrow", label = "Markers: Arrow Only" }
}
local markerIdx = 1

local MarkerBtn = createBtn("MarkerBtn", MarkerStyles[markerIdx].label, Color3.fromRGB(40, 44, 56), function()
    markerIdx = (markerIdx % #MarkerStyles) + 1
    local cur = MarkerStyles[markerIdx]
    Config.MarkerStyle = cur.id
    MarkerBtn.Text = cur.label
    if State.BestMove and #State.BestMove >= 4 then
        local fromSq = algToSq(string.sub(State.BestMove, 1, 2))
        local toSq = algToSq(string.sub(State.BestMove, 3, 4))
        updateMarkers(fromSq, toSq, State.EvalScore)
    end
end)

-- 3. Auto-Play Toggle
local AutoPlayBtn
AutoPlayBtn = createBtn("AutoPlayBtn", Config.AutoPlay and "Auto-Play: ON" or "Auto-Play: OFF", Config.AutoPlay and Color3.fromRGB(0, 180, 90) or Color3.fromRGB(40, 44, 56), function()
    Config.AutoPlay = not Config.AutoPlay
    AutoPlayBtn.BackgroundColor3 = Config.AutoPlay and Color3.fromRGB(0, 180, 90) or Color3.fromRGB(40, 44, 56)
    AutoPlayBtn.Text = "Auto-Play: " .. (Config.AutoPlay and "ON" or "OFF")
    State.ScheduledPly = -999 -- Immediately triggers scheduler
end)

-- 4. Force Move Button
local ForceBtn = createBtn("ForceBtn", "⚡ Force Move Now", Color3.fromRGB(60, 110, 240), function()
    if State.BestMove and State.IsMyTurn and not State.IsThinking and State.LastEvaluatedPly == State.CurrentPly then
        executeMove(State.BestMove)
    end
end)
ForceBtn.Font = Enum.Font.GothamBold

-- 5. Status Box
local StatusBox = Instance.new("Frame")
StatusBox.Name = "StatusBox"
StatusBox.Size = UDim2.new(1, 0, 0, 80)
StatusBox.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
StatusBox.BorderSizePixel = 0
StatusBox.Parent = Container

local StatusCorner = Instance.new("UICorner")
StatusCorner.CornerRadius = UDim.new(0, 6)
StatusCorner.Parent = StatusBox

local StatusPadding = Instance.new("UIPadding")
StatusPadding.PaddingTop = UDim.new(0, 6)
StatusPadding.PaddingBottom = UDim.new(0, 6)
StatusPadding.PaddingLeft = UDim.new(0, 8)
StatusPadding.PaddingRight = UDim.new(0, 8)
StatusPadding.Parent = StatusBox

local StatusLayout = Instance.new("UIListLayout")
StatusLayout.FillDirection = Enum.FillDirection.Vertical
StatusLayout.Padding = UDim.new(0, 2)
StatusLayout.Parent = StatusBox

local Line1 = Instance.new("TextLabel")
Line1.Size = UDim2.new(1, 0, 0, 16)
Line1.BackgroundTransparency = 1
Line1.Font = Enum.Font.GothamBold
Line1.TextSize = 12
Line1.TextColor3 = Color3.fromRGB(180, 185, 200)
Line1.TextXAlignment = Enum.TextXAlignment.Left
Line1.Text = "Status: Idle (Home Screen)"
Line1.Parent = StatusBox

local Line2 = Instance.new("TextLabel")
Line2.Size = UDim2.new(1, 0, 0, 16)
Line2.BackgroundTransparency = 1
Line2.Font = Enum.Font.GothamBold
Line2.TextSize = 13
Line2.TextColor3 = Color3.fromRGB(0, 230, 118)
Line2.TextXAlignment = Enum.TextXAlignment.Left
Line2.Text = "Best Move: --"
Line2.Parent = StatusBox

local Line3 = Instance.new("TextLabel")
Line3.Size = UDim2.new(1, 0, 0, 16)
Line3.BackgroundTransparency = 1
Line3.Font = Enum.Font.Gotham
Line3.TextSize = 12
Line3.TextColor3 = Color3.fromRGB(180, 185, 200)
Line3.TextXAlignment = Enum.TextXAlignment.Left
Line3.Text = "Eval: 0.0"
Line3.Parent = StatusBox

local Line4 = Instance.new("TextLabel")
Line4.Size = UDim2.new(1, 0, 0, 16)
Line4.BackgroundTransparency = 1
Line4.Font = Enum.Font.Gotham
Line4.TextSize = 11
Line4.TextColor3 = Color3.fromRGB(240, 160, 40)
Line4.TextXAlignment = Enum.TextXAlignment.Left
Line4.Text = "Latency: 0ms"
Line4.Parent = StatusBox

-- Close
local active = true
CloseBtn.MouseButton1Click:Connect(function()
    active = false
    ScreenGui:Destroy()
    clearMarkers()
    local _, root = getBoardElements()
    local eb = root and root:FindFirstChild("EvalBar")
    if eb then eb.Visible = false end
end)

_G.RoChessBotCleanup = function()
    active = false
    pcall(function() ScreenGui:Destroy() end)
    pcall(clearMarkers)
    local _, root = getBoardElements()
    local eb = root and root:FindFirstChild("EvalBar")
    if eb then eb.Visible = false end
end

-- =====================================================================
-- Main Loop (Fast, Non-Blocking, 0.05s Loop)
-- =====================================================================
task.spawn(function()
    while active do
        pcall(syncState)
        pcall(checkAutoPlay)

        if State.InGame then
            local colorStr = State.MyColor == 1 and "White" or "Black"
            local turnStr = State.IsMyTurn and "YOUR TURN" or "Opponent"
            Line1.Text = string.format("[%s] %s | Ply: %d", colorStr, turnStr, State.CurrentPly)
            Line1.TextColor3 = State.IsMyTurn and Color3.fromRGB(0, 230, 118) or Color3.fromRGB(240, 180, 40)
            Line2.Text = "Best Move: " .. (State.BestMove or "--")

            local cp = State.EvalScore or 0
            if math.abs(cp) > 25000 then
                Line3.Text = "Eval: Mate in " .. tostring(math.ceil((30000 - math.abs(cp)) / 2))
            else
                Line3.Text = string.format("Eval: %+.2f", cp / 100)
            end

            Line4.Text = string.format("Mode: %s | Latency: %dms", Config.Mode, State.CalcTimeMs)
        else
            Line1.Text = "Status: Waiting for game..."
            Line1.TextColor3 = Color3.fromRGB(180, 185, 200)
            Line2.Text = "Best Move: --"
            Line3.Text = "Eval: 0.0"
            Line4.Text = "Mode: " .. Config.Mode .. " (Ready)"
        end

        task.wait(0.05)
    end
end)

print("[RoChess Bot v5.0] Loaded & Running smoothly!")
