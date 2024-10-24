locals {
  tags                         = { azd-env-name : var.environment_name }
  sha                          = base64encode(sha256("${var.environment_name}${var.location}${data.azurerm_client_config.current.subscription_id}"))
  resource_token               = substr(replace(lower(local.sha), "[^A-Za-z0-9_]", ""), 0, 13)
  cosmos_connection_string_key = "AZURE-COSMOS-CONNECTION-STRING"
  enable_telemetry             = true
}
# ------------------------------------------------------------------------------------------------------
# Deploy resource Group
# ------------------------------------------------------------------------------------------------------
resource "azurecaf_name" "rg_name" {
  name          = var.environment_name
  resource_type = "azurerm_resource_group"
  random_length = 0
  clean_input   = true
}

resource "azurerm_resource_group" "rg" {
  name     = azurecaf_name.rg_name.result
  location = var.location

  tags = local.tags
}

# ------------------------------------------------------------------------------------------------------
# Deploy application insights
# ------------------------------------------------------------------------------------------------------
module "applicationinsights" {
  source  = "Azure/avm-res-insights-component/azurerm"
  version = "0.1.3"
  enable_telemetry    = local.enable_telemetry
  location            = var.location
  name                = "appi-${local.resource_token}"
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = module.loganalytics.resource_id
  tags                = azurerm_resource_group.rg.tags
}

module "dashboard" {
  source  = "Azure/avm-res-portal-dashboard/azurerm"
  version = "0.1.0"
  enable_telemetry        = local.enable_telemetry
  location                = var.location
  name                    = "dash-${local.resource_token}"
  resource_group_name     = azurerm_resource_group.rg.name
  template_file_path      = "./dashboard.tpl"
  template_file_variables = {
    subscriptions_id = data.azurerm_client_config.current.subscription_id
    resource_group_name = azurerm_resource_group.rg.name
    applicationinsights_name = module.applicationinsights.name
  }
  tags                = azurerm_resource_group.rg.tags
}

# ------------------------------------------------------------------------------------------------------
# Deploy log analytics
# ------------------------------------------------------------------------------------------------------
module "loganalytics" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "0.4.1"
  enable_telemetry                          = local.enable_telemetry
  location                                  = var.location
  resource_group_name                       = azurerm_resource_group.rg.name
  name                                      = "log-${local.resource_token}"
  tags                                      = azurerm_resource_group.rg.tags
  log_analytics_workspace_retention_in_days = 30
  log_analytics_workspace_sku               = "PerGB2018"
}

# ------------------------------------------------------------------------------------------------------
# Deploy key vault
# ------------------------------------------------------------------------------------------------------
module "keyvault" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.9.1"
  enable_telemetry               = local.enable_telemetry
  name                           = "kv-${local.resource_token}"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.rg.name
  tags                           = azurerm_resource_group.rg.tags
  tenant_id                      = data.azurerm_client_config.current.tenant_id
  public_network_access_enabled  = true
  sku_name                       = "standard"
  purge_protection_enabled       = false

  secrets = {
    cosmos_secret = {
      name = local.cosmos_connection_string_key
    }
  }
  secrets_value = {
    cosmos_secret = module.cosmos.cosmosdb_mongodb_connection_strings.primary_mongodb_connection_string
  }
  role_assignments = {
    user = {
      role_definition_id_or_name = "Key Vault Administrator"
      principal_id               = var.principal_id
    }
    api = {
      role_definition_id_or_name = "Key Vault Administrator"
      principal_id               = module.api.identity_principal_id
    }
  }
  wait_for_rbac_before_secret_operations = {
    create = "60s"
  }
  network_acls = null
}

