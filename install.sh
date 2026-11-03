#!/usr/bin/env bash
# Adaptation of https://github.com/niloysh/testbed-automator for a single
# Ubuntu 22.04 VM with private IPv4 and an IPv6 default route.
# Full scope: kubeadm + containerd + dual-stack Flannel + Multus + OVS CNI
# + n2br/n3br/n4br + OpenEBS LocalPV Hostpath. Run as a regular sudo user.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/kubeadm-config.yaml}"
BUILD_DIR="${SCRIPT_DIR}/build"
NODE_INTERFACE="${NODE_INTERFACE:-enp3s0}"
K8S_MINOR="1.35"
FLANNEL_VERSION="v0.28.6"
MULTUS_VERSION="v4.3.0"
OVS_VERSION="v0.40.0"
HELM_VERSION="v3.19.0"
LOCALPV_VERSION="4.2.0"
CHECK_ONLY=0
KUBECTL_READY=0

info() { printf '\n[INFO] %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
on_error() {
  local rc=$?
  trap - ERR
  # Command substitutions inherit ERR; let the parent report the failure once.
  if (( BASH_SUBSHELL > 0 )); then
    exit "$rc"
  fi
  printf '\n[ERROR] Installation stopped at line %s (exit %s).\n' "$1" "$rc" >&2
  if [[ "$KUBECTL_READY" == 1 ]]; then
    kubectl --request-timeout=10s get pods -A -o wide >&2 || true
    kubectl --request-timeout=10s get events -A --sort-by=.lastTimestamp >&2 || true
  fi
  printf 'Inspect the error above. No automatic kubeadm reset was performed.\n' >&2
  exit "$rc"
}
trap 'on_error "$LINENO"' ERR

usage() {
  cat <<'HELP'
Usage: ./install.sh [--check]
  --check  Read-only host checks and HTTP download checks; no sudo or OS changes.
  --help   Show this help.

Run as a regular user with sudo permissions, on Ubuntu 22.04 amd64.
Both files must be in the same directory. No default IPv4 route is required.
Optional environment: NODE_INTERFACE, NODE_IPV4, NODE_IPV6, CONFIG_FILE.
This version targets one VM; --worker is intentionally not implemented.
An existing incompatible cluster is refused, never reset automatically.
HELP
}

fetch() {
  local url=$1 destination=$2
  if ! curl -fLsS --connect-timeout 10 --max-time 180 --retry 2 \
      --retry-delay 2 "$url" -o "$destination"; then
    printf '\nDownload failed: %s\n' "$url" >&2
    printf '%s\n' 'An IPv6 default route does not provide access to IPv4-only servers.' \
      'Check DNS64/NAT64, an existing proxy, or provide routed IPv4 connectivity.' \
      'The installer does not invent a gateway or change DNS/network addressing.' >&2
    return 1
  fi
}

inspect_host() {
  local c
  for c in ip python3 curl dpkg hostname; do
    command -v "$c" >/dev/null || die "Required command missing: ${c}"
  done
  [[ -f "$CONFIG_FILE" ]] || die "Missing kubeadm YAML: ${CONFIG_FILE}"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 22.04 ]] || \
    die 'This installer was prepared for Ubuntu 22.04.'
  [[ "$(dpkg --print-architecture)" == amd64 ]] || \
    die 'The OVS deployment in this package targets amd64.'
  [[ "$NODE_INTERFACE" =~ ^[a-zA-Z0-9_-]+$ ]] || die 'Invalid network interface name.'
  ip link show dev "$NODE_INTERFACE" >/dev/null
  local detected
  detected=$(ip -j address show dev "$NODE_INTERFACE" | python3 -c '
import ipaddress,json,sys
data=json.load(sys.stdin)[0]
selected=[]
for family,override in zip(("inet","inet6"),sys.argv[1:]):
    candidates=[a for a in data["addr_info"] if a["family"]==family
        and a.get("scope")=="global" and not a.get("deprecated",False)
        and not a.get("tentative",False) and not a.get("temporary",False)]
    if override:
        if not any(a["local"]==override for a in candidates):
            sys.exit("Requested address is not assigned to the selected interface: "+override)
        value=override
    else:
        if len(candidates)!=1:
            sys.exit("Expected one stable address per family; set NODE_IPV4/NODE_IPV6 explicitly.")
        value=candidates[0]["local"]
    ipaddress.ip_address(value)
    selected.append(value)
print(" ".join(selected))
' "${NODE_IPV4:-}" "${NODE_IPV6:-}")
  read -r NODE_IPV4 NODE_IPV6 <<< "$detected"
  [[ -n "$(ip -6 route show default dev "$NODE_INTERFACE")" ]] || \
    die "No IPv6 default route on ${NODE_INTERFACE}."
  info "Interface ${NODE_INTERFACE}; private/node IPv4 ${NODE_IPV4}; node IPv6 ${NODE_IPV6}"
  ip -4 route show
  ip -6 route show default
  if [[ -z "$(ip -4 route show default)" ]]; then
    info 'No IPv4 default route: using IPv6 for reachable Internet destinations.'
  fi
}

