local OICHandler = {
  PRIORITY = 1000,
  VERSION  = "1.4.2",
}


local cache           = require "kong.plugins.openid-connect.cache"
local arguments       = require "kong.plugins.openid-connect.arguments"
local log             = require "kong.plugins.openid-connect.log"
local openid          = require "kong.openid-connect"
local uri             = require "kong.openid-connect.uri"
local set             = require "kong.openid-connect.set"
local hash            = require "kong.openid-connect.hash"
local codec           = require "kong.openid-connect.codec"
local constants       = require "kong.constants"
local session_factory = require "resty.session"


local kong            = kong
local ngx             = ngx
local redirect        = ngx.redirect
local var             = ngx.var
local time            = ngx.time
local null            = ngx.null
local header          = ngx.header
local set_header      = ngx.req.set_header
local clear_header    = ngx.req.clear_header
local escape_uri      = ngx.escape_uri
local encode_base64   = ngx.encode_base64
local tonumber        = tonumber
local tostring        = tostring
local ipairs          = ipairs
local concat          = table.concat
local lower           = string.lower
local gsub            = string.gsub
local find            = string.find
local type            = type
local sub             = string.sub
local json            = codec.json
local base64url       = codec.base64url


local PRIVATE_KEY_JWKS = {}


local PARAM_TYPES_ALL = {
  "header",
  "query",
  "body",
}


local function hide_cookie(name)
  local cookies = var.http_cookie
  if not cookies then
    return
  end

  local results = {}
  local i = 1
  local j = 0
  local sc_pos = find(cookies, ";", 1, true)
  while sc_pos do
    local cookie = sub(cookies, i, sc_pos - 1)
    local eq_pos = find(cookie, "=", 1, true)
    if eq_pos then
      local cookie_name = gsub(sub(cookie, 1, eq_pos - 1), "^%s+", "")
      if cookie_name ~= name and cookie_name ~= "" then
        j = j + 1
        results[j] = cookie
      end
    end
    i = sc_pos + 1
    sc_pos = find(cookies, ";", i, true)
  end

  local cookie = sub(cookies, i)
  if cookie and cookie ~= "" then
    local eq_pos = find(cookie, "=", 1, true)
    if eq_pos then
      local cookie_name = gsub(sub(cookie, 1, eq_pos - 1), "^%s+", "")
      if cookie_name ~= name and cookie_name ~= "" then
        j = j + 1
        results[j] = cookie
      end
    end
  end

  if j == 0 then
    clear_header("Cookie")
  else
    set_header("Cookie", concat(results, "; ", 1, j))
  end
end


local function unexpected(trusted_client, ...)
  log.err(...)

  if trusted_client.unexpected_redirect_uri then
    return redirect(trusted_client.unexpected_redirect_uri)
  end

  local message = "An unexpected error occurred"
  if trusted_client.display_errors then
    local err = concat({...}, " ")
    if err ~= "" then
      message = message .. " (" .. err .. ")"
    end
  end

  return kong.response.exit(500, { message = message })
end


local function create_session_open(args, secret)
  local strategy = args.get_conf_arg("session_strategy", "default")
  local storage  = args.get_conf_arg("session_storage", "cookie")

  local redis, memcache

  if storage == "memcache" then
    log("loading configuration for memcache session storage")
    memcache = {
      uselocking = false,
      prefix     = args.get_conf_arg("session_memcache_prefix", "sessions"),
      socket     = args.get_conf_arg("session_memcache_socket"),
      host       = args.get_conf_arg("session_memcache_host", "127.0.0.1"),
      port       = args.get_conf_arg("session_memcache_port", 11211),
    }

  elseif storage == "redis" then
    log("loading configuration for redis session storage")
    redis = {
      uselocking = false,
      prefix     = args.get_conf_arg("session_redis_prefix", "sessions"),
      socket     = args.get_conf_arg("session_redis_socket"),
      host       = args.get_conf_arg("session_redis_host", "127.0.0.1"),
      port       = args.get_conf_arg("session_redis_port", 6379),
      auth       = args.get_conf_arg("session_redis_auth"),
    }
  end

  return function(options)
    options.strategy = strategy
    options.storage  = storage
    options.memcache = memcache
    options.redis    = redis
    options.secret   = secret

    log("trying to open session using cookie named '", options.name, "'")
    return session_factory.open(options)
  end
end


local function create_get_http_opts(args)
  return function(options)
    options = options or {}
    options.http_version              = args.get_conf_arg("http_version", 1.1)
    options.http_proxy                = args.get_conf_arg("http_proxy")
    options.http_proxy_authorization  = args.get_conf_arg("http_proxy_authorization")
    options.https_proxy               = args.get_conf_arg("https_proxy")
    options.https_proxy_authorization = args.get_conf_arg("https_proxy_authorization")
    options.no_proxy                  = args.get_conf_arg("no_proxy")
    options.keepalive                 = args.get_conf_arg("keepalive", true)
    options.ssl_verify                = args.get_conf_arg("ssl_verify", true)
    options.timeout                   = args.get_conf_arg("timeout", 10000)
    return options
  end
end


local function create_introspect_token(args, oic)
  local endpoint    = args.get_conf_arg("introspection_endpoint")
  local auth_method = args.get_conf_arg("introspection_endpoint_auth_method")
  local hint        = args.get_conf_arg("introspection_hint", "access_token")
  local use_cache   = args.get_conf_arg("cache_introspection")
  local headers     = args.get_conf_args("introspection_headers_names", "introspection_headers_values")

  return function(access_token, ttl)
    local pargs       = args.get_conf_args("introspection_post_args_names", "introspection_post_args_values")
    local client_args = args.get_conf_arg("introspection_post_args_client")
    if client_args then
      for _, client_arg_name in ipairs(client_args) do
        local extra_arg = args.get_uri_arg(client_arg_name)
        if extra_arg then
          if type(pargs) ~= "table" then
            pargs = {}
          end

          pargs[client_arg_name] = extra_arg

        else
          extra_arg = args.get_post_arg(client_arg_name)
          if extra_arg then
            if type(pargs) ~= "table" then
              pargs = {}
            end

            pargs[client_arg_name] = extra_arg
          end
        end
      end
    end

    local opts = {
      introspection_endpoint             = endpoint,
      introspection_endpoint_auth_method = auth_method,
      headers                            = headers,
      args                               = pargs,
    }

    if use_cache then
      log("introspecting token with caching enabled")
      return cache.introspection.load(oic, access_token, hint, ttl, true, opts)
    end

    log("introspecting token")
    return cache.introspection.load(oic, access_token, hint, ttl, false, opts)
  end
end


local function redirect_uri(args)
  -- we try to use current url as a redirect_uri by default
  -- if none is configured.
  local scheme
  local host
  local port

  if kong.ip.is_trusted(var.realip_remote_addr or var.remote_addr) then
    scheme = args.get_header("X-Forwarded-Proto")
    if not scheme then
      scheme = var.scheme
      if type(scheme) == "table" then
        scheme = scheme[1]
      end
    end

    scheme = lower(scheme)

    host = args.get_header("X-Forwarded-Host")
    if host then
      local s = find(host, "@", 1, true)
      if s then
        host = sub(host, s + 1)
      end

      s = find(host, ":", 1, true)
      host = s and lower(sub(host, 1, s - 1)) or lower(host)

    else
      host = var.host
      if type(host) == "table" then
        host = host[1]
      end
    end

    port = args.get_header("X-Forwarded-Port")
    if port then
      port = tonumber(port)
      if not port or port < 1 or port > 65535 then
        local h = args.get_header("X-Forwarded-Host")
        if h then
          local s = find(h, "@", 1, true)
          if s then
            h = sub(h, s + 1)
          end

          s = find(h, ":", 1, true)
          if s then
            port = tonumber(sub(h, s + 1))
          end
        end
      end
    end

    if not port or port < 1 or port > 65535 then
      port = var.server_port
      if type(port) == "table" then
        port = port[1]
      end

      port = tonumber(port)
    end

  else
    scheme = var.scheme
    if type(scheme) == "table" then
      scheme = scheme[1]
    end

    host = var.host
    if type(host) == "table" then
      host = host[1]
    end

    port = var.server_port
    if type(port) == "table" then
      port = port[1]
    end

    port = tonumber(port)
  end

  local u = var.request_uri
  if type(u) == "table" then
    u = u[1]
  end

  do
    local s = find(u, "?", 2, true)
    if s then
      u = sub(u, 1, s - 1)
    end
  end

  local url = { scheme, "://", host }

  if port == 80 and scheme == "http" then
    url[4] = u

  elseif port == 443 and scheme == "https" then
    url[4] = u

  else
    url[4] = ":"
    url[5] = port
    url[6] = u
  end

  return concat(url)
end


local function find_claim(token, search)
  if type(token) ~= "table" then
    return nil
  end

  local search_t = type(search)
  local t = token
  if search_t == "string" then
    if not t[search] then
      return nil
    end
    t = t[search]

  elseif search_t == "table" then
    for _, claim in ipairs(search) do
      if not t[claim] then
        return nil
      end

      t = t[claim]
    end

  else
    return nil
  end

  if type(t) == "table" then
    return concat(t, " ")
  end

  return tostring(t)
end


local function find_consumer(token, claim, anonymous, consumer_by, ttl)
  if not token then
    return nil, "token for consumer mapping was not found"
  end

  if type(token) ~= "table" then
    return nil, "opaque token cannot be used for consumer mapping"
  end

  local payload = token.payload

  if not payload then
    return nil, "token payload was not found for consumer mapping"
  end

  if type(payload) ~= "table" then
    return nil, "invalid token payload was specified for consumer mapping"
  end

  local subject = find_claim(payload, claim)
  if not subject then
    if type(claim) == "table" then
      return nil, "claim (" .. concat(claim, ",") .. ") was not found for consumer mapping"
    end

    return nil, "claim (" .. tostring(claim) .. ") was not found for consumer mapping"
  end

  return cache.consumers.load(subject, anonymous, consumer_by, ttl)
end


local function set_consumer(ctx, consumer, credential)
  local head = constants.HEADERS

  if consumer then
    log("setting kong consumer context and headers")

    ctx.authenticated_consumer = consumer

    if credential and credential ~= null then
      ctx.authenticated_credential = credential

    else
      set_header(head.ANONYMOUS, nil)

      if consumer.id and consumer.id ~= null then
        ctx.authenticated_credential = {
          consumer_id = consumer.id
        }
      else
        ctx.authenticated_credential = nil
      end
    end

    if consumer.id and consumer.id ~= null then
      set_header(head.CONSUMER_ID, consumer.id)
    else
      set_header(head.CONSUMER_ID, nil)
    end

    if consumer.custom_id and consumer.custom_id ~= null then
      set_header(head.CONSUMER_CUSTOM_ID, consumer.custom_id)
    else
      set_header(head.CONSUMER_CUSTOM_ID, nil)
    end

    if consumer.username and consumer.username ~= null then
      set_header(head.CONSUMER_USERNAME, consumer.username)
    else
      set_header(head.CONSUMER_USERNAME, nil)
    end

  elseif not ctx.authenticated_credential then
    log("removing possible remnants of anonymous")

    ctx.authenticated_consumer   = nil
    ctx.authenticated_credential = nil

    set_header(head.CONSUMER_ID,        nil)
    set_header(head.CONSUMER_CUSTOM_ID, nil)
    set_header(head.CONSUMER_USERNAME,  nil)

    set_header(head.ANONYMOUS,          nil)
  end