# ------------------------------------------------------------------------------------------------------
# Deploy cosmos
# ------------------------------------------------------------------------------------------------------
module "cosmos" {
  source  = "Azure/avm-res-documentdb-databaseaccount/azurerm"
  version = "0.3.0"
  enable_telemetry    = local.enable_telemetry
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  name                = "cosmos-${local.resource_token}"
  tags                = azurerm_resource_group.rg.tags
  mongo_databases = {
    database_collection = {
      name       = "Todo"
      collections = {
        "collection1" = {
          name                = "TodoList"
          shard_key           = "_id"
          index = {
            keys   = ["_id"]
            unique = true
          }
        }
        "collection2" = {
          name                = "TodoItem"
          shard_key           = "_id"
          index = {
            keys   = ["_id"]
            unique = true
          }
        }
      }
    }
  }
  capabilities = [
    {
      name = "EnableServerless"
    }
  ]
  consistency_policy = {
    consistency_level = "Session"
  }
  backup = {
    type                = "Periodic"
    storage_redundancy  = "Geo"
    interval_in_minutes = 240
    retention_in_hours  = 8
  }
  geo_locations = [
    {
      location          = azurerm_resource_group.rg.location
      failover_priority = 0
      zone_redundant    = false
    }
  ]
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service plan
# ------------------------------------------------------------------------------------------------------
module "appserviceplan" {
  source  = "Azure/avm-res-web-serverfarm/azurerm"
  version = "0.2.0"
  enable_telemetry    = local.enable_telemetry
  name                = "plan-${local.resource_token}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  os_type             = "Linux"
  tags                = azurerm_resource_group.rg.tags
  sku_name            = "B3"
  worker_count           = 1
  zone_balancing_enabled = false
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service web app
# ------------------------------------------------------------------------------------------------------
module "web" {
  source              = "Azure/avm-res-web-site/azurerm"
  version             = "0.10.0"
  enable_telemetry    = local.enable_telemetry
  name                = "app-web-${local.resource_token}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = merge(local.tags, { azd-service-name : "web" })
  kind                = "webapp"
  os_type             = "Linux"
  service_plan_resource_id = module.appserviceplan.resource_id
  site_config         = {
    always_on         = true
    use_32_bit_worker = false
    ftps_state        = "FtpsOnly"
    health_check_path = ""
    app_command_line  = "pm2 serve /home/site/wwwroot --no-daemon --spa"
    application_stack = {
      node = {
        current_stack = "node"
        node_version  = "20-lts"
      }
    }
    app_settings        = {
      "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
    }
    logs = {
      app_service_logs = {
        http_logs = {
          config1 = {
            file_system = {
              retention_in_days = 1
              retention_in_mb   = 35
            }
          }
        }
        application_logs = {
          config1 = {
            file_system_level = "Verbose"
          }
        }
        detailed_error_messages = true
        failed_request_tracing  = true
      }
    }
  }
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service api
# ------------------------------------------------------------------------------------------------------
module "api" {
  source              = "Azure/avm-res-web-site/azurerm"
  version             = "0.10.0"
  enable_telemetry    = local.enable_telemetry
  name                = "app-api-${local.resource_token}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = merge(local.tags, { "azd-service-name" : "api" })
  kind                = "webapp" 
  os_type             = "Linux"
  service_plan_resource_id = module.appserviceplan.resource_id
  https_only          = true
  managed_identities  = {
    system_assigned   = true
  }
  site_config         = {
    always_on         = true
    use_32_bit_worker = false
    ftps_state        = "FtpsOnly"
    health_check_path = ""
    app_command_line  = ""
    application_stack = {
      node = {
        current_stack = "node"
        node_version  = "20-lts"
      }
    }
    app_settings        = {
      "AZURE_COSMOS_CONNECTION_STRING_KEY"    = local.cosmos_connection_string_key
      "AZURE_COSMOS_DATABASE_NAME"            = keys(module.cosmos.mongo_databases)[0]
      "SCM_DO_BUILD_DURING_DEPLOYMENT"        = "true"
      "AZURE_KEY_VAULT_ENDPOINT"              = module.keyvault.uri
      "APPLICATIONINSIGHTS_CONNECTION_STRING" = module.applicationinsights.connection_string
      "API_ALLOW_ORIGINS"                     = "https://app-web-${local.resource_token}.azurewebsites.net"
    }
    logs = {
      app_service_logs = {
        http_logs = {
          config1 = {
            file_system = {
              retention_in_days = 1
              retention_in_mb   = 35
            }
          }
        }
        application_logs = {
          config1 = {
            file_system_level = "Verbose"
          }
        }
        detailed_error_messages = true
        failed_request_tracing  = true
      }
    }    
  }
}

# Workaround: set API_ALLOW_ORIGINS to the web app URI
resource "null_resource" "api_set_allow_origins" {
  triggers = {
    web_uri = module.web.resource_uri
  }

  provisioner "local-exec" {
    command = "az webapp config appsettings set --resource-group ${azurerm_resource_group.rg.name} --name ${module.api.name} --settings API_ALLOW_ORIGINS=https://${module.web.resource_uri}"
  }
}

# This is a temporary solution until the azurerm provider supports the basicPublishingCredentialsPolicies resource type
resource "null_resource" "webapp_basic_auth_disable" {
  triggers = {
    account = module.web.name
  }
 
  provisioner "local-exec" {
    command = "az resource update --resource-group ${azurerm_resource_group.rg.name} --name ftp --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies --parent sites/${module.web.name} --set properties.allow=false && az resource update --resource-group ${azurerm_resource_group.rg.name} --name scm --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies --parent sites/${module.web.name} --set properties.allow=false"
  }
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service apim
# ------------------------------------------------------------------------------------------------------
module "apim" { 
  count                     = var.useAPIM ? 1 : 0
  source                    = "./modules/apim"
  name                      = "apim-${local.resource_token}"
  location                  = var.location
  rg_name                   = azurerm_resource_group.rg.name
  tags                      = merge(local.tags, { "azd-service-name" : var.environment_name })
  application_insights_name = module.applicationinsights.name
  sku                       = var.apimSKU
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service apim-api
# ------------------------------------------------------------------------------------------------------
module "apimApi" { 
  count                    = var.useAPIM ? 1 : 0
  source                   = "./modules/apim-api"
  name                     = module.apim[0].APIM_SERVICE_NAME
  rg_name                  = azurerm_resource_group.rg.name
  web_front_end_url        = module.web.resource_uri
  api_management_logger_id = module.apim[0].API_MANAGEMENT_LOGGER_ID
  api_name                 = "todo-api"
  api_display_name         = "Simple Todo API"
  api_path                 = "todo"
  api_backend_url          = module.api.resource_uri
}
