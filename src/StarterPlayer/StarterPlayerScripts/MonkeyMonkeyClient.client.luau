-- MonkeyMonkeyClient.client.luau
-- Monkey-Monkey in-game UI
-- Place inside: StarterPlayerScripts

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player.PlayerGui

local mmFolder = ReplicatedStorage:WaitForChild("MonkeyMonkeyRemotes")
local gameStateEvent = mmFolder:WaitForChild("GameState")
local drawCardEvent = mmFolder:WaitForChild("DrawCard")
local gameOverEvent = mmFolder:WaitForChild("GameOver")

-- ── State ─────────────────────────────────────────────────────────────────────
local gameGui: ScreenGui? = nil
local drawLocked = false -- prevent double-draw clicks

-- ── Card display helpers ──────────────────────────────────────────────────────
local SUIT_SYMBOLS = { S = "♠", H = "♥", D = "♦", C = "♣" }
local SUIT_COLORS = {
	S = Color3.fromRGB(15, 15, 20),
	H = Color3.fromRGB(200, 30, 30),
	D = Color3.fromRGB(200, 30, 30),
	C = Color3.fromRGB(15, 15, 20),
}

local function parseCard(card: string): (string, string, Color3)
	if card == "MONKEY" then
		return "MONKEY", "🐒", Color3.fromRGB(180, 80, 0)
	end
	local rank, suit = card:match("^(.-)_(.+)$")
	rank = rank or "?"
	suit = suit or "S"
	return rank, SUIT_SYMBOLS[suit] or "?", SUIT_COLORS[suit] or Color3.fromRGB(0, 0, 0)
end

-- Create a card face-up (your own hand).
local function makeFaceUpCard(parent: Instance, card: string, xOffset: number, cardW: number, cardH: number): Frame
	local rank, symbol, color = parseCard(card)

	local frame = Instance.new("Frame")
	frame.Name = "Card"
	frame.Size = UDim2.fromOffset(cardW, cardH)
	frame.Position = UDim2.new(0, xOffset, 0.5, -(cardH / 2))
	frame.BackgroundColor3 = (card == "MONKEY") and Color3.fromRGB(255, 240, 200) or Color3.fromRGB(255, 255, 255)
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(130, 130, 130)
	stroke.Thickness = 1
	stroke.Parent = frame

	if card == "MONKEY" then
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.TextColor3 = color
		lbl.Font = Enum.Font.GothamBold
		lbl.TextScaled = true
		lbl.Text = "🐒\nMONKEY"
		lbl.Parent = frame
	else
		-- Top-left rank + suit
		local top = Instance.new("TextLabel")
		top.Size = UDim2.new(1, -4, 0, math.floor(cardH * 0.38))
		top.Position = UDim2.new(0, 3, 0, 2)
		top.BackgroundTransparency = 1
		top.TextColor3 = color
		top.Font = Enum.Font.GothamBold
		top.TextScaled = true
		top.TextXAlignment = Enum.TextXAlignment.Left
		top.TextYAlignment = Enum.TextYAlignment.Top
		top.Text = rank .. "\n" .. symbol
		top.Parent = frame

		-- Centre suit
		local centre = Instance.new("TextLabel")
		centre.Size = UDim2.new(1, 0, 0.4, 0)
		centre.Position = UDim2.new(0, 0, 0.3, 0)
		centre.BackgroundTransparency = 1
		centre.TextColor3 = color
		centre.Font = Enum.Font.GothamBold
		centre.TextScaled = true
		centre.Text = symbol
		centre.Parent = frame
	end

	return frame
end

