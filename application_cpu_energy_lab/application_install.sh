#!/usr/bin/env bash
# Application layer for vmteste: Kubernetes 1.35 / containerd / dual-stack.
# Helm: kube-prometheus-stack 92.17.0, Kepler 0.12.0, Chaos Mesh 2.8.7.
# Only real energy sensors. No automatic stress experiment is started.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${APP_BUILD_DIR:-${SCRIPT_DIR}/build/applications}"
CHECK_ONLY=0
CREDENTIAL_MODE=''
VERIFY_PID=''
KPS_VERSION=92.17.0
KEPLER_VERSION=0.12.0
CHAOS_VERSION=2.8.7
MANAGER=application-install
info() { printf '\n[INFO] %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n "$VERIFY_PID" ]]; then kill "$VERIFY_PID" 2>/dev/null || true; fi; }
on_error() {
  local rc=$?
  trap - ERR
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  if [[ -n "$CREDENTIAL_MODE" ]]; then
    printf '\n[ERROR] Credential command failed (exit %s). See the error above.\n' "$rc" >&2
    exit "$rc"
  fi
  printf '\n[ERROR] Applications installation stopped at line %s (exit %s).\n' "$1" "$rc" >&2
  kubectl --request-timeout=10s get pods -A -o wide >&2 || true
  kubectl --request-timeout=10s get events -A --sort-by=.lastTimestamp >&2 || true
  printf 'Keep the diagnostic output. Existing releases and volumes were not automatically removed.\n' >&2
  exit "$rc"
}
trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

usage() {
  cat <<'HELP'
Usage: ./application_install.sh [--check | --credentials | --renew-chaos-token]
  --check   Check the existing cluster, hardware sensor candidates and prerequisites.
            Writes local diagnostic files, but does not install cluster resources.
  --credentials       Show current Grafana login and Chaos Dashboard token.
                      Automatically renew a missing or nearly expired token.
  --renew-chaos-token  Renew and show the Chaos token plus Grafana login.
                      These two modes do not reinstall or restart applications.
  --help    Show this help.

Run on the Ubuntu VM as the regular ubuntu user with sudo access.
Requires the working cluster, kubectl, Helm 3, Python/PyYAML and OpenEBS Hostpath
created by the infrastructure installer. Does not run kubeadm or restart containerd.
Grafana uses dual-stack NodePort 30000; Chaos Dashboard uses NodePort 30001.
SSH forwarding remains available. Cloud/host firewall rules are not changed.
No synthetic meter or sensor-replacement power model is enabled. Kepler remains installed with
zero scheduled Pods if the VM exposes no readable RAPL/hwmon energy sensors.
HELP
}

show_credentials() {
  command -v kubectl >/dev/null || die 'kubectl is required.'
  command -v python3 >/dev/null || die 'python3 is required.'
  python3 - "$BUILD_DIR" "$1" <<'PY'
import base64,datetime,json,os,pathlib,subprocess,sys,tempfile,time
root=pathlib.Path(sys.argv[1]);force=sys.argv[2]=='renew'
if not (root/'context.json').is_file():
    sys.exit('Installation context not found. Run the installer first, or set APP_BUILD_DIR to its existing directory.')
state=json.loads((root/'context.json').read_text())
def get(*args):
    return json.loads(subprocess.check_output(['kubectl','--request-timeout=15s',*args,'-o','json']))
if get('get','namespace','kube-system')['metadata']['uid']!=state['cluster_uid']:
    sys.exit('Current kubectl context belongs to another cluster. Credentials were not read or changed.')
secret=get('-n','monitoring','get','secret','grafana-admin')
user=base64.b64decode(secret['data']['admin-user']).decode()
password=base64.b64decode(secret['data']['admin-password']).decode()
account=get('-n','cpu-lab','get','serviceaccount','chaos-lab-manager')
directory=root/'credentials';directory.mkdir(mode=0o700,exist_ok=True);directory.chmod(0o700)
path=directory/'chaos-token.txt';token=path.read_text().strip() if path.exists() else ''
def claims(value):
    part=value.split('.')[1]
    return json.loads(base64.urlsafe_b64decode(part+'='*(-len(part)%4)))
try:
    payload=claims(token)
    valid=(payload['exp']>time.time()+300 and
           payload['sub']=='system:serviceaccount:cpu-lab:chaos-lab-manager' and
           payload.get('kubernetes.io',{}).get('serviceaccount',{}).get('uid')==account['metadata']['uid'])
except (ValueError,KeyError,IndexError,TypeError):valid=False
if force or not valid:
    token=subprocess.check_output(['kubectl','--request-timeout=15s','-n','cpu-lab','create','token',
                                   'chaos-lab-manager','--duration=24h'],text=True).strip()
    if not token:sys.exit('Kubernetes returned an empty token.')
    payload=claims(token)
    print('Token Chaos Mesh renovado.')
def save(name,value):
    fd,tmp=tempfile.mkstemp(prefix='.credentials-',dir=directory)
    try:
        with os.fdopen(fd,'w') as stream:stream.write(value+'\n')
        os.replace(tmp,directory/name)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
save('grafana-user.txt',user);save('grafana-password.txt',password);save('chaos-token.txt',token)
print('\nGRAFANA\nUsuario: '+user+'\nSenha: '+password)
print('\nCHAOS MESH\nName: cpu-lab-manager\nToken:\n'+token)
if payload.get('exp'):
    print('Expira em (UTC): '+datetime.datetime.fromtimestamp(payload['exp'],datetime.timezone.utc).isoformat())
print('\nCole o token inteiro no campo Token e clique Submit. O login no navegador continua sendo manual.')
PY
}

preflight() {
  local command
  for command in kubectl helm python3 ip curl openssl sha256sum systemctl crictl; do
    command -v "$command" >/dev/null || die "Required command missing: ${command}"
  done
  [[ "$EUID" -ne 0 ]] || die 'Run as ubuntu, without sudo before this script.'
  helm version --short | python3 -c 'import sys; s=sys.stdin.read().strip(); sys.exit(0 if s.startswith("v3.") else "Helm 3 is required.")'
  python3 -c 'import yaml' || die 'PyYAML is required (Ubuntu package python3-yaml).'
  if ! sudo -n true 2>/dev/null; then sudo -v; fi
  kubectl --request-timeout=15s get --raw=/readyz
  printf '\n'
  kubectl get storageclass openebs-hostpath >/dev/null
  mkdir -p "$BUILD_DIR/credentials" "$BUILD_DIR/charts"
  chmod 0700 "$BUILD_DIR" "$BUILD_DIR/credentials"
  # Read hardware counters only. Do not load MSR modules or enable synthetic meters.
  # The diagnostic file intentionally belongs to the invoking user.
  # shellcheck disable=SC2024
  sudo python3 - <<'PY' > "$BUILD_DIR/sensor-candidates.json"
import glob,json,pathlib
found=[]
patterns=['/sys/class/powercap/*/energy_uj','/sys/class/powercap/*/*/energy_uj',
          '/sys/class/powercap/*/*/*/energy_uj',
          '/sys/class/hwmon/hwmon*/power*_input','/sys/class/hwmon/hwmon*/energy*_input']
for pattern in patterns:
    for name in glob.glob(pattern):
        try:
            float(pathlib.Path(name).read_text().strip())
            if name not in found: found.append(name)
        except (OSError,ValueError): pass
print(json.dumps(found))
PY
  python3 - "$BUILD_DIR" <<'PY'
import ipaddress,json,pathlib,re,subprocess,sys,urllib.parse,yaml
root=pathlib.Path(sys.argv[1])
def get(*args): return json.loads(subprocess.check_output(['kubectl',*args,'-o','json']))
nodes=get('get','nodes')['items']
if len(nodes)!=1: sys.exit('This installer targets the single-node VM discussed in the guide.')
node=nodes[0]
if not any(c['type']=='Ready' and c['status']=='True' for c in node['status']['conditions']): sys.exit('Node is not Ready.')
name=node['metadata']['name']
internal=[a['address'] for a in node['status']['addresses'] if a['type']=='InternalIP']
v4=next((a for a in internal if ipaddress.ip_address(a).version==4),None)
v6=next((a for a in internal if ipaddress.ip_address(a).version==6),None)
if not v4 or not v6: sys.exit('Expected the working dual-stack node with IPv4 and IPv6 InternalIPs.')
interfaces=json.loads(subprocess.check_output(['ip','-j','address','show']))
iface=next((i['ifname'] for i in interfaces if any(a.get('local')==v4 for a in i['addr_info'])),None)
if not iface or not re.fullmatch(r'[A-Za-z0-9_-]+',iface): sys.exit('Could not identify the node IPv4 interface.')
conf=json.loads(subprocess.check_output(['kubectl','config','view','--minify','-o','json']))
url=urllib.parse.urlparse(conf['clusters'][0]['cluster']['server'])
if url.hostname not in internal: sys.exit('Run on the VM using its direct API kubeconfig, not an external proxy context.')
cm=get('-n','kube-system','get','configmap','kubeadm-config')
cluster=yaml.safe_load(cm['data']['ClusterConfiguration'])
cidrs=[ipaddress.ip_network(s.strip()) for s in cluster['networking']['serviceSubnet'].split(',')]
service_v4=next(str(n) for n in cidrs if n.version==4)
service=get('-n','default','get','service','kubernetes')
uid=get('get','namespace','kube-system')['metadata']['uid']
version=node['status']['nodeInfo']['kubeletVersion'].lstrip('v')
state={'cluster_uid':uid,'node':name,'ipv4':v4,'ipv6':v6,'interface':iface,
       'api_host':url.hostname,'api_port':url.port or 443,'service_cidr':service_v4,
       'service_ip':service['spec']['clusterIP'],'kube_version':version,
       'sensor_candidates':json.loads((root/'sensor-candidates.json').read_text())}
expected_ports={30000:('monitoring','grafana'),30001:('chaos-mesh','chaos-dashboard')}
for svc in get('get','services','--all-namespaces')['items']:
    owner=(svc['metadata']['namespace'],svc['metadata']['name'])
    for port in svc['spec'].get('ports',[]):
        number=port.get('nodePort')
        if number in expected_ports and owner!=expected_ports[number]:
            sys.exit('NodePort '+str(number)+' is already used by '+ '/'.join(owner))
old=root/'context.json'
if old.exists() and json.loads(old.read_text()).get('cluster_uid')!=uid:
    sys.exit('This build directory belongs to another cluster; choose APP_BUILD_DIR explicitly.')
old.write_text(json.dumps(state,indent=2)+'\n')
print('Node:',name,'API:',url.hostname,url.port or 443,'Service CIDR:',service_v4)
print('Readable real sensor candidates:',len(state['sensor_candidates']))
if not state['sensor_candidates']:
    print('REAL-ONLY MODE: CPU graphs will work; Kepler will have zero scheduled Pods and no watt readings.')
PY
  read -r NODE_NAME NODE_INTERFACE SERVICE_CIDR SERVICE_IP SENSOR_STATE < <(
    python3 - "$BUILD_DIR/context.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d['node'],d['interface'],d['service_cidr'],d['service_ip'],
      'present' if d['sensor_candidates'] else 'absent')
PY
  )
  if ! ip -4 route get "$SERVICE_IP" >/dev/null 2>&1; then
    info "Host has no IPv4 route to Kubernetes Services; installation will add only ${SERVICE_CIDR} via ${NODE_INTERFACE}."
  fi
  if kubectl -n cpu-lab get stresschaos -o json > "$BUILD_DIR/current-stress.json" 2>/dev/null; then
    python3 - "$BUILD_DIR/current-stress.json" <<'PY'
import json,sys
items=json.load(open(sys.argv[1])).get('items',[])
if items: sys.exit('Existing StressChaos experiments found in cpu-lab. Finish/remove them before reinstalling the applications.')
PY
  fi
}

