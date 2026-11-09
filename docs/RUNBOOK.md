# Runbook алертов

Имена алертов совпадают с `monitoring/prometheus/rules/alerts.yml`. Почему порог такой — в `docs/ARCHITECTURE.md`, раздел «Пороги». Здесь: что проверить и как не сделать хуже.

Общее перед любой правкой на хосте: вторая сессия SSH уже открыта, команда одна, есть способ откатиться. Не начинать с массовой чистки iptables и не открывать порты экспортёров наружу.

<a id="exporterdown"></a>
## ExporterDown

**Что значит.** Prometheus 5 минут не может снять `up` с job `node`, `blackbox`, `prometheus` или `alertmanager`. Это процесс экспортёра или сам Prometheus, не «сайт лежит». У blackbox `up{job="blackbox-http"}` в этот алерт не входит: недоступная цель — это `HttpEndpointDown`, а мёртвый blackbox — job `blackbox`.

**Как проверить.**

```bash
docker ps --filter name=monitoring-
docker logs --tail 50 monitoring-prometheus
docker logs --tail 50 monitoring-node-exporter
```

С хоста, не публикуя порт: `docker exec monitoring-prometheus wget -qO- http://node-exporter:9100/metrics | head`.

**Как исправить.** Поднять конкретный контейнер (`docker start` / `docker compose up -d` из `/opt/monitoring-stack/docker`). Если падает node_exporter — смотреть, не отвалился ли mount `/proc`. Не добавлять `privileged: true`.

**Не делать.** Не вешать `ports: 9100:9100` на `0.0.0.0`, чтобы «открыть метрики с ноутбука».

<a id="monitoringcomponentunhealthy"></a>
## MonitoringComponentUnhealthy

**Что значит.** Blackbox из той же docker-сети не получил HTTP 200 с `grafana:3000/api/health`, `prometheus:9090/-/healthy` или `alertmanager:9093/-/healthy`. Снаружи это не видно: UI закрыт прокси.

**Как проверить.** В лейбле `instance` уже есть URL. Повторить запрос из сети стека:

```bash
docker exec monitoring-blackbox-exporter wget -qS -O /dev/null http://grafana:3000/api/health
```

Если в образе нет wget, тот же URL через `docker exec monitoring-prometheus wget`.

**Как исправить.** Логи контейнера из `instance`. Частый случай Grafana — база не стартовала из-за прав на volume (uid 472) или пустого пароля, которого compose без `GRAFANA_ADMIN_PASSWORD` не примет. Пароль не печатать в тикет.

**Не делать.** Не включать анонимный доступ, чтобы проба стала зелёной.

<a id="diskspacelow"></a>
## DiskSpaceLow

**Что значит.** На ФС, которая не tmpfs/overlay/squashfs/aufs/devtmpfs/ramfs, свободно меньше 15% и ещё не меньше 5%, и это держится 15 минут. Точка монтирования — в лейбле.

**Как проверить.**

```bash
df -h
df -i
docker system df
du -xh --max-depth=1 / | sort -h
```

Сверить, что в алерте не overlay. Посмотреть, не растёт ли каталог restic или логи Docker (`max-size` в compose уже 10 МБ × 3).

**Как исправить.** Удалять то, что понятно: старые образы `docker image prune` только после того, как ясно, что они не нужны; ротация логов. Расширение диска — отдельное изменение с планом отката. Если это том с `/srv/app/data` из репозитория backup, не трогать репозиторий restic как «просто большой каталог».

**Не делать.** `rm -rf` по догадке, `chmod -R 777`, отключение алерта.

<a id="diskspacecritical"></a>
## DiskSpaceCritical

**Что значит.** Свободно меньше 5% дольше 5 минут. Warning в Alertmanager должен быть подавлен inhibit, в Prometheus оба правила могут быть активны.

**Как проверить.** То же, что для DiskSpaceLow, плюс кто пишет прямо сейчас: `iotop` или `du` повторно через минуту. Пять минут — короткое окно; если место кончилось быстрее, алерт уже опоздал, смотреть `dmesg` на ENOSPC.

**Как исправить.** Освободить место точечно. Если ФС уже ro, это следующий алерт, не «ещё чуть-чуть почистить».

**Не делать.** Не запускать `restic forget --prune` на хосте приложения. В связанном репозитории prune только с admin-хоста.

