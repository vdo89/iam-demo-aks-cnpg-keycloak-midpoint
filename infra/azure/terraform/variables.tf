variable "location" {
  type        = string
  description = "Azure region"
  default     = "westeurope"

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "Location cannot be empty. Set it to a valid Azure region such as 'westeurope'."
  }
}

variable "prefix" {
  type        = string
  description = "Resource prefix (short, lowercase)"
  default     = "rwsdemo"

  validation {
    condition     = can(regex("^[a-z0-9]{1,16}$", var.prefix))
    error_message = "Prefix must be 1-16 lowercase alphanumeric characters so the generated storage account name remains under Azure's 24 character limit."
  }
}

variable "create_resource_group" {
  type        = bool
  description = "Whether to create the resource group automatically. Set to false to reuse an existing group."
  default     = true
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to create or reuse. Leave empty to default to \"<prefix>-rg\"."
  default     = ""

  validation {
    condition     = var.resource_group_name == "" || length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name cannot be only whitespace. Leave it empty to use the default or provide a valid name."
  }
}

variable "aks_default_node_vm_size" {
  type        = string
  description = "VM size for the default AKS node pool"
  default     = "Standard_B2ms"
}

variable "aks_default_node_count" {
  type        = number
  description = "Number of nodes in the default AKS node pool"
  default     = 1

  validation {
    condition     = var.aks_default_node_count >= 1
    error_message = "AKS must run at least one system node. Increase vCPU quota before raising the count beyond the default when using a free subscription."
  }
}

variable "aks_default_node_max_surge" {
  type        = string
  description = "Maximum number or percentage of surge nodes to add during upgrades of the default node pool. Use \"0\" to disable surge nodes when regional vCPU quota is tight; AKS will then rotate the single system node sequentially using its default max_unavailable budget."
  default     = "0"

  validation {
    condition     = can(regex("^[0-9]+%?$", trimspace(var.aks_default_node_max_surge)))
    error_message = "aks_default_node_max_surge must be an integer (e.g. \"1\") or percentage (e.g. \"33%\"). Use \"0\" to avoid extra surge nodes on constrained subscriptions."
  }
}

variable "aks_sku_tier" {
  type        = string
  description = "AKS control plane SKU tier. Keep \"Free\" to stay within the AKS free tier limits; switch to \"Paid\" only when you need the Uptime SLA."
  default     = "Free"

  validation {
    condition     = contains(["Free", "Paid"], var.aks_sku_tier)
    error_message = "aks_sku_tier must be either \"Free\" or \"Paid\"."
  }
}
