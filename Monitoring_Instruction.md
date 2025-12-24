# Полное руководство по настройке стека мониторинга и развертыванию приложений в k3s

**Цель:** Развернуть на локальном сервере (ноутбуке) `k3s` кластер, установить в него стек мониторинга `Prometheus + Grafana`, настроить сбор метрик с удаленных серверов (включая системные метрики, статус сервисов и статистику WireGuard), визуализировать их в Grafana и развернуть кастомное веб-приложение.

---

### **Часть 1: Установка базовой системы (k3s и Helm)**

На этом этапе мы подготовим "базу" — легковесный Kubernetes кластер и менеджер пакетов.

#### **Шаг 1.1: Установка k3s**
1.  Выполните команду установки `k3s`:
    ```bash
    curl -sfL https://get.k3s.io | sh - 
    ```
2.  **Важно:** `k3s` требует прав `root`. Все команды `kubectl` и `helm` для работы с этим кластером нужно выполнять через `sudo`.
    ```bash
    sudo kubectl get nodes
    ```

#### **Шаг 1.2: Установка Helm**
Helm — это менеджер пакетов для Kubernetes.
```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

---

### **Часть 2: Установка и настройка экспортеров на удаленных серверах**

На этом шаге мы с помощью Ansible установим на удаленные серверы (`gw` и `vds3`) агентов (`экспортеров`), которые будут собирать данные.

#### **Шаг 2.1: Настройка Ansible**
Убедитесь, что ваш inventory-файл `/mnt/usb_hdd1/Projects/Ansible/inventory` содержит целевые хосты в группе `monitored_vms`:
```ini
[monitored_vms]
vds3.iri1968.dpdns.org
gw.iri1968.dpdns.org
```
И настроен доступ к ним (например, через `~/.ssh/config` или `ansible_user`, `ansible_port` и т.д.).

#### **Шаг 2.2: Настройка Node Exporter (Системные метрики + Статус сервисов)**
Мы обновили шаблон сервиса `node_exporter`, чтобы он также собирал данные о статусе конкретных `systemd` сервисов.

1.  **Проверьте шаблон `/mnt/usb_hdd1/Projects/Ansible/templates/node_exporter.service.j2`:**
    Строка `ExecStart` должна выглядеть так, включая коллектор `systemd` и фильтр по сервисам:
    ```systemd
    ExecStart=/usr/local/bin/node_exporter --collector.systemd --collector.systemd.unit-include="(caddy|udp2raw|chisel|gost|nginx|mihomo)\\.service"
    ```
2.  **Запустите плейбук** для установки/обновления `node_exporter` на всех хостах:
    ```bash
    cd /mnt/usb_hdd1/Projects/Ansible/ 
    ansible-playbook install_node_exporter.yml
    ```
    (Используйте флаг `-K`, если для `sudo` на удаленных хостах требуется пароль).

#### **Шаг 2.3: Настройка WireGuard Exporter**
Этот плейбук скачивает и настраивает экспортер для метрик WireGuard.

1.  **Запустите плейбук:**
    ```bash
    cd /mnt/usb_hdd1/Projects/Ansible/ 
    ansible-playbook install_wireguard_exporter.yml
    ```
2.  После выполнения плейбуков убедитесь, что метрики доступны на портах `9100` (node_exporter) и `9586` (wireguard_exporter) ваших серверов.

---

### **Часть 3: Установка и настройка Prometheus**

Теперь установим Prometheus в кластер `k3s` и настроим его на сбор данных с наших экспортеров.

#### **Шаг 3.1: Конфигурация Prometheus (`values-light.yaml`)**
Файл `values-light.yaml` должен содержать конфигурацию для сбора данных с обоих экспортеров:
```yaml
grafana:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

alertmanager:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 1d
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 200m
        memory: 512Mi
    additionalScrapeConfigs:
      - job_name: 'vds3_node_exporter'
        scrape_interval: 15s
        static_configs:
          - targets: ['95.181.224.54:9100']
            labels:
              instance: 'vds3'
      - job_name: 'gw_node_exporter'
        scrape_interval: 15s
        static_configs:
          - targets: ['144.31.139.199:9100']
            labels:
              instance: 'gw'
      - job_name: 'vds3_wireguard_exporter'
        scrape_interval: 15s
        static_configs:
          - targets: ['95.181.224.54:9586']
            labels:
              instance: 'vds3'
      - job_name: 'gw_wireguard_exporter'
        scrape_interval: 15s
        static_configs:
          - targets: ['144.31.139.199:9586']
            labels:
              instance: 'gw'
