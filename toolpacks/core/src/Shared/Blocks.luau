--[[
	Conventions shared between the block tools. Blocks created by Place Block
	are tagged with an attribute so other tools can recognise them.
]]

local Blocks = {}

Blocks.ATTRIBUTE = "StudioToolsBlock"

Blocks.MATERIALS = {
	"SmoothPlastic",
	"Plastic",
	"Wood",
	"WoodPlanks",
	"Brick",
	"Concrete",
	"Slate",
	"Metal",
	"Grass",
	"Neon",
	"Glass",
}

function Blocks.isBlock(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("BasePart") and instance:GetAttribute(Blocks.ATTRIBUTE) == true
end

-- Snaps a block center so that blocks of `size` tile a grid whose cells start at the origin.
function Blocks.snapCenter(position: Vector3, size: number): Vector3
	local function snap(v: number): number
		return (math.floor(v / size) + 0.5) * size
	end
	return Vector3.new(snap(position.X), snap(position.Y), snap(position.Z))
end

function Blocks.create(size: number, cframe: CFrame, color: Color3, material: string): Part
	local part = Instance.new("Part")
	part.Name = "Block"
	part.Anchored = true
	part.Size = Vector3.one * size
	part.CFrame = cframe
	part.Color = color
	part.Material = (Enum.Material :: any)[material] or Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute(Blocks.ATTRIBUTE, true)
	return part
end

return Blocks