download_checks() {
  local url
  info 'Checking the actual package/manifest/chart endpoints.'
  for url in \
    "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    "https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel.yml" \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset.yml" \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/${OVS_VERSION}/manifests/ovs-cni.yml.in" \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
    "https://openebs.github.io/dynamic-localpv-provisioner/localpv-provisioner-${LOCALPV_VERSION}.tgz"; do
    printf 'Checking %s\n' "$url"
    fetch "$url" /dev/null
  done
  info 'HTTP checks passed. Container image pulls are checked during installation.'
}

check_existing_installation() {
  # Do this before package changes; never turn an old cluster into an implicit upgrade.
  if sudo test -f /etc/kubernetes/admin.conf; then
    sudo test -f /etc/kubernetes/testbed-dualstack-owner || \
      die 'An existing cluster was not created by this installer. Stop; do not overwrite or reset it.'
    local old_minor
    old_minor=$(sudo cat /etc/kubernetes/testbed-dualstack-owner)
    [[ "$old_minor" == "$K8S_MINOR" ]] || die 'Existing cluster uses a different Kubernetes minor version.'
  elif sudo test -f /etc/kubernetes/manifests/kube-apiserver.yaml; then
    die 'An incomplete kubeadm installation exists. Inspect it before proceeding; no automatic cleanup.'
  else
    local package version
    for package in kubeadm kubelet kubectl; do
      version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)
      [[ -z "$version" || "$version" == "${K8S_MINOR}."* ]] || \
        die "${package} ${version} is already installed. This script does not upgrade an older cluster."
    done
    # Do not replace an unrelated CNI configuration.
    if sudo test -d /etc/cni/net.d && \
        [[ -n "$(sudo find /etc/cni/net.d -maxdepth 1 -type f \( -name '*.conf' -o -name '*.conflist' \) -print -quit)" ]]; then
      die 'Existing CNI files found. Inspect the previous installation before running this installer.'
    fi
  fi
}

install_packages() {
  info 'Installing Ubuntu prerequisites and Kubernetes packages.'
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg python3 python3-yaml python3-toml iproute2 iputils-ping \
    conntrack socat iptables ebtables ethtool jq git vim tmux tcpdump \
    containerd openvswitch-switch
  sudo install -d -m 0755 /etc/apt/keyrings
  fetch "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" "${BUILD_DIR}/kubernetes.key"
  sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${BUILD_DIR}/kubernetes.key"
  sudo chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' \
    "$K8S_MINOR" | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  sudo chmod 0644 /etc/apt/sources.list.d/kubernetes.list
  sudo apt-get update
  local version
  # Consume the whole producer output: early awk exit can SIGPIPE apt-cache
  # and turn a successful selection into exit 141 under set -o pipefail.
  version=$(apt-cache madison kubeadm | awk -v prefix="${K8S_MINOR}." \
    'index($3,prefix)==1 && !found {print $3; found=1}')
  [[ -n "$version" ]] || die "No Kubernetes ${K8S_MINOR} package is available."
  if sudo test -f /etc/kubernetes/admin.conf; then
    # Resume at the exact installed package version; do not upgrade implicitly.
    version=$(dpkg-query -W -f='${Version}' kubeadm)
  fi
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages \
    "kubeadm=${version}" "kubelet=${version}" "kubectl=${version}" cri-tools
  sudo apt-mark hold kubeadm kubelet kubectl
  # Backup once per run before changing host configuration.
  BACKUP_DIR="/var/backups/testbed-automator/$(date -u +%Y%m%dT%H%M%SZ)"
  sudo install -d -m 0700 "$BACKUP_DIR"
  info "Host configuration backups: ${BACKUP_DIR}"
}

render_config() {
  info 'Rendering kubeadm configuration from the current interface addresses.'
  K8S_VERSION=$(kubeadm version -o short)
  python3 - "$CONFIG_FILE" "${BUILD_DIR}/kubeadm-config.rendered.yaml" \
    "$NODE_INTERFACE" "$NODE_IPV4" "$NODE_IPV6" "$K8S_VERSION" "$(hostname -s)" <<'PY'
import ipaddress,json,pathlib,subprocess,sys,yaml
src,dst,interface,v4,v6,version,hostname=sys.argv[1:]
docs=list(yaml.safe_load_all(pathlib.Path(src).read_text()))
by_kind={d["kind"]:d for d in docs if isinstance(d,dict)}
required={"InitConfiguration","ClusterConfiguration","KubeletConfiguration","KubeProxyConfiguration"}
if set(by_kind)!=required or len(docs)!=4:
    sys.exit("Expected exactly four kubeadm/kubelet/kube-proxy documents.")
init,cluster=by_kind["InitConfiguration"],by_kind["ClusterConfiguration"]
for d in (init,cluster):
    if d.get("apiVersion")!="kubeadm.k8s.io/v1beta4": sys.exit("Use kubeadm v1beta4.")
net=cluster["networking"]
pairs=[]
for key in ("podSubnet","serviceSubnet"):
    pair=[ipaddress.ip_network(s.strip(),strict=True) for s in net[key].split(",")]
    if [n.version for n in pair]!=[4,6]: sys.exit(key+" must be IPv4,IPv6 in that order.")
    pairs.append(pair)
pods,services=pairs
if pods[0].prefixlen>24 or pods[1].prefixlen>64: sys.exit("Pod CIDR is smaller than the per-node allocation.")
if services[1].prefixlen<108: sys.exit("Use an IPv6 Service CIDR of /108 or smaller size, e.g. /112.")
all_networks=pods+services
for i,a in enumerate(all_networks):
    for b in all_networks[i+1:]:
        if a.version==b.version and a.overlaps(b): sys.exit("Overlapping Pod/Service CIDRs.")
for iface in json.loads(subprocess.check_output(["ip","-j","address","show"])):
    # On resume, cni0/flannel interfaces legitimately belong to the Pod CIDR.
    if iface["ifname"]!=interface: continue
    for addr in iface.get("addr_info",[]):
        host=ipaddress.ip_interface(f'{addr["local"]}/{addr["prefixlen"]}').network
        if any(host.version==n.version and host.overlaps(n) for n in all_networks):
            sys.exit("Pod/Service CIDR overlaps the host interface network.")
init["localAPIEndpoint"]["advertiseAddress"]=v4
init["nodeRegistration"]["name"]=hostname
args=init["nodeRegistration"].setdefault("kubeletExtraArgs",[])
args[:]=[a for a in args if a["name"]!="node-ip"]+[{"name":"node-ip","value":f"{v4},{v6}"}]
cluster["kubernetesVersion"]=version
cluster["controlPlaneEndpoint"]=f"{v4}:6443"
cluster["apiServer"]["certSANs"]=list(dict.fromkeys([hostname,"localhost","127.0.0.1","::1",v4,v6]))
by_kind["KubeProxyConfiguration"]["clusterCIDR"]=net["podSubnet"]
for candidate in ("/run/systemd/resolve/resolv.conf","/etc/resolv.conf"):
    p=pathlib.Path(candidate)
    if not p.is_file(): continue
    ns=[parts[1] for line in p.read_text().splitlines()
        if len(parts:=line.split())>1 and parts[0]=="nameserver"]
    if ns and not any(ipaddress.ip_address(s.split("%")[0]).is_loopback for s in ns):
        by_kind["KubeletConfiguration"]["resolvConf"]=candidate
        break
else: sys.exit("No resolv.conf with non-loopback nameservers was found.")
pathlib.Path(dst).write_text(yaml.safe_dump_all(docs,sort_keys=False))
PY
  RENDERED_CONFIG="${BUILD_DIR}/kubeadm-config.rendered.yaml"
  kubeadm config validate --config "$RENDERED_CONFIG"
}

prepare_manifests() {
  info 'Preparing pinned CNI manifests; enabling both IP families in Flannel.'
  fetch "https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel.yml" "${BUILD_DIR}/flannel.upstream.yaml"
  fetch "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset.yml" "${BUILD_DIR}/multus.upstream.yaml"
  fetch "https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/${OVS_VERSION}/manifests/ovs-cni.yml.in" "${BUILD_DIR}/ovs.upstream.yaml.in"
  python3 - "$BUILD_DIR" "$NODE_INTERFACE" "$MULTUS_VERSION" "$OVS_VERSION" <<'PY'
import json,pathlib,sys,yaml
root=pathlib.Path(sys.argv[1]); interface,multus,ovs=sys.argv[2:]
cfg=list(yaml.safe_load_all((root/"kubeadm-config.rendered.yaml").read_text()))
cluster=next(d for d in cfg if d["kind"]=="ClusterConfiguration")
init=next(d for d in cfg if d["kind"]=="InitConfiguration")
api_host=init["localAPIEndpoint"]["advertiseAddress"]
api_port=str(init["localAPIEndpoint"]["bindPort"])
def use_direct_api(docs):
    # hostNetwork agents must bootstrap before Pod/Service networking works.
    # This VM has connected private IPv4 but no default IPv4 route, so the
    # Kubernetes Service IP cannot be assumed reachable from its host network.
    values={"KUBERNETES_SERVICE_HOST":api_host,"KUBERNETES_SERVICE_PORT":api_port,
        "KUBERNETES_SERVICE_PORT_HTTPS":api_port}
    for doc in docs:
        if not doc or doc.get("kind")!="DaemonSet": continue
        spec=doc["spec"]["template"]["spec"]
        if not spec.get("hostNetwork",False): continue
        for c in spec.get("containers",[])+spec.get("initContainers",[]):
            c["env"]=[e for e in c.get("env",[]) if e["name"] not in values]
            c["env"].extend({"name":k,"value":v} for k,v in values.items())
v4,v6=cluster["networking"]["podSubnet"].split(",")
docs=list(yaml.safe_load_all((root/"flannel.upstream.yaml").read_text()))
cm=next(d for d in docs if d and d["kind"]=="ConfigMap")
net=json.loads(cm["data"]["net-conf.json"])
net.update(Network=v4,IPv6Network=v6,EnableIPv4=True,EnableIPv6=True,IPv6SubnetLen=64)
cm["data"]["net-conf.json"]=json.dumps(net,indent=2)+"\n"
ds=next(d for d in docs if d and d["kind"]=="DaemonSet")
container=next(c for c in ds["spec"]["template"]["spec"]["containers"] if c["name"]=="kube-flannel")
container["args"]=[a for a in container["args"] if not a.startswith("--iface=")]+["--iface="+interface]
assert "--ip-masq" in container["args"]
container["readinessProbe"]={"exec":{"command":["/bin/sh","-c","test -s /run/flannel/subnet.env"]},
    "initialDelaySeconds":2,"periodSeconds":3,"timeoutSeconds":1,"failureThreshold":3}
container["terminationMessagePolicy"]="FallbackToLogsOnError"
use_direct_api(docs)
(root/"flannel.yaml").write_text(yaml.safe_dump_all(docs,sort_keys=False))
docs=list(yaml.safe_load_all((root/"multus.upstream.yaml").read_text()))
for doc in docs:
    if doc and doc["kind"]=="DaemonSet":
        spec=doc["spec"]["template"]["spec"]
        for c in spec.get("containers",[])+spec.get("initContainers",[]):
            c["image"]="ghcr.io/k8snetworkplumbingwg/multus-cni:"+multus
use_direct_api(docs)
(root/"multus.yaml").write_text(yaml.safe_dump_all(docs,sort_keys=False))
values={"NAMESPACE":"kube-system","CNI_MOUNT_PATH":"/opt/cni/bin",
    "OVS_CNI_PLUGIN_IMAGE_REPO":"ghcr.io/k8snetworkplumbingwg",
    "OVS_CNI_PLUGIN_IMAGE_NAME":"ovs-cni-plugin","OVS_CNI_PLUGIN_IMAGE_VERSION":ovs,
    "OVS_CNI_PLUGIN_IMAGE_PULL_POLICY":"IfNotPresent","OVS_CNI_MARKER_HEALTHCHECK_INTERVAL":"60"}
text=(root/"ovs.upstream.yaml.in").read_text()
# Substitute only upstream ${VARIABLE} tokens. Preserve Kubernetes $(NODE_NAME).
for key,value in values.items(): text=text.replace("${"+key+"}",value)
if "${" in text: sys.exit("An upstream OVS template variable was not handled.")
docs=list(yaml.safe_load_all(text))
for doc in docs:
    if doc and doc["kind"]=="DaemonSet":
        doc["spec"]["template"]["spec"]["tolerations"]=[{"operator":"Exists"}]
use_direct_api(docs)
(root/"ovs.yaml").write_text(yaml.safe_dump_all(docs,sort_keys=False))
PY
  fetch "https://openebs.github.io/dynamic-localpv-provisioner/localpv-provisioner-${LOCALPV_VERSION}.tgz" "${BUILD_DIR}/localpv-provisioner.tgz"
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "${BUILD_DIR}/helm.tgz"
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" "${BUILD_DIR}/helm.sha256sum"
  local expected
  expected=$(awk 'NR==1 {print $1}' "${BUILD_DIR}/helm.sha256sum")
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid Helm checksum file.'
  printf '%s  %s\n' "$expected" "${BUILD_DIR}/helm.tgz" | sha256sum --check --status
  tar --no-same-owner -xzf "${BUILD_DIR}/helm.tgz" -C "$BUILD_DIR" linux-amd64/helm
  sudo install -m 0755 "${BUILD_DIR}/linux-amd64/helm" /usr/local/bin/helm
  helm template openebs "${BUILD_DIR}/localpv-provisioner.tgz" --namespace openebs \
    --set hostpathClass.isDefaultClass=true --set analytics.enabled=false \
    > "${BUILD_DIR}/openebs.yaml"
}

backup_file() {
  if sudo test -e "$1"; then
    sudo cp -a --parents "$1" "$BACKUP_DIR"
  fi
}

configure_host_networking() {
  info 'Preserving IPv6 router advertisements before enabling forwarding.'
  backup_file /etc/fstab
  sudo swapoff -a
  sudo sed -i -E '/^[[:space:]]*#/! { /[[:space:]]swap[[:space:]]/ s/^/# testbed: /; }' /etc/fstab
  printf 'overlay\nbr_netfilter\nvxlan\n' | sudo tee /etc/modules-load.d/testbed-k8s.conf >/dev/null
  sudo modprobe overlay
  sudo modprobe br_netfilter
  sudo modprobe vxlan
  backup_file /etc/sysctl.d/99-testbed-dualstack.conf
  cat <<EOF | sudo tee /etc/sysctl.d/99-testbed-dualstack.conf >/dev/null
# Keep learning/renewing the IPv6 default route while acting as a router.
net.ipv6.conf.${NODE_INTERFACE}.accept_ra = 2
net.ipv6.conf.${NODE_INTERFACE}.accept_ra_defrtr = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
  # Apply this file in order, so accept_ra=2 precedes forwarding=1.
  sudo sysctl -p /etc/sysctl.d/99-testbed-dualstack.conf
  [[ -n "$(ip -6 route show default dev "$NODE_INTERFACE")" ]] || \
    die 'IPv6 default route disappeared. Check RA/netplan before proceeding.'
  # Do not change netplan, DNS, the IPv4 gateway, or disable the host firewall.
}

configure_runtime() {
  info 'Configuring containerd CRI with systemd cgroups.'
  local version pause_image
  version=$(containerd --version)
  info "Detected runtime: ${version}"
  sudo install -d -m 0755 /etc/containerd
  backup_file /etc/containerd/config.toml
  containerd config default > "${BUILD_DIR}/containerd.toml"
  pause_image=$(kubeadm config images list --config "$RENDERED_CONFIG" | awk '/\/pause:/ && !found {print; found=1}')
  [[ -n "$pause_image" ]] || die 'Could not determine the Kubernetes sandbox image.'
  python3 - "${BUILD_DIR}/containerd.toml" "$pause_image" <<'PY'
import pathlib,sys,toml
p=pathlib.Path(sys.argv[1]); cfg=toml.loads(p.read_text())
schema=cfg.get("version",1); plugins=cfg.get("plugins",{})
# Select the actual configuration schema, independent of version banners
# such as "1.7.28", "v1.7.28", or distro-specific build suffixes.
if schema==2 and "io.containerd.grpc.v1.cri" in plugins:
    runtime=plugins["io.containerd.grpc.v1.cri"]
    runtime["sandbox_image"]=sys.argv[2]
elif schema==3 and "io.containerd.cri.v1.runtime" in plugins and "io.containerd.cri.v1.images" in plugins:
    runtime=plugins["io.containerd.cri.v1.runtime"]
    plugins["io.containerd.cri.v1.images"].setdefault("pinned_images",{})["sandbox"]=sys.argv[2]
else:
    sys.exit(f"Unsupported containerd default configuration: schema {schema}, CRI plugins {list(plugins)}")
runc=runtime.get("containerd",{}).get("runtimes",{}).get("runc")
if not isinstance(runc,dict): sys.exit("The default runc runtime is missing.")
runc.setdefault("options",{})["SystemdCgroup"]=True
cri_ids={"cri","io.containerd.grpc.v1.cri","io.containerd.cri.v1.runtime","io.containerd.cri.v1.images"}
cfg["disabled_plugins"]=[item for item in cfg.get("disabled_plugins",[]) if item not in cri_ids]
p.write_text(toml.dumps(cfg))
print(f"Containerd schema {schema}: systemd cgroups enabled; sandbox image {sys.argv[2]}")
PY
  # Let the installed binary parse the complete configuration before applying it.
  containerd --config "${BUILD_DIR}/containerd.toml" config dump > "${BUILD_DIR}/containerd.effective.toml"
  sudo install -m 0644 "${BUILD_DIR}/containerd.toml" /etc/containerd/config.toml
  sudo systemctl enable --now containerd
  if ! sudo systemctl restart containerd; then
    sudo journalctl -u containerd -n 60 --no-pager >&2 || true
    die 'containerd could not start with the generated configuration.'
  fi
  sudo systemctl is-active --quiet containerd
  # NetworkReady can still be false here: Flannel has not been installed yet.
  # Keep the diagnostic JSON owned by the invoking user.
  # shellcheck disable=SC2024
  sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
    --image-endpoint unix:///run/containerd/containerd.sock info > "${BUILD_DIR}/cri-info.json"
  python3 - "${BUILD_DIR}/cri-info.json" <<'PY'
import json,pathlib,sys
info=json.loads(pathlib.Path(sys.argv[1]).read_text())
conditions=info.get("status",{}).get("conditions",[])
if not any(c.get("type")=="RuntimeReady" and c.get("status") is True for c in conditions):
    sys.exit("The CRI runtime is not ready: "+json.dumps(conditions))
print("Containerd CRI RuntimeReady verified.")
PY
  sudo systemctl enable kubelet
  sudo systemctl enable --now openvswitch-switch
  local bridge
  for bridge in n2br n3br n4br; do sudo ovs-vsctl --may-exist add-br "$bridge"; done
}

prepull_images() {
  info 'Pulling Kubernetes and addon images before initializing the cluster.'
  sudo kubeadm config images pull --config "$RENDERED_CONFIG"
  local image
  python3 - "$BUILD_DIR" <<'PY' > "${BUILD_DIR}/images.txt"
import pathlib,sys,yaml
root=pathlib.Path(sys.argv[1]); images=set()
def walk(obj):
    if isinstance(obj,dict):
        for k,v in obj.items():
            if k=="image" and isinstance(v,str): images.add(v)
            walk(v)
    elif isinstance(obj,list):
        for item in obj: walk(item)
for name in ("flannel.yaml","multus.yaml","ovs.yaml","openebs.yaml"):
    for doc in yaml.safe_load_all((root/name).read_text()): walk(doc)
# The provisioner creates helper Pods lazily, so include their image explicitly.
images.add("docker.io/openebs/linux-utils:4.1.0")
images.add("docker.io/curlimages/curl:8.12.1")
for image in sorted(images): print(image)
PY
  while IFS= read -r image; do
    info "Pulling ${image}"
    if ! sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
        --image-endpoint unix:///run/containerd/containerd.sock pull "$image"; then
      die "Image pull failed: ${image}. Check registry reachability and containerd proxy settings; the cluster was not initialized by this step."
    fi
  done < "${BUILD_DIR}/images.txt"
}

create_cluster() {
  if sudo test -f /etc/kubernetes/admin.conf; then
    info 'Checking the existing cluster before resuming addon installation.'
    # The diagnostic JSON is intentionally written as the invoking user.
    # shellcheck disable=SC2024
    sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=15s \
      -n kube-system get configmap kubeadm-config -o json > "${BUILD_DIR}/existing-cluster.json"
    python3 - "$RENDERED_CONFIG" "${BUILD_DIR}/existing-cluster.json" <<'PY'
import json,pathlib,sys,yaml
want=next(d for d in yaml.safe_load_all(pathlib.Path(sys.argv[1]).read_text()) if d["kind"]=="ClusterConfiguration")
have=yaml.safe_load(json.loads(pathlib.Path(sys.argv[2]).read_text())["data"]["ClusterConfiguration"])
for key in ("podSubnet","serviceSubnet"):
    if have["networking"][key]!=want["networking"][key]: sys.exit("Existing cluster "+key+" differs. No automatic migration.")
if have.get("controlPlaneEndpoint")!=want.get("controlPlaneEndpoint"):
    sys.exit("Existing control-plane address changed. No automatic address migration.")
PY
  else
    sudo kubeadm init --config "$RENDERED_CONFIG"
    printf '%s\n' "$K8S_MINOR" | sudo tee /etc/kubernetes/testbed-dualstack-owner >/dev/null
  fi
  install -d -m 0700 "${HOME}/.kube"
  if [[ -f "${HOME}/.kube/config" ]]; then
    cp -a "${HOME}/.kube/config" "${HOME}/.kube/config.before-testbed-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  sudo install -o "$(id -u)" -g "$(id -g)" -m 0600 /etc/kubernetes/admin.conf "${HOME}/.kube/config"
  export KUBECONFIG="${HOME}/.kube/config"
  KUBECTL_READY=1
  # Scope the single-node scheduling change to this VM.
  if kubectl get node "$(hostname -s)" -o json | \
      python3 -c 'import json,sys; sys.exit(not any(t["key"]=="node-role.kubernetes.io/control-plane" for t in json.load(sys.stdin)["spec"].get("taints",[])))'; then
    kubectl taint node "$(hostname -s)" node-role.kubernetes.io/control-plane:NoSchedule-
  fi
}

install_addons() {
  info 'Installing Flannel, Multus and OVS CNI.'
  kubectl apply -f "${BUILD_DIR}/flannel.yaml"
  kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=300s
  kubectl wait node "$(hostname -s)" --for=condition=Ready --timeout=300s
  kubectl -n kube-system rollout status deployment/coredns --timeout=300s
  kubectl apply -f "${BUILD_DIR}/multus.yaml"
  kubectl wait --for=condition=Established --timeout=120s crd/network-attachment-definitions.k8s.cni.cncf.io
  kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=300s
  kubectl apply -f "${BUILD_DIR}/ovs.yaml"
  kubectl -n kube-system rollout status daemonset/ovs-cni-amd64 --timeout=300s
  sudo test -x /opt/cni/bin/ovs
  sudo test -s /etc/cni/net.d/00-multus.conf || \
    die 'Multus did not generate /etc/cni/net.d/00-multus.conf.'
  info 'Installing OpenEBS LocalPV Hostpath.'
  helm upgrade --install openebs "${BUILD_DIR}/localpv-provisioner.tgz" \
    --namespace openebs --create-namespace \
    --set hostpathClass.isDefaultClass=true --set analytics.enabled=false \
    --wait --timeout 5m
  kubectl get storageclass openebs-hostpath
  kubectl get nodes -o wide
  kubectl get pods -A -o wide
  sudo ovs-vsctl list-br
}

smoke_test() {
  info 'Testing dual-stack Pod creation, Multus/OVS, DNS, IPv6 egress and a PVC.'
  local existing_namespace
  existing_namespace=$(kubectl --request-timeout=15s get namespace testbed-install-check --ignore-not-found -o json)
  if [[ -n "$existing_namespace" ]]; then
    python3 -c '
import json,sys
labels=json.load(sys.stdin).get("metadata",{}).get("labels",{})
if labels.get("app.kubernetes.io/managed-by")!="testbed-dualstack-installer":
    sys.exit("Existing test namespace is not owned by this installer; refusing to overwrite it.")
' <<< "$existing_namespace"
    kubectl -n testbed-install-check delete pod check-pod --ignore-not-found --timeout=60s
  fi
  # All objects below are temporary and belong to this dedicated test namespace.
  kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: testbed-install-check
  labels:
    app.kubernetes.io/managed-by: testbed-dualstack-installer
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: check-n2
  namespace: testbed-install-check
spec:
  config: '{"cniVersion":"0.4.0","type":"ovs","bridge":"n2br"}'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: check-volume
  namespace: testbed-install-check
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: openebs-hostpath
  resources:
    requests:
      storage: 16Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: check-pod
  namespace: testbed-install-check
  annotations:
    k8s.v1.cni.cncf.io/networks: check-n2
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  containers:
    - name: check
      image: docker.io/curlimages/curl:8.12.1
      command: [/bin/sh, -c]
      args: ['set -eu; printf "storage-ok\n" > /check/probe; cat /check/probe; sleep 900']
      volumeMounts:
        - name: check-volume
          mountPath: /check
  volumes:
    - name: check-volume
      persistentVolumeClaim:
        claimName: check-volume
YAML
  kubectl -n testbed-install-check wait pod/check-pod --for=condition=Ready --timeout=300s
  kubectl -n testbed-install-check get pod check-pod -o json | python3 -c '
import ipaddress,json,sys
p=json.load(sys.stdin)
ips=[entry["ip"] for entry in p["status"].get("podIPs",[])]
if {ipaddress.ip_address(ip).version for ip in ips}!={4,6}:
    sys.exit("The Pod did not receive both an IPv4 and an IPv6 address: "+str(ips))
networks=json.loads(p["metadata"]["annotations"].get("k8s.v1.cni.cncf.io/network-status","[]"))
if not any(n.get("name","").endswith("/check-n2") and n.get("interface") for n in networks):
    sys.exit("The secondary OVS attachment is missing.")
print("Pod addresses:",", ".join(ips))
print("Secondary OVS interface verified.")
'
  kubectl -n testbed-install-check exec check-pod -- cat /check/probe
  # This resolves a public hostname through CoreDNS and uses the Pod IPv6 path.
  kubectl -n testbed-install-check exec check-pod -- curl -6 -fLsS \
    --connect-timeout 10 --max-time 45 -o /dev/null https://pkgs.k8s.io/
  kubectl delete namespace testbed-install-check --wait=false
  info 'Installation and functional smoke checks completed successfully.'
  printf 'IPv6 default route:\n'
  ip -6 route show default
  printf '\nThe IPv4 API endpoint is internal to this VM/network: https://%s:6443\n' "$NODE_IPV4"
  printf 'The API certificate also includes the node IPv6: %s\n' "$NODE_IPV6"
  printf 'Logs and generated configuration: %s\n' "$BUILD_DIR"
}

main() {
  while (($#)); do
    case "$1" in
      --check) CHECK_ONLY=1 ;;
      --help|-h) usage; return 0 ;;
      *) usage >&2; die "Unknown argument: $1" ;;
    esac
    shift
  done
  inspect_host
  download_checks
  [[ "$CHECK_ONLY" == 0 ]] || return 0
  [[ "$EUID" -ne 0 ]] || die 'Run ./install.sh as a regular sudo user, without sudo before the script.'
  # Validation-only sudo (-v) may require a password under verifypw even
  # when normal commands are allowed without one. Test a real command first.
  if ! sudo -n true 2>/dev/null; then
    sudo -v
  fi
  check_existing_installation
  mkdir -p "$BUILD_DIR"
  exec > >(tee -a "${BUILD_DIR}/install-$(date -u +%Y%m%dT%H%M%SZ).log") 2>&1
  install_packages
  render_config
  prepare_manifests
  configure_host_networking
  configure_runtime
  prepull_images
  create_cluster
  install_addons
  smoke_test
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

