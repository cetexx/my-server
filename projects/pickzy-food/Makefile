STACK   := pickzy-food
COMPOSE := docker-compose.yml
API     := $(STACK)_api

-include .env
export

# --- Deploy ---

.PHONY: deploy
deploy: pull ## Deploy/update stack
	docker stack deploy -c $(COMPOSE) $(STACK) --with-registry-auth

.PHONY: pull
pull: ## Pull latest images
	docker pull ghcr.io/pickzy-app/food-api:$(IMAGE_TAG)
	docker pull ghcr.io/pickzy-app/food-scraper:$(IMAGE_TAG)
	docker pull ghcr.io/pickzy-app/food-landing:$(IMAGE_TAG)

.PHONY: remove
remove: ## Remove stack
	docker stack rm $(STACK)

# --- Operations ---

.PHONY: migrate
migrate: ## Run database migrations
	docker exec $$(docker ps -qf name=$(API) -f status=running | head -1) \
		php artisan migrate --force --no-interaction

.PHONY: seed
seed: ## Run database seeders
	docker exec $$(docker ps -qf name=$(API) -f status=running | head -1) \
		php artisan db:seed --force --no-interaction

.PHONY: cache
cache: ## Clear and rebuild caches
	docker exec $$(docker ps -qf name=$(API) -f status=running | head -1) \
		sh -c "php artisan config:cache && php artisan route:cache && php artisan view:cache"

.PHONY: tinker
tinker: ## Open Laravel tinker
	docker exec -it $$(docker ps -qf name=$(API) -f status=running | head -1) \
		php artisan tinker

.PHONY: exec
exec: ## Run command in API container (usage: make exec cmd="php artisan ...")
	docker exec $$(docker ps -qf name=$(API) -f status=running | head -1) $(cmd)

# --- Monitoring ---

.PHONY: status
status: ## Show stack services
	docker stack services $(STACK)

.PHONY: ps
ps: ## Show running containers
	docker stack ps $(STACK) --no-trunc

.PHONY: logs
logs: ## API logs (usage: make logs or make logs svc=scraper)
	docker service logs -f --tail 100 $(STACK)_$(or $(svc),api)

# --- Help ---

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
