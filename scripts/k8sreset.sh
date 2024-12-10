# domain variables
DOMAIN_NAME="ragandnar.com"
CERTIFICATE_FILE_NAME="fullchain.cer"
PRIVATE_KEY_FILE_NAME="ragandnar.com.key"

# minikube variables
MINIKUBE_NODES="3"

# terraform variables
TERRAFORM_VERSION=">= 1.8.0"
HELM_VERSION="2.15.0"
KUBERNETES_VERSION="2.32.0"

# domain variables check
DOMAIN_VARIABLE_FAIL=false
if [[ "${DOMAIN_NAME}" == "example.com" ]]; then
    echo -e "\033[0;91mERROR\033[0m DOMAIN_NAME is set to example.com"
    DOMAIN_VARIABLE_FAIL=true
fi
if [[ "${CERTIFICATE_FILE_NAME}" == "example.cer" ]]; then
    echo -e "\033[0;91mERROR\033[0m CERTIFICATE_FILE_NAME is set to example.cer"
    DOMAIN_VARIABLE_FAIL=true
fi
if [[ "${PRIVATE_KEY_FILE_NAME}" == "example.key" ]]; then
    echo -e "\033[0;91mERROR\033[0m PRIVATE_KEY_FILE_NAME is set to example.key"
    DOMAIN_VARIABLE_FAIL=true
fi
if [ "${DOMAIN_VARIABLE_FAIL}" = true ]; then
    exit 1
fi

# minikube variables check
if (( "${MINIKUBE_NODES}" < 2 )); then
    echo -e "\033[0;93mWARNING\033[0m MINIKUBE_NODES is set to less than 2 which will cause some pods to remain in a pending state"
fi

# countdown
for i in {5..1}; do
  echo -e "\033[0;96m$i\033[0m"
  sleep 1
done

cd $HOME/.project && rm -rf minikube && mkdir minikube && cd minikube
minikube delete && minikube start --driver="docker" --nodes="${MINIKUBE_NODES}" --addons="metrics-server"
touch terraform.tf
touch providers.tf
touch data.tf
touch main.tf
mkdir values

cat << EOF > terraform.tf
terraform {
  required_version = "${TERRAFORM_VERSION}"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "${HELM_VERSION}"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "${KUBERNETES_VERSION}"
    }
  }
}
EOF

cat << 'EOF' > providers.tf
provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "minikube"
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "minikube"
}
EOF

cat << 'EOF' > data.tf
data "kubernetes_nodes" "all_nodes" {}

data "kubernetes_all_namespaces" "all_namespaces" {}

data "kubernetes_server_version" "minikube_version" {}

data "kubernetes_config_map" "kubeadm_config" {
  metadata {
    name      = "kubeadm-config"
    namespace = "kube-system"
  }
}

data "kubernetes_config_map" "kubelet_config" {
  metadata {
    name      = "kubelet-config"
    namespace = "kube-system"
  }
}
EOF

cat << EOF > main.tf
resource "kubernetes_namespace" "prometheus" {
  metadata {
    name = "prometheus-system"
  }
}

resource "helm_release" "prometheus_crds" {
  chart       = "prometheus-operator-crds"
  name        = "prometheus-operator-crds"
  namespace   = kubernetes_namespace.prometheus.id
  repository  = "https://prometheus-community.github.io/helm-charts"
  version     = "16.0.1"
  timeout     = 600
  max_history = 10
}

resource "helm_release" "prometheus" {
  chart       = "kube-prometheus-stack"
  name        = "kube-prometheus-stack"
  namespace   = kubernetes_namespace.prometheus.id
  repository  = "https://prometheus-community.github.io/helm-charts"
  values      = [file("values/prometheus.yaml")]
  version     = "66.3.1"
  timeout     = 600
  max_history = 10
  depends_on = [
    helm_release.prometheus_crds,
  ]
}

resource "kubernetes_namespace" "traefik" {
  metadata {
    name = "traefik-system"
  }
}

resource "kubernetes_secret" "default_tls" {
  metadata {
    name      = "default-tls"
    namespace = kubernetes_namespace.traefik.id
  }
  data = {
    "tls.crt" = file("/home/user/.ssl/${CERTIFICATE_FILE_NAME}")
    "tls.key" = file("/home/user/.ssl/${PRIVATE_KEY_FILE_NAME}")
  }
  type = "kubernetes.io/tls"
}

resource "helm_release" "traefik" {
  chart       = "traefik"
  name        = "traefik"
  namespace   = kubernetes_namespace.traefik.id
  repository  = "https://traefik.github.io/charts"
  values      = [file("values/traefik.yaml")]
  version     = "33.1.0"
  timeout     = 600
  max_history = 10
  depends_on = [
    helm_release.prometheus,
  ]
}
EOF

cat << EOF > values/prometheus.yaml
crds:
  enabled: false

defaultRules:
  disabled:
    Watchdog: true

alertmanager:
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
    - alertmanager.${DOMAIN_NAME}
  alertmanagerSpec:
    resources:
      requests:
        memory: "64Mi"
        cpu: "100m"
      limits:
        memory: "1024Mi"
        cpu: "1000m"

grafana:
  enabled: false

kubeControllerManager:
  enabled: false

kubeEtcd:
  enabled: false

kubeScheduler:
  enabled: false

prometheus:
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
    - prometheus.${DOMAIN_NAME}
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    retention: 30d
    resources:
      requests:
        memory: "64Mi"
        cpu: "100m"
      limits:
        memory: "1024Mi"
        cpu: "1000m"
EOF

cat << 'EOF' > values/traefik.yaml
deployment:
  replicas: 2

ingressClass:
  enabled: true
  isDefaultClass: true
  name: traefik

providers:
  kubernetesIngress:
    ingressClass: traefik

logs:
  access:
    enabled: true

metrics:
  prometheus:
    service:
      enabled: true
    serviceMonitor:
      enabled: true

ports:
  web:
    nodePort: 31080
    redirectTo:
      port: websecure
  websecure:
    asDefault: true
    nodePort: 31443

tlsStore:
  default:
    defaultCertificate:
      secretName: default-tls

service:
  type: NodePort

resources:
  requests:
    memory: "64Mi"
    cpu: "100m"
  limits:
    memory: "1024Mi"
    cpu: "1000m"

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app.kubernetes.io/name: '{{ template "traefik.name" . }}'
          app.kubernetes.io/instance: '{{ .Release.Name }}-{{ .Release.Namespace }}'
      topologyKey: kubernetes.io/hostname
EOF

## init
terraform init

## first apply
terraform apply -auto-approve \
-target="kubernetes_namespace.prometheus" \
-target="helm_release.prometheus_crds" \
-target="helm_release.prometheus"

## second apply
terraform apply -auto-approve
