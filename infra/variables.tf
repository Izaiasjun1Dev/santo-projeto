variable "regiao" {
  type = string
}

variable "projeto" {
  type = string
}

variable "ambiente" {
  type = string
}

variable "cidr_vpc" {
  type = string
}

variable "zonas" {
  type = list(string)
}

variable "repositorios" {
  type = list(string)
}

variable "tipo_instancia" {
  type = string
}

variable "quantidade_nos" {
  type = number
}