fetch() { curl -fLsS --connect-timeout 10 --max-time 180 --retry 2 "$1" -o "$2"; }

prepare_charts() {
  info 'Downloading and checking pinned Helm charts.'
  fetch "https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-${KPS_VERSION}/kube-prometheus-stack-${KPS_VERSION}.tgz" "$BUILD_DIR/charts/monitoring.tgz"
  fetch "https://charts.chaos-mesh.org/chaos-mesh-${CHAOS_VERSION}.tgz" "$BUILD_DIR/charts/chaos.tgz"
  helm pull oci://quay.io/sustainable_computing_io/charts/kepler --version "$KEPLER_VERSION" --destination "$BUILD_DIR/charts"
  mv "$BUILD_DIR/charts/kepler-${KEPLER_VERSION}.tgz" "$BUILD_DIR/charts/kepler.tgz"
  python3 - "$BUILD_DIR/charts" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={'monitoring.tgz':'f267989be8318f12b37273a075504d4986a2a744383daf7cca0732a8d35d400d',
          'chaos.tgz':'c963e0f4ed2e30c1c7e236477f1c31fcf988b171991801bbe392546948436d38',
          'kepler.tgz':'0e1e106c19c9df0725bf02781aab412132284cfa5dae4665bab6b1c621844501'}
for name,want in expected.items():
    got=hashlib.sha256((root/name).read_bytes()).hexdigest()
    if got!=want: sys.exit('Chart checksum mismatch: '+name)
    print('SHA-256 OK:',name)
PY
}

