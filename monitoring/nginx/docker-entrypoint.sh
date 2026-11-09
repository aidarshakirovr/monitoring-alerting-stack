#!/bin/sh
# Корневая ФС контейнера только для чтения. Каталоги кэша nginx живут на tmpfs
# и создаются при старте: в образе они есть, но tmpfs их перекрывает.
set -eu
mkdir -p \
  /tmp \
  /var/cache/nginx/client_temp \
  /var/cache/nginx/proxy_temp \
  /var/cache/nginx/fastcgi_temp \
  /var/cache/nginx/uwsgi_temp \
  /var/cache/nginx/scgi_temp \
  /var/run
exec nginx -g 'daemon off;'
