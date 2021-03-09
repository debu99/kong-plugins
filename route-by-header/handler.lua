local hostname_type   = require "kong.tools.utils".hostname_type
local req_get_headers = ngx.req.get_headers

local pairs  = pairs
local ipairs = ipairs
local lower = string.lower


local BasePlugin = require "kong.plugins.base_plugin"


local RouteByHeaderHandler = BasePlugin:extend()


local conf_cache = setmetatable({}, {__mod = "k"})


function RouteByHeaderHandler:new()
  RouteByHeaderHandler.super:new(self, "route-by-header")
end


local function update_balancer_address(target, type)
  local ba = ngx.ctx.balancer_address
  ba.host = target
  ba.type = type
end


local function is_condition_true(headers_match_criteria, headers)
  local header_set = false

  for name, value in pairs(headers_match_criteria) do
    local header_value_t = headers[lower(name)]
    if header_value_t ~= value then
      return false
    end
    header_set = true
  end

  return header_set
end


local function apply_rules(conf)
  local headers = req_get_headers()
  for _, rules_map in ipairs(conf.rules) do
    if is_condition_true(rules_map.condition, headers) then
      update_balancer_address(rules_map.upstream_name, rules_map.upstream_type)

      -- return after 1st match
      return
    end
  end
end


function RouteByHeaderHandler:access(conf)
  RouteByHeaderHandler.super.access(self)
  local config = conf_cache[conf]
  if not config then
    for _, rule in ipairs(conf.rules) do
      rule.upstream_type = hostname_type(rule.upstream_name)
    end
    config = conf
    conf_cache[conf] = conf
  end
  apply_rules(config)
end


RouteByHeaderHandler.priority = 2000
RouteByHeaderHandler.version  = "0.1.0"


return RouteByHeaderHandler

