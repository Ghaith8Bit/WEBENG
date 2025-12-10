include .env
export

up:
	docker-compose up -d

down:
	docker-compose down

restart:
	docker-compose down
	docker-compose up -d

logs:
	docker-compose logs -f

ps:
	docker-compose ps

clean:
	docker-compose down -v

check:
	docker exec -it service_db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c "\dt"

health:
	docker exec -it service_db pg_isready -U $(POSTGRES_USER)

bash-db:
	docker exec -it service_db bash

bash-pgadmin:
	docker exec -it service_pgadmin bash