```

#### **Шаг 3.2: Установка/Обновление стека мониторинга**
1.  **Добавьте репозиторий Prometheus (если не делали ранее):**
    ```bash
    sudo helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    sudo helm repo update
    ```
2.  **Установите или обновите `kube-prometheus-stack`:**
    ```bash
    sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f values-light.yaml
    ```
    *Использование `upgrade --install` позволяет выполнить как установку, так и обновление одной командой.*

#### **Шаг 3.3: Проверка**
Убедитесь, что Prometheus видит все цели. Пробросьте порт к Prometheus (`sudo kubectl port-forward -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 9090:9090`), откройте `http://localhost:9090` и перейдите в `Status -> Targets`. Все 4 цели должны быть в состоянии **UP**.

---

### **Часть 4: Визуализация в Grafana**

#### **Шаг 4.1: Доступ к Grafana**
Для удобства используйте скрипт `connect_grafana.sh`:
```bash
./connect_grafana.sh
```
Откройте `http://localhost:3000`. Логин `admin`, пароль будет выведен в терминале.

#### **Шаг 4.2: Импорт дашбордов**
1.  **Дашборд системных метрик:** Импорт через Grafana.com, ID: **`1860`**.
2.  **Дашборд WireGuard:** Импорт через `Upload JSON file`, файл: `wireguard-dashboard.json`.
3.  **Дашборд статуса сервисов:** Импорт через `Upload JSON file`, файл: `service-status-dashboard.json`.

---

### **Часть 5: Развертывание кастомного приложения (s-ui)**

Этот раздел описывает, как развернуть собственное приложение из исходного кода в локальный кластер `k3s`.

#### **Шаг 5.1: Сборка и локальный импорт Docker-образа**
Этот метод позволяет использовать локально собранный образ в `k3s` без необходимости загружать его в публичный репозиторий (Docker Hub, GHCR).

1.  **Соберите Docker-образ:**
    Перейдите в директорию с `Dockerfile` вашего приложения и выполните сборку.
    ```bash
    cd /mnt/usb_hdd1/Projects/sing-chisel-tel
    docker build -t igor04091968/sui:latest .
    ```
2.  **Сохраните образ в архив:**
    ```bash
    docker save igor04091968/sui:latest -o /tmp/sui.tar
    ```
3.  **Импортируйте образ в `k3s`:**
    `k3s` использует `containerd` в качестве среды выполнения, поэтому образ нужно импортировать в его хранилище.
    ```bash
    sudo k3s ctr images import /tmp/sui.tar
    ```
4.  **Удалите временный архив:**
    ```bash
    rm /tmp/sui.tar
    ```

#### **Шаг 5.2: Создание манифестов Kubernetes**
Создайте в директории проекта файл `sui-deployment.yaml`, который описывает, как запустить приложение в кластере.
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sui-deployment
  labels:
    app: sui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sui
  template:
    metadata:
      labels:
        app: sui
    spec:
      containers:
      - name: sui
        image: igor04091968/sui:latest
        imagePullPolicy: Never # Важно: заставляет Kubernetes использовать локальный образ
        ports:
        - containerPort: 2095
---
apiVersion: v1
kind: Service
metadata:
  name: sui-service
spec:
  type: NodePort # Открывает доступ к приложению извне кластера
  selector:
    app: sui # Должен совпадать с 'labels' в Deployment
  ports:
    - protocol: TCP
      port: 2095
      targetPort: 2095
```

#### **Шаг 5.3: Развертывание приложения**
Примените манифест к вашему кластеру:
```bash
cd /mnt/usb_hdd1/Projects/sing-chisel-tel
sudo kubectl apply -f sui-deployment.yaml
```

#### **Шаг 5.4: Проверка и доступ**
1.  **Проверьте статус пода:**
    ```bash
    sudo kubectl get pods -l app=sui
    ```
    Статус должен быть `Running`.
2.  **Узнайте порт доступа:**
    Посмотрите, какой порт `NodePort` был назначен вашей службе.
    ```bash
    sudo kubectl get service sui-service
    ```
    Вывод будет примерно таким: `2095:31222/TCP`. Здесь `31222` — это внешний порт.
3.  **Доступ к приложению:**
    Откройте в браузере: `http://localhost:<NodePort>`, например, `http://localhost:31222`.

#### **Шаг 5.5: Отладка: Пример с портом**
Изначально мы столкнулись с тем, что приложение не открывалось. Проблема была решена просмотром логов пода:
```bash
sudo kubectl logs deployment/sui-deployment
```
В логах мы увидели строку `web server run http on [::]:2095`, которая показала, что реальный порт приложения — `2095`, а не `2590`, как мы думали. После исправления порта в `sui-deployment.yaml` и повторного применения (`kubectl apply`) все заработало. Это стандартный и важный метод отладки в Kubernetes.