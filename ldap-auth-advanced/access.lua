local constants = require "kong.constants"
local ldap_cache = require "kong.plugins.ldap-auth-advanced.cache"
local ldap = require "kong.plugins.ldap-auth-advanced.ldap"
local ldap_groups = require "kong.plugins.ldap-auth-advanced.groups"

local clear_header = kong.service.request.clear_header

local kong = kong
local match = string.match
local lower = string.lower
local find = string.find
local sub = string.sub
local fmt = string.format
local request = ngx.req
local md5 = ngx.md5
local decode_base64 = ngx.decode_base64
local ngx_socket_tcp = ngx.socket.tcp
local ngx_set_header = ngx.req.set_header
local tostring =  tostring
local ipairs = ipairs

local AUTHORIZATION = "authorization"
local PROXY_AUTHORIZATION = "proxy-authorization"


local ldap_config_cache = setmetatable({}, { __mode = "k" })

local _M = {}

local function retrieve_credentials(authorization_header_value, conf)
  local username, password
  if authorization_header_value then
    local s, e = find(lower(authorization_header_value), "^%s*" ..
                      lower(conf.header_type) .. "%s+")
    if s == 1 then
      local cred = sub(authorization_header_value, e + 1)
      local decoded_cred = decode_base64(cred)
      username, password = match(decoded_cred, "(.+):(.+)")
    end
  end
  return username, password
end


local function ldap_authenticate(given_username, given_password, conf)
  local is_authenticated
  local groups = nil
  local err, suppressed_err, ok

  local sock = ngx_socket_tcp()
  sock:settimeout(conf.timeout)

  local opts = {}

  -- keep TLS connections in a separate pool to avoid reusing non-secure
  -- connections and vica versa, because StartTLS use the same port 
  if conf.start_tls then
    opts.pool = conf.ldap_host .. ":" .. conf.ldap_port .. ":starttls"
  end

  ok, err = sock:connect(conf.ldap_host, conf.ldap_port, opts)
  if not ok then
    kong.log.err("failed to connect to ", conf.ldap_host, ":", 
                 tostring(conf.ldap_port),": ", err)
    return nil, nil, err
  end

  if conf.ldaps or conf.start_tls then
    -- convert connection to a StarTLS connection only if it is a new connection
    if conf.start_tls and sock:getreusedtimes() == 0 then
      local success, err = ldap.start_tls(sock)
      if not success then
        return false, nil, err
      end
    end

    local _, err = sock:sslhandshake(true, conf.ldap_host, conf.verify_ldap_host)
    if err ~= nil then
      return false, nil, fmt("failed to do SSL handshake with %s:%s: %s",
                             conf.ldap_host, tostring(conf.ldap_port), err)
    end
  end

  if conf.bind_dn then
    is_authenticated = false
    kong.log.debug("binding with ", conf.bind_dn, " and conf.ldap_password")
    ok, err = ldap.bind_request(sock, conf.bind_dn, conf.ldap_password)

    if err then
      kong.log.err("Error during bind request. ", err)
      return kong.response.exit(500, { message = "An unexpected error occurred" })
    end

    if ok then
      kong.log.debug("ldap bind successful, performing search request with base_dn:", 
        conf.base_dn, ", scope='sub', and filter=", conf.attribute .. "=" .. given_username)

      local search_results, err = ldap.search_request(sock, {
        base = conf.base_dn;
        scope = "sub";
        filter = conf.attribute .. "=" .. given_username,
      })

      if err then
        kong.log.err("failed ldap search for "..
                     conf.attribute .. "=" .. given_username .. " base_dn=" ..
                     conf.base_dn)
        return kong.response.exit(500, { message = "An unexpected error occurred" })
      end

      local user_dn
      for dn, result in pairs(search_results) do
        if user_dn then
          kong.log.err("more than one user found in ldap_search with" ..
                       " attribute = " .. conf.attribute ..
                       " and given_username=" .. given_username)
          return kong.response.exit(500)
        end
        
        local raw_groups = result[conf.group_member_attribute]
        if raw_groups and #raw_groups then
          local group_dn = conf.group_base_dn or conf.base_dn
          local group_attr = conf.group_name_attribute or conf.attribute
          
          groups = ldap_groups.validate_groups(raw_groups, group_dn, group_attr)
          ldap_groups.set_groups(groups)

          if groups == nil then
            kong.log.debug("user has groups, but they are invalid. " ..
                   "group must include group_base_dn with group_name_attribute")
          end
        else
          clear_header(constants.HEADERS.AUTHENTICATED_GROUPS)
        end

        user_dn = dn
      end
      
      if not user_dn then
        return false, nil, "User not found"
      end

      is_authenticated, err = ldap.bind_request(sock, user_dn, given_password)

      if err then
        kong.log.err("bind request failed for user " .. given_username)
        return false, nil, err
      end
    end
  else
    kong.log.debug("bind_dn failed to bind with given ldap_password," .. 
      "attempting to bind with username and base_dn:", 
      conf.attribute .. "=" .. given_username .. "," .. conf.base_dn)
    local who = conf.attribute .. "=" .. given_username .. "," .. conf.base_dn
    is_authenticated, err = ldap.bind_request(sock, who, given_password)
  end

  ok, suppressed_err = sock:setkeepalive(conf.keepalive)
  if not ok then
    kong.log.err("failed to keepalive to ", conf.ldap_host, ":",
                 tostring(conf.ldap_port), ": ", suppressed_err)
  end
  return is_authenticated, groups, err
