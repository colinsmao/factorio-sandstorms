
local function tint_picture(picture, tint)
  local result = {}
  for _, layer in pairs(picture.layers) do
    local l = table.deepcopy(layer)
    if l.tint ~= nil then
      l.tint = {
        r = l.tint.r * tint.r,
        g = l.tint.g * tint.g,
        b = l.tint.b * tint.b,
        a = l.tint.a * tint.a,
      }
    else
      l.tint = table.deepcopy(tint)
    end
    table.insert(result, l)
  end
  return result
end

local function create_dusty_panel_entity(panel_entity)
  local result = table.deepcopy(panel_entity)
  result.name = panel_entity.name .. "-dusty"
  result.localised_name = {"entity-name.dusty-solar-panel", panel_entity.localised_name or {"entity-name." .. panel_entity.name}}
  result.localised_description = {"entity-description.dusty-solar-panel", panel_entity.localised_name or {"entity-name." .. panel_entity.name}}
  result.pictures = tint_picture(panel_entity.picture, {r=1, g=0.667, b=0, a=1})
  result.repair_speed_modifier = (panel_entity.repair_speed_modifier or 1) * 0.25
  result.production = panel_entity.production * 0.2
  if data.raw["item"][panel_entity.name] ~= nil then
    result.placable_by = panel_entity.name  -- q picker & blueprints select the un-dusty panel
  end
  -- replace with un-dusty panel ghost on death
  result.create_ghost_on_death = false
  result.dying_trigger_effect = {
    type = "script",
    effect_id = "create-ghost-" .. panel_entity.name,
  }

  return result
end

local function create_dusty_panel_item(panel_item)
  local result = table.deepcopy(panel_item)
  result.name = panel_item.name .. "-dusty"
  result.place_result = panel_item.place_result .. "-dusty"
  result.localised_name = {"item-name.dusty-solar-panel", panel_item.localised_name or {"item-name." .. panel_item.name}}
  result.localised_description = {"item-description.dusty-solar-panel", panel_item.localised_name or {"item-name." .. panel_item.name}}
  -- TODO: result.icons = generate_barrel_icons(fluid, empty_barrel_item, barrel_side_mask, barrel_hoop_top_mask)

  return result
end

local to_add = {}
for name, panel_entity in pairs(data.raw["solar-panel"]) do
  table.insert(to_add, create_dusty_panel_entity(panel_entity))
  local panel_item = data.raw["item"][name]
  data:extend({create_dusty_panel_item(panel_item)})
end
data:extend(to_add)

-- for name, panel_item in pairs(data.raw["item"]["solar-panel"]) do
--   create_dusty_panel_item(panel_item)
-- end
