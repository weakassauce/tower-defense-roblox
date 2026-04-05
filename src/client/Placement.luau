--!strict
-- src/client/Placement.luau
-- Camera management + mouse-based tower placement and pickup.
-- Default mode is "overview" — a scripted camera high above the map looking
-- straight down. Tab toggles to "explore" where the default Roblox follow
-- camera and character take over so you can walk around.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local Config = require(ReplicatedStorage.Shared.Config)

local Hud = require(script.Parent.Hud)

local Placement = {}

type Mode = "overview" | "explore"

local camera = workspace.CurrentCamera

local mode: Mode = "overview"
local enabled = false

-- When set, the RenderStepped loop uses this CFrame every frame instead of
-- the normal overview/explore logic. Used by the castle-destroyed cinematic.
local cinematicCFrame: CFrame? = nil
local lerpStartCFrame: CFrame? = nil
local lerpStartTime = 0
local lerpDuration = 0

local preview: Part? = nil
local previewRange: Part? = nil
local cellsFolder: Folder? = nil
local towersFolder: Folder? = nil

-- Overview camera — positioned high and tilted forward looking at map center.
-- Map extents are ±64 studs (16*8/2) so ~150 up / 100 back frames it nicely.
local OVERVIEW_POS = Vector3.new(0, 150, 100)
local OVERVIEW_TARGET = Vector3.new(0, 0, 0)

-- --- Helpers ---

local function ensureWorkspaceFolders()
	if not cellsFolder then
		local map = workspace:FindFirstChild("Map")
		if map then
			cellsFolder = map:FindFirstChild("Cells") :: Folder?
		end
	end
	if not towersFolder then
		towersFolder = workspace:FindFirstChild("Towers") :: Folder?
	end
end

local function applyOverviewCamera()
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(OVERVIEW_POS, OVERVIEW_TARGET)
end

local function applyExploreCamera()
	camera.CameraType = Enum.CameraType.Custom
end

local function getCellUnderMouse(): (number?, number?, Vector3?)
	ensureWorkspaceFolders()
	if not cellsFolder then
		return nil, nil, nil
	end

	local mousePos = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { cellsFolder }

	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not result or not result.Instance then
		return nil, nil, nil
	end

	local gx = result.Instance:GetAttribute("gx")
	local gy = result.Instance:GetAttribute("gy")
	if typeof(gx) == "number" and typeof(gy) == "number" then
		return gx, gy, result.Position
	end
	return nil, nil, nil
end

local function getTowerUnderMouse(): (number?, number?)
	ensureWorkspaceFolders()
	if not towersFolder then
		return nil, nil
	end

	local mousePos = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { towersFolder }

	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not result or not result.Instance then
		return nil, nil
	end

	-- Walk up to the Tower model (direct child of the Towers folder)
	local inst: Instance? = result.Instance
	while inst and inst.Parent ~= towersFolder do
		inst = inst.Parent
	end
	if not inst or not inst:IsA("Model") then
		return nil, nil
	end

	local pivot = inst:GetPivot().Position
	local gx, gy = Config.worldToGrid(pivot.X, pivot.Z)
	return gx, gy
end

local function buildPreview()
	preview = Instance.new("Part")
	preview.Name = "PlacementPreview"
	preview.Anchored = true
	preview.CanCollide = false
	preview.Size = Vector3.new(3, 6, 3)
	preview.Material = Enum.Material.Neon
	preview.Color = Color3.fromRGB(100, 220, 100)
	preview.Transparency = 0.55
	preview.CastShadow = false
	preview.Parent = workspace

	previewRange = Instance.new("Part")
	previewRange.Name = "PlacementPreviewRange"
	previewRange.Anchored = true
	previewRange.CanCollide = false
	previewRange.Size = Vector3.new(20, 0.2, 20)
	previewRange.Material = Enum.Material.Neon
	previewRange.Color = Color3.fromRGB(100, 220, 100)
	previewRange.Transparency = 0.9
	previewRange.CastShadow = false
	previewRange.Parent = workspace
end

local function hidePreview()
	if preview then
		preview.Transparency = 1
	end
	if previewRange then
		previewRange.Transparency = 1
	end
end

local function showPreview(gx: number, gy: number, valid: boolean, rangeStuds: number)
	if not preview or not previewRange then
		return
	end
	local cellWorld = Config.gridToWorld(gx, gy)
	preview.Transparency = 0.55
	preview.Position = Vector3.new(cellWorld.X, 3, cellWorld.Z)
	preview.Color = valid and Color3.fromRGB(100, 220, 100) or Color3.fromRGB(230, 80, 80)

	previewRange.Transparency = 0.88
	previewRange.Position = Vector3.new(cellWorld.X, 0.25, cellWorld.Z)
	previewRange.Size = Vector3.new(rangeStuds * 2, 0.2, rangeStuds * 2)
	previewRange.Color = preview.Color
end

-- --- Public API ---

function Placement.setEnabled(v: boolean)
	enabled = v
	if not enabled then
		hidePreview()
	end
end

-- Smoothly lerps the camera from its current position to `cf` over
-- `duration` seconds and then holds it there. While cinematic, placement
-- preview is hidden.
function Placement.cinematicPanTo(cf: CFrame, duration: number)
	lerpStartCFrame = camera.CFrame
	cinematicCFrame = cf
	lerpStartTime = os.clock()
	lerpDuration = math.max(0, duration)
end

-- Lerps the camera toward a view of the player's character, then switches
-- CameraType to Custom so Roblox's default follow-cam takes over. Used at
-- the end of the castle-destroyed cinematic so the camera returns to the
-- player instead of the top-down overview.
function Placement.cinematicReturnToCharacter(duration: number)
	local player = Players.LocalPlayer
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: Part?
	if not root then
		-- No character yet; just release the cinematic and fall back to overview
		cinematicCFrame = nil
		lerpStartCFrame = nil
		mode = "overview"
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.lookAt(OVERVIEW_POS, OVERVIEW_TARGET)
		return
	end

	local charPos = root.Position
	local eye = charPos + Vector3.new(-14, 10, -14)
	local target = charPos + Vector3.new(0, 3, 0)
	lerpStartCFrame = camera.CFrame
	cinematicCFrame = CFrame.lookAt(eye, target)
	lerpStartTime = os.clock()
	lerpDuration = math.max(0.01, duration)
	task.delay(duration, function()
		cinematicCFrame = nil
		lerpStartCFrame = nil
		-- Hand control to Roblox's default follow camera so it tracks
		-- the character going forward.
		mode = "explore"
		camera.CameraType = Enum.CameraType.Custom
	end)
end

-- Clears any in-progress cinematic lerp. Unlike the original version of
-- this function, we DON'T force the camera back to overview — if the
-- player ended up in character view at the end of the castle-destroyed
-- cinematic, they keep that view across restarts and can press Tab
-- whenever they want to swap to the top-down placement camera.
function Placement.cinematicRelease()
	cinematicCFrame = nil
	lerpStartCFrame = nil
end

-- Sets character follow as the active camera mode (used for walking
-- around the lobby).
function Placement.enterLobbyMode()
	cinematicCFrame = nil
	lerpStartCFrame = nil
	mode = "explore"
	camera.CameraType = Enum.CameraType.Custom
end

-- Sets the top-down overview camera (used when the player touches the
-- Realm Defense portal).
function Placement.enterArenaMode()
	cinematicCFrame = nil
	lerpStartCFrame = nil
	mode = "overview"
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(OVERVIEW_POS, OVERVIEW_TARGET)
end

function Placement.init()
	buildPreview()
	hidePreview()
	applyOverviewCamera()

	-- Tab toggle (sink the input so the default behavior doesn't steal it)
	ContextActionService:BindAction("ToggleCameraMode", function(_action, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if mode == "overview" then
			mode = "explore"
			applyExploreCamera()
		else
			mode = "overview"
			applyOverviewCamera()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Tab)

	-- Keep the scripted camera pinned each frame + update hover preview
	RunService.RenderStepped:Connect(function()
		if cinematicCFrame then
			camera.CameraType = Enum.CameraType.Scriptable
			if lerpStartCFrame and lerpDuration > 0 then
				local t = math.clamp((os.clock() - lerpStartTime) / lerpDuration, 0, 1)
				-- Ease-out quad
				local eased = 1 - (1 - t) * (1 - t)
				camera.CFrame = lerpStartCFrame:Lerp(cinematicCFrame, eased)
				if t >= 1 then
					lerpStartCFrame = nil
				end
			else
				camera.CFrame = cinematicCFrame
			end
			hidePreview()
			return
		end
		if mode == "overview" and camera.CameraType == Enum.CameraType.Scriptable then
			camera.CFrame = CFrame.lookAt(OVERVIEW_POS, OVERVIEW_TARGET)
		end

		if not enabled or Hud.isGameOver() then
			hidePreview()
			return
		end

		local sel = Hud.getSelection()
		local def = TowerDefs[sel.towerType]
		if not def then
			-- Nothing selected → no preview
			hidePreview()
			return
		end

		local gx, gy = getCellUnderMouse()
		if gx and gy then
			local isPath = Config.isPath(gx, gy)
			showPreview(gx, gy, not isPath, def.range)
		else
			hidePreview()
		end
	end)

	-- Mouse handlers: left = place, right = pickup
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not enabled or Hud.isGameOver() then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local sel = Hud.getSelection()
			if not TowerDefs[sel.towerType] then
				return -- nothing selected
			end
			local gx, gy = getCellUnderMouse()
			if gx and gy then
				if sel.fromInventoryIndex >= 0 then
					Remotes.PlaceFromInventory:FireServer(sel.fromInventoryIndex, gx, gy)
				else
					Remotes.PlaceTower:FireServer(gx, gy, sel.towerType)
				end
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			local gx, gy = getTowerUnderMouse()
			if gx and gy then
				Remotes.PickupTower:FireServer(gx, gy)
			end
		end
	end)
end

return Placement