end


local function find_trusted_client_by_arg(arg, clients)
  if not arg then
    return nil
  end

  local client_index = tonumber(arg)
  if client_index then
    if clients[client_index] then
      local client_id = clients[client_index]
      if client_id then
        return client_id, client_index
      end
    end

    return
  end

  for i, c in ipairs(clients) do
    if arg == c then
      return clients[i], i
    end
  end
end


local function find_trusted_client(args)
  -- load client configuration
  local clients        = args.get_conf_arg("client_id",      {})
  local secrets        = args.get_conf_arg("client_secret",  {})
  local auths          = args.get_conf_arg("client_auth",    {})
  local algs           = args.get_conf_arg("client_alg",     {})
  local jwks           = args.get_conf_arg("client_jwk",     {})
  local redirects      = args.get_conf_arg("redirect_uri",   {})
  local display_errors = args.get_conf_arg("display_errors", false)

  local login_redirect_uris        = args.get_conf_arg("login_redirect_uri",        {})
  local logout_redirect_uris       = args.get_conf_arg("logout_redirect_uri",       {})
  local forbidden_redirect_uris    = args.get_conf_arg("forbidden_redirect_uri",    {})
  local unauthorized_redirect_uris = args.get_conf_arg("unauthorized_redirect_uri", {})
  local unexpected_redirect_uris   = args.get_conf_arg("unexpected_redirect_uris",  {})

  clients.n = #clients

  local client_id
  local client_index

  if clients.n > 1 then
    local client_arg_name = args.get_conf_arg("client_arg", "client_id")
    client_id, client_index = find_trusted_client_by_arg(args.get_header(client_arg_name, "X"), clients)
    if not client_id then
      client_id, client_index = find_trusted_client_by_arg(args.get_uri_arg(client_arg_name), clients)
      if not client_id then
        client_id, client_index = find_trusted_client_by_arg(args.get_body_arg(client_arg_name), clients)
      end
    end
  end

  local client = {
    clients                    = clients,
    secrets                    = secrets,
    auths                      = auths,
    algs                       = algs,
    jwks                       = jwks,
    redirects                  = redirects,
    login_redirect_uris        = login_redirect_uris,
    logout_redirect_uris       = logout_redirect_uris,
    forbidden_redirect_uris    = forbidden_redirect_uris,
    forbidden_destroy_session  = args.get_conf_arg("forbidden_destroy_session", true),
    unauthorized_redirect_uris = unauthorized_redirect_uris,
    unexpected_redirect_uris   = unexpected_redirect_uris,
  }

  if client_id then
    client.id                        = client_id
    client.index                     = client_index
    client.secret                    = secrets[client_index]                    or secrets[1]
    client.auth                      = auths[client_index]                      or auths[1]
    client.jwk                       = jwks[client_index]                       or jwks[1]
    client.alg                       = algs[client_index]                       or algs[1]
    client.redirect_uri              = redirects[client_index]                  or redirects[1] or redirect_uri(args)
    client.login_redirect_uri        = login_redirect_uris[client_index]        or login_redirect_uris[1]
    client.logout_redirect_uri       = logout_redirect_uris[client_index]       or logout_redirect_uris[1]
    client.forbidden_redirect_uri    = forbidden_redirect_uris[client_index]    or forbidden_redirect_uris[1]
    client.unauthorized_redirect_uri = unauthorized_redirect_uris[client_index] or unauthorized_redirect_uris[1]
    client.unexpected_redirect_uri   = unexpected_redirect_uris[client_index]   or unexpected_redirect_uris[1]

  else
    client.id                        = clients[1]
    client.index                     = 1
    client.secret                    = secrets[1]
    client.auth                      = auths[1]
    client.alg                       = algs[1]
    client.jwk                       = jwks[1]
    client.redirect_uri              = redirects[1] or redirect_uri(args)
    client.login_redirect_uri        = login_redirect_uris[1]
    client.logout_redirect_uri       = logout_redirect_uris[1]
    client.forbidden_redirect_uri    = forbidden_redirect_uris[1]
    client.unauthorized_redirect_uri = unauthorized_redirect_uris[1]
    client.unexpected_redirect_uri   = unexpected_redirect_uris[1]
  end

  if not client.jwk then
    client.jwk = PRIVATE_KEY_JWKS[client.alg] or PRIVATE_KEY_JWKS.RS256
  end

  client.display_errors = display_errors

  return client
end


local function reset_trusted_client(new_client_index, trusted_client, oic, options)
  if not new_client_index or new_client_index == trusted_client.index or trusted_client.clients.n < 2 then
    return
  end

  local new_id, new_index = find_trusted_client_by_arg(new_client_index, trusted_client.clients)
  if not new_id then
    return
  end

  trusted_client.index                     = new_index
  trusted_client.id                        = new_id
  trusted_client.secret                    = trusted_client.secrets[new_client_index] or
                                             trusted_client.secret
  trusted_client.auth                      = trusted_client.auths[new_client_index] or
                                             trusted_client.auth
  trusted_client.jwk                       = trusted_client.jwk[new_client_index] or
                                             trusted_client.jwk
  trusted_client.alg                       = trusted_client.algs[new_client_index] or
                                             trusted_client.alg
  trusted_client.redirect_uri              = trusted_client.redirects[new_client_index] or
                                             trusted_client.redirect_uri
  trusted_client.login_redirect_uri        = trusted_client.login_redirect_uris[new_client_index] or
                                             trusted_client.login_redirect_uri
  trusted_client.logout_redirect_uri       = trusted_client.logout_redirect_uris[new_client_index] or
                                             trusted_client.logout_redirect_uri
  trusted_client.forbidden_redirect_uri    = trusted_client.forbidden_redirect_uris[new_client_index] or
                                             trusted_client.forbidden_redirect_uri
  trusted_client.unauthorized_redirect_uri = trusted_client.unauthorized_redirect_uris[new_client_index] or
                                             trusted_client.unauthorized_redirect_uri
  trusted_client.unexpected_redirect_uri   = trusted_client.unexpected_redirect_uris[new_client_index] or
                                             trusted_client.unexpected_redirect_uri

  if not trusted_client.jwk then
    trusted_client.jwk = PRIVATE_KEY_JWKS[trusted_client.alg] or PRIVATE_KEY_JWKS.RS256
  end

  options.client_id     = trusted_client.id
  options.client_secret = trusted_client.secret
  options.client_auth   = trusted_client.auth
  options.client_alg    = trusted_client.alg
  options.redirect_uri  = trusted_client.redirect_uri

  oic.options:reset(options)
end


