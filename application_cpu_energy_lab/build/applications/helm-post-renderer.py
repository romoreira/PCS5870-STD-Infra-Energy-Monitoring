#!/usr/bin/env python3
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
