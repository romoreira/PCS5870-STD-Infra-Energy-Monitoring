#!/usr/bin/env bash
# Pod energy estimates from the official legacy Kepler local regression models.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_BUILD_DIR:-${SCRIPT_DIR}/build/applications}"
BUILD_DIR="${KEPLER_ESTIMATED_DIR:-${APP_DIR}/kepler-estimated}"
IMAGE='quay.io/sustainable_computing_io/kepler@sha256:1c822681f48d8c6f66a4613987007107322e5320f695c1cd284cef2d343bf24b'
FORWARD_PID=''
info() { printf '\n[INFO] %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n "$FORWARD_PID" ]]; then kill "$FORWARD_PID" 2>/dev/null || true; fi; }
on_error() {
  local rc=$?
  trap - ERR
  ((BASH_SUBSHELL==0)) || exit "$rc"
  printf '\n[ERROR] Kepler energy installation stopped at line %s (exit %s).\n' "$1" "$rc" >&2
  kubectl --request-timeout=10s -n kepler-estimated get pods -o wide >&2 || true
  kubectl --request-timeout=10s -n kepler-estimated logs ds/kepler-estimated --tail=100 >&2 || true
  printf 'Diagnostics: %s. No cluster reset or automatic uninstall was performed.\n' "$BUILD_DIR" >&2
  exit "$rc"
}
trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

preflight() {
  local cmd
  for cmd in kubectl helm python3 curl; do command -v "$cmd" >/dev/null || die "Missing command: ${cmd}"; done
  python3 -c 'import yaml' || die 'Install python3-yaml first.'
  [[ -f "$APP_DIR/context.json" ]] || die 'Application context not found. Place this script beside application_install.sh or set APP_BUILD_DIR.'
  mkdir -p "$BUILD_DIR"
  chmod 0700 "$BUILD_DIR"
  python3 - "$APP_DIR" "$BUILD_DIR" <<'PY'
import json,pathlib,subprocess,sys,urllib.parse
app=pathlib.Path(sys.argv[1]);root=pathlib.Path(sys.argv[2]);state=json.loads((app/'context.json').read_text())
def get(*args):return json.loads(subprocess.check_output(['kubectl','--request-timeout=15s',*args,'-o','json']))
if get('get','namespace','kube-system')['metadata']['uid']!=state['cluster_uid']:
    sys.exit('Current kubectl context belongs to another cluster.')
nodes=get('get','nodes')['items']
if len(nodes)!=1 or nodes[0]['metadata']['name']!=state['node']:sys.exit('This script targets the existing single-node lab.')
if not any(c['type']=='Ready' and c['status']=='True' for c in nodes[0]['status']['conditions']):sys.exit('Node is not Ready.')
conf=json.loads(subprocess.check_output(['kubectl','config','view','--minify','-o','json']))
url=urllib.parse.urlparse(conf['clusters'][0]['cluster']['server'])
state['api_host']=url.hostname;state['api_port']=url.port or 443
prom=get('-n','monitoring','get','prometheus','monitoring-prometheus')
selector=prom['spec'].get('serviceMonitorSelector')
labels={'release':'monitoring','app.kubernetes.io/name':'kepler','app.kubernetes.io/instance':'kepler-estimated','app.kubernetes.io/managed-by':'Helm','helm.sh/chart':'kepler-0.6.2'}
if selector is None:sys.exit('Prometheus does not select ServiceMonitors.')
if any(labels.get(k)!=v for k,v in selector.get('matchLabels',{}).items()) or selector.get('matchExpressions'):
    sys.exit('Unexpected Prometheus ServiceMonitor selector; inspect it before installing.')
workload=get('-n','cpu-lab','get','deployment','ubuntu-test')
if workload.get('status',{}).get('availableReplicas',0)<1:sys.exit('Ubuntu-test deployment is not available.')
if pathlib.Path('/sys/kernel/btf/vmlinux').is_file():print('Kernel BTF present for eBPF.')
else:sys.exit('Kernel BTF /sys/kernel/btf/vmlinux is unavailable. Kepler eBPF needs kernel support.')
(root/'context.json').write_text(json.dumps(state,indent=2)+'\n')
print('Node:',state['node'],'API:',state['api_host'],state['api_port'])
print('Mode: pretrained local regression; pod energy is estimated, without a calibrated error bound.')
PY
}

generate_assets() {
  python3 - "$BUILD_DIR" <<'GENERATOR'
"""Generate a separately managed legacy Kepler estimator and Grafana dashboard."""
import json
import pathlib
import sys
import yaml


def generate(root, state):
    root = pathlib.Path(root)
    root.mkdir(parents=True, exist_ok=True)
    values = {
        'fullnameOverride': 'kepler-estimated',
        'image': {'repository': 'quay.io/sustainable_computing_io/kepler',
                  'tag': 'release-0.8.0',
                  'digest': 'sha256:1c822681f48d8c6f66a4613987007107322e5320f695c1cd284cef2d343bf24b',
                  'pullPolicy': 'IfNotPresent'},
        'nodeSelector': {'kubernetes.io/hostname': state['node']},
        'canMount': {'usrSrc': False},
        'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                      'limits': {'cpu': '1', 'memory': '512Mi'}},
        'modelServer': {'enabled': False},
        'extraEnvVars': {
            'KEPLER_LOG_LEVEL': '3', 'KEPLER_NAMESPACE': 'kepler-estimated',
            'ENABLE_GPU': 'false', 'ENABLE_QAT': 'false', 'ENABLE_MSR': 'false',
            'ENABLE_API_SERVER': 'true', 'ENABLE_EBPF_CGROUPID': 'true',
            'ENABLE_PROCESS_METRICS': 'false', 'EXPOSE_VM_METRICS': 'false',
            'EXPOSE_CONTAINER_METRICS': 'true', 'EXPOSE_COMPONENT_POWER': 'true',
            'EXPOSE_ESTIMATED_IDLE_POWER_METRICS': 'false',
            'MODEL_SERVER_ENABLE': 'false',
            'MODEL_CONFIG': 'NODE_COMPONENTS_LOCAL_REGRESSOR=true\nNODE_TOTAL_LOCAL_REGRESSOR=true\nPROCESS_COMPONENTS_ESTIMATOR=false\nPROCESS_TOTAL_ESTIMATOR=false\n',
            'KUBERNETES_SERVICE_HOST': state['api_host'],
            'KUBERNETES_SERVICE_PORT': str(state['api_port']),
            'KUBERNETES_SERVICE_PORT_HTTPS': str(state['api_port']),
        },
        'serviceMonitor': {
            'enabled': True, 'namespace': 'monitoring', 'interval': '5s',
            'scrapeTimeout': '4s', 'labels': {'release': 'monitoring'},
            'relabelings': [
                {'action': 'replace', 'sourceLabels': ['__meta_kubernetes_pod_node_name'], 'targetLabel': 'instance'},
                {'action': 'replace', 'targetLabel': 'job', 'replacement': 'kepler-estimated'}]},
    }
    (root/'values.yaml').write_text(yaml.safe_dump(values, sort_keys=False))
    renderer = r'''#!/usr/bin/env python3
import sys,yaml
docs=[]
for d in yaml.safe_load_all(sys.stdin):
    if d is None:continue
    if not isinstance(d,dict) or not d.get('kind'):sys.exit('Unexpected non-resource YAML')
    if d['kind']=='DaemonSet':
        spec=d['spec']['template']['spec'];spec['hostPID']=True
        spec['dnsPolicy']='ClusterFirstWithHostNet'
        for c in spec.get('containers',[]):
            c['startupProbe'].update({'failureThreshold':30,'periodSeconds':5,'timeoutSeconds':3})
    docs.append(d)
yaml.safe_dump_all(docs,sys.stdout,sort_keys=False)
'''
    (root/'post-render.py').write_text(renderer)
    (root/'post-render.py').chmod(0o755)
    selector = 'job="kepler-estimated",container_namespace="$namespace",pod_name=~"$pod",mode="dynamic"'
    metric = 'kepler_container_joules_total{'+selector+'}'
    panels = [{
        'id': 1, 'type': 'text', 'title': 'Estimativa por modelo — Kepler legado',
        'gridPos': {'x': 0, 'y': 0, 'w': 24, 'h': 5},
        'options': {'mode': 'markdown', 'content':
            '**Estimativa de energia dinâmica atribuída aos containers do pod.** Kepler release-0.8.0 '
            'usa os modelos oficiais locais de regressão e atividade real de CPU/eBPF. '
            'Os coeficientes não foram calibrados para o host desta VM; não há precisão garantida em watts. '
            'A parcela ociosa do host não está incluída. Dados ausentes ficam indisponíveis.\n\n'
            '**Teste:** Chaos Mesh → namespace `cpu-lab`, label `app=ubuntu-test`, '
            '3 CPU workers, load 80%, duração 120s. Selecione o mesmo intervalo no Grafana. '
            'W = potência; J = energia acumulada. O instalador não inicia carga.'}}]

    def panel(title, expr, x, y, unit, kind='timeseries', w=12):
        p = {'id': len(panels)+1, 'title': title, 'type': kind,
             'gridPos': {'x': x, 'y': y, 'w': w, 'h': 8},
             'datasource': {'type': 'prometheus', 'uid': 'prometheus'},
             'targets': [{'refId': 'A', 'expr': expr, 'legendFormat': '{{pod_name}}'}],
             'fieldConfig': {'defaults': {'unit': unit, 'noValue': 'Indisponível'}, 'overrides': []},
             'options': {'legend': {'displayMode': 'list', 'placement': 'bottom'}}}
        if kind == 'stat':p['targets'][0]['instant'] = True
        panels.append(p)

    watts = 'sum by (pod_name) (rate('+metric+'[1m]))'
    energy = 'sum by (pod_name) (increase('+metric+'[$__range]))'
    panel('Pod — potência dinâmica estimada (W)', watts, 0, 5, 'watt')
    panel('Pod — energia dinâmica estimada no intervalo (J)', energy, 12, 5, 'joule', 'stat')
    cpu = 'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="$namespace",pod=~"$pod",container!="",container!="POD"}[1m]))'
    panel('Pod — CPU utilizada (núcleos)', cpu, 0, 13, 'cores')
    panels[-1]['targets'][0]['legendFormat'] = '{{pod}}'
    panel('Pod — energia dinâmica estimada no intervalo (Wh)', '('+energy+') / 3600', 12, 13, 'watth', 'stat')
    panel('Pod — potência dinâmica estimada do pacote CPU (W)',
          'sum by (pod_name) (rate(kepler_container_package_joules_total{'+selector+'}[1m]))', 0, 21, 'watt')
    panel('Pod — energia dinâmica estimada nos últimos 120s (J)',
          'sum by (pod_name) (increase('+metric+'[120s]))', 12, 21, 'joule', 'stat')
    panel('Kepler — coleta ativa (1 = sim)', 'max(up{job="kepler-estimated"})', 0, 29, 'short', 'stat')
    panel('Kepler — séries de energia do pod', 'count('+metric+')', 12, 29, 'short', 'stat')
    dashboard = {
        'uid': 'pod-energy-estimated', 'title': 'Pod Energy — Kepler Estimated',
        'schemaVersion': 39, 'version': 1, 'editable': True, 'refresh': '5s',
        'timezone': 'browser', 'time': {'from': 'now-15m', 'to': 'now'},
        'tags': ['kepler', 'estimated', 'pod', 'cpu-lab'], 'panels': panels,
        'templating': {'list': [
            {'name': 'namespace', 'label': 'Namespace', 'type': 'query',
             'datasource': {'type': 'prometheus', 'uid': 'prometheus'},
             'query': 'label_values(kepler_container_joules_total{job="kepler-estimated"}, container_namespace)',
             'current': {'text': 'cpu-lab', 'value': 'cpu-lab'}, 'refresh': 1},
            {'name': 'pod', 'label': 'Pod', 'type': 'query',
             'datasource': {'type': 'prometheus', 'uid': 'prometheus'},
             'query': 'label_values(kepler_container_joules_total{job="kepler-estimated",container_namespace="$namespace"}, pod_name)',
             'includeAll': True, 'allValue': '.*', 'multi': False,
             'current': {'text': 'All', 'value': '$__all'}, 'refresh': 1}]}}
    (root/'pod-energy-dashboard.json').write_text(json.dumps(dashboard, ensure_ascii=False, indent=2)+'\n')
    cm = {'apiVersion': 'v1', 'kind': 'ConfigMap',
          'metadata': {'name': 'pod-energy-estimated-dashboard', 'namespace': 'monitoring',
                       'labels': {'grafana_dashboard': '1', 'testbed.lab/managed-by': 'kepler-pod-energy'}},
          'data': {'pod-energy-estimated.json': json.dumps(dashboard, ensure_ascii=False)}}
    (root/'dashboard.yaml').write_text(yaml.safe_dump(cm, sort_keys=False))


if __name__ == '__main__':
    root = pathlib.Path(sys.argv[1])
    generate(root, json.loads((root/'context.json').read_text()))

GENERATOR
}

prepare_chart() {
  info 'Downloading the pinned legacy chart.'
  curl -fLsS --connect-timeout 10 --max-time 180 --retry 2 \
    https://github.com/sustainable-computing-io/kepler-helm-chart/releases/download/kepler-0.6.2/kepler-0.6.2.tgz \
    -o "$BUILD_DIR/kepler-0.6.2.tgz"
  python3 - "$BUILD_DIR/kepler-0.6.2.tgz" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1])
