local kong = kong
local null = ngx.null

local ipairs = ipairs


local _M = {}


local SNI_CACHE_KEY = "mtls-auth:cert_enabled_snis"


function _M.consumer_field_cache_key(key, value)
  return kong.db.consumers:cache_key(key, value, "consumers")
end

local function invalidate_sni_cache()
  kong.cache:invalidate(SNI_CACHE_KEY)
end


function _M.init_worker()
  if not kong.worker_events or not kong.worker_events.register then
    return
  end

  local register = kong.worker_events.register
  for _, v in ipairs({"services", "routes", "plugins"}) do
    register(invalidate_sni_cache, "crud", v)
  end

  register(
    function(data)
      local cache_key = _M.consumer_field_cache_key

      local old_entity = data.old_entity
      if old_entity then
        if old_entity.custom_id and old_entity.custom_id ~= null and old_entity.custom_id ~= "" then
          kong.cache:invalidate(cache_key("custom_id", old_entity.custom_id))
        end

        if old_entity.username and old_entity.username ~= null and old_entity.username ~= "" then
          kong.cache:invalidate(cache_key("username", old_entity.username))
        end
      end

      local entity = data.entity
      if entity then
        if entity.custom_id and entity.custom_id ~= null and entity.custom_id ~= "" then
          kong.cache:invalidate(cache_key("custom_id", entity.custom_id))
        end

        if entity.username and entity.username ~= null and entity.username ~= "" then
          kong.cache:invalidate(cache_key("username", entity.username))
        end
      end
    end, "crud", "consumers")
end


return _M