-- Create a face-down card the current player can click to draw.
local function makeFaceDownCard(
	parent: Instance,
	cardIndex: number,
	xOffset: number,
	cardW: number,
	cardH: number,
	onDraw: (number) -> ()
): Frame
	local frame = Instance.new("Frame")
	frame.Name = "NeighborCard"
	frame.Size = UDim2.fromOffset(cardW, cardH)
	frame.Position = UDim2.new(0, xOffset, 0.5, -(cardH / 2))
	frame.BackgroundColor3 = Color3.fromRGB(28, 68, 148)
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 215, 0)
	stroke.Thickness = 2
	stroke.Parent = frame

	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.TextColor3 = Color3.fromRGB(220, 220, 255)
	icon.Font = Enum.Font.GothamBold
	icon.TextScaled = true
	icon.Text = "🂠"
	icon.Parent = frame

	-- Clickable overlay
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromScale(1, 1)
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.ZIndex = frame.ZIndex + 1
	btn.Parent = frame

	local basePos = frame.Position
	btn.MouseEnter:Connect(function()
		frame.Position = basePos - UDim2.fromOffset(0, 8)
	end)
	btn.MouseLeave:Connect(function()
		frame.Position = basePos
	end)
	btn.MouseButton1Click:Connect(function()
		if not drawLocked then
			onDraw(cardIndex)
		end
	end)

	return frame
end

-- ── UI build ──────────────────────────────────────────────────────────────────
local function buildGameUI()
	if gameGui then
		gameGui:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "MonkeyMonkeyGame"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	gui.Parent = playerGui
	gameGui = gui

	-- ── Status bar ────────────────────────────────────────────────────────────
	local statusBar = Instance.new("Frame")
	statusBar.Name = "StatusBar"
	statusBar.Size = UDim2.new(0.55, 0, 0, 44)
	statusBar.Position = UDim2.new(0.225, 0, 0, 58)
	statusBar.BackgroundColor3 = Color3.fromRGB(12, 12, 22)
	statusBar.BackgroundTransparency = 0.15
	statusBar.BorderSizePixel = 0
	statusBar.Parent = gui

	local sbCorner = Instance.new("UICorner")
	sbCorner.CornerRadius = UDim.new(0, 8)
	sbCorner.Parent = statusBar

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusLabel"
	statusLabel.Size = UDim2.fromScale(1, 1)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(255, 255, 200)
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextScaled = true
	statusLabel.Text = "Monkey Monkey"
	statusLabel.Parent = statusBar

	-- ── Player panel (right side) ─────────────────────────────────────────────
	local playerPanel = Instance.new("Frame")
	playerPanel.Name = "PlayerPanel"
	playerPanel.Size = UDim2.new(0, 180, 0, 0) -- height set dynamically
	playerPanel.Position = UDim2.new(1, -192, 0, 110)
	playerPanel.BackgroundColor3 = Color3.fromRGB(12, 12, 22)
	playerPanel.BackgroundTransparency = 0.15
	playerPanel.BorderSizePixel = 0
	playerPanel.AutomaticSize = Enum.AutomaticSize.Y
	playerPanel.Parent = gui

	local ppCorner = Instance.new("UICorner")
	ppCorner.CornerRadius = UDim.new(0, 8)
	ppCorner.Parent = playerPanel

	local ppPad = Instance.new("UIPadding")
	ppPad.PaddingTop = UDim.new(0, 8)
	ppPad.PaddingBottom = UDim.new(0, 8)
	ppPad.PaddingLeft = UDim.new(0, 10)
	ppPad.PaddingRight = UDim.new(0, 10)
	ppPad.Parent = playerPanel

	local ppList = Instance.new("UIListLayout")
	ppList.SortOrder = Enum.SortOrder.LayoutOrder
	ppList.Padding = UDim.new(0, 4)
	ppList.Parent = playerPanel

	local ppTitle = Instance.new("TextLabel")
	ppTitle.Name = "PanelTitle"
	ppTitle.Size = UDim2.new(1, 0, 0, 24)
	ppTitle.BackgroundTransparency = 1
	ppTitle.TextColor3 = Color3.fromRGB(255, 200, 50)
	ppTitle.Font = Enum.Font.GothamBold
	ppTitle.TextScaled = true
	ppTitle.Text = "PLAYERS"
	ppTitle.LayoutOrder = 0
	ppTitle.Parent = playerPanel

	-- ── Draw area (middle — neighbour cards) ──────────────────────────────────
	local drawArea = Instance.new("Frame")
	drawArea.Name = "DrawArea"
	drawArea.Size = UDim2.new(0.72, 0, 0, 150)
	drawArea.Position = UDim2.new(0.14, 0, 0.28, 0)
	drawArea.BackgroundTransparency = 1
	drawArea.Visible = false
	drawArea.Parent = gui

	local drawPrompt = Instance.new("TextLabel")
	drawPrompt.Name = "DrawPrompt"
	drawPrompt.Size = UDim2.new(1, 0, 0, 28)
	drawPrompt.Position = UDim2.fromScale(0, 0)
	drawPrompt.BackgroundTransparency = 1
	drawPrompt.TextColor3 = Color3.fromRGB(255, 230, 80)
	drawPrompt.Font = Enum.Font.GothamBold
	drawPrompt.TextScaled = true
	drawPrompt.Text = "Pick a card from your neighbour:"
	drawPrompt.Parent = drawArea

	local cardRow = Instance.new("Frame")
	cardRow.Name = "CardRow"
	cardRow.Size = UDim2.new(1, 0, 1, -32)
	cardRow.Position = UDim2.new(0, 0, 0, 32)
	cardRow.BackgroundTransparency = 1
	cardRow.Parent = drawArea

	-- ── My hand (bottom strip) ────────────────────────────────────────────────
	local handStrip = Instance.new("Frame")
	handStrip.Name = "HandStrip"
	handStrip.Size = UDim2.new(1, 0, 0, 128)
	handStrip.Position = UDim2.new(0, 0, 1, -134)
	handStrip.BackgroundColor3 = Color3.fromRGB(12, 12, 22)
	handStrip.BackgroundTransparency = 0.25
	handStrip.BorderSizePixel = 0
	handStrip.ClipsDescendants = true
	handStrip.Parent = gui

	local handLabel = Instance.new("TextLabel")
	handLabel.Name = "HandLabel"
	handLabel.Size = UDim2.new(0, 90, 0, 22)
	handLabel.Position = UDim2.new(0, 8, 0, 4)
	handLabel.BackgroundTransparency = 1
	handLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	handLabel.Font = Enum.Font.Gotham
	handLabel.TextScaled = true
	handLabel.Text = "Your Hand"
	handLabel.Parent = handStrip

	return gui
