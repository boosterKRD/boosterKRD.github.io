helm create postgresql-chart
rm -rf postgresql-chart/templates/*

helm install my-postgresql ./postgresql-chart
helm uninstall my-postgresql

kubectl get pods
kubectl get svc

kubectl exec -it my-postgresql-postgres-client -- psql -h my-postgresql-postgres-service -U postgres -d postgres




### DOCs
postgresql-chart/
├── Chart.yaml       # Метаданные Chart (имя, версия, описание)
├── values.yaml      # Параметры конфигурации по умолчанию
└── templates/       # Шаблоны для Kubernetes-ресурсов
    ├── deployment.yaml
    ├── service.yaml
    └── configmap.yaml

- Chart.yaml: Описание Chart’а — имя, версия, описание, зависимости.
- values.yaml: Параметры по умолчанию, которые можно переопределять при установке.
- templates/: Папка с шаблонами для Kubernetes-ресурсов, такими как Deployment, Service, ConfigMap и другие. Эти шаблоны используют переменные из values.yaml и Chart.yaml.    

1. Установка Helm на macOS (например, через Homebrew):
```bash
brew install helm
```
2.	Основные команды Helm:
**Установка Chart**
Здесь <release-name> — это уникальное имя развертывания, а <chart-path> — путь к Chart или имя Chart из репозитория.
```bash
helm install <release-name> <chart-path> -f custom-values.yaml
```
**Обновление Chart**
Команда обновляет уже развернутый релиз с новыми значениями или изменёнными шаблонами.
```bash
helm upgrade <release-name> <chart-path> -f custom-values.yaml
```

**Удаление Chart**
```bash
helm uninstall <release-name>
```

**Просмотр списка релизов**
```bash
helm list
```



----
Условия и циклы:
```yaml
{{- if .Values.replicaCount }}
replicas: {{ .Values.replicaCount }}
{{- else }}
replicas: 1
{{- end }}

{{- range .Values.ports }}
- containerPort: {{ . }}
{{- end }}
```

Управление релизами и откаты
```yaml
helm history my-postgresql
helm rollback <release-name> <revision-number> #Откат к предыдущей версии

#------------------------------------------------------------------------------------------------------------------------
REVISION        UPDATED                         STATUS          CHART                   APP VERSION     DESCRIPTION     
1               Sat Nov  9 21:12:48 2024        deployed        postgresql-chart-0.1.0  1.16.0          Install complete
```