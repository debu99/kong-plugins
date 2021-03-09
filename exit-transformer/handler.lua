local inspect = require "inspect"

local utils = require "kong.tools.utils"
local runloop_handler = require "kong.runloop.handler"
local workspaces = require "kong.workspaces"

local BasePlugin = require "kong.plugins.base_plugin"

local PLUGIN_NAME    = require("kong.plugins.exit-transformer").PLUGIN_NAME
local PLUGIN_VERSION = require("kong.plugins.exit-transformer").PLUGIN_VERSION


local function request_id()
  local ok, res = pcall(function() return ngx.var.set_request_id end)
  if ok then
    return res
  end

  return utils.uuid()
end


local function get_conf()
  -- Gets plugin configuration for the ctx, no matter the priority
  local workspace = workspaces.get_workspace()
  -- Not really needed, but a hack because get_workspace might return an
  -- empty {} to signal... something? AFAIK, this is fixed on 2.0 already,
  -- this solution makes it so it won't work on neither version of kong.
  local workspace_id = workspace and workspace.id

  local plugins_iterator = runloop_handler.get_plugins_iterator()

  for plugin, plugin_conf in plugins_iterator:iterate("access", ngx.ctx) do

    if plugin.name ~= PLUGIN_NAME then
      goto continue
    end

    -- it's very important that this filtering happens here and not once we
    -- already have a config. Since plugin confs applying globally on
    -- different workspaces would collide here and rely only on the first
    -- match
    if not workspace_id and not plugin_conf.handle_unknown then
      goto continue
    end

    if ngx.ctx.KONG_UNEXPECTED and not plugin_conf.handle_unexpected then
      goto continue
    end

    if not ngx.ctx.is_proxy_request and not plugin_conf.handle_admin then
      goto continue
    end

    do
      return plugin_conf
    end

    ::continue::
  end

  return nil
end


local transform_function_cache = setmetatable({}, { __mode = "k" })
local function get_transform_functions(config)
  local functions = transform_function_cache[config]
  -- transform functions have the following available to them
  local helper_ctx = {
    type = type,
    print = print,
    pairs = pairs,
    ipairs = ipairs,
    inspect = inspect,
    request_id = request_id,
  }

  if not functions then
    -- first call, go compile the functions
    functions = {}
    for _, fn_str in ipairs(config.functions) do
      local fn = loadstring(fn_str)     -- load
      -- Set function context
      local fn_ctx = {}
      setmetatable(fn_ctx, { __index = helper_ctx })
      setfenv(fn, fn_ctx)
      local _, actual_fn = pcall(fn)
      table.insert(functions, actual_fn)
    end

    transform_function_cache[config] = functions
  end

  return ipairs(functions)
end

local _M = BasePlugin:extend()

_M.PRIORITY = 9999
_M.VERSION = PLUGIN_VERSION

function _M:new()
  _M.super.new(self, PLUGIN_NAME)
end

function _M:init_worker()
  kong.response.register_hook("exit", self.exit, self)
end


function _M:access(conf)
  _M.super.access(self)
end


function _M:exit(status, body, headers)
  -- Try to get plugin configuration for current context
  local conf = get_conf()
  if not conf then
    return status, body, headers
  end

  -- Reduce on status, body, headers through transform functions
  for _, fn in get_transform_functions(conf) do
    status, body, headers = fn(status, body, headers)
  end

  return status, body, headers
end

return _M