end

-- ── UI update ─────────────────────────────────────────────────────────────────
local function updateUI(state)
	if not gameGui then
		buildGameUI()
	end
	local gui = gameGui
	if not gui then
		return
	end

	local isMyTurn = state.currentTurnName == player.Name

	-- Status bar
	local statusLabel = gui:FindFirstChild("StatusBar")
		and gui.StatusBar:FindFirstChild("StatusLabel") :: TextLabel?
	if statusLabel then
		if state.phase == "gameover" then
			-- handled separately by gameOverEvent
		elseif isMyTurn then
			statusLabel.Text = "Your turn! Draw from " .. state.rightNeighbourName
			statusLabel.TextColor3 = Color3.fromRGB(80, 255, 120)
		else
			statusLabel.Text = state.currentTurnName .. "'s turn"
			statusLabel.TextColor3 = Color3.fromRGB(255, 255, 200)
		end
	end

	-- Player panel entries
	local playerPanel = gui:FindFirstChild("PlayerPanel")
	if playerPanel then
		for _, child in ipairs(playerPanel:GetChildren()) do
			if child.Name == "PlayerEntry" then
				child:Destroy()
			end
		end

		for i, pInfo in ipairs(state.players) do
			local entry = Instance.new("TextLabel")
			entry.Name = "PlayerEntry"
			entry.LayoutOrder = i
			entry.Size = UDim2.new(1, 0, 0, 26)
			entry.BackgroundTransparency = 1
			entry.Font = (state.currentTurnName == pInfo.name) and Enum.Font.GothamBold or Enum.Font.Gotham
			entry.TextScaled = true
			entry.TextXAlignment = Enum.TextXAlignment.Left

			local arrow = (state.currentTurnName == pInfo.name) and "▶ " or "   "
			local safe = (not pInfo.isActive) and " ✓" or ""
			local nameStr = (pInfo.name == player.Name) and "You" or pInfo.name
			entry.Text = arrow .. nameStr .. ": " .. pInfo.cardCount .. safe

			if not pInfo.isActive then
				entry.TextColor3 = Color3.fromRGB(80, 200, 100) -- safe = green
			elseif state.currentTurnName == pInfo.name then
				entry.TextColor3 = Color3.fromRGB(255, 230, 80) -- active turn = yellow
			else
				entry.TextColor3 = Color3.fromRGB(220, 220, 220)
			end

			entry.Parent = playerPanel
		end
	end

	-- My hand strip
	local handStrip = gui:FindFirstChild("HandStrip")
	if handStrip then
		for _, child in ipairs(handStrip:GetChildren()) do
			if child.Name == "Card" then
				child:Destroy()
			end
		end

		local myHand = state.myHand or {}
		local CARD_W = 68
		local CARD_H = 100
		local GAP = 6
		local totalW = #myHand * (CARD_W + GAP) - GAP
		local startX = math.max(8, (handStrip.AbsoluteSize.X - totalW) / 2)

		for i, card in ipairs(myHand) do
			local xOff = startX + (i - 1) * (CARD_W + GAP)
			makeFaceUpCard(handStrip, card, xOff, CARD_W, CARD_H)
		end
	end

	-- Draw area (neighbour cards, only shown to the current player)
	local drawArea = gui:FindFirstChild("DrawArea")
	local cardRow = drawArea and drawArea:FindFirstChild("CardRow")
	if drawArea and cardRow then
		for _, child in ipairs(cardRow:GetChildren()) do
			if child.Name == "NeighborCard" then
				child:Destroy()
			end
		end

		local count = state.rightNeighbourCardCount or 0
		if isMyTurn and count > 0 then
			drawArea.Visible = true
			drawLocked = false

			local prompt = drawArea:FindFirstChild("DrawPrompt") :: TextLabel?
			if prompt then
				prompt.Text = "Draw from " .. state.rightNeighbourName .. ":"
			end

			local CARD_W = 58
			local CARD_H = 84
			local GAP = 5
			local totalW = count * (CARD_W + GAP) - GAP
			local startX = math.max(0, (cardRow.AbsoluteSize.X - totalW) / 2)

			for i = 1, count do
				local xOff = startX + (i - 1) * (CARD_W + GAP)
				makeFaceDownCard(cardRow, i, xOff, CARD_W, CARD_H, function(idx: number)
					if drawLocked then
						return
					end
					drawLocked = true
					drawCardEvent:FireServer(idx)
					drawArea.Visible = false
				end)
			end
		else
			drawArea.Visible = false
		end
	end
