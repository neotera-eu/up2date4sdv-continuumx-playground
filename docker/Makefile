# ContinuumX playground helpers.
#
# make build              build all images
# make build cloud        build one service (mqtt-broker|cloud|edge|servicebus-demo)
# make run                start all + show connection info
# make run edge           start one or more services
# make down               stop containers
# make delete             remove containers (keep volumes and images)
# make prune              remove containers, volumes and project images
# make info               show SSH / URLs / MQTT info again
# make revert             restore /etc/hosts from /etc/hosts.backup

COMPOSE      ?= podman compose
COMPOSE_FILE ?= compose.yaml
export COMPOSE_FILE

SERVICES := mqtt-broker cloud edge servicebus-demo
ARGS := $(filter-out build run down delete prune info revert help,$(MAKECMDGOALS))

.PHONY: help build run down delete prune info revert $(SERVICES)

help:
	@echo "Targets:"
	@echo "  make build [service...]   Build images"
	@echo "  make run [service...]     Host prep + start stack (full run prints info)"
	@echo "  make down                 Stop containers"
	@echo "  make delete               Remove containers (keep volumes/images)"
	@echo "  make prune                Remove containers + volumes + project images"
	@echo "  make info                 Print connection info"
	@echo "  make revert               Restore /etc/hosts from /etc/hosts.backup"
	@echo ""
	@echo "Host prep (automatic on make run):"
	@echo "  - loads overlay + br_netfilter and sets bridge/inotify sysctls"
	@echo "  - warns on conflicting /etc/hosts names (cloud, u2deb-*, mqtt-broker)"
	@echo "    and can backup + replace with a clean file (make revert undoes it)"
	@echo "  Needs sudo or run0 once."
	@echo ""
	@echo "Services: $(SERVICES)"

$(SERVICES):
	@:

build:
ifeq ($(strip $(ARGS)),)
	$(COMPOSE) build
else
	$(COMPOSE) build $(ARGS)
endif

run:
	@bash ./host-prep.sh
ifeq ($(strip $(ARGS)),)
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory info
else
	$(COMPOSE) up -d $(ARGS)
endif

down:
	$(COMPOSE) stop

delete:
	$(COMPOSE) down --remove-orphans

prune:
	$(COMPOSE) down -v --rmi local --remove-orphans

info:
	@bash ./print-info.sh

revert:
	@bash ./host-revert.sh