if hashlib.sha256(p.read_bytes()).hexdigest()!='c76689bd87ca37a0101bc85f13ea31e6d569c5c9a7d69d00c5f08db3d7e72296':sys.exit('Legacy chart checksum mismatch.')
print('Chart SHA-256 verified.')
PY
  helm template kepler-estimated "$BUILD_DIR/kepler-0.6.2.tgz" -n kepler-estimated \
    --kube-version "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["kube_version"])' "$BUILD_DIR/context.json")" \
    -f "$BUILD_DIR/values.yaml" --post-renderer "$BUILD_DIR/post-render.py" > "$BUILD_DIR/rendered.yaml"
}

install_estimator() {
  command -v crictl >/dev/null || die 'crictl is required on the Kubernetes VM.'
  if ! sudo -n true 2>/dev/null; then sudo -v; fi
  info 'Pulling the pinned Kepler release-0.8.0 image into containerd.'
  sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
    --image-endpoint unix:///run/containerd/containerd.sock pull "$IMAGE"
  if kubectl get namespace kepler-estimated -o json > "$BUILD_DIR/namespace.json" 2>/dev/null; then
    python3 - "$BUILD_DIR/namespace.json" <<'PY'
import json,sys
if json.load(open(sys.argv[1]))['metadata'].get('labels',{}).get('testbed.lab/managed-by')!='kepler-pod-energy':
    sys.exit('Existing kepler-estimated namespace is not owned by this installer.')
PY
  else
    kubectl create namespace kepler-estimated
    kubectl label namespace kepler-estimated testbed.lab/managed-by=kepler-pod-energy
  fi
  kubectl label namespace kepler-estimated pod-security.kubernetes.io/enforce=privileged --overwrite
  helm list -n kepler-estimated -a -o json > "$BUILD_DIR/releases.json"
  python3 - "$BUILD_DIR/releases.json" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
    if r['name']=='kepler-estimated' and r['chart']!='kepler-0.6.2':sys.exit('Existing estimator release has another chart version.')
PY
  helm upgrade --install kepler-estimated "$BUILD_DIR/kepler-0.6.2.tgz" -n kepler-estimated \
    -f "$BUILD_DIR/values.yaml" --post-renderer "$BUILD_DIR/post-render.py" --wait --timeout 5m --history-max 5
  kubectl -n kepler-estimated rollout status daemonset/kepler-estimated --timeout=120s
  kubectl apply -f "$BUILD_DIR/dashboard.yaml"
}

