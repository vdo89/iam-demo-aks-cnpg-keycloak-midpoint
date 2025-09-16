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
