# Что проверено

Дата прогона на этой машине: 2026-11-09. Это не прод и не обещание, что плейбук уже стоит на сервере.

| Проверка | Результат |
| --- | --- |
| `bash scripts/ci-local.sh` | Прошёл: yamllint, shellcheck, ansible-lint (профиль дотянулся до production), `ansible-playbook --syntax-check`, юнит-тесты textfile и bootstrap, `promtool` из образа `prom/prometheus:v3.16.0` (`check config`, `check rules`, `test rules` — 22 правила), `amtool check-config`, `blackbox_exporter --config.check`, `docker compose config` |
| `docker compose up` на этой ВМ | Контейнеры поднялись. После правки healthcheck nginx стал `healthy`. Grafana, Prometheus, Alertmanager, node_exporter, blackbox — `healthy` |
| Авторизация прокси | `curl -k` без пароля: Grafana, Prometheus и Alertmanager отвечают **401**. С basic auth пользователя `monitoring`: **200**. `/healthz` без пароля отвечает `200` и телом `ok` — так и задумано |
| Страница входа Grafana | Через прокси пришла HTML-страница логина (в теле есть Grafana). Браузером не кликал: самоподписный сертификат и форма проверены curl, не глазами |
| Куда слушает хост | `ss`: только `127.0.0.1:8443`, `:8444`, `:8445`. `http://127.0.0.1:9090` с хоста не открывается |
| Scrape | Все job в Prometheus `up`. `probe_success` внутренних health — 1. `https://example.invalid/health` и `example.invalid:443` — 0 |
| node_exporter | С хоста видны ФС `ext4` на `/` и `/var/lib/docker`. Служебный FUSE в выгрузку не попал после исключения `fuse.*` |
| `for:` живых алертов | Не ждал 5–15 минут, пока `example.invalid` перейдёт из pending в firing. Условие `probe_success == 0` уже есть, порог по времени покрыт `promtool test rules` |
| DOCKER-USER на живом хосте | Не применялся. Скрипт гонялся только с `--dry-run` и с заведомо плохим CIDR |
| `ansible-playbook` без `--syntax-check` | Не запускался. Секреты на сервер не выписывались, systemd-таймеры не ставились |
| journald / настоящий restic | Не проверялись. Фикстуры JSON и `auth.log` — да |
| Две таблицы iptables на этой ВМ | У `iptables-legacy` политика FORWARD была DROP и не знала мост compose, из-за этого контейнеры не видели друг друга. Для проверки я выставил на ВМ `FORWARD ACCEPT`. В репозиторий это не входит: на обычном хосте Docker сидит на одном бэкенде iptables/nft. Это не доказательство DOCKER-USER |

Повторить локально:

```bash
bash scripts/ci-local.sh
bash scripts/bootstrap-local-secrets.sh
docker compose --env-file docker/secrets/compose.env -f docker/compose.yaml up -d
```

Пароли скрипт печатает только как пути. Не коммитьте `docker/secrets/` и `ansible/group_vars/all/vault.yml`.
