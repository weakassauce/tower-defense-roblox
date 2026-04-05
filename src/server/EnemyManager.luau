--!strict
-- src/server/EnemyManager.luau
-- Owns the list of enemies, spawns them at the first waypoint, walks them
-- through the path, and handles damage / slow / poison / death.
-- Ported from enemies.js.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local _Config = Shared.Config

local EnemyManager = {}

export type EnemyConfig = {
	enemyType: string,
	hp: number,
	speed: number,
	reward: number,
	color: Color3,
	scale: number,
}

export type Enemy = {
	model: Model,
	root: Part,
	hpFill: Frame,
	hpText: TextLabel,
	hp: number,
	maxHp: number,
	speed: number,
	baseSpeed: number,
	reward: number,
	waypointIndex: number,
	alive: boolean,
	reachedEnd: boolean,
	damaged: boolean,
	rewarded: boolean,
	slowTimer: number,
	poisonTimer: number,
	poisonDps: number,
	enemyType: string,
	color: Color3,
}

local enemies: { Enemy } = {}
local waypoints: { Vector3 } = {}
local enemyFolder: Folder? = nil

-- --- Model builders ---

local function makePart(
	name: string,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Shape = shape or Enum.PartType.Block
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

-- Builds a composite enemy model. Returns (model, rootPart) where rootPart
-- is the primary body used for positioning and HP bar attachment.
local function buildEnemyModel(config: EnemyConfig): (Model, Part)
	local model = Instance.new("Model")
	model.Name = "Enemy_" .. config.enemyType

	local scale = config.scale

	if config.enemyType == "scout" then
		-- Wolf-like: elongated body + pointy ears + glowing eyes
		local body = makePart(
			"Body",
			Vector3.new(5.5, 2.8, 3.4) * scale,
			config.color,
			Enum.Material.SmoothPlastic
		)
		body.Parent = model

		local head = makePart(
			"Head",
			Vector3.new(2.4, 2.2, 2.4) * scale,
			config.color,
			Enum.Material.SmoothPlastic
		)
		head.CFrame = CFrame.new(2.6 * scale, 1.2 * scale, 0)
		head.Parent = model

		local earL = makePart(
			"EarL",
			Vector3.new(0.6, 1.2, 0.6) * scale,
			Color3.fromRGB(245, 127, 23),
			Enum.Material.SmoothPlastic
		)
		earL.CFrame = CFrame.new(2.8 * scale, 2.5 * scale, -0.7 * scale)
		earL.Parent = model
		local earR = makePart(
			"EarR",
			Vector3.new(0.6, 1.2, 0.6) * scale,
			Color3.fromRGB(245, 127, 23),
			Enum.Material.SmoothPlastic
		)
		earR.CFrame = CFrame.new(2.8 * scale, 2.5 * scale, 0.7 * scale)
		earR.Parent = model

		local eyeL = makePart(
			"EyeL",
			Vector3.new(0.4, 0.4, 0.4) * scale,
			Color3.fromRGB(255, 235, 59),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
		eyeL.CFrame = CFrame.new(3.6 * scale, 1.4 * scale, -0.7 * scale)
		eyeL.Parent = model
		local eyeR = makePart(
			"EyeR",
			Vector3.new(0.4, 0.4, 0.4) * scale,
			Color3.fromRGB(255, 235, 59),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
		eyeR.CFrame = CFrame.new(3.6 * scale, 1.4 * scale, 0.7 * scale)
		eyeR.Parent = model

		model.PrimaryPart = body
		return model, body
	elseif config.enemyType == "troll" then
		-- Big chunky body + darker head + horns + red eyes
		local body = makePart(
			"Body",
			Vector3.new(5.6, 6.5, 5.4) * scale,
			config.color,
			Enum.Material.SmoothPlastic,
			Enum.PartType.Ball
		)
		body.Parent = model

		local head = makePart(
			"Head",
			Vector3.new(3.4, 3, 3.4) * scale,
			Color3.fromRGB(74, 20, 140),
			Enum.Material.SmoothPlastic,
			Enum.PartType.Ball
		)
		head.CFrame = CFrame.new(0, 4.8 * scale, 0)
		head.Parent = model

		local hornL = makePart(
			"HornL",
			Vector3.new(0.6, 2.4, 0.6) * scale,
			Color3.fromRGB(33, 33, 33),
			Enum.Material.SmoothPlastic
		)
		hornL.CFrame = CFrame.new(-1.2 * scale, 6.2 * scale, 0) * CFrame.Angles(0, 0, math.rad(-18))
		hornL.Parent = model
		local hornR = makePart(
			"HornR",
			Vector3.new(0.6, 2.4, 0.6) * scale,
			Color3.fromRGB(33, 33, 33),
			Enum.Material.SmoothPlastic
		)
		hornR.CFrame = CFrame.new(1.2 * scale, 6.2 * scale, 0) * CFrame.Angles(0, 0, math.rad(18))
		hornR.Parent = model

		local eyeL = makePart(
			"EyeL",
			Vector3.new(0.55, 0.55, 0.55) * scale,
			Color3.fromRGB(255, 82, 82),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
		eyeL.CFrame = CFrame.new(-0.9 * scale, 4.9 * scale, 1.5 * scale)
		eyeL.Parent = model
		local eyeR = makePart(
			"EyeR",
			Vector3.new(0.55, 0.55, 0.55) * scale,
			Color3.fromRGB(255, 82, 82),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
		eyeR.CFrame = CFrame.new(0.9 * scale, 4.9 * scale, 1.5 * scale)
		eyeR.Parent = model

		model.PrimaryPart = body
		return model, body
	else
		-- Goblin (default): green body + smaller head + pointy ears + red eyes
		local body = makePart(
			"Body",
			Vector3.new(4, 4.2, 4) * scale,
			config.color,
			Enum.Material.SmoothPlastic,
			Enum.PartType.Ball
		)
		body.Parent = model

		local head = makePart(
			"Head",
			Vector3.new(2.6, 2.6, 2.6) * scale,
			Color3.fromRGB(51, 105, 30),
			Enum.Material.SmoothPlastic,
			Enum.PartType.Ball
		)
		head.CFrame = CFrame.new(0, 3.4 * scale, 0)
		head.Parent = model

		local earL = makePart(
			"EarL",
			Vector3.new(0.6, 1.4, 0.6) * scale,
			Color3.fromRGB(51, 105, 30),
			Enum.Material.SmoothPlastic
		)
		earL.CFrame = CFrame.new(-1.6 * scale, 4 * scale, 0) * CFrame.Angles(0, 0, math.rad(-35))
		earL.Parent = model
		local earR = makePart(
			"EarR",
			Vector3.new(0.6, 1.4, 0.6) * scale,
			Color3.fromRGB(51, 105, 30),
			Enum.Material.SmoothPlastic
		)
		earR.CFrame = CFrame.new(1.6 * scale, 4 * scale, 0) * CFrame.Angles(0, 0, math.rad(35))
		earR.Parent = model

		local eyeL = makePart(
			"EyeL",
			Vector3.new(0.4, 0.4, 0.4) * scale,
			Color3.fromRGB(255, 23, 68),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
		eyeL.CFrame = CFrame.new(-0.7 * scale, 3.5 * scale, 1.1 * scale)
		eyeL.Parent = model
		local eyeR = makePart(
			"EyeR",
			Vector3.new(0.4, 0.4, 0.4) * scale,
			Color3.fromRGB(255, 23, 68),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
		eyeR.CFrame = CFrame.new(0.7 * scale, 3.5 * scale, 1.1 * scale)
		eyeR.Parent = model

		model.PrimaryPart = body
		return model, body
	end
end

local function buildHpBar(parent: Part, maxHp: number): (Frame, TextLabel)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HpBar"
	billboard.Size = UDim2.fromOffset(130, 36)
	billboard.StudsOffset = Vector3.new(0, parent.Size.Y * 0.6 + 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = parent

	-- "X/X" text above the bar
	local hpText = Instance.new("TextLabel")
	hpText.Name = "HpText"
	hpText.Size = UDim2.fromOffset(130, 16)
	hpText.Position = UDim2.fromOffset(0, 0)
	hpText.BackgroundTransparency = 1
	hpText.Text = string.format("%d/%d", maxHp, maxHp)
	hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
	hpText.Font = Enum.Font.GothamBold
	hpText.TextSize = 14
	hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	hpText.TextStrokeTransparency = 0
	hpText.TextXAlignment = Enum.TextXAlignment.Center
	hpText.Parent = billboard

	-- Background strip with rounded corners
	local bg = Instance.new("Frame")
	bg.Name = "BarBg"
	bg.Size = UDim2.fromOffset(126, 14)
	bg.Position = UDim2.fromOffset(2, 20)
	bg.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 5)
	bgCorner.Parent = bg

	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = Color3.fromRGB(0, 0, 0)
	bgStroke.Thickness = 2
	bgStroke.Parent = bg

	-- Fill frame (width scales with HP ratio)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(60, 230, 80)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 5)
	fillCorner.Parent = fill

	return fill, hpText
end

-- --- Public API ---

function EnemyManager.init(waypointList: { Vector3 })
	waypoints = waypointList

	-- Fresh folder each Play session so hot reloads don't pile up enemies
	local existing = workspace:FindFirstChild("Enemies")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = workspace
	enemyFolder = folder

	enemies = {}
end

function EnemyManager.spawn(config: EnemyConfig): Enemy
	assert(#waypoints > 0, "EnemyManager.init(waypoints) must be called first")
	assert(enemyFolder, "enemyFolder not initialized")

	local model, body = buildEnemyModel(config)
	local hpFill, hpText = buildHpBar(body, config.hp)

	local startPos = waypoints[1]
	model:PivotTo(CFrame.new(startPos))
	model.Parent = enemyFolder

	local enemy: Enemy = {
		model = model,
		root = body,
		hpFill = hpFill,
		hpText = hpText,
		hp = config.hp,
		maxHp = config.hp,
		speed = config.speed,
		baseSpeed = config.speed,
		reward = config.reward,
		waypointIndex = 2, -- head toward the second waypoint (we already stand on the first)
		alive = true,
		reachedEnd = false,
		damaged = false,
		rewarded = false,
		slowTimer = 0,
		poisonTimer = 0,
		poisonDps = 0,
		enemyType = config.enemyType,
		color = config.color,
	}

	table.insert(enemies, enemy)
	return enemy
end

function EnemyManager.damage(enemy: Enemy, amount: number)
	if not enemy.alive then
		return
	end

	enemy.hp -= amount
	if enemy.hp <= 0 then
		enemy.alive = false
		enemy.model:Destroy()
		return
	end

	-- Update HP bar + text
	local shownHp = math.max(0, math.ceil(enemy.hp))
	enemy.hpText.Text = string.format("%d/%d", shownHp, enemy.maxHp)
	local ratio = math.max(0, enemy.hp / enemy.maxHp)
	enemy.hpFill.Size = UDim2.fromScale(ratio, 1)
	if ratio > 0.5 then
		-- Vibrant green
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(60, 230, 80)
	elseif ratio > 0.25 then
		-- Bright amber
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(255, 170, 30)
	else
		-- Vibrant red
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
	end
end

function EnemyManager.applySlow(enemy: Enemy, factor: number, duration: number)
	enemy.speed = enemy.baseSpeed * factor
	enemy.slowTimer = duration
end

function EnemyManager.applyPoison(enemy: Enemy, dps: number, duration: number)
	enemy.poisonDps = math.max(enemy.poisonDps, dps)
	enemy.poisonTimer = math.max(enemy.poisonTimer, duration)
end

function EnemyManager.getAlive(): { Enemy }
	local alive = {}
	for _, e in enemies do
		if e.alive then
			table.insert(alive, e)
		end
	end
	return alive
end

-- All enemies including dead/reachedEnd ones that haven't been cleaned yet.
-- Used by the main loop to find enemies that need to have their reward
-- paid or HP damage applied to the base.
function EnemyManager.getAll(): { Enemy }
	return enemies
end

function EnemyManager.update(dt: number)
	for _, enemy in enemies do
		if not enemy.alive then
			continue
		end

		-- Slow timer
		if enemy.slowTimer > 0 then
			enemy.slowTimer -= dt
			if enemy.slowTimer <= 0 then
				enemy.speed = enemy.baseSpeed
			end
		end

		-- Poison DoT
		if enemy.poisonTimer > 0 then
			enemy.poisonTimer -= dt
			EnemyManager.damage(enemy, enemy.poisonDps * dt)
			if not enemy.alive then
				continue
			end
		end

		-- Walk toward current waypoint
		local target = waypoints[enemy.waypointIndex]
		if not target then
			continue
		end

		local currentPos = enemy.root.Position
		local toTarget = Vector3.new(target.X - currentPos.X, 0, target.Z - currentPos.Z)
		local dist = toTarget.Magnitude
		local step = enemy.speed * dt

		if dist <= step then
			enemy.waypointIndex += 1
			if enemy.waypointIndex > #waypoints then
				enemy.alive = false
				enemy.reachedEnd = true
				enemy.model:Destroy()
				continue
			end
			enemy.model:PivotTo(CFrame.new(target))
		else
			local dir = toTarget.Unit
			local newPos = currentPos + dir * step
			-- Face direction of travel so multi-part models will look right later
			enemy.model:PivotTo(CFrame.lookAt(newPos, newPos + dir))
		end
	end
end

-- Remove dead enemies from the list (call after damage/reward processing)
function EnemyManager.cleanup()
	for i = #enemies, 1, -1 do
		if not enemies[i].alive then
			table.remove(enemies, i)
		end
	end
end

function EnemyManager.clear()
	for _, enemy in enemies do
		if enemy.alive then
			enemy.model:Destroy()
		end
	end
	enemies = {}
end

return EnemyManager
