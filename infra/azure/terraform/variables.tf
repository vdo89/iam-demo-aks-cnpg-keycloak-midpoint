variable "location" {
  type        = string
  description = "Azure region"
  default     = "westeurope"
}

variable "prefix" {
  type        = string
  description = "Resource prefix (short, lowercase)"
  default     = "rwsdemo"
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
}