end

-- ── Remote listeners ──────────────────────────────────────────────────────────
gameStateEvent.OnClientEvent:Connect(function(state)
	if not gameGui then
		buildGameUI()
	end
	updateUI(state)
end)

gameOverEvent.OnClientEvent:Connect(function(loserName: string)
	local isLoser = loserName == player.Name

	-- Update status bar with result
	local statusLabel = gameGui
		and gameGui:FindFirstChild("StatusBar")
		and gameGui.StatusBar:FindFirstChild("StatusLabel") :: TextLabel?
	if statusLabel then
		if isLoser then
			statusLabel.Text = "You are the Monkey! 🐒  You lose!"
			statusLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
		else
			statusLabel.Text = loserName .. " is the Monkey! 🐒"
			statusLabel.TextColor3 = Color3.fromRGB(80, 255, 120)
		end
	end

	-- Hide the draw area so no stale clicks fire
	local drawArea = gameGui and gameGui:FindFirstChild("DrawArea")
	if drawArea then
		drawArea.Visible = false
	end

	-- Destroy UI after the game-over message has been read
	task.delay(6, function()
		if gameGui then
			gameGui:Destroy()
			gameGui = nil
		end
		drawLocked = false
	end)
end)

-- Clean up if the player leaves the room (server fires LeaveRoom)
local tableRemotes = ReplicatedStorage:WaitForChild("TableGameRemotes")
local leaveRoomEvent = tableRemotes:WaitForChild("LeaveRoom")
leaveRoomEvent.OnClientEvent:Connect(function()
	if gameGui then
		gameGui:Destroy()
		gameGui = nil
	end
	drawLocked = false
end)

print("[MonkeyMonkeyClient] Ready")