<a id="diskinodeslow"></a>
## DiskInodesLow

**Что значит.** Свободных inode меньше 10% дольше 15 минут. `df -h` при этом может быть спокойным.

**Как проверить.** `df -i` и поиск каталогов с кучей мелких файлов (`find <mount> -xdev -printf '%h\n' | sort | uniq -c | sort -nr | head`).

**Как исправить.** Удалять мелкий мусор (кэши, сессии, старые сокеты в `/tmp`, если это не чужое). На некоторых ФС inode задаются при mkfs и не лечатся удалением больших файлов.

**Не делать.** Не пересоздавать ФС в инциденте.

<a id="filesystemreadonly"></a>
## FilesystemReadOnly

**Что значит.** `node_filesystem_readonly == 1` дольше 5 минут на «настоящей» ФС. Часто ядро ушло в ro после ошибок диска.

**Как проверить.** `mount | grep <mountpoint>`, `dmesg -T | tail`, `journalctl -k -n 50`. Есть ли I/O errors.

**Как исправить.** Если это ошибка диска — не remount rw вслепую поверх сыплющегося носителя. Сначала копия того, что ещё читается, и план замены диска. Плановый ro (например, отдельный том) — поправить алерт фильтром, а не игнорировать все ro.

**Не делать.** `mount -o remount,rw` как первый шаг на ФС с ошибками.

<a id="httpendpointdown"></a>
## HttpEndpointDown

**Что значит.** Модуль `http_2xx` пять минут не получает ответ 200 с цели из file_sd. Редиректы не считаются успехом. TLS проверяется по-настоящему. В примере цель `https://example.invalid/health`: алерт будет гореть, пока цель не заменят. Это ожидаемо.

**Как проверить.** Лейбл `instance`. С хоста blackbox, не со своего ноутбука: сеть и DNS другие.

```bash
docker exec monitoring-blackbox-exporter wget -qS -O /dev/null https://example.invalid/health
```

Подставить свою цель. Код ответа, таймаут или ошибка TLS — разные причины.

**Как исправить.** Чинить цель или, если URL в file_sd ошибочный, поправить `monitoring_http_targets` и прогнать плейбук. Файл на хосте: `/opt/monitoring-stack/monitoring/prometheus/file_sd/http_targets.yml`, затем `docker kill -s HUP` не используется: lifecycle API выключен, нужен перезапуск контейнера Prometheus или `docker compose up -d`.

**Не делать.** Не подменять цель на заведомо живой чужой URL, чтобы закрыть алерт. Не включать `follow_redirects` и `insecure_skip_verify` в инциденте.

<a id="tlscertificateexpiressoon"></a>
## TlsCertificateExpiresSoon

**Что значит.** До `probe_ssl_earliest_cert_expiry` меньше 14 дней и не меньше 3, и это держится час. Для сертификата на 90 дней с автопродлением около 30-го дня это уже «продление не сработало». Для годового ручного сертификата порог, скорее всего, мал — его меняют заранее, не во время ночной страницы.

**Как проверить.**

```bash
echo | openssl s_client -connect example.invalid:443 -servername example.invalid 2>/dev/null | openssl x509 -noout -dates -issuer
```