end

local function load_credential(given_username, given_password, conf)
  local ok, groups, err = ldap_authenticate(given_username, given_password, conf)
  if err ~= nil then
    kong.log.err(err)
  end

  if ok == nil then
    return nil
  end
  if ok == false then
    return false
  end
  return {username = given_username, password = given_password, groups = groups}
end


local function cache_key(conf, username, password)
  if not ldap_config_cache[conf] then
    ldap_config_cache[conf] = md5(fmt("%s:%u:%s:%s:%u",
      lower(conf.ldap_host),
      conf.ldap_port,
      conf.base_dn,
      conf.attribute,
      conf.cache_ttl
    ))
  end

  return fmt("ldap_auth_cache:%s:%s:%s", ldap_config_cache[conf],
             username, password)
end


local function authenticate(conf, given_credentials)
  local given_username, given_password = retrieve_credentials(given_credentials,
                                                              conf)
  if given_username == nil then
    return false
  end

  local credential, err = kong.cache:get(cache_key(conf, given_username, given_password), {
    ttl = conf.cache_ttl,
    neg_ttl = conf.cache_ttl
  }, load_credential, given_username, given_password, conf)
  if err or credential == nil then
    return kong.response.exit(500, err)
  end

  return credential and credential.password == given_password, credential
end


-- in case of auth plugins concatenation, remove remnants of anonymous
local function remove_headers(consumer)
  ngx.ctx.authenticated_consumer = nil
  ngx_set_header(constants.HEADERS.ANONYMOUS, nil)

  if not consumer then
    ngx_set_header(constants.HEADERS.CONSUMER_ID, nil)
    ngx_set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, nil)
    ngx_set_header(constants.HEADERS.CONSUMER_USERNAME, nil)
  end
end


local function set_consumer(consumer, credential, anonymous)
  if credential then
    ngx_set_header(constants.HEADERS.CREDENTIAL_USERNAME, credential.username)
    ngx.ctx.authenticated_credential = credential
  end

  if consumer and not anonymous then
    ngx_set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
    ngx_set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
    ngx_set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
    remove_headers(consumer)

    ngx.ctx.authenticated_consumer = consumer
    return
  end

  if consumer and anonymous then
    ngx_set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
    ngx_set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
    ngx_set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
    ngx_set_header(constants.HEADERS.ANONYMOUS, true)
    ngx.ctx.authenticated_consumer = consumer
    return
  end

  remove_headers()
end