local function append_header(name, value)
  if type(value) == "table" then
    for _, val in ipairs(value) do
      append_header(name, val)
    end

  else
    local header_value = header[name]

    if header_value ~= nil then
      if type(header_value) == "table" then
        header_value[#header_value+1] = value

      else

        header_value = { header_value, value }
      end

    else
      header_value = value
    end

    header[name] = header_value
  end
end


local function set_upstream_header(header_key, header_value)
  if not header_key or not header_value or header_value == null then
    return
  end

  if header_key == "authorization:bearer" then
    set_header("Authorization", "Bearer " .. header_value)

  elseif header_key == "authorization:basic" then
    set_header("Authorization", "Basic " .. header_value)

  else
    set_header(header_key, header_value)
  end
end


local function set_downstream_header(header_key, header_value)
  if not header_key or not header_value or header_value == null then
    return
  end

  if header_key == "authorization:bearer" then
    append_header("Authorization", "Bearer " .. header_value)

  elseif header_key == "authorization:basic" then
    append_header("Authorization", "Basic " .. header_value)

  else
    append_header(header_key, header_value)
  end
end


local function get_header_value(header_value)
  if not header_value or header_value == null then
    return
  end

  local val_type = type(header_value)
  if val_type == "table" then
    header_value = json.encode(header_value)
    if header_value then
      header_value = encode_base64(header_value)
    end

  elseif val_type ~= "string" then
    return tostring(header_value)
  end

  return header_value
end


local function set_headers(args, header_key, header_value)
  if not header_key or not header_value or header_value == null then
    return
  end

  local us = "upstream_"   .. header_key
  local ds = "downstream_" .. header_key

  do
    local value

    local usm = args.get_conf_arg(us .. "_header")
    if usm then
      if type(header_value) == "function" then
        value = header_value()

      else
        value = header_value
      end

      if value and value ~= null then
        set_upstream_header(usm, get_header_value(value))
      end
    end

    local dsm = args.get_conf_arg(ds .. "_header")
    if dsm then
      if not usm then
        if type(header_value) == "function" then
          value = header_value()

        else
          value = header_value
        end
      end

      if value and value ~= null then
        set_downstream_header(dsm, get_header_value(value))
      end
    end
  end
end


local function anonymous_access(ctx, anonymous, trusted_client)
  local consumer_token = {
    payload = {
      id = anonymous
    }
  }

  local consumer, err = find_consumer(consumer_token, "id", true, "id")
  if type(consumer) ~= "table" then
    if err then
      return unexpected(trusted_client, "anonymous consumer was not found (", err, ")")

    else
      return unexpected(trusted_client, "anonymous consumer was not found")
    end
  end

  local head = constants.HEADERS

  ctx.authenticated_consumer   = consumer
  ctx.authenticated_credential = nil

  if consumer.id and consumer.id ~= null then
    set_header(head.CONSUMER_ID, consumer.id)
  else
    set_header(head.CONSUMER_ID, nil)
  end

  if consumer.custom_id and consumer.custom_id ~= null then
    set_header(head.CONSUMER_CUSTOM_ID, consumer.custom_id)
  else
    set_header(head.CONSUMER_CUSTOM_ID, nil)
  end

  if consumer.username and consumer.username ~= null then
    set_header(head.CONSUMER_USERNAME, consumer.username)
  else
    set_header(head.CONSUMER_USERNAME, nil)
  end

  set_header(head.ANONYMOUS, true)
end


local function unauthorized(ctx, issuer, msg, err, session, anonymous, trusted_client)
  if err then
    log.notice(err)
  end

  if session then
    session:destroy()
  end

  if anonymous then
    return anonymous_access(ctx, anonymous, trusted_client)
  end

  if trusted_client.unauthorized_redirect_uri then
    return redirect(trusted_client.unauthorized_redirect_uri)
  end

  if trusted_client.display_errors and err then
    msg = msg .. " (" .. err .. ")"
  end

  local parts = uri.parse(issuer)

  return kong.response.exit(401, { message = msg }, {
    ["WWW-Authenticate"] = 'Bearer realm="' .. (parts.host or "kong") .. '"'
  })
end


local function forbidden(ctx, issuer, msg, err, session, anonymous, trusted_client)
  if err then
    log.notice(err)
  end

  if session and trusted_client.forbidden_destroy_session then
    session:destroy()
  end

  if anonymous then
    return anonymous_access(ctx, anonymous, trusted_client)
  end

  if trusted_client.forbidden_redirect_uri then
    return redirect(trusted_client.forbidden_redirect_uri)
  end

  if trusted_client.display_errors and err then
    msg = msg .. " (" .. err .. ")"
  end

  local parts = uri.parse(issuer)

  return kong.response.exit(403, { message = msg }, {
    ["WWW-Authenticate"] = 'Bearer realm="' .. (parts.host or "kong") .. '"'
  })
end


local function success(response)
  if not response then
    return kong.response.exit(204)
  end

  return kong.response.exit(200, response)
end


local function get_auth_methods(get_conf_arg)
  local auth_methods = get_conf_arg("auth_methods", {
    "password",
    "client_credentials",
    "authorization_code",
    "bearer",
    "introspection",
    "kong_oauth2",
    "refresh_token",
    "session",
  })

  local ret = {}
  for _, auth_method in ipairs(auth_methods) do
    ret[auth_method] = true
  end
  return ret
end


local function decode_basic_auth(basic_auth)
  if not basic_auth then
    return nil
  end

  local s = find(basic_auth, ":", 2, true)
  if s then
    local username = sub(basic_auth, 1, s - 1)
    local password = sub(basic_auth, s + 1)
    return username, password
  end
end


local function get_credentials(args, credential_type, usr_arg, pwd_arg)
  local password_param_type = args.get_conf_arg(credential_type .. "_param_type", PARAM_TYPES_ALL)

  for _, location in ipairs(password_param_type) do
    if location == "header" then
      local grant_type = args.get_header("Grant-Type", "X")
      if not grant_type or grant_type == credential_type then
        local username, password = decode_basic_auth(args.get_header("authorization:basic"))
        if username and password then
          return username, password, "header"
        end
      end

    elseif location == "query" then
      local grant_type = args.get_uri_arg("grant_type")
      if not grant_type or grant_type == credential_type then
        local username = args.get_uri_arg(usr_arg)
        local password = args.get_uri_arg(pwd_arg)
        if username and password then
          return username, password, "query"
        end
      end

    elseif location == "body" then
      local grant_type = args.get_body_arg("grant_type")
      if not grant_type or grant_type == credential_type then
        local username, loc = args.get_body_arg(usr_arg)
        local password = args.get_body_arg(pwd_arg)
        if username and password then
          return username, password, loc
        end
      end
    end
  end
end


local function replay_downstream_headers(args, headers, auth_method)
  if headers and auth_method then
    local replay_for = args.get_conf_arg("token_headers_grants")
    if not replay_for then
      return
    end
    log("replaying token endpoint request headers")
    local replay_prefix = args.get_conf_arg("token_headers_prefix")
    for _, v in ipairs(replay_for) do
      if v == auth_method then
        local replay_headers = args.get_conf_arg("token_headers_replay")
        if replay_headers then
          for _, replay_header in ipairs(replay_headers) do
            local extra_header = headers[replay_header]
            if extra_header then
              if replay_prefix then
                append_header(replay_prefix .. replay_header, extra_header)

              else
                append_header(replay_header, extra_header)
              end
            end
          end
        end
        return
      end
    end
  end
end


local function get_exp(access_token, tokens_encoded, now, exp_default)
  if access_token and type(access_token) == "table" then
    local exp

    if type(access_token.payload) == "table" then
      if access_token.payload.exp then
        exp = tonumber(access_token.payload.exp)
        if exp then
          return exp
        end
      end
    end

    exp = tonumber(access_token.exp)
    if exp then
      return exp
    end
  end

  if tokens_encoded and type(tokens_encoded) == "table" then
    if tokens_encoded.expires_in then
      local expires_in = tonumber(tokens_encoded.expires_in)
      if expires_in then
        if expires_in == 0 then
          return 0
        end

        return now + expires_in
      end
    end
  end

  return exp_default
end


local function no_cache_headers()
  header["Cache-Control"] = "no-cache, no-store"
  header["Pragma"]        = "no-cache"
end


local function rediscover_keys(issuer, options)
  return function()
    return cache.issuers.rediscover(issuer, options)
  end
end


function OICHandler.init_worker()
  local keys, err = kong.db.oic_jwks:get()
  if not keys then
    log.err(err)

  else
    for _, jwk in ipairs(keys.jwks.keys) do
      if jwk.alg ~= "HS256" and jwk.alg ~= "HS384" and jwk.alg ~= "HS512" then
        PRIVATE_KEY_JWKS[jwk.alg] = jwk
      end
    end
  end

  cache.init_worker()
end


function OICHandler.access(_, conf)
  local ctx = ngx.ctx
  local args = arguments(conf)
  args.get_http_opts = create_get_http_opts(args)

  -- check if preflight request and whether it should be authenticated
  if not args.get_conf_arg("run_on_preflight", true) and var.request_method == "OPTIONS" then
    return
  end

  local trusted_client = find_trusted_client(args)

  local unauthorized_error_message = args.get_conf_arg("unauthorized_error_message", "Unauthorized")
  local forbidden_error_message = args.get_conf_arg("forbidden_error_message", "Forbidden")

  local anonymous = args.get_conf_arg("anonymous")
  if anonymous and ctx.authenticated_credential then
    -- we're already authenticated, and we're configured for using anonymous,
    -- hence we're in a logical OR between auth methods and we're already done.
    log("skipping because user is already authenticated")
    return
  end

  -- common variables
  local ok, err

  -- load discovery information
  log("loading discovery information")
  local oic, iss, secret, options
  do
    local issuer
    local issuer_uri = args.get_conf_arg("issuer")

    local discovery_options = args.get_http_opts {
      headers               = args.get_conf_args("discovery_headers_names", "discovery_headers_values"),
      rediscovery_lifetime  = args.get_conf_arg("rediscovery_lifetime", 300),
      extra_jwks_uris       = args.get_conf_arg("extra_jwks_uris"),
    }

    issuer, err = cache.issuers.load(issuer_uri, discovery_options)
    if type(issuer) ~= "table" then
      return unexpected(trusted_client, err or "discovery information could not be loaded")
    end

    options = {
      client_id                 = trusted_client.id,
      client_secret             = trusted_client.secret,
      client_auth               = trusted_client.auth,
      client_alg                = trusted_client.alg,
      client_jwk                = trusted_client.jwk,
      redirect_uri              = trusted_client.redirect_uri,
      scope                     = args.get_conf_arg("scopes", {}),
      response_mode             = args.get_conf_arg("response_mode"),
      response_type             = args.get_conf_arg("response_type"),
      audience                  = args.get_conf_arg("audience"),
      domains                   = args.get_conf_arg("domains"),
      max_age                   = args.get_conf_arg("max_age"),
      timeout                   = args.get_conf_arg("timeout", 10000),
      leeway                    = args.get_conf_arg("leeway", 0),
      http_version              = args.get_conf_arg("http_version", 1.1),
      http_proxy                = args.get_conf_arg("http_proxy"),
      http_proxy_authorization  = args.get_conf_arg("http_proxy_authorization"),
      https_proxy               = args.get_conf_arg("https_proxy"),
      https_proxy_authorization = args.get_conf_arg("http_proxy_authorization"),
      authorization_endpoint    = args.get_conf_arg("authorization_endpoint"),
      token_endpoint            = args.get_conf_arg("token_endpoint"),
      no_proxy                  = args.get_conf_arg("no_proxy"),
      keepalive                 = args.get_conf_arg("keepalive", true),
      ssl_verify                = args.get_conf_arg("ssl_verify", true),
      verify_parameters         = args.get_conf_arg("verify_parameters"),
      verify_nonce              = args.get_conf_arg("verify_nonce"),
      verify_signature          = args.get_conf_arg("verify_signature"),
      verify_claims             = args.get_conf_arg("verify_claims"),
      rediscover_keys           = rediscover_keys(issuer_uri, discovery_options),
    }

    log("initializing library")
    oic, err = openid.new(options, issuer.configuration, issuer.keys)
    if type(oic) ~= "table" then
      return unexpected(trusted_client, err or "unable to initialize library")
    end

    iss = oic.configuration.issuer
    if not iss then
      iss = issuer_uri
      if iss then
        if sub(iss, -33) == "/.well-known/openid-configuration" then
          iss = sub(iss, 1, -34)
        end

        if sub(iss, -1) == "/" then
          return sub(iss, 1, -2)
        end
      end
    end

    secret = args.get_conf_arg("session_secret")
    if not secret then
      secret = issuer.secret
    elseif #secret ~= 32 then
      secret = sub(encode_base64(hash.S256(secret)), 1, 32)
    end
  end

  -- user may want to ignore access token signature verification with
  -- some flows, e.g. azure ad sends jwt access tokens for which they
  -- don't provide a JWK in public uri
  local ignore_signature = {}
  do
    local ignore_grants = args.get_conf_arg("ignore_signature")
    if ignore_grants then
      for _, grant in ipairs(ignore_grants) do
        ignore_signature[grant] = true
      end
    end
  end

  -- initialize functions
  local introspect_token = create_introspect_token(args, oic)
  local session_open     = create_session_open(args, secret)

  -- load enabled authentication methods
  local auth_methods = get_auth_methods(args.get_conf_arg)

  -- dynamic login redirect uri (only used with authorization code flow)
  local dynamic_login_redirect_uri

  -- try to open session
  local session
  local session_present
  local session_modified
  local session_regenerate
  local session_data
  local session_error
  if auth_methods.session then
    local session_secure = args.get_conf_arg("session_cookie_secure")
    if session_secure == nil then
      local scheme
      if kong.ip.is_trusted(var.realip_remote_addr or var.remote_addr) then
        scheme = args.get_header("X-Forwarded-Proto")
      end

      if not scheme then
        scheme = var.scheme
        if type(scheme) == "table" then
          scheme = scheme[1]
        end
      end

      session_secure = lower(scheme) == "https"
    end

    session, session_present, session_error = session_open {
      name = args.get_conf_arg("session_cookie_name", "session"),
      cookie = {
        lifetime = args.get_conf_arg("session_cookie_lifetime", 3600),
        idletime = args.get_conf_arg("session_cookie_idletime"),
        renew    = args.get_conf_arg("session_cookie_renew", 600),
        path     = args.get_conf_arg("session_cookie_path", "/"),
        domain   = args.get_conf_arg("session_cookie_domain"),
        samesite = args.get_conf_arg("session_cookie_samesite", "Lax"),
        httponly = args.get_conf_arg("session_cookie_httponly", true),
        maxsize  = args.get_conf_arg("session_cookie_maxsize", 4000),
        secure   = session_secure,
      },
    }

    if session_present then
      session_data = session.data
    end
  end

  -- logout
  do
    local logout = false
    local logout_methods = args.get_conf_arg("logout_methods", { "POST", "DELETE" })
    if logout_methods then
      local request_method = var.request_method
      for _, logout_method in ipairs(logout_methods) do
        if logout_method == request_method then
          logout = true
          break
        end
      end

      if logout then
        logout = false

        local logout_query_arg = args.get_conf_arg("logout_query_arg")
        if logout_query_arg then
          logout = args.get_uri_arg(logout_query_arg) ~= nil
        end

        if logout then
          log("logout by query argument")

        else
          local logout_uri_suffix = args.get_conf_arg("logout_uri_suffix")
          if logout_uri_suffix then
            logout = sub(var.request_uri, -#logout_uri_suffix) == logout_uri_suffix
            if logout then
              log("logout by uri suffix")

            else
              local logout_post_arg = args.get_conf_arg("logout_post_arg")
              if logout_post_arg then
                logout = args.get_post_arg(logout_post_arg) ~= nil
                if logout then
                  log("logout by post argument")
                end
              end
            end
          end
        end
      end

      if logout then
        local id_token
        if session_present and type(session_data) == "table" then
          reset_trusted_client(session_data.client, trusted_client, oic, options)

          if type(session_data.tokens) == "table" then
            id_token = session_data.tokens.id_token

            if args.get_conf_arg("logout_revoke", false) then
              local revocation_endpoint = args.get_conf_arg("revocation_endpoint")
              local revocation_endpoint_auth_method = args.get_conf_arg("revocation_endpoint_auth_method")
              if session_data.tokens.refresh_token and args.get_conf_arg("logout_revoke_refresh_token", false) then
                if revocation_endpoint then
                  log("revoking refresh token")
                  ok, err = oic.token:revoke(session_data.tokens.refresh_token, "refresh_token", {
                    revocation_endpoint = revocation_endpoint,
                    revocation_endpoint_auth_method = revocation_endpoint_auth_method,
                  })
                  if not ok and err then
                    log("revoking refresh token failed: ", err)
                  end

                else
                  log("unable to revoke refresh token, because revocation endpoint was not specified")
                end
              end

              if session_data.tokens.access_token and args.get_conf_arg("logout_revoke_access_token", true) then
                if revocation_endpoint then
                  log("revoking access token")
                  ok, err = oic.token:revoke(session_data.tokens.access_token, "access_token", {
                    revocation_endpoint = revocation_endpoint,
                    revocation_endpoint_auth_method = revocation_endpoint_auth_method,
                  })
                  if not ok and err then
                    log("revoking access token failed: ", err)
                  end

                else
                  log("unable to revoke access token, because revocation endpoint was not specified")
                end
              end
            end
          end

          log("destroying session")
          session:destroy()
        end

        no_cache_headers()

        local end_session_endpoint = args.get_conf_arg("end_session_endpoint", oic.configuration.end_session_endpoint)
        if end_session_endpoint then
          local redirect_params_added = false
          if find(end_session_endpoint, "?", 1, true) then
            redirect_params_added = true
          end

          local u = { end_session_endpoint }
          local i = 1

          if id_token then
            u[i+1] = redirect_params_added and "&id_token_hint=" or "?id_token_hint="
            u[i+2] = id_token
            i=i+2
            redirect_params_added = true
          end

          if trusted_client.logout_redirect_uri then
            u[i+1] = redirect_params_added and "&post_logout_redirect_uri=" or "?post_logout_redirect_uri="
            u[i+2] = escape_uri(trusted_client.logout_redirect_uri)
          end

          log("redirecting to end session endpoint")
          return redirect(concat(u))

        else
          if trusted_client.logout_redirect_uri then
            log("redirecting to logout redirect uri")
            return redirect(trusted_client.logout_redirect_uri)
          end

          log("logout response")
          return success()
        end
      end
    end
  end

  -- find credentials
  local bearer_token
  local token_endpoint_args
  if not session_present then
    local hide_credentials = args.get_conf_arg("hide_credentials", false)

    if auth_methods.session then
      if session_error then
        log("session was not found (", session_error, ")")
      else
        log("session was not found")
      end
    end

    -- bearer token authentication
    if auth_methods.bearer or auth_methods.introspection or auth_methods.kong_oauth2 then
      log("trying to find bearer token")
      local bearer_token_param_type = args.get_conf_arg("bearer_token_param_type", PARAM_TYPES_ALL)
      for _, location in ipairs(bearer_token_param_type) do
        if location == "header" then
          bearer_token = args.get_header("authorization:bearer")
          if bearer_token then
            if hide_credentials then
              args.clear_header("Authorization")
            end
            break
          end

          bearer_token = args.get_header("access_token")
          if bearer_token then
            if hide_credentials then
              args.clear_header("access-token")
              args.clear_header("access_token")
            end
            break
          end

          bearer_token = args.get_header("x_access_token")
          if bearer_token then
            if hide_credentials then
              args.clear_header("x-access-token")
              args.clear_header("x_access_token")
            end
            break
          end
        elseif location == "cookie" then
          local name = args.get_conf_arg("bearer_token_cookie_name")
          if name then
            bearer_token = var["cookie_" .. name]
            if bearer_token then
              if hide_credentials then
                hide_cookie(name)
              end
              break
            end
          end

        elseif location == "query" then
          bearer_token = args.get_uri_arg("access_token")
          if bearer_token then
            if hide_credentials then
              args.clear_uri_arg("access_token")
            end
            break
          end

        elseif location == "body" then
          bearer_token = args.get_post_arg("access_token")
          if bearer_token then
            if hide_credentials then
              args.clear_post_arg("access_token")
            end
            break
          end

          bearer_token = args.get_json_arg("access_token")
          if bearer_token then
            if hide_credentials then
              args.clear_json_arg("access_token")
            end
            break
          end
        end
      end

      if bearer_token then
        log("found bearer token")
        session_data = {
          client = trusted_client.index,
          tokens = {
            access_token = bearer_token,
          },
        }

        -- additionally we can validate the id token as well
        -- and pass it on, if it is passed on the request
        local id_token_param_name = args.get_conf_arg("id_token_param_name")
        if id_token_param_name then
          log("trying to find id token")

          local id_token, loc = args.get_req_arg(
            id_token_param_name,
            args.get_conf_arg("id_token_param_type", PARAM_TYPES_ALL)
          )

          if id_token then
            log("found id token")
            if hide_credentials then
              if loc == "header" then
                args.clear_header(id_token_param_name, "X")

              elseif loc == "query" then
                args.clear_uri_arg(id_token_param_name)

              elseif loc == "post" then
                args.clear_post_arg(id_token_param_name)

              elseif loc == "json" then
                args.clear_json_arg(id_token_param_name)
              end
            end

            session_data.tokens.id_token = id_token

          else
            log("id token was not found")
          end
        end

      else
        log("bearer token was not found")
      end
    end

    if not bearer_token then
      if auth_methods.refresh_token then
        local refresh_token_param_name = args.get_conf_arg("refresh_token_param_name")
        if refresh_token_param_name then
          log("trying to find refresh token")

          local refresh_token, loc = args.get_req_arg(
            refresh_token_param_name,
            args.get_conf_arg("refresh_token_param_type", PARAM_TYPES_ALL)
          )

          if loc == "header" then
            local value_prefix = lower(sub(refresh_token, 1, 6))
            if value_prefix == "bearer" then
              refresh_token =  sub(refresh_token, 8)
            end
          end

          if refresh_token then
            log("found refresh token")
            if hide_credentials then
              log("hiding credentials from ", loc)
              if loc == "header" then
                args.clear_header(refresh_token_param_name, "X")

              elseif loc == "query" then
                args.clear_uri_arg(refresh_token_param_name)

              elseif loc == "post" then
                args.clear_post_arg(refresh_token_param_name)

              elseif loc == "json" then
                args.clear_json_arg(refresh_token_param_name)
              end
            end

            token_endpoint_args = {
              {
                refresh_token    = refresh_token,
                grant_type       = "refresh_token",
                ignore_signature = ignore_signature.refresh_token,
              },
            }
          else
            log("refresh token was not found")
          end
        end
      end

      if not token_endpoint_args then
        if auth_methods.password or auth_methods.client_credentials then
          local usr, pwd, loc1
          if auth_methods.password then
            log("trying to find credentials for password grant")
            usr, pwd, loc1 = get_credentials(args, "password", "username",  "password")
          end

          local cid, sec, loc2
          if auth_methods.client_credentials then
            log("trying to find credentials for client credentials grant")
            cid, sec, loc2 = get_credentials(args, "client_credentials", "client_id", "client_secret")
          end

          if usr and pwd and cid and sec then
            log("found credentials and will try both password and client credentials grants")

            token_endpoint_args = {
              {
                username         = usr,
                password         = pwd,
                grant_type       = "password",
                ignore_signature = ignore_signature.password,
              },
              {
                client_id        = cid,
                client_secret    = sec,
                grant_type       = "client_credentials",
                ignore_signature = ignore_signature.client_credentials,
              },
            }

          elseif usr and pwd then
            log("found credentials for password grant")

            token_endpoint_args = {
              {
                username         = usr,
                password         = pwd,
                grant_type       = "password",
                ignore_signature = ignore_signature.password,
              },
            }

          elseif cid and sec then
            log("found credentials for client credentials grant")

            token_endpoint_args = {
              {
                client_id        = cid,
                client_secret    = sec,
                grant_type       = "client_credentials",
                ignore_signature = ignore_signature.client_credentials,
              },
            }

          else

            log("credentials for client credentials or password grants were not found")
          end

          if token_endpoint_args and hide_credentials then
            if loc1 == "header" or loc2 == "header" then
              args.clear_header("Authorization", "X")
              args.clear_header("Grant-Type",    "X")
              args.clear_header("Grant_Type",    "X")
            end

            if loc1 then
              if loc1 == "query" then
                args.clear_uri_arg("username", "password", "grant_type")

              elseif loc1 == "post" then
                args.clear_post_arg("username", "password", "grant_type")

              elseif loc1 == "json" then
                args.clear_json_arg("username", "password", "grant_type")
              end
            end

            if loc2 then
              if loc2 == "query" then
                args.clear_uri_arg("client_id", "client_secret", "grant_type")

              elseif loc2 == "post" then
                args.clear_post_arg("client_id", "client_secret", "grant_type")

              elseif loc2 == "json" then
                args.clear_json_arg("client_id", "client_secret", "grant_type")
              end
            end
          end
        end
      end

      if type(token_endpoint_args) ~= "table" then
        -- authorization code flow
        if auth_methods.authorization_code then
          log("trying to open authorization code flow session")

          local authorization_secure = args.get_conf_arg("authorization_cookie_secure")
          if authorization_secure == nil then
            local scheme
            if kong.ip.is_trusted(var.realip_remote_addr or var.remote_addr) then
              scheme = args.get_header("X-Forwarded-Proto")
            end

            if not scheme then
              scheme = var.scheme
              if type(scheme) == "table" then
                scheme = scheme[1]
              end
            end

            authorization_secure = lower(scheme) == "https"
          end

          local authorization, authorization_present, authorization_error = session_open {
            name = args.get_conf_arg("authorization_cookie_name", "authorization"),
            cookie = {
              lifetime = args.get_conf_arg("authorization_cookie_lifetime", 600),
              path     = args.get_conf_arg("authorization_cookie_path", "/"),
              domain   = args.get_conf_arg("authorization_cookie_domain"),
              samesite = args.get_conf_arg("authorization_cookie_samesite", "off"),
              httponly = args.get_conf_arg("authorization_cookie_httponly", true),
              secure   = authorization_secure,
            },
          }

          if authorization_present then
            log("found authorization code flow session")

            local authorization_data = authorization.data
            if type(authorization_data) ~= "table" then
              authorization_data = {}
            end

            log("checking authorization code flow state")

            local state = authorization_data.state
            if state then
              log("found authorization code flow state")

              local nonce         = authorization_data.nonce
              local code_verifier = authorization_data.code_verifier

              reset_trusted_client(authorization_data.client, trusted_client, oic, options)

              -- authorization code response
              token_endpoint_args = {
                state         = state,
                nonce         = nonce,
                code_verifier = code_verifier,
              }

              log("verifying authorization code flow")

              token_endpoint_args, err = oic.authorization:verify(token_endpoint_args)
              if type(token_endpoint_args) ~= "table" then
                log("invalid authorization code flow")

                no_cache_headers()

                if args.get_uri_arg("state") == state then
                  return unauthorized(ctx, iss, unauthorized_error_message, err,
                                      authorization, anonymous, trusted_client)

                elseif args.get_post_arg("state") == state then
                  return unauthorized(ctx, iss, unauthorized_error_message, err,
                                      authorization, anonymous, trusted_client)

                else
                  log(err)
                end

                log("creating authorization code flow request with previous parameters")
                token_endpoint_args, err = oic.authorization:request {
                  args          = authorization_data.args,
                  client        = trusted_client.index,
                  state         = state,
                  nonce         = nonce,
                  code_verifier = code_verifier,
                }

                if type(token_endpoint_args) ~= "table" then
                  log("unable to start authorization code flow request with previous parameters")
                  return unexpected(trusted_client, err)
                end

                log("starting a new authorization code flow with previous parameters")
                -- it seems that user may have opened a second tab
                -- lets redirect that to idp as well in case user
                -- had closed the previous, but with same parameters
                -- as before.
                authorization:start()
                authorization.data.uri = redirect_uri(args)
                authorization:save()

                log("redirecting client to openid connect provider with previous parameters")
                return redirect(token_endpoint_args.url)
              end

              log("authorization code flow verified")

              dynamic_login_redirect_uri = authorization.data.uri

              authorization:hide()
              authorization:destroy()

              if var.request_method == "POST" then
                args.clear_post_arg("code", "state", "session_state")

              else
                args.clear_uri_arg("code", "state", "session_state")
              end

              token_endpoint_args.ignore_signature = ignore_signature.authorization_code
              token_endpoint_args = { token_endpoint_args }

            else
              log("authorization code flow state was not found")
            end

          else
            if authorization_error then
              log("authorization code flow session was not found (", authorization_error, ")")
            else
              log("authorization code flow session was not found")
            end
          end

          if type(token_endpoint_args) ~= "table" then
            log("creating authorization code flow request")

            no_cache_headers()

            local extra_args  = args.get_conf_args("authorization_query_args_names",
                                                   "authorization_query_args_values")
            local client_args = args.get_conf_arg("authorization_query_args_client")
            if client_args then
              for _, client_arg_name in ipairs(client_args) do
                local extra_arg = args.get_uri_arg(client_arg_name)
                if extra_arg then
                  if not extra_args then
                    extra_args = {}
                  end

                  extra_args[client_arg_name] = extra_arg

                else
                  extra_arg = args.get_post_arg(client_arg_name)
                  if extra_arg then
                    if not extra_args then
                      extra_args = {}
                    end

                    extra_args[client_arg_name] = extra_arg
                  end
                end
              end
            end

            token_endpoint_args, err = oic.authorization:request {
              args = extra_args,
            }

            if type(token_endpoint_args) ~= "table" then
              log("unable to start authorization code flow request")
              return unexpected(trusted_client, err)
            end

            authorization.data = {
              uri           = redirect_uri(args),
              args          = extra_args,
              client        = trusted_client.index,
              state         = token_endpoint_args.state,
              nonce         = token_endpoint_args.nonce,
              code_verifier = token_endpoint_args.code_verifier,
            }

            authorization:save()

            log("redirecting client to openid connect provider")
            return redirect(token_endpoint_args.url)

          else
            log("authenticating using authorization code flow")
          end

        else
          return unauthorized(ctx,
                              iss,
                              unauthorized_error_message,
                              "no suitable authorization credentials were provided",
                              nil,
                              anonymous,
                              trusted_client)
        end
      end

    else
      log("authenticating using bearer token")
    end

  else
    log("authenticating using session")
  end

  if type(session_data) ~= "table" then
    session_data = {}
  end

  local credential, consumer

  local leeway = args.get_conf_arg("leeway", 0)
  local exp
  local ttl
  do
    local now = time()
    local ttl_default   = args.get_conf_arg("cache_ttl", 3600)
    local ttl_max       = args.get_conf_arg("cache_ttl_max")
    local ttl_min       = args.get_conf_arg("cache_ttl_min")
    local ttl_neg       = args.get_conf_arg("cache_ttl_min")
    local ttl_resurrect = args.get_conf_arg("cache_ttl_resurrect")

    if ttl_max and ttl_max > 0 then
      if ttl_min and ttl_min > ttl_max then
        ttl_min = ttl_max
      end

      if ttl_default > ttl_max then
        ttl_default = ttl_max
      end
    end

    if ttl_min and ttl_min > 0 then
      if ttl_default < ttl_min then
        ttl_default = ttl_min
      end
    end

    ttl = {
      now = now,
      default_ttl = ttl_default,
      min_ttl = ttl_min,
      max_ttl = ttl_max,
      neg_ttl = ttl_neg,
      resurrect_ttl = ttl_resurrect
    }
  end

  local exp_default
  if ttl.default_ttl == 0 then
    exp_default = 0
  else
    exp_default = ttl.now + ttl.default_ttl
  end

  local tokens_encoded
  if type(session_data.tokens) == "table" then
    tokens_encoded = session_data.tokens
  end

  local tokens_decoded

  local auth_method
  local token_introspected
  local jwt_token_introspected

  local downstream_headers

  -- retrieve or verify tokens
  if bearer_token then
    if auth_methods.bearer then
      log("verifying bearer token")
      tokens_decoded, err = oic.token:verify(tokens_encoded)
      if type(tokens_decoded) ~= "table" then
        if not auth_methods.kong_oauth2 and not auth_methods.introspection then
          log("unable to verify bearer token")
          return unauthorized(ctx, iss, unauthorized_error_message, err or "invalid jwt token",
                              session, anonymous, trusted_client)
        end

        if err then
          log("unable to verify bearer token (", err, "), trying to introspect it")

        else
          log("unable to verify bearer token, trying to introspect it")
        end
      end
    end

    if not auth_methods.bearer or type(tokens_decoded) ~= "table" or type(tokens_decoded.access_token) ~= "table" then
      if type(tokens_decoded) ~= "table" then
        tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
        if not tokens_decoded then
          return unauthorized(ctx, iss, unauthorized_error_message,
                              err, session, anonymous, trusted_client)
        end
      end

      local access_token
      if type(tokens_decoded.access_token) ~= "table" then
        log("opaque bearer token was provided")
        access_token = tokens_decoded.access_token

      elseif type(tokens_encoded) == "table" then
        log("bearer authentication was not enabled")
        access_token = tokens_encoded.access_token
      end

      if not access_token then
        return unauthorized(ctx, iss, unauthorized_error_message,
                            "access token not found",
                            session, anonymous, trusted_client)
      end

      if auth_methods.kong_oauth2 then
        log("trying to find matching kong oauth2 token")
        token_introspected, credential, consumer = cache.kong_oauth2.load(
          ctx, access_token, ttl, true)
        if type(token_introspected) == "table" then
          log("found matching kong oauth2 token")
          token_introspected.active = true

        else
          log("matching kong oauth2 token was not found")
        end
      end

      if type(token_introspected) ~= "table" or token_introspected.active ~= true then
        if auth_methods.introspection then
          token_introspected, err = introspect_token(access_token, ttl)
          if type(token_introspected) == "table" then
            if token_introspected.active then
              log("authenticated using oauth2 introspection")

            else
              log("opaque token is not active anymore")
            end

          else
            log("unable to authenticate using oauth2 introspection")
          end
        end

        if type(token_introspected) ~= "table" or token_introspected.active ~= true then
          log("authentication with opaque bearer token failed")
          return unauthorized(ctx, iss, unauthorized_error_message, err or "invalid or inactive token",
                              session, anonymous, trusted_client)
        end

        auth_method = "introspection"

      else
        auth_method = "kong_oauth2"
      end

      exp = get_exp(token_introspected, tokens_encoded, ttl.now, exp_default)

    else
      log("bearer token verified")

      if args.get_conf_arg("introspect_jwt_tokens", false) then
        log("introspecting jwt bearer token")
        jwt_token_introspected, err = introspect_token(tokens_encoded.access_token, ttl)
        if type(jwt_token_introspected) == "table" then
          if jwt_token_introspected.active then
            log("jwt bearer token is active and not revoked")

          else
            return unauthorized(ctx, iss, unauthorized_error_message,
                                "jwt bearer token is not active anymore or has been revoked",
                                session, anonymous, trusted_client)
          end

        else
          log("unable to introspect jwt bearer token")
          return unauthorized(ctx, iss, unauthorized_error_message, err,
                              session, anonymous, trusted_client)
        end

        exp = get_exp(jwt_token_introspected, tokens_encoded, ttl.now, exp_default)
      end

      if not exp then
        exp = get_exp(tokens_decoded.access_token, tokens_encoded, ttl.now, exp_default)
      end

      log("authenticated using jwt bearer token")
      auth_method = "bearer"
    end

    if auth_methods.session then
      session_modified = true
      session.data = {
        client  = trusted_client.index,
        tokens  = tokens_encoded,
        expires = exp,
      }
    end

  elseif type(tokens_encoded) ~= "table" then
    -- let's try to retrieve tokens when using authorization code flow,
    -- password credentials, client credentials or refresh_token
    local auth_params
    if type(token_endpoint_args) == "table" then
      for _, arg in ipairs(token_endpoint_args) do
        arg.args = args.get_conf_args("token_post_args_names", "token_post_args_values")
        local client_args = args.get_conf_arg("token_post_args_client")
        if client_args then
          for _, client_arg_name in ipairs(client_args) do
            local extra_arg = args.get_uri_arg(client_arg_name)
            if extra_arg then
              if not arg.args then
                arg.args = {}
              end

              arg.args[client_arg_name] = extra_arg

            else
              extra_arg = args.get_post_arg(client_arg_name)
              if extra_arg then
                if not arg.args then
                  arg.args = {}
                end

                arg.args[client_arg_name] = extra_arg
              end
            end
          end
        end

        local token_headers = args.get_conf_args("token_headers_names", "token_headers_values")
        local token_headers_client = args.get_conf_arg("token_headers_client")
        if token_headers_client then
          log("parsing client headers for token request")
          for _, token_header_name in ipairs(token_headers_client) do
            local token_header_value = args.get_header(token_header_name)
            if token_header_value then
              if not token_headers then
                token_headers = {}
              end

              token_headers[token_header_name] = token_header_value
            end
          end
        end

        if token_headers then
          log("injecting token headers to token request")
          arg.headers = token_headers
        end

        local token_endpoint_auth_method = args.get_conf_arg("token_endpoint_auth_method")
        if token_endpoint_auth_method then
          arg.token_endpoint_auth_method = token_endpoint_auth_method
        end

        if args.get_conf_arg("cache_tokens") then
          log("trying to exchange credentials using token endpoint with caching enabled")
          tokens_encoded, err, downstream_headers = cache.tokens.load(oic, arg, ttl, true)

          if type(tokens_encoded) == "table"   and
            (arg.grant_type == "refresh_token" or
              arg.grant_type == "password"      or
              arg.grant_type == "client_credentials")
          then
            log("verifying tokens")
            tokens_decoded, err = oic.token:verify(tokens_encoded, arg)
            if type(tokens_decoded) ~= "table" then
              log("token verification failed, trying to exchange credentials ",
                  "using token endpoint with cache flushed")
              tokens_encoded, err, downstream_headers = cache.tokens.load(oic, arg, ttl, true, true)

            else
              log("tokens verified")
            end
          end

        else
          log("trying to exchange credentials using token endpoint")
          tokens_encoded, err, downstream_headers = cache.tokens.load(oic, arg, ttl, false)
        end

        if type(tokens_encoded) == "table" then
          log("exchanged credentials with tokens")
          auth_method = arg.grant_type or "authorization_code"
          auth_params = arg
          break
        end
      end
    end

    if type(tokens_encoded) ~= "table" then
      log("unable to exchange credentials with tokens")
      return unauthorized(ctx, iss, unauthorized_error_message, err,
                          session, anonymous, trusted_client)
    end

    if type(tokens_decoded) ~= "table" then
      log("verifying tokens")
      tokens_decoded, err = oic.token:verify(tokens_encoded, auth_params)
      if type(tokens_decoded) ~= "table" then
        log("token verification failed")
        return unauthorized(ctx, iss, unauthorized_error_message, err,
                            session, anonymous, trusted_client)

      else
        log("tokens verified")
      end
    end

    exp = get_exp(tokens_decoded.access_token, tokens_encoded, ttl.now, exp_default)

    if auth_methods.session then
      session_modified = true
      session.data = {
        client  = trusted_client.index,
        tokens  = tokens_encoded,
        expires = exp,
      }
    end

  elseif session_present then
    -- it looks like we are using session authentication
    log("authenticated using session")

    auth_method = "session"
    if session_data.expires then
      exp = session_data.expires
    else
      exp = exp_default
    end

  else
    return unauthorized(ctx,
                        iss,
                        unauthorized_error_message,
                        "unable to authenticate with any enabled authentication method",
                        nil,
                        anonymous,
                        trusted_client)
  end

  log("checking for access token")
  if type(tokens_encoded) ~= "table" or not tokens_encoded.access_token then
    return unauthorized(ctx, iss, unauthorized_error_message, "access token was not found",
                        session, anonymous, trusted_client)

  else
    log("found access token")
  end

  if not exp then
    exp = exp_default
  end

  local refresh_tokens = args.get_conf_arg("refresh_tokens", true)

  local leeway_adjusted_exp
  if exp ~= 0 and leeway ~= 0 then
    if refresh_tokens and tokens_encoded.refresh_token then
      leeway_adjusted_exp = exp - leeway
    else
      leeway_adjusted_exp = exp + leeway
    end

  else
    leeway_adjusted_exp = exp
  end

  if exp > 0 then
    local ttl_new = exp - ttl.now
    if ttl_new > 0 then
      if ttl.max_ttl and ttl.max_ttl > 0 then
        if ttl_new > ttl.max_ttl then
          ttl_new = ttl.max_ttl
        end
      end

      if ttl.min_ttl and ttl.min_ttl > 0 then
        if ttl_new < ttl.min_ttl then
          ttl_new = ttl.min_ttl
        end
      end

      ttl.default_ttl = ttl_new
    end
  end

  log("checking for access token expiration")

  if leeway_adjusted_exp == 0 or leeway_adjusted_exp > ttl.now then
    log("access token is valid and has not expired")

    if auth_method == "session" then
      if args.get_conf_arg("reverify") then
        log("reverifying tokens")
        if ignore_signature.session then
          tokens_decoded, err = oic.token:verify(tokens_encoded , { ignore_signature = true })
        else
          tokens_decoded, err = oic.token:verify(tokens_encoded)
        end

        if type(tokens_decoded) ~= "table" then
          log("reverifying tokens failed")
          return unauthorized(ctx,
                              iss,
                              unauthorized_error_message,
                              err,
                              session,
                              anonymous,
                              trusted_client)

        else
          log("reverified tokens")
        end
      end
    end

  else
    log("access token has expired")

    if not refresh_tokens then
      return unauthorized(ctx,
                          iss,
                          unauthorized_error_message,
                          "access token has expired and refreshing of tokens was disabled",
                          session,
                          anonymous,
                          trusted_client)
    end

    -- access token has expired, try to refresh the access token before proxying
    if not tokens_encoded.refresh_token then
      return unauthorized(ctx,
                          iss,
                          unauthorized_error_message,
                          "access token cannot be refreshed in absence of refresh token",
                          session,
                          anonymous,
                          trusted_client)
    end

    log("trying to refresh access token using refresh token")

    local refresh_token = tokens_encoded.refresh_token

    local tokens_refreshed
    tokens_refreshed, err = oic.token:refresh(refresh_token)
    if type(tokens_refreshed) ~= "table" then
      log("unable to refresh access token using refresh token")
      return unauthorized(ctx,
                          iss,
                          unauthorized_error_message,
                          err,
                          session,
                          anonymous,
                          trusted_client)

    else
      log("refreshed access token using refresh token")
    end

    if not tokens_refreshed.refresh_token then
      -- perhaps this refresh token was not a single use token
      tokens_refreshed.refresh_token = refresh_token
    end

    log("verifying refreshed tokens")

    if ignore_signature.refresh_token then
      tokens_decoded, err = oic.token:verify(tokens_refreshed, { ignore_signature = true })
    else
      tokens_decoded, err = oic.token:verify(tokens_refreshed)
    end

    if type(tokens_decoded) ~= "table" then
      log("unable to verify refreshed tokens")
      return unauthorized(ctx,
                          iss,
                          unauthorized_error_message,
                          err,
                          session,
                          anonymous,
                          trusted_client)

    else
      log("verified refreshed tokens")
    end

    tokens_encoded = tokens_refreshed

    exp = get_exp(tokens_decoded.access_token, tokens_encoded, ttl.now, exp_default)

    if exp > 0 then
      local ttl_new = exp - ttl.now
      if ttl_new > 0 then
        if ttl.max_ttl and ttl.max_ttl > 0 then
          if ttl_new > ttl.max_ttl then
            ttl_new = ttl.max_ttl
          end
        end

        if ttl.min_ttl and ttl.min_ttl > 0 then
          if ttl_new < ttl.min_ttl then
            ttl_new = ttl.min_ttl
          end
        end

        ttl.default_ttl = ttl_new
      end
    end

    if auth_methods.session then
      if session_present then
        session_regenerate = true
      else
        session_modified = true
      end

      session.data = {
        client  = trusted_client.index,
        tokens  = tokens_encoded,
        expires = exp,
      }
    end
  end

  local decode_tokens = type(tokens_decoded) ~= "table"

  -- additional claims verification
  do
    -- additional non-standard verification of the claim against a jwt session cookie
    local jwt_session_cookie = args.get_conf_arg("jwt_session_cookie")
    if jwt_session_cookie then
      if decode_tokens and type(tokens_decoded) ~= "table" then
        decode_tokens = false
        tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
        if err then
          log("error decoding tokens (", err, ")")
        end
      end

      local jwt_session_claim = args.get_conf_arg("jwt_session_claim", "sid")
      if type(tokens_decoded) == "table" and type(tokens_decoded.access_token) == "table" then
        log("validating jwt claim against jwt session cookie")
        local jwt_session_cookie_value = args.get_value(var["cookie_" .. jwt_session_cookie])
        if not jwt_session_cookie_value then
          return unauthorized(ctx,
                              iss,
                              unauthorized_error_message,
                              "jwt session cookie was not specified for session claim verification",
                              session,
                              anonymous,
                              trusted_client)
        end

        local jwt_session_claim_value

        jwt_session_claim_value = tokens_decoded.access_token.payload[jwt_session_claim]

        if not jwt_session_claim_value then
          return unauthorized(ctx,
                              iss,
                              unauthorized_error_message,
                              "jwt session claim (" .. jwt_session_claim ..
                                ") was not specified in jwt access token",
                              session,
                              anonymous,
                              trusted_client)
        end

        if jwt_session_claim_value ~= jwt_session_cookie_value then
          return unauthorized(ctx,
                              iss,
                              unauthorized_error_message,
                              "invalid jwt session claim (" .. jwt_session_claim ..
                                ") was specified in jwt access token",
                              session,
                              anonymous,
                              trusted_client)
        end

        log("jwt claim matches jwt session cookie")

      else
        log("jwt claim verification skipped as it was not found on access token")
      end
    end

    -- scope verification
    local scopes_required = args.get_conf_arg("scopes_required")
    if scopes_required then
      log("verifying required scopes")
      local scopes_claim = args.get_conf_arg("scopes_claim", { "scope" })

      local access_token_scopes
      if type(token_introspected) == "table" then
        access_token_scopes = find_claim(token_introspected, scopes_claim)
        if access_token_scopes then
          log("scopes found in introspection results")
        else
          log("scopes not found in introspection results")
        end

      elseif type(jwt_token_introspected) == "table" then
        access_token_scopes = find_claim(jwt_token_introspected, scopes_claim)
        if access_token_scopes then
          log("scopes found in jwt introspection results")
        else
          log("scopes not found in jwt introspection results")
        end
      end

      if not access_token_scopes then
        if decode_tokens and type(tokens_decoded) ~= "table" then
          decode_tokens = false
          tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
          if err then
            log("error decoding tokens (", err, ")")
          end
        end

        if type(tokens_decoded) == "table" and type(tokens_decoded.access_token) == "table" then
          access_token_scopes = find_claim(tokens_decoded.access_token.payload, scopes_claim)
          if access_token_scopes then
            log("scopes found in access token")
          else
            log("scopes not found in access token")
          end
        end
      end

      if not access_token_scopes then
        return forbidden(ctx,
                         iss,
                         forbidden_error_message,
                         "scopes required but no scopes found",
                         session,
                         anonymous,
                         trusted_client)
      end

      access_token_scopes = set.new(access_token_scopes)

      local scopes_valid
      for _, scope_required in ipairs(scopes_required) do
        if set.has(scope_required, access_token_scopes) then
          scopes_valid = true
          break
        end
      end

      if scopes_valid then
        log("required scopes were found")

      else
        return forbidden(ctx,
                         iss,
                         forbidden_error_message,
                         "required scopes were not found [ " .. concat(access_token_scopes, ", ") .. " ]",
                         session,
                         anonymous,
                         trusted_client)
      end
    end

    -- audience verification
    local audience_required = args.get_conf_arg("audience_required")
    if audience_required then
      log("verifying required audience")

      local audience_claim = args.get_conf_arg("audience_claim", { "aud" })

      local access_token_audience
      if type(token_introspected) == "table" then
        access_token_audience = find_claim(token_introspected, audience_claim)
        if access_token_audience then
          log("audience found in introspection results")
        else
          log("audience not found in introspection results")
        end

      elseif type(jwt_token_introspected) == "table" then
        access_token_audience = find_claim(jwt_token_introspected, audience_claim)
        if access_token_audience then
          log("audience found in jwt introspection results")
        else
          log("audience not found in jwt introspection results")
        end
      end

      if not access_token_audience then
        if decode_tokens and type(tokens_decoded) ~= "table" then
          decode_tokens = false
          tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
          if err then
            log("error decoding tokens (", err, ")")
          end
        end

        if type(tokens_decoded) == "table" and type(tokens_decoded.access_token) == "table" then
          access_token_audience = find_claim(tokens_decoded.access_token.payload, audience_claim)
          if access_token_audience then
            log("audience found in access token")
          else
            log("audience not found in access token")
          end
        end
      end

      if not access_token_audience then
        return forbidden(ctx,
                         iss,
                         forbidden_error_message,
                         "audience required but no audience found",
                         session,
                         anonymous,
                         trusted_client)
      end

      access_token_audience = set.new(access_token_audience)

      local audience_valid
      for _, aud_required in ipairs(audience_required) do
        if set.has(aud_required, access_token_audience) then
          audience_valid = true
          break
        end
      end

      if audience_valid then
        log("required audience was found")

      else
        return forbidden(ctx,
                         iss,
                         forbidden_error_message,
                         "required audience was not found [ " .. concat(access_token_audience, ", ") .. " ]",
                         session,
                         anonymous,
                         trusted_client)
      end
    end
  end

  local userinfo = false
  local userinfo_loaded = false
  local cache_userinfo  = args.get_conf_arg("cache_user_info")
  local search_userinfo = args.get_conf_arg("search_user_info")

  -- consumer mapping
  if not consumer then
    local consumer_claim = args.get_conf_arg("consumer_claim")
    if consumer_claim then
      log("trying to find kong consumer")

      local consumer_by = args.get_conf_arg("consumer_by")

      if not consumer then
        if type(token_introspected) == "table" then
          log("trying to find consumer using introspection response")
          consumer, err = find_consumer({ payload = token_introspected }, consumer_claim, false, consumer_by, ttl)
          if consumer then
            log("consumer was found with introspection results")
          elseif err then
            log("consumer was not found with introspection results (", err, ")")
          else
            log("consumer was not found with introspection results")
          end

        elseif type(jwt_token_introspected) == "table" then
          log("trying to find consumer using jwt introspection response")
          consumer, err = find_consumer({ payload = jwt_token_introspected }, consumer_claim, false, consumer_by, ttl)
          if consumer then
            log("consumer was found with jwt introspection results")
          elseif err then
            log("consumer was not found with jwt introspection results (", err, ")")
          else
            log("consumer was not found with jwt introspection results")
          end
        end
      end

      if not consumer then
        if decode_tokens and type(tokens_decoded) ~= "table" then
          decode_tokens = false
          tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
          if err then
            log("error decoding tokens (", err, ")")
          end
        end

        if type(tokens_decoded) == "table" then
          if type(tokens_decoded.id_token) == "table" then
            log("trying to find consumer using id token")
            consumer, err = find_consumer(tokens_decoded.id_token, consumer_claim, false, consumer_by, ttl)
            if consumer then
              log("consumer was found with id token")
            elseif err then
              log("consumer was not found with id token (", err, ")")
            else
              log("consumer was not found with id token")
            end
          end

          if not consumer and type(tokens_decoded.access_token) == "table" then
            log("trying to find consumer using access token")
            consumer, err = find_consumer(tokens_decoded.access_token, consumer_claim, false, consumer_by, ttl)
            if consumer then
              log("consumer was found with access token")
            elseif err then
              log("consumer was not found with access token (", err, ")")
            else
              log("consumer was not found with access token")
            end
          end
        end
      end

      if not consumer and search_userinfo then
        if type(userinfo) ~= "table" and not userinfo_loaded then
          log("loading user info")
          if cache_userinfo then
            userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, true)
          else
            userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, false)
          end

          userinfo_loaded = true

          if type(userinfo) == "table" then
            log("user info loaded")
          elseif err then
            log("user info could not be loaded (", err, ")")
          else
            log("user info could not be loaded")
          end
        end

        if type(userinfo) == "table" then
          log("trying to find consumer using user info")
          consumer, err = find_consumer({ payload = userinfo }, consumer_claim, false, consumer_by, ttl)
          if consumer then
            log("consumer was found with user info")
          elseif err then
            log("consumer was not found with user info (", err, ")")
          else
            log("consumer was not found with user info")
          end
        end
      end

      if not consumer then
        log("kong consumer was not found")

        local consumer_optional = args.get_conf_arg("consumer_optional", false)
        if consumer_optional then
          log("kong consumer is optional")

        else
          if err then
            return forbidden(ctx,
                             iss,
                             forbidden_error_message,
                             "kong consumer was not found (" .. err .. ")",
                             session,
                             anonymous,
                             trusted_client)

          else
            return forbidden(ctx,
                             iss,
                             forbidden_error_message,
                             "kong consumer was not found",
                             session,
                             anonymous,
                             trusted_client)
          end
        end

      else
        log("found kong consumer")
      end
    end
  end

  -- setting consumer context and headers
  set_consumer(ctx, consumer, credential)

  if not consumer then
    -- setting credential by arbitrary claim, in case when consumer mapping was not used
    local credential_claim = args.get_conf_arg("credential_claim")
    if credential_claim then
      log("finding credential claim value")

      local credential_value
      if type(token_introspected) == "table" then
        credential_value = find_claim(token_introspected, credential_claim)
        if credential_value then
          log("credential claim found in introspection results")

        else
          log("credential claim not found in introspection results")
        end
      elseif type(jwt_token_introspected) == "table" then
        credential_value = find_claim(jwt_token_introspected, credential_claim)
        if credential_value then
          log("credential claim found in jwt introspection results")

        else
          log("credential claim not found in jwt introspection results")
        end
      end

      if not credential_value then
        if decode_tokens and type(tokens_decoded) ~= "table" then
          decode_tokens = false
          tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
          if err then
            log("error decoding tokens (", err, ")")
          end
        end

        if type(tokens_decoded) == "table" then
          if type(tokens_decoded.id_token) == "table" then
            credential_value = find_claim(tokens_decoded.id_token.payload, credential_claim)
            if credential_value then
              log("credential claim found in id token")
            else
              log("credential claim not found in id token")
            end
          end

          if not credential_value and type(tokens_decoded.access_token) == "table" then
            credential_value = find_claim(tokens_decoded.access_token.payload, credential_claim)
            if credential_value then
              log("credential claim found in access token")
            else
              log("credential claim not found in access token")
            end
          end
        end
      end

      if not credential_value and search_userinfo then
        if type(userinfo) ~= "table" and not userinfo_loaded then
          log("loading user info")
          if cache_userinfo then
            userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, true)
          else
            userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, false)
          end

          userinfo_loaded = true

          if type(userinfo) == "table" then
            log("user info loaded")
          elseif err then
            log("user info could not be loaded (", err, ")")
          else
            log("user info could not be loaded")
          end
        end

        if type(userinfo) == "table" then
          log("trying to find credential using user info")
          credential_value = find_claim(userinfo, credential_claim)
          if credential_value then
            log("credential claim found in user info")
          else
            log("credential claim was not found in user info")
          end
        end
      end

      if not credential_value then
        log("credential claim was not found")

      elseif type(credential_value) == "table" then
        log("credential claim is invalid")

      else
        log("credential found '", credential_value, "'")
        ctx.authenticated_credential = {
          id = tostring(credential_value)
        }
      end
    end

    -- trying to find authenticated groups for ACL plugin to filter
    local authenticated_groups_claim = args.get_conf_arg("authenticated_groups_claim")
    if authenticated_groups_claim then
      log("finding authenticated groups claim value")

      local authenticated_groups
      if type(token_introspected) == "table" then
        authenticated_groups = find_claim(token_introspected, authenticated_groups_claim)
        if authenticated_groups then
          log("authenticated groups claim found in introspection results")
        else
          log("authenticated groups claim not found in introspection results")
        end
      end

      if not authenticated_groups then
        if decode_tokens and type(tokens_decoded) ~= "table" then
          decode_tokens = false
          tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
          if err then
            log("error decoding tokens (", err, ")")
          end
        end

        if type(tokens_decoded) == "table" then
          if type(tokens_decoded.id_token) == "table" then
            authenticated_groups = find_claim(tokens_decoded.id_token.payload, authenticated_groups_claim)
            if authenticated_groups then
              log("authenticated groups found in id token")
            else
              log("authenticated groups not found in id token")
            end
          end

          if not authenticated_groups and type(tokens_decoded.access_token) == "table" then
            authenticated_groups = find_claim(tokens_decoded.access_token.payload, authenticated_groups_claim)
            if authenticated_groups then
              log("authenticated groups claim found in access token")
            else
              log("authenticated groups claim not found in access token")
            end
          end
        end
      end

      if not authenticated_groups and search_userinfo then
        if type(userinfo) ~= "table" and not userinfo_loaded then
          log("loading user info")
          if cache_userinfo then
            userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, true)
          else
            userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, false)
          end

          userinfo_loaded = true

          if type(userinfo) == "table" then
            log("user info loaded")
          elseif err then
            log("user info could not be loaded (", err, ")")
          else
            log("user info could not be loaded")
          end
        end

        if type(userinfo) == "table" then
          log("trying to find credential using user info")
          authenticated_groups = find_claim(userinfo, authenticated_groups_claim)
          if authenticated_groups then
            log("authenticated groups claim found in user info")
          else
            log("authenticated groups claim was not found in user info")
          end
        end
      end

      if not authenticated_groups then
        log("authenticated groups claim was not found")
      else
        log("authenticated groups found '", authenticated_groups, "'")
        ctx.authenticated_groups = set.new(authenticated_groups)
      end
    end
  end

  -- here we replay token endpoint request response headers, if any
  replay_downstream_headers(args, downstream_headers, auth_method)

  -- proprietary token exchange
  local token_exchanged
  do
    local exchange_token_endpoint = args.get_conf_arg("token_exchange_endpoint")
    if exchange_token_endpoint then
      local error_status
      local opts = args.get_http_opts {
        method  = "POST",
        headers = {
          Authorization = "Bearer " .. tokens_encoded.access_token,
        },
      }

      if args.get_conf_arg("cache_token_exchange") then
        log("trying to exchange access token with caching enabled")
        token_exchanged, err, error_status = cache.token_exchange.load(
          tokens_encoded.access_token, exchange_token_endpoint, opts, ttl, true)

      else
        log("trying to exchange access token")
        token_exchanged, err, error_status = cache.token_exchange.load(
          tokens_encoded.access_token, exchange_token_endpoint, opts, ttl, false)
      end

      if not token_exchanged or error_status ~= 200 then
        if error_status == 401 then
          return unauthorized(ctx,
                              iss,
                              unauthorized_error_message,
                              err or "exchange token endpoint returned unauthorized",
                              session,
                              anonymous,
                              trusted_client)

        elseif error_status == 403 then
          return forbidden(ctx,
                           iss,
                           forbidden_error_message,
                           err or "exchange token endpoint returned forbidden",
                           session,
                           anonymous,
                           trusted_client)

        else
          if err then
            return unexpected(trusted_client, err)
          else
            return unexpected(trusted_client, "exchange token endpoint returned ", error_status or "unknown")
          end
        end

      else
        log("exchanged access token successfully")
      end
    end
  end

  log("setting upstream and downstream headers")
  do
    local upstream_headers_claims = args.get_conf_arg("upstream_headers_claims")
    local upstream_headers_names  = args.get_conf_arg("upstream_headers_names")
    if upstream_headers_claims and upstream_headers_names then
      for i, claim in ipairs(upstream_headers_claims) do
        claim = args.get_value(claim)
        if claim then
          local name = args.get_value(upstream_headers_names[i])
          if name then
            local value
            if type(token_introspected) == "table" then
              value = get_header_value(args.get_value(token_introspected[claim]))
            end

            if not value and type(jwt_token_introspected) == "table" then
              value = get_header_value(args.get_value(jwt_token_introspected[claim]))
            end

            if not value and type(tokens_encoded) == "table" then
              if decode_tokens and type(tokens_decoded) ~= "table" then
                decode_tokens = false
                tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
                if err then
                  log("error decoding tokens (", err, ")")
                end
              end

              if type(tokens_decoded) == "table" then
                if type(tokens_decoded.access_token) == "table" then
                  value = get_header_value(args.get_value(tokens_decoded.access_token.payload[claim]))
                end

                if not value and type(tokens_decoded.id_token) == "table" then
                  value = get_header_value(args.get_value(tokens_decoded.id_token.payload[claim]))
                end
              end
            end

            if not value and search_userinfo then
              if type(userinfo) ~= "table" and not userinfo_loaded then
                log("loading user info")
                if cache_userinfo then
                  userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, true)
                else
                  userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, false)
                end

                userinfo_loaded = true

                if userinfo then
                  log("user info loaded")
                elseif err then
                  log("user info could not be loaded (", err, ")")
                else
                  log("user info could not be loaded")
                end
              end

              if type(userinfo) == "table" then
                value = get_header_value(args.get_value(userinfo[claim]))
              end
            end

            if value then
              set_upstream_header(name, value)
            end
          end
        end
      end
    end

    local downstream_headers_claims = args.get_conf_arg("downstream_headers_claims")
    local downstream_headers_names  = args.get_conf_arg("downstream_headers_names")
    if downstream_headers_claims and downstream_headers_names then
      for i, claim in ipairs(downstream_headers_claims) do
        claim = args.get_value(claim)
        if claim then
          local name = args.get_value(downstream_headers_names[i])
          if name then
            local value
            if type(token_introspected) == "table" then
              value = get_header_value(args.get_value(token_introspected[claim]))
            end

            if not value and type(jwt_token_introspected) == "table" then
              value = get_header_value(args.get_value(jwt_token_introspected[claim]))
            end

            if not value and type(tokens_encoded) == "table" then
              if decode_tokens and type(tokens_decoded) ~= "table" then
                decode_tokens = false
                tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
                if err then
                  log("error decoding tokens (", err, ")")
                end
              end

              if type(tokens_decoded) == "table" then
                if type(tokens_decoded.access_token) == "table" then
                  value = get_header_value(args.get_value(tokens_decoded.access_token.payload[claim]))
                end

                if not value and type(tokens_decoded.id_token) == "table" then
                  value = get_header_value(args.get_value(tokens_decoded.id_token.payload[claim]))
                end
              end
            end

            if not value and search_userinfo then
              if type(userinfo) ~= "table" and not userinfo_loaded then
                log("loading user info")
                if cache_userinfo then
                  userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, true)
                else
                  userinfo, err = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, false)
                end

                userinfo_loaded = true

                if type(userinfo) == "table" then
                  log("user info loaded")
                elseif err then
                  log("user info could not be loaded (", err, ")")
                else
                  log("user info could not be loaded")
                end
              end

              if type(userinfo) == "table" then
                value = get_header_value(args.get_value(userinfo[claim]))
              end
            end

            if value then
              set_downstream_header(name, value)
            end
          end
        end
      end
    end

    -- full headers
    set_headers(args, "access_token",  token_exchanged or tokens_encoded.access_token)
    set_headers(args, "id_token",      tokens_encoded.id_token)
    set_headers(args, "refresh_token", tokens_encoded.refresh_token)
    set_headers(args, "introspection", token_introspected or jwt_token_introspected or function()
      return introspect_token(tokens_encoded.access_token, ttl)
    end)

    set_headers(args, "user_info", userinfo or function()
      if not userinfo_loaded then
        if cache_userinfo then
          userinfo = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, true)
        else
          userinfo = cache.userinfo.load(oic, tokens_encoded.access_token, ttl, false)
        end

        userinfo_loaded = true

        return userinfo
      end
    end)

    set_headers(args, "access_token_jwk", function()
      if decode_tokens and type(tokens_decoded) ~= "table" then
        decode_tokens = false
        tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
        if err then
          log("error decoding tokens (", err, ")")
        end
      end

      if type(tokens_decoded) == "table" then
        local access_token = tokens_decoded.access_token
        if type(access_token) == "table" and access_token.jwk then
          return access_token.jwk
        end
      end
    end)

    set_headers(args, "id_token_jwk", function()
      if decode_tokens and type(tokens_decoded) ~= "table" then
        decode_tokens = false
        tokens_decoded, err = oic.token:decode(tokens_encoded, { verify_signature = false })
        if err then
          log("error decoding tokens (", err, ")")
        end
      end

      if type(tokens_decoded) == "table" then
        local id_token = tokens_decoded.id_token
        if type(id_token) == "table" and id_token.jwk then
          return id_token.jwk
        end
      end
    end)

    -- session headers
    set_headers(args, "session_id", function()
      if session and session.id and session.encoder then
        return session.encoder.encode(session.id)
      end
    end)
  end


  if auth_methods.session then
    -- remove session cookie from the upstream request?
    log("starting session and hiding session cookie from upstream")
    session:hide()
    session:start()
    if session_regenerate then
      log("regenerating session identifier")
      session:regenerate()
    elseif session_modified then
      log("saving session")
      session:save()
    else
      log("closing session")
      session:close()
    end
  end

  -- login actions
  do
    local login_action = args.get_conf_arg("login_action")
    if login_action == "response" or login_action == "redirect" then
      local has_login_method

      local login_methods = args.get_conf_arg("login_methods", { "authorization_code" })
      for _, login_method in ipairs(login_methods) do
        if auth_method == login_method then
          has_login_method = true
          break
        end
      end

      if has_login_method then
        if login_action == "response" then
          local login_response = {}

          local login_tokens = args.get_conf_arg("login_tokens")
          if login_tokens then
            log("adding login tokens to response")
            local output_tokens
            local output_introspection
            for _, name in ipairs(login_tokens) do
              if name == "tokens" then
                output_tokens = true
                break
              elseif name == "introspection" then
                output_introspection = true
              end
            end

            local response
            if output_introspection then
              if token_introspected then
                response = token_introspected
              elseif jwt_token_introspected then
                response = jwt_token_introspected
              elseif output_tokens then
                response = tokens_encoded
              end

            elseif output_tokens then
              response = tokens_encoded
            end

            if response then
              login_response = response
            elseif tokens_encoded then
              for _, name in ipairs(login_tokens) do
                if tokens_encoded[name] then
                  login_response[name] = tokens_encoded[name]
                end
              end
            end
          end

          log("login with response login action")
          return success(args.get_value(login_response))

        elseif login_action == "redirect" then
          local login_redirect_uri = trusted_client.login_redirect_uri or
            dynamic_login_redirect_uri

          if login_redirect_uri then
            local u = { login_redirect_uri }
            local i = 2

            local login_tokens = args.get_conf_arg("login_tokens")
            if login_tokens then
              log("adding login tokens to redirect uri")

              local login_redirect_mode   = args.get_conf_arg("login_redirect_mode", "fragment")
              local redirect_params_added = false

              if login_redirect_mode == "query" then
                if find(u[1], "?", 1, true) then
                  redirect_params_added = true
                end

              else
                if find(u[1], "#", 1, true) then
                  redirect_params_added = true
                end
              end

              for _, name in ipairs(login_tokens) do
                local value
                if name == "tokens" then
                  value = tokens_encoded

                elseif name == "introspection" then
                  if token_introspected then
                    value = token_introspected
                  elseif jwt_token_introspected then
                    value = jwt_token_introspected
                  end

                else
                  value = tokens_encoded[name]
                end

                if value then
                  if type(value) == "table" then
                    value = json.encode(value)
                    if value then
                      value = base64url.encode(value)
                    end

                  else
                    value = tostring(value)
                  end

                  if not redirect_params_added then
                    if login_redirect_mode == "query" then
                      u[i] = "?"
                    else
                      u[i] = "#"
                    end

                    redirect_params_added = true
                  else
                    u[i] = "&"
                  end

                  u[i+1] = name
                  u[i+2] = "="
                  u[i+3] = value
                  i=i+4
                end
              end
            end

            no_cache_headers()

            log("login with redirect login action")
            return redirect(concat(u))

          else
            log.notice("login action was set to redirect but no login redirect uri was specified")
          end
        end
      end
    end
  end

  log("proxying to upstream")
end


return OICHandler