generate_assets() {
  python3 - "$BUILD_DIR" <<'APPLICATION_GENERATOR'
"""Build the local assets embedded in application_install.sh."""
import json
import pathlib
import sys
import textwrap
import yaml


def generate(root, state):
    root = pathlib.Path(root)
    root.mkdir(parents=True, exist_ok=True)
    real_meter = bool(state['sensor_candidates'])
    public_host = '[' + state['ipv6'] + ']'
    grafana_url = 'http://' + public_host + ':30000'
    chaos_url = 'http://' + public_host + ':30001'
    def emit(name, value):
        (root / name).write_text(yaml.safe_dump(value, sort_keys=False))
    monitoring = {
        'fullnameOverride': 'monitoring',
        'alertmanager': {'enabled': False},
        'defaultRules': {'create': False},
        'kubeEtcd': {'enabled': False}, 'kubeControllerManager': {'enabled': False},
        'kubeScheduler': {'enabled': False}, 'kubeProxy': {'enabled': False},
        'prometheusOperator': {
            'admissionWebhooks': {'enabled': False}, 'tls': {'enabled': False},
            'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                          'limits': {'cpu': '1', 'memory': '512Mi'}}},
        'prometheus': {'prometheusSpec': {
            'replicas': 1, 'retention': '2d', 'retentionSize': '3GB',
            'scrapeInterval': '15s', 'evaluationInterval': '15s',
            'resources': {'requests': {'cpu': '300m', 'memory': '512Mi'},
                          'limits': {'cpu': '2', 'memory': '2Gi'}},
            'storageSpec': {'volumeClaimTemplate': {'spec': {
                'storageClassName': 'openebs-hostpath', 'accessModes': ['ReadWriteOnce'],
                'resources': {'requests': {'storage': '5Gi'}}}}},
            'additionalScrapeConfigs': ([{'job_name': 'kepler', 'scrape_interval': '5s',
                'static_configs': [{'targets': ['kepler.kepler.svc.cluster.local:28282']}]}]
                if real_meter else [])}},
        'grafana': {
            'fullnameOverride': 'grafana',
            'defaultDashboardsEnabled': False,
            'admin': {'existingSecret': 'grafana-admin', 'userKey': 'admin-user',
                      'passwordKey': 'admin-password'},
            'persistence': {'enabled': True, 'type': 'pvc', 'storageClassName': 'openebs-hostpath',
                            'size': '1Gi'},
            'deploymentStrategy': {'type': 'Recreate'},
            'service': {'type': 'NodePort', 'nodePort': 30000,
                        'ipFamilyPolicy': 'RequireDualStack', 'ipFamilies': ['IPv4', 'IPv6']},
            'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                          'limits': {'cpu': '1', 'memory': '512Mi'}},
            'grafana.ini': {'server': {'root_url': grafana_url + '/'},
                            'users': {'allow_sign_up': False},
                            'auth.anonymous': {'enabled': False}},
            'sidecar': {
                'dashboards': {'enabled': True, 'label': 'grafana_dashboard',
                               'labelValue': '1', 'searchNamespace': 'monitoring'},
                'datasources': {'enabled': True, 'uid': 'prometheus', 'alertmanager': {'enabled': False}}}},
        'kube-state-metrics': {'resources': {
            'requests': {'cpu': '50m', 'memory': '64Mi'},
            'limits': {'cpu': '500m', 'memory': '256Mi'}}},
        'prometheus-node-exporter': {'resources': {
            'requests': {'cpu': '50m', 'memory': '32Mi'},
            'limits': {'cpu': '500m', 'memory': '128Mi'}}},
    }
    emit('monitoring-values.yaml', monitoring)
    emit('kepler-values.yaml', {
        'fullnameOverride': 'kepler', 'namespace': {'create': False, 'name': 'kepler'},
        'image': {'tag': 'v0.12.0'},
        'daemonset': {
            'nodeSelector': {'testbed.lab/energy-sensor': 'present'},
            'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                          'limits': {'cpu': '500m', 'memory': '512Mi'}}},
        'config': {
            'log': {'level': 'info'}, 'cpu': {'preferredMeters': ['rapl', 'hwmon']},
            'monitor': {'interval': '5s'},
            'kube': {'enabled': True, 'podInformer': {'mode': 'apiserver'}},
            'experimental': {'gpu': {'enabled': False}},
            'dev': {'fake-cpu-meter': {'enabled': False}}},
        'serviceMonitor': {'enabled': False},
    })
    emit('chaos-values.yaml', {
        'clusterScoped': False,
        'controllerManager': {
            'replicaCount': 1, 'targetNamespace': 'cpu-lab', 'serviceAccount': 'chaos-controller-manager',
            'enableFilterNamespace': True, 'allowHostNetworkTesting': False,
            'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                          'limits': {'cpu': '1', 'memory': '512Mi'}}},
        'chaosDaemon': {
            'runtime': 'containerd', 'socketPath': '/run/containerd/containerd.sock',
            'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                          'limits': {'cpu': '1', 'memory': '512Mi'}}},
        'dnsServer': {'create': False},
        'dashboard': {
            'create': True, 'replicaCount': 1, 'securityMode': True,
            'rootUrl': chaos_url, 'service': {'type': 'NodePort', 'nodePort': 30001},
            'persistentVolume': {'enabled': True, 'size': '1Gi',
                                 'storageClassName': 'openebs-hostpath'},
            'resources': {'requests': {'cpu': '50m', 'memory': '128Mi'},
                          'limits': {'cpu': '500m', 'memory': '512Mi'}}},
    })
    workload = {
        'apiVersion': 'apps/v1', 'kind': 'Deployment',
        'metadata': {'name': 'ubuntu-test', 'namespace': 'cpu-lab',
                     'labels': {'app': 'ubuntu-test'}},
        'spec': {'replicas': 1, 'selector': {'matchLabels': {'app': 'ubuntu-test'}},
                 'template': {'metadata': {'labels': {'app': 'ubuntu-test', 'testbed.lab/workload': 'cpu'}},
                    'spec': {'automountServiceAccountToken': False,
                        'terminationGracePeriodSeconds': 10,
                        'containers': [{'name': 'ubuntu-test', 'image': 'docker.io/library/ubuntu:22.04',
                            'command': ['/bin/bash', '-c', 'exec sleep infinity'],
                            'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                                          'limits': {'cpu': '4', 'memory': '1Gi'}}}]}}}}
    emit('ubuntu-test.yaml', workload)
    emit('cpu-stress.yaml', {
        'apiVersion': 'chaos-mesh.org/v1alpha1', 'kind': 'StressChaos',
        'metadata': {'name': 'cpu-stress-ubuntu', 'namespace': 'cpu-lab'},
        'spec': {'mode': 'one', 'duration': '120s', 'containerNames': ['ubuntu-test'],
                 'selector': {'namespaces': ['cpu-lab'], 'labelSelectors': {'app': 'ubuntu-test'}},
                 'stressors': {'cpu': {'workers': 3, 'load': 80}}}})
    rbac = [
        {'apiVersion': 'v1', 'kind': 'ServiceAccount',
         'metadata': {'name': 'chaos-lab-manager', 'namespace': 'cpu-lab'}},
        {'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'Role',
         'metadata': {'name': 'chaos-lab-manager', 'namespace': 'cpu-lab'},
         'rules': [
             {'apiGroups': [''], 'resources': ['pods', 'events', 'services'],
              'verbs': ['get', 'list', 'watch']},
             {'apiGroups': ['apps'], 'resources': ['deployments', 'replicasets', 'statefulsets', 'daemonsets'],
              'verbs': ['get', 'list', 'watch']},
             {'apiGroups': ['chaos-mesh.org'], 'resources': ['*'],
              'verbs': ['get', 'list', 'watch', 'create', 'delete', 'patch', 'update']}]},
        {'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'RoleBinding',
         'metadata': {'name': 'chaos-lab-manager', 'namespace': 'cpu-lab'},
         'subjects': [{'kind': 'ServiceAccount', 'name': 'chaos-lab-manager', 'namespace': 'cpu-lab'}],
         'roleRef': {'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'Role', 'name': 'chaos-lab-manager'}},
        {'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'ClusterRole',
         'metadata': {'name': 'cpu-lab-chaos-namespace-reader'},
         'rules': [{'apiGroups': [''], 'resources': ['namespaces'], 'verbs': ['get', 'list', 'watch']}]},
        {'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'ClusterRoleBinding',
         'metadata': {'name': 'cpu-lab-chaos-namespace-reader'},
         'subjects': [{'kind': 'ServiceAccount', 'name': 'chaos-lab-manager', 'namespace': 'cpu-lab'},
                      {'kind': 'ServiceAccount', 'name': 'chaos-controller-manager', 'namespace': 'chaos-mesh'}],
         'roleRef': {'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'ClusterRole',
                     'name': 'cpu-lab-chaos-namespace-reader'}},
    ]
    (root / 'chaos-access-rbac.yaml').write_text(yaml.safe_dump_all(rbac, sort_keys=False))
    description = (
        'Candidatos a sensores reais foram encontrados. A disponibilidade de watts depende de o Kepler conseguir lê-los. '
        'Selecione uma única zona; package/core/dram podem se sobrepor.' if real_meter else
        'Esta VM não expõe contadores RAPL nem sensores hwmon de potência/energia legíveis. '
        'Kepler está instalado com 0 pods desejados. Uso de CPU e memória são reais; watts/joules ficam indisponíveis. '
        'Nenhum medidor sintético ou modelo de potência foi ativado.')
    panels = []
    def panel(title, expr, x, y, w=12, h=8, unit='short', kind='timeseries', legend=''):
        value = {'id': len(panels)+1, 'title': title, 'type': kind,
            'gridPos': {'x': x, 'y': y, 'w': w, 'h': h},
            'datasource': {'type': 'prometheus', 'uid': 'prometheus'},
            'targets': [{'refId': 'A', 'expr': expr, 'legendFormat': legend}],
            'fieldConfig': {'defaults': {'unit': unit, 'noValue': 'Indisponível',
                'custom': {'drawStyle': 'line', 'fillOpacity': 10, 'lineWidth': 2}}, 'overrides': []},
            'options': {'legend': {'displayMode': 'list', 'placement': 'bottom'},
                        'tooltip': {'mode': 'multi'}}}
        panels.append(value)
    panels.append({'id': 1, 'type': 'text', 'title': 'CPU Energy Lab — métricas reais',
        'gridPos': {'x': 0, 'y': 0, 'w': 24, 'h': 4},
        'options': {'mode': 'markdown', 'content':
            '**Fluxo:** Chaos Dashboard → StressChaos → ubuntu-test → Prometheus → Grafana.\n\n'
            '**Energia:** '+description+'\n\n'
            '**Experimento recomendado:** namespace `cpu-lab`, app `ubuntu-test`, CPU workers **3**, '
            'load **80%**, duração **120s**. O container está limitado a **4 CPUs**.'}})
    cpu = 'sum(rate(container_cpu_usage_seconds_total{namespace="cpu-lab",container="ubuntu-test",pod=~"ubuntu-test-.*"}[1m]))'
    panel('Ubuntu-test — CPU utilizada (núcleos)', cpu, 0, 4, unit='cores')
    panel('VM — utilização de CPU (%)', '100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])))', 12, 4, unit='percent')
    panel('Ubuntu-test — memória de trabalho', 'sum(container_memory_working_set_bytes{namespace="cpu-lab",container="ubuntu-test",pod=~"ubuntu-test-.*"})', 0, 12, unit='bytes')
    panel('Kepler — potência real da zona selecionada (W)', 'sum(kepler_node_cpu_watts{job="kepler",zone="$zone"})', 12, 12, unit='watt')
    panel('Kepler — potência atribuída ao Ubuntu-test (W)', 'sum(kepler_pod_cpu_watts{job="kepler",pod_namespace="cpu-lab",pod_name=~"ubuntu-test-.*",zone="$zone"})', 0, 20, unit='watt')
    panel('Kepler — energia real da zona no período (J)', 'sum(increase(kepler_node_cpu_joules_total{job="kepler",zone="$zone"}[$__range]))', 12, 20, unit='joule', kind='stat')
    panel('CPU do Ubuntu-test — percentual do limite de 4 CPUs', f'100 * ({cpu}) / 4', 0, 28, unit='percent')
    panel('Kepler — coleta ativa (1 = sim)', 'max(up{job="kepler"}) or vector(0)', 12, 28, kind='stat')
    dashboard = {'uid': 'cpu-energy-lab', 'title': 'CPU Energy Lab', 'schemaVersion': 39, 'version': 1,
        'tags': ['cpu', 'kepler', 'chaos-mesh', 'testbed'], 'timezone': 'browser', 'refresh': '5s',
        'editable': True, 'time': {'from': 'now-15m', 'to': 'now'},
        'templating': {'list': [{'name': 'zone', 'label': 'Zona de energia (uma por vez)',
            'type': 'query', 'datasource': {'type': 'prometheus', 'uid': 'prometheus'},
            'query': 'label_values(kepler_node_cpu_watts{job="kepler"}, zone)', 'refresh': 1,
            'multi': False, 'includeAll': False,
            'current': {'text': 'package', 'value': 'package'}}]}, 'panels': panels}
    (root / 'cpu-energy-dashboard.json').write_text(json.dumps(dashboard, ensure_ascii=False, indent=2)+'\n')
    emit('dashboard-configmap.yaml', {'apiVersion': 'v1', 'kind': 'ConfigMap',
        'metadata': {'name': 'cpu-energy-dashboard', 'namespace': 'monitoring',
                     'labels': {'grafana_dashboard': '1', 'app.kubernetes.io/managed-by': 'application-install'}},
        'data': {'cpu-energy-lab.json': json.dumps(dashboard, ensure_ascii=False)}})

    post_renderer = r'''#!/usr/bin/env python3
import json,pathlib,sys,yaml
state=json.loads((pathlib.Path(__file__).parent/'context.json').read_text())
# Kubernetes CRD schemas can contain a bare '=' enum item. PyYAML assigns
# its legacy YAML value tag, while Kubernetes treats it as a scalar string.
yaml.SafeLoader.add_constructor('tag:yaml.org,2002:value',lambda loader,node:loader.construct_scalar(node))
docs=[]
for doc in yaml.safe_load_all(sys.stdin):
    # Empty upstream template documents must not become '--- null'. Helm's
    # Kubernetes manifest parser rejects that separator during installation.
    if doc is None: continue
    if not isinstance(doc,dict) or not doc.get('apiVersion') or not doc.get('kind'):
        sys.exit('Post-renderer received a non-resource YAML document.')
    docs.append(doc)
for d in docs:
    if d.get('kind')=='Service' and d.get('metadata',{}).get('name') in ('grafana','chaos-dashboard'):
        svc=d['spec'];svc['type']='NodePort'
        svc['ipFamilyPolicy']='RequireDualStack';svc['ipFamilies']=['IPv4','IPv6']
        # Expose only the browser endpoint, not the dashboard metrics port.
        port=80 if d['metadata']['name']=='grafana' else 2333
        selected=[p for p in svc['ports'] if p['port']==port]
        if len(selected)!=1: sys.exit('Unexpected browser Service ports.')
        selected[0]['nodePort']=30000 if port==80 else 30001
        svc['ports']=selected
    spec=None
    if d.get('kind') in ('Deployment','DaemonSet','StatefulSet','Job'):
        spec=d.get('spec',{}).get('template',{}).get('spec',{})
    if spec and spec.get('hostNetwork'):
        values={'KUBERNETES_SERVICE_HOST':state['api_host'],
                'KUBERNETES_SERVICE_PORT':str(state['api_port']),
                'KUBERNETES_SERVICE_PORT_HTTPS':str(state['api_port'])}
        for c in spec.get('containers',[])+spec.get('initContainers',[]):
            c['env']=[e for e in c.get('env',[]) if e['name'] not in values]
            c['env'].extend({'name':k,'value':v} for k,v in values.items())
yaml.safe_dump_all(docs,sys.stdout,sort_keys=False)
'''
    (root / 'helm-post-renderer.py').write_text(post_renderer)
    (root / 'helm-post-renderer.py').chmod(0o755)
    access = '''#!/usr/bin/env bash
set -Eeuo pipefail
children=()
cleanup() { for child in "${children[@]}"; do kill "$child" 2>/dev/null || true; done; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
kubectl -n monitoring port-forward --address=127.0.0.1 service/grafana 3000:80 &
children+=("$!")
kubectl -n chaos-mesh port-forward --address=127.0.0.1 service/chaos-dashboard 2333:2333 &
children+=("$!")
kubectl -n monitoring port-forward --address=127.0.0.1 service/monitoring-prometheus 9090:9090 &
children+=("$!")
printf '\\nKeep this terminal open. Grafana :3000; Chaos Dashboard :2333; Prometheus :9090.\\n'
wait -n "${children[@]}"
'''
    (root / 'application_access.sh').write_text(access)
    (root / 'application_access.sh').chmod(0o755)
    renew = '''#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
kubectl -n cpu-lab create token chaos-lab-manager --duration=24h > "$SCRIPT_DIR/credentials/chaos-token.txt"
printf 'Updated %s/credentials/chaos-token.txt\\n' "$SCRIPT_DIR"
printf 'Chaos Dashboard — Name: cpu-lab-manager\\nToken:\\n'
cat "$SCRIPT_DIR/credentials/chaos-token.txt"
printf '\\n'
'''
    (root / 'renew_chaos_token.sh').write_text(renew)
    (root / 'renew_chaos_token.sh').chmod(0o755)
    host = state.get('ipv6') or state['ipv4']
    guide = f'''# Acesso ao laboratório

Abra diretamente no navegador de um computador com conectividade IPv6:

| Aplicação | URL |
|---|---|
| Grafana | {grafana_url}/d/cpu-energy-lab |
| Chaos Mesh | {chaos_url} |

Grafana usa NodePort TCP **30000**; Chaos Dashboard usa **30001**, ambos dual-stack.
Autorize essas portas no grupo de segurança da nuvem e no firewall da VM somente
para o IPv6/rede do seu computador. O instalador não altera esses firewalls.
O acesso direto é HTTP; para transportar as credenciais por SSH, use a alternativa abaixo.
Prometheus e Kepler continuam internos.

## Alternativa com túnel SSH

Na VM: `./application_access.sh` (neste diretório). Mantenha aberto.
No computador com navegador, abra outro terminal e conecte por SSH:

```bash
ssh -N -L 3000:127.0.0.1:3000 -L 2333:127.0.0.1:2333 -L 9090:127.0.0.1:9090 ubuntu@{host}
```

Acrescente as opções de chave/bastion que você já usa para entrar nesta VM.
No navegador do seu computador:

| Aplicação | URL |
|---|---|
| Grafana | http://localhost:3000/d/cpu-energy-lab |
| Chaos Mesh | http://localhost:2333 |
| Prometheus | http://localhost:9090 |

Grafana: usuário `admin`; senha em `credentials/grafana-password.txt`.
Chaos Mesh: token em `credentials/chaos-token.txt`; renove com `./renew_chaos_token.sh`.
O servidor pode limitar a validade solicitada de 24 horas.

Na janela do Chaos Mesh, preencha **Name** com `cpu-lab-manager` e **Token** com o token inteiro.
Para consultar os dois logins e renovar automaticamente um token ausente ou próximo de expirar,
execute `./application_install.sh --credentials` no diretório onde está o instalador,
com o mesmo `APP_BUILD_DIR` usado na instalação, caso tenha sido personalizado.
Para forçar a renovação, use `--renew-chaos-token`. Essas opções não reinstalam aplicações.
A geração/renovação é automática ao executar o comando; colar o token no navegador continua manual.

## Experimento pelo navegador

Abra Grafana e Chaos Dashboard em abas separadas. Observe aproximadamente 1 minuto de baseline.
No Chaos Dashboard: NEW EXPERIMENT → STRESS TEST → CPU.
Escolha namespace `cpu-lab`, label `app=ubuntu-test`, container `ubuntu-test`, modo `one`,
workers `3`, load `80`, duração `120s`. Use nome `cpu-stress-ubuntu`.
Submeta para iniciar. A carga termina ao completar o período; acompanhe o estado na interface.
O arquivo `cpu-stress.yaml` contém o mesmo experimento para referência/importação.
O instalador somente valida esse YAML no servidor; não aplica o experimento.

O limite de 4 CPUs protege a capacidade restante da VM de 8 vCPUs. Três workers a 80% visam
aproximadamente 2,4 núcleos de carga, sujeitos ao escalonamento e às outras aplicações.
O gráfico usa taxa de 1 minuto; a curva sobe e desce gradualmente.

## Energia

{description}

Kepler usa exclusivamente medidores `rapl` e `hwmon`. Não há medidor sintético nem modelo
substituindo sensores ausentes.
Potência atribuída a um pod é uma atribuição do Kepler a partir do sensor e do uso de CPU;
não é um wattímetro físico por pod. Numa VM, um sensor exposto pode pertencer ao host físico.
CPU stress mede carga de CPU; não é um teste de GPU.

Para parar o experimento de exemplo pelo terminal:
`kubectl -n cpu-lab delete stresschaos cpu-stress-ubuntu --ignore-not-found`.
'''
    (root / 'ACESSO.md').write_text(guide)


if __name__ == '__main__':
    destination = pathlib.Path(sys.argv[1])
    generate(destination, json.loads((destination / 'context.json').read_text()))

APPLICATION_GENERATOR
}

render_charts() {
  local release namespace chart values
  while read -r release namespace chart values; do
    helm template "$release" "$BUILD_DIR/charts/$chart" --namespace "$namespace" \
      --kube-version "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kube_version"])' "$BUILD_DIR/context.json")" \
      --include-crds --skip-tests --post-renderer "$BUILD_DIR/helm-post-renderer.py" \
      -f "$BUILD_DIR/$values" > "$BUILD_DIR/${release}-rendered.yaml"
  done <<'CHARTS'
monitoring monitoring monitoring.tgz monitoring-values.yaml
kepler kepler kepler.tgz kepler-values.yaml
chaos-mesh chaos-mesh chaos.tgz chaos-values.yaml
CHARTS
  python3 - "$BUILD_DIR" <<'PY'
import pathlib,sys,yaml
root=pathlib.Path(sys.argv[1]); images=set(); services=set()
def walk(obj):
    if isinstance(obj,dict):
        for k,v in obj.items():
            if k=='image' and isinstance(v,str): images.add(v)
            walk(v)
    elif isinstance(obj,list):
        for v in obj: walk(v)
for release in ('monitoring','kepler','chaos-mesh'):
    for doc in yaml.safe_load_all((root/(release+'-rendered.yaml')).read_text()):
        if not isinstance(doc,dict):sys.exit('Rendered chart contains an empty/non-resource document.')
        if doc.get('kind')=='Service':services.add(doc['metadata']['name'])
        if doc.get('kind')=='Service' and doc['metadata']['name'] in ('grafana','chaos-dashboard'):
            spec=doc['spec'];want=30000 if doc['metadata']['name']=='grafana' else 30001
            if spec.get('type')!='NodePort' or spec.get('ipFamilyPolicy')!='RequireDualStack' or spec.get('ipFamilies')!=['IPv4','IPv6'] or len(spec['ports'])!=1 or spec['ports'][0].get('nodePort')!=want:
                sys.exit('Browser NodePort/dual-stack configuration is invalid.')
        walk(doc)
for svc in ('grafana','monitoring-prometheus','chaos-dashboard','kepler'):
    if svc not in services: sys.exit('Unexpected chart Service naming: missing '+svc)
images.add('docker.io/library/ubuntu:22.04')
images.add('quay.io/prometheus-operator/prometheus-config-reloader:v0.94.2')
(root/'images.txt').write_text('\n'.join(sorted(images))+'\n')
print('Charts rendered; expected UI, Prometheus and Kepler Services verified.')
PY
}

ensure_service_route() {
  local unit=/etc/systemd/system/testbed-service-cidr-route.service
  if ip -4 route get "$SERVICE_IP" >/dev/null 2>&1 && ! sudo test -f "$unit"; then return 0; fi
  info "Ensuring a specific host route for ${SERVICE_CIDR}; required for admission webhooks without an IPv4 default route."
  if sudo test -f "$unit"; then
    sudo cat "$unit" | python3 -c 'import sys; sys.exit(0 if "Managed by application-install" in sys.stdin.read() else "Existing route unit is not owned by this installer.")'
  fi
  cat <<EOF | sudo tee "$unit" >/dev/null
# Managed by application-install
[Unit]
Description=Host route for Kubernetes IPv4 Service CIDR
Wants=network-online.target
After=network-online.target
Before=kubelet.service

[Service]
Type=oneshot
ExecStart=$(command -v ip) -4 route replace ${SERVICE_CIDR} dev ${NODE_INTERFACE} proto static metric 250
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  sudo chmod 0644 "$unit"
  sudo systemctl daemon-reload
  sudo systemctl enable testbed-service-cidr-route.service
  sudo systemctl restart testbed-service-cidr-route.service
  ip -4 route get "$SERVICE_IP"
}

prepare_namespaces() {
  local namespace
  for namespace in monitoring kepler chaos-mesh cpu-lab; do
    kubectl get namespace "$namespace" --ignore-not-found -o json > "$BUILD_DIR/namespace-check.json"
    python3 - "$BUILD_DIR/namespace-check.json" "$MANAGER" <<'PY'
import json,pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text().strip()
if s:
    d=json.loads(s)
    if d['metadata'].get('labels',{}).get('testbed.lab/managed-by')!=sys.argv[2]:
        sys.exit('Existing namespace is not managed by this installer: '+d['metadata']['name'])
PY
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "$namespace" testbed.lab/managed-by="$MANAGER" --overwrite
  done
  kubectl annotate namespace cpu-lab chaos-mesh.org/inject=enabled --overwrite
  kubectl label node "$NODE_NAME" testbed.lab/energy-sensor="$SENSOR_STATE" --overwrite
  if kubectl -n monitoring get secret grafana-admin --ignore-not-found -o json > "$BUILD_DIR/grafana-secret-check.json"; then
    python3 - "$BUILD_DIR/grafana-secret-check.json" "$BUILD_DIR/credentials" <<'PY'
import base64,json,pathlib,sys
raw=pathlib.Path(sys.argv[1]).read_text().strip()
if raw:
    d=json.loads(raw);root=pathlib.Path(sys.argv[2])
    for key,name in [('admin-user','grafana-user.txt'),('admin-password','grafana-password.txt')]:
        (root/name).write_bytes(base64.b64decode(d['data'][key]))
PY
  fi
  rm -f "$BUILD_DIR/grafana-secret-check.json"
  if [[ ! -s "$BUILD_DIR/credentials/grafana-password.txt" ]]; then
    printf admin > "$BUILD_DIR/credentials/grafana-user.txt"
    openssl rand -hex 16 | tr -d '\n' > "$BUILD_DIR/credentials/grafana-password.txt"
  fi
  chmod 0600 "$BUILD_DIR/credentials/"*.txt
  kubectl -n monitoring create secret generic grafana-admin \
    --from-file=admin-user="$BUILD_DIR/credentials/grafana-user.txt" \
    --from-file=admin-password="$BUILD_DIR/credentials/grafana-password.txt" \
    --dry-run=client -o yaml | kubectl apply -f -
}

prepull_images() {
  local image
  info 'Pulling application images into containerd before Helm installation.'
  while IFS= read -r image; do
    info "Pulling ${image}"
    sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
      --image-endpoint unix:///run/containerd/containerd.sock pull "$image"
  done < "$BUILD_DIR/images.txt"
}

install_release() {
  local release=$1 namespace=$2 chart=$3 values=$4 expected=$5
  helm list -n "$namespace" -a -o json > "$BUILD_DIR/release-check.json"
  python3 - "$BUILD_DIR/release-check.json" "$release" "$expected" <<'PY'
import json,sys
for release in json.load(open(sys.argv[1])):
    if release['name']==sys.argv[2] and release['chart']!=sys.argv[3]:
        sys.exit('Existing Helm release has another chart/version; automatic replacement refused: '+release['chart'])
PY
  helm upgrade --install "$release" "$BUILD_DIR/charts/$chart" --namespace "$namespace" \
    -f "$BUILD_DIR/$values" --post-renderer "$BUILD_DIR/helm-post-renderer.py" \
    --wait --timeout 10m --history-max 5
}

install_applications() {
  install_release monitoring monitoring monitoring.tgz monitoring-values.yaml "kube-prometheus-stack-${KPS_VERSION}"
  install_release kepler kepler kepler.tgz kepler-values.yaml "kepler-${KEPLER_VERSION}"
  # The namespace filter needs read-only Namespace access during controller startup.
  kubectl apply -f "$BUILD_DIR/chaos-access-rbac.yaml"
  install_release chaos-mesh chaos-mesh chaos.tgz chaos-values.yaml "chaos-mesh-${CHAOS_VERSION}"
  kubectl wait --for=condition=Established crd/stresschaos.chaos-mesh.org --timeout=120s
  kubectl apply -f "$BUILD_DIR/ubuntu-test.yaml"
  kubectl -n cpu-lab rollout status deployment/ubuntu-test --timeout=180s
  kubectl apply -f "$BUILD_DIR/dashboard-configmap.yaml"
  # Exercise the actual admission webhook/schema without starting CPU stress.
  kubectl apply --dry-run=server -f "$BUILD_DIR/cpu-stress.yaml"
  kubectl auth can-i create stresschaos.chaos-mesh.org -n cpu-lab \
    --as=system:serviceaccount:cpu-lab:chaos-lab-manager
  kubectl -n cpu-lab create token chaos-lab-manager --duration=24h > "$BUILD_DIR/credentials/chaos-token.txt"
  chmod 0600 "$BUILD_DIR/credentials/chaos-token.txt"
}

verify_metrics() {
  local port=19090 ready=0
  info 'Verifying Prometheus health and real CPU telemetry.'
  kubectl -n monitoring port-forward --address=127.0.0.1 service/monitoring-prometheus \
    "${port}:9090" > "$BUILD_DIR/prometheus-check-portforward.log" 2>&1 &
  VERIFY_PID=$!
  for _ in {1..30}; do
    kill -0 "$VERIFY_PID" 2>/dev/null || die 'Temporary Prometheus port-forward failed. Inspect its log or free localhost:19090.'
    if curl -fsS --max-time 3 "http://127.0.0.1:${port}/-/ready" >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  [[ "$ready" == 1 ]] || die 'Prometheus did not become ready through port-forward.'
  local query='count(container_cpu_usage_seconds_total{namespace="cpu-lab",container="ubuntu-test",pod=~"ubuntu-test-.*"})'
  ready=0
  for _ in {1..24}; do
    curl -fsS --get --max-time 10 "http://127.0.0.1:${port}/api/v1/query" \
      --data-urlencode "query=${query}" > "$BUILD_DIR/cpu-query.json"
    if python3 - "$BUILD_DIR/cpu-query.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));r=d.get('data',{}).get('result',[])
sys.exit(0 if d.get('status')=='success' and r and float(r[0]['value'][1])>0 else 1)
PY
    then ready=1; break; fi
    sleep 5
  done
  [[ "$ready" == 1 ]] || die 'Ubuntu-test CPU telemetry is missing in Prometheus. Inspect kubelet/cAdvisor targets.'
  if [[ "$SENSOR_STATE" == present ]]; then
    curl -fsS --get --max-time 10 "http://127.0.0.1:${port}/api/v1/query" \
      --data-urlencode 'query=max(up{job="kepler"})' > "$BUILD_DIR/kepler-query.json"
    python3 - "$BUILD_DIR/kepler-query.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])).get('data',{}).get('result',[])
if not r or float(r[0]['value'][1])!=1: sys.exit('Kepler target is not up. Check its Pod, logs and Service.')
print('Real-meter Kepler exporter is being scraped.')
PY
  else
    info 'Kepler chart installed with zero scheduled Pods: no real energy sensor candidates exposed by this VM.'
  fi
  kill "$VERIFY_PID" 2>/dev/null || true
  wait "$VERIFY_PID" 2>/dev/null || true
  VERIFY_PID=''
  info 'Real CPU telemetry verified. No stress load was started.'
}

verify_browser_services() {
  info 'Checking Grafana and Chaos Dashboard through their IPv6 NodePorts.'
  python3 - "$BUILD_DIR/context.json" <<'PY'
import json,subprocess,sys
state=json.load(open(sys.argv[1]));host='['+state['ipv6']+']'
for namespace,name,port,path in [('monitoring','grafana',30000,'/api/health'),('chaos-mesh','chaos-dashboard',30001,'/')]:
    svc=json.loads(subprocess.check_output(['kubectl','-n',namespace,'get','svc',name,'-o','json']))
    spec=svc['spec']
    if spec.get('type')!='NodePort' or spec.get('ipFamilies')!=['IPv4','IPv6'] or spec['ports'][0].get('nodePort')!=port:
        sys.exit('Browser Service does not have the expected dual-stack NodePort: '+name)
    url='http://'+host+':'+str(port)+path
    subprocess.run(['curl','-g','-6','--noproxy','*','-fsS','--connect-timeout','5','--max-time','15',url],check=True,stdout=subprocess.DEVNULL)
    print('IPv6 NodePort OK:',name,url)
PY
}

main() {
  while (($#)); do
    case "$1" in
      --check) CHECK_ONLY=1 ;;
      --credentials) CREDENTIAL_MODE=show ;;
      --renew-chaos-token) CREDENTIAL_MODE=renew ;;
      --help|-h) usage; return 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
  if [[ -n "$CREDENTIAL_MODE" ]]; then
    [[ "$CHECK_ONLY" == 0 ]] || die 'Use --check separately from the credential options.'
    show_credentials "$CREDENTIAL_MODE"
    return 0
  fi
  preflight
  [[ "$CHECK_ONLY" == 0 ]] || return 0
  exec > >(tee -a "$BUILD_DIR/application-install-$(date -u +%Y%m%dT%H%M%SZ).log") 2>&1
  prepare_charts
  generate_assets
  render_charts
  prepull_images
  ensure_service_route
  prepare_namespaces
  install_applications
  verify_browser_services
  verify_metrics
  info 'Application installation completed. Browser access instructions:'
  printf '%s/ACESSO.md\n' "$BUILD_DIR"
  printf 'Grafana: TCP 30000; Chaos Dashboard: TCP 30001 on the node IPv6. See ACESSO.md.\n'
  printf 'Optional SSH forwarding on the VM: %s/application_access.sh\n' "$BUILD_DIR"
  printf 'Grafana password file: %s/credentials/grafana-password.txt\n' "$BUILD_DIR"
  printf 'Chaos Dashboard token file: %s/credentials/chaos-token.txt\n' "$BUILD_DIR"
  printf 'Show logins and renew an expired Chaos token: %s/application_install.sh --credentials\n' "$SCRIPT_DIR"
  kubectl get pods -A -o wide
  helm list -A
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi

