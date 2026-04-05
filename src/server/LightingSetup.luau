--!strict
-- src/server/LightingSetup.luau
-- Dials in atmospheric lighting + post-effects on the Lighting service so
-- emissive materials glow and the scene feels warmer. Called once at boot.

local Lighting = game:GetService("Lighting")

local LightingSetup = {}

function LightingSetup.apply()
	-- Core properties (Future tech is already declared in default.project.json)
	Lighting.Ambient = Color3.fromRGB(60, 55, 45)
	Lighting.OutdoorAmbient = Color3.fromRGB(110, 100, 85)
	Lighting.Brightness = 2.2
	Lighting.ClockTime = 14.5
	Lighting.ExposureCompensation = 0.15
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.5
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.4

	-- --- Atmosphere: slight haze with warm tint ---
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	atmosphere.Density = 0.32
	atmosphere.Offset = 0.1
	atmosphere.Color = Color3.fromRGB(199, 170, 130)
	atmosphere.Decay = Color3.fromRGB(106, 112, 125)
	atmosphere.Glare = 0.6
	atmosphere.Haze = 1.6

	-- --- Bloom: makes emissive materials glow (wizard orbs, storm orbs,
	-- cauldron brew, inferno flames, muzzle flashes later) ---
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if not bloom then
		bloom = Instance.new("BloomEffect")
		bloom.Parent = Lighting
	end
	bloom.Intensity = 0.55
	bloom.Size = 28
	bloom.Threshold = 0.95

	-- --- Sun rays ---
	local sunRays = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if not sunRays then
		sunRays = Instance.new("SunRaysEffect")
		sunRays.Parent = Lighting
	end
	sunRays.Intensity = 0.18
	sunRays.Spread = 1

	-- --- Subtle color correction for a warmer image ---
	local colorCorrection = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if not colorCorrection then
		colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Parent = Lighting
	end
	colorCorrection.Saturation = 0.12
	colorCorrection.Contrast = 0.08
	colorCorrection.TintColor = Color3.fromRGB(255, 240, 220)
end

return LightingSetup
