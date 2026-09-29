# Usage:
#   make plan ENV=dev
#   make apply ENV=prod
#   make fmt
#   make validate ENV=dev
ENV ?= dev
DIR := environments/$(ENV)

.PHONY: init plan apply destroy output refresh
init plan apply destroy output refresh:
	@cd $(DIR) && ./tf.sh $@

.PHONY: fmt
fmt:
	terraform fmt -recursive

.PHONY: validate
validate:
	@cd $(DIR) && ./tf.sh init -backend=false -input=false >/dev/null && ./tf.sh validate