local function find_consumer(consumer_field, value)
  local result, err
  local dao = kong.db.consumers

  if consumer_field == "id" then
    result, err = dao:select({ id = value })
  else 
     result, err = dao["select_by_" .. consumer_field](dao, value)
  end

  if err then
    kong.log.debug("failed to load consumer", err)
    return
  end

  return result
end


local function load_consumers(value, consumer_by, ttl)
  local err
  
  if not value then
    return nil, "cannot load consumers with empty value"
  end

  for _, field_name in ipairs(consumer_by) do
    local key
    local consumer

    if field_name == "id" then
      key = kong.db.consumers:cache_key(value)
    else
      key = ldap_cache.consumer_field_cache_key(field_name, value)
    end

    consumer, err = kong.cache:get(key, ttl, find_consumer, field_name, value)

    if consumer then
      return consumer
    end
  end

  return nil, err
end


local function do_authentication(conf)
  local headers = request.get_headers()
  local authorization_value = headers[AUTHORIZATION]
  local proxy_authorization_value = headers[PROXY_AUTHORIZATION]
  local anonymous = conf.anonymous
  local consumer, err
  local ttl = conf.ttl

  -- If both headers are missing, check anonymous
  if not (authorization_value or proxy_authorization_value) then
    ngx.header["WWW-Authenticate"] = 'LDAP realm="kong"'
    consumer, err = load_consumers(anonymous, { 'id' }, ttl)

    if err then
      kong.log.err('error fetching anonymous user with conf.anonymous="' .. 
                   (anonymous or '') .. '"', err)
      return false, { status = 500, message = "An unexpected error occurred" }
    end

    if consumer then
      set_consumer(consumer, nil, anonymous)
      return true
    end

    -- anonymous is configured but doesn't exist
    if anonymous ~= "" and not consumer then
      kong.log.err('anonymous user not found with conf.anonymous="' .. 
                   (anonymous or '') .. '"', err)
      return false, { status = 500, message = "An unexpected error occurred" }
    end

    return false, { status = 401, message = "Unauthorized" }
  end

  local is_authorized, credential = authenticate(conf, proxy_authorization_value)
  if not is_authorized then
    is_authorized, credential = authenticate(conf, authorization_value)
  end

  if not is_authorized then
    consumer, err = load_consumers(anonymous, { 'id' }, ttl)
    if consumer then
      set_consumer(consumer, credential, anonymous)
      return true
    end

    if err then
      return false, { status = 500 }
    end

    return false, {status = 403, message = "Invalid authentication credentials"}
  end

  if conf.hide_credentials then
    request.clear_header(AUTHORIZATION)
    request.clear_header(PROXY_AUTHORIZATION)
  end

  if not conf.consumer_optional then
    kong.log.debug('consumer mapping is not optional, looking for consumer.')
    consumer, err = load_consumers(credential.username, conf.consumer_by, ttl)

    if not consumer then
      kong.log.debug("consumer not found, checking anonymous")
      if err then
        return false, { status = 403, "kong consumer was not found (" .. err .. ")" }
      end

      consumer, err = load_consumers(anonymous, { 'id' }, ttl)

      if err then
        return false, { status = 403, "kong consumer was not found (" .. err .. ")" }
      end

    else
      -- we found a consumer to map, so no need to fallback to anonymous
      kong.log.debug("consumer found, id:", consumer.id)
      anonymous = nil
    end
  end
  
  ldap_groups.set_groups(credential.groups)
  set_consumer(consumer, credential, anonymous)

  return true
end


function _M.execute(conf)
  if ngx.ctx.authenticated_credential and conf.anonymous ~= "" then
    -- we're already authenticated, and we're configured for using anonymous,
    -- hence we're in a logical OR between auth methods and we're already done.
    kong.log.debug("credential found, using anonymous consumer:", conf.anonymous)
    return
  end

  local ok, err = do_authentication(conf)
  if not ok then
    return kong.response.exit(err.status, { message = err.message })
  end
end


return _M
