#!/bin/bash
#
# Этот скрипт находит под Grafana в пространстве имен 'monitoring'
# и пробрасывает его порт 3000 на локальный порт 3000.
#

echo "🔍 Поиск пода Grafana..."
# Получаем имя пода, используя правильные метки. Команда не выведет ничего, если под не найден.
POD_NAME=$(sudo kubectl get pods -n monitoring -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=prometheus" -o jsonpath="{.items[0].metadata.name}")

# Проверяем, найдено ли имя пода
if [ -z "$POD_NAME" ]; then
    echo "❌ Под Grafana не найден. Убедитесь, что стек мониторинга запущен в пространстве 'monitoring'."
    exit 1
fi

echo "✅ Найден под Grafana: $POD_NAME"
echo "🔑 Пароль администратора (логин 'admin'):"
sudo kubectl get secret --namespace monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
echo ""
echo "🚀 Запуск проброса порта. Откройте http://localhost:3000 в вашем браузере."
echo "ℹ️ Нажмите Ctrl+C, чтобы остановить."

# Запускаем проброс порта
sudo kubectl port-forward -n monitoring $POD_NAME 3000:3000
