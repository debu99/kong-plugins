local endpoints = require "kong.api.endpoints"


local kong               = kong
local credentials_schema = kong.db.basicauth_credentials.schema
local consumers_schema   = kong.db.consumers.schema

local enums              = require "kong.enterprise_edition.dao.enums"
local ee_api             = require "kong.enterprise_edition.api_helpers"
local ee_crud            = require "kong.enterprise_edition.crud_helpers"

return {
  ["/consumers/:consumers/basic-auth"] = {
    schema = credentials_schema,
    methods = {
      ---EE [[
      --Restrict endpoints from editing consumer.type or non-proxy consumers
      before = function (self)
        ee_api.routes_consumers_before(self, self.args.post)
      end,
      --]] EE
    },
  },
  ["/consumers/:consumers/basic-auth/:basicauth_credentials"] = {
    schema = credentials_schema,
    methods = {
      before = function(self, db)
        local consumer, _, err_t = endpoints.select_entity(self, db, consumers_schema)
        if err_t then
          return endpoints.handle_error(err_t)
        end
        if not consumer then
          return kong.response.exit(404, { message = "Not found" })
        end

        ---EE [[
        if consumer and consumer.type ~= enums.CONSUMERS.TYPE.PROXY then
          kong.response.exit(404, { message = "Not Found" })
        end
        --]] EE

        self.consumer = consumer

        if self.req.method ~= "PUT" then
          local cred, _, err_t = endpoints.select_entity(self, db, credentials_schema)
          if err_t then
            return endpoints.handle_error(err_t)
          end

          if not cred or cred.consumer.id ~= consumer.id then
            return kong.response.exit(404, { message = "Not found" })
          end

          self.basicauth_credential = cred
          self.params.basicauth_credentials = cred.id
        end
      end,
    },
  },
  ["/basic-auths"] = {
    schema = credentials_schema,
    methods = {
      ---EE [[
      -- post process credentials to filter out non-proxy consumers
      GET = function(self, db, helpers, parent)
        return parent(ee_crud.post_process_credential)
      end,
      --]] EE
    }
  },
  ["/basic-auths/:basicauth_credentials/consumer"] = {
    schema = consumers_schema,
    methods = {
      ---EE [[
      -- post process credentials to filter out non-proxy consumers
      GET = function(self, db, helpers, parent)
        local post_process = function(consumer)
          if consumer and consumer.type ~= enums.CONSUMERS.TYPE.PROXY then
            kong.response.exit(404, { message = "Not Found" })
          end
        end
        return parent(post_process)
      end
      --]] EE
    }
  },
}
