# 🚀 Руководство по развертыванию MiroTalk

Полное руководство по развертыванию MiroTalk для групповых P2P видеозвонков на домене `connect.mooz.pro`.

## 📋 Предварительные требования

### Сервер
- **ОС**: Ubuntu 20.04+ / Debian 11+ / CentOS 8+
- **RAM**: минимум 2GB, рекомендуется 4GB+
- **CPU**: минимум 2 ядра
- **Диск**: минимум 20GB свободного места
- **Сеть**: статический IP адрес

### DNS настройки
Убедитесь, что домен `connect.mooz.pro` настроен в DNS:
```
A    connect.mooz.pro    → IP_ВАШЕГО_СЕРВЕРА
```

### Порты
Откройте следующие порты в firewall:
- `22` - SSH
- `80` - HTTP (для Let's Encrypt)
- `443` - HTTPS
- `3478/udp` - TURN сервер (опционально)
- `5349/tcp` - TURN TLS (опционально)

## 🎯 Варианты развертывания

### 1. Быстрое развертывание (рекомендуется)

```bash
# Клонируйте файлы на локальную машину
git clone <your-repo>
cd jitsi

# Запустите автоматическое развертывание
./quick_deploy.sh YOUR_SERVER_IP
```

### 2. Ручное развертывание

#### Шаг 1: Подготовка сервера
```bash
# Подключитесь к серверу
ssh root@YOUR_SERVER_IP

# Скачайте скрипт установки
wget https://your-repo/install_mirotalk.sh
chmod +x install_mirotalk.sh

# Запустите установку
sudo ./install_mirotalk.sh
```

#### Шаг 2: Настройка TURN сервера (опционально)
```bash
# На сервере
sudo ./setup_turn_server.sh
```

## 🔧 Управление после установки

### Основные команды

```bash
# Переход в рабочую директорию
cd /opt/mirotalk

# Управление сервисами
./manage_mirotalk.sh start      # Запуск
./manage_mirotalk.sh stop       # Остановка
./manage_mirotalk.sh restart    # Перезапуск
./manage_mirotalk.sh status     # Статус
./manage_mirotalk.sh logs       # Логи
./manage_mirotalk.sh monitor    # Мониторинг
```

### Systemd управление

```bash
# Управление через systemd
sudo systemctl start mirotalk
sudo systemctl stop mirotalk
sudo systemctl restart mirotalk
sudo systemctl status mirotalk
```

## 📊 Мониторинг и диагностика

### Проверка статуса

```bash
# Статус всех контейнеров
docker compose ps

# Использование ресурсов
docker stats

# Логи всех сервисов
docker compose logs -f

# Логи конкретного сервиса
docker compose logs mirotalk
docker compose logs nginx
```

### Проверка доступности

```bash
# Проверка HTTP редиректа
curl -I http://connect.mooz.pro

# Проверка HTTPS
curl -I https://connect.mooz.pro

# Проверка SSL сертификата
openssl s_client -connect connect.mooz.pro:443 -servername connect.mooz.pro
```

### Проверка P2P соединений

```bash
# Тест STUN серверов
nmap -sU -p 3478 connect.mooz.pro

# Тест TURN сервера
turnutils_stunclient connect.mooz.pro

# Мониторинг TURN сервера
turn-monitor.sh
```

## 🔒 SSL сертификаты

### Автоматическое управление

SSL сертификаты настраиваются автоматически через Let's Encrypt:

```bash
# Ручное обновление сертификатов
cd /opt/mirotalk
docker compose run --rm certbot renew
docker compose exec nginx nginx -s reload
```

### Автоматическое обновление

Настроена cron задача для обновления сертификатов каждые 12 часов.

## 🔄 Обновления и бэкапы

### Обновление MiroTalk

```bash
# Автоматическое обновление
./manage_mirotalk.sh update

# Ручное обновление
cd /opt/mirotalk/mirotalk
git pull origin main
docker compose build --no-cache
docker compose up -d
```

### Бэкапы

```bash
# Создание бэкапа
./manage_mirotalk.sh backup pre_update

# Восстановление из бэкапа
./manage_mirotalk.sh restore backup_20231201_120000

# Список доступных бэкапов
ls -la /opt/mirotalk/backups/
```

## 🛠️ Конфигурация

### Основные настройки (.env)

```bash
# Редактирование конфигурации
nano /opt/mirotalk/.env
```

Основные параметры:
- `DOMAIN` - доменное имя
- `MAX_PARTICIPANTS` - максимальное количество участников
- `TURN_SERVERS` - настройки TURN сервера
- `ENABLE_RECORDING` - включение записи

### Nginx конфигурация

```bash
# Редактирование nginx конфигурации
nano /opt/mirotalk/nginx/conf.d/mirotalk.conf

# Перезагрузка nginx
docker compose exec nginx nginx -s reload
```

## 🆘 Устранение неполадок

### Проблемы с SSL

```bash
# Проверка сертификатов
ls -la /etc/letsencrypt/live/connect.mooz.pro/

# Тест SSL
openssl x509 -in /etc/letsencrypt/live/connect.mooz.pro/fullchain.pem -text -noout

# Пересоздание сертификата
docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot -d connect.mooz.pro
```

### Проблемы с P2P

```bash
# Проверка TURN сервера
systemctl status coturn
turn-monitor.sh

# Проверка портов
netstat -tuln | grep -E ":(3478|5349)"

# Тест STUN/TURN
turnutils_stunclient connect.mooz.pro
```

### Проблемы с Docker

```bash
# Перезапуск Docker
sudo systemctl restart docker

# Очистка системы
./manage_mirotalk.sh cleanup

# Пересборка контейнеров
docker compose build --no-cache
docker compose up -d
```

### Проблемы с производительностью

```bash
# Мониторинг ресурсов
docker stats
htop

# Проверка дискового пространства
df -h
du -sh /opt/mirotalk/

# Очистка логов
find /var/log -name "*.log" -type f -mtime +30 -delete
```

## 📞 Поддержка

### Логи для диагностики

```bash
# Все логи системы
journalctl -u docker -f

# Логи MiroTalk
tail -f /opt/mirotalk/logs/mirotalk.log

# Логи Nginx
tail -f /var/log/nginx/mirotalk.error.log

# Логи TURN сервера
tail -f /var/log/turnserver.log
```

### Полезные команды

```bash
# Полная перезагрузка системы
./manage_mirotalk.sh stop
./manage_mirotalk.sh start

# Проверка всех сервисов
systemctl status docker coturn nginx

# Проверка сетевых соединений
netstat -tuln
ss -tuln
```

## 🎉 Готово!

После успешного развертывания MiroTalk будет доступен по адресу:

**https://connect.mooz.pro**

### Возможности:
- ✅ P2P видеозвонки
- ✅ Групповые конференции
- ✅ SSL/TLS шифрование
- ✅ Автоматические обновления
- ✅ TURN сервер для NAT
- ✅ Мониторинг и логирование
- ✅ Резервное копирование

### Дополнительные настройки:
- Настройка TURN сервера для улучшения P2P
- Включение записи конференций
- Настройка уведомлений
- Интеграция с внешними сервисами

---

**Удачного использования MiroTalk!** 🎥📞