Адрес взять из `instance`. Сравнить с тем, какой сертификат должен быть (свой УЦ, Let's Encrypt, самоподписный прокси `monitoring.example`).

**Как исправить.** Штатное продление. Для прокси этого стека: удалить `server.crt` и `server.key` в каталоге секретов и перевыпустить (bootstrap или задача Ansible с `creates`). Помнить, что клиенты с запиненным старым сертификатом отвалятся. 90 дней — срок лабораторного сертификата.

**Не делать.** Не ставить `insecure_skip_verify`, не отодвигать системные часы.

<a id="tlscertificateexpirescriticallysoon"></a>
## TlsCertificateExpiresCriticallySoon

**Что значит.** Меньше 3 дней. Warning по тому же `instance` inhibit должен скрыть. Трёх дней не хватает на длинные выходные без человека — если так вышло, менять сертификат сейчас, а не «в понедельник».

**Как проверить и исправить.** Как у warning, только без откладывания. Проверить, что новый сертификат виден тем же `openssl s_client`, и что blackbox целится в тот же адрес.

**Не делать.** Не выключать HTTPS на сервисе, чтобы алерт пропал.

<a id="tlsprobefailed"></a>
## TlsProbeFailed

**Что значит.** TCP+TLS проба не успешна 5 минут. Срока сертификата в этом случае нет: алерт истечения не заменяет этот. В примере `example.invalid:443` падает всегда.

**Как проверить.** `openssl s_client` до адреса из `instance`. Отличить «нет маршрута», «соединение сброшено» и «сертификат отвергнут».

**Как исправить.** Сеть до цели, SNI, неверный порт в file_sd. Если сертификат просрочен, клиент с проверкой тоже не подключится — это не повод отключать проверку в модуле.

**Не делать.** Не переключать модуль на `tcp_connect` без TLS, чтобы проба стала зелёной.

<a id="resticsnapshotolderthanrpo"></a>
## ResticSnapshotOlderThanRPO

**Что значит.** `restic_snapshot_age_seconds` больше порога, который записал скрипт: RPO (по умолчанию 4 часа, как `restic_rpo_hours` в репозитории backup) плюс grace (по умолчанию 1 час, не измерен). Условие держится 15 минут — один лишний цикл таймера. Юнит `restic-textfile.service` при этом тоже падает с кодом 1, хотя метрика `restic_snapshot_check_success` равна 1: измерение удалось, бэкап старый.

**Как проверить.**

```bash
systemctl status restic-textfile.service --no-pager
journalctl -u restic-textfile.service -n 30 --no-pager
# на хосте, где стоит роль backup:
systemctl status app-backup.timer --no-pager
sudo -u restic-backup restic snapshots --repo /var/backups/restic-repo --password-file /etc/restic/backup.pass
```

Путь репозитория взять из `/etc/monitoring/restic-textfile.env`, не из этого файла.

**Как исправить.** Почему не прошёл backup: таймер, место, сеть до S3, хук дампа. Чинить причину и дождаться нового снапшота. Grace менять только если бэкап стабильно длиннее или короче часа, и записать, откуда новая цифра.

**Не делать.** Не удалять репозиторий. Не запускать `forget --prune` с хоста приложения. Не править метрику руками, чтобы алерт погас.

<a id="resticsnapshotcheckfailed"></a>
## ResticSnapshotCheckFailed

**Что значит.** Скрипт не смог измерить возраст: нет restic, нет прав на пароль, пустой список снапшотов, репозиторий не открылся, часы уехали больше чем на 5 минут. Ряда `restic_snapshot_age_seconds` нет. Код выхода 1.

**Как проверить.** Журнал юнита, затем вручную от того же пользователя:

```bash
sudo -u restic-backup test -r /etc/restic/backup.pass && echo readable || echo not-readable
```

Не печатать содержимое файла пароля.

**Как исправить.** Права 0640 и владелец, как их оставила роль backup. Бинарник restic в PATH юнита (юнит не имеет лишнего PATH). Пустой репозиторий — это ещё не сделанный первый backup, а не «поменять порог».

**Не делать.** `chmod 644` на `backup.pass`.

<a id="restictextfilestale"></a>
## ResticTextfileStale

**Что значит.** Файл `restic_snapshot.prom` не менялся больше 30 минут (таймер — 15). Возраст в Prometheus мог застыть на хорошем значении.

**Как проверить.** `stat /var/lib/node_exporter/textfile/restic_snapshot.prom`, `systemctl status restic-textfile.timer`. Жив ли node_exporter и видит ли он файл: в метриках есть `node_textfile_mtime_seconds`.

**Как исправить.** Запустить сервис вручную `systemctl start restic-textfile.service` и прочитать ошибку. Часто это ProtectSystem/права на каталог или отсутствие пользователя.

**Не делать.** Не обновлять mtime через `touch`: алерт погаснет, бэкап не появится.

<a id="resticmetricsabsent"></a>
## ResticMetricsAbsent

**Что значит.** Ряда `restic_snapshot_check_success` нет 30 минут. Таймер не включён (нет пользователя `restic-backup`), файл не создан или node_exporter его не читает. Если экспортер сам лежит, одновременно будет ExporterDown.

**Как проверить.** `systemctl list-timers | grep restic` и каталог textfile. Роль пишет в лог Ansible, что пользователь не найден и таймер не включён.

**Как исправить.** Поставить пользователя так, как это делает роль backup, либо задать `monitoring_restic_user` и прогнать плейбук. Если restic на этом хосте не нужен — удалить правило из файла правил и заново прогнать `promtool test rules`, а не оставлять вечный critical.

**Не делать.** Не писать руками `.prom` с `success 1` и нулевым возрастом.

<a id="sshauthfailureshigh"></a>
## SshAuthFailuresHigh

**Что значит.** Больше 20 неудачных аутентификаций в окне скрипта (по умолчанию 15 минут), и gauge держится таким 15 минут. Это warning. Порог — эвристика. На хосте с ключами и `PasswordAuthentication no` так выглядит сканер или сломанный клиент. На хосте в интернете фон может быть выше.

**Как проверить.** Источник в лейбле `source` (`journal`, `file`, `authlog`, `secure`).

```bash
journalctl _COMM=sshd --since "20 min ago" --no-pager | tail
# или
sudo tail -n 200 /var/log/auth.log
```

Смотреть адреса и имена. Метрика адреса не хранит. Сравнить с легитимным пользователем деплоя: не его ли ключ внезапно отвергается (`Failed publickey` для известного пользователя — это не брутфорс, а доступ, который сейчас сломают, если начать банить).

**Как исправить.** Если это сканер, а парольный вход уже выключен ролью hardening — алерт информационный, порог поднимают после наблюдения, fail2ban при желании берётся из той роли, не из этого репозитория. Если это свой пользователь — чинить ключ, не банить его IP.

**Не делать.** Не менять `sshd_config` без второй сессии. Не ставить `PasswordAuthentication yes`, чтобы «посмотреть, пускает ли».

<a id="sshauthfailurescritical"></a>
## SshAuthFailuresCritical

**Что значит.** Больше 100 неудач в том же окне, 10 минут. Warning по тому же instance inhibit скрывает. Для словаря 100 за 15 минут ещё не потолок, для человека — уже нет.

**Как проверить.** Тот же журнал. Есть ли один адрес или много (рядом может гореть `SshBruteforceSources`). Не идёт ли легитимный ansible/CI с битым ключом в цикле.

**Как исправить.** Ограничить источник на периметре, если это не ваш автоматизатор. Свой автоматизатор — остановить цикл и починить ключ. Этот стек IP не банит.

**Не делать.** `iptables -F`. Не закрывать 22 для всех, пока вторая сессия не подтверждена.

<a id="sshbruteforcesources"></a>
## SshBruteforceSources

**Что значит.** Больше 15 разных адресов в неудачных строках окна. Один человек с одним IP так не выглядит. На опубликованном в интернет SSH фон сканеров может перейти порог без «атаки на вас лично».

**Как проверить.** Журнал, `awk` по полю `from`, не метрика. Счётчик уникальных адресов в textfile — оценка парсера, он пропускает строку без `from`.

**Как исправить.** Решить, должен ли 22 быть доступен из интернета. Если нет — закрыть на периметре и оставить доступ через bastion. Порог 15 не выведен из вашего трафика.

**Не делать.** Не добавлять IP в labels Prometheus «для удобства»: кардинальность и утечка адресов в TSDB и в Grafana.

<a id="sshauthmetricsfailed"></a>
## SshAuthMetricsFailed

**Что значит.** `ssh_auth_metrics_collection_success == 0`. Журнал не прочитан. Нули в соседних gauge не значат «тихо».

**Как проверить.** `journalctl -u ssh-auth-metrics.service`. Типично: нет прав на journald внутри юнита с `ProtectSystem=strict`, нет `/var/log/auth.log`, неверный `SSH_AUTH_LOG_FILE`.

**Как исправить.** Задать в `/etc/monitoring/ssh-auth-metrics.env` явный читаемый файл или поправить юнит, если ProtectSystem мешает `journalctl` (это названо в рисках). После правки — `systemctl daemon-reload` и ручной старт.

**Не делать.** Не ставить `success 1` вручную.

<a id="sshauthmetricsstale"></a>
## SshAuthMetricsStale

**Что значит.** `ssh_auth.prom` старше 10 минут при таймере в 5. Плюс `for: 5m` на самом алерте.

**Как проверить.** `systemctl status ssh-auth-metrics.timer`, `stat` файла.

**Как исправить.** Как у неудачного сбора: поднять таймер, прочитать ошибку. Не трогать `touch`.

<a id="sshauthmetricsabsent"></a>
## SshAuthMetricsAbsent

**Что значит.** Метрики сбора нет 30 минут. Таймер не ставился или node_exporter не видит каталог.

**Как проверить.** `systemctl cat ssh-auth-metrics.timer`, каталог `/var/lib/node_exporter/textfile`, mount в `docker inspect monitoring-node-exporter`.

**Как исправить.** Роль `monitoring_textfile` и перезапуск node_exporter, если каталог создан после старта контейнера (Docker не подхватит новый host path, если контейнер монтировал несуществующий путь как каталог не туда — сверить Source в mount).

**Не делать.** Не отключать алерт, оставляя SSH без сигнала.

<a id="nodetextfilescrapeerror"></a>
## NodeTextfileScrapeError

**Что значит.** `node_textfile_scrape_error == 1` десять минут. Каталог не читается или `.prom` битый. Битый файл не обновляет mtime, поэтому алерт «устарел» может не сработать.

**Как проверить.** `docker logs monitoring-node-exporter`, `promtool check metrics < file.prom` на хосте. Частая ошибка — HELP/TYPE разъехались или в файле остался временный кусок. Скрипты пишут во временный файл и делают `mv`.

**Как исправить.** Починить файл или права каталога (каталог 2775, файлы 0644, чтобы uid 65534 в контейнере мог читать). Перезапуск скрипта перезапишет файл.

**Не делать.** Не выключать textfile collector: вместе с ним пропадут restic и SSH.

<a id="monitoringdockerusernotapplied"></a>
## MonitoringDockerUserNotApplied

**Что значит.** `monitoring_docker_user_applied{family="ipv4"}` равен 0 дольше 10 минут. Скрипт не записал правила DOCKER-USER/INPUT: нет цепочки, `MONITORING_BIND_IP=0.0.0.0`, нет iptables. Пока так, опубликованный порт не ограничен этими правилами. Bind на `127.0.0.1` сам по себе снаружи всё ещё закрыт.

**Как проверить.** `systemctl status monitoring-docker-user.service`, `journalctl -u monitoring-docker-user.service -n 40`. `sudo iptables -S DOCKER-USER` и `sudo iptables -S INPUT | grep mon-`.

**Как исправить.** Поднять Docker, поставить конкретный `MONITORING_BIND_IP`, перезапустить юнит. Не ставить `0.0.0.0`.

**Не делать.** `iptables -F DOCKER-USER` и `iptables -F INPUT`.

<a id="monitoringdockeruserstale"></a>
## MonitoringDockerUserStale

**Что значит.** Файл `docker_user.prom` старше 15 минут при таймере в 5. Скрипт не запускается, и неизвестно, на месте ли правила.

**Как проверить.** `systemctl status monitoring-docker-user.timer`, `stat /var/lib/node_exporter/textfile/docker_user.prom`.

**Как исправить.** Запустить сервис вручную и прочитать ошибку. После `systemctl restart docker` юнит должен прийти следом (`PartOf=`). Если не пришёл — `systemctl enable --now monitoring-docker-user.service`.

**Не делать.** Не обновлять mtime через `touch`.

<a id="watchdog"></a>
## Watchdog

**Что значит.** `vector(1)` без `for`. Алерт должен гореть всегда. Severity `none`, маршрут ведёт в receiver `watchdog`. Без `vault_watchdog_webhook_url` он виден только в UI и не доказывает, что дежурный узнает о смерти Prometheus. На `env=production` роль не стартует, пока этот URL и `vault_alertmanager_webhook_url` пустые. Приёмник — любой ping-сервис, который орёт, когда пинги прекратились (совместимый с healthchecks). URL в git не класть.

**Как проверить.** `docker exec monitoring-prometheus wget -qO- http://127.0.0.1:9090/api/v1/rules | head`. Статус контейнера. Не путать с «Alertmanager молчит»: при пустом receiver страница и не должна прийти.

**Как исправить.** Починить Prometheus. Чтобы watchdog стал сторожем дежурства, задать `vault_watchdog_webhook_url` на приёмник, который орёт, когда пинг прекратился (dead man's switch). URL в git не класть.

**Не делать.** Не отправлять severity `none` в тот же канал, что critical, без фильтра: он будет гореть всегда.
