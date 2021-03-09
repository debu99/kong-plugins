local typedefs = require "kong.db.schema.typedefs"
local null = ngx.null

local function validate_flows(config)
  if config.enable_authorization_code
  or config.enable_implicit_grant
  or config.enable_client_credentials
  or config.enable_password_grant
  then
    return true
  end

  return nil, "at least one of these fields must be true: enable_authorization_code, enable_implicit_grant, enable_client_credentials, enable_password_grant"
end


return {
  name = "application-registration",
  fields = {
    { consumer = typedefs.no_consumer },
    { service = { type = "foreign", reference = "services", ne = null, on_delete = "cascade" }, },
    { route = typedefs.no_route },
    { run_on = typedefs.run_on_first },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { scopes = { type = "array", elements = { type = "string" }, }, },
          { mandatory_scope = { type = "boolean", default = false, required = true }, },
          { display_name = { type = "string", unique = true, required = true }, },
          { description = { type = "string", unique = true }, },
          { auto_approve = { type = "boolean", required = true, default = false }, },
          { provision_key = { type = "string", unique = true, auto = true, required = true }, },
          { token_expiration = { type = "number", default = 7200, required = true }, },
          { enable_authorization_code = { type = "boolean", default = false, required = true }, },
          { enable_implicit_grant = { type = "boolean", default = false, required = true }, },
          { enable_client_credentials = { type = "boolean", default = false, required = true }, },
          { enable_password_grant = { type = "boolean", default = false, required = true }, },
          { auth_header_name = { type = "string", default = "authorization" }, },
          { refresh_token_ttl = { type = "number", default = 1209600, required = true }, },
        },
        custom_validator = validate_flows,
        entity_checks = {
          { conditional = {
              if_field = "mandatory_scope",
              if_match = { eq = true },
              then_field = "scopes",
              then_match = { required = true },
          }, },
        },
      }
    }
  },
}
