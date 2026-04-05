--!strict
-- src/server/Castle.luau
-- A visible stone castle placed at the end of the path. Exposes build(),
-- updateHp(current, max) to refresh its HP bar, and flashDamage() for a
-- brief red flash whenever the base takes a hit.

local Castle = {}

local castleFolder: Folder? = nil
local castleCenter: Vector3 = Vector3.new(0, 0, 0)
local hpFill: Frame? = nil
local hpText: TextLabel? = nil
local bodyParts: { Part } = {}
local originalColors: { [Part]: Color3 } = {}

local STONE = Color3.fromRGB(150, 145, 135)
local STONE_DARK = Color3.fromRGB(95, 90, 82)
local ROOF = Color3.fromRGB(120, 40, 35)
local WOOD = Color3.fromRGB(78, 52, 36)

local function makeBlock(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function track(part: Part)
	-- Tint-flashable parts: collected so flashDamage can swap them together
	table.insert(bodyParts, part)
	originalColors[part] = part.Color
end

-- Builds the castle centered at `pos` (Vector3 in world space). Returns
-- the list of extra waypoints that extend the enemy path into the castle
-- interior (so enemies visually walk into the gate before dying).
function Castle.build(pos: Vector3, maxHp: number): { Vector3 }
	-- Fresh folder each time
	local existing = workspace:FindFirstChild("Castle")
	if existing then
		existing:Destroy()
	end

	castleFolder = Instance.new("Folder")
	castleFolder.Name = "Castle"
	castleFolder.Parent = workspace
	castleCenter = pos
	bodyParts = {}
	originalColors = {}

	local cx = pos.X
	local cz = pos.Z
	local folder = castleFolder

	-- Stone platform
	local base = makeBlock(
		folder,
		"Base",
		Vector3.new(18, 2, 20),
		CFrame.new(cx, 1, cz),
		STONE_DARK,
		Enum.Material.Slate
	)
	track(base)

	-- Central keep
	local keep = makeBlock(
		folder,
		"Keep",
		Vector3.new(9, 14, 9),
		CFrame.new(cx + 2, 9, cz),
		STONE,
		Enum.Material.Brick
	)
	track(keep)

	-- Keep battlements (small blocks around the top)
	for i = 0, 7 do
		local angle = (i / 8) * math.pi * 2
		local bx = cx + 2 + math.cos(angle) * 4.8
		local bz = cz + math.sin(angle) * 4.8
		local bat = makeBlock(
			folder,
			"KeepCren",
			Vector3.new(1, 1.4, 1),
			CFrame.new(bx, 16.7, bz),
			STONE_DARK,
			Enum.Material.Brick
		)
		track(bat)
	end

	-- 4 corner towers
	local cornerOffsets = {
		Vector3.new(-7, 0, -8.5),
		Vector3.new(7, 0, -8.5),
		Vector3.new(-7, 0, 8.5),
		Vector3.new(7, 0, 8.5),
	}
	for i, off in cornerOffsets do
		local tx = cx + off.X
		local tz = cz + off.Z
		local tower = makeBlock(
			folder,
			"CornerTower" .. i,
			Vector3.new(3.5, 16, 3.5),
			CFrame.new(tx, 10, tz),
			STONE,
			Enum.Material.Brick
		)
		track(tower)
		local cap = makeBlock(
			folder,
			"CornerCap" .. i,
			Vector3.new(4.2, 0.5, 4.2),
			CFrame.new(tx, 18.3, tz),
			STONE_DARK,
			Enum.Material.Brick
		)
		track(cap)
		-- Conical roof as a stacked block
		local roof = makeBlock(
			folder,
			"CornerRoof" .. i,
			Vector3.new(2.4, 2.2, 2.4),
			CFrame.new(tx, 19.7, tz),
			ROOF,
			Enum.Material.Slate
		)
		track(roof)
	end

	-- Gate: dark archway on the west side (enemies enter here)
	local gateArch = makeBlock(
		folder,
		"Gate",
		Vector3.new(0.8, 6, 5),
		CFrame.new(cx - 7, 5, cz),
		Color3.fromRGB(20, 12, 6),
		Enum.Material.DiamondPlate
	)
	track(gateArch)
	-- Wooden door under the arch
	local gateDoor = makeBlock(
		folder,
		"GateDoor",
		Vector3.new(0.4, 5, 4),
		CFrame.new(cx - 7.3, 4.5, cz),
		WOOD,
		Enum.Material.Wood
	)
	track(gateDoor)

	-- Flag pole + flag on top of the keep
	makeBlock(
		folder,
		"Pole",
		Vector3.new(0.3, 5, 0.3),
		CFrame.new(cx + 2, 18.5, cz),
		WOOD,
		Enum.Material.Wood
	)
	makeBlock(
		folder,
		"Flag",
		Vector3.new(3, 1.6, 0.1),
		CFrame.new(cx + 3.5, 19.8, cz),
		Color3.fromRGB(200, 40, 30),
		Enum.Material.Fabric
	)

	-- --- HP bar above the keep ---
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CastleHpBar"
	billboard.Size = UDim2.fromOffset(280, 60)
	billboard.StudsOffset = Vector3.new(0, 14, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = keep

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromOffset(280, 22)
	title.Position = UDim2.fromOffset(0, 0)
	title.BackgroundTransparency = 1
	title.Text = "CASTLE"
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(232, 194, 143)
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.TextStrokeTransparency = 0
	title.Parent = billboard

	local text = Instance.new("TextLabel")
	text.Name = "HpText"
	text.Size = UDim2.fromOffset(280, 16)
	text.Position = UDim2.fromOffset(0, 22)
	text.BackgroundTransparency = 1
	text.Text = string.format("%d / %d", maxHp, maxHp)
	text.Font = Enum.Font.GothamBold
	text.TextSize = 14
	text.TextColor3 = Color3.fromRGB(255, 255, 255)
	text.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	text.TextStrokeTransparency = 0
	text.Parent = billboard
	hpText = text

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.fromOffset(260, 14)
	barBg.Position = UDim2.fromOffset(10, 42)
	barBg.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	barBg.BorderSizePixel = 0
	barBg.Parent = billboard

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 6)
	bgCorner.Parent = barBg
	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = Color3.fromRGB(0, 0, 0)
	bgStroke.Thickness = 2
	bgStroke.Parent = barBg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(60, 230, 80)
	fill.BorderSizePixel = 0
	fill.Parent = barBg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill
	hpFill = fill

	-- Return extra waypoints so enemies walk into the gate and a step
	-- inside before dying
	return {
		Vector3.new(cx - 10, 2, cz),
		Vector3.new(cx - 3, 2, cz),
	}
end

function Castle.updateHp(current: number, max: number)
	if not hpFill or not hpText then
		return
	end
	local clamped = math.max(0, current)
	hpText.Text = string.format("%d / %d", clamped, max)
	local ratio = math.max(0, clamped / max)
	hpFill.Size = UDim2.fromScale(ratio, 1)
	if ratio > 0.5 then
		hpFill.BackgroundColor3 = Color3.fromRGB(60, 230, 80)
	elseif ratio > 0.25 then
		hpFill.BackgroundColor3 = Color3.fromRGB(255, 170, 30)
	else
		hpFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
	end
end

function Castle.flashDamage()
	if #bodyParts == 0 then
		return
	end
	task.spawn(function()
		for _, part in bodyParts do
			part.Color = Color3.fromRGB(255, 90, 90)
		end
		task.wait(0.12)
		for _, part in bodyParts do
			part.Color = originalColors[part] or part.Color
		end
	end)
end

-- Unanchors every castle part and launches it outward/upward so the
-- castle physically blows apart when the player loses. The folder is
-- destroyed after a short delay so the pieces can fall and settle.
function Castle.explode()
	local folder = castleFolder
	if not folder then
		return
	end

	local center = castleCenter
	for _, child in folder:GetDescendants() do
		if child:IsA("BasePart") then
			local dx = child.Position.X - center.X
			local dz = child.Position.Z - center.Z
			local dir: Vector3
			local distSq = dx * dx + dz * dz
			if distSq < 0.25 then
				dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
				if dir.Magnitude < 0.01 then
					dir = Vector3.new(1, 0, 0)
				end
				dir = dir.Unit
			else
				dir = Vector3.new(dx, 0, dz).Unit
			end

			child.Anchored = false
			child.CanCollide = true
			child.CastShadow = true
			child.AssemblyLinearVelocity = dir * (25 + math.random() * 15)
				+ Vector3.new(0, 45 + math.random() * 30, 0)
			child.AssemblyAngularVelocity = Vector3.new(
				(math.random() - 0.5) * 12,
				(math.random() - 0.5) * 12,
				(math.random() - 0.5) * 12
			)
		end
	end

	-- Clear refs since the pieces are now owned by physics
	hpFill = nil
	hpText = nil
	bodyParts = {}

	task.delay(5, function()
		if folder and folder.Parent then
			folder:Destroy()
		end
		if castleFolder == folder then
			castleFolder = nil
		end
	end)
end

return Castle