query() {
  curl -fsS --get --max-time 10 http://127.0.0.1:19091/api/v1/query \
    --data-urlencode "query=$1" -o "$BUILD_DIR/query.json" || return 1
  python3 - "$BUILD_DIR/query.json" <<'PY'
import json,sys,math
d=json.load(open(sys.argv[1]));r=d.get('data',{}).get('result',[])
if d.get('status')!='success' or not r:sys.exit(1)
sys.exit(0 if any(math.isfinite(float(x['value'][1])) and float(x['value'][1])>0 for x in r) else 1)
PY
}

verify_estimates() {
  info 'Checking energy counters for the actual Ubuntu pod in Prometheus.'
  kubectl -n monitoring port-forward --address=127.0.0.1 svc/monitoring-prometheus 19091:9090 \
    > "$BUILD_DIR/port-forward.log" 2>&1 &
  FORWARD_PID=$!
  local ready=0
  for _ in {1..30}; do
    kill -0 "$FORWARD_PID" 2>/dev/null || die 'Temporary Prometheus forwarding failed; inspect port-forward.log or free port 19091.'
    if curl -fsS --max-time 2 http://127.0.0.1:19091/-/ready >/dev/null 2>&1; then ready=1;break;fi
    sleep 1
  done
  [[ "$ready" == 1 ]] || die 'Prometheus did not become reachable.'
  # Ensure a process from the sleeping target container is observed by eBPF.
  # Sleeping briefly only exercises pod discovery; it does not generate stress.
  kubectl -n cpu-lab exec deployment/ubuntu-test -c ubuntu-test -- /bin/sleep 8
  ready=0
  for _ in {1..36}; do
    if query 'count(kepler_container_joules_total{job="kepler-estimated",container_namespace="cpu-lab",pod_name=~"ubuntu-test-.*",mode="dynamic"})'; then ready=1;break;fi
    sleep 5
  done
  [[ "$ready" == 1 ]] || die 'No Ubuntu energy counter found. Check Kepler eBPF/pod discovery, model initialization and Prometheus targets. No synthetic substitute was enabled.'
  query 'count(kepler_node_info{job="kepler-estimated",components_power_source="estimator"})' \
    || die 'Kepler does not report the expected estimator source. Inspect its metrics and logs.'
  kubectl -n kepler-estimated logs ds/kepler-estimated > "$BUILD_DIR/exporter.log"
  python3 - "$BUILD_DIR/exporter.log" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
if 'Using weights from model' not in s or 'estimate Node Component Power' not in s:
    sys.exit('Energy counters exist, but trained-model initialization was not confirmed in logs. Inspect exporter.log.')
print('Local trained-model initialization confirmed; Ubuntu pod energy counters are present.')
PY
  kill "$FORWARD_PID" 2>/dev/null || true
  wait "$FORWARD_PID" 2>/dev/null || true
  FORWARD_PID=''
  info 'Pod energy estimate collection verified. No CPU stress was started.'
}

main() {
  local action=install
  case "${1:-}" in
    --check) action=check ;;
    --verify-only) action=verify ;;
    --help|-h) printf 'Usage: ./kepler_pod_energy_install.sh [--check | --verify-only]\nInstalls legacy Kepler with official pretrained local regression weights and a separate Grafana dashboard.\n';return ;;
    '') ;;
    *) die "Unknown option: $1" ;;
  esac
  (($#<=1)) || die 'Too many arguments.'
  preflight
  [[ "$action" != check ]] || return 0
  exec > >(tee -a "$BUILD_DIR/install-$(date -u +%Y%m%dT%H%M%SZ).log") 2>&1
  if [[ "$action" == install ]]; then
    generate_assets
    prepare_chart
    install_estimator
  fi
  verify_estimates
  printf '\nGrafana via your existing SSH tunnel: http://localhost:3000/d/pod-energy-estimated\n'
  printf 'Dashboard: Pod Energy — Kepler Estimated. Namespace: cpu-lab. Select the Ubuntu pod.\n'
  printf 'Create your 120s CPU experiment in Chaos Mesh and compare watts/joules. Values are estimates.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi

