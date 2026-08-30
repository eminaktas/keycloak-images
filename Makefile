SHELL := /usr/bin/env bash

STREAM ?= 26.7
ARCH ?= x86_64
OUTPUT_DIR := _output/$(STREAM)
VERSION := $(shell jq -r --arg track "$(STREAM)" '.streams[] | select(.track == $$track) | .version' config/versions.json)
REVISION := $(shell jq -r --arg track "$(STREAM)" '.streams[] | select(.track == $$track) | .revision' config/versions.json)
RESOURCES_VERSION := $(shell jq -r --arg track "$(STREAM)" '.streams[] | select(.track == $$track) | .resourcesVersion' config/versions.json)
IMMUTABLE_TAG := $(VERSION)-r$(REVISION)
SERVER_REF ?=

.DEFAULT_GOAL := help

.PHONY: help validate render keys package packages images image-server image-operator smoke pair-test clean

help:
	@echo "Keycloak image build targets"
	@echo ""
	@echo "  make validate                         Validate and render all active tracks"
	@echo "  make render STREAM=26.7               Render one track"
	@echo "  make packages STREAM=26.7 ARCH=x86_64 Build both APKs in one Melange build"
	@echo "  make images STREAM=26.7 ARCH=x86_64   Build both OCI image tarballs"
	@echo "  make smoke SERVER_IMAGE=<ref>         Smoke-test a server image"
	@echo "  make pair-test SERVER_IMAGE=<ref> OPERATOR_IMAGE=<ref>"

validate:
	./hack/validate.sh

render:
	./hack/render.sh "$(STREAM)" "$(SERVER_REF)"

keys: render
	@if [[ ! -f "$(OUTPUT_DIR)/melange.rsa" ]]; then melange keygen "$(OUTPUT_DIR)/melange.rsa"; fi

packages: package

package: keys
	melange build "$(OUTPUT_DIR)/keycloak.melange.yaml" \
		--arch "$(ARCH)" \
		--out-dir "$(OUTPUT_DIR)/packages" \
		--signing-key "$(OUTPUT_DIR)/melange.rsa"

images: image-server image-operator

image-server: packages
	apko build "$(OUTPUT_DIR)/keycloak.apko.yaml" \
		"keycloak-images/keycloak:$(IMMUTABLE_TAG)" "$(OUTPUT_DIR)/keycloak.tar" \
		--arch "$(ARCH)"

image-operator: packages
	apko build "$(OUTPUT_DIR)/keycloak-operator.apko.yaml" \
		"keycloak-images/keycloak-operator:$(IMMUTABLE_TAG)" "$(OUTPUT_DIR)/keycloak-operator.tar" \
		--arch "$(ARCH)"

smoke:
	@test -n "$(SERVER_IMAGE)" || { echo "SERVER_IMAGE is required" >&2; exit 2; }
	./hack/smoke-server.sh "$(SERVER_IMAGE)"

pair-test:
	@test -n "$(SERVER_IMAGE)" || { echo "SERVER_IMAGE is required" >&2; exit 2; }
	@test -n "$(OPERATOR_IMAGE)" || { echo "OPERATOR_IMAGE is required" >&2; exit 2; }
	./hack/test-pair.sh "$(SERVER_IMAGE)" "$(OPERATOR_IMAGE)" "$(RESOURCES_VERSION)"

clean:
	rm -rf _output
