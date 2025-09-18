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

variable "aks_default_node_vm_size" {
  type        = string
  description = "VM size for the default AKS node pool"
  default     = "Standard_D4s_v3"
}

variable "aks_default_node_count" {
  type        = number
  description = "Number of nodes in the default AKS node pool"
  default     = 3
}
